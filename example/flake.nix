{
  description = "Example Swift project built with swiftix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    swiftix.url = "github:stillwind-ai/swiftix";
  };

  outputs = { self, nixpkgs, swiftix, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          mkSwiftPackage = swiftix.lib.mkSwiftPackage { inherit pkgs; };
          swiftpm2nixHelpers = swiftix.lib.swiftpm2nixHelpers { inherit pkgs; };
        in {
          default = mkSwiftPackage {
            pname = "example-app";
            version = "0.1.0";
            src = ./.;
            swift = swiftix.packages.${system}.swift-6_3;
            swiftpmGenerated = swiftpm2nixHelpers ./nix;
            executableName = "ExampleApp";
          };
        }
      );

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          isDarwin = pkgs.lib.hasSuffix "darwin" system;
          swift = swiftix.packages.${system}.swift-6_3;
        in {
          default = pkgs.mkShell {
            packages = [ swift ]
              ++ pkgs.lib.optionals isDarwin [ pkgs.apple-sdk_15 ]
              ++ pkgs.lib.optionals (!isDarwin) [ pkgs.stdenv.cc ];

            shellHook = pkgs.lib.optionalString isDarwin ''
              export SDKROOT="${pkgs.apple-sdk_15}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
            '' + pkgs.lib.optionalString (!isDarwin) ''
              export C_INCLUDE_PATH="${pkgs.stdenv.cc.libc.dev}/include"
              export LIBRARY_PATH="${pkgs.stdenv.cc.libc}/lib:${pkgs.stdenv.cc.cc.lib}/lib"
            '';
          };
        }
      );
    };
}
