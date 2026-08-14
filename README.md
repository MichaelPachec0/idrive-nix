# idrive-docker

A Nix flake that packages the proprietary iDrive Linux backup client. It
provides a package derivation, a NixOS module (native systemd service or
containerized), and an OCI image built with Nix.

GitHub: https://github.com/MichaelPachec0/idrive-docker

The client is proprietary software, so any consumer of this flake must set
`nixpkgs.config.allowUnfree = true`. Without it, evaluation fails with an
"unfree" error before the package ever builds.

## Requirements

- Nix with flakes enabled
- `nixpkgs.config.allowUnfree = true`
- An iDrive account (for actual backup/restore; not required to build)

## Flake usage

```nix
{
  inputs.idrive.url = "github:MichaelPachec0/idrive-docker";

  outputs = { nixpkgs, idrive, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        idrive.nixosModules.idrive
        {
          nixpkgs.overlays = [ idrive.overlays.default ];
          nixpkgs.config.allowUnfree = true;
          services.idrive = {
            enable = true;
            backupPaths = [ "/srv/data" ];
          };
        }
      ];
    };
  };
}
```

This runs the client natively under systemd (`services.idrive.backend`
defaults to `"native"`). See "Container backend" below for the alternative.

The package alone is also available directly as `idrive.packages.<system>.idrive-client`,
without the module, if you just want the `idrive` binary on `PATH`.

## First-run login

Whichever backend you use, the client needs an account linked before it will
do anything. On a native install:

```
sudo idrive --account-setting
```

Then, at the prompts:
- `1) Login using IDrive credentials`
  - enter your IDrive username
  - enter your IDrive password
- `1) Create new Backup Location`
  - enter a name for the backup location; do not leave it empty

Login state and settings are stored under `services.idrive.stateDir`
(`/var/lib/idrive` by default), so they persist across rebuilds.

