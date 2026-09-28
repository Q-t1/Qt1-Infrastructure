# Host side of the headscale guest: the VM entry and its two host-generated
# credentials. No WAN port forwarding here — the caddy guest
# (../modules/guests/caddy.nix) is what's actually reachable from the WAN
# now; this one only needs to be reachable from caddy, over the bridge.
# The guest's own configuration is ../../guests/headscale.nix.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  infraLib = import ../../lib.nix { inherit lib; };
  host = config.qt1.infra.microvmHost;
  cfg = config.qt1.infra.guests.headscale;
in
{
  options.qt1.infra.guests.headscale =
    infraLib.guestOptions {
      index = 2;
      description = "the headscale microVM (self-hosted Tailscale coordination server)";
    }
    // {

      serverUrl = lib.mkOption {
        type = lib.types.str;
        example = "https://access.example.com";
        description = ''
          Public URL Tailscale clients reach headscale at (`https://`, no
          trailing slash). headscale itself only listens plain HTTP on the
          bridge (internalPort below) — the caddy guest
          (qt1.infra.guests.caddy) is what actually terminates TLS for this
          hostname and needs a DNS record pointing at this host's WAN address;
          see its own option docs and the README.
        '';
      };

      tlsHostname = lib.mkOption {
        type = lib.types.str;
        default = lib.removePrefix "https://" cfg.serverUrl;
        readOnly = true;
        description = ''
          serverUrl with its scheme stripped. This is what the caddy guest
          requests its Let's Encrypt certificate for, and what a bridge-local
          consumer of tailscaleClient (the host, or another guest) should
          point at qt1.infra.guests.caddy.address via its own
          `networking.hosts`, so it reaches caddy directly over the bridge
          instead of round-tripping through the WAN/NAT — see the README's
          "Joining the tailnet" section.
        '';
      };

      internalPort = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        readOnly = true;
        description = ''
          Port headscale listens on for plain HTTP on the guest bridge, once
          caddy is fronting it for TLS — not reachable from the WAN. What
          qt1.infra.guests.caddy reverse-proxies to.
        '';
      };

      grpcFromHost = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Serve headscale's gRPC admin API on the guest bridge, reachable
          from the host only (not from other guests, and never from the WAN —
          this guest has no forwardPorts entry). Off by default: with it off
          headscale keeps its gRPC API on its local unix socket, which is all
          the `headscale` CLI running on the guest itself needs.

          Turned on by qt1.infra.guests.monitoring when it collects
          headscale's inventory metrics, since the exporter that reads them
          runs on the host alongside the other collectors. Plaintext
          (`grpc_allow_insecure`): headscale has no certificate of its own
          here — caddy terminates TLS for it — and this listener never leaves
          the host-only bridge. Callers still need an API key, minted by
          monitoring-mint-headscale-apikey.
        '';
      };

      grpcPort = lib.mkOption {
        type = lib.types.port;
        default = 50443;
        readOnly = true;
        description = ''
          Port headscale's gRPC admin API listens on when grpcFromHost is
          set — headscale's own default. Bridge-only, host-only.
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

      magicDnsAliases = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          "grafana.tailnet.example.com" = "caddy-internal";
        };
        description = ''
          Extra MagicDNS names, as `fqdn = "node-name"`: each fqdn resolves,
          for every tailnet client, to the current tailnet addresses of the
          node with that name. Kept in sync inside the guest by
          headscale-magicdns-aliases (see guests/headscale.nix), since node
          addresses are assigned at registration, not known at build time.
          Set by qt1.infra.guests.caddyInternal for its vhosts; rarely set by
          hand.
        '';
      };

      adminSshKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "ssh-ed25519 AAAA... user@host" ];
        description = ''
          Public keys authorized for root SSH on the guest, on top of
          qt1.infra.microvmHost.adminSshKeys (the host-wide default) —
          key-only and reachable only from the host (not from other guests on
          the bridge or the WAN). Needed because the `headscale` CLI (e.g.
          `apikeys create`) talks to the running server over a local unix
          socket, so it has to run on this guest itself.
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
          adminSshKeys), generated the same way as sshHostKeyFile. Its public
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

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (infraLib.mkGuest config {
        name = "headscale";
        inherit cfg;
        module = import ../../guests/headscale.nix {
          inherit (cfg)
            serverUrl
            baseDomain
            internalPort
            magicDnsAliases
            grpcFromHost
            grpcPort
            ;
          adminSshKeys = host.adminSshKeys ++ cfg.adminSshKeys;
        };
        credentialFiles = {
          ssh-host-ed25519-key = cfg.sshHostKeyFile;
          automation-ssh-pubkey = "${cfg.automationSshKeyFile}.pub";
        };
      })

      (infraLib.provisionSecrets {
        vm = "headscale";
        description = "Generate the headscale guest's SSH host key and automation SSH key";
        path = [
          pkgs.openssh
          pkgs.coreutils
        ];
        secrets = {
          ${cfg.sshHostKeyFile} = ''
            ssh-keygen -q -t ed25519 -N "" -f "$f"
            rm -f "$f.pub"
          '';
          ${cfg.automationSshKeyFile} = ''
            ssh-keygen -q -t ed25519 -N "" -f "$f"
            chmod 0444 "$f.pub"
          '';
        };
      })

      {
        # The host's own tailnet join (qt1.infra.tailscaleClient, when
        # enabled) points at this headscale by default.
        qt1.infra.tailscaleClient = {
          loginServerUrl = lib.mkDefault cfg.serverUrl;
          authKeyFile = lib.mkDefault cfg.tailscaleAuthKeyFile;
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

            ${infraLib.headscaleRemoteShell cfg}

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
      }
    ]
  );
}
