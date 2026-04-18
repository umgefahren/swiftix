{
  description = "Swift toolchains as Nix packages (like fenix, but for Swift)";

  nixConfig = {
    extra-substituters = [ "https://cache.garnix.io" ];
    extra-trusted-public-keys = [ "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=" ];
  };

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

      # Load release data (versions + hashes), sorted newest-first.
      # The Swift release API (and therefore update.sh output) is oldest-first;
      # `latest`/`default` rely on head-of-list, so we sort here to be robust
      # against whatever order the file happens to be written in.
      releaseData =
        let raw = builtins.fromJSON (builtins.readFile ./data/releases.json);
        in builtins.sort (a: b: nixpkgs.lib.versionOlder b.version a.version) raw;

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
          # swiftpm2nix CLI tool
          swiftpm2nix = pkgs.callPackage ./lib/swiftpm2nix { };
        }
      );

      # Builder functions for SwiftPM projects.
      # Usage: swiftix.lib.mkSwiftPackage { inherit pkgs; } { pname = ...; }
      lib = {
        mkSwiftPackage = import ./lib/mkSwiftPackage.nix;
        swiftpm2nixHelpers = { pkgs }: (pkgs.callPackage ./lib/swiftpm2nix/support.nix { }).helpers;
      };

      # Overlay for use with nixpkgs
      overlays.default = final: prev: {
        swiftix = self.packages.${prev.system};
      };

      # Checks: run via `nix flake check`
      # Generates version/compile/interpret checks for every toolchain.
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          isDarwin = pkgs.lib.hasSuffix "darwin" system;
          nixArch = if pkgs.lib.hasPrefix "aarch64" system then "aarch64" else "x86_64";

          # Platform-specific dependencies and flags for compilation checks
          checkDeps =
            if isDarwin then [ pkgs.apple-sdk_15 ]
            else [ pkgs.stdenv.cc pkgs.stdenv.cc.libc pkgs.stdenv.cc.libc.dev ];

          swiftcFlags =
            if isDarwin then
              "-sdk ${pkgs.apple-sdk_15}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
            else builtins.concatStringsSep " " [
              "-Xcc --gcc-toolchain=${pkgs.stdenv.cc.cc}"
              "-Xcc --sysroot=${pkgs.stdenv.cc.libc}"
              "-Xclang-linker --gcc-toolchain=${pkgs.stdenv.cc.cc}"
              "-Xclang-linker --sysroot=${pkgs.stdenv.cc.libc}"
            ];

          # Ensure HOME is writable — CI sandboxes set HOME=/homeless-shelter
          # which isn't writable, causing swiftc's clang module cache to fail.
          envSetup = ''
            export HOME=$(mktemp -d)
          '' + pkgs.lib.optionalString (!isDarwin) ''
            export C_INCLUDE_PATH="${pkgs.stdenv.cc.libc.dev}/include"
            export LIBRARY_PATH="${pkgs.stdenv.cc.libc}/lib:${pkgs.stdenv.cc.cc.lib}/lib"
          '';

          # Generate checks for a single toolchain
          mkChecks = release:
            let
              systemKey =
                if isDarwin then "macOS"
                else if nixArch == "x86_64" then "linux-x86_64"
                else "linux-aarch64";
              hash = release.hashes.${systemKey} or null;
              safeName = builtins.replaceStrings ["."] ["_"] release.version;
              swift = self.packages.${system}.${"swift-" + safeName};
            in
            pkgs.lib.optionalAttrs (hash != null) {
              "version-${safeName}" = pkgs.runCommand "swiftix-check-version-${safeName}" {
                buildInputs = checkDeps;
              } ''
                ${swift}/bin/swift --version
                ${swift}/bin/swiftc --version
                touch $out
              '';

              "compile-${safeName}" = pkgs.runCommand "swiftix-check-compile-${safeName}" {
                buildInputs = checkDeps;
              } (envSetup + ''
                cat > hello.swift << 'EOF'
                print("Hello from swiftix!")
                let x = (1...10).reduce(0, +)
                guard x == 55 else { fatalError("math is broken") }
                print("Sum 1..10 = \(x)")
                EOF
                ${swift}/bin/swiftc ${swiftcFlags} -o hello hello.swift
                ./hello | grep -q "Hello from swiftix"
                touch $out
              '');

              "interpret-${safeName}" = pkgs.runCommand "swiftix-check-interpret-${safeName}" {
                buildInputs = checkDeps;
              } (envSetup + ''
                echo 'print("interpreted!")' | ${swift}/bin/swift ${swiftcFlags} - 2>&1 | grep -q "interpreted"
                touch $out
              '');
            };

          # Build the example project with the latest Swift
          exampleCheck =
            let
              swift = self.packages.${system}.latest;
              mkSwiftPackage = self.lib.mkSwiftPackage { inherit pkgs; };
              swiftpm2nixHelpers = self.lib.swiftpm2nixHelpers { inherit pkgs; };
            in {
              "example" = mkSwiftPackage {
                pname = "example-app";
                version = "0.1.0";
                src = ./example;
                inherit swift;
                swiftpmGenerated = swiftpm2nixHelpers ./example/nix;
                executableName = "ExampleApp";
              };
            };

        in builtins.foldl' (acc: release: acc // mkChecks release) {} releaseData
           // exampleCheck
      );
    };
}
