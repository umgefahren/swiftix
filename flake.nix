{
  description = "Swift toolchains as Nix packages (like fenix, but for Swift)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Systems we support
      darwinSystems = [ "aarch64-darwin" "x86_64-darwin" ];
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      allSystems = darwinSystems ++ linuxSystems;

      forAllSystems = f: nixpkgs.lib.genAttrs allSystems f;

      # Load release data (versions + hashes)
      releaseData = builtins.fromJSON (builtins.readFile ./data/releases.json);

      # Import toolchain builder
      mkToolchain = import ./lib/mkToolchain.nix;

    in {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          isDarwin = pkgs.lib.hasSuffix "darwin" system;
          isLinux = pkgs.lib.hasSuffix "linux" system;

          nixArch = if pkgs.lib.hasPrefix "aarch64" system then "aarch64" else "x86_64";

          # Build a package set from all releases that have a hash for this system
          toolchains = builtins.listToAttrs (
            builtins.concatMap (release:
              let
                systemKey =
                  if isDarwin then "macOS"
                  else if nixArch == "x86_64" then "linux-x86_64"
                  else "linux-aarch64";
                hash = release.hashes.${systemKey} or null;
                safeName = "swift-" + builtins.replaceStrings ["."] ["_"] release.version;
              in
              if hash != null then [{
                name = safeName;
                value = mkToolchain {
                  inherit pkgs system;
                  inherit (release) version tag;
                  sha256 = hash;
                };
              }] else []
            ) releaseData
          );

          # Find latest version
          latestRelease = builtins.head releaseData;
          latestName = "swift-" + builtins.replaceStrings ["."] ["_"] latestRelease.version;
        in
        toolchains // {
          # Alias: latest points to the newest release
          latest = toolchains.${latestName} or (builtins.throw "No toolchain available for ${system}");
          default = toolchains.${latestName} or (builtins.throw "No toolchain available for ${system}");
        }
      );

      # Overlay for use with nixpkgs
      overlays.default = final: prev: {
        swiftix = self.packages.${prev.system};
      };

      # Checks: run via `nix flake check`
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          isDarwin = pkgs.lib.hasSuffix "darwin" system;
          # Test against the latest available toolchain
          swift = self.packages.${system}.latest;

          # macOS needs the SDK for compilation/linking
          sdkDeps = pkgs.lib.optionals isDarwin [ pkgs.apple-sdk_15 ];
          sdkFlags = pkgs.lib.optionalString isDarwin
            "-sdk ${pkgs.apple-sdk_15}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
        in {
          # Smoke test: key binaries respond to --version
          version = pkgs.runCommand "swiftix-check-version" {
            buildInputs = sdkDeps;
          } ''
            ${swift}/bin/swift --version
            ${swift}/bin/swiftc --version
            touch $out
          '';

          # Compile and run a Swift program
          compile = pkgs.runCommand "swiftix-check-compile" {
            buildInputs = sdkDeps;
          } ''
            cat > hello.swift << 'EOF'
            print("Hello from swiftix!")
            let x = (1...10).reduce(0, +)
            guard x == 55 else { fatalError("math is broken") }
            print("Sum 1..10 = \(x)")
            EOF
            ${swift}/bin/swiftc ${sdkFlags} -o hello hello.swift
            ./hello | grep -q "Hello from swiftix"
            touch $out
          '';

          # Verify the REPL / interpreter mode works
          interpret = pkgs.runCommand "swiftix-check-interpret" {
            buildInputs = sdkDeps;
          } ''
            echo 'print("interpreted!")' | ${swift}/bin/swift ${sdkFlags} - 2>&1 | grep -q "interpreted"
            touch $out
          '';
        }
      );
    };
}
