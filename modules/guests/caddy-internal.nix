# Host side of the caddy-internal guest: the VM entry, the vhosts it serves,
# and the MagicDNS alias records headscale publishes for them. See
# ../../guests/caddy-internal.nix for the guest's own configuration.
{ config, lib, ... }:

let
  infraLib = import ../../lib.nix { inherit lib; };
  headscale = config.qt1.infra.guests.headscale;
  monitoring = config.qt1.infra.guests.monitoring;
  cfg = config.qt1.infra.guests.caddyInternal;

  # VM name, and so its tailnet node name (qt1.guest.tailnet in
  # guests/base.nix): what every alias record points at.
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
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          grafana = "10.100.0.4:3000";
        };
        description = ''
          Internal apps to serve, as `label = "upstream-host:port"`. Each is
          reachable over the tailnet only, at `https://<label>.<baseDomain>/`
          (qt1.infra.guests.headscale.baseDomain), behind a certificate from
          caddy's own local CA — whose root must be installed on each client
          device, see ../../guests/caddy-internal.nix. Guests set their own
          entry here (see modules/guests/monitoring.nix), and open their port
          to this guest's `address` only.
        '';
      };

      urls = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = lib.mapAttrs (label: _: "https://${label}.${headscale.baseDomain}/") cfg.virtualHosts;
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
          # A plain conditional, not lib.mkIf: this is a function argument to
          # the guest module, not an option definition — an mkIf here would
          # arrive as an attrset the guest cannot read.
          metrics = lib.optionalAttrs cfg.metricsFromMonitoring {
            port = cfg.metricsPort;
            from = monitoring.address;
          };
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
