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
lib.nix                          helpers for the host-side guest modules
modules/microvm-host.nix         guest bridge + NAT           (qt1.infra.microvmHost)
modules/tailscale-client.nix     join the tailnet             (qt1.infra.tailscaleClient)
guests/base.nix                  what every guest shares      (qt1.guest)
modules/guests/headscale.nix     host-side VM declaration     (qt1.infra.guests.headscale)
guests/headscale.nix             the guest's own NixOS config
modules/guests/caddy.nix         host-side VM declaration     (qt1.infra.guests.caddy)
guests/caddy.nix                 the guest's own NixOS config
modules/guests/caddy-internal.nix host-side VM declaration    (qt1.infra.guests.caddyInternal)
guests/caddy-internal.nix        the guest's own NixOS config
modules/crowdsec.nix             host-side CrowdSec + bouncer (qt1.infra.crowdsec)
modules/guests/monitoring.nix    host-side VM + collection    (qt1.infra.guests.monitoring)
guests/monitoring.nix            the guest's own NixOS config
guests/dashboards/               Grafana dashboards, provisioned per topic
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
  crowdsec.enable = true;   # optional: bans offenders against caddy's logs
  guests.caddyInternal.enable = true;   # optional: tailnet-only proxy for internal apps
  guests.monitoring.enable = true;   # optional: Loki+Prometheus+Grafana, behind caddyInternal
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
headscale coordinates, via `qt1.infra.tailscaleClient`. **On the host running
the headscale/caddy guests, enabling it is all it takes:**

```nix
qt1.infra.tailscaleClient.enable = true;
```

Its settings default to those guests' own values:

- `loginServerUrl`: headscale's `serverUrl`.
- `authKeyFile`: the shared pre-auth key (see below).
- `loginServerAddress`: the **caddy** guest's bridge address. `serverUrl`'s
  hostname is resolved to it via `networking.hosts`, so the host reaches
  headscale straight over the bridge instead of out through the WAN and back
  in via the router's port forward (NAT hairpinning, which not every router
  supports reliably). The TLS handshake still validates, since caddy's
  certificate is for the hostname, not the IP.

