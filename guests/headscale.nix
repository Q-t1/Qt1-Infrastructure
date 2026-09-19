# headscale (Tailscale coordination server) and headplane (its web UI),
# collocated on one guest. Both are reached from outside only through the
# cloudflared guest's dashboard-managed tunnel, routed to this guest's
# address on the guest bridge (see ../modules/guests/headscale.nix and the
# README) — nothing here opens a port on the host or the WAN.
#
# Stateful, unlike the cloudflared guest: headscale's node/key database and
# headplane's own data live on persistent volumes rather than the default
# tmpfs root, so they survive guest restarts.
#
# Called with its network coordinates and public hostnames by the host-side
# module; guests are evaluated by microvm.nix in a nested nixosSystem that
# gets none of the host's specialArgs, so they are passed in explicitly
# rather than read from the enclosing config.
{
  address,
  mac,
  gateway,
  prefixLength,
  serverUrl,
  baseDomain,
  headplaneUrl,
}:

{ ... }:

{
  microvm = {
    # credentialFiles (for headplane's cookie secret) is only implemented by
    # the qemu runner.
    hypervisor = "qemu";
    vcpu = 2;
    mem = 1024;
    interfaces = [
      {
        type = "tap";
        id = "vm-headscale";
        inherit mac;
      }
    ];
    volumes = [
      {
        image = "headscale-data.img";
        mountPoint = "/var/lib/headscale";
        size = 512;
      }
      {
        image = "headplane-data.img";
        mountPoint = "/var/lib/headplane";
        size = 256;
      }
    ];
  };

  # Credentials (headplane's cookie secret) arrive over qemu's fw_cfg; its
  # sysfs interface is a module, so load it early enough for systemd to
  # import them at boot.
  boot.initrd.kernelModules = [ "qemu_fw_cfg" ];

  networking = {
    useNetworkd = true;
    useDHCP = false;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    firewall.allowedTCPPorts = [
      8080
      3000
    ];
  };
  systemd.network.networks."10-uplink" = {
    matchConfig.MACAddress = mac;
    address = [ "${address}/${toString prefixLength}" ];
    gateway = [ gateway ];
  };

  services.headscale = {
    enable = true;
    address = "0.0.0.0";
    port = 8080;
    settings = {
      server_url = serverUrl;
      dns = {
        base_domain = baseDomain;
        # MagicDNS clients use this as their sole resolver, so it must be
        # able to resolve the public internet too, not just the tailnet.
        nameservers.global = [
          "1.1.1.1"
          "8.8.8.8"
        ];
      };
    };
  };

  services.headplane = {
    enable = true;
    settings = {
      server = {
        host = "0.0.0.0";
        port = 3000;
        base_url = headplaneUrl;
        # Cloudflare Tunnel terminates TLS at the edge; the backend hop from
        # cloudflared to this guest is plain HTTP, but the browser only ever
        # sees https://, so the Secure cookie attribute is still correct.
        cookie_secret_path = "/run/credentials/headplane.service/headplane-cookie-secret";
      };
      # config_path and headscale.url default to headscale's own configFile
      # and localhost port, which is correct here since both run on this
      # guest.
    };
  };

  # Headplane needs its cookie secret in its own credential store; the
  # credential itself is imported at the VM level from the host (see
  # ../modules/guests/headscale.nix).
  systemd.services.headplane.serviceConfig.ImportCredential = "headplane-cookie-secret";

  system.stateVersion = "26.05";
}
