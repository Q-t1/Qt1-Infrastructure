# caddy: the WAN-facing reverse proxy in front of headscale. Takes over the
# job headscale's own built-in Let's Encrypt did before, but as a real HTTP
# reverse proxy it can also do what a single TLS listener inside headscale
# itself couldn't: keep /api/v1/* (headscale's REST API) off the public
# internet entirely, not just bearer-token gated. See
# ../modules/guests/caddy.nix and headscale's own guest config
# (../guests/headscale.nix).
#
# Stateful, unlike a "just forwards packets" guest: caddy's certificate and
# ACME account data live on a persistent volume (/var/lib/caddy), so a
# guest restart doesn't mean re-issuing a certificate (and burning into
# Let's Encrypt's rate limit) every time.
#
# No SSH — caddy needs no local CLI/admin access the way headscale does,
# it's entirely declared here. Its own service logs are mirrored to the
# guest's serial console instead, the same reasoning as pangolin's old
# guest: `journalctl -u microvm@caddy` on the host is the only way to see
# them, since there's no other route in.
#
# Called with its network coordinates and the hostname/upstream it fronts
# by the host-side module; guests are evaluated by microvm.nix in a nested
# nixosSystem that gets none of the host's specialArgs, so they are passed
# in explicitly rather than read from the enclosing config.
{
  address,
  mac,
  gateway,
  prefixLength,
  hostname,
  upstream,
  letsEncryptEmail,
}:

{ ... }:

{
  microvm = {
    hypervisor = "qemu";
    vcpu = 1;
    mem = 256;
    interfaces = [
      {
        type = "tap";
        id = "vm-caddy";
        inherit mac;
      }
    ];
    volumes = [
      {
        image = "caddy-data.img";
        mountPoint = "/var/lib/caddy";
        size = 256;
      }
    ];
  };

  boot.initrd.kernelModules = [ "qemu_fw_cfg" ];

  networking = {
    useNetworkd = true;
    useDHCP = false;
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    firewall.allowedTCPPorts = [
      80 # ACME HTTP-01 challenge, and caddy's own http->https redirect
      443
    ];
  };
  systemd.network.networks."10-uplink" = {
    matchConfig.MACAddress = mac;
    address = [ "${address}/${toString prefixLength}" ];
    gateway = [ gateway ];
  };

  systemd.services.caddy.serviceConfig = {
    StandardOutput = "journal+console";
    StandardError = "journal+console";
  };

  services.caddy = {
    enable = true;
    email = letsEncryptEmail;
    virtualHosts.${hostname}.extraConfig = ''
      # headscale's REST API (/api/v1/*) is bearer-token gated on its own,
      # but that's not the same as being off the public internet — this is
      # what actually keeps it off: never proxied, full stop. Use SSH + the
      # local `headscale` CLI (see the README) for anything that would
      # otherwise need this from outside the bridge.
      @blocked path /api/*
      respond @blocked 404

      reverse_proxy ${upstream}
    '';
  };

  system.stateVersion = "26.05";
}