A guest joins with `tailnet = true` in its `mkGuest` call (see "Adding a
guest"), which sets all of the above inside the guest. It also gives the
guest a stable node: named after the VM, not ephemeral, with tailscaled's
state on a persistent volume. A genuinely external Tailscale client (a
phone, a laptop away from home) has no bridge to shortcut through and just
uses `serverUrl` over the WAN.

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

## Protecting caddy (`qt1.infra.crowdsec`)

Optional, off by default. When enabled, [CrowdSec](https://www.crowdsec.net)
runs on the **host** (not its own guest — see the reasoning in
`modules/crowdsec.nix`) and watches the caddy guest's access log for the
scenarios in the `crowdsecurity/caddy` hub collection (bruteforce, scanners,
common HTTP attacks). An offending IP gets banned by the local firewall
bouncer, which drops it at the host before it ever reaches caddy:

```nix
qt1.infra.crowdsec.enable = true;
```

Three things this depends on that are easy to get wrong by hand — all three
were silently wrong here until the CrowdSec dashboard showed 0 parsed events —
so they're built in rather than left as setup steps:

- **Caddy needs an access log, on stdout, at INFO** — caddy logs no requests
  at all by default, and the two obvious ways to turn it on both produce
  nothing readable here. `guests/caddy.nix` sets the vhost's own
  `logFormat = "output stdout"`: the guest mirrors stdout to its console and
  the host's journal, which is the only way anything leaves that guest and
  the only thing CrowdSec reads. A bare `log` directive instead points the
  access log at caddy's *default* logger, which `services.caddy` pins at
  level `ERROR` — access entries are INFO, so caddy silently logs nothing —
  and the nixpkgs module's own default writes them to a file under
  `/var/log/caddy` inside the guest's tmpfs root, where nothing can read them
  and they grow in RAM. Both were live here until the caddy/crowdsec
  dashboards made the silence visible.
- **Something has to feed the hub's caddy parser.** The `crowdsecurity/caddy`
  collection installs a parser for `s01-parse` and an enricher for
  `s02-enrich` and *nothing* for `s00-raw` — yet its parser filters on
  `evt.Parsed.program` and reads `evt.Parsed.message`, fields that only exist
  once an `s00-raw` parser has set them (normally `crowdsecurity/non-syslog`,
  which ships inside a collection this one does not depend on). On top of that
  every line arrives wrapped in the guest's console format,
  `[   12.345678] caddy[480]: {...}`, which is no longer JSON.
  `modules/crowdsec.nix` therefore ships one local parser
  (`qt1/microvm-console`, via `localConfig.parsers.s00Raw`) that strips the
  prefix — optionally, so a bare line works too — and sets those two fields.
  Check it with `sudo cscli explain --log '<a line from journalctl -u
  microvm@caddy>' --type caddy`: the chain should reach `s02-enrich` and then
  list scenarios.
- **The ban has to land on `FORWARD`, not just `INPUT`.** The WAN traffic
  this protects is never delivered to the host itself — it's `FORWARD`ed
  on to the caddy guest by `qt1.infra.microvmHost`'s NAT
  (`networking.nat.forwardPorts`). A bouncer ruleset that only touches
  `INPUT` (the common default elsewhere) would silently ban IPs that keep
  right on reaching caddy. This module puts the drop rule on both chains
  (iptables) or hooks both `input` and `forward` itself (nftables, if
  `networking.nftables.enable`).

`collections` (default `[ "crowdsecurity/caddy" ]`) is the main knob this
module exposes — add to it only alongside a matching acquisition of your
own (`services.crowdsec.localConfig.acquisitions`), since a collection with
nothing feeding it never sees an event. The other one is
`metricsFromGuests`, which moves CrowdSec's own (already enabled) Prometheus
endpoint off loopback and onto the guest bridge so the monitoring guest can
scrape it; the monitoring guest sets it for you (see `crowdsecMetrics`
below), and there is no reason to set it by hand. Everything else — the local API,
registering the bouncer, minting its API key — is unattended, the same
pattern as headscale's own secrets above: `cscli bouncers add` runs
automatically the first time, idempotent after that.

**Migrating a host that ran CrowdSec before this module turned off
`DynamicUser`** (see the comment in `modules/crowdsec.nix`). Its state still
sits in `/var/lib/private/`, partly owned by `nobody`. Move it back and chown
it once, *before* switching to the new configuration, with both units stopped:

```sh
sudo systemctl stop crowdsec-firewall-bouncer.service crowdsec.service
for d in crowdsec crowdsec-firewall-bouncer-register; do
  sudo rm /var/lib/$d                      # the symlink into private/
  sudo mv /var/lib/private/$d /var/lib/$d
  sudo chown -R crowdsec:crowdsec /var/lib/$d
done
sudo nixos-rebuild switch --flake .#<host>
```

The ban list (`crowdsec.db`), the machine credentials and the bouncer's API
key all come along, so nothing is re-registered. The bouncer stops enforcing
bans between the `stop` and the switch.

No CrowdSec Console enrollment or central API (CAPI) registration here —
this is a purely local deployment (local detection, local ban list, no
account, no shared community blocklist). Wiring that in is a matter of
setting `services.crowdsec.settings.capi.credentialsFile` yourself; it's
left out here deliberately, since the upstream module's auto-registration
script has a rough edge that can fail a restart after the first run.

## caddy-internal guest (`qt1.infra.guests.caddyInternal`)

Optional, off by default. The tailnet-only counterpart of the caddy guest
above: one [Caddy](https://caddyserver.com) reverse proxy (`10.100.0.5`) in
front of every *internal* app, each served at its own MagicDNS name,
`https://<label>.<baseDomain>/`:

```nix
qt1.infra.guests.caddyInternal = {
  enable = true;
  # Guests register their own entry (monitoring adds `grafana`); add others
  # by hand as `label = "upstream-host:port"`.
  virtualHosts.myapp = "10.100.0.9:8080";
};
# -> https://myapp.<baseDomain>/, listed in qt1.infra.guests.caddyInternal.urls
```

Requires `guests.headscale` and `guests.caddy` (for the same NAT-hairpin
shortcut described in "Joining the tailnet").

It is kept separate from the WAN-facing caddy on purpose. That one is
port-forwarded from the internet; this one never is. So no vhost mistake
here can publish an internal app, and a compromise of the public proxy
doesn't hand over a tailnet node.

How it fits together:

- **This guest is the tailnet node, the apps aren't.** It joins the tailnet
  as node `caddy-internal` (`tailnet = true`, see "Joining the tailnet"),
  with its tailscaled state on a small persistent volume
  (`/var/lib/tailscale`) and not ephemeral. A restart therefore keeps the
  same node and the same tailnet addresses.
- **Names**: for each vhost, headscale serves `<label>.<baseDomain>` as an
  extra DNS record (A + AAAA) pointing at that node's tailnet addresses —
  `qt1.infra.guests.headscale.magicDnsAliases`, which this module fills in.
  Node addresses are assigned by headscale at registration, so they can't be
  written at build time: `headscale-magicdns-aliases`, a one-minute timer
  inside the headscale guest, looks them up with `headscale nodes list` and
  rewrites `/var/lib/headscale/extra-records.json` (`dns.extra_records_path`)
  when they change; headscale reloads that file by itself.
- **Reachability**: Caddy listens on 443 and 80, opened only on this guest's
  `tailscale0`. It proxies only the declared hostnames; port 80 redirects
  each of them to https and closes the connection for any other `Host` (the
  node's tailnet IP, a stale name, …). Upstreams are reached over the
  bridge, and each app's guest opens its port to this guest's bridge address
  only.
- **HTTPS from a local CA**: headscale cannot issue publicly-trusted
  certificates for MagicDNS names — there's no `tailscale cert` equivalent,
  because its `/set-dns` control endpoint is a `NotImplementedHandler`
  (HTTP 501) as of 0.29.3, so the ACME DNS-01 challenge that would drive can
  never complete. Caddy's own local CA (`local_certs`) issues every vhost
  certificate itself instead: offline, no challenge, nothing to resolve
  publicly.

  The cost is trust distribution — see "Trusting the local CA" below. Note
  WireGuard already encrypts all of this end to end, so the certificates buy
  browser trust (no warnings, working secure-context APIs) rather than new
  confidentiality, and the bridge hop to each app stays plaintext either
  way.

### Trusting the local CA

The CA's root certificate is served by the proxy itself, at
`qt1.infra.guests.caddyInternal.rootCertUrl`:

```
http://caddy-internal.<baseDomain>/root.crt
```

Plain HTTP on purpose: a device that hasn't installed the root yet can't
verify a certificate signed by it, so serving the root over one would be
circular. A CA root is a public certificate, so publishing it is safe — and
only that one path is routed, never the private keys sitting beside it.

Install it once per device that browses these names, otherwise every URL
gives an untrusted-certificate warning:

- **Linux**: add to `security.pki.certificateFiles` (NixOS), or drop into
  `/usr/local/share/ca-certificates/` and run `update-ca-certificates`.
- **macOS**: `sudo security add-trusted-cert -d -r trustRoot -k \
  /Library/Keychains/System.keychain root.crt`.
- **iOS**: open the URL in Safari to install the profile, then *also* enable
  it under Settings → General → About → Certificate Trust Settings. The
  second step is separate and easy to miss — without it the certificate is
  installed but not trusted.
- **Firefox** keeps its own trust store, so add it there too regardless of
  the OS.

The root lives on the guest's `/var/lib/caddy` volume, so it survives
restarts and this is a one-time step per device. Deleting that volume means
a new root and re-installing everywhere.

Clients need MagicDNS on to resolve the names (the default: `tailscale up`
accepts the tailnet's DNS unless `--accept-dns=false`). The node must
register as exactly `caddy-internal`: if headscale already knows a node by
that name, the new one gets a suffixed name and the aliases resolve to
nothing. Check and fix it on the headscale guest:

```
headscale nodes list
headscale nodes rename -i <id> caddy-internal   # after deleting the stale one
```

## monitoring guest (`qt1.infra.guests.monitoring`)

Optional, off by default. Bundles [Loki](https://grafana.com/oss/loki/),
[Prometheus](https://prometheus.io) and [Grafana](https://grafana.com) into
one guest (`10.100.0.4`) — all three from nixpkgs' own modules, no Docker —
since none of them is independently useful here; they exist purely to back
this one Grafana instance:

```nix
qt1.infra.guests.monitoring.enable = true;
```

Requires `guests.caddyInternal`, its only way in (see below).
**Collection happens outside this guest**, mostly on the host alongside
`qt1.infra.crowdsec` — the guest itself only stores and draws:

- **Metrics**: a plain `node_exporter` on the host, bridge-bound only
  (`10.100.0.1:9100`, never the WAN-facing uplink), scraped by Prometheus
  inside the guest. Whole-box resource metrics, which covers every guest from
  the outside; the only per-guest internals collected are the two caddies'
  HTTP metrics below, and the `headscale` guest runs no exporter of its own.
- **Logs**: [Grafana Alloy](https://grafana.com/docs/alloy/) on the host
  tails the whole host journal and pushes it to this guest's Loki, keeping
  each entry's systemd unit as a `unit` label (so a query can ask for one
  service's lines instead of the whole box).
  `services.promtail` was removed upstream (end of life) — Alloy is its
  nixpkgs-blessed replacement. This is the same host journal
  `qt1.infra.crowdsec` already reads from: caddy's access log and
  crowdsec's own logs both land there and ship to Loki too. headscale's own
  application logs don't (it never mirrors its console to the host journal
  the way caddy does) — out of scope for now.
- **caddy's HTTP metrics** (`caddyMetrics`, on by default): request rate and
  latency per vhost, status code and method, in-flight requests, and each
  proxy's own memory/CPU/goroutines, from both caddy guests — with the
  "Caddy / Overview" dashboard (`guests/dashboards/caddy/`) over them. This
  is the one thing collected from *inside* a guest: no host-side exporter
  can see the requests a proxy inside a VM handled. Each caddy turns on
  caddy's global `metrics` option (HTTP metrics are off until something
  does) and serves `/metrics` on its bridge address, on port 2020, opened to
  the monitoring guest's address alone — not caddy's admin API, which can
  rewrite caddy's whole config and stays on the guest's loopback. Set
  `caddyMetrics = false` to collect none of it.
- **CrowdSec's metrics** (`crowdsecMetrics`, on by default whenever
  `qt1.infra.crowdsec` is enabled): active decisions (bans) by scenario and
  origin, alerts, bucket overflows, what the parsers accept and reject, and
  the local API's own traffic per bouncer — with the "CrowdSec / Overview"
  dashboard (`guests/dashboards/crowdsec/`) over them. CrowdSec already
  exposes all of this on `127.0.0.1:6060`; the only thing this turns on is
  serving it where the monitoring guest can reach it
  (`qt1.infra.crowdsec.metricsFromGuests`, set for you), with port 6060
  opened on the bridge interface alone — the endpoint has no authentication
  of its own, and the host's firewall default-drops it everywhere else.
- **headscale's tailnet inventory** (`headscaleMetrics`, on by default
  whenever `guests.headscale` is enabled): nodes and whether they're online,
  users, pre-auth keys, API keys, advertised vs. approved routes, and every
  expiry timestamp among them. headscale's own `/metrics` carries none of
  that — it only counts map responses — so this comes from
  [`prometheus-tailscale-exporter`](https://github.com/adinhodovic/tailscale-exporter)
  on the host (`10.100.0.1:9250`), which reads it over headscale's gRPC admin
  API. Wiring it up costs three things, all automatic:
  - headscale serves its gRPC API on the bridge
    (`guests.headscale.grpcFromHost`), plaintext and source-restricted to the
    host's address — it holds no certificate of its own, caddy terminates TLS
    in front of it, and the listener is one bridge hop away from its only
    caller. With the option off, that API stays on headscale's local unix
    socket, which is all the `headscale` CLI needs.
  - an API key is minted on first boot by
    `monitoring-mint-headscale-apikey`, the same SSH-into-the-guest pattern
    as headscale's own pre-auth key, and written to
    `/var/lib/microvms/monitoring/headscale-exporter.env` (10-year expiry;
    delete the file and restart the unit to rotate).
  - Grafana provisions
    [dashboard 24516, "Headscale / Overview"](https://grafana.com/grafana/dashboards/24516-headscale-overview/)
    (revision 7, vendored in `guests/dashboards/headscale/`) to read it.
    Provisioned dashboards are read-only in the UI — "Save as" a copy to
    change one. The dashboard comes from a Kubernetes-shaped mixin and
    matches every query on `cluster`/`namespace`, so the scrape job attaches
    both as static labels; without them every panel reads "No data".

  Set `qt1.infra.guests.monitoring.headscaleMetrics = false` to skip all
  three, including the gRPC listener.

Dashboards live in `guests/dashboards/<topic>/` and are provisioned per
topic, so each one appears only when whatever feeds it is actually being
collected. The headscale one is vendored from grafana.com; the caddy and
crowdsec ones are written for this repo, against the labels the scrape jobs
attach (`instance` is the guest's name) and the `unit` label on journal logs
— each ends in a log panel reading the matching service's lines out of Loki,
so a spike in the graphs and the lines behind it are on the same page.
Provisioned dashboards are read-only in the UI: "Save as" a copy to change
one.

Both Loki and Prometheus default to 30 days' retention, sized against the
guest's own volumes (`/var/lib/loki` 8G, `/var/lib/prometheus2` 4G).

**Reachable only over the tailnet, at its MagicDNS alias only — this is the
actual point of the guest.** Grafana is served at exactly one URL,
`https://grafana.<baseDomain>/` (label: `grafanaLabel`; also exposed
read-only as `qt1.infra.guests.monitoring.grafanaUrl`), through the
caddy-internal guest above. This guest registers that vhost there itself and
never joins the tailnet. Four things enforce it, stacked:

1. Like every other guest here, it never appears in the host's
   `networking.nat.forwardPorts`, so it can't be reached from the WAN at all.
2. Grafana's port (3000) is opened on the bridge for caddy-internal's
   address only (the same `iptables`-source-IP trick the headscale guest
   uses to scope its SSH). The host and the other guests can't reach it.
3. caddy-internal itself is reachable only from tailnet peers, and only
   proxies requests for `grafana.<baseDomain>`. Grafana's own
   `enforce_domain` redirects any other `Host` back to that name.
4. Loki's push port (3100) is opened on the bridge, but source-restricted to
   the host's own address only — nothing else on the bridge can reach it
   either.

Grafana's initial admin password is host-generated, unattended, the same
pattern as every other secret in this repo:

```
sudo cat /var/lib/microvms/monitoring/grafana-admin-password
```

**Nothing here survives a from-scratch reinstall of the host** — same
caveat as the headscale/caddy guests: `/var/lib/loki`, `/var/lib/prometheus2`
and `/var/lib/grafana` are plain root-fs volume images, not backed by
anything else. Back them up before reinstalling if the history matters to
you, or accept starting fresh.

## Adding a guest

Every guest is built from the same pieces, so a new one is mostly its own
service config:

1. `guests/<name>.nix` — the guest's own NixOS module, a function of only
   what's specific to it (see `guests/caddy-internal.nix`). The common base
   (`guests/base.nix`) is imported for it: qemu microVM, tap interface
   `vm-<name>`, static address on the bridge via networkd, fw_cfg
   credentials, public resolvers, `system.stateVersion`. Its network
   coordinates are under `config.qt1.guest`, and
   `qt1.guest.allowedTCPPortsFrom = [ { port; from; } ]` opens a port to a
   single bridge address. microvm.nix evaluates guests in a nested
   `nixosSystem` that receives none of the host's specialArgs, so anything
   else it needs is passed in explicitly.
2. `modules/guests/<name>.nix` — the host side, using `lib.nix`:
   - `options.qt1.infra.guests.<name> = infraLib.guestOptions { index; description; } // { … }`
     gives `enable`, plus `address` (`10.100.0.<index>`) and `mac`.
   - `infraLib.mkGuest config { name; cfg; module; credentialFiles; tailnet; }`
     declares `microvm.vms.<name>` with the base module and the host
     assertions. `tailnet = true` joins the tailnet (see "Joining the
     tailnet").
   - `infraLib.provisionSecrets { vm; description; path; secrets; }` creates
     host-generated secrets before the VM starts.
   - A web UI goes on caddy-internal: `qt1.infra.guests.caddyInternal.virtualHosts.<label> = "<address>:<port>"`.
3. Add it to `nixosModules.microvmHost`'s imports in `flake.nix` and enable
   it in `checks/test-host.nix`.
