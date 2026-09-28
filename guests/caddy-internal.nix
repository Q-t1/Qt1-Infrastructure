# caddy-internal: the tailnet-only counterpart of the WAN-facing caddy guest
# (./caddy.nix). One reverse proxy in front of every internal app, each
# served at its own MagicDNS name (<label>.<baseDomain>, e.g.
# grafana.ts.example.com) — the apps themselves never join the tailnet.
#
# Kept apart from ./caddy.nix on purpose: that one is port-forwarded from the
# WAN, this one never is, so no vhost mistake here can publish an internal
# app to the internet, and a compromise of the WAN-facing proxy doesn't hand
# over a tailnet node.
#
# How the names resolve: this guest joins the tailnet as a stable node named
# after the VM (qt1.guest.tailnet in ./base.nix), and headscale serves every <label>.<baseDomain> as an extra
# DNS record pointing at this node's tailnet addresses — kept in sync by
# headscale-magicdns-aliases inside the headscale guest (see
# ./headscale.nix), since those addresses are assigned by headscale at
# registration, not known at build time.
#
# Reachability: caddy listens on port 80, opened only on tailscale0 — not the
# guest bridge, not (transitively) the WAN, since this guest never appears in
# the host's networking.nat.forwardPorts. Requests for anything but a
# declared vhost (this node's own MagicDNS name, its tailnet IP, …) get the
# connection closed. Upstreams are reached over the guest bridge; each app's
# own guest scopes its port to this guest's bridge address.
#
# HTTPS with an internal CA: headscale can't issue publicly-trusted
# certificates for MagicDNS names the way Tailscale's own `tailscale cert`
# does — its /set-dns control endpoint is a NotImplementedHandler (HTTP 501)
# as of 0.29.3, so the ACME DNS-01 challenge a client would drive through it
# can never complete. Caddy's own local CA (`local_certs`) sidesteps that
# entirely: it issues every vhost's certificate itself, offline, with no
# challenge and nothing to resolve publicly.
#
# The trade-off is trust distribution — that CA's root has to be installed on
# each device that browses these names. To make that possible at all, the
# root certificate is served (and only the root: never the keys beside it) at
# http://<this node>.<baseDomain>/root.crt, over plain HTTP, since a client
# that doesn't trust the CA yet can't fetch it over a certificate the CA
# signed. Publishing it is safe: a CA root is a public certificate by
# definition.
#
# Note the tailnet (WireGuard) already encrypts all of this end to end, so
# the certificates buy browser trust — no warnings, working secure-context
# APIs — rather than new confidentiality. The bridge hop from here to each
# app's own guest stays plaintext either way.
#
# Its Prometheus metrics (per-vhost request rates, latency histograms,
# in-flight requests) are served on the guest bridge for the monitoring guest
# only, and only when it asks for them — see the `metrics` argument below and
# qt1.infra.guests.caddyInternal.metricsFromMonitoring.
#
# Built on ./base.nix; called with the vhosts it serves by the host-side
# module, since guests are evaluated by microvm.nix in a nested nixosSystem
# that gets none of the host's specialArgs.
{
  baseDomain,
  virtualHosts,
  # `{ port = <n>; from = "<address>"; }` when the monitoring guest scrapes
  # this one (qt1.infra.guests.caddyInternal.metricsFromMonitoring), `{ }`
  # otherwise: it gates the whole metrics listener below, collection included.
  metrics ? { },
}:

{ config, lib, ... }:

let
  # This guest's own tailnet node name, set by mkGuest (../lib.nix) — the
  # MagicDNS name the root certificate is served at.
  nodeName = config.qt1.guest.name;

  # Where caddy's local CA keeps the root it generates on first use. Beside
  # root.crt live root.key and the intermediate's key, which is why the vhost
  # below routes exactly one path instead of serving this directory.
  localCaDir = "${config.services.caddy.dataDir}/.local/share/caddy/pki/authorities/local";
