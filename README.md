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
modules/tailscale-client.nix     join the tailnet             (qt1.infra.tailscaleClient)
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
    adminSshKey = "ssh-ed25519 AAAA... you@yourhost";
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

headplane has no web UI of its own at `/` — it's mounted under `/admin`
(fixed by headplane itself, not configurable), so browse to
`https://headplane.qt1.fr/admin`. headscale has no web UI at all; a blank
page at its root is normal, and `/health` is the way to check it's alive.

`serverUrl`, `baseDomain` (for MagicDNS), `headplaneUrl` and `adminSshKey`
have no defaults and must be set when enabling the guest — see the snippet
above. Unlike the cloudflared tunnel token, headplane's session cookie and
the guest's SSH host key need no human input, so there's nothing to
provision by hand: `headscale-provision-secrets` generates whichever one is
missing under `/var/lib/microvms/headscale/` before the VM starts, the first
time you switch with the guest enabled. Both arrive in the guest as systemd
credentials (qemu runner only), so neither lands in the Nix store.

To rotate either one, remove the file and restart the generator (the VM
picks it up on its own next restart, via `Wants=`/`After=`):

```
sudo rm /var/lib/microvms/headscale/headplane-cookie-secret   # or ssh_host_ed25519_key
sudo systemctl restart headscale-provision-secrets.service
sudo systemctl restart microvm@headscale
```

`adminSshKey` authorizes root SSH into the guest, key-only, reachable only
from the host (not from other guests on the bridge) — needed because the
`headscale` CLI (`headscale users create`, `headscale apikeys create`, ...)
talks to the running server over a local socket, so it has to run on the
guest itself: `ssh root@10.100.0.3 headscale apikeys create`.

headscale's default DERP relays are Tailscale's own (`derp.urls`), so no UDP
port needs exposing for that either — only the two TCP ports above, reached
from cloudflared over the guest bridge.

**Nothing here survives a from-scratch reinstall of the host.** The node/key
database, headplane's data and both secrets above all live under
`/var/lib/microvms/headscale/` on the host's own root filesystem — there's no
separate persistent dataset backing it. Back that directory up before
reinstalling, or be ready to reprovision the two secrets and have every
Tailscale client re-register against a fresh instance.

## Joining the tailnet (`qt1.infra.tailscaleClient`)

Any machine — the bare host or a guest — can join the tailnet this repo's own
headscale coordinates, via `qt1.infra.tailscaleClient`:

```nix
qt1.infra.tailscaleClient = {
  enable = true;
  loginServerUrl = config.qt1.infra.guests.headscale.internalUrl;
  authKeyFile = config.qt1.infra.guests.headscale.tailscaleAuthKeyFile;
  # ephemeral = true;   # set for machines with non-persistent state
};
```

**Use `internalUrl`, not `serverUrl`, for anything that's already on the guest
bridge** — the host and any guest. Cloudflare Tunnel does not pass through
the `Upgrade` header Tailscale's client-registration protocol (ts2021/noise)
needs: every attempt through the public `serverUrl` fails server-side with
*"no upgrade header in TS2021 request"*, a Cloudflare/Tailscale protocol
incompatibility with no fix on this end. `internalUrl` (headscale's plain
`http://` address on the bridge) sidesteps Cloudflare entirely, which is also
just the more direct route for traffic that never needed to leave the LAN.
This means an actual external Tailscale client — a phone, a laptop away from
home — trying to join via the public hostname will likely hit the same wall;
that's a separate, bigger problem than internal auto-join and isn't solved
here.

For the *host* this is the option above, applied directly. For a *guest*, use
that guest's own opt-in instead (currently `qt1.infra.guests.cloudflared.tailscale.enable`)
— it wires `loginServerUrl` from the headscale guest automatically and passes
the key in as a systemd credential, the same way as the cloudflared tunnel
token, rather than a plain file path. cloudflared's join is `--ephemeral`
since its root is tmpfs: without that, every restart would register as a new
device and headscale would accumulate dead nodes.

**No manual step here, unlike the other secrets in this repo — including the
pre-auth key itself.** Minting one normally requires headscale already
running and a user already created in it, which is exactly what
`headscale-mint-tailscale-authkey` does on the host, unattended: it waits for
the headscale guest's SSH to come up, using a second host-generated keypair
(distinct from `adminSshKey`, authorized the same way, see
`automationSshKeyFile`) to create a `tailnetUser` (default `homelab`) if it
doesn't exist and mint it a reusable, 10-year pre-auth key at
`tailscaleAuthKeyFile`. Every consumer — the host, cloudflared — points at
that same shared file. Idempotent on that file already existing, so this only
ever runs for real once; to rotate the key, remove the file and restart:

```
sudo rm /var/lib/microvms/headscale/tailscale-authkey
sudo systemctl restart headscale-mint-tailscale-authkey
```

The headscale guest itself is deliberately not a tailnet member — the
coordination server being its own client would mean reaching itself back
through its own tunnel, which is more circularity than it's worth.

Enabling any of this for the first time changes the headscale and cloudflared
guests' own configuration (new SSH credential wiring), so the switch that
turns it on restarts both VMs to pick it up — a brief, expected interruption,
not a sign anything is wrong.

## Adding a guest

1. `guests/<name>.nix` — the guest's NixOS config, as a function of its network
   coordinates (see `guests/cloudflared.nix`). microvm.nix evaluates guests in
   a nested `nixosSystem` that receives none of the host's specialArgs, so pass
   anything it needs explicitly.
2. `modules/guests/<name>.nix` — `qt1.infra.guests.<name>` options and the
   `microvm.vms.<name>` declaration.
3. Add it to `nixosModules.microvmHost`'s imports in `flake.nix`, give it an
   address and a MAC, and enable it in `checks/test-host.nix`.