For more `idrive` command-line options, see the
[IDrive documentation](https://www.idrive.com/readme).

### The service sits inactive until an account is linked

`idrive --cron` (what the systemd unit runs) exits 0 immediately on an
unconfigured system: this is a precondition check inside the client itself,
not a fault in the unit. That means a fresh deployment starts the service,
watches it exit cleanly, and leaves it inactive. `Restart=on-failure` does
not bring it back, because that clean exit is not a failure. After you
finish `idrive --account-setting`, run:

```
sudo systemctl restart idrive
```

If you skip this, the service will simply sit there doing nothing and you
may reasonably conclude something is broken. It is not; it is just waiting
for a restart after setup.

## Container backend

To run the client inside the Nix-built OCI image instead of natively under
systemd, set `backend = "container"` and point `container.imageFile` at the
flake's own image output:

```nix
services.idrive = {
  enable = true;
  backend = "container";
  backupPaths = [ "/srv/data" ];
  container.imageFile = idrive.packages.<system>.idrive-image;
};
```

This maps `backupPaths` to `/source/1`, `/source/2`, and so on inside the
container, and `services.idrive.stateDir` to the container's
`/opt/IDriveForLinux/idriveIt`, matching the layout of the original Docker
image exactly. `container.runtime` selects `podman` (default) or `docker`;
`container.image` is the image name:tag to run, defaulting to
`idrive-docker:<package version>`.

### Container first-run login takes two different commands, depending on state

The container backend has the same "inactive until linked" behavior as
native, with one extra wrinkle: the client's own precondition check makes
the *default* auto-started container exit and get removed within well under
a second when no account is linked yet. That changes which login command
actually works, depending on whether an account already exists:

**If an account is already linked** (for example, after migrating state
from a previous native or Docker Hub install) and the container is staying
up, you can exec into the running container:

```
podman exec -it idrive idrive --account-setting
```

(substitute `docker` for `podman` if `services.idrive.container.runtime =
"docker"`). The container name is `idrive`, matching the
`virtualisation.oci-containers.containers.idrive` attribute name.

**For genuine first-time setup**, with no account linked yet, the
auto-started container will not stay up long enough for `exec` to reach it.
Run the image manually and interactively instead, using the same state
directory the module configures:

```
podman run --rm -it -v /var/lib/idrive:/opt/IDriveForLinux/idriveIt <image> idrive --account-setting
```

Replace `/var/lib/idrive` with your `services.idrive.stateDir` if you
changed it from the default, and `<image>` with your
`services.idrive.container.image` (or the tag your image was loaded with).
Once setup completes, restart the managed unit so it picks up the
now-linked account:

```
sudo systemctl restart podman-idrive.service
```

(or `docker-idrive.service` under the docker runtime.)

## Migration from the old Docker image

If you are moving from the original `snorre0815/idrive-docker` /
`ghcr.io/snorre-k/idrive-docker` image to the native backend, copy the
existing volume contents into the new state directory:

```
docker cp idrive:/opt/IDriveForLinux/idriveIt/. /var/lib/idrive/
```

Then set `services.idrive.legacySourceLinks = true`. The old image addressed
backup sources as `/source/1`, `/source/2`, and so on; existing backup sets
are configured against those exact paths. `legacySourceLinks` recreates them
as symlinks on the host pointing at your real `backupPaths`, so those backup
sets keep working without reconfiguration. This option applies only to
`backend = "native"`: the container backend already reproduces `/source/N`
itself through its own volume mappings, and setting `legacySourceLinks` next
to `backend = "container"` fails evaluation rather than doing nothing
silently.

## Migration from IDrive version 2.x

If you are coming from IDrive client 2.x (the last release was 2.38), the
client migrates its own configuration to the 3.x format the first time you
run account setup against it. Take note of your existing backup schedules
before doing this:

```
sudo idrive --account-setting
```

You will see a prompt similar to:

```
Linux user "root" is already having an active script setup with path
"/IDriveForLinux/scripts/Idrivelib/lib/dashboard.pl".
Configuring the same user profile with current path will terminate and
delete all the existing scheduled jobs. Do you want to continue (y/n)?: y
```

Backup content and backup set definitions are kept, but scheduled jobs are
deleted and must be recreated afterward. If your restore location was
configured beneath the old `/IDriveForLinux` path, update it: this package
installs under the Nix store, and the client's own working paths are under
`services.idrive.stateDir`, not `/IDriveForLinux`.

## Self-update is blocked by design

The upstream client can normally update itself in place. This package
refuses that on purpose: `idrive --check-update`, `--handle-update`,
`--launch-update`, `-C`, and `--utilities UPDATEFROMDASHBOARD` all fail
rather than run.

This exists because of upstream issue #26, a family of reports where the
client's in-place updater half-applies and leaves an unparseable user
profile behind, with knock-on reports of the process pinning a CPU core at
100% and runaway CDPDBDUMP growth reaching 200 GB (see "Monitoring
CDPDBDUMP growth" below). Under Nix, the install tree is a read-only store
path, so that failure mode is unreachable: there is no writable installer
for a self-update to corrupt.

To upgrade, bump this flake's input in your own flake (`nix flake update
idrive`, or pin a specific `rev`) rather than running the updater. That
rebuilds against a newer pinned version of the client instead of mutating an
existing install.

## Versions

`idrive-client` (the default, `idrive.packages.<system>.idrive-client`) is
version 3.14.0.

Version 3.8.0 is also available as `idrive.packages.<system>.idrive-client_3_8_0`,
but only for `x86_64-linux`. The vendor no longer distributes a 3.8.0
installer at any URL, so this build is instead extracted from the published
`ghcr.io/snorre-k/idrive-docker:3.8.0` image layer, which only exists for
that one architecture. There is no `aarch64-linux` build of 3.8.0, and none
is planned unless the vendor makes an ARM-capable source available again.

## aarch64 support is built but not hardware-verified

This flake builds `idrive-client` (3.14.0) for `aarch64-linux`, and the
flake's checks evaluate and build cleanly on that architecture. However, no
aarch64 hardware or emulator was available during development to actually
run the client on that architecture. The client embeds a table of transfer
binary ("evsbin") candidates for different targets; the ARM entry used here
was selected from that table by matching the target triple, not confirmed
by running it. If you use this on aarch64, you are the first real-world
verification of that path; issues there are plausible and reports are
welcome.

## Timezone

`services.idrive.timeZone` controls the timezone the client sees for backup
schedules and log timestamps, both under the native and container backends.
It defaults to `config.time.timeZone` (falling back to `Etc/UTC` if that is
unset), so in most configurations you do not need to set it explicitly. Set
it directly if you want the client on a different timezone than the rest of
the host.

## Monitoring CDPDBDUMP growth

The client writes its own change-tracking database (`CDPDBDUMP`) under
`user_profile/<profile>/` inside the state directory, and it chooses that
location itself; there is no option in this module to relocate it, because
an earlier `dumpDir` option was removed after turning out to be inert
against the client's own hardcoded path. This directory is exactly what
grew to 200 GB in upstream issue #26's runaway-disk reports. Keep an eye on
disk usage under `services.idrive.stateDir` (or the container's mapped
volume); this module cannot cap or redirect that growth for you.

## Publishing to Docker Hub (fork operators only)

CI publishes the OCI image to both GHCR and Docker Hub. GHCR needs no extra
setup: it authenticates with the repository's own `GITHUB_TOKEN`. Docker Hub
publishing needs a repository **variable** (not a secret) named
`DOCKERHUB_USERNAME`, plus the usual Docker Hub access token secret, set on
your fork. It is a variable rather than a secret deliberately, since it is
not sensitive and this keeps it unmasked in workflow logs for easier
debugging. If you fork this repository and do not set that variable, GHCR
publishing still works; Docker Hub publishing will not.

## What CI does not test

The flake's checks, including three NixOS VM tests, cover packaging,
wrapping, the prepare script, the native service, the container backend,
and the image build. They do not and cannot cover real backup or restore
against iDrive's own servers, since that requires a live iDrive account and
credentials that CI does not have. They also do not cover aarch64 on real
hardware, per the note above.
