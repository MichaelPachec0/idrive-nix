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

Run this as the user the service runs as, which is what plain `sudo` gives
you while `services.idrive.user` keeps its default of `root`. If you have
pointed that option at a different user, run setup as that user instead:

```
sudo -u alice idrive --account-setting
```

The client keys its profile by the invoking user (`user_profile/<user>` in
the state directory), so a profile created by root is not a profile the
daemon running as `alice` can use, and the two users writing into the same
state directory will collide on ownership.

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

## Two shapes: one machine account, or one account per user

Decide which of these you want before configuring anything, because they
have different privilege requirements and different failure modes.

**One backup account for the whole machine.** `services.idrive.enable =
true`, a system service. It backs up whatever paths you list regardless of
who owns them, which is what you want for a server or a machine backed up
as a unit. Reading other users' files is the hard part; see the permission
model section below.

**One account per user.** `services.idrive.userServices = [ "alice" ]`, a
systemd user service per listed user. Each gets their own iDrive account,
profile, schedule and state directory under `~/.local/state/idrive`.

```nix
services.idrive = {
  package = pkgs.idrive-client;
  userServices = [ "alice" "bob" ];
};
```

The per-user shape needs no privilege at all: each user's own uid already
owns everything they back up, so none of `readAllFiles`,
`supplementaryGroups`, or ACLs applies, and restoring into their own home
needs no `writablePaths` entry. If your situation is "a few people, each
backing up their own files", this is the simpler and safer shape.

Both can run on the same machine. Two things differ:

- **The interactive command.** `idrive` for the system service,
  `idrive-user` for a per-user one. Two different commands cannot share one
  name on `PATH`, and a command that means different things depending on
  who typed it would be worse than a longer name.
- **Lingering.** The module enables it for every user in `userServices`.
  Without it a user's systemd manager exits at logout and takes the backup
  service with it, which is not something you want to learn during a
  restore.

Per-user first-run setup is the ordinary one, run as yourself:

```
idrive-user --account-setting
```

## Naming the device in the iDrive web interface

What iDrive shows as the device name is what it calls the backup location,
and the client derives its default from the machine's hostname. There is no
command-line flag that sets it, so this module sets it by answering the two
commands the client uses to ask (`uname -n`, and `hostname` as its
fallback):

```nix
services.idrive = {
  enable = true;
  deviceName = "nas-backup";
};
```

For per-user services, name each one separately. Without this every user's
client registers under the same hostname and the web interface shows
several devices with one name:

```nix
services.idrive = {
  userServices = [ "alice" "bob" ];
  userDeviceNames = {
    alice = "laptop-alice";
    bob = "laptop-bob";
  };
};
```

Three things to know before setting these:

- **Letters, digits, underscore and hyphen only, 4 to 64 characters.** The
  client rejects anything else at setup time, so spaces and dots do not
  work.
- **Set it before first account setup.** iDrive fixes the name when the
  client first registers the machine, so this option decides the name of a
  device that does not exist yet. It does not rename one that already does.
- **Renaming an existing device is a web interface operation.** Changing
  this option afterwards will not move a device that is already registered,
  because by then the name is server-side state.

Nothing else on the system is affected. The shims answer only for the
device name and only when one is configured; every other query, including
the architecture check that decides which transfer binaries get staged,
passes straight through to the real tools.

## Permission model: which files the service can actually read

By default `services.idrive.user` is `root`, and root reads everything. If
you narrow that to a dedicated account, read access becomes the thing you
have to think about, because a backup agent silently skips what it cannot
read: you get a backup that looks like it worked and is missing files.

**`ReadOnlyPaths` does not grant access.** The unit lists `backupPaths`
under systemd's `ReadOnlyPaths`, which only marks them read-only inside the
unit's own mount namespace. Ordinary Unix permissions still decide what the
service uid can open. Listing a path there does not make it readable.

Three ways to actually grant read access, in increasing order of privilege:

**1. `supplementaryGroups`** - use when the data is already group-readable.

