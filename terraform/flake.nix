{
  description = "Terraform flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let pkgs = import nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; };
    in {
      pkgs.config = {
        allowUnfree = true;
      };

      devShells.x86_64-linux.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          terraform
        ];
      };
    };
}
