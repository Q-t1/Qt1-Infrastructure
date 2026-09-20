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
  guests.headscale = {
    enable = true;
    serverUrl = "https://access.example.com";
    baseDomain = "tailnet.example.com";   # must differ from serverUrl's domain
    letsEncryptEmail = "you@example.com";
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

## headscale guest

`headscale` (10.100.0.2) is the WAN-facing entrypoint into the local
infrastructure — a self-hosted [headscale](https://github.com/juanfont/headscale)
coordination server for Tailscale, run entirely from nixpkgs' own
`services.headscale` module (no Docker, no separate reverse proxy). Unlike
the old Cloudflare Tunnel or the Pangolin stack this repo ran before it,
headscale terminates its own TLS via built-in Let's Encrypt
(`tls_letsencrypt_hostname`), so **this guest needs real inbound ports**. The
host forwards them in from the WAN (`networking.nat.forwardPorts`, wired by
`modules/guests/headscale.nix`):

| Port | Proto | Purpose                                      |
| ---- | ----- | --------------------------------------------- |
| 80   | tcp   | ACME HTTP-01 challenge (`tls_letsencrypt_listen`) |
| 443  | tcp   | headscale itself: the Tailscale client protocol *and* `/api/v1/*` |

Your router/firewall must forward these from your WAN address to this host —
that's outside this repo's scope. You also need DNS: an A/AAAA record for
`serverUrl`'s hostname pointed at your WAN address. `baseDomain` (for
MagicDNS) needs no DNS record of its own — headscale resolves it internally
for tailnet clients, not the public internet.

**`/api/v1/*` is not network-isolated from the client protocol.** headscale
serves both on the same TLS listener with no config knob to split them onto
different paths or ports, so the REST API is technically reachable from the
WAN. It's bearer-token gated (401 without a valid API key), and this repo
never provisions a long-lived key ahead of time — mint one on demand, over
SSH, only when you actually need it:

```
ssh root@10.100.0.2 headscale apikeys create --expiration 90d
```

gRPC (`grpc_listen_addr`) is unaffected by any of this: it defaults to
`127.0.0.1` only and is never in `forwardPorts` above, so it's unreachable
from the WAN regardless. The local `headscale` CLI (used above, and by
`headscale-mint-tailscale-authkey` below) talks over a unix socket instead,
so it never needs gRPC at all.

Everything else is unattended: headscale generates its own Noise/DERP private
keys and its Let's Encrypt cert cache under `/var/lib/headscale` (a
persistent volume) the first time it's missing, no different from how it
behaves on bare metal. `serverUrl`, `baseDomain`, `letsEncryptEmail` and
`adminSshKey` have no defaults and must be set when enabling the guest — see
the snippet above.

`adminSshKey` authorizes root SSH into the guest, key-only, reachable only
from the host (not from other guests on the bridge or the WAN) — needed
because the `headscale` CLI (`headscale users create`, `headscale apikeys
create`, ...) talks to the running server over a local socket, so it has to
run on the guest itself: `ssh root@10.100.0.2 headscale --help`.

**Nothing here survives a from-scratch reinstall of the host.** The node/key
database, both generated private keys and the Let's Encrypt cache all live
under `/var/lib/headscale` on the host's own root filesystem — there's no
separate persistent dataset backing it. Back that directory up before
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
headscale guest's own bridge address:**

```nix
networking.hosts.${config.qt1.infra.guests.headscale.address} = [
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
(distinct from `adminSshKey`, authorized the same way, see
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
