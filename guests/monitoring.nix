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
# Collection is mostly on the HOST, alongside crowdsec.nix
# (../modules/guests/monitoring.nix): a host-side node_exporter this guest's
# Prometheus scrapes over the bridge, host-side Grafana Alloy tailing the
# host journal into this guest's Loki, the host's own CrowdSec metrics
# (crowdsecMetrics) and — when headscaleMetrics is on — a host-side
# prometheus-tailscale-exporter reading headscale's tailnet inventory out of
# its gRPC admin API. The one exception is caddyMetrics: each caddy guest
# serves its own HTTP metrics on the bridge, for this guest only, since no
# host-side collector can see the requests a proxy inside a VM handled.
# Nothing is collected from inside the headscale guest.
#
# Dashboards are provisioned from ./dashboards, one directory (and one
# provider) per topic, so a dashboard only exists when whatever feeds it is
# actually collected:
#
#  - headscale/headscale-overview.json is revision 7 of grafana.com dashboard
#    24516 ("Headscale / Overview", generated from the exporter's own
#    tailscale-mixin), with a single edit: its data source variable points at
#    the Prometheus datasource's pinned uid instead of the mixin's
#    placeholder.
#  - caddy/caddy-overview.json and crowdsec/crowdsec-overview.json are written
#    for this repo rather than vendored, against the labels the scrape jobs
#    below attach and the `unit` label host-side Alloy puts on journal logs.
#
# Built on ./base.nix; called with the hostname Grafana is served at and
# caddy-internal's bridge address by the host-side module, since guests are
# evaluated by microvm.nix in a nested nixosSystem that gets none of the
# host's specialArgs.
{
  grafanaHostname,
  proxyAddress,
  # `{ target = "host:port"; }` when the host runs the headscale metrics
  # exporter (qt1.infra.guests.monitoring.headscaleMetrics), `{ }` otherwise
  # — it gates both the scrape job and the dashboard that reads it.
  headscaleExporter ? { },
  # `[ { instance = "caddy"; target = "host:port"; } ... ]` — one entry per
  # caddy guest serving its metrics on the bridge
  # (qt1.infra.guests.monitoring.caddyMetrics), `[ ]` otherwise. `instance` is
  # the guest's name, which is what the caddy dashboard's own variable lists.
  caddyExporters ? [ ],
  # `{ target = "host:port"; }` when the host's CrowdSec serves its metrics on
  # the bridge (qt1.infra.guests.monitoring.crowdsecMetrics), `{ }` otherwise.
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
      server = {
        http_listen_port = lokiPort;
        # Errors and warnings only. At info level loki logs several verbose
        # metrics.go lines per query, and — because this guest mirrors its
        # services' logs to the console, which the host journal captures and
        # host-side Alloy ships straight back here — its own query logs would
        # be ingested as log data. That path is bounded rather than runaway
        # (ingesting generates no queries), but an auto-refreshing dashboard
        # would otherwise keep feeding loki's chatter about itself into
        # storage. Errors still reach the console, which is the only way to
        # debug this guest at all: see the mirroring block at the end.
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
      # 30d default — plenty for a homelab, and bounds the 8G volume above.
      limits_config = {
        retention_period = "720h";
        reject_old_samples = true;
        reject_old_samples_max_age = "168h";
      };
    };
  };

  # Give loki ownership of its data volume's root. microvm.nix creates each
  # volume with mkfs, so the fresh ext4's root directory belongs to root —
  # and loki runs unprivileged, so it cannot create the rules/, chunks/ and
  # compactor/ subdirectories its config points at. It dies at startup, in a
  # restart loop, with:
  #
  #   mkdir /var/lib/loki/rules: permission denied
  #   error initialising module: ruler-storage
  #
  # Prometheus needs no equivalent because its own nixpkgs module declares
  # StateDirectory, which systemd applies when the unit starts, i.e. after
  # the volume is mounted. Loki's module declares neither that nor a
  # tmpfiles rule, so this is ours to do. It must be tmpfiles (ordered after
  # local-fs.target) rather than the module's users.users.loki.createHome,
  # which cannot help: whatever it does to this path happens before the
  # volume is mounted over it.
  systemd.tmpfiles.rules = [
    "d /var/lib/loki 0700 ${config.services.loki.user} ${config.services.loki.group} - -"
  ];

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
    ]
    ++ lib.optional (caddyExporters != [ ]) {
      # Both proxies in one job, told apart by the `instance` label rather
      # than by job name: every panel in the caddy dashboard is written
      # against one instance at a time, picked from a variable.
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
          # CrowdSec runs on the host, like every other collector here.
          labels.instance = "host";
        }
      ];
    }
    ++ lib.optional (headscaleExporter != { }) {
      # The job name the upstream mixin selects on by default — the
      # dashboard's `job` variable is populated from it.
      job_name = "tailscale-exporter";
      static_configs = [
        {
          targets = [ headscaleExporter.target ];
          labels = {
            instance = "host";
            # The dashboard is generated from a Kubernetes-shaped mixin:
            # every one of its queries matches on cluster and namespace, and
            # its variables are populated from them, so without these two
            # labels every panel reads "No data". Their values are arbitrary
            # here — there is one cluster of one — they just have to exist.
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
        # All interfaces (the bridge address may not be up yet when Grafana
        # starts); the firewall above admits caddy-internal only.
        http_addr = "0.0.0.0";
        http_port = grafanaPort;
        domain = grafanaHostname;
        # https, terminated by caddy-internal with a local-CA certificate;
        # grafana itself stays plain HTTP on the bridge behind it. Getting
        # this scheme wrong makes grafana hand out http:// redirects and
        # asset URLs, which the browser then blocks as mixed content.
        root_url = "https://${grafanaHostname}/";
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
    # Grafana matches a provisioned datasource by name and then *updates it
    # by uid*, so introducing a uid for a datasource that already exists in
    # its database fails the whole provisioning step with "Datasource
    # provisioning error: data source not found" — and a failed provisioning
    # module takes the entire process down, not just the datasource. Deleting
    # by name first turns that update into an insert. Reproduced and verified
    # against grafana 13.1.6.
    #
    # Delete-then-insert runs on every start, but the uids below are pinned,
    # so each datasource is recreated identically and anything referencing it
    # by uid keeps working. The one casualty is a hand-made dashboard still
    # pointing at a random uid grafana generated before these were pinned;
    # repoint it at "prometheus" or "loki" once.
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
    provision.datasources.settings.datasources = [
      {
        name = "Prometheus";
        type = "prometheus";
        access = "proxy";
        url = "http://127.0.0.1:${toString prometheusPort}";
        isDefault = true;
        # Pinned rather than generated, so a provisioned dashboard can name
        # it: the headscale dashboard below carries this uid as its data
        # source variable's value.
        uid = "prometheus";
      }
      {
        name = "Loki";
        type = "loki";
        access = "proxy";
        url = "http://127.0.0.1:${toString lokiPort}";
        # Pinned for the same reason as Prometheus's above: the caddy and
        # crowdsec dashboards each carry a logs panel naming this uid.
        uid = "loki";
      }
    ];
    # Dashboards are provisioned from the store, one provider per topic
    # directory under ./dashboards, so a provider only appears when whatever
    # feeds it is actually being collected. They are read-only in the UI as a
    # result (Grafana reverts an edited provisioned dashboard on its next
    # scan); "Save as" a copy to modify one.
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

    # Mirror all three services' own logs to the guest's serial console, the
    # same way ./caddy.nix does and for the same reason: this guest exposes
    # no SSH, and its root is a tmpfs, so its journal dies with it. Without
    # this the host only ever sees systemd's "Started ..." lines — enough to
    # know a unit was launched, useless for finding out why it then failed
    # to serve. `journalctl -u microvm@monitoring` on the host is the only
    # way to read these.
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