```nix
services.idrive = {
  user = "idrive";
  group = "idrive";
  supplementaryGroups = [ "media" ];
};
```

Grants exactly that group's access and nothing else. This is the tightest
option, and the one to reach for first.

**2. Default ACLs** - use when the data is not group-readable but the set of
paths is known and stable. This is host state the module does not manage:

```
setfacl -R -m u:idrive:rX /srv/data
setfacl -R -d -m u:idrive:rX /srv/data
```

The second line sets a *default* ACL so files created later inherit it.
Without it, anything added after you run this is unreadable again.

**3. `readAllFiles = true`** - use when the backup set is broad or
unpredictable enough that neither of the above is practical.

```nix
services.idrive = {
  user = "idrive";
  group = "idrive";
  readAllFiles = true;
};
```

This grants the `CAP_DAC_READ_SEARCH` capability, which bypasses file read
and directory search permission checks system-wide. Be clear-eyed about it:
the service can then read any file root could read. What it buys over
running as root is that it grants no write, execute, or other capability, so
the client still cannot modify or delete anything outside what its own
user, group, and supplementary groups allow. It is not a guarantee of
access either: SELinux, AppArmor, or a filesystem that refuses the
capability can still deny a read.

`createUser` defaults to true, so setting `user` to something other than
`root` makes the module define that system account for you. Set it to false
if you manage the account yourself.

### Restore is the weak direction

Reading is solvable. Writing back is not, and you should decide this before
you need a restore rather than during one.

Restored files are created by the service's uid, with the unit's umask. Two
consequences:

- **Ownership.** They come back owned by the service user, not by whoever
  owned them originally. Restoring the original ownership requires
  `CAP_CHOWN` plus `CAP_FOWNER` to write into directories the service does
  not own, and granting those amounts to rebuilding root. The capability
  split stops buying you anything at that point.
- **Modes.** systemd's default umask is `0022`, so a file that was `0600`
  can come back `0644`, readable by anyone who can reach the restore
  location. `services.idrive.umask` sets the unit's `UMask` if you want to
  pin this; it defaults to null, meaning the module does not change
  restore behavior on its own.

The practical recommendations:

- Run restores as root (`user = "root"`, the default) if you need ownership
  and modes preserved.
- Or restore to a staging directory the service user owns, then move the
  files into place and fix ownership yourself, where you can see exactly
  what you are changing.
- Either way, do a test restore of a small path before you rely on this, and
  check the resulting owner and mode. That is the only way to find out what
  the client actually preserves in your setup.

`supplementaryGroups`, `readAllFiles`, `umask`, and `createUser` apply to
`backend = "native"` only. The containerized client runs as the image's own
root user, which the module cannot substitute, and setting any of them
alongside `backend = "container"` fails evaluation rather than doing nothing
quietly.

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

(as the service user, per "First-run login" above)

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
installer at any URL. It does still exist, though, bundled inside the
published `ghcr.io/snorre-k/idrive-docker:3.8.0` image: that image carries
the vendor's own installer alongside the installed tree. This build
recovers that installer and feeds it through exactly the same derivation
the current version uses, so the two packages differ only in which
installer they were built from. The image it comes from was published for
`x86_64-linux` only and no ARM result has ever been built or run from it,
so this package does not claim `aarch64-linux`.

## aarch64 support is built but not hardware-verified

This flake builds `idrive-client` (3.14.0) for `aarch64-linux`, and CI
builds the package and the OCI image on a native ARM runner on every push.
The checks are a different matter: `nix flake check` only evaluates the
checks for the system it runs on ("omitted these incompatible systems:
aarch64-linux" on any other), and CI runs it on `x86_64-linux` only, so no
check in this suite has ever run on ARM. Beyond that, no aarch64 hardware
or emulator was available during development to actually
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
credentials that CI does not have. They also never run on aarch64 at all:
CI builds the package and image on an ARM runner, but runs `nix flake
check` only on `x86_64-linux`, per the note above.
