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

  # On Linux, flags are injected via wrapper scripts (see configurePhase)
  # so SwiftPM's internal manifest compilation also gets them.
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

    # SwiftPM internally compiles Package.swift manifests using swiftc
    # directly, bypassing our -Xswiftc flags. Create wrapper scripts that
    # inject --gcc-toolchain and --sysroot so the bundled clang can always
    # find glibc CRT files and GCC support libraries.
    _swiftix_wrappers=$(mktemp -d)
    for bin in swift swiftc; do
      cat > "$_swiftix_wrappers/$bin" <<WRAPPER
    #!/bin/bash
    exec "${swift}/bin/$bin" \
      -Xcc --gcc-toolchain=${pkgs.stdenv.cc.cc} \
      -Xcc --sysroot=${pkgs.stdenv.cc.libc} \
      -Xclang-linker --gcc-toolchain=${pkgs.stdenv.cc.cc} \
      -Xclang-linker --sysroot=${pkgs.stdenv.cc.libc} \
      "\$@"
    WRAPPER
      chmod +x "$_swiftix_wrappers/$bin"
    done
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
