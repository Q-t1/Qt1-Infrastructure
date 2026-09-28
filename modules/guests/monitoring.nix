# Host side of the monitoring guest: the VM entry, its two host-generated
# Grafana secrets, Grafana's vhost on caddy-internal, and the collection that
# actually feeds it (node_exporter for metrics, Grafana Alloy for logs, the
# host's own CrowdSec metrics, and the scrape targets for the two caddy
# guests' HTTP metrics) — the guest itself only holds the storage/UI (Loki,
# Prometheus, Grafana). See ../../guests/monitoring.nix for the guest's own
# configuration and the reasoning behind bundling all three into one guest.
#
# Which of the three optional collections are on is decided here, by
# headscaleMetrics / caddyMetrics / crowdsecMetrics: each one both switches on
# whatever serves the data (a host exporter, a listener inside a caddy guest,
# CrowdSec's own endpoint) and gates the dashboard that reads it.
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

  # Both proxies, when they're enabled and serving metrics: each one's own
  # bridge address and metrics port, labelled with the guest's name. See
  # caddyMetrics.
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
  # prometheus-tailscale-exporter's own default port.
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
        # headscale's inventory only comes out of its gRPC admin API, so ask
        # the headscale guest to serve it on the bridge — host-only, see that
        # option's own docs.
        qt1.infra.guests.headscale.grpcFromHost = true;

        # The exporter that turns that API into Prometheus metrics. Host-side
        # like every other collector here, which also keeps the API key on the
        # host instead of shipping it into a guest. Bridge-bound only, never
        # the uplink/WAN interface.
        services.prometheus.exporters.tailscale = {
          enable = true;
          listenAddress = host.hostAddress;
          port = headscaleExporterPort;
          environmentFile = cfg.headscaleApiKeyFile;
        };
        # The nixpkgs module documents environmentFile for Tailscale's own
        # SaaS variables; headscale mode reads a different set. Only the API
        # key among them is a secret, so the other two stay here rather than
        # in the generated file.
        systemd.services.prometheus-tailscale-exporter = {
          serviceConfig.Environment = [
            "HEADSCALE_ADDRESS=${headscale.address}:${toString headscale.grpcPort}"
            # Plaintext gRPC: headscale holds no certificate of its own here.
            # See qt1.infra.guests.headscale.grpcFromHost.
            "HEADSCALE_INSECURE=true"
          ];
          # environmentFile doesn't exist until the unit below has minted the
          # key, and systemd refuses to start a unit whose EnvironmentFile is
          # missing.
          after = [ "monitoring-mint-headscale-apikey.service" ];
          requires = [ "monitoring-mint-headscale-apikey.service" ];
        };
        networking.firewall.interfaces.${host.bridge}.allowedTCPPorts = [ headscaleExporterPort ];

        # Mints the exporter's API key instead of a human running `headscale
        # apikeys create` by hand, the same way
        # headscale-mint-tailscale-authkey mints the pre-auth key. Idempotent
        # on the file already existing, so this is a no-op after the first
        # successful run.
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

            # Prometheus-style duration; headscale's own default is 90d,
            # which would silently stop the exporter a quarter after every
            # fresh deploy. Read-only inventory over a host-only socket, so
            # a long-lived key is the right trade here — as with the
            # pre-auth key, rotate by deleting the file.
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
        # Ask both proxies to serve their HTTP metrics on the bridge, for this
        # guest's address only — see each guest's own
        # metricsFromMonitoring. Set for both unconditionally: the option
        # only does anything inside a guest that is itself enabled, and
        # caddyExporters (above) is what decides which ones get scraped.
        qt1.infra.guests.caddy.metricsFromMonitoring = true;
        qt1.infra.guests.caddyInternal.metricsFromMonitoring = true;
      })

      (lib.mkIf cfg.crowdsecMetrics {
        # Same shape, for the host's own CrowdSec: it already exposes these
        # metrics, on loopback, so all this does is move the listener to the
        # bridge. No firewall rule here — qt1.infra.crowdsec owns that one,
        # next to the listener it opens.
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
          // Keep each entry's systemd unit as a label. Without this the whole
          // host journal arrives under `job="host"` and nothing downstream can
          // tell caddy's access log from crowdsec's decisions from a kernel
          // message — which is exactly what the caddy and crowdsec dashboards'
          // log panels select on. Bounded cardinality: it's one value per unit
          // that has ever logged. journald's own fields arrive prefixed with
          // __journal_ and are dropped unless promoted like this.
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
