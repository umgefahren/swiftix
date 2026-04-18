{ pkgs, system, version, tag, sha256 }:

let
  isDarwin = pkgs.lib.hasSuffix "darwin" system;
  isLinux = !isDarwin;
  nixArch = if pkgs.lib.hasPrefix "aarch64" system then "aarch64" else "x86_64";

  # Linux: we bake a sysroot + wrapper into the toolchain so that `swift build`
  # and `swiftc` work out-of-the-box in plain devShells, without callers having
  # to replicate the sysroot setup from mkSwiftPackage.nix. The Swift.org
  # tarball expects a distro-style `/usr/{include,lib}` layout plus libgcc
  # crt files on the default linker search path — NixOS has neither.
  #
  # The wrapper injects:
  #   -sdk <sysroot>                  : tells Swift where SwiftGlibc / swiftrt.o live
  #   -Xcc --gcc-toolchain=<cc>       : clang finds crt*.o / libgcc_s
  #   -Xcc --sysroot=<sysroot>        : clang finds glibc headers
  #   -Xclang-linker --gcc-toolchain=<cc> -Xclang-linker --sysroot=<sysroot>
  #                                    : same for the link step
  linuxCC       = if isLinux then pkgs.stdenv.cc.cc       else null;
  linuxLibc     = if isLinux then pkgs.stdenv.cc.libc     else null;
  linuxLibcDev  = if isLinux then pkgs.stdenv.cc.libc.dev else null;

  # URL construction
  # Release category: "swift-6.3-release" from tag "swift-6.3-RELEASE"
  category = builtins.replaceStrings ["RELEASE"] ["release"] tag;

  # macOS
  darwinUrl = "https://download.swift.org/${category}/xcode/${tag}/${tag}-osx.pkg";

  # Linux — default to ubuntu24.04 for now
  linuxPlatform = "ubuntu2404" + (if nixArch == "aarch64" then "-aarch64" else "");
  linuxFileSuffix = "ubuntu24.04" + (if nixArch == "aarch64" then "-aarch64" else "");
  linuxUrl = "https://download.swift.org/${category}/${linuxPlatform}/${tag}/${tag}-${linuxFileSuffix}.tar.gz";

  url = if isDarwin then darwinUrl else linuxUrl;

  src = pkgs.fetchurl {
    inherit url sha256;
  };

  # The inner .pkg directory name follows this pattern
  innerPkg = "${tag}-osx-package.pkg";

