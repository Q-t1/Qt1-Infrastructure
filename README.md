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
modules/guests/cloudflared.nix   host-side VM declaration     (qt1.infra.guests.cloudflared)
guests/cloudflared.nix           the guest's own NixOS config
modules/guests/headscale.nix     host-side VM declaration     (qt1.infra.guests.headscale)
guests/headscale.nix             the guest's own NixOS config
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
  guests.cloudflared.enable = true;
  guests.headscale = {
    enable = true;
    serverUrl = "https://headscale.example.com";
    baseDomain = "tailnet.example.com";
    headplaneUrl = "https://headplane.example.com";
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

## cloudflared guest

`cloudflared` (10.100.0.2) runs a dashboard-managed Cloudflare Tunnel — the
entrypoint into the local infrastructure. Public hostnames and private routes
are configured in Cloudflare Zero Trust, so the VM only needs a tunnel token,
and it stays stopped until that token is on the host. Create the tunnel in the
dashboard (connector: cloudflared), copy its token, then on the host, after the
first switch:

```
sudo install -m 0400 -o microvm -g kvm /dev/stdin /var/lib/microvms/cloudflared/tunnel-token
# paste the token, then Ctrl-D
sudo systemctl start microvm@cloudflared
```

The token is only read when the VM boots: after rotating it, run
`sudo systemctl restart microvm@cloudflared`. It is passed in as a systemd
credential (qemu runner only), so it never lands in the Nix store. Tunnel logs
are on the host, in `journalctl -u microvm@cloudflared`.

LAN origins see the tunnel's traffic coming from the host's own address; a
service on the host itself also needs its port opened in the host firewall.

## headscale + headplane guest

`headscale` (10.100.0.3) runs [headscale](https://github.com/juanfont/headscale)
(a self-hosted Tailscale coordination server) and
[headplane](https://github.com/tale/headplane) (its web UI) together on one
guest. Unlike cloudflared it is stateful: its node/key database and
headplane's own data live on two persistent volumes
(`/var/lib/microvms/headscale/{headscale,headplane}-data.img`), auto-created
on first boot, so they survive guest restarts.

Both services are reached only through the cloudflared tunnel — nothing here
opens a port on the host or the WAN. headscale and headplane are on the same
bridge as cloudflared, so it reaches them directly; add two public hostnames
in the Cloudflare Zero Trust dashboard, routed to:

- `http://10.100.0.3:8080` for `serverUrl` (headscale)
- `http://10.100.0.3:3000` for `headplaneUrl` (headplane)

`serverUrl`, `baseDomain` (for MagicDNS) and `headplaneUrl` have no defaults
and must be set when enabling the guest — see the snippet above. headplane
also needs a 32-character session cookie secret, provisioned by hand like the
cloudflared tunnel token, then on the host, after the first switch:

```
sudo install -m 0400 -o microvm -g kvm /dev/stdin /var/lib/microvms/headscale/headplane-cookie-secret
# paste 32 characters, no trailing newline, then Ctrl-D
sudo systemctl start microvm@headscale
```

The secret is only read when the VM boots: after rotating it, run
`sudo systemctl restart microvm@headscale`. It arrives as a systemd
credential (qemu runner only), so it never lands in the Nix store.

headscale's default DERP relays are Tailscale's own (`derp.urls`), so no UDP
port needs exposing for that either — only the two TCP ports above, reached
from cloudflared over the guest bridge.

## Adding a guest

1. `guests/<name>.nix` — the guest's NixOS config, as a function of its network
   coordinates (see `guests/cloudflared.nix`). microvm.nix evaluates guests in
   a nested `nixosSystem` that receives none of the host's specialArgs, so pass
   anything it needs explicitly.
2. `modules/guests/<name>.nix` — `qt1.infra.guests.<name>` options and the
   `microvm.vms.<name>` declaration.
3. Add it to `nixosModules.microvmHost`'s imports in `flake.nix`, give it an
   address and a MAC, and enable it in `checks/test-host.nix`.
