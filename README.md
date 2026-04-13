# swiftix

[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fstillwind-ai%2Fswiftix)](https://garnix.io/repo/stillwind-ai/swiftix)


Swift toolchains as Nix packages. Like [fenix](https://github.com/nix-community/fenix) for Rust, but for Swift.

Downloads prebuilt toolchains from [swift.org](https://swift.org/download/) and makes them available as Nix packages with all native dependencies patched for NixOS and macOS.

## Supported platforms

| Platform | Architectures |
|---|---|
| macOS | aarch64, x86_64 |
| Linux (Ubuntu 24.04) | x86_64, aarch64 |

## Available toolchains

| Package | Version |
|---|---|
| `swift-6_3` | 6.3 (latest) |
| `swift-6_2_4` | 6.2.4 |
| `swift-6_1_3` | 6.1.3 |
| `swift-6_0_3` | 6.0.3 |
| `swift-5_10_1` | 5.10.1 |

`latest` and `default` are aliases for the newest version.

## Quick start

Run Swift without installing anything:

```sh
nix run github:stillwind-ai/swiftix -- --version
```

Or drop into a shell with a specific version:

```sh
nix shell github:stillwind-ai/swiftix#swift-6_2_4
swift --version
```

## Using in a project

### Dev shell (flake.nix)

The simplest way to use swiftix in your Swift project:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    swiftix.url = "github:stillwind-ai/swiftix";
  };

  outputs = { nixpkgs, swiftix, ... }:
    let
      system = "aarch64-darwin"; # or x86_64-linux, aarch64-linux, x86_64-darwin
      pkgs = nixpkgs.legacyPackages.${system};
      swift = swiftix.packages.${system}.latest;
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [ swift ];
      };
    };
}
```

Then run `nix develop` to enter a shell with Swift available.

### Multi-platform dev shell

For a flake that works across all supported systems:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    swiftix.url = "github:stillwind-ai/swiftix";
  };

  outputs = { nixpkgs, swiftix, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          swift = swiftix.packages.${system}.latest;
        in {
          default = pkgs.mkShell {
            packages = [ swift ];
          };
        }
      );
    };
}
```

### Pinning a specific version

Replace `latest` with any available package name:

```nix
swift = swiftix.packages.${system}.swift-6_1_3;
```

### Using the overlay

You can add swiftix to your nixpkgs as an overlay:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    swiftix.url = "github:stillwind-ai/swiftix";
  };

  outputs = { nixpkgs, swiftix, ... }:
    let
      pkgs = import nixpkgs {
        system = "aarch64-darwin";
        overlays = [ swiftix.overlays.default ];
      };
    in {
      devShells.aarch64-darwin.default = pkgs.mkShell {
        packages = [ pkgs.swiftix.latest ];
      };
    };
}
```

## Linux usage notes

On Linux, swiftc's bundled clang needs to know where to find the system C library and GCC support files. When compiling Swift code, pass these flags:

```nix
pkgs.mkShell {
  packages = [ swift ];
  buildInputs = [ pkgs.stdenv.cc ];

  shellHook = ''
    export C_INCLUDE_PATH="${pkgs.stdenv.cc.libc.dev}/include"
    export LIBRARY_PATH="${pkgs.stdenv.cc.libc}/lib:${pkgs.stdenv.cc.cc.lib}/lib"
  '';
}
```

Or pass the flags directly to `swiftc`:

```sh
swiftc \
  -Xcc --gcc-toolchain=$NIX_CC/.. \
  -Xcc --sysroot=$NIX_CC/../lib \
  -Xclang-linker --gcc-toolchain=$NIX_CC/.. \
  -Xclang-linker --sysroot=$NIX_CC/../lib \
  -o hello hello.swift
```

On macOS, you may need to pass `-sdk` pointing to the macOS SDK if not using Xcode's default:

```sh
swiftc -sdk $(xcrun --show-sdk-path) -o hello hello.swift
```

## Building a SwiftPM project with `mkSwiftPackage`

swiftix provides `mkSwiftPackage` — a builder that handles all platform-specific toolchain wiring (SDK paths, linker flags, sandbox workarounds) so you can build SwiftPM projects as Nix derivations with reproducible, pre-fetched dependencies.

### Step 1: Resolve dependencies

In your Swift project, resolve dependencies to generate `.build/workspace-state.json`:

```sh
swift package resolve
```

### Step 2: Generate Nix dependency files

Run `swiftpm2nix` (included with swiftix) to create fixed-output derivation expressions from the resolved dependencies:

```sh
nix run github:stillwind-ai/swiftix#swiftpm2nix
```

This creates a `nix/` directory with `default.nix` (hashes) and `workspace-state.json`. Commit these files.

### Step 3: Write your flake.nix

```nix
{
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
            pname = "my-app";
            version = "1.0.0";
            src = ./.;
            swift = swiftix.packages.${system}.swift-6_3;
            swiftpmGenerated = swiftpm2nixHelpers ./nix;
            executableName = "MyApp"; # name of the executable target
          };
        }
      );
    };
}
```

Then build with `nix build`.

### `mkSwiftPackage` options

| Option | Default | Description |
|---|---|---|
| `pname` | required | Package name |
| `version` | required | Package version |
| `src` | required | Source directory |
| `swift` | required | Swift toolchain from swiftix |
| `swiftpmGenerated` | required | Output of `swiftpm2nix.helpers ./nix` |
| `executableName` | `pname` | Name of the SwiftPM executable target |
| `buildConfig` | `"release"` | `"release"` or `"debug"` |
| `swiftFlags` | `[]` | Extra flags passed to `swift build` |

All other attributes are passed through to `mkDerivation`.

### Full example

See the [`example/`](./example) directory for a complete SwiftPM project using `swift-argument-parser`, `swift-algorithms`, and `swift-log` from Apple.

## Dev shell for SwiftPM projects

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    swiftix.url = "github:stillwind-ai/swiftix";
  };

  outputs = { nixpkgs, swiftix, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      swift = swiftix.packages.${system}.latest;
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          swift
        ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
          pkgs.apple-sdk_15
        ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
          pkgs.stdenv.cc
        ];

        shellHook = pkgs.lib.optionalString pkgs.stdenv.isLinux ''
          export C_INCLUDE_PATH="${pkgs.stdenv.cc.libc.dev}/include"
          export LIBRARY_PATH="${pkgs.stdenv.cc.libc}/lib:${pkgs.stdenv.cc.cc.lib}/lib"
        '';
      };
    };
}
```

## CI with Garnix

swiftix includes checks for every toolchain version. If you use [Garnix](https://garnix.io), add the flake input and the checks will run automatically.

## Adding new Swift versions

Run the update script to fetch the latest releases and prefetch hashes:

```sh
./update.sh           # update all versions
./update.sh 6.4       # update only a specific version
```

## License

Apache 2.0
