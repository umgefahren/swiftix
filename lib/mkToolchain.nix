{ pkgs, system, version, tag, sha256 }:

let
  isDarwin = pkgs.lib.hasSuffix "darwin" system;
  nixArch = if pkgs.lib.hasPrefix "aarch64" system then "aarch64" else "x86_64";

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
  ] else [];

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

    mkdir -p $out
    tar xzf $src --strip-components=2 -C $out

    runHook postInstall
  '';

  postFixup = if isDarwin then ''
    # Make the toolchain work in pure Nix environments (sandbox):
    # swiftc's bundled clang invokes its co-located "ld" to link.
    # The toolchain ships LLD but its ld64 personality doesn't support
    # the macOS platform version on this system. Replace with nixpkgs'
    # ld64 from cctools which is a proper Apple-compatible linker.
    rm -f $out/bin/ld
    ln -s ${pkgs.darwin.binutils-unwrapped}/bin/ld $out/bin/ld
  '' else ''
    # Patch ELF binaries
    if command -v patchelf &>/dev/null; then
      find $out/bin -type f -executable | while read f; do
        if file "$f" | grep -q ELF; then
          patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" "$f" 2>/dev/null || true
        fi
      done
    fi
  '';

  meta = with pkgs.lib; {
    description = "Swift ${version} toolchain";
    homepage = "https://swift.org";
    license = licenses.asl20;
    platforms = if isDarwin then platforms.darwin else platforms.linux;
  };
}
