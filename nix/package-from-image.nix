{ lib
, stdenv
, dockerTools
, autoPatchelfHook
, makeWrapper
, bash
, coreutils
, gnutar
, gzip
, procps
, util-linux
, unixtools
, expat
, popt
, zlib
, bzip2
, xz
}:

let
  wrappers = import ./wrappers.nix {
    inherit lib bash coreutils gnutar gzip procps util-linux unixtools;
  };

  # 3.8.0's installer is no longer distributed anywhere: the vendor download
  # URL has no version selector and always serves current, and both
  # versioned-URL guesses 404. The only surviving artifact is the
  # already-installed tree published in this image, so this package extracts
  # that rather than running an extraction pipeline against a .bin that
  # cannot be fetched. Manifest digest from
  # `nix run nixpkgs#skopeo -- inspect docker://ghcr.io/snorre-k/idrive-docker:3.8.0`.
  image = dockerTools.pullImage {
    imageName = "ghcr.io/snorre-k/idrive-docker";
    imageDigest = "sha256:08deb8c698f0f96e0779665d83209504ccfc372c0d1c4db0ed321e60b77c174d";
    finalImageTag = "3.8.0";
    sha256 = "sha256-6XYH9ztgQijlnI/3CbhPpvM/1/iszmUpCz+gn3KGQjo=";
    os = "linux";
    arch = "amd64";
  };
in
stdenv.mkDerivation {
  pname = "idrive-client";
  version = "3.8.0";

  src = image;

  nativeBuildInputs = [ autoPatchelfHook makeWrapper gnutar gzip ];
  # Same vendored-binary dependency set nix/package.nix needs, confirmed
  # against this tree's own auto-patchelf output rather than assumed to
  # match: bzip2 and xz for the vendored Python C extensions, plus the same
  # libreadline.so.6 gap (see the autoPatchelfIgnoreMissingDeps comment
  # below).
  buildInputs = [ (lib.getLib stdenv.cc.cc) expat popt zlib bzip2 xz ];

  # readline.cpython-35m-x86_64-linux-gnu.so wants libreadline.so.6; current
  # nixpkgs has no package providing that SONAME and it is not vendored
  # alongside it either. Not on the path exercised by `idrive --version` or
  # the non-interactive CLI, so ignored rather than papered over.
  autoPatchelfIgnoreMissingDeps = [ "libreadline.so.6" ];

  dontConfigure = true;
  dontBuild = true;

  unpackPhase = ''
    runHook preUnpack
    mkdir -p image
    tar -xf "$src" -C image
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    root="$out/opt/IDriveForLinux"
    mkdir -p "$root"

    # Find the layer carrying the installed tree and unpack just that path.
    # This is the output of the vendor installer, not its input: bin/idrive
    # is already a real executable, bin/Idrivelib/dependencies/python/ is
    # already extracted, and idevsutil* is already sitting in idriveIt/, so
    # none of nix/package.nix's marker-scan, nested-archive extraction, or
    # evsbin pruning applies here.
    found=
    for layer in image/*/layer.tar image/*.tar; do
      [ -e "$layer" ] || continue
      if tar -tf "$layer" | grep -q '^opt/IDriveForLinux/bin/idrive$'; then
        tar -xf "$layer" -C "$out" opt/IDriveForLinux
        found=1
        break
      fi
    done
    if [ -z "$found" ]; then
      echo "no layer in the image contained opt/IDriveForLinux/bin/idrive" >&2
      exit 1
    fi

    runHook postInstall
  '';

  postInstall = ''
    root="$out/opt/IDriveForLinux"
    vendorLib="$root/bin/Idrivelib/dependencies/python/lib"
  '' + wrappers.mkWrappers { root = "$root"; vendorLib = "$vendorLib"; };

  appendRunpaths = [
    "${placeholder "out"}/opt/IDriveForLinux/bin/Idrivelib/dependencies/python/lib"
  ];

  meta = {
    description = "IDrive Linux backup client, 3.8.0 rollback build";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    # The published image this package extracts from was built amd64-only;
    # there is no aarch64 source for 3.8.0 to fall back to, so this package
    # does not claim aarch64 support the way nix/package.nix does.
    platforms = [ "x86_64-linux" ];
    mainProgram = "idrive";
  };
}
