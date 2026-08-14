{ lib
, callPackage
, dockerTools
, runCommand
, gnutar
}:

let
  # 3.8.0's installer is not downloadable from the vendor any more: the
  # download URL has no version selector and always serves current, and
  # both versioned-URL guesses 404. It does still exist, though, bundled
  # inside the published 3.8.0 image: the vendor ships its own installer
  # along with the installed tree, at
  # bin/Idrivelib/dependencies/pkg/idriveforlinux.bin, with APPVERSION set
  # to 3.8.0 in its header. That copy is what this package builds from, so
  # the rollback build is the same derivation as the current one (see
  # nix/package.nix) fed a different installer, rather than a second,
  # subtly different packaging of an already-installed tree. Manifest
  # digest from
  # `nix run nixpkgs#skopeo -- inspect docker://ghcr.io/snorre-k/idrive-docker:3.8.0`.
  image = dockerTools.pullImage {
    imageName = "ghcr.io/snorre-k/idrive-docker";
    imageDigest = "sha256:08deb8c698f0f96e0779665d83209504ccfc372c0d1c4db0ed321e60b77c174d";
    finalImageTag = "3.8.0";
    sha256 = "sha256-6XYH9ztgQijlnI/3CbhPpvM/1/iszmUpCz+gn3KGQjo=";
    os = "linux";
    arch = "amd64";
  };

  bundle = "opt/IDriveForLinux/bin/Idrivelib/dependencies/pkg/idriveforlinux.bin";

  installer = runCommand "idrive-installer-3.8.0.bin"
    {
      nativeBuildInputs = [ gnutar ];
    } ''
    mkdir -p image extracted
    tar -xf "${image}" -C image

    # The installer lives in whichever layer carries the installed tree;
    # ask each layer for that one path and take the first that has it,
    # rather than listing whole layers to decide.
    found=
    for layer in image/*/layer.tar image/*.tar; do
      [ -e "$layer" ] || continue
      if tar -xf "$layer" -C extracted "${bundle}" 2>/dev/null; then
        found="extracted/${bundle}"
        break
      fi
    done
    if [ -z "$found" ]; then
      echo "no layer in the image contained ${bundle}" >&2
      exit 1
    fi

    # The installer's own version header, checked so a wrong layer or a
    # re-tagged image fails here instead of quietly producing a package
    # labelled 3.8.0 that contains something else.
    if ! head -n 20 "$found" | grep -q '^APPVERSION="3.8.0"$'; then
      echo "the extracted installer does not declare APPVERSION 3.8.0:" >&2
      head -n 20 "$found" >&2
      exit 1
    fi

    cp "$found" "$out"
  '';

  package = callPackage ./package.nix {
    version = "3.8.0";
    inherit installer;
  };
in
package.overrideAttrs (old: {
  meta = old.meta // {
    description = "IDrive Linux backup client, 3.8.0 rollback build";
    # The installer recovered above carries every architecture's payload,
    # exactly as the current one does, so nothing in the build itself is
    # x86_64-specific. What is x86_64-specific is the evidence: the only
    # surviving copy of that installer is inside an image that was
    # published amd64-only, and no aarch64 result has ever been built or
    # run from it. Claiming a platform this has never produced a working
    # client for is what the rest of this packaging exists to avoid, so
    # this stays narrower than nix/package.nix until someone actually
    # tests it.
    platforms = [ "x86_64-linux" ];
  };
})
