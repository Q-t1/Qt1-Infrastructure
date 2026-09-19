# Cloudflare Tunnel entrypoint into the local infrastructure. The tunnel is
# dashboard-managed: public hostnames and private routes live in Cloudflare
# Zero Trust, so the VM only needs the tunnel token. That token comes from the
# host as the `tunnel-token` systemd credential (see
# ../modules/guests/cloudflared.nix).
#
# Stateless: the root filesystem is tmpfs and there is no SSH. The tunnel's
# logs are mirrored to the serial console, so they show up on the host with
# `journalctl -u microvm@cloudflared`.
#
# Optionally also joins the tailnet coordinated by this repo's own headscale
# guest (../../modules/tailscale-client.nix), `--ephemeral` since the tmpfs
# root means a fresh identity every boot otherwise piles up dead nodes.
#
# Called with its network coordinates by the host-side module; guests are
# evaluated by microvm.nix in a nested nixosSystem that gets none of the
# host's specialArgs, so they are passed in explicitly rather than read from
# the enclosing config.
{
  address,
  mac,
  gateway,
  prefixLength,
  tailscaleEnable ? false,
  tailscaleLoginServerUrl ? null,
}:

{ pkgs, lib, ... }:

{
  imports = [ ../modules/tailscale-client.nix ];

  microvm = {
    # credentialFiles is only implemented by the qemu runner.
    hypervisor = "qemu";
    vcpu = 1;
    mem = 512;
    interfaces = [
      {
        type = "tap";
        id = "vm-cloudflared";
        inherit mac;
      }
    ];
  };

  # Credentials arrive over qemu's fw_cfg; its sysfs interface is a module, so
  # load it early enough for systemd to import them at boot.
  boot.initrd.kernelModules = [ "qemu_fw_cfg" ];

  networking = {
    useNetworkd = true;
    useDHCP = false;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
  };
  systemd.network.networks."10-uplink" = {
    matchConfig.MACAddress = mac;
    address = [ "${address}/${toString prefixLength}" ];
    gateway = [ gateway ];
  };

  # quic-go, which cloudflared uses to reach the edge, wants bigger UDP
  # buffers than the kernel default.
  boot.kernel.sysctl = {
    "net.core.rmem_max" = 7500000;
    "net.core.wmem_max" = 7500000;
  };

  environment.systemPackages = [ pkgs.cloudflared ];

  systemd.services.cloudflared-tunnel = {
    description = "Cloudflare Tunnel";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --token-file %d/tunnel-token";
      ImportCredential = "tunnel-token";
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = "5s";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
  };

  qt1.infra.tailscaleClient = lib.optionalAttrs tailscaleEnable {
    enable = true;
    loginServerUrl = tailscaleLoginServerUrl;
    # Imported the same way as the tunnel token; wired from the host in
    # ../modules/guests/cloudflared.nix.
    authKeyFile = "/run/credentials/tailscale-autoconnect.service/tailscale-authkey";
    ephemeral = true;
  };
  systemd.services.tailscale-autoconnect = lib.mkIf tailscaleEnable {
    serviceConfig.ImportCredential = "tailscale-authkey";
  };

  system.stateVersion = "26.05";
}