in
{
  microvm = {
    vcpu = 1;
    mem = 256;
    volumes = [
      {
        # The local CA's root key and certificate, plus every vhost
        # certificate it signs. Without this the root would be regenerated
        # on every guest restart, and each restart would mean re-installing
        # a new root on every device.
        image = "caddy-data.img";
        mountPoint = config.services.caddy.dataDir;
        size = 256;
      }
    ];
  };
  # "vm-caddy-internal" would exceed the 15-character interface name limit.
  qt1.guest.tapId = "vm-caddy-int";

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    80 # the http->https redirects and the root.crt vhost below
    443
  ];

  # The metrics endpoint below is the one thing here reachable over the guest
  # bridge rather than the tailnet — from the monitoring guest's address only,
  # nothing else on the bridge, and never from the WAN (this guest has no
  # forwardPorts entry at all).
  qt1.guest.allowedTCPPortsFrom = lib.optional (metrics != { }) {
    inherit (metrics) port from;
  };

  services.caddy = {
    enable = true;
    # Issue every certificate from caddy's own local CA instead of an ACME
    # provider. Nothing here can reach an ACME challenge — this guest is
    # never port-forwarded from the WAN (no HTTP-01/TLS-ALPN-01) and
    # headscale can't drive DNS-01 for these names (see the header) — so
    # this also guarantees no site ever stalls retrying public issuance.
    #
    # The global `metrics` option beside it is what actually turns HTTP metrics
    # collection on — without it caddy 2.11 leaves them unregistered and the
    # endpoint added further down serves only Go/process metrics. `per_host`
    # adds the vhost as a label, which is the whole point here: one proxy,
    # every internal app behind it. Caddy only labels hosts it has an explicit
    # matcher for and buckets the rest under `_other`, so the label
    # cardinality is bounded by virtualHosts.
    globalConfig = ''
      local_certs
    ''
    + lib.optionalString (metrics != { }) ''
      metrics {
        per_host
      }
    '';
    virtualHosts = lib.mapAttrs' (
      label: upstream:
      lib.nameValuePair "https://${label}.${baseDomain}" {
        # Access log to the journal instead of the module's default
        # per-vhost file (named after the whole site address, scheme
        # included).
        logFormat = "output stdout";
        extraConfig = ''
          reverse_proxy ${upstream}
        '';
      }
    ) virtualHosts;
    # Three things that aren't per-app reverse proxies:
    #
    #  - This node's own MagicDNS name serves the local CA's root
    #    certificate, and nothing else. Plain HTTP on purpose: a device that
    #    hasn't installed the root yet cannot verify a certificate signed by
    #    it, so offering the root over https would be circular. Only
    #    /root.crt is routed into localCaDir — root.key and the
    #    intermediate's key sit in that same directory and must never be
    #    reachable.
    #
    #  - An explicit http->https redirect per app. Caddy normally derives
    #    these from the https:// sites on its own, but declaring the
    #    catch-all below suppresses that (verified against `caddy adapt`:
    #    the :80 server comes out with no redirect routes at all). Without
    #    them, typing a bare hostname reaches the catch-all and the
    #    connection just dies.
    #
    #  - A catch-all for any other Host on port 80 (the tailnet IP, a stale
    #    name, a probe): close the connection without a response. Caddy
    #    matches the more specific site addresses above first. On 443 no
    #    catch-all is needed or possible: an unrecognised SNI has no
    #    certificate, so the handshake simply fails.
    extraConfig = ''
      http://${nodeName}.${baseDomain} {
        handle /root.crt {
          root * ${localCaDir}
          file_server
        }
        handle {
          abort
        }
      }

      ${lib.concatMapStrings (label: ''
        http://${label}.${baseDomain} {
          redir https://{host}{uri} permanent
        }
      '') (lib.attrNames virtualHosts)}

      http:// {
        abort
      }
    ''
    # The metrics endpoint, on a port of its own. Caddy already serves
    # /metrics on its admin API, but that API can also rewrite caddy's whole
    # configuration, so it stays on this guest's loopback where upstream put
    # it: this site exposes the metrics and nothing else. Plain http:// with
    # an explicit port, so neither automatic HTTPS (no certificate for a
    # bridge address) nor the catch-all above (it only listens on :80)
    # applies to it. The bridge address here is a Host matcher rather than a
    # bind address — caddy listens on :<port> on every interface, tailscale0
    # included — so it is the firewall rule above, not this line, that keeps
    # the endpoint to its one caller.
    + lib.optionalString (metrics != { }) ''
      http://${config.qt1.guest.address}:${toString metrics.port} {
        metrics
      }
    '';
  };
}
