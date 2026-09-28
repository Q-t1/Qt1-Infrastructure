# A machine joining the tailnet coordinated by this repo's own headscale
# guest. Generic on purpose: the same module applies whether it's mixed into
# the bare host's configuration or into a guest's — only `authKeyFile` differs
# (a plain host path for the host, a systemd-credential path imported from the
# host for a guest; see qt1.guest.tailnet in ../guests/base.nix for that
# wiring). On the host, loginServerUrl/authKeyFile/loginServerAddress default
# to the headscale/caddy guests' own values when those are enabled.
{ config, lib, ... }:

let
  cfg = config.qt1.infra.tailscaleClient;

  upFlags = [
    "--login-server=${cfg.loginServerUrl}"
  ]
  ++ lib.optional cfg.ephemeral "--ephemeral"
  ++ lib.optional (cfg.hostname != null) "--hostname=${cfg.hostname}"
  ++ cfg.extraUpFlags;
in
{
  options.qt1.infra.tailscaleClient = {
    enable = lib.mkEnableOption "joining the tailnet coordinated by this repo's headscale guest";

    loginServerUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://headscale.example.com";
      description = "headscale's public serverUrl (qt1.infra.guests.headscale.serverUrl) to authenticate against.";
    };

    authKeyFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Path to a file holding a headscale pre-auth key — normally
        qt1.infra.guests.headscale.tailscaleAuthKeyFile, the reusable key
        headscale-mint-tailscale-authkey mints on the host, shared across
        every machine that uses this module.
      '';
    };

    loginServerAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.100.0.3";
      description = ''
        If set, resolve loginServerUrl's hostname straight to this address
        (via networking.hosts) instead of public DNS. On the guest bridge
        this is the caddy guest's address: reaching headscale's public
        hostname directly over the bridge instead of out through the WAN
        and back in via the router's port forward (NAT hairpinning, which
        not every router supports). See the README's "Joining the tailnet".
      '';
    };

    hostname = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Node name to register as (`tailscale up --hostname`), and so this
        machine's MagicDNS name. Defaults to the OS hostname.
      '';
    };

    ephemeral = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Pass `--ephemeral` to `tailscale up`, so headscale forgets this node
        as soon as it disconnects. Set this for machines with non-persistent
        state (this repo's tmpfs-root guests) — otherwise every restart
        registers as a new device and headscale accumulates dead nodes.
      '';
    };

    extraUpFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--advertise-tags=tag:server" ];
      description = "Extra flags appended to `tailscale up`.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale.enable = true;

    networking.hosts = lib.mkIf (cfg.loginServerAddress != null) {
      ${cfg.loginServerAddress} = [
        # scheme://host[:port][/path] -> host
        (lib.head (
          lib.splitString ":" (
            lib.head (lib.splitString "/" (lib.last (lib.splitString "://" cfg.loginServerUrl)))
          )
        ))
      ];
    };

    # tailscaled's own persisted state makes `tailscale up` idempotent: on a
    # machine with a real disk this is a no-op after the first real run, and
    # on a tmpfs-root guest it re-registers fresh every boot (hence
    # `ephemeral` above, so those re-registrations don't pile up).
    systemd.services.tailscale-autoconnect = {
      description = "Join the tailnet via headscale";
      after = [
        "tailscaled.service"
        "network-online.target"
      ];
      wants = [
        "tailscaled.service"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];
      path = [ config.services.tailscale.package ];
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
      script = ''
        set -euo pipefail
        exec tailscale up --authkey="file:${cfg.authKeyFile}" ${lib.escapeShellArgs upFlags}
      '';
    };
  };
}
