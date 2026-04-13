# Build a SwiftPM project with swiftix.
#
# Usage:
#   mkSwiftPackage {
#     pname = "my-app";
#     version = "1.0.0";
#     src = ./.;
#     swift = swiftix.packages.${system}.swift-6_3;
#     swiftpmGenerated = swiftpm2nix.helpers ./nix;
#     executableName = "MyApp";  # optional, defaults to pname
#   }
{ pkgs }:

{
  pname,
  version,
  src,
  swift,
  swiftpmGenerated,
  executableName ? pname,
  buildConfig ? "release",
  swiftFlags ? [],
  ...
} @ args:

let
  isDarwin = pkgs.lib.hasSuffix "darwin" pkgs.system;

  platformDeps =
    if isDarwin then [ pkgs.apple-sdk_15 pkgs.libcxx ]
    else [ pkgs.stdenv.cc ];

  sdkRoot =
    if isDarwin then
      "${pkgs.apple-sdk_15}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    else null;

  darwinArch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64";

  platformSwiftcFlags =
    if isDarwin then [
      "-Xswiftc" "-sdk" "-Xswiftc" sdkRoot
    ] else [];

  extraFlags = map (f: toString f) swiftFlags;

  allFlags = [ "-c" buildConfig "--skip-update" "--disable-sandbox" ]
    ++ platformSwiftcFlags
    ++ extraFlags;

  # Remove our custom attrs before passing to mkDerivation
  cleanArgs = builtins.removeAttrs args [
    "swift" "swiftpmGenerated" "executableName" "buildConfig" "swiftFlags"
  ];

in
pkgs.stdenv.mkDerivation (cleanArgs // {
  inherit pname version src;

  nativeBuildInputs = [ swift ] ++ platformDeps
    ++ (args.nativeBuildInputs or []);

  # Set deployment target at derivation level so it's available in all phases.
  # SwiftPM reads this to set the -target triple version.
  MACOSX_DEPLOYMENT_TARGET = pkgs.lib.optionalString isDarwin "14.0";

  configurePhase = ''
    runHook preConfigure
    export HOME="$(mktemp -d)"
  '' + swiftpmGenerated.configure
  + pkgs.lib.optionalString isDarwin ''
    export SDKROOT="${sdkRoot}"
    export LIBRARY_PATH="${pkgs.libcxx}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
    # Prevent stdenv CC wrapper (gcc) from interfering with SwiftPM
    unset NIX_LDFLAGS NIX_CFLAGS_COMPILE CC CXX

    # SwiftPM manifest compilation ignores MACOSX_DEPLOYMENT_TARGET on some
    # CI builders. Use SWIFT_EXEC_MANIFEST to inject -target with a version.
    _swiftix_wrappers=$(mktemp -d)
    _bash="$(command -v bash)"
    printf '#!%s\nexec "%s" -target ${darwinArch}-apple-macosx14.0 "$@"\n' \
      "$_bash" "${swift}/bin/swiftc" \
      > "$_swiftix_wrappers/swiftc"
    chmod +x "$_swiftix_wrappers/swiftc"
    export SWIFT_EXEC_MANIFEST="$_swiftix_wrappers/swiftc"
  ''
  + pkgs.lib.optionalString (!isDarwin) ''
    export C_INCLUDE_PATH="${pkgs.stdenv.cc.libc.dev}/include"
    export LIBRARY_PATH="${pkgs.stdenv.cc.libc}/lib:${pkgs.stdenv.cc.cc.lib}/lib"
    # SwiftPM uses CC for C compilation. stdenv sets CC=gcc which doesn't
    # understand clang flags like -target and -fblocks. Use toolchain's clang.
    export CC="${swift}/bin/clang"

    # Create a sysroot with the directory layout Swift expects.
    # Swift's glibc.modulemap hardcodes /usr/include paths, the Swift
    # driver uses the sysroot (-sdk) to detect glibc for SwiftGlibc,
    # and it also looks for swiftrt.o under $SDK/usr/lib/swift/.
    _sysroot=$(mktemp -d)
    mkdir -p "$_sysroot/usr/lib"
    ln -s ${pkgs.stdenv.cc.libc.dev}/include "$_sysroot/usr/include"
    # Symlink glibc lib contents (not the directory itself, so we can
    # also add the Swift runtime alongside)
    for f in ${pkgs.stdenv.cc.libc}/lib/*; do
      ln -sf "$f" "$_sysroot/usr/lib/"
    done
    ln -sf ${swift}/lib/swift "$_sysroot/usr/lib/swift"
    ln -sf ${pkgs.stdenv.cc.libc}/lib "$_sysroot/lib"

    # SwiftPM resolves swiftc by absolute path from the swift binary,
    # ignoring PATH. Use SWIFT_EXEC_MANIFEST to override the compiler
    # for Package.swift manifest compilation. The wrapper injects:
    # - -sdk: so Swift finds SwiftGlibc module
    # - -Xcc --gcc-toolchain/--sysroot: so clang finds CRT files and headers
    # - -Xclang-linker: same for the link step
    _swiftix_wrappers=$(mktemp -d)
    _bash="$(command -v bash)"
    printf '#!%s\nexec "%s" -sdk %s -Xcc --gcc-toolchain=%s -Xcc --sysroot=%s -Xclang-linker --gcc-toolchain=%s -Xclang-linker --sysroot=%s "$@"\n' \
      "$_bash" "${swift}/bin/swiftc" "$_sysroot" "${pkgs.stdenv.cc.cc}" "$_sysroot" "${pkgs.stdenv.cc.cc}" "$_sysroot" \
      > "$_swiftix_wrappers/swiftc"
    chmod +x "$_swiftix_wrappers/swiftc"
    export SWIFT_EXEC_MANIFEST="$_swiftix_wrappers/swiftc"
    export PATH="$_swiftix_wrappers:$PATH"
  '' + ''
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    swift build ${builtins.concatStringsSep " " allFlags} \
  '' + pkgs.lib.optionalString (!isDarwin) ''
      -Xswiftc -sdk -Xswiftc $_sysroot \
      -Xswiftc -Xcc -Xswiftc --gcc-toolchain=${pkgs.stdenv.cc.cc} \
      -Xswiftc -Xcc -Xswiftc --sysroot=$_sysroot \
      -Xswiftc -Xclang-linker -Xswiftc --gcc-toolchain=${pkgs.stdenv.cc.cc} \
      -Xswiftc -Xclang-linker -Xswiftc --sysroot=$_sysroot \
  '' + ''

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp .build/${buildConfig}/${executableName} $out/bin/
    runHook postInstall
  '';
})
