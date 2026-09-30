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
  caddy = config.qt1.infra.guests.caddy;
  caddyInternal = config.qt1.infra.guests.caddyInternal;
  crowdsec = config.qt1.infra.crowdsec;
  cfg = config.qt1.infra.guests.monitoring;

  caddyExporters =
    lib.optional (cfg.caddyMetrics && caddy.enable) {
      instance = "caddy";
      target = "${caddy.address}:${toString caddy.metricsPort}";
    }
    ++ lib.optional (cfg.caddyMetrics && caddyInternal.enable) {
      instance = "caddy-internal";
      target = "${caddyInternal.address}:${toString caddyInternal.metricsPort}";
    };

  nodeExporterPort = 9100;
  headscaleExporterPort = 9250;
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
        default = "https://${cfg.grafanaLabel}.${headscale.baseDomain}/";
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

      headscaleMetrics = lib.mkOption {
        type = lib.types.bool;
        default = headscale.enable;
        defaultText = lib.literalExpression "config.qt1.infra.guests.headscale.enable";
        description = ''
          Collect headscale's tailnet inventory — nodes, users, pre-auth
          keys, API keys and their expiries — into Prometheus, and provision
          the "Headscale / Overview" dashboard that reads it.

          headscale's own /metrics endpoint carries none of this (it only
          counts map responses), so the numbers come from
          prometheus-tailscale-exporter, which reads them over headscale's
          gRPC admin API. That costs three things, all automatic: the gRPC
          API gets served on the bridge for the host only
          (qt1.infra.guests.headscale.grpcFromHost), an API key is minted on
          first boot (monitoring-mint-headscale-apikey, see
          headscaleApiKeyFile), and the exporter runs on the host next to
          node_exporter.
        '';
      };

      caddyMetrics = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Collect both caddy guests' own HTTP metrics — request rate and
          latency per vhost and status code, in-flight requests, TLS/process
          counters — into Prometheus, and provision the "Caddy / Overview"
          dashboard that reads them.

          This is the one thing collected from inside the guests rather than
          on the host: each caddy serves the endpoint on its bridge address,
          for this guest's address only
          (qt1.infra.guests.caddy.metricsFromMonitoring and its
          caddyInternal counterpart, which this option sets). Whichever of
          the two guests is enabled is scraped; with the option off neither
          caddy collects HTTP metrics at all.
        '';
      };

      crowdsecMetrics = lib.mkOption {
        type = lib.types.bool;
        default = crowdsec.enable;
        defaultText = lib.literalExpression "config.qt1.infra.crowdsec.enable";
        description = ''
          Collect the host's CrowdSec metrics — active decisions (bans) by
          scenario, alerts, parser and bucket/scenario counters, LAPI requests
          per bouncer — into Prometheus, and provision the "CrowdSec /
          Overview" dashboard that reads them.

          CrowdSec already exposes all of this; the only thing this turns on
          is serving it on the bridge instead of loopback, so the Prometheus
          in this guest can reach it (qt1.infra.crowdsec.metricsFromGuests,
          which this option sets).
        '';
      };

      headscaleApiKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/microvms/monitoring/headscale-exporter.env";
        description = ''
          Host path holding the headscale API key the exporter reads its
          inventory with, minted automatically the first time this path
          doesn't exist (see monitoring-mint-headscale-apikey — the same
          pattern as headscale's own tailscaleAuthKeyFile). Delete it and
          restart that unit to rotate the key; the old one stays valid until
          it expires or is revoked with `headscale apikeys expire`.

          An environment file (`HEADSCALE_API_KEY=...`) rather than the bare
          key, since that's what the exporter's systemd unit consumes. It is
          never handed to the guest — unlike the Grafana secrets above, the
          exporter runs on the host.
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
          headscaleExporter = lib.optionalAttrs cfg.headscaleMetrics {
            target = "${host.hostAddress}:${toString headscaleExporterPort}";
          };
          inherit caddyExporters;
          crowdsecExporter = lib.optionalAttrs cfg.crowdsecMetrics {
            target = "${host.hostAddress}:${toString crowdsec.metricsPort}";
          };
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

      (lib.mkIf cfg.headscaleMetrics {
        qt1.infra.guests.headscale.grpcFromHost = true;

        services.prometheus.exporters.tailscale = {
          enable = true;
          listenAddress = host.hostAddress;
          port = headscaleExporterPort;
          environmentFile = cfg.headscaleApiKeyFile;
        };
        # Only the API key is secret; the rest of headscale mode's settings stay here.
        systemd.services.prometheus-tailscale-exporter = {
          serviceConfig.Environment = [
            "HEADSCALE_ADDRESS=${headscale.address}:${toString headscale.grpcPort}"
            "HEADSCALE_INSECURE=true"
          ];
          # systemd won't start a unit whose EnvironmentFile is missing.
          after = [ "monitoring-mint-headscale-apikey.service" ];
          requires = [ "monitoring-mint-headscale-apikey.service" ];
        };
        networking.firewall.interfaces.${host.bridge}.allowedTCPPorts = [ headscaleExporterPort ];

        systemd.services.monitoring-mint-headscale-apikey = {
          description = "Mint a headscale API key for the metrics exporter";
          after = [ "microvm@headscale.service" ];
          wants = [ "microvm@headscale.service" ];
          wantedBy = [ "multi-user.target" ];
          path = [
            pkgs.openssh
            pkgs.coreutils
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Restart = "on-failure";
            RestartSec = "10s";
          };
          script = ''
            set -euo pipefail

            dest=${lib.escapeShellArg cfg.headscaleApiKeyFile}
            if [ -e "$dest" ]; then
              exit 0
            fi

            ${infraLib.headscaleRemoteShell headscale}

            # headscale's 90d default would silently stop the exporter.
            key=$(remote headscale apikeys create --expiration 10y)

            install -d -m 0755 "$(dirname "$dest")"
            (
              umask 0377
              printf 'HEADSCALE_API_KEY=%s\n' "$key" > "$dest.tmp"
            )
            mv "$dest.tmp" "$dest"
          '';
        };
      })

      (lib.mkIf cfg.caddyMetrics {
        qt1.infra.guests.caddy.metricsFromMonitoring = true;
        qt1.infra.guests.caddyInternal.metricsFromMonitoring = true;
      })

      (lib.mkIf cfg.crowdsecMetrics {
        qt1.infra.crowdsec.metricsFromGuests = true;
      })

      {
        assertions = [
          {
            assertion = caddyInternal.enable;
            message = "qt1.infra.guests.monitoring requires qt1.infra.guests.caddyInternal.enable — the tailnet-only proxy is Grafana's only way in.";
          }
          {
            assertion = cfg.headscaleMetrics -> headscale.enable;
            message = "qt1.infra.guests.monitoring.headscaleMetrics requires qt1.infra.guests.headscale.enable — there is no headscale to read an inventory from otherwise.";
          }
          {
            assertion = cfg.crowdsecMetrics -> crowdsec.enable;
            message = "qt1.infra.guests.monitoring.crowdsecMetrics requires qt1.infra.crowdsec.enable — there is no CrowdSec serving metrics otherwise.";
          }
        ];

        qt1.infra.guests.caddyInternal.virtualHosts.${cfg.grafanaLabel} =
          "${cfg.address}:${toString grafanaPort}";

        services.prometheus.exporters.node = {
          enable = true;
          listenAddress = host.hostAddress;
          port = nodeExporterPort;
        };
        networking.firewall.interfaces.${host.bridge}.allowedTCPPorts = [ nodeExporterPort ];

        services.alloy.enable = true;
        environment.etc."alloy/config.alloy".text = ''
          // Promote the systemd unit to a `unit` label; the dashboards' log panels select on it.
          loki.relabel "journal" {
            forward_to = []

            rule {
              source_labels = ["__journal__systemd_unit"]
              target_label  = "unit"
            }
          }

          loki.source.journal "host" {
            labels        = { job = "host" }
            relabel_rules = loki.relabel.journal.rules
            forward_to    = [loki.write.monitoring.receiver]
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
