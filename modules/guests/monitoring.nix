# Host side of the monitoring guest: the VM entry, its two host-generated
# Grafana secrets, Grafana's vhost on caddy-internal, and the host-side
# collection that actually feeds it
# (node_exporter for metrics, Grafana Alloy for logs) — the guest itself only
# holds the storage/UI (Loki, Prometheus, Grafana). See ../../guests/monitoring.nix
# for the guest's own configuration and the reasoning behind bundling all
# three into one guest.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  infraLib = import ../../lib.nix { inherit lib; };
  host = config.qt1.infra.microvmHost;
  headscale = config.qt1.infra.guests.headscale;
  caddyInternal = config.qt1.infra.guests.caddyInternal;
  cfg = config.qt1.infra.guests.monitoring;

  nodeExporterPort = 9100;
  # Must match guests/monitoring.nix.
  grafanaPort = 3000;
in
{
  options.qt1.infra.guests.monitoring =
    infraLib.guestOptions {
      index = 4;
      description = "the monitoring microVM (Loki + Prometheus + Grafana, reachable only over the tailnet, through caddy-internal)";
    }
    // {
      grafanaLabel = lib.mkOption {
        type = lib.types.str;
        default = "grafana";
        description = ''
          Grafana's vhost on caddy-internal, i.e. the first label of its
          MagicDNS alias: `<grafanaLabel>.<baseDomain>`.
        '';
      };

      grafanaUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://${cfg.grafanaLabel}.${headscale.baseDomain}/";
        readOnly = true;
        description = ''
          The one URL Grafana answers at, over the tailnet only: its MagicDNS
          alias (qt1.infra.guests.headscale.baseDomain), served by
          caddy-internal. See guests/monitoring.nix.
        '';
      };

      adminPasswordFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/microvms/monitoring/grafana-admin-password";
        description = ''
          Host path holding Grafana's initial admin password, generated on the
          host the first time this path doesn't exist (see
          monitoring-provision-secrets, see ../../lib.nix). Read by qemu, which runs as the
          `microvm` user, and passed into the guest as a systemd credential so
          it never lands in the Nix store.
        '';
      };

      secretKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/microvms/monitoring/grafana-secret-key";
        description = ''
          Host path holding Grafana's secret_key (used to sign/encrypt
          datasource secrets in its own database) — required by the upstream
          module with no default, generated the same way as adminPasswordFile.
        '';
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (infraLib.mkGuest config {
        name = "monitoring";
        inherit cfg;
        module = import ../../guests/monitoring.nix {
          grafanaHostname = "${cfg.grafanaLabel}.${headscale.baseDomain}";
          proxyAddress = caddyInternal.address;
        };
        credentialFiles = {
          grafana-admin-password = cfg.adminPasswordFile;
          grafana-secret-key = cfg.secretKeyFile;
        };
      })

      (infraLib.provisionSecrets {
        vm = "monitoring";
        description = "Generate the monitoring guest's Grafana admin password and secret key";
        path = [
          pkgs.openssl
          pkgs.coreutils
        ];
        secrets = lib.genAttrs [ cfg.adminPasswordFile cfg.secretKeyFile ] (_: ''
          openssl rand -hex 32 > "$f"
        '');
      })

      {
        assertions = [
          {
            assertion = caddyInternal.enable;
            message = "qt1.infra.guests.monitoring requires qt1.infra.guests.caddyInternal.enable — the tailnet-only proxy is Grafana's only way in.";
          }
        ];

        qt1.infra.guests.caddyInternal.virtualHosts.${cfg.grafanaLabel} =
          "${cfg.address}:${toString grafanaPort}";

        # Host-side metrics collection: a plain node_exporter, bridge-bound only
        # (never the uplink/WAN interface), scraped by Prometheus inside the
        # monitoring guest.
        services.prometheus.exporters.node = {
          enable = true;
          listenAddress = host.hostAddress;
          port = nodeExporterPort;
        };
        networking.firewall.interfaces.${host.bridge}.allowedTCPPorts = [ nodeExporterPort ];

        # Host-side log collection: Grafana Alloy (services.promtail was removed
        # upstream — EOL — this is its nixpkgs-blessed replacement) tails the
        # whole host journal and pushes it to the monitoring guest's Loki. This
        # is the same host journal crowdsec.nix already reads from (caddy's
        # access log and crowdsec's own logs both land there); headscale's own
        # application logs don't, since it never mirrors its console to the host
        # journal the way caddy does — out of scope for this pass.
        services.alloy.enable = true;
        environment.etc."alloy/config.alloy".text = ''
          loki.source.journal "host" {
            labels     = { job = "host" }
            forward_to = [loki.write.monitoring.receiver]
          }

          loki.write "monitoring" {
            endpoint {
              url = "http://${cfg.address}:3100/loki/api/v1/push"
            }
          }
        '';
      }
    ]
  );
}
