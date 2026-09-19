# Minimal NixOS host used only to evaluate/build the infra layer on its own,
# with no consumer flake involved. Nothing here is deployed.
{
  qt1.infra.microvmHost = {
    enable = true;
    uplinkInterface = "eth0";
  };
  qt1.infra.guests.cloudflared.enable = true;
  qt1.infra.guests.headscale = {
    enable = true;
    serverUrl = "https://headscale.example.com";
    baseDomain = "tailnet.example.com";
    headplaneUrl = "https://headplane.example.com";
  };

  # Enough of a machine for `system.build.toplevel` to evaluate.
  boot.loader.grub.devices = [ "/dev/vda" ];
  fileSystems."/" = {
    device = "/dev/vda1";
    fsType = "ext4";
  };
  networking = {
    hostName = "infra-test";
    # the host owns its uplink; networkd here only manages the guest bridge
    useDHCP = false;
  };
  system.stateVersion = "26.05";
}
