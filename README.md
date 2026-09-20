# Qt1-Infrastructure

Infrastructure layer for the homelab: the [microvm.nix](https://github.com/microvm-nix/microvm.nix)
host wiring, the guests, and the services running on them. OS-level
configuration for the machines themselves lives in the separate
[devSystem](../devSystem) flake.

The two flakes are independent: this one has its own `nixpkgs` and `microvm`
inputs and builds on its own, and devSystem consumes it as a flake input.

## Layout

```
flake.nix                        nixosModules.default, standalone test host, checks
modules/microvm-host.nix         guest bridge + NAT           (qt1.infra.microvmHost)
modules/guests/newt.nix          host-side VM declaration     (qt1.infra.guests.newt)
guests/newt.nix                  the guest's own NixOS config
modules/guests/pangolin.nix      host-side VM declaration     (qt1.infra.guests.pangolin)
guests/pangolin.nix              the guest's own NixOS config
checks/test-host.nix             minimal host, used only to build this layer alone
```

`nixosModules.default` imports microvm.nix's host module plus everything above.
All of it is gated behind `qt1.infra.*` options, and `microvm.host.enable`
follows `qt1.infra.microvmHost.enable`, so importing the module without
enabling anything leaves the host untouched.

The modules take no `inputs` specialArg — the `microvm` input is closed over in
`flake.nix` — so any flake can import them without carrying this flake's
inputs.

## Use from another flake

```nix
# flake.nix
inputs.qt1-infrastructure = {
  url = "git+file:///Users/quentin/Projects/Qt1-Infrastructure";
  inputs.nixpkgs.follows = "nixpkgs";   # one nixpkgs per host
};
```

```nix
# the host's configuration.nix
imports = [ inputs.qt1-infrastructure.nixosModules.default ];

qt1.infra = {
  microvmHost = {
    enable = true;
    uplinkInterface = "enp2s0";   # the only OS fact this layer needs
  };
  guests.newt.enable = true;
  guests.pangolin = {
    enable = true;
    dashboardDomain = "example.com";   # can equal baseDomain, see its option doc
    baseDomain = "example.com";
    letsEncryptEmail = "you@example.com";
  };
};
```

Defaults worth knowing: bridge `microvm`, `10.100.0.0/24` with the host at
`.1`, guests NAT'd out of `uplinkInterface`. Guests are built with the *host's*
`pkgs`, so under `follows` they come from the same nixpkgs revision as their
host.

## Build it standalone

```
nix flake check                                  # on x86_64-linux
nix eval .#nixosConfigurations.infra-test.config.system.build.toplevel.drvPath
```

The second form only evaluates, so it works from macOS.

## pangolin guest

`pangolin` (10.100.0.4) is the WAN-facing entrypoint into the local
infrastructure — a self-hosted [Pangolin](https://github.com/fosrl/pangolin)
stack, replacing the old Cloudflare Tunnel. Three docker containers, run the
same way upstream's own compose file runs them (there's no native nixpkgs
package for any of them):

- **pangolin**: the control-plane app — dashboard, API, and the database of
  sites/resources/targets.
- **gerbil**: the WireGuard gateway sites tunnel through. Owns the ports that
  are actually reachable from the WAN.
- **traefik**: reverse-proxies resources to their targets and terminates TLS
  via Let's Encrypt.

Unlike Cloudflare Tunnel, **this guest needs real inbound ports.** The host
forwards them in from the WAN (`networking.nat.forwardPorts`, wired by
`modules/guests/pangolin.nix`):

| Port        | Proto | Purpose                          |
| ----------- | ----- | --------------------------------- |
| 80          | tcp   | HTTP → HTTPS redirect, ACME       |
| 443         | tcp   | HTTPS (dashboard + resources)     |
| 51820       | udp   | WireGuard (sites ↔ gerbil)        |
| 21820       | udp   | WireGuard (clients ↔ gerbil)      |

Your router/firewall must forward these from your WAN address to this host —
that's outside this repo's scope. You also need DNS: an A/AAAA record for
`dashboardDomain` and a wildcard record for `*.baseDomain`, both pointed at
your WAN address.

Everything else is unattended: `server.secret` is generated on the guest's own
persistent volume the first time it's missing (nothing to provision by hand,
unlike newt's config file below), and Pangolin/gerbil/traefik's own config
files are rendered from `dashboardDomain`, `baseDomain` and `letsEncryptEmail`
at build time.

After the first switch, watch it come up and grab the one-time setup token
from `journalctl -u microvm@pangolin -f` on the host (see the note on
`docker-pangolin`'s console logging above), then open
`https://<dashboardDomain>/auth/initial-setup` — or, before DNS/port-forwarding
are even live, reach the dashboard directly over the bridge at
`http://<pangolin address>:3002` — to create an admin account and your first
organization. From there, add **Resources** (public hostnames under
`baseDomain`) pointed at their **Targets** (an address on the guest bridge,
e.g. another guest's IP:port) — this is the Pangolin-dashboard equivalent of
what used to be configured in the Cloudflare Zero Trust dashboard.

Docker's own image/layer storage and Pangolin's config/db/certs each live on a
persistent volume (`/var/lib/docker` and `/var/lib/pangolin` respectively), so
neither is re-pulled nor regenerated across guest restarts.

## newt guest

`newt` (10.100.0.2) is Pangolin's lightweight site connector — a fully
userspace WireGuard client (no kernel module or capabilities needed) that
dials out to the pangolin guest and proxies whatever targets are registered
against it. It plays the same "dashboard-managed, only needs one credential"
role cloudflared used to.

To provision it: in the Pangolin dashboard, add a **Site** of type **Newt**,
which gives you a Newt ID and secret. Then, on the host, after the first
switch:

```
sudo install -d -m 0755 -o microvm -g kvm /var/lib/microvms/newt
sudo install -m 0400 -o microvm -g kvm /dev/stdin /var/lib/microvms/newt/newt-config.json <<'EOF'
{
  "endpoint": "http://10.100.0.4:3000",
  "id": "<newt id from the dashboard>",
  "secret": "<newt secret from the dashboard>"
}
EOF
sudo systemctl start microvm@newt
```

`endpoint` above is `qt1.infra.guests.pangolin.internalUrl`: this newt site is
this repo's own, colocated on the same guest bridge as the pangolin guest, so
it talks to Pangolin's API directly over the bridge instead of round-tripping
through the WAN entrypoint, DNS and TLS to reach itself. It's otherwise no
different from — and authenticates the same way as — a newt site running
anywhere else.

The config file is only read when the VM boots: after changing it, run
`sudo systemctl restart microvm@newt`. It is passed in as a systemd credential
(qemu runner only), so it never lands in the Nix store. newt's logs are on the
host, in `journalctl -u microvm@newt`.

## Adding a guest

1. `guests/<name>.nix` — the guest's NixOS config, as a function of its network
   coordinates (see `guests/newt.nix`). microvm.nix evaluates guests in
   a nested `nixosSystem` that receives none of the host's specialArgs, so pass
   anything it needs explicitly.
2. `modules/guests/<name>.nix` — `qt1.infra.guests.<name>` options and the
   `microvm.vms.<name>` declaration.
3. Add it to `nixosModules.microvmHost`'s imports in `flake.nix`, give it an
   address and a MAC, and enable it in `checks/test-host.nix`.
