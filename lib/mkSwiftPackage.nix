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
    if isDarwin then [ pkgs.apple-sdk_15 pkgs.libcxx pkgs.xcbuild ]
    else [ pkgs.stdenv.cc ];

  sdkRoot =
    if isDarwin then
      "${pkgs.apple-sdk_15}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    else null;

  # On Linux, manifest compilation uses SWIFT_EXEC_MANIFEST (see configurePhase).
  # Project compilation also needs the flags via -Xswiftc.
  platformSwiftcFlags =
    if isDarwin then [
      "-Xswiftc" "-sdk" "-Xswiftc" sdkRoot
    ] else [
      "-Xswiftc" "-Xcc" "-Xswiftc" "--gcc-toolchain=${pkgs.stdenv.cc.cc}"
      "-Xswiftc" "-Xcc" "-Xswiftc" "--sysroot=${pkgs.stdenv.cc.libc}"
      "-Xswiftc" "-Xclang-linker" "-Xswiftc" "--gcc-toolchain=${pkgs.stdenv.cc.cc}"
      "-Xswiftc" "-Xclang-linker" "-Xswiftc" "--sysroot=${pkgs.stdenv.cc.libc}"
    ];

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

  configurePhase = ''
    runHook preConfigure
    export HOME=$(mktemp -d)
  '' + swiftpmGenerated.configure
  + pkgs.lib.optionalString isDarwin ''
    export SDKROOT="${sdkRoot}"
    export LIBRARY_PATH="${pkgs.libcxx}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
    export MACOSX_DEPLOYMENT_TARGET="14.0"
    # Prevent stdenv CC wrapper paths from interfering with SwiftPM
    unset NIX_LDFLAGS NIX_CFLAGS_COMPILE
  ''
  + pkgs.lib.optionalString (!isDarwin) ''
    export C_INCLUDE_PATH="${pkgs.stdenv.cc.libc.dev}/include"
    export LIBRARY_PATH="${pkgs.stdenv.cc.libc}/lib:${pkgs.stdenv.cc.cc.lib}/lib"

    # SwiftPM resolves swiftc by absolute path from the swift binary's
    # location, ignoring PATH. Use SWIFT_EXEC_MANIFEST to override the
    # compiler used for Package.swift manifest compilation.
    _swiftix_wrappers=$(mktemp -d)
    _bash="$(command -v bash)"
    printf '#!%s\nexec "%s" -Xcc --gcc-toolchain=%s -Xcc --sysroot=%s -Xclang-linker --gcc-toolchain=%s -Xclang-linker --sysroot=%s "$@"\n' \
      "$_bash" "${swift}/bin/swiftc" "${pkgs.stdenv.cc.cc}" "${pkgs.stdenv.cc.libc}" "${pkgs.stdenv.cc.cc}" "${pkgs.stdenv.cc.libc}" \
      > "$_swiftix_wrappers/swiftc"
    chmod +x "$_swiftix_wrappers/swiftc"
    export SWIFT_EXEC_MANIFEST="$_swiftix_wrappers/swiftc"
    export PATH="$_swiftix_wrappers:$PATH"
  '' + ''
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    swift build ${builtins.concatStringsSep " " allFlags}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp .build/${buildConfig}/${executableName} $out/bin/
    runHook postInstall
  '';
})
