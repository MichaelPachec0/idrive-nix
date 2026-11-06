{ lib, symlinkJoin, writeShellApplication, acl, coreutils, findutils, gnugrep, gnused }:

# The client stores file content and mtime only. Anything it creates on restore
# comes back 0777 root:root, and symlinks do not come back at all. These tools
# keep that metadata in two files inside each tree, so a tree that is backed up
# carries its own record. The file names are fixed because the restore side has
# to find them in a tree that may have moved.
let
  runtimeInputs = [ acl coreutils findutils gnugrep gnused ];

  save = writeShellApplication {
    name = "idrive-save-permissions";
    inherit runtimeInputs;
    text = ''
      usage() {
        echo "usage: idrive-save-permissions [--owner USER:GROUP] DIR..." >&2
        exit 2
      }

      owner=root:root
      if [ "''${1:-}" = "--owner" ]; then
        [ $# -ge 2 ] || usage
        owner=$2
        shift 2
      fi
      [ $# -ge 1 ] || usage

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      status=0

      for root in "$@"; do
        # An unplugged disk is not a failure, the same as for backupPaths.
        if [ ! -d "$root" ]; then
          echo "idrive-save-permissions: skipping $root: not a directory" >&2
          continue
        fi

        # Written outside the tree and moved in, so a failed scan leaves the
        # previous record in place and never a partial one.
        if ! (cd "$root" && getfacl -R -p .) > "$work/acl" \
          || ! (cd "$root" && find . -type l -printf '%p\0%l\0%u:%g\0') > "$work/links"; then
          echo "idrive-save-permissions: failed to scan $root, keeping the old record" >&2
          status=1
          continue
        fi

        # The client has to be able to read these to back them up, and they
        # list every file name in the tree, so nobody else should.
        for pair in acl:.idrive-perms.acl links:.idrive-links; do
          source=$work/''${pair%%:*}
          target=$root/''${pair#*:}
          install -m 0600 -o "''${owner%%:*}" -g "''${owner#*:}" "$source" "$target.new"
          mv -f "$target.new" "$target"
        done
      done

      exit "$status"
    '';
  };

  restore = writeShellApplication {
    name = "idrive-restore-permissions";
    inherit runtimeInputs;
    text = ''
      usage() {
        echo "usage: idrive-restore-permissions [--force] [--keep-special] DIR" >&2
        exit 2
      }

      fail() {
        echo "idrive-restore-permissions: $1" >&2
        exit 1
      }

      force=0
      keep_special=0
      dir=
      while [ $# -gt 0 ]; do
        case $1 in
          --force) force=1 ;;
          --keep-special) keep_special=1 ;;
          -*) usage ;;
          *) [ -z "$dir" ] || usage; dir=$1 ;;
        esac
        shift
      done
      [ -n "$dir" ] || usage

      [ "$(id -u)" -eq 0 ] || fail "must run as root"
      [ -d "$dir" ] || fail "$dir is not a directory"
      dir=$(realpath -- "$dir")
      manifest=$dir/.idrive-perms.acl
      links=$dir/.idrive-links
      [ -f "$manifest" ] && [ ! -L "$manifest" ] || fail "no .idrive-perms.acl in $dir"

      # A restored manifest is 0777 like everything else, and applying one as
      # root can hand any file to anyone. It can be trusted only if nobody else
      # could have reached it: some root-owned directory above it must be
      # closed to other users, and nobody else may be able to replace that
      # directory. What sits below it does not matter, which matters because
      # the client makes its own Restore_Data 0777. Walking up, a closed
      # directory counts until a directory above it turns out to be replaceable.
      closed() {
        local path=$1 found=1 owner mode
        while [ "$path" != / ]; do
          path=$(dirname -- "$path")
          owner=$(stat -c %u -- "$path")
          mode=$(stat -c %a -- "$path")
          if [ "$owner" -ne 0 ] \
            || { [ $(( 8#$mode & 8#022 )) -ne 0 ] && [ $(( 8#$mode & 8#1000 )) -eq 0 ]; }; then
            found=1
          elif [ $(( 8#$mode & 8#077 )) -eq 0 ]; then
            found=0
          fi
        done
        return "$found"
      }

      if ! closed "$dir"; then
        if [ "$force" -eq 0 ]; then
          fail "refusing: $dir is not under a directory only root can enter, so
      its manifest could have been altered. Restore to the default location
      (inside the state directory) and apply it there, or pass --force if nobody
      else can log in to this machine."
        fi
        echo "idrive-restore-permissions: warning: applying a manifest other users could reach" >&2
      fi

      # Checked even with --force: a record of a tree only names paths in it.
      # setfacl decodes octal escapes and is loose about header spacing, so
      # those forms are refused too rather than matched on their meaning. One
      # grep and no pipeline: with pipefail a grep -q that stops early would
      # fail the pipeline and read as "nothing found".
      if LC_ALL=C grep -qaP \
        '^\s+#|^#(?! (file|owner|group|flags): )|^# file: (/|(.*/)?\.\.(/|$)|.*\\0(56|57))' \
        "$manifest"; then
        fail "the manifest names a path outside $dir or is malformed, refusing"
      fi

      chmod 0600 "$manifest"
      [ ! -f "$links" ] || chmod 0600 "$links"

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      status=0

      # setuid, setgid and sticky are the bits worth the most to an attacker
      # and the least likely to matter in a restored data tree, so they take
      # an explicit request.
      if [ "$keep_special" -eq 1 ]; then
        cp "$manifest" "$work/acl"
      else
        if grep -qa '^# flags: ' "$manifest"; then
          echo "idrive-restore-permissions: leaving out setuid/setgid/sticky bits (--keep-special keeps them):" >&2
          grep -a -B3 '^# flags: ' "$manifest" | sed -n 's/^# file: /  /p' >&2
        fi
        sed '/^# flags: /d' "$manifest" > "$work/acl"
      fi

      # A path the manifest names may be gone from a partial restore. setfacl
      # says so and carries on with the rest.
      (cd "$dir" && setfacl -P --restore="$work/acl") || status=1

      if [ -f "$links" ]; then
        while IFS= read -r -d "" path && IFS= read -r -d "" target && IFS= read -r -d "" who; do
          case /$path/ in
            */../*) fail "the link list names a path outside $dir, refusing" ;;
          esac
          [ ! -e "$dir/$path" ] && [ ! -L "$dir/$path" ] || continue
          if [ ! -d "$(dirname -- "$dir/$path")" ]; then
            echo "idrive-restore-permissions: cannot recreate $path: no parent directory" >&2
            status=1
            continue
          fi
          ln -s -- "$target" "$dir/$path"
          chown -h -- "$who" "$dir/$path" || status=1
        done < "$links"
      fi

      # Anything newer than the manifest was not in it and is still 0777.
      left=$(find "$dir" ! -type l -perm -o+w)
      if [ -n "$left" ]; then
        echo "idrive-restore-permissions: still world writable, not in the manifest:" >&2
        printf '%s\n' "$left" | sed 's/^/  /' >&2
        status=1
      fi

      exit "$status"
    '';
  };
in
symlinkJoin {
  name = "idrive-permission-tools";
  paths = [ save restore ];
  meta.platforms = lib.platforms.linux;
}
