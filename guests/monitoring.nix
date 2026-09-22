# monitoring: Loki (logs) + Prometheus (metrics) + Grafana (UI), all from
# nixpkgs' own modules (no Docker), bundled into one guest since none of the
# three is independently useful here — they exist purely to back this one
# Grafana instance.
#
# Reachable only over the tailnet: this guest joins it itself
# (qt1.infra.tailscaleClient), and Grafana's port is opened only on the
# tailscale0 interface below — never the guest bridge, never (transitively)
# the WAN, the same way every other guest here stays off the WAN by simply
# never appearing in the host's networking.nat.forwardPorts.
#
# Collection itself happens on the HOST, alongside crowdsec.nix
# (../modules/guests/monitoring.nix): a host-side node_exporter this guest's
# Prometheus scrapes over the bridge, and host-side Grafana Alloy tailing the
# host journal into this guest's Loki. Nothing is collected from inside the
# headscale/caddy guests in this pass.
#
# Called with its network coordinates, the tailnet it joins, and caddy's own
# bridge address/hostname (for the NAT-hairpin shortcut below) by the
# host-side module; guests are evaluated by microvm.nix in a nested
# nixosSystem that gets none of the host's specialArgs, so they are passed in
# explicitly rather than read from the enclosing config.
{
  address,
  mac,
  gateway,
  prefixLength,
  loginServerUrl,
  caddyAddress,
  tlsHostname,
}:

{ lib, ... }:

let
  lokiPort = 3100;
  prometheusPort = 9090;
  grafanaPort = 3000;
  nodeExporterPort = 9100;
in
{
  imports = [ ../modules/tailscale-client.nix ];

  microvm = {
    hypervisor = "qemu";
    vcpu = 2;
    mem = 1536;
    interfaces = [
      {
        type = "tap";
        id = "vm-monitoring";
        inherit mac;
      }
    ];
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

  boot.initrd.kernelModules = [ "qemu_fw_cfg" ];

  networking = {
    hostName = "monitoring";
    useNetworkd = true;
    useDHCP = false;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    # See the README's "Joining the tailnet" section: this resolves
    # headscale's public hostname straight to caddy's bridge address instead
    # of round-tripping out through the WAN and back in via the router's NAT
    # (hairpinning, which not every router supports), for this guest's own
    # tailscale-autoconnect run below.
    hosts.${caddyAddress} = [ tlsHostname ];
    firewall = {
      # Loki's push API: bridge-reachable, but only from the host itself
      # (the only Promtail-equivalent, Grafana Alloy, runs there) — not from
      # other guests on the bridge. extraCommands runs before the firewall's
      # default-drop rule, the same trick guests/headscale.nix uses to scope
      # its own SSH to the host only.
      extraCommands = ''
        iptables -A nixos-fw -p tcp --dport ${toString lokiPort} -s ${gateway} -j nixos-fw-accept
      '';
      # Grafana itself: tailnet-only, not bridge-reachable at all — this is
      # the actual "reachable only from the headscale net" enforcement,
      # alongside this guest never appearing in the host's
      # networking.nat.forwardPorts (see modules/guests/monitoring.nix).
      interfaces.tailscale0.allowedTCPPorts = [ grafanaPort ];
    };
  };
  systemd.network.networks."10-uplink" = {
    matchConfig.MACAddress = mac;
    address = [ "${address}/${toString prefixLength}" ];
    gateway = [ gateway ];
  };

  qt1.infra.tailscaleClient = {
    enable = true;
    inherit loginServerUrl;
    authKeyFile = "/run/credentials/tailscale-autoconnect.service/tailscale-authkey";
    # tmpfs root — same reasoning as every other guest here: without this,
    # every VM restart would register as a new tailnet node.
    ephemeral = true;
  };
  # tailscale-client.nix declares the credential path above but not the
  # import itself — mirrors sshd.serviceConfig.ImportCredential in
  # guests/headscale.nix, importing the fw_cfg credential this guest's own
  # host module hands in via microvm.credentialFiles.tailscale-authkey.
  systemd.services.tailscale-autoconnect.serviceConfig.ImportCredential = [ "tailscale-authkey" ];

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
            targets = [ "${gateway}:${toString nodeExporterPort}" ];
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
        http_addr = "0.0.0.0";
        http_port = grafanaPort;
      };
      security = {
        # Both require the file provider in this nixpkgs version — a plain
        # string here would land in the world-readable Nix store, and
        # secret_key has no default at all (hard assertion failure if
        # unset). Both files are host-generated, unattended, the same
        # pattern as the tailscale authkey above — see
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

  system.stateVersion = "26.05";
}
