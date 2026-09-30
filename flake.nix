{
  description = "Qt1 infrastructure: microVM host layer, guests and services";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
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

        # No `inputs` specialArg: `microvm` is closed over here, so consumers
        # don't need to carry it.
        microvmHost = {
          imports = [
            microvm.nixosModules.host
            ./modules/microvm-host.nix
            ./modules/tailscale-client.nix
            ./modules/guests/headscale.nix
            ./modules/guests/caddy.nix
            ./modules/guests/caddy-internal.nix
            ./modules/crowdsec.nix
            ./modules/guests/monitoring.nix
            ./modules/guests/gatus.nix
          ];
        };
      };

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
