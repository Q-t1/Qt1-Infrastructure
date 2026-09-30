{ lib }:

rec {
  publicResolvers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  guestOptions =
    { index, description }:
    {
      enable = lib.mkEnableOption description;

      address = lib.mkOption {
        type = lib.types.str;
        default = "10.100.0.${toString index}";
        description = "Address of the guest on the guest network.";
      };

      mac = lib.mkOption {
        type = lib.types.str;
        default = "02:00:00:00:00:${lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString index))}";
        description = "MAC of the guest's tap interface; the guest matches on it.";
      };
    };

  mkGuest =
    config:
    {
      name,
      cfg,
      module,
      credentialFiles ? { },
      tailnet ? false,
    }:
    let
      infra = config.qt1.infra;
      host = infra.microvmHost;
      headscale = infra.guests.headscale;
      caddy = infra.guests.caddy;
    in
    {
      assertions = [
        {
          assertion = host.enable;
          message = "qt1.infra.guests.${name} requires qt1.infra.microvmHost.enable.";
        }
      ]
      ++ lib.optionals tailnet [
        {
          assertion = headscale.enable;
          message = "qt1.infra.guests.${name} requires qt1.infra.guests.headscale.enable — it joins the tailnet headscale coordinates.";
        }
        {
          assertion = caddy.enable;
          message = "qt1.infra.guests.${name} requires qt1.infra.guests.caddy.enable — its tailnet join reaches headscale through caddy's bridge address (see the README's \"Joining the tailnet\").";
        }
      ];

      microvm.vms.${name}.config = {
        imports = [
          ./guests/base.nix
          module
        ];
        qt1.guest = {
          inherit name;
          inherit (cfg) address mac;
          inherit (host) prefixLength;
          gateway = host.hostAddress;
          tailnet = lib.mkIf tailnet {
            enable = true;
            loginServerUrl = headscale.serverUrl;
            loginServerAddress = caddy.address;
          };
        };
        # storeOnDisk (the default) turns this off, dropping
        # share/microvm/system; `microvm -l` then silently fails for every guest.
        microvm.systemSymlink = true;
        microvm.credentialFiles =
          credentialFiles
          // lib.optionalAttrs tailnet {
            tailscale-authkey = headscale.tailscaleAuthKeyFile;
          };
      };
    };

  # `secrets` maps each host path to a shell snippet that writes "$f".
  # Existing files are kept: delete one and restart <vm>-provision-secrets to rotate.
  provisionSecrets =
    {
      vm,
      description,
      path,
      secrets,
    }:
    {
      systemd.services."${vm}-provision-secrets" = {
        inherit description path;
        before = [ "microvm@${vm}.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail
          umask 0077
        ''
        + lib.concatStrings (
          lib.mapAttrsToList (file: generate: ''
            f=${lib.escapeShellArg file}
            if [ ! -e "$f" ]; then
              install -d -m 0755 "$(dirname "$f")"
              ${generate}
              chown microvm:kvm "$f"
              chmod 0400 "$f"
            fi
          '') secrets
        );
      };

      systemd.services."microvm@${vm}" = {
        wants = [ "${vm}-provision-secrets.service" ];
        after = [ "${vm}-provision-secrets.service" ];
      };
    };

  # Defines `remote` (runs its arguments as root on the headscale guest over
  # SSH) and waits up to a minute for sshd. The calling unit needs openssh and
  # coreutils on its path, `set -euo pipefail`, and no EXIT trap of its own.
  headscaleRemoteShell = headscale: ''
    known_hosts=$(mktemp)
    trap 'rm -f "$known_hosts"' EXIT
    printf '%s %s\n' ${lib.escapeShellArg headscale.address} \
      "$(ssh-keygen -y -f ${lib.escapeShellArg headscale.sshHostKeyFile})" > "$known_hosts"

    ssh_opts=(
      -i ${lib.escapeShellArg headscale.automationSshKeyFile}
      -o UserKnownHostsFile="$known_hosts"
      -o ConnectTimeout=5
      -o BatchMode=yes
    )
    remote() { ssh "''${ssh_opts[@]}" root@${lib.escapeShellArg headscale.address} "$@"; }

    for _ in $(seq 1 30); do
      remote true 2>/dev/null && break
      sleep 2
    done
  '';
}
