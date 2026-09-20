# A machine joining the tailnet coordinated by this repo's own headscale
# guest. Generic on purpose: the same module applies whether it's mixed into
# the bare host's configuration or into a guest's — only `authKeyFile` differs
# (a plain host path for the host, a systemd-credential path imported from the
# host for a guest; see modules/guests/cloudflared.nix's `tailscale.*` options
# for that wiring).
{ config, lib, ... }:

let
  cfg = config.qt1.infra.tailscaleClient;
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
        Path to a file holding a headscale pre-auth key. Provisioned by hand,
        like the cloudflared tunnel token: minting one requires headscale
        already running and a user already created in it, so it can't be
        generated unattended the way this repo's other secrets are (see
        README). A single `--reusable` key can be shared across every machine
        that uses this module.
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
        exec tailscale up \
          --login-server=${lib.escapeShellArg cfg.loginServerUrl} \
          --authkey="file:${cfg.authKeyFile}" \
          ${lib.optionalString cfg.ephemeral "--ephemeral"} \
          ${lib.escapeShellArgs cfg.extraUpFlags}
      '';
    };
  };
}
