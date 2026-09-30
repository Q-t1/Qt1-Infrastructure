# AGENT.md

Context for coding agents working in this repo. `README.md` is the
operator-facing manual (setup, DNS, trusting the CA, rotation commands); this
file covers how the flake is built and the invariants to keep when changing it.

## What this is

The infrastructure layer of a homelab: a NixOS module that turns a host into a
[microvm.nix](https://github.com/microvm-nix/microvm.nix) hypervisor and
declares the guests running on it. OS-level host config lives in the separate
`devSystem` flake, which imports `nixosModules.default` from here. The flakes are
independent: this one has its own `nixpkgs`/`microvm` inputs and builds alone.

Everything is gated behind `qt1.infra.*`. Importing the module without enabling
anything leaves the host untouched.

## Flake outputs

| Output | What |
| --- | --- |
| `nixosModules.default` / `.microvmHost` | `microvm.nixosModules.host` + every module under `modules/` |
| `nixosConfigurations.infra-test` | `checks/test-host.nix`: every option enabled, eval/build only, never deployed |
| `checks.x86_64-linux.infra-test` | That host's toplevel |
| `formatter.<system>` | `nixfmt` |

```sh
nix flake check                    # x86_64-linux only
nix eval .#nixosConfigurations.infra-test.config.system.build.toplevel.drvPath   # works on macOS too
nix fmt
```

Run both the eval and `nix fmt` after any change. There are no runtime tests, so
the test host evaluating is the only automated signal.

## Layout

```
flake.nix                    outputs; module import list
lib.nix                      guestOptions, mkGuest, provisionSecrets, headscaleRemoteShell, publicResolvers
modules/microvm-host.nix     qt1.infra.microvmHost      bridge `microvm`, NAT out of uplinkInterface
modules/tailscale-client.nix qt1.infra.tailscaleClient  tailnet join (host or guest)
modules/crowdsec.nix         qt1.infra.crowdsec         host-side CrowdSec + firewall bouncer
modules/guests/<name>.nix    qt1.infra.guests.<name>    host side of each guest: options, VM entry, host services
guests/base.nix              qt1.guest                  shared by every guest
guests/<name>.nix            the guest's own NixOS config
guests/dashboards/<topic>/   Grafana dashboards, one provisioning provider per topic
checks/test-host.nix         minimal host enabling everything
```

## Network and guests

Bridge `microvm`, `10.100.0.0/24`, host at `.1` (the guests' gateway). Guest `N`
gets `10.100.0.N` and MAC `02:00:00:00:00:NN` (hex), tap `vm-<name>`. Guests are
NAT'd out of `microvmHost.uplinkInterface`. Only caddy has WAN port forwards.

| Guest | Option | IP | vCPU/MiB | Role | Reachable by |
| --- | --- | --- | --- | --- | --- |
| headscale | `guests.headscale` | .2 | 2 / 512 (1024 with Headplane) | Tailscale coordination server, optional Headplane UI | caddy → :8080; host → :22 SSH, :50443 gRPC (if `grpcFromHost`); caddy-internal → :3000 Headplane |
| caddy | `guests.caddy` | .3 | 1 / 256 | WAN reverse proxy, Let's Encrypt | WAN :80/:443 (forwarded); monitoring → :2020 metrics |
| monitoring | `guests.monitoring` | .4 | 2 / 1536 | Loki + Prometheus + Grafana | host → :3100 Loki push; caddy-internal → :3000 Grafana |
| caddy-internal | `guests.caddyInternal` | .5 | 1 / 256 | Tailnet-only reverse proxy, local CA | tailnet → :80/:443 on `tailscale0`; gatus → :443; monitoring → :2020 |
| gatus | `guests.gatus` | .6 | 1 / 256 | Public status page | caddy → :8080; host → :8080 (push API) |

Host-side services on the bridge interface only: node_exporter `:9100`,
prometheus-tailscale-exporter `:9250`, CrowdSec metrics `:6060`. The CrowdSec
LAPI stays on loopback.

### Traffic paths

- **WAN → headscale:** router → host NAT → caddy (TLS) → headscale `:8080`
  (plain HTTP). caddy returns 404 for `/api/*`, so headscale's REST API is never
  reachable from outside. Use the `headscale` CLI over SSH instead.
- **WAN → other public sites:** `guests.caddy.virtualHosts.<hostname> =
  "ip:port"`. Currently only gatus uses this.
- **Tailnet → internal apps:** caddy-internal is the tailnet node, and the apps
  never join the tailnet. `guests.caddyInternal.virtualHosts.<label>` →
  `https://<label>.<baseDomain>/`. Names are headscale extra DNS records
  (`guests.headscale.magicDnsAliases`), rewritten every minute by the
  `headscale-magicdns-aliases` timer inside the headscale guest, because node IPs
  aren't known at build time. Certificates come from caddy's `local_certs` CA:
  headscale can't do DNS-01. The CA root is served over plain HTTP at
  `http://caddy-internal.<baseDomain>/root.crt`.
- **Tailnet join (NAT-hairpin shortcut):** every bridge-local tailscale client
  pins `serverUrl`'s hostname to caddy's bridge IP through `networking.hosts`
  (`tailscaleClient.loginServerAddress`). gatus does the same for its checks.

## Core patterns (follow these)

**One guest = two files.** `modules/guests/<name>.nix` is the host side;
`guests/<name>.nix` is the guest's NixOS config.

- Host side declares `options.qt1.infra.guests.<name> = infraLib.guestOptions {
  index; description; } // { … }`, then
  `config = lib.mkIf cfg.enable (lib.mkMerge [ (infraLib.mkGuest config { … }) … ])`.
- `mkGuest config { name; cfg; module; credentialFiles ? {}; tailnet ? false; }`
  creates `microvm.vms.<name>` with `guests/base.nix` + `module`, fills
  `qt1.guest.*`, adds assertions, and sets `microvm.systemSymlink = true`.
  Without that last setting, `microvm -l` breaks.
- The guest module is a **function of plain arguments** returning a NixOS module:
  `module = import ../../guests/<name>.nix { … };`. microvm.nix evaluates guests
  in a nested `nixosSystem` without the host's specialArgs, so every value the
  guest needs is passed explicitly. Optional features are passed as `{ }`/`null`
  and tested with `!= { }`. Build them with `lib.optionalAttrs`, **never
  `lib.mkIf`**: these are function arguments, not option definitions, so an
  `mkIf` would arrive as an unreadable attrset.
- Nothing takes an `inputs` specialArg. `lib.nix` is imported by path:
  `import ../../lib.nix { inherit lib; }`.

**Firewalling.** Guests open bridge ports to a *single* source with
`qt1.guest.allowedTCPPortsFrom = [ { port; from; } ]` (iptables `extraCommands`
ahead of the default drop). `networking.firewall.allowedTCPPorts` is used only
for ports every bridge peer may reach (headscale `:8080`, caddy `:80/:443`).
Services often bind `0.0.0.0`, and the firewall rule does the scoping. That is
deliberate: `systemd-networkd-wait-online` is disabled on the host, so binding a
bridge address races boot.

**Cross-module wiring.** A feature's module flips the options it depends on in
other modules. Don't set these by hand:

| Setter | Sets |
| --- | --- |
| `guests.caddy` | `tailscaleClient.loginServerAddress` (mkDefault) |
| `guests.headscale` | `tailscaleClient.{loginServerUrl,authKeyFile}` (mkDefault); `caddyInternal.virtualHosts.headplane` |
| `guests.caddyInternal` | `headscale.magicDnsAliases` from its vhosts |
| `guests.monitoring` | `caddyInternal.virtualHosts.grafana`; `caddy/caddyInternal.metricsFromMonitoring` (`caddyMetrics`); `headscale.grpcFromHost` (`headscaleMetrics`); `crowdsec.metricsFromGuests` (`crowdsecMetrics`) |
| `guests.gatus` | `caddy.virtualHosts.<hostname>`; `caddyInternal.probesFromGatus`; endpoints derived from `headscale.tlsHostname` and `caddyInternal.urls`; `microvms` default from `microvm.autostart` |

Dependencies are enforced with `assertions` and messages that explain why. Fixed
values another module needs are exposed as `readOnly` options (`metricsPort`,
`internalPort`, `grpcPort`, `urls`, `tlsHostname`, …). A few ports are
duplicated as `let` constants between the two halves of a guest and marked
`# Must match …`.

**Guests are stateless except for volumes.** The root is tmpfs. State goes on
`microvm.volumes` images under `/var/lib/microvms/<vm>/` on the host, which
aren't backed up and don't survive a host reinstall. SSH is enabled only on
headscale, host-only and key-only. Every other guest mirrors its services'
output to the serial console (`StandardOutput/StandardError =
"journal+console"`), so `journalctl -u microvm@<name>` on the host is the only
way to see its logs. That same host journal feeds CrowdSec and Alloy → Loki.

**Secrets are generated on the host, unattended.**

- `infraLib.provisionSecrets { vm; description; path; secrets = { "<host path>" = "<shell writing \"$f\">"; }; }`
  creates a `<vm>-provision-secrets` oneshot ordered before `microvm@<vm>`.
  It's idempotent: to rotate a secret, delete the file and restart the unit.
- They reach the guest through `mkGuest`'s `credentialFiles` → qemu fw_cfg →
  systemd credentials. The guest reads them with `ImportCredential` from
  `/run/credentials/<unit>/<name>`. Secrets never enter the Nix store.
- Anything that needs the `headscale` CLI (pre-auth key, exporter API key) runs
  as a host oneshot using `infraLib.headscaleRemoteShell`, which SSHes in with
  the host-generated automation key.

| Host file (`/var/lib/microvms/…`) | Made by | Used for |
| --- | --- | --- |
| `headscale/ssh_host_ed25519_key` | headscale-provision-secrets | pinned guest SSH host key |
| `headscale/automation-ssh-key{,.pub}` | headscale-provision-secrets | host → guest automation SSH |
| `headscale/headplane-cookie-secret` | headscale-provision-secrets | exactly 32 chars |
| `headscale/tailscale-authkey` | headscale-mint-tailscale-authkey | shared reusable 10-year pre-auth key, user `homelab` |
| `monitoring/grafana-{admin-password,secret-key}` | monitoring-provision-secrets | Grafana |
| `monitoring/headscale-exporter.env` | monitoring-mint-headscale-apikey | `HEADSCALE_API_KEY=`, 10-year key |
| `gatus/push-token` | gatus-provision-secrets | bearer token for `gatus-push-microvms` |

## Per-component notes

- **tailscale-client:** a oneshot `tailscale up --authkey=file:…`. Guests with
  `tailnet = true` get a stable, non-ephemeral node named after the VM, with
  tailscaled state on a 64 MiB volume. headscale itself is deliberately not a
  tailnet member.
- **crowdsec (host):** a journalctl acquisition on `microvm@caddy.service` plus a
  local `s00-raw` parser `qt1/microvm-console` that strips the journal header and
  serial-console prefix and sets `evt.Parsed.{program,message}` for the hub's
  caddy parser. The bouncer drops on both `INPUT` **and `FORWARD`**, because WAN
  traffic to caddy is forwarded. With nftables it uses its own ruleset hooking
  input+forward. Several upstream-module workarounds are in place:
  `DynamicUser=false`, `StateDirectory`, `restartTriggers` on `localConfig`, an
  `ExecStartPre` that links `/etc/crowdsec/config.yaml` and prunes stale
  localConfig links, bouncer ordering, and a safer register script. There's no
  CAPI or console enrollment.
- **monitoring:** collection happens on the host (node_exporter, Alloy tailing the
  whole journal with a `unit` label, CrowdSec metrics, tailscale-exporter over
  headscale gRPC). The only in-guest collection is the caddies' `:2020` metrics.
  Datasource uids are pinned (`prometheus`, `loki`) and deleted and re-created on
  every start. Dashboards: `headscale/` is vendored from grafana.com 24516 rev 7,
  with only its datasource uid changed, and needs the `cluster`/`namespace`
  scrape labels. `caddy/` and `crowdsec/` are written for this repo against the
  `instance` and `unit` labels. Retention is 30 days (Loki 8G, Prometheus 4G).
- **gatus:** endpoints are derived automatically (headscale `/health` through the
  public caddy, every caddy-internal URL, and each autostarted microVM as an
  *external* endpoint pushed by the host's `gatus-push-microvms` timer with a 5m
  heartbeat). Generated endpoints set `ui.hide-*` because the page is public.
  Push keys must match gatus's `key.sanitize` (`gatusKey`).

## Adding a guest

1. Pick the next free `index` (currently 7).
2. Write `guests/<name>.nix` as `{ args… }: { config, lib, ... }: { … }`: set
   `microvm.{vcpu,mem,volumes}`, open ports with `allowedTCPPortsFrom`, and
   mirror service output to the console if there's no SSH. The tap name
   `vm-<name>` must fit in 15 characters; otherwise override `qt1.guest.tapId`.
3. Write `modules/guests/<name>.nix` using `guestOptions`, `mkGuest`, and
   `provisionSecrets` if needed. For a web UI, register a vhost on caddyInternal
   (tailnet) or caddy (public) and assert that proxy is enabled.
4. Add it to `nixosModules.microvmHost.imports` in `flake.nix` and enable it in
   `checks/test-host.nix`.
5. Update the README (operator docs) and this file.

## Style

- Format with `nixfmt` (`nix fmt`).
- Option `description`s carry the user-facing docs.
- Keep code comments to the non-obvious *why*: upstream quirks, ordering races,
  security scoping. Don't restate what the Nix says, and don't narrate history
  (that belongs in git).
- Use nixpkgs service modules only, with no Docker.
- `system.stateVersion` is `26.05`.
