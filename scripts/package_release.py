#!/usr/bin/env python3
"""Package the existing signed app and public notices without changing the app.

Run on macOS after scripts/build.sh. The version is read from the bundle and
inserted into INSTALL.txt. ditto preserves macOS bundle metadata. Both the
staged copy and an extracted ZIP copy must pass strict signature verification
before dist/Clicky-macOS-arm64.zip is atomically replaced.
"""

import hashlib
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "dist" / "Clicky.app"
OUTPUT = ROOT / "dist" / "Clicky-macOS-arm64.zip"
FORBIDDEN_SUFFIXES = {".mp4", ".webm", ".pem", ".p12", ".pfx", ".key"}
FORBIDDEN_NAMES = {"keychain-password", "identity.json", "signing-identity.json"}
PUBLIC_ROOTS = {"Clicky.app", "LICENSE", "THIRD_PARTY_NOTICES.md", "INSTALL.txt", "__MACOSX"}


def run(*command):
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def verify_signature(app):
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))


def allowed_name(name):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        return False
    for part in path.parts:
        lower = part.lower()
        # Resource forks use ._ prefixes; apply the same checks to their names.
        lower = lower.removeprefix("._")
        if (lower.startswith(".env") or lower in FORBIDDEN_NAMES
                or ".keychain" in lower
                or PurePosixPath(lower).suffix in FORBIDDEN_SUFFIXES):
            return False
    return True


def verify_contents(archive, version, build):
    with zipfile.ZipFile(archive) as zipped:
        names = zipped.namelist()
        for name in names:
            if not allowed_name(name) or PurePosixPath(name).parts[0] not in PUBLIC_ROOTS:
                raise ValueError(f"Unexpected or private file in archive: {name}")
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "INSTALL.txt",
                     "Clicky.app/Contents/Info.plist", "Clicky.app/Contents/MacOS/Clicky"):
            if name not in names:
                raise ValueError(f"Missing release file: {name}")
        info = plistlib.loads(zipped.read("Clicky.app/Contents/Info.plist"))
        if (info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (version, build):
            raise ValueError("Packaged app version changed during packaging")
        if f"Clicky {version} (build {build})" not in zipped.read("INSTALL.txt").decode():
            raise ValueError("Install instructions do not match the packaged version")
        damaged = zipped.testzip()
        if damaged:
            raise ValueError(f"Archive integrity check failed: {damaged}")
        return len(names)


def main():
    if sys.platform != "darwin":
        raise SystemExit("Release packaging requires macOS codesign and ditto")
    try:
        if not APP.is_dir() or APP.is_symlink():
            raise ValueError("Build dist/Clicky.app before packaging a release")
        verify_signature(APP)
        info = plistlib.loads((APP / "Contents" / "Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != "dev.clicky.app":
            raise ValueError("Expected Clicky's dev.clicky.app bundle identifier")
        version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
        if not all(isinstance(value, str) and value for value in (version, build)):
            raise ValueError("The app bundle must contain a version and build number")
        run("/usr/bin/lipo", str(APP / "Contents" / "MacOS" / "Clicky"), "-verify_arch", "arm64")
        original_executable = hashlib.sha256((APP / "Contents" / "MacOS" / "Clicky").read_bytes()).hexdigest()
        instructions = (ROOT / "docs" / "INSTALL.txt").read_text()
        for token, replacement in (("{{VERSION}}", version), ("{{BUILD}}", build)):
            if token not in instructions:
                raise ValueError(f"Missing release instruction token {token}")
            instructions = instructions.replace(token, replacement)
        scratch = ROOT / "build"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="release-", dir=scratch) as directory:
            staging = Path(directory) / "payload"
            staging.mkdir()
            run("/usr/bin/ditto", str(APP), str(staging / "Clicky.app"))
            for filename in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
                shutil.copy2(ROOT / filename, staging / filename)
            install = staging / "INSTALL.txt"
            install.write_text(instructions)
            shutil.copystat(ROOT / "docs" / "INSTALL.txt", install)
            for path in staging.rglob("*"):
                if not allowed_name(path.relative_to(staging).as_posix()):
                    raise ValueError(f"Unexpected source media or signing file: {path.name}")
                if path.is_symlink() and not path.resolve().is_relative_to(staging):
                    raise ValueError(f"External symbolic link in release: {path.name}")
            verify_signature(staging / "Clicky.app")
            # ditto's ZIP metadata includes access times. Pin those on the
            # temporary copy to its preserved modification times so merely
            # reading/verifying the source does not change the release bytes.
            # No timestamps or files in dist/Clicky.app are modified.
            for path in staging.rglob("*"):
                metadata = path.lstat()
                os.utime(path, ns=(metadata.st_mtime_ns, metadata.st_mtime_ns), follow_symlinks=False)
            archive = Path(directory) / OUTPUT.name
            run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", str(staging), str(archive))
            count = verify_contents(archive, version, build)
            extracted = Path(directory) / "extracted"
            run("/usr/bin/ditto", "-x", "-k", str(archive), str(extracted))
            verify_signature(extracted / "Clicky.app")
            extracted_executable = hashlib.sha256(
                (extracted / "Clicky.app" / "Contents" / "MacOS" / "Clicky").read_bytes()).hexdigest()
            if extracted_executable != original_executable:
                raise ValueError("Executable changed during release packaging")
            verify_signature(APP)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            archive.replace(OUTPUT)
        print(f"Packaged Clicky {version} (build {build}): {OUTPUT}")
        print(f"Verified {count} ZIP entries, signature roundtrip, public notices, and excluded private/source files")
        print(f"SHA-256: {digest}")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            detail = error.stderr.strip() or str(error)
        else:
            detail = str(error)
        raise SystemExit(f"package_release: {detail}") from error


if __name__ == "__main__":
    main()
