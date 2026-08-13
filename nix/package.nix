{ lib
, stdenv
, fetchurl
, gnutar
, gzip
, gawk
, autoPatchelfHook
, expat
, popt
, zlib
, bzip2
, xz
, makeWrapper
, coreutils
, bash
, procps
, util-linux
, unixtools
, version ? "3.14.0"
}:

let
  wrappers = import ./wrappers.nix {
    inherit lib bash coreutils gnutar gzip procps util-linux unixtools;
  };
  sources = lib.importJSON ./sources.json;
  source = sources.${version} or (throw
    "idrive-client: version ${version} is not pinned in nix/sources.json");

  # Mirrors the arch selection in the installer's own shell header. The
  # aarch64 evsbin variant is not chosen by the shell header at all (it only
  # ever removes the evsbin directory after setup); the real selection lives
  # inside the compiled bin/idrive binary's embedded AppConfig::evsZipFiles
  # table, keyed by app type and uname-m-derived machine name. For
  # appType "IDrive" and machineName "aarch64" that table's ordered
  # candidate list is: synology_aarch64bit, QNAP_ARM, synology_ARM,
  # Netgear_ARM, synology_Alpine, tried in turn at runtime until one of
  # them actually executes. synology_aarch64bit is first in that list,
  # exactly mirroring how IDrive_linux_64bit is first (and the only entry
  # actually used) for the "64" machine name, so it is used as the evsbin
  # archive extracted into idriveIt/ below.
  #
  # `keep` controls which evsbin archives survive pruning, separately from
  # which one gets extracted. On x86_64 the vendor's own table has exactly
  # one real candidate for "64", so keeping only it is unambiguous. On
  # aarch64 the pick is a runtime bet: the vendor's own installer only
  # settles on synology_aarch64bit by trying to execute it and falling
  # through to the next candidate on failure, and that probe cannot be run
  # at Nix build time (no way to execute a foreign-arch binary here, and no
  # aarch64 hardware to test against). Rather than gamble the whole package
  # on one untested pick, every candidate the vendor's table would try for
  # aarch64 is kept in the store; if synology_aarch64bit turns out not to
  # run on real hardware, recovery is swapping which archive gets extracted
  # into idriveIt/, not rebuilding from a different source. This is
  # deliberately not a build-time or run-time fallback probe: adding one
  # here would be speculative complexity for a failure mode nobody has
  # observed yet. If aarch64 users ever do report transfer failures, that
  # probe belongs in the mutable-state prepare step, which already has
  # every candidate on hand to try.
  variants = {
    x86_64-linux = {
      arch = "x86_64";
      evs = "IDrive_linux_64bit";
      keep = [ "IDrive_linux_64bit" ];
    };
    aarch64-linux = {
      arch = "aarch64";
      evs = "IDrive_synology_aarch64bit";
      keep = [
        "IDrive_synology_aarch64bit"
        "IDrive_QNAP_ARM"
        "IDrive_synology_ARM"
        "IDrive_Netgear_ARM"
        "IDrive_synology_Alpine"
      ];
    };
  };
  variant = variants.${stdenv.hostPlatform.system} or (throw
    "idrive-client: unsupported system ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation (finalAttrs: {
  pname = "idrive-client";
  inherit version;

  src = fetchurl {
    url = source.url;
    inherit (source) hash;
  };

  # The vendor installer is deliberately never executed: it assumes an FHS
  # layout and a populated PATH. Its payload is located the same way the
  # installer locates it, by the __idrive__ marker line, which is stable
  # across versions in a way a raw gzip-magic scan is not.
  nativeBuildInputs = [ gnutar gzip gawk autoPatchelfHook makeWrapper ];

  # Confirmed in phase 0 from ldd against the extracted binaries, plus two
  # more found by autoPatchelfHook itself against vendored Python C
  # extensions phase 0 did not individually ldd: bzip2 (libbz2.so.1.0, wanted
  # by _bz2.cpython-35m-x86_64-linux-gnu.so) and xz (liblzma.so.5, wanted by
  # _lzma.cpython-35m-x86_64-linux-gnu.so). Grow this list only from
  # autoPatchelfHook's own missing-dependency output; do not add openssl,
  # which cannot satisfy the vendored 1.0.0 SONAMEs.
  buildInputs = [
    (lib.getLib stdenv.cc.cc)
    expat
    popt
    zlib
    bzip2
    xz
  ];

  # The vendored Python extensions and the dashboard reference libraries that
  # exist only inside the bundle, including OpenSSL 1.0.0. The hook must
  # resolve those against the output itself rather than against nixpkgs.
  appendRunpaths = [
    "${placeholder "out"}/opt/IDriveForLinux/bin/Idrivelib/dependencies/python/lib"
  ];

  # readline.cpython-35m-x86_64-linux-gnu.so (Python's stdlib readline
  # module, used for interactive line editing) wants libreadline.so.6.
  # Current nixpkgs ships only SONAME 7 (readline70) and SONAME 8
  # (readline); there is no package providing SONAME 6, and unlike the
  # OpenSSL 1.0.0 libraries it is not vendored alongside it either, so there
  # is nothing to point autoPatchelf at. This module is not on the path
  # exercised by `idrive --version` or by the non-interactive CLI in
  # general, so the missing dependency is ignored rather than papered over
  # with a mismatched SONAME that would not actually link.
  autoPatchelfIgnoreMissingDeps = [ "libreadline.so.6" ];

  dontConfigure = true;
  dontBuild = true;

  unpackPhase = ''
    runHook preUnpack

    start=$(awk '/^__idrive__/ { print NR + 1; exit 0; }' "$src")
    if [ -z "$start" ]; then
      echo "could not find the __idrive__ payload marker in the installer" >&2
      exit 1
    fi
    echo "payload starts at line $start"

    mkdir -p payload
    tail -n +"$start" "$src" | tar -xz -C payload

    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    root="$out/opt/IDriveForLinux"
    mkdir -p "$root"
    # The relative layout is preserved verbatim: the vendored interpreters
    # resolve their siblings by relative path, and the client builds every
    # path at runtime relative to its own resolved location.
    cp -a payload/IDriveForLinux/. "$root/"

    dep="$root/bin/Idrivelib/dependencies"

    # The outer payload carries no runnable client. These three nested
    # archives are what the vendor installer would extract, done here at
    # build time because the store is read-only at runtime.
    tar -xzf "$dep/linuxbin/k3/${variant.arch}/idrive.tar.gz" -C "$root/bin"
    tar -xzf "$dep/pythonbin/k3/${variant.arch}/python.tar.gz" -C "$dep"

    mkdir -p "$root/idriveIt"
    tar -xzf "$dep/evsbin/${variant.evs}.tar.gz" -C "$root/idriveIt" \
      --strip-components=1

    # Drop the archives for every other architecture and NAS vendor, plus the
    # cached installer copy the client keeps for self-updates it can no
    # longer perform. What stays in evsbin/ is variant.keep, not just the
    # one archive actually extracted above: see the comment on `variants`
    # for why aarch64 keeps its whole candidate set.
    rm -rf "$dep/pkg"
    find "$dep/evsbin" -name '*.tar.gz' \
      ${lib.concatMapStringsSep " " (n: "! -name '${n}.tar.gz'") variant.keep} \
      -delete
    rm -rf "$dep/linuxbin/k2" "$dep/pythonbin/k2"
    for d in "$dep/linuxbin/k3" "$dep/pythonbin/k3"; do
      find "$d" -mindepth 1 -maxdepth 1 -type d ! -name '${variant.arch}' \
        -exec rm -rf {} +
    done

    runHook postInstall
  '';

  postInstall = ''
    root="$out/opt/IDriveForLinux"
    vendorLib="$root/bin/Idrivelib/dependencies/python/lib"
  '' + wrappers.mkWrappers { root = "$root"; vendorLib = "$vendorLib"; };

  meta = {
    description = "IDrive Linux backup client";
    homepage = "https://www.idrive.com/";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "idrive";
  };
})
