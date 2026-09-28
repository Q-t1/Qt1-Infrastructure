# Helpers shared by the host-side guest modules (modules/guests/*.nix): the
# options every guest has, the microvm.vms declaration they all make, and
# the host-generated-secrets pattern. Plain functions imported by path —
# like the rest of this flake, nothing here goes through specialArgs.
{ lib }:

rec {
  # Public resolvers used wherever something needs internet DNS: every
  # guest's own resolver, and headscale's global nameservers for MagicDNS
  # clients.
  publicResolvers = [
    "1.1.1.1"
    "8.8.8.8"
  ];

  # enable/address/mac for guest number `index` on the guest network:
  # 10.100.0.<index>, 02:00:00:00:00:<index in hex>.
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

  # The host-side half of a guest: its microvm.vms entry, built on
  # ./guests/base.nix, plus the assertions every guest needs.
  #
  #   name            VM name — also the guest's hostname and, by default,
  #                   its tap interface (`vm-<name>`)
  #   cfg             the guest's own qt1.infra.guests.<name> config
  #   module          the guest's own NixOS module (guests/<name>.nix)
  #   credentialFiles host paths handed in as systemd credentials
  #   tailnet         join the tailnet coordinated by the headscale guest
  #                   (see qt1.guest.tailnet in ./guests/base.nix)
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
        # storeOnDisk defaults to true (nothing here shares the host's
        # /nix/store into the guest), which defaults systemSymlink to false —
        # that drops share/microvm/system, which `microvm -l` requires to
        # function at all (it dies under set -e the moment readlink on that
        # path fails, for every guest, silently).
        microvm.systemSymlink = true;
        microvm.credentialFiles =
          credentialFiles
          // lib.optionalAttrs tailnet {
            # The shared, reusable pre-auth key every tailscaleClient points
            # at (see modules/guests/headscale.nix) — not this guest's own.
            tailscale-authkey = headscale.tailscaleAuthKeyFile;
          };
      };
    };

  # Host-generated secrets for guest `vm`, created before its VM starts
  # instead of gating on a manual provisioning step: a `<vm>-provision-secrets`
  # oneshot ordered before `microvm@<vm>`. Idempotent — a file that already
  # exists is left alone, so rotating one is a matter of removing it by hand
  # and restarting that service.
  #
  # `secrets` maps each host path to a shell snippet that creates "$f"
  # (run under umask 077). The file is then handed to the microvm user
  # (qemu reads it as a credential) with mode 0400.
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

  # Shell prelude for a host-side oneshot that has to run `headscale`
  # commands inside the headscale guest: everything the CLI needs has to run
  # on that guest itself (it talks to the server over a local unix socket),
  # so the host reaches it over SSH with the unattended keypair
  # headscale-provision-secrets generates.
  #
  # Defines a `remote` function running its arguments as root on the guest,
  # and waits (up to a minute) for sshd to answer — right after boot it may
  # not be up yet. Takes the headscale guest's own
  # `config.qt1.infra.guests.headscale`; the unit needs openssh and coreutils
  # on its path, `set -euo pipefail`, and no EXIT trap of its own (this one
  # cleans up the known_hosts file it writes).
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
