# Host side of the headscale + headplane guest: the VM entry, the
# credential for headplane's session cookie secret, and the gate that keeps
# the VM stopped until that secret has been provisioned. The guest's own
# configuration is ../../guests/headscale.nix.
{ config, lib, ... }:

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
        Host path holding headplane's session cookie secret: exactly 32
        characters, provisioned by hand (see README). Read by qemu, which
        runs as the `microvm` user, and passed into the guest as a systemd
        credential so it never lands in the Nix store.
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
        Host path holding the guest's SSH host private key, provisioned by
        hand (see README): generate once with
        `ssh-keygen -t ed25519 -N "" -f <path>`. The guest's root filesystem
        is tmpfs, so without this a new host key (and a
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

    # Keep the VM stopped (skipped, not failed) until both secrets exist;
    # start it with `systemctl start microvm@headscale` once provisioned.
    # Two different condition *types* are used (rather than ConditionPathExists
    # twice) because systemd ORs repeats of the same condition key but ANDs
    # different ones.
    systemd.services."microvm@headscale".unitConfig = {
      ConditionPathExists = cfg.cookieSecretFile;
      ConditionPathExistsGlob = cfg.sshHostKeyFile;
    };
  };
}
