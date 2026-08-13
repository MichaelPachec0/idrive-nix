{ lib
, stdenv
, fetchurl
, gnutar
, gzip
, gawk
, version ? "3.14.0"
}:

let
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
  # Netgear_ARM, synology_Alpine, tried in turn until one runs successfully.
  # synology_aarch64bit is first in that list, exactly mirroring how
  # IDrive_linux_64bit is first (and the only entry actually used) for the
  # "64" machine name.
  variants = {
    x86_64-linux = { arch = "x86_64"; evs = "IDrive_linux_64bit"; };
    aarch64-linux = { arch = "aarch64"; evs = "IDrive_synology_aarch64bit"; };
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
  nativeBuildInputs = [ gnutar gzip gawk ];

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
    # longer perform. The archives for THIS system stay: the client's
    # first-run setup still looks for them.
    rm -rf "$dep/pkg"
    find "$dep/evsbin" -name '*.tar.gz' ! -name '${variant.evs}.tar.gz' -delete
    rm -rf "$dep/linuxbin/k2" "$dep/pythonbin/k2"
    for d in "$dep/linuxbin/k3" "$dep/pythonbin/k3"; do
      find "$d" -mindepth 1 -maxdepth 1 -type d ! -name '${variant.arch}' \
        -exec rm -rf {} +
    done

    runHook postInstall
  '';

  meta = {
    description = "IDrive Linux backup client";
    homepage = "https://www.idrive.com/";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "idrive";
  };
})
