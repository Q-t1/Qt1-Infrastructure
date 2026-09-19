{
  description = "Qt1 infrastructure: microVM host layer, guests and services";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # Lightweight NixOS guests. The host module is imported by
    # nixosModules.microvmHost below, so consumers never need this input
    # themselves.
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      microvm,
      flake-utils,
    }:
    let
      lib = nixpkgs.lib;

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
    in
    flake-utils.lib.eachSystem systems (system: {
      formatter = nixpkgs.legacyPackages.${system}.nixfmt;
    })
    // {
      nixosModules = {
        default = self.nixosModules.microvmHost;

        # The whole infra layer: microvm.nix's host module, our bridge/NAT
        # wiring, and the guest catalogue. Everything is gated behind
        # `qt1.infra.*` options, so importing this module without enabling
        # anything changes nothing about the host.
        #
        # Note these modules deliberately take no `inputs` specialArg: the
        # `microvm` input is closed over here, which is what lets any flake
        # import this without carrying infra's inputs.
        microvmHost = {
          imports = [
            microvm.nixosModules.host
            ./modules/microvm-host.nix
            ./modules/tailscale-client.nix
            ./modules/guests/cloudflared.nix
            ./modules/guests/headscale.nix
          ];
        };
      };

      # Standalone proof that the infra layer evaluates and builds with no
      # consumer flake involved. On a non-Linux machine, evaluate rather than
      # build:
      #   nix eval .#nixosConfigurations.infra-test.config.system.build.toplevel.drvPath
      nixosConfigurations.infra-test = lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.default
          ./checks/test-host.nix
        ];
      };

      checks.x86_64-linux.infra-test = self.nixosConfigurations.infra-test.config.system.build.toplevel;
    };
}
