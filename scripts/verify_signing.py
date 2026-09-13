#!/usr/bin/env python3
"""Verify update identity and tamper rejection on disposable copies of Clicky."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]


def command(args, expected=0):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True)
    if result.returncode != expected:
        raise SystemExit(result.stderr or result.stdout)
    return result.stdout + result.stderr


def signature(app):
    output = command(["codesign", "-d", "-r-", "-vvv", app])
    requirement = re.search(r"^designated => (.+)$", output, re.MULTILINE).group(1)
    digest = re.search(r"^CDHash=(.+)$", output, re.MULTILINE).group(1)
    assert "certificate leaf" in requirement and "cdhash" not in requirement.lower()
    return requirement, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, nargs="?", default=PROJECT / "dist/Clicky.app")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    search = ["security", "list-keychains", "-d", "user"]
    original_list = shlex.split(command(search))
    requirement, original_hash = signature(args.app)
    command(["codesign", "--verify", "--deep", "--strict", args.app])
    with tempfile.TemporaryDirectory(prefix="clicky-identity-test-") as temporary:
        copy = Path(temporary) / "Clicky.app"
        command(["ditto", args.app, copy])
        plist = copy / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["CFBundleVersion"] = str(int(info["CFBundleVersion"]) + 1)
        plist.write_bytes(plistlib.dumps(info))
        command(["python3", PROJECT / "scripts/sign_app.py", copy])
        updated_requirement, updated_hash = signature(copy)
        assert original_hash != updated_hash, "Update must change the signed contents"
        assert requirement == updated_requirement, "Update must preserve cryptographic identity"
        command(["codesign", "--verify", "--deep", "--strict", "-R", "=" + requirement, copy])
        info["CFBundleVersion"] = "unsigned-edit"
        plist.write_bytes(plistlib.dumps(info))
        rejected = subprocess.run(["codesign", "--verify", "--strict", str(copy)], capture_output=True).returncode != 0
        assert rejected, "Unsigned changes must be rejected"
    assert original_list == shlex.split(command(search)), "Signing must restore the user's keychain search list"
    report = {"sameIdentityAfterChangedBuild": True, "unsignedChangesRejected": True,
              "keychainSearchListRestored": True, "designatedRequirement": requirement,
              "originalCDHash": original_hash, "updatedCDHash": updated_hash,
              "permissionRetention": "Requires a user grant and subsequent live update check; not inferred from signature validation"}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("Passed: changed build retains certificate identity; tampering rejected; keychain list restored.")


if __name__ == "__main__":
    main()
