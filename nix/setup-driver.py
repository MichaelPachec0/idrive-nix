"""Answer the IDrive client's first-run prompts from secret files.

The client has no non-interactive login, and piping answers cannot work: its
helper checks sys.stdin.isatty() and refuses with Invalid_arguments before it
ever shows the password prompt. So this runs the client on a pseudo-terminal
and answers each prompt it recognises, by its exact text.

The rule throughout is to stop rather than guess. Each prompt is answered at
most once, so one run never tries a bad password twice. Anything
unrecognised, and any decision that belongs to a person, ends the run.
Success needs the client's exit status and its files on disk to agree.

Secrets are read from files named on the command line, so they never reach
the process table or the environment.
"""

import argparse
import fcntl
import glob
import os
import pty
import pwd
import re
import select
import signal
import sys
import time

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")

# Failures worth trying again. Anything else is left alone, because retrying a
# rejected password is how an account gets locked. The module's retry timer
# only acts while this file exists.
RETRY_MARKER = ".setup-retry"
TRANSIENT = re.compile(
    r"Failed to establish a new connection|Failed to connect"
    r"|Name or service not known|Temporary failure|Network is unreachable"
    r"|timed out|gateway timeout",
    re.I,
)


class SetupFailed(Exception):
    pass


def log(message):
    print("idrive-setup: " + message, file=sys.stderr, flush=True)


def read_secret(path, label):
    try:
        with open(path, encoding="utf-8") as handle:
            value = handle.read().rstrip()
    except OSError:
        raise SetupFailed(
            "cannot read the %s file %s; it must exist and be readable by "
            "this service" % (label, path)
        )
    if not value:
        raise SetupFailed("%s is empty" % path)
    if "\n" in value:
        raise SetupFailed("%s holds more than one line" % path)
    return value


def plan(username, password, key):
    """Prompts as (label, ending, context, answer), checked in order.

    `ending` must match the end of the output. `context` must appear in the
    text since the last answer, which is what tells apart the several menus
    that all end in "Enter your choice:". An answer of None stops the run
    with the message in the fifth field.
    """
    choice = r"Enter your choice:\s*$"
    no_key = (
        "this account uses a private encryption key, but "
        "services.idrive.encryptionKeyFile is not set"
    )
    return [
        ("login method", choice, "Login using IDrive credentials", "1", None),
        ("username", r"Enter your IDrive username:\s*$", None, username, None),
        ("password", r"Enter your IDrive password:\s*$", None, password, None),
        (
            "encryption type",
            choice,
            "Default encryption key",
            "2" if key else "1",
            None,
        ),
        (
            "backup location",
            choice,
            "Create new Backup Location",
            None,
            "this account already has backup locations and one must be "
            "chosen; a wrong choice orphans an existing backup set, so run "
            "`idrive --account-setting` by hand once",
        ),
        ("new key", r"Set your encryption key:\s*$", None, key, no_key),
        ("key confirmation", r"Confirm your encryption key:\s*$", None, key, no_key),
        ("existing key", r"Enter your encryption key:\s*$", None, key, no_key),
        (
            "two-factor code",
            r"(verification code|one-time code)[^\n]*:?\s*$",
            None,
            None,
            "this account needs a two-factor code, which a static secret "
            "cannot answer; run `idrive --account-setting` by hand once",
        ),
        # Declining leaves an already linked profile as it is. The files are
        # then all that can say so, see the exit status handling below.
        (
            "reconfigure",
            r"Do you want to reconfigure it\? \(y/n\)\s*$",
            None,
            "n",
            None,
        ),
    ]


def is_linked(state, want_key=False):
    """True once a completed login's files exist.

    Starting the client is enough to create user_profile/<user>/.trace, so a
    non-empty user_profile proves nothing. These are written by the login
    itself: the encoded server credential, the account's configuration, and
    the cached name of the logged-in user. With a private key there is also
    the encoded key, which the client removes again if the server rejects it.
    """
    user = pwd.getpwuid(os.getuid()).pw_name
    cached = os.path.join(state, "cache", "idriveuser.txt")
    if not os.path.isfile(cached) or os.path.getsize(cached) == 0:
        return False
    for profile in glob.glob(os.path.join(glob.escape(state), "user_profile", glob.escape(user), "*")):
        credential = os.path.join(profile, ".userInfo", "IDPWD")
        config = os.path.join(profile, "CONFIGURATION_FILE")
        if (
            os.path.isfile(credential)
            and os.path.getsize(credential) > 0
            and os.path.isfile(config)
        ):
            private = os.path.join(profile, ".userInfo", "IDPVT")
            if not want_key or (os.path.isfile(private) and os.path.getsize(private) > 0):
                return True
    return False


