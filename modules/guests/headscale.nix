# Host side of the headscale guest: the VM entry, its two host-generated
# credentials and the WAN port forwarding that makes it reachable — unlike
# the old Cloudflare Tunnel/Pangolin split, headscale terminates its own TLS
# and needs real inbound ports the same way Pangolin's gerbil/traefik did.
# The guest's own configuration is ../../guests/headscale.nix.
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
    enable = lib.mkEnableOption "the headscale microVM (self-hosted Tailscale coordination server)";

    address = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.2";
      description = "Address of the guest on the guest network.";
    };

    mac = lib.mkOption {
      type = lib.types.str;
      default = "02:00:00:00:00:02";
      description = "MAC of the guest's tap interface; the guest matches on it.";
    };

    serverUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://access.example.com";
      description = ''
        Public URL Tailscale clients reach headscale at (`https://`, no
        trailing slash) — also what headscale requests its Let's Encrypt
        certificate for. Needs a DNS record pointing at this host's WAN
        address, and this host's router/firewall must forward ports 80/tcp
        (ACME HTTP-01 challenge) and 443/tcp (the server itself) to it — see
        forwardPorts below and the README.
      '';
    };

    tlsHostname = lib.mkOption {
      type = lib.types.str;
      default = lib.removePrefix "https://" cfg.serverUrl;
      readOnly = true;
      description = ''
        serverUrl with its scheme stripped. A bridge-local consumer of
        tailscaleClient (the host, or another guest) should point this
        hostname at `address` via its own `networking.hosts`, so it reaches
        headscale directly over the bridge instead of round-tripping through
        the WAN/NAT — see the README's "Joining the tailnet" section.
      '';
    };

    baseDomain = lib.mkOption {
      type = lib.types.str;
      example = "tailnet.example.com";
      description = ''
        Base domain for MagicDNS (a node's hostname becomes
        hostname.''${baseDomain}). Must be a different domain from
        serverUrl's. No DNS record needed for this one — headscale resolves
        it itself, to tailnet-internal addresses, not the public internet.
      '';
    };

    letsEncryptEmail = lib.mkOption {
      type = lib.types.str;
      example = "you@example.com";
      description = "Contact address for Let's Encrypt certificate issuance.";
    };

    adminSshKey = lib.mkOption {
      type = lib.types.str;
      example = "ssh-ed25519 AAAA... user@host";
      description = ''
        Public key authorized for root SSH on the guest, key-only and
        reachable only from the host (not from other guests on the bridge or
        the WAN). Needed because the `headscale` CLI (e.g. `apikeys create`)
        talks to the running server over a local unix socket, so it has to
        run on this guest itself.
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

    automationSshKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvms/headscale/automation-ssh-key";
      description = ''
        Host path holding a second, host-only SSH keypair (distinct from
        adminSshKey), generated the same way as sshHostKeyFile. Its public
        half is authorized for root on the guest too, so
        headscale-mint-tailscale-authkey can run `headscale` commands without
        a human present; its private half never leaves the host.
      '';
    };

    tailnetUser = lib.mkOption {
      type = lib.types.str;
      default = "homelab";
      description = ''
        headscale user that owns the auto-minted, reusable pre-auth key at
        tailscaleAuthKeyFile — created if it doesn't already exist. Kept
        separate from any human/OIDC user, since this one just owns the
        shared enrollment key for this repo's own machines.
      '';
    };

    tailscaleAuthKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/microvms/headscale/tailscale-authkey";
      readOnly = true;
      description = ''
        Host path holding a reusable headscale pre-auth key, minted
        automatically by headscale-mint-tailscale-authkey the first time this
        path doesn't exist. Point any `qt1.infra.tailscaleClient.authKeyFile`
        (the host) or a guest's own opt-in at this same file — one key,
        shared across every machine that wants to join the tailnet.
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
            letsEncryptEmail
            adminSshKey
            ;
          inherit (host) prefixLength;
          gateway = host.hostAddress;
        })
      ];
      microvm.credentialFiles = {
        ssh-host-ed25519-key = cfg.sshHostKeyFile;
        automation-ssh-pubkey = "${cfg.automationSshKeyFile}.pub";
      };
    };

    # Both secrets are host-generated, not human-provided, so create
    # whichever is missing before the VM starts instead of gating on a
    # manual provisioning step. Idempotent: a file that already exists is
    # left alone, so rotating one is still a matter of removing it by hand
    # and restarting this service.
    systemd.services.headscale-provision-secrets = {
      description = "Generate the headscale guest's SSH host key and automation SSH key";
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

        if [ ! -e ${lib.escapeShellArg cfg.automationSshKeyFile} ]; then
          ssh-keygen -q -t ed25519 -N "" -f ${lib.escapeShellArg cfg.automationSshKeyFile}
          chown microvm:kvm ${lib.escapeShellArg cfg.automationSshKeyFile}
          chmod 0400 ${lib.escapeShellArg cfg.automationSshKeyFile}
          chmod 0444 ${lib.escapeShellArg cfg.automationSshKeyFile}.pub
        fi
      '';
    };

    systemd.services."microvm@headscale" = {
      wants = [ "headscale-provision-secrets.service" ];
      after = [ "headscale-provision-secrets.service" ];
    };

    # Mints the reusable pre-auth key any tailscaleClient can join with,
    # instead of a human running `headscale preauthkeys create` by hand.
    # Idempotent on tailscaleAuthKeyFile already existing, so this is a no-op
    # after the first successful run; delete that file and restart this
    # service to rotate it. Runs whenever headscale is enabled, whether or
    # not anything currently consumes the key.
    systemd.services.headscale-mint-tailscale-authkey = {
      description = "Mint a reusable headscale pre-auth key for tailscaleClient";
      after = [ "microvm@headscale.service" ];
      wants = [ "microvm@headscale.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.openssh
        pkgs.jq
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

        dest=${lib.escapeShellArg cfg.tailscaleAuthKeyFile}
        if [ -e "$dest" ]; then
          exit 0
        fi

        known_hosts=$(mktemp)
        trap 'rm -f "$known_hosts"' EXIT
        printf '%s %s\n' ${lib.escapeShellArg cfg.address} \
          "$(ssh-keygen -y -f ${lib.escapeShellArg cfg.sshHostKeyFile})" > "$known_hosts"

        ssh_opts=(
          -i ${lib.escapeShellArg cfg.automationSshKeyFile}
          -o UserKnownHostsFile="$known_hosts"
          -o ConnectTimeout=5
          -o BatchMode=yes
        )
        remote() { ssh "''${ssh_opts[@]}" root@${lib.escapeShellArg cfg.address} "$@"; }

        for _ in $(seq 1 30); do
          remote true 2>/dev/null && break
          sleep 2
        done

        find_user_id() {
          # headscale prints the bare JSON `null` (not `[]`) for an empty
          # user list, e.g. on a genuinely fresh server before this script
          # has created anyone yet — `(. // [])` normalizes that so `.[]`
          # doesn't choke on it.
          remote headscale users list --output json \
            | jq -r --arg name ${lib.escapeShellArg cfg.tailnetUser} '(. // [])[] | select(.name == $name) | .id'
        }

        user_id=$(find_user_id)
        if [ -z "$user_id" ]; then
          remote headscale users create ${lib.escapeShellArg cfg.tailnetUser}
          user_id=$(find_user_id)
        fi

        key=$(remote headscale preauthkeys create --user "$user_id" --reusable --expiration 87600h --output json \
          | jq -r '.key')

        (
          umask 0377
          printf '%s' "$key" > "$dest.tmp"
        )
        chown microvm:kvm "$dest.tmp"
        mv "$dest.tmp" "$dest"
      '';
    };

    # Real inbound ports, unlike the old cloudflared tunnel: headscale
    # terminates its own TLS and needs the ACME HTTP-01 challenge and the
    # server's own HTTPS port to actually reach the guest.
    networking.nat.forwardPorts = [
      {
        sourcePort = 80;
        destination = "${cfg.address}:80";
        proto = "tcp";
      }
      {
        sourcePort = 443;
        destination = "${cfg.address}:443";
        proto = "tcp";
      }
    ];
  };
}
