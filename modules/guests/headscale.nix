# Host side of the headscale + headplane guest: the VM entry and its two
# credentials. Unlike the cloudflared tunnel token, neither secret needs a
# human to obtain it, so both are generated on the host the first time they're
# missing (see headscale-provision-secrets below) rather than provisioned by
# hand. The guest's own configuration is ../../guests/headscale.nix.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  host = config.qt1.infra.microvmHost;
  cfg = config.qt1.infra.guests.headscale;
in
{
  options.qt1.infra.guests.headscale = {
    enable = lib.mkEnableOption "the headscale + headplane microVM";

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.3";
      description = "Address of the guest on the guest network.";
    };

    mac = lib.mkOption {
      type = lib.types.str;
      default = "02:00:00:00:00:02";
      description = "MAC of the guest's tap interface; the guest matches on it.";
    };

    serverUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://headscale.example.com";
      description = ''
        Public URL Tailscale clients and headplane reach headscale at. Route
        this hostname to http://${cfg.address}:8080 in the cloudflared
        tunnel's dashboard-managed config; nothing here opens a port on the
        host or the WAN.
      '';
    };

    baseDomain = lib.mkOption {
      type = lib.types.str;
      example = "tailnet.example.com";
      description = ''
        Base domain for MagicDNS. Must be a different domain to
        {option}`serverUrl`'s.
      '';
    };

    headplaneUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://headplane.example.com";
      description = ''
        Public URL headplane is reached at. Route this hostname to
        http://${cfg.address}:3000 in the cloudflared tunnel's
        dashboard-managed config.
      '';
    };

    cookieSecretFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvms/headscale/headplane-cookie-secret";
      description = ''
        Host path holding headplane's session cookie secret: 32 random
        characters, generated on the host the first time this path doesn't
        exist (see headscale-provision-secrets). Read by qemu, which runs as
        the `microvm` user, and passed into the guest as a systemd credential
        so it never lands in the Nix store.
      '';
    };

    adminSshKey = lib.mkOption {
      type = lib.types.str;
      example = "ssh-ed25519 AAAA... user@host";
      description = ''
        Public key authorized for root SSH on the guest, key-only and
        reachable only from the host (not from other guests on the bridge).
        Needed because the `headscale` CLI (e.g. `apikeys create`) has to run
        on the same machine as the server.
      '';
    };

    sshHostKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvms/headscale/ssh_host_ed25519_key";
      description = ''
        Host path holding the guest's SSH host private key, generated on the
        host the first time this path doesn't exist (see
        headscale-provision-secrets). The guest's root filesystem is tmpfs,
        so without a key pinned here a new one (and a
        REMOTE-HOST-IDENTIFICATION-CHANGED warning) would be generated on
        every VM restart. Read by qemu, which runs as the `microvm` user, and
        passed into the guest as a systemd credential so it never lands in
        the Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = host.enable;
        message = "qt1.infra.guests.headscale requires qt1.infra.microvmHost.enable.";
      }
    ];

    microvm.vms.headscale.config = {
      imports = [
        (import ../../guests/headscale.nix {
          inherit (cfg)
            address
            mac
            serverUrl
            baseDomain
            headplaneUrl
            adminSshKey
            ;
          inherit (host) prefixLength;
          gateway = host.hostAddress;
        })
      ];
      microvm.credentialFiles = {
        headplane-cookie-secret = cfg.cookieSecretFile;
        ssh-host-ed25519-key = cfg.sshHostKeyFile;
      };
    };

    # Both secrets are host-generated, not human-provided (unlike
    # cloudflared's tunnel token), so create whichever is missing before the
    # VM starts instead of gating on a manual provisioning step. Idempotent:
    # a file that already exists is left alone, so rotating one is still a
    # matter of removing it by hand and restarting this service.
    systemd.services.headscale-provision-secrets = {
      description = "Generate the headscale guest's SSH host key and headplane cookie secret";
      before = [ "microvm@headscale.service" ];
      path = [
        pkgs.openssh
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        install -d -m 0755 "$(dirname ${lib.escapeShellArg cfg.sshHostKeyFile})"

        if [ ! -e ${lib.escapeShellArg cfg.sshHostKeyFile} ]; then
          ssh-keygen -q -t ed25519 -N "" -f ${lib.escapeShellArg cfg.sshHostKeyFile}
          rm -f ${lib.escapeShellArg cfg.sshHostKeyFile}.pub
          chown microvm:kvm ${lib.escapeShellArg cfg.sshHostKeyFile}
          chmod 0400 ${lib.escapeShellArg cfg.sshHostKeyFile}
        fi

        if [ ! -e ${lib.escapeShellArg cfg.cookieSecretFile} ]; then
          (
            umask 0377
            head -c 32 /dev/urandom | base64 | head -c 32 > ${lib.escapeShellArg cfg.cookieSecretFile}
          )
          chown microvm:kvm ${lib.escapeShellArg cfg.cookieSecretFile}
        fi
      '';
    };

    systemd.services."microvm@headscale" = {
      wants = [ "headscale-provision-secrets.service" ];
      after = [ "headscale-provision-secrets.service" ];
    };
  };
}
