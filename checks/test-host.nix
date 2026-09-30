{ ... }:
{
  qt1.infra.microvmHost = {
    enable = true;
    uplinkInterface = "eth0";
  };
  qt1.infra.guests.headscale = {
    enable = true;
    serverUrl = "https://access.example.com";
    baseDomain = "tailnet.example.com";
    adminSshKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyKeyForEvalOnly test@example.com" ];
  };
  qt1.infra.guests.caddy = {
    enable = true;
    letsEncryptEmail = "you@example.com";
  };
  qt1.infra.crowdsec.enable = true;
  qt1.infra.guests.caddyInternal.enable = true;
  qt1.infra.guests.headscale.headplane.enable = true;
  qt1.infra.guests.monitoring.enable = true;
  qt1.infra.guests.gatus = {
    enable = true;
    hostname = "status.example.com";
  };
  qt1.infra.tailscaleClient.enable = true;

  boot.loader.grub.devices = [ "/dev/vda" ];
  fileSystems."/" = {
    device = "/dev/vda1";
    fsType = "ext4";
  };
  networking = {
    hostName = "infra-test";
    useDHCP = false;
  };
  system.stateVersion = "26.05";
}
