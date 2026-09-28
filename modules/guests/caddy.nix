# Host side of the caddy guest: the VM entry and the WAN port forwarding
# that makes it reachable — caddy is now what needs real inbound ports,
# not headscale (see ../../guests/caddy.nix and modules/guests/headscale.nix).
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
          inherit (cfg) letsEncryptEmail;
          hostname = headscale.tlsHostname;
          upstream = "${headscale.address}:${toString headscale.internalPort}";
          # A plain conditional, not lib.mkIf: this is a function argument to
          # the guest module, not an option definition — an mkIf here would
          # arrive as an attrset the guest cannot read.
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
        ];

        # The host's own tailnet join reaches headscale through this guest
        # over the bridge (see the README's "Joining the tailnet").
        qt1.infra.tailscaleClient.loginServerAddress = lib.mkDefault cfg.address;

        # Real inbound ports: caddy is now the WAN-facing TLS terminator,
        # headscale itself no longer needs any (see
        # modules/guests/headscale.nix).
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
