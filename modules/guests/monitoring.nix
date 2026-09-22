# Host side of the monitoring guest: the VM entry, its two host-generated
# Grafana secrets, and the host-side collection that actually feeds it
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
  host = config.qt1.infra.microvmHost;
  headscale = config.qt1.infra.guests.headscale;
  caddy = config.qt1.infra.guests.caddy;
  cfg = config.qt1.infra.guests.monitoring;

  nodeExporterPort = 9100;
in
{
  options.qt1.infra.guests.monitoring = {
    enable = lib.mkEnableOption "the monitoring microVM (Loki + Prometheus + Grafana, reachable only over the tailnet)";

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.4";
      description = "Address of the guest on the guest network.";
    };

    mac = lib.mkOption {
      type = lib.types.str;
      default = "02:00:00:00:00:04";
      description = "MAC of the guest's tap interface; the guest matches on it.";
    };

    adminPasswordFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvms/monitoring/grafana-admin-password";
      description = ''
        Host path holding Grafana's initial admin password, generated on the
        host the first time this path doesn't exist (see
        monitoring-provision-secrets below). Read by qemu, which runs as the
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

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = host.enable;
        message = "qt1.infra.guests.monitoring requires qt1.infra.microvmHost.enable.";
      }
      {
        assertion = headscale.enable;
        message = "qt1.infra.guests.monitoring requires qt1.infra.guests.headscale.enable — this guest joins the tailnet it coordinates, unconditionally, as its only means of reachability.";
      }
      {
        assertion = caddy.enable;
        message = "qt1.infra.guests.monitoring requires qt1.infra.guests.caddy.enable — it needs caddy's bridge address for the NAT-hairpin shortcut its tailscale-autoconnect run uses (see guests/monitoring.nix).";
      }
    ];

    microvm.vms.monitoring.config = {
      imports = [
        (import ../../guests/monitoring.nix {
          inherit (cfg) address mac;
          inherit (host) prefixLength;
          gateway = host.hostAddress;
          loginServerUrl = headscale.serverUrl;
          caddyAddress = caddy.address;
          tlsHostname = headscale.tlsHostname;
        })
      ];
      # storeOnDisk defaults to true, which defaults systemSymlink to false —
      # that drops share/microvm/system, which `microvm -l` requires to
      # function at all. Same reasoning as every other guest here.
      microvm.systemSymlink = true;
      microvm.credentialFiles = {
        # The same shared, reusable pre-auth key every tailscaleClient
        # consumer points at (see modules/guests/headscale.nix and the
        # README's "Joining the tailnet" section) — not a secret of this
        # guest's own.
        tailscale-authkey = headscale.tailscaleAuthKeyFile;
        grafana-admin-password = cfg.adminPasswordFile;
        grafana-secret-key = cfg.secretKeyFile;
      };
    };

    # Both secrets are host-generated, not human-provided — created before
    # the VM starts instead of gating on a manual provisioning step.
    # Idempotent: files that already exist are left alone, so rotating one is
    # a matter of removing it by hand and restarting this service. Mirrors
    # headscale-provision-secrets in modules/guests/headscale.nix exactly.
    systemd.services.monitoring-provision-secrets = {
      description = "Generate the monitoring guest's Grafana admin password and secret key";
      before = [ "microvm@monitoring.service" ];
      path = [
        pkgs.openssl
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        install -d -m 0755 "$(dirname ${lib.escapeShellArg cfg.adminPasswordFile})"

        for f in ${lib.escapeShellArg cfg.adminPasswordFile} ${lib.escapeShellArg cfg.secretKeyFile}; do
          if [ ! -e "$f" ]; then
            umask 0377
            openssl rand -hex 32 > "$f"
            chown microvm:kvm "$f"
            chmod 0400 "$f"
          fi
        done
      '';
    };

    systemd.services."microvm@monitoring" = {
      wants = [ "monitoring-provision-secrets.service" ];
      after = [ "monitoring-provision-secrets.service" ];
    };

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
  };
}
