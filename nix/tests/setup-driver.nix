{ runCommand, python3, bash, coreutils, gnugrep }:

# Exercises nix/setup-driver.py against a fake client, because the paths past
# the password prompt cannot be reached in CI: they need a real account. The
# fake client refuses a stdin that is not a terminal, as the real one does
# (its helper checks sys.stdin.isatty() before asking for the password), and
# records every answer it receives, so each scenario can assert what was
# actually typed as well as how the run ended.
runCommand "idrive-setup-driver" {
  nativeBuildInputs = [ python3 bash coreutils gnugrep ];
  driver = ../setup-driver.py;
} ''
  set -u
  mkdir work
  cd work

  cat > client <<'FAKE'
  #!/usr/bin/env bash
  [ -t 0 ] || { echo "Invalid_arguments"; exit 1; }
  ask() { printf '%s' "$1"; IFS= read -r a; printf '%s\n' "$a" >> "$ANSWERS"; }
  linked() {
    mkdir -p "$STATE/user_profile/$(id -un)/someone/.userInfo" "$STATE/cache"
    echo encoded > "$STATE/user_profile/$(id -un)/someone/.userInfo/IDPWD"
    echo conf > "$STATE/user_profile/$(id -un)/someone/CONFIGURATION_FILE"
    echo someone > "$STATE/cache/idriveuser.txt"
  }
  keyfile() {
    mkdir -p "$STATE/user_profile/$(id -un)/someone/.userInfo"
    echo encoded > "$STATE/user_profile/$(id -un)/someone/.userInfo/IDPVT"
  }
  login() {
    printf 'Choose a method to authenticate your IDrive account:\n'
    printf '      1) Login using IDrive credentials\n'
    printf '      2) Login using the SSO account\n'
    ask 'Enter your choice: '
    ask 'Enter your IDrive username: '
    ask 'Enter your IDrive password: '
  }
  encmenu() {
    printf 'Configure your IDrive account with encryption key\n'
    printf '      1) Default encryption key\n      2) Private encryption key\n'
    ask 'Enter your choice: '
  }
  case "$SCENARIO" in
    default) login; encmenu; linked ;;
    private) login; encmenu
      ask 'Set your encryption key: '; ask 'Confirm your encryption key: '; keyfile; linked ;;
    existing-private) login; ask 'Enter your encryption key: '; keyfile; linked ;;
    rejected-key) login; ask 'Enter your encryption key: '; linked
      echo 'Invalid encryption key. Try again.'; exit 0 ;;
    key-not-used) login; encmenu; linked ;;
    device-menu) login
      printf 'Multiple backup locations are configured with this account. Enter your choice: \n'
      printf '      1) Create new Backup Location\n      2) Select from existing Backup Locations\n'
      ask 'Enter your choice: '; linked ;;
    two-factor) login; ask 'Enter the verification code: '; linked ;;
    unknown-prompt) login; ask 'Something IDrive added later: '; linked ;;
    wrong-password) login
      echo 'Failed to authenticate user "someone". Try again.'
      ask 'Enter your IDrive password: ' ;;
    silent-success) login ;;
    linked-but-failed) login; encmenu; linked; exit 1 ;;
    reconfigure) linked; ask 'Your account is already configured. Do you want to reconfigure it? (y/n)'; exit 1 ;;
    echoes-secret) login; IFS= read -r p < "$PASSWORD_COPY"; echo "debug $p"; exit 1 ;;
    helper-broken) login; echo "'helpers' object has no attribute '_helpers__servicepath'"; exit 1 ;;
    hangs) login; sleep 60 ;;
  esac
  FAKE
  sed -i 's/^  //' client
  sed -i "1s|.*|#!${bash}/bin/bash|" client
  chmod +x client

  printf 'hunter2-pass  \n' > pw
  printf 'priv-key-123\n' > key
  printf 'someone\n' > user
  fails=0

  # run NAME EXPECTED_EXIT EXPECTED_ANSWERS [driver args...]
  run() {
    name=$1; want=$2; answers=$3; shift 3
    rm -rf state answers out; mkdir state; : > answers
    got=0
    SCENARIO=$name STATE=$PWD/state ANSWERS=$PWD/answers PASSWORD_COPY=$PWD/pw \
      python3 "$driver" --client "$PWD/client" --state "$PWD/state" \
      --username-file user --password-file pw \
      --idle-timeout 2 --timeout 20 "$@" > out 2>&1 || got=$?
    have=$(paste -sd, answers)
    if [ "$got" != "$want" ] || [ "$have" != "$answers" ]; then
      echo "FAIL $name: exit $got (want $want), answers [$have] (want [$answers])"
      cat out
      fails=$((fails + 1))
    else
      echo "ok   $name"
    fi
  }

  run default 0 '1,someone,hunter2-pass,1'
  run private 0 '1,someone,hunter2-pass,2,priv-key-123,priv-key-123' --encryption-key-file key
  run existing-private 0 '1,someone,hunter2-pass,priv-key-123' --encryption-key-file key
  run reconfigure 0 'n'

  # The client exits 0 here with its login files already written.
  run rejected-key 1 '1,someone,hunter2-pass,priv-key-123' --encryption-key-file key
  grep -q 'rejected the encryption key' out || { echo "FAIL rejected-key: not named"; fails=$((fails + 1)); }
  # A key was supplied, so a run that stored none did not do what was asked.
  run key-not-used 1 '1,someone,hunter2-pass,2' --encryption-key-file key
  # A private-key account with no key supplied has nothing safe to answer.
  run existing-private 1 '1,someone,hunter2-pass'
  # Picking here could create a new device and orphan the old backup set.
  run device-menu 1 '1,someone,hunter2-pass'
  grep -q 'by hand' out || { echo "FAIL device-menu: no guidance"; fails=$((fails + 1)); }
  run two-factor 1 '1,someone,hunter2-pass'
  grep -q 'two-factor' out || { echo "FAIL two-factor: not named"; fails=$((fails + 1)); }
  run unknown-prompt 1 '1,someone,hunter2-pass'
  # One attempt only: retrying a bad secret risks locking the account.
  run wrong-password 1 '1,someone,hunter2-pass'
  # Exit status and files must both agree before setup counts as done.
  run silent-success 1 '1,someone,hunter2-pass'
  run linked-but-failed 1 '1,someone,hunter2-pass,1'
  run helper-broken 1 '1,someone,hunter2-pass'
  grep -q 'packaging fault' out || { echo "FAIL helper-broken: not named"; fails=$((fails + 1)); }
  run hangs 1 '1,someone,hunter2-pass'

  # Has to be a failing run: output is only logged on failure, so a secret
  # echoed during a successful one would never be at risk.
  run echoes-secret 1 '1,someone,hunter2-pass'
  grep -q 'debug \[redacted\]' out || { echo "FAIL echoes-secret: output was not logged"; fails=$((fails + 1)); }
  if grep -q 'hunter2-pass' out; then
    echo "FAIL echoes-secret: the password reached the log"
    fails=$((fails + 1))
  fi

  # Secrets are only ever named by path on the command line.
  rm -rf state; mkdir state; : > answers
  printf '  \n' > blank
  if python3 "$driver" --client "$PWD/client" --state "$PWD/state" \
      --username-file user --password-file blank > out 2>&1; then
    echo "FAIL blank: an all-whitespace password was accepted"
    fails=$((fails + 1))
  fi
  printf 'two words\n' > badkey
  if python3 "$driver" --client "$PWD/client" --state "$PWD/state" \
      --username-file user --password-file pw --encryption-key-file badkey > out 2>&1; then
    echo "FAIL badkey: a key with whitespace was accepted"
    fails=$((fails + 1))
  fi

  [ "$fails" = 0 ] || exit 1
  touch $out
''
