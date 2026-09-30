{
  config,
  lib,
  ...
}:

let
  infraLib = import ../../lib.nix { inherit lib; };
  headscale = config.qt1.infra.guests.headscale;
  monitoring = config.qt1.infra.guests.monitoring;
  cfg = config.qt1.infra.guests.caddy;
in
{
  options.qt1.infra.guests.caddy =
    infraLib.guestOptions {
      index = 3;
      description = "the caddy microVM (TLS-terminating reverse proxy in front of headscale)";
    }
    // {
      letsEncryptEmail = lib.mkOption {
        type = lib.types.str;
        example = "you@example.com";
        description = ''
          Contact address for Let's Encrypt certificate issuance. This is
          caddy's own ACME client now — headscale no longer requests a
          certificate of its own, see qt1.infra.guests.headscale.serverUrl.
        '';
      };

      virtualHosts = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          "status.example.com" = "10.100.0.6:8080";
        };
        description = ''
          Public sites to serve besides headscale's, as
          `hostname = "upstream-host:port"`. Each is reachable from the
          internet, with a Let's Encrypt certificate of its own, and needs a
          DNS record pointing at this host's WAN address. Guests set their
          own entry here (see modules/guests/gatus.nix), and open their port
          to this guest's `address` only.

          Anything added here is published to the internet — an internal app
          belongs on qt1.infra.guests.caddyInternal instead.
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
        name = "caddy";
        inherit cfg;
        module = import ../../guests/caddy.nix {
          inherit (cfg) letsEncryptEmail virtualHosts;
          hostname = headscale.tlsHostname;
          upstream = "${headscale.address}:${toString headscale.internalPort}";
          metrics = lib.optionalAttrs cfg.metricsFromMonitoring {
            port = cfg.metricsPort;
            from = monitoring.address;
          };
        };
      })

      {
        assertions = [
          {
            assertion = headscale.enable;
            message = "qt1.infra.guests.caddy requires qt1.infra.guests.headscale.enable — it exists to front it.";
          }
          {
            assertion = !(cfg.virtualHosts ? ${headscale.tlsHostname});
            message = "qt1.infra.guests.caddy.virtualHosts must not contain `${headscale.tlsHostname}` — that hostname is headscale's own.";
          }
        ];

        qt1.infra.tailscaleClient.loginServerAddress = lib.mkDefault cfg.address;

        networking.nat.forwardPorts = [
          {
            sourcePort = 80;
            destination = "${cfg.address}:80";
            proto = "tcp";
          }
          {
            sourcePort = 443;
            destination = "${cfg.address}:443";
            proto = "tcp";
          }
        ];
      }
    ]
  );
}
