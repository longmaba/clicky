#!/usr/bin/env python3
"""Sign Clicky with a persistent, private local certificate.

The identity is held outside the checkout in a dedicated encrypted keychain.
Explicit --setup adds current-user trust for this certificate's Code Signing
policy only. System trust, Gatekeeper policy, and TCC databases are not modified.
This is development signing, not Developer ID distribution/notarization.
"""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_STATE = Path.home() / "Library/Application Support/Clicky Build/Signing"


def run(args, *, data=None, sensitive=()):
    result = subprocess.run([str(a) for a in args], input=data, capture_output=True)
    if result.returncode:
        message = result.stderr.decode(errors="replace") or result.stdout.decode(errors="replace")
        for secret in sensitive:
            message = message.replace(secret, "[redacted]")
        raise RuntimeError(f"{Path(args[0]).name} failed: {message.strip()}")
    return result.stdout


def keychain_helper():
    source = PROJECT / "scripts/signing_keychain.swift"
    helper = PROJECT / "build/tools/clicky-keychain"
    if not helper.exists() or source.stat().st_mtime > helper.stat().st_mtime:
        helper.parent.mkdir(parents=True, exist_ok=True)
        run(["/usr/bin/xcrun", "swiftc", source, "-o", helper])
    return helper


def open_keychain(state, password, create=False):
    request = {"path": str(state / "clicky.keychain-db"), "password": password,
               "operation": "create" if create else "unlock"}
    run([keychain_helper()], data=json.dumps(request).encode(), sensitive=(password,))


def create_identity(state):
    # Never silently rotate an incomplete identity: that would lose permissions.
    if any(state.iterdir()):
        raise RuntimeError(f"Signing setup is incomplete in {state}; recover it instead of replacing the certificate.")
    password = secrets.token_hex(32)
    (state / "keychain-password").write_text(password)
    open_keychain(state, password, create=True)
    with tempfile.TemporaryDirectory(prefix="clicky-signing-") as temporary:
        temp = Path(temporary)
        config = temp / "certificate.cnf"
        config.write_text("""[req]
distinguished_name = identity
x509_extensions = code_signing
prompt = no
[identity]
CN = Clicky Local Development
O = Clicky
[code_signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
        key = temp / "private.pem"
        certificate = state / "certificate.pem"
        run(["/usr/bin/openssl", "genrsa", "-out", key, "3072"])
        run(["/usr/bin/openssl", "req", "-new", "-x509", "-key", key,
             "-sha256", "-days", "3650", "-config", config, "-out", certificate])
        keychain = state / "clicky.keychain-db"
        run(["/usr/bin/security", "import", key, "-k", keychain, "-t", "priv", "-f", "openssl",
             "-x", "-T", "/usr/bin/codesign"])
        run(["/usr/bin/security", "import", certificate, "-k", keychain, "-t", "cert", "-f", "pemseq"])
        # Limit unattended key use to Apple's code-signing tooling, on this
        # dedicated keychain only. The password is sent over stdin, not argv.
        command = shlex.join(["set-key-partition-list", "-S", "apple-tool:,apple:", "-s",
                              "-k", password, str(keychain)]) + "\n"
        run(["/usr/bin/security", "-i"], data=command.encode(), sensitive=(password,))
    der = run(["/usr/bin/openssl", "x509", "-in", state / "certificate.pem", "-outform", "DER"])
    metadata = {"schemaVersion": 1, "certificateSHA1": hashlib.sha1(der).hexdigest().upper(),
                "certificateSHA256": hashlib.sha256(der).hexdigest(),
                "name": "Clicky Local Development"}
    (state / "identity.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def identity(state, allow_create=False):
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    state.chmod(0o700)
    if not (state / "identity.json").exists():
        if not allow_create:
            raise RuntimeError("Local signing is not set up. Run: python3 scripts/sign_app.py --setup")
        return create_identity(state)
    metadata = json.loads((state / "identity.json").read_text())
    der = run(["/usr/bin/openssl", "x509", "-in", state / "certificate.pem", "-outform", "DER"])
    if hashlib.sha256(der).hexdigest() != metadata["certificateSHA256"]:
        raise RuntimeError("The local signing certificate changed; refusing to change Clicky's identity.")
    open_keychain(state, (state / "keychain-password").read_text())
    return metadata


@contextmanager
def signing_search_list(state):
    # codesign's chain lookup still uses the search list even with --keychain.
    # Keep all existing entries and the default, and restore the exact list after
    # signing. Serialize Clicky's builds; never overwrite a concurrent user edit.
    with (state / "build.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        command = ["/usr/bin/security", "list-keychains", "-d", "user"]
        original = shlex.split(run(command).decode())
        keychain = str(state / "clicky.keychain-db")
        wanted = original if keychain in original else [*original, keychain]
        if wanted != original:
            run([*command, "-s", *wanted])
        try:
            yield
        finally:
            current = shlex.split(run(command).decode())
            if wanted != original and current == wanted:
                run([*command, "-s", *original])


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, nargs="?")
    parser.add_argument("--setup", action="store_true", help="Create/reuse the local identity and add current-user Code Signing trust")
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    args = parser.parse_args()
    if args.setup:
        metadata = identity(args.state, allow_create=True)
        run(["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
             "-k", args.state / "clicky.keychain-db", args.state / "certificate.pem"])
        print(f"Local signing ready: {metadata['certificateSHA1']}.")
        return
    if args.app is None:
        parser.error("Supply the Clicky.app path, or use --setup once before building")
    app = args.app.resolve()
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != "dev.clicky.app":
        raise RuntimeError("This signing helper only signs the Clicky bundle identifier.")
    metadata = identity(args.state)
    fingerprint = metadata["certificateSHA1"]
    requirement = f'designated => identifier "dev.clicky.app" and certificate leaf = H"{fingerprint}"'
    with signing_search_list(args.state):
        run(["/usr/bin/codesign", "--force", "--sign", fingerprint, "--keychain", args.state / "clicky.keychain-db",
             "--options", "runtime", "--timestamp=none", "--requirements", "=" + requirement, app])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    print(f"Signed Clicky with reusable local certificate {fingerprint}.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        raise SystemExit(str(error))
