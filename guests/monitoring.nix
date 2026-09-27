# monitoring: Loki (logs) + Prometheus (metrics) + Grafana (UI), all from
# nixpkgs' own modules (no Docker), bundled into one guest since none of the
# three is independently useful here — they exist purely to back this one
# Grafana instance.
#
# Reachable only over the tailnet, and only at its MagicDNS alias
# (http://grafana.<baseDomain>/ by default), through the caddy-internal
# guest (./caddy-internal.nix): that proxy is the tailnet node, this guest
# never joins the tailnet itself. Grafana's port is opened on the bridge for
# caddy-internal's address only — not the host, not the other guests — and
# like every other guest here this one stays off the WAN by simply never
# appearing in the host's networking.nat.forwardPorts.
#
# Collection itself happens on the HOST, alongside crowdsec.nix
# (../modules/guests/monitoring.nix): a host-side node_exporter this guest's
# Prometheus scrapes over the bridge, and host-side Grafana Alloy tailing the
# host journal into this guest's Loki. Nothing is collected from inside the
# headscale/caddy guests in this pass.
#
# Built on ./base.nix; called with the hostname Grafana is served at and
# caddy-internal's bridge address by the host-side module, since guests are
# evaluated by microvm.nix in a nested nixosSystem that gets none of the
# host's specialArgs.
{
  grafanaHostname,
  proxyAddress,
}:

{ config, ... }:

let
  lokiPort = 3100;
  prometheusPort = 9090;
  grafanaPort = 3000;
  nodeExporterPort = 9100;
in
{

  microvm = {
    vcpu = 2;
    mem = 1536;
    volumes = [
      {
        image = "loki-data.img";
        mountPoint = "/var/lib/loki";
        size = 8192;
      }
      {
        image = "prometheus-data.img";
        # Prometheus's own default services.prometheus.stateDir.
        mountPoint = "/var/lib/prometheus2";
        size = 4096;
      }
      {
        image = "grafana-data.img";
        mountPoint = "/var/lib/grafana";
        size = 512;
      }
    ];
  };

  qt1.guest.allowedTCPPortsFrom = [
    # Loki's push API: only from the host itself (the only
    # Promtail-equivalent, Grafana Alloy, runs there) — not from other
    # guests on the bridge.
    {
      port = lokiPort;
      from = config.qt1.guest.gateway;
    }
    # Grafana: only from caddy-internal — its one way in, and the actual
    # "reachable only from the headscale net" enforcement, alongside this
    # guest never appearing in the host's networking.nat.forwardPorts.
    {
      port = grafanaPort;
      from = proxyAddress;
    }
  ];

  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server.http_listen_port = lokiPort;
      common = {
        path_prefix = "/var/lib/loki";
        storage.filesystem = {
          chunks_directory = "/var/lib/loki/chunks";
          rules_directory = "/var/lib/loki/rules";
        };
        replication_factor = 1;
        ring.kvstore.store = "inmemory";
      };
      schema_config.configs = [
        {
          from = "2024-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        compaction_interval = "10m";
        retention_enabled = true;
        retention_delete_delay = "2h";
        delete_request_store = "filesystem";
      };
      # 30d default — plenty for a homelab, and bounds the 8G volume above.
      limits_config = {
        retention_period = "720h";
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
      };
    };
  };

  services.prometheus = {
    enable = true;
    port = prometheusPort;
    # 30d default, matching Loki's own retention above.
    retentionTime = "30d";
    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [
          {
            targets = [ "${config.qt1.guest.gateway}:${toString nodeExporterPort}" ];
            labels.instance = "host";
          }
        ];
      }
    ];
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        # All interfaces (the bridge address may not be up yet when Grafana
        # starts); the firewall above admits caddy-internal only.
        http_addr = "0.0.0.0";
        http_port = grafanaPort;
        domain = grafanaHostname;
        root_url = "http://${grafanaHostname}/";
        # Redirects any request whose Host isn't the MagicDNS alias back to
        # it — a second layer behind caddy-internal's own Host matching (and
        # DNS rebinding protection).
        enforce_domain = true;
      };
      security = {
        # Both require the file provider in this nixpkgs version — a plain
        # string here would land in the world-readable Nix store, and
        # secret_key has no default at all (hard assertion failure if
        # unset). Both files are host-generated, unattended — see
        # ../modules/guests/monitoring.nix's monitoring-provision-secrets.
        admin_password = "$__file{/run/credentials/grafana.service/grafana-admin-password}";
        secret_key = "$__file{/run/credentials/grafana.service/grafana-secret-key}";
      };
    };
    provision.datasources.settings.datasources = [
      {
        name = "Prometheus";
        type = "prometheus";
        access = "proxy";
        url = "http://127.0.0.1:${toString prometheusPort}";
        isDefault = true;
      }
      {
        name = "Loki";
        type = "loki";
        access = "proxy";
        url = "http://127.0.0.1:${toString lokiPort}";
      }
    ];
  };
  systemd.services.grafana.serviceConfig.ImportCredential = [
    "grafana-admin-password"
    "grafana-secret-key"
  ];
}