in
pkgs.stdenv.mkDerivation {
  pname = "swift-toolchain";
  inherit version src;

  # Don't try to unpack automatically
  dontUnpack = true;

  nativeBuildInputs = if isDarwin then [
    pkgs.xar
    pkgs.cpio
    pkgs.darwin.sigtool
  ] else [
    pkgs.autoPatchelfHook
  ];

  buildInputs = pkgs.lib.optionals (!isDarwin) [
    pkgs.stdenv.cc.cc.lib  # libstdc++
    pkgs.ncurses
    pkgs.libedit
    pkgs.libxml2
    pkgs.curl
    pkgs.libuuid
    pkgs.zlib
    pkgs.sqlite
    pkgs.python312
  ];

  installPhase = if isDarwin then ''
    runHook preInstall

    # Extract the .pkg (xar archive)
    mkdir -p pkg_contents
    cd pkg_contents
    xar -xf $src

    # Extract the Payload (gzip'd cpio)
    mkdir -p $out
    cd $out
    zcat $NIX_BUILD_TOP/pkg_contents/${innerPkg}/Payload | cpio -id 2>/dev/null

    # Move usr/* to top level so we get $out/bin/swift etc.
    if [ -d "$out/usr" ]; then
      mv $out/usr/* $out/
      rmdir $out/usr
    fi

    runHook postInstall
  '' else ''
    runHook preInstall

    mkdir -p $out tmp_extract
    tar xzf $src --strip-components=2 --no-same-owner -C tmp_extract
    cp -a tmp_extract/* $out/
    rm -rf tmp_extract

    runHook postInstall
  '';

  # On Linux, set up search paths and compat symlinks before autoPatchelfHook runs
  preFixup = pkgs.lib.optionalString (!isDarwin) ''
    # Add the toolchain's own lib directories so bundled Swift
    # runtime libraries are found by autoPatchelfHook.
    addAutoPatchelfSearchPath $out/lib
    addAutoPatchelfSearchPath $out/lib/swift/linux

    # The Ubuntu-built binaries expect Ubuntu sonames which differ from
    # nixpkgs. Create a compat directory with symlinks.
    mkdir -p $out/lib/compat
    # Point Ubuntu sonames to the actual nixpkgs shared libraries.
    # The Ubuntu binaries expect libxml2.so.2 and libedit.so.2, but nixpkgs
    # has different soname versions (libxml2.so.16, libedit.so.0).
    ln -sf "$(ls ${pkgs.libxml2.out}/lib/libxml2.so.* | head -1)" $out/lib/compat/libxml2.so.2
    ln -sf "$(ls ${pkgs.libedit.out}/lib/libedit.so.* | head -1)" $out/lib/compat/libedit.so.2
    addAutoPatchelfSearchPath $out/lib/compat
  '';

  postFixup = if isLinux then ''
    # --- Linux: bake in a sysroot + wrapper so `swift build` works on NixOS ---
    #
    # The Swift.org Linux tarball is built expecting a distro where
    # /usr/lib/x86_64-linux-gnu/Scrt1.o, libgcc_s, etc. exist on the default
    # search path. NixOS has none of this; glibc lives at ${linuxLibc}/lib
    # and libgcc_s at ${linuxCC.lib}/lib. Without help, Swift's embedded
    # clang-driven link step fails with "cannot open Scrt1.o" and friends.
    #
    # We construct a sysroot that stitches together glibc + Swift runtime
    # in the directory layout Swift's driver / glibc.modulemap expect, then
    # wrap `swift` and `swiftc` so every invocation picks it up.

    # 1. Build the sysroot inside the toolchain.
    mkdir -p "$out/sysroot/usr/lib"
    ln -s ${linuxLibcDev}/include "$out/sysroot/usr/include"
    for f in ${linuxLibc}/lib/*; do
      ln -sf "$f" "$out/sysroot/usr/lib/"
    done
    ln -sf "$out/lib/swift" "$out/sysroot/usr/lib/swift"
    ln -sf ${linuxLibc}/lib "$out/sysroot/lib"

    # Provide a plain `ld` at $out/bin/ld (nixpkgs binutils). Swift's
    # link step goes swiftc → clang → ld; clang searches for ld first
    # on PATH (not in --gcc-toolchain, since raw gcc doesn't ship ld),
    # and in a bare devShell the only PATH entry is $out/bin. Without
    # this, link fails with `Executable "ld" doesn't exist!`.
    ln -sf ${pkgs.binutils-unwrapped}/bin/ld "$out/bin/ld"

    # 2. Install a shell wrapper for swiftc that exec's swift-driver under
    #    argv[0]=swiftc with our sysroot flags prepended. We deliberately do
    #    NOT wrap `swift` — `swift <subcommand>` (e.g. `swift build`, `swift
    #    package`) dispatches on the first argument, and injecting flags
    #    before it would break that.
    #
    #    SwiftPM compiles Package.swift manifests by invoking swiftc via
    #    absolute path, so wrapping swiftc is enough to get the manifest
    #    build working. For user-source compilation, SwiftPM forks swiftc
    #    again, also picked up here.
    rm -f "$out/bin/swiftc"
    cat > "$out/bin/swiftc" <<EOF
    #!${pkgs.runtimeShell}
    # swiftix-injected wrapper: feed swift-driver our NixOS sysroot +
    # gcc-toolchain so Swift's embedded clang/linker can find crt*.o, libc
    # headers, and libgcc_s (the last lives in cc.lib, which --gcc-toolchain
    # alone does not cover — hence the explicit -L).
    #
    # Some integrated tool modes (notably -modulewrap, -frontend, repl) must
    # receive their trigger flag as argv[1]; injecting -sdk before them would
    # cause swift-driver to reject the invocation. Pass those through bare.
    case "\''${1:-}" in
      -modulewrap|-frontend|-repl|repl|--driver-mode=*)
        exec -a swiftc "$out/bin/swift-driver" "\$@"
        ;;
    esac
    exec -a swiftc "$out/bin/swift-driver" \\
      -sdk "$out/sysroot" \\
      -Xcc --gcc-toolchain=${linuxCC} \\
      -Xcc --sysroot="$out/sysroot" \\
      -Xclang-linker --gcc-toolchain=${linuxCC} \\
      -Xclang-linker --sysroot="$out/sysroot" \\
      -Xclang-linker -Wl,--dynamic-linker=${pkgs.stdenv.cc.bintools.dynamicLinker} \\
      -L${linuxCC.lib}/lib \\
      -Xclang-linker -L${linuxCC.lib}/lib \\
      "\$@"
    EOF
    chmod +x "$out/bin/swiftc"

    # 3. Setup hook: sourced automatically when the toolchain is in a shell's
    #    buildInputs / nativeBuildInputs (and by mkShell). SwiftPM uses $CC
    #    for C sources; stdenv would point that at gcc, which doesn't accept
    #    the clang flags Swift emits (-target, -fblocks, ...). Override it
    #    to our bundled clang.
    #
    #    Because stdenv's cc-wrapper sets CC=gcc from its own setup-hook, we
    #    register our override through a preConfigureHook so it runs *after*
    #    all buildInput setup-hooks have executed. For interactive devShells
    #    (where configure never runs), we additionally append to shellHook
    #    via the NIX_SWIFTIX_CC_OVERRIDE mechanism.
    mkdir -p "$out/nix-support"
    cat > "$out/nix-support/setup-hook" <<HOOK
    _swiftix_cc_override() {
      export CC="$out/bin/clang"
      export CXX="$out/bin/clang++"
    }
    preConfigureHooks+=(_swiftix_cc_override)
    # Also run immediately (handles devShells, which source setup-hooks but
    # never invoke preConfigureHooks). Safe to run twice.
    _swiftix_cc_override
    HOOK
  '' else if isDarwin then ''
    # Make the toolchain work in pure Nix environments (sandbox):
    # swiftc's bundled clang invokes its co-located "ld" to link.
    # The toolchain ships LLD but its ld64 personality doesn't support
    # the macOS platform version on this system. Replace with nixpkgs'
    # ld64 from cctools which is a proper Apple-compatible linker.
    rm -f $out/bin/ld
    ln -s ${pkgs.darwin.binutils-unwrapped}/bin/ld $out/bin/ld

    # SwiftPM hardcodes /usr/bin/xcrun which doesn't exist in the Nix
    # sandbox. Binary-patch all SwiftPM binaries to use "xcrun" (PATH
    # lookup) instead. This is the same fix nixpkgs applies to their
    # SwiftPM source before compiling (sed 's|/usr/bin/xcrun|xcrun|g').
    # We null-pad to keep the same byte length.
    for bin in $out/bin/swift-build $out/bin/swift-package $out/bin/swift-run $out/bin/swift-test $out/bin/swift-plugin-server; do
      if [ -f "$bin" ]; then
        sed -i "s|/usr/bin/xcrun|xcrun\x00\x00\x00\x00\x00\x00\x00\x00\x00|g" "$bin"
        # Re-sign after patching — macOS kills binaries with invalid signatures
        codesign -fs - "$bin"
      fi
    done

    # Provide xcrun (from xcbuild) and libtool/vtool (from cctools) so
    # SwiftPM can find them via PATH lookup after the binary patch above.
    ln -sf ${pkgs.xcbuild}/bin/xcrun $out/bin/xcrun
    ln -sf ${pkgs.darwin.cctools}/bin/libtool $out/bin/libtool
    ln -sf ${pkgs.darwin.cctools}/bin/vtool $out/bin/vtool

    # Setup hook: add libcxx to LIBRARY_PATH. Swift's Darwin back-compat
    # shims (libswiftCompatibility56.a and friends) pull in `operator new`
    # / `operator delete` from libc++. Swift's driver auto-links `-lc++`
    # but relies on a default system library path to resolve it — macOS
    # has that path, nixpkgs doesn't. libc++ lives at ${pkgs.libcxx}/lib
    # under Nix. Without this, bare `swift build` fails at link time with
    # "Could not find or use auto-linked library 'c++'".
    mkdir -p "$out/nix-support"
    cat > "$out/nix-support/setup-hook" <<'HOOK'
    _swiftix_darwin_libs() {
      export LIBRARY_PATH="${pkgs.libcxx}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
    }
    preConfigureHooks+=(_swiftix_darwin_libs)
    # Also run immediately for interactive devShells, which source setup
    # hooks but never invoke preConfigureHooks. Idempotent — re-export is
    # fine (LIBRARY_PATH is a colon list, but we only add one entry).
    _swiftix_darwin_libs
    HOOK
  '' else "";

  meta = with pkgs.lib; {
    description = "Swift ${version} toolchain";
    homepage = "https://swift.org";
    license = licenses.asl20;
    platforms = if isDarwin then platforms.darwin else platforms.linux;
  };
}
