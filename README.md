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
modules/tailscale-client.nix     join the tailnet             (qt1.infra.tailscaleClient)
modules/guests/headscale.nix     host-side VM declaration     (qt1.infra.guests.headscale)
guests/headscale.nix             the guest's own NixOS config
modules/guests/caddy.nix         host-side VM declaration     (qt1.infra.guests.caddy)
guests/caddy.nix                 the guest's own NixOS config
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
    # Trusted for root on every guest that exposes SSH, by default (see
    # "headscale guest" below) — e.g. the host's own SSH identity.
    adminSshKeys = [ "ssh-ed25519 AAAA... root@yourhost" ];
  };
  guests.headscale = {
    enable = true;
    serverUrl = "https://access.example.com";
    baseDomain = "tailnet.example.com";   # must differ from serverUrl's domain
    adminSshKeys = [ "ssh-ed25519 AAAA... you@yourhost" ];
  };
  guests.caddy = {
    enable = true;
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

## caddy guest

`caddy` (10.100.0.3) is the WAN-facing entrypoint into the local
infrastructure — a [Caddy](https://caddyserver.com) reverse proxy, run from
nixpkgs' own `services.caddy` module (no Docker), whose only job is
terminating TLS for headscale and gating what's actually allowed through to
it. **This guest needs real inbound ports.** The host forwards them in from
the WAN (`networking.nat.forwardPorts`, wired by `modules/guests/caddy.nix`):

| Port | Proto | Purpose                                    |
| ---- | ----- | ------------------------------------------- |
| 80   | tcp   | ACME HTTP-01 challenge, http→https redirect |
| 443  | tcp   | HTTPS: the Tailscale client protocol, proxied through to headscale |

Your router/firewall must forward these from your WAN address to this host —
that's outside this repo's scope. You also need DNS: an A/AAAA record for
`qt1.infra.guests.headscale.serverUrl`'s hostname, pointed at your WAN
address (this is the *only* DNS record needed — not a wildcard; nothing here
uses subdomains-per-resource the way the old Pangolin stack did).

**`/api/v1/*` (headscale's REST API) is not proxied through at all** — this
is the whole reason caddy sits in front rather than leaving headscale to
terminate its own TLS (which it can do, but can't split `/api` off from the
client protocol on the same listener). Caddy's own Caddyfile
(`guests/caddy.nix`) matches `/api/*` and returns a bare 404 before it ever
reaches headscale; every other path is reverse-proxied to headscale's
internal address. For anything that would otherwise need `/api/v1` from
outside the bridge, use the local `headscale` CLI over SSH instead — see the
headscale guest section below.

Caddy's own certificate and ACME account data live under `/var/lib/caddy`, a
persistent volume, so a guest restart doesn't mean re-issuing a certificate
(and burning into Let's Encrypt's rate limit) every time. There's no SSH into
this guest — it's entirely declared here, nothing to run a CLI against — so
its logs are mirrored to the serial console instead: `journalctl -u
microvm@caddy` on the host.

## headscale guest

`headscale` is a self-hosted [headscale](https://github.com/juanfont/headscale)
coordination server for Tailscale, run entirely from nixpkgs' own
`services.headscale` module (no Docker). Unlike the old Cloudflare Tunnel or
the Pangolin stack this repo ran before it, headscale is not itself
WAN-facing: it only listens plain HTTP on the guest bridge
(`internalPort`, `10.100.0.2:8080` by default) and is reached from the
outside only through the caddy guest above, which is what actually holds
the TLS certificate for `serverUrl`'s hostname.

`/api/v1/*` is bearer-token gated on its own (401 without a valid API key),
but with caddy in front that's now a second layer, not the only one — see
the caddy section above for what actually keeps it off the WAN. This repo
never provisions a long-lived API key ahead of time either way — mint one on
demand, over SSH, only when you actually need it:

```
ssh root@10.100.0.2 headscale apikeys create --expiration 90d
```

gRPC (`grpc_listen_addr`) is unaffected by any of this: it defaults to
`127.0.0.1` only and was never in the WAN forwardPorts to begin with, so
it's unreachable from the WAN regardless. The local `headscale` CLI (used
above, and by `headscale-mint-tailscale-authkey` below) talks over a unix
socket instead, so it never needs gRPC at all.

Everything else is unattended: headscale generates its own Noise/DERP private
keys under `/var/lib/headscale` (a persistent volume) the first time it's
missing, no different from how it behaves on bare metal. `serverUrl` and
`baseDomain` have no defaults and must be set when enabling the guest — see
the snippet above; `letsEncryptEmail` lives on `qt1.infra.guests.caddy` now,
since caddy is what does ACME.

`adminSshKeys` authorizes root SSH into the guest, key-only, reachable only
from the host (not from other guests on the bridge or the WAN) — needed
because the `headscale` CLI (`headscale users create`, `headscale apikeys
create`, ...) talks to the running server over a local socket, so it has to
run on the guest itself: `ssh root@10.100.0.2 headscale --help`. The guest
trusts `qt1.infra.microvmHost.adminSshKeys` (the host-wide default — every
SSH-exposed guest trusts these) plus this guest's own `adminSshKeys`, combined.

**Nothing here survives a from-scratch reinstall of the host.** The node/key
database and both generated private keys live under `/var/lib/headscale` on
the host's own root filesystem — there's no separate persistent dataset
backing it (same for caddy's `/var/lib/caddy`). Back these up before
reinstalling, or be ready to reprovision and have every Tailscale client
re-register against a fresh instance.

## Joining the tailnet (`qt1.infra.tailscaleClient`)

Any machine — the bare host or a guest — can join the tailnet this repo's own
headscale coordinates, via `qt1.infra.tailscaleClient`:

```nix
qt1.infra.tailscaleClient = {
  enable = true;
  loginServerUrl = config.qt1.infra.guests.headscale.serverUrl;
  authKeyFile = config.qt1.infra.guests.headscale.tailscaleAuthKeyFile;
  # ephemeral = true;   # set for machines with non-persistent state
};
```

**For anything already on the guest bridge — the host, or another guest —
also add a `networking.hosts` entry pointing `serverUrl`'s hostname at the
*caddy* guest's own bridge address** (caddy holds the TLS certificate now,
not headscale — see the caddy guest section above):

```nix
networking.hosts.${config.qt1.infra.guests.caddy.address} = [
  config.qt1.infra.guests.headscale.tlsHostname
];
```

This resolves the same public hostname straight to the bridge instead of out
through the WAN and back in via the router's port forward (NAT hairpinning,
which not every router supports reliably) — the TLS handshake still
validates correctly, since the certificate is for the hostname, not whichever
IP you actually connected to. Skip this for a genuinely external Tailscale
client (a phone, a laptop away from home); it has no bridge to shortcut
through and just uses `serverUrl` over the WAN normally.

**No manual step here, unlike the guest's own secrets above — including the
pre-auth key itself.** Minting one normally requires headscale already
running and a user already created in it, which is exactly what
`headscale-mint-tailscale-authkey` does on the host, unattended: it waits for
the headscale guest's SSH to come up, using a second host-generated keypair
(distinct from `adminSshKeys`, authorized the same way, see
`automationSshKeyFile`) to create a `tailnetUser` (default `homelab`) if it
doesn't exist and mint it a reusable, 10-year pre-auth key at
`tailscaleAuthKeyFile`. Every consumer points at that same shared file.
Idempotent on that file already existing, so this only ever runs for real
once; to rotate the key, remove the file and restart:

```
sudo rm /var/lib/microvms/headscale/tailscale-authkey
sudo systemctl restart headscale-mint-tailscale-authkey
```

The headscale guest itself is deliberately not a tailnet member — the
coordination server being its own client would mean reaching itself back
through its own tunnel, which is more circularity than it's worth.

## Adding a guest

1. `guests/<name>.nix` — the guest's NixOS config, as a function of its network
   coordinates (see `guests/headscale.nix`). microvm.nix evaluates guests in
   a nested `nixosSystem` that receives none of the host's specialArgs, so pass
   anything it needs explicitly.
2. `modules/guests/<name>.nix` — `qt1.infra.guests.<name>` options and the
   `microvm.vms.<name>` declaration.
3. Add it to `nixosModules.microvmHost`'s imports in `flake.nix`, give it an
   address and a MAC, and enable it in `checks/test-host.nix`.