def drive(args, prompts, secrets):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.setdefault("TERM", "dumb")
        os.execv(args.client, [args.client, "--account-setting", "--auto-setup"])

    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    def clean(text):
        for secret in secrets:
            text = text.replace(secret, "[redacted]")
        return text

    def stop():
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)

    # `section` is the text since the last answer. `transcript` keeps it all
    # for the log, and is only ever printed through clean().
    transcript = ""
    section = ""
    answered = set()
    status = None
    started = last_output = time.monotonic()

    try:
        while True:
            now = time.monotonic()
            if now - started > args.timeout:
                raise SetupFailed("the client did not finish in time")
            if now - last_output > args.idle_timeout:
                raise SetupFailed("the client stopped at something this cannot answer")

            ready, _, _ = select.select([fd], [], [], 0.2)
            data = b""
            if ready:
                try:
                    data = os.read(fd, 4096)
                except BlockingIOError:
                    pass
                except OSError:
                    # EIO: the last holder of the terminal has gone.
                    data = b""
            if data:
                text = ANSI.sub("", data.decode("utf-8", "replace")).replace("\r", "")
                transcript += text
                section += text
                last_output = time.monotonic()
            else:
                # Polled rather than waiting for end of file: anything the
                # client left running could hold the terminal open forever.
                done, code = os.waitpid(pid, os.WNOHANG)
                if done:
                    status = os.waitstatus_to_exitcode(code)
                    break

            for label, ending, context, answer, refusal in prompts:
                if not re.search(ending, section):
                    continue
                if context is not None and context not in section:
                    continue
                if answer is None:
                    raise SetupFailed(refusal)
                if label in answered:
                    raise SetupFailed("the client asked for the %s again" % label)
                answered.add(label)
                log("answering: " + label)
                # Let the client finish turning off echo and flushing input
                # before the answer arrives, or it can be thrown away.
                time.sleep(0.3)
                os.write(fd, (answer + "\n").encode("utf-8"))
                section = ""
                last_output = time.monotonic()
                break
    except SetupFailed:
        stop()
        log("client output so far:")
        print(clean(transcript), file=sys.stderr, flush=True)
        raise

    # Drain whatever the client wrote just before it exited.
    try:
        while True:
            data = os.read(fd, 4096)
            if not data:
                break
            transcript += ANSI.sub("", data.decode("utf-8", "replace")).replace("\r", "")
    except OSError:
        pass

    return status, clean(transcript), "reconfigure" in answered


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--client", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--username")
    parser.add_argument("--username-file")
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--encryption-key-file")
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--idle-timeout", type=float, default=120)
    args = parser.parse_args()

    marker = os.path.join(args.state, RETRY_MARKER)
    if os.path.exists(marker):
        os.remove(marker)

    try:
        username = args.username
        if args.username_file:
            username = read_secret(args.username_file, "username")
        password = read_secret(args.password_file, "password")
        key = None
        if args.encryption_key_file:
            key = read_secret(args.encryption_key_file, "encryption key")
            if re.search(r"\s", key):
                # The client refuses these too, but only after the password
                # has been sent.
                raise SetupFailed(
                    "the encryption key contains whitespace, which IDrive "
                    "does not accept"
                )

        secrets = [password] + ([key] if key else [])
        status, transcript, declined = drive(args, plan(username, password, key), secrets)

        if "_helpers__servicepath" in transcript:
            log("client output:")
            print(transcript, file=sys.stderr, flush=True)
            raise SetupFailed(
                "the vendored Python helper could not resolve its service "
                "path, so no login can succeed. This is a packaging fault, "
                "not a credential problem."
            )

        # The client exits 0 after a rejected key as well, by which point
        # the login's files already exist.
        if "Invalid encryption key" in transcript:
            log("client output:")
            print(transcript, file=sys.stderr, flush=True)
            raise SetupFailed("IDrive rejected the encryption key")

        # Declining to reconfigure has no documented exit status, so only
        # the files can decide that case. Nothing is typed in that case
        # either, so a key cannot be expected to have been stored.
        want_key = bool(key) and not declined
        if (status == 0 or declined) and is_linked(args.state, want_key):
            log("account linked")
            return 0

        log("client output:")
        print(transcript, file=sys.stderr, flush=True)
        if TRANSIENT.search(transcript):
            with open(marker, "w", encoding="utf-8"):
                pass
            log("this looks like a network failure, so setup will retry")
        raise SetupFailed(
            "the client exited with status %s and the account is %s"
            % (status, "linked" if is_linked(args.state, want_key) else "not linked")
        )
    except SetupFailed as failure:
        log(str(failure))
        return 1


if __name__ == "__main__":
    sys.exit(main())
