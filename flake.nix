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
      #
      # Every check exercises the toolchain in the same shape the README
      # quick-start documents: `buildInputs = [ swift ]` (plus apple-sdk_15
      # on Darwin, whose setup-hook sets SDKROOT — required in the sandbox).
      # No manual -sdk / -Xcc / C_INCLUDE_PATH / LIBRARY_PATH / CC glue.
      # If a check needs glue to pass, that glue belongs inside the toolchain,
      # not inside the check — otherwise CI silently masks regressions in
      # the documented experience.
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          isDarwin = pkgs.lib.hasSuffix "darwin" system;
          nixArch = if pkgs.lib.hasPrefix "aarch64" system then "aarch64" else "x86_64";

          # Only apple-sdk_15 on Darwin. Nothing on Linux — the Linux fix
          # bakes sysroot, swiftc wrapper, and CC setup-hook into the toolchain.
          bareInputs = pkgs.lib.optional isDarwin pkgs.apple-sdk_15;

          # HOME must be writable for swiftc's clang module cache; sandbox
          # sets HOME=/homeless-shelter. Not toolchain glue — it's a sandbox
          # quirk every Nix derivation hits.
          writableHome = ''
            export HOME=$(mktemp -d)
          '';

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
                buildInputs = [ swift ] ++ bareInputs;
              } ''
                swift --version
                swiftc --version
                touch $out
              '';

              "compile-${safeName}" = pkgs.runCommand "swiftix-check-compile-${safeName}" {
                buildInputs = [ swift ] ++ bareInputs;
              } (writableHome + ''
                cat > hello.swift << 'EOF'
                print("Hello from swiftix!")
                let x = (1...10).reduce(0, +)
                guard x == 55 else { fatalError("math is broken") }
                print("Sum 1..10 = \(x)")
                EOF
                swiftc -o hello hello.swift
                ./hello | grep -q "Hello from swiftix"
                touch $out
              '');

              "interpret-${safeName}" = pkgs.runCommand "swiftix-check-interpret-${safeName}" {
                buildInputs = [ swift ] ++ bareInputs;
              } (writableHome + ''
                echo 'print("interpreted!")' | swift - 2>&1 | grep -q "interpreted"
                touch $out
              '');
            };

          # Bare `swift build` against a minimal SwiftPM package on the latest
          # toolchain. This is the path that regressed on Linux — SwiftPM
          # manifest compilation invokes swiftc via absolute path, so the
          # baked-in wrapper must kick in without caller-provided flags.
          swiftpmCheck =
            let
              swift = self.packages.${system}.latest;
            in {
              "swiftpm-build" = pkgs.runCommand "swiftix-check-swiftpm-build" {
                buildInputs = [ swift ] ++ bareInputs;
              } (writableHome + ''
                mkdir pkg && cd pkg
                cat > Package.swift << 'EOF'
                // swift-tools-version:5.9
                import PackageDescription
                let package = Package(
                    name: "hello",
                    targets: [ .executableTarget(name: "hello") ]
                )
                EOF
                mkdir -p Sources/hello
                echo 'print("hi from swiftpm")' > Sources/hello/main.swift
                swift build -c release --disable-sandbox --skip-update
                ./.build/release/hello | grep -q "hi from swiftpm"
                touch $out
              '');
            };

        in builtins.foldl' (acc: release: acc // mkChecks release) {} releaseData
           // swiftpmCheck
      );
    };
}
