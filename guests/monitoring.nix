# monitoring: Loki (logs) + Prometheus (metrics) + Grafana (UI), all from
# nixpkgs' own modules (no Docker), bundled into one guest since none of the
# three is independently useful here — they exist purely to back this one
# Grafana instance.
#
# Reachable only over the tailnet, and only through its MagicDNS name
# (http://monitoring.<baseDomain>/): this guest joins the tailnet itself
# (qt1.infra.tailscaleClient) under a stable node name, Grafana listens on
# loopback only, and an nginx in front of it — its port opened only on the
# tailscale0 interface below, never the guest bridge, never (transitively)
# the WAN — answers for that one hostname and drops every other Host
# (tailnet IP, bare `monitoring`, anything else). Like every other guest here
# it also stays off the WAN by simply never appearing in the host's
# networking.nat.forwardPorts.
#
# Collection itself happens on the HOST, alongside crowdsec.nix
# (../modules/guests/monitoring.nix): a host-side node_exporter this guest's
# Prometheus scrapes over the bridge, and host-side Grafana Alloy tailing the
# host journal into this guest's Loki. Nothing is collected from inside the
# headscale/caddy guests in this pass.
#
# Called with its network coordinates, the tailnet it joins (login server and
# MagicDNS base domain), and caddy's own bridge address/hostname (for the NAT-hairpin shortcut below) by the
# host-side module; guests are evaluated by microvm.nix in a nested
# nixosSystem that gets none of the host's specialArgs, so they are passed in
# explicitly rather than read from the enclosing config.
{
  address,
  mac,
  gateway,
  prefixLength,
  loginServerUrl,
  baseDomain,
  caddyAddress,
  tlsHostname,
}:

{ lib, ... }:

let
  lokiPort = 3100;
  prometheusPort = 9090;
  grafanaPort = 3000;
  nodeExporterPort = 9100;

  # The tailnet node name this guest registers under, and so its MagicDNS
  # name — the one URL Grafana is served at.
  nodeName = "monitoring";
  fqdn = "${nodeName}.${baseDomain}";
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
        # tailscaled's node key. Persisting it keeps this guest the same
        # tailnet node — and so the same MagicDNS name — across restarts;
        # on the tmpfs root alone every boot registered a fresh node, and
        # while the previous one hadn't yet expired headscale handed the new
        # one a suffixed name (monitoring-xxxxxxxx), breaking the URL.
        image = "tailscale-state.img";
        mountPoint = "/var/lib/tailscale";
        size = 64;
      }
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
    hostName = nodeName;
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
      # nginx in front of Grafana: tailnet-only, not bridge-reachable at
      # all — this is the actual "reachable only from the headscale net"
      # enforcement, alongside this guest never appearing in the host's
      # networking.nat.forwardPorts (see modules/guests/monitoring.nix).
      # Grafana's own port isn't opened anywhere: it listens on loopback.
      interfaces.tailscale0.allowedTCPPorts = [ 80 ];
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
    # Not ephemeral: /var/lib/tailscale is a persistent volume above, so
    # restarts reuse the same node instead of piling up new ones — and an
    # ephemeral node would be deleted by headscale whenever the VM stays
    # down past its inactivity timeout, losing the name with it.
    ephemeral = false;
    # Pinned explicitly rather than inherited from the OS hostname: this is
    # the label MagicDNS serves, i.e. the URL below.
    extraUpFlags = [ "--hostname=${nodeName}" ];
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
        # Loopback only: nginx below is the sole way in.
        http_addr = "127.0.0.1";
        http_port = grafanaPort;
        domain = fqdn;
        root_url = "http://${fqdn}/";
        # Redirects any request whose Host isn't the MagicDNS name back to
        # it — a second layer behind nginx's own Host filtering (and DNS
        # rebinding protection).
        enforce_domain = true;
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

  # The only listener reachable from the tailnet (port 80 on tailscale0, see
  # the firewall above). Plain HTTP: headscale can't issue certificates for
  # MagicDNS names the way Tailscale's own `tailscale cert` does, and the
  # tailnet (WireGuard) already encrypts the traffic end to end.
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts = {
      # Anything that didn't ask for the MagicDNS name — the node's tailnet
      # IP, its short name, a made-up Host — gets the connection closed
      # without a response.
      "_" = {
        default = true;
        extraConfig = "return 444;";
      };
      ${fqdn}.locations."/" = {
        proxyPass = "http://127.0.0.1:${toString grafanaPort}";
        # Grafana Live (dashboard streaming) runs over websockets.
        proxyWebsockets = true;
      };
    };
  };

  system.stateVersion = "26.05";
}
