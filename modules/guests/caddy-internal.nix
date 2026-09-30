{ config, lib, ... }:

let
  infraLib = import ../../lib.nix { inherit lib; };
  headscale = config.qt1.infra.guests.headscale;
  monitoring = config.qt1.infra.guests.monitoring;
  gatus = config.qt1.infra.guests.gatus;
  cfg = config.qt1.infra.guests.caddyInternal;

  name = "caddy-internal";
in
{
  options.qt1.infra.guests.caddyInternal =
    infraLib.guestOptions {
      index = 5;
      description = "the tailnet-only reverse proxy for internal apps (caddy-internal microVM)";
    }
    // {
      virtualHosts = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.coercedTo lib.types.str (upstream: { inherit upstream; }) (
            lib.types.submodule {
              options = {
                upstream = lib.mkOption {
                  type = lib.types.str;
                  description = "Where the app listens, as `host:port`.";
                };
                path = lib.mkOption {
                  type = lib.types.str;
                  default = "/";
                  example = "/admin/";
                  description = ''
                    The path the app lives under, for an app that serves
                    nothing at `/` (Headplane only answers under /admin).
                    Requests for `/` itself are redirected here, so the bare
                    hostname works instead of showing the app's empty 404.
                  '';
                };
              };
            }
          )
        );
        default = { };
        example = {
          grafana = "10.100.0.4:3000";
          headplane = {
            upstream = "10.100.0.2:3000";
            path = "/admin/";
          };
        };
        description = ''
          Internal apps to serve, as `label = "upstream-host:port"`, or
          `label = { upstream; path; }` for an app that lives under a
          subpath. Each is reachable over the tailnet only, at
          `https://<label>.<baseDomain>/`
          (qt1.infra.guests.headscale.baseDomain), behind a certificate from
          caddy's own local CA — whose root must be installed on each client
          device, see ../../guests/caddy-internal.nix. Guests set their own
          entry here (see modules/guests/monitoring.nix), and open their port
          to this guest's `address` only.
        '';
      };

      urls = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = lib.mapAttrs (
          label: vhost: "https://${label}.${headscale.baseDomain}${vhost.path}"
        ) cfg.virtualHosts;
        readOnly = true;
        description = "The URL each virtualHosts entry is served at.";
      };

      rootCertUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://${name}.${headscale.baseDomain}/root.crt";
        readOnly = true;
        description = ''
          Where this proxy serves its local CA's root certificate. Install it
          on every device that browses the URLs above, or they get an
          untrusted-certificate warning. Plain HTTP by design — see
          ../../guests/caddy-internal.nix.
        '';
      };

      probesFromGatus = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Open this proxy's HTTPS port on the guest bridge to the gatus
          guest's address, so the status page can check every vhost the way
          a tailnet client reaches it. Only that one address: the rest of the
          bridge and the WAN still can't reach it.

          Turned on by qt1.infra.guests.gatus.
        '';
      };

      metricsFromMonitoring = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Serve this caddy's Prometheus metrics — request rates and latency
          histograms per vhost and status code, in-flight requests, its own
          Go/process counters — on the guest bridge, for the monitoring guest
          only. Off by default: with it off caddy collects no HTTP metrics at
          all and opens no extra listener.

          Turned on by qt1.infra.guests.monitoring (see its caddyMetrics
          option), which is also what scrapes the endpoint. It carries no
          authentication of its own, so it is opened to that one guest's
          address only, never to the rest of the bridge and never to the WAN.
        '';
      };

      metricsPort = lib.mkOption {
        type = lib.types.port;
        default = 2020;
        readOnly = true;
        description = ''
          Port the metrics endpoint listens on when metricsFromMonitoring is
          set, on this guest's bridge address only. Deliberately not 2019:
          that is caddy's admin API, which can rewrite caddy's whole
          configuration and stays on the guest's loopback.
        '';
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (infraLib.mkGuest config {
        inherit name cfg;
        module = import ../../guests/caddy-internal.nix {
          inherit (cfg) virtualHosts;
          inherit (headscale) baseDomain;
          metrics = lib.optionalAttrs cfg.metricsFromMonitoring {
            port = cfg.metricsPort;
            from = monitoring.address;
          };
          probeFrom = if cfg.probesFromGatus then gatus.address else null;
        };
        tailnet = true;
      })

      {
        assertions = [
          {
            assertion = !(cfg.virtualHosts ? ${name});
            message = "qt1.infra.guests.caddyInternal.virtualHosts must not contain `${name}` — that name is already the proxy node's own MagicDNS record, serving the local CA's root certificate.";
          }
        ];

        qt1.infra.guests.headscale.magicDnsAliases = lib.mapAttrs' (
          label: _: lib.nameValuePair "${label}.${headscale.baseDomain}" name
        ) cfg.virtualHosts;
      }
    ]
  );
}
