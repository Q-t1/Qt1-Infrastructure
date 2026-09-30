{
  grafanaHostname,
  proxyAddress,
  headscaleExporter ? { },
  caddyExporters ? [ ],
  crowdsecExporter ? { },
}:

{ config, lib, ... }:

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
    {
      port = lokiPort;
      from = config.qt1.guest.gateway;
    }
    {
      port = grafanaPort;
      from = proxyAddress;
    }
  ];

  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server = {
        http_listen_port = lokiPort;
        # At info, Loki's own query logs loop back into it through the console
        # mirror and host-side Alloy.
        log_level = "warn";
      };
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
      limits_config = {
        retention_period = "720h";
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
      };
    };
  };

  # The volume's root is root-owned after mkfs and Loki's module declares no
  # StateDirectory, so unprivileged Loki can't create its subdirectories.
  # tmpfiles runs after the mount; users.users.loki.createHome runs before it.
  systemd.tmpfiles.rules = [
    "d /var/lib/loki 0700 ${config.services.loki.user} ${config.services.loki.group} - -"
  ];

  services.prometheus = {
    enable = true;
    port = prometheusPort;
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
    ]
    ++ lib.optional (caddyExporters != [ ]) {
      job_name = "caddy";
      static_configs = map (exporter: {
        targets = [ exporter.target ];
        labels.instance = exporter.instance;
      }) caddyExporters;
    }
    ++ lib.optional (crowdsecExporter != { }) {
      job_name = "crowdsec";
      static_configs = [
        {
          targets = [ crowdsecExporter.target ];
          labels.instance = "host";
        }
      ];
    }
    ++ lib.optional (headscaleExporter != { }) {
      # The job name the upstream mixin selects on.
      job_name = "tailscale-exporter";
      static_configs = [
        {
          targets = [ headscaleExporter.target ];
          labels = {
            instance = "host";
            # The mixin-generated dashboard matches every query on these;
            # without them every panel reads "No data".
            cluster = "qt1";
            namespace = "monitoring";
          };
        }
      ];
    };
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = grafanaPort;
        domain = grafanaHostname;
        # caddy-internal terminates TLS; an http root_url yields mixed-content redirects.
        root_url = "https://${grafanaHostname}/";
        enforce_domain = true;
      };
      security = {
        # $__file keeps these out of the Nix store; secret_key has no default.
        admin_password = "$__file{/run/credentials/grafana.service/grafana-admin-password}";
        secret_key = "$__file{/run/credentials/grafana.service/grafana-secret-key}";
      };
    };
    # Grafana updates provisioned datasources by uid, so adding a uid to one
    # that already exists fails provisioning and takes Grafana down. Deleting
    # by name first turns the update into an insert.
    provision.datasources.settings.deleteDatasources = [
      {
        name = "Prometheus";
        orgId = 1;
      }
      {
        name = "Loki";
        orgId = 1;
      }
    ];
    # uids are pinned: the provisioned dashboards reference them.
    provision.datasources.settings.datasources = [
      {
        name = "Prometheus";
        type = "prometheus";
        access = "proxy";
        url = "http://127.0.0.1:${toString prometheusPort}";
        isDefault = true;
        uid = "prometheus";
      }
      {
        name = "Loki";
        type = "loki";
        access = "proxy";
        url = "http://127.0.0.1:${toString lokiPort}";
        uid = "loki";
      }
    ];
    provision.dashboards.settings.providers =
      lib.optional (headscaleExporter != { }) {
        name = "headscale";
        options.path = ./dashboards/headscale;
      }
      ++ lib.optional (caddyExporters != [ ]) {
        name = "caddy";
        options.path = ./dashboards/caddy;
      }
      ++ lib.optional (crowdsecExporter != { }) {
        name = "crowdsec";
        options.path = ./dashboards/crowdsec;
      };
  };
  systemd.services = lib.mkMerge [
    {
      grafana.serviceConfig.ImportCredential = [
        "grafana-admin-password"
        "grafana-secret-key"
      ];
    }

    (lib.genAttrs
      [
        "loki"
        "prometheus"
        "grafana"
      ]
      (_: {
        serviceConfig = {
          StandardOutput = "journal+console";
          StandardError = "journal+console";
        };
      })
    )
  ];
}
