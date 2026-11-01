#!/usr/bin/env python3
"""Install this checkout's privacy hooks and a checksum-pinned local secret scanner."""
import argparse
import getpass
import hashlib
import io
import json
import os
import platform
import plistlib
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

from privacy_check import ROOT, common_dir

VERSION = "8.30.1"
ARCHIVES = {
    ("Darwin", "arm64"): ("darwin_arm64", "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"),
    ("Darwin", "x86_64"): ("darwin_x64", "dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"),
    ("Linux", "x86_64"): ("linux_x64", "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"),
    ("Linux", "aarch64"): ("linux_arm64", "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"),
    ("Linux", "arm64"): ("linux_arm64", "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"),
}


def config(name):
    result = subprocess.run(["git", "-C", str(ROOT), "config", "--get", name], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def install_scanner(directory):
    binary = directory / "gitleaks"
    receipt = directory / "scanner.json"
    target, expected = ARCHIVES[(platform.system(), platform.machine())]
    if binary.is_file() and receipt.is_file():
        prior = json.loads(receipt.read_text())
        if (prior.get("archive_sha256") == expected and prior.get("version") == VERSION
                and prior.get("binary_sha256") == hashlib.sha256(binary.read_bytes()).hexdigest()):
            return
    url = "https://github.com/gitleaks/gitleaks/releases/download/v{0}/gitleaks_{0}_{1}.tar.gz".format(VERSION, target)
    with urllib.request.urlopen(url, timeout=30) as response:
        archive = response.read(30 * 1024 * 1024)
    if hashlib.sha256(archive).hexdigest() != expected:
        raise RuntimeError("scanner checksum mismatch")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        member = tar.getmember("gitleaks")
        if not member.isfile():
            raise RuntimeError("invalid scanner archive")
        data = tar.extractfile(member).read()
    # Extract only the named regular file; never unpack archive paths or symlinks.
    with tempfile.NamedTemporaryFile(dir=directory, delete=False) as temporary:
        temporary.write(data)
        staged = Path(temporary.name)
    staged.chmod(0o700)
    staged.replace(binary)
    receipt.write_text(json.dumps({"version": VERSION, "archive_sha256": expected,
                                   "binary_sha256": hashlib.sha256(data).hexdigest()}) + "\n")
    receipt.chmod(0o600)


def seed_private_terms(directory):
    path = directory / "private-terms.json"
    terms = set(json.loads(path.read_text())["terms"]) if path.exists() else set()
    name = config("user.name")
    generic = {"developer", "runner", "ubuntu", "root", "admin", "user", "tester", "circe", "codex", "claude"}
    candidates = [config("user.email"), name, getpass.getuser(), str(Path.home())]
    candidates.extend(piece for piece in re.split(r"\W+", name) if len(piece) >= 5)
    # Protect the user's actual cloud/SSH identifiers without putting them in tracked policy.
    # Read only SavedComputers, never Keychain or cloud credential databases; do not change app state.
    preferences = Path.home() / "Library/Preferences/com.circe.desktop.plist"
    if platform.system() == "Darwin" and preferences.is_file():
        with preferences.open("rb") as source:
            saved = plistlib.load(source).get("savedComputers.v1", [])
        if isinstance(saved, (str, bytes)):
            saved = json.loads(saved)
        for computer in saved:
            connection = computer.get("connection", {})
            cloud = connection.get("googleCloud", {})
            for field in ["instance", "project", "account", "user", "hostKeyAlias"]:
                value = cloud.get(field)
                if isinstance(value, str):
                    candidates.append(value)
                    if field == "hostKeyAlias" and re.fullmatch(r"circe-gce-[0-9]+", value):
                        candidates.append(value.removeprefix("circe-gce-"))
            destination = connection.get("ssh", {}).get("destination")
            if isinstance(destination, str):
                candidates.append(destination)
    for value in candidates:
        if len(value) >= 3 and value.casefold() not in generic:
            terms.add(value)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump({"terms": sorted(terms)}, output, indent=2)
        output.write("\n")
    path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-only", action="store_true", help="Install scanner only, for CI; no hooks or private identity changes.")
    args = parser.parse_args()
    try:
        if not args.tools_only:
            current = config("core.hooksPath")
            expected = str(ROOT / ".githooks")
            if current and current not in {".githooks", expected}:
                raise RuntimeError("existing hooks must be integrated manually")
            if not current:
                hooks = common_dir(ROOT) / "hooks"
                if any((hooks / n).exists() for n in ["pre-commit", "pre-push"]):
                    raise RuntimeError("existing hooks must be integrated manually")
        directory = common_dir(ROOT) / "circe-privacy"
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory.chmod(0o700)
        install_scanner(directory)
        if not args.tools_only:
            seed_private_terms(directory)
            for name in ["pre-commit", "pre-push"]:
                (ROOT / ".githooks" / name).chmod(0o755)
            subprocess.run(["git", "-C", str(ROOT), "config", "--local", "core.hooksPath", ".githooks"], check=True)
        print("Privacy scanner installed." if args.tools_only else "Privacy hooks enabled; private identity terms stay in local Git metadata.")
        return 0
    except Exception:
        print("Privacy setup failed. Check network/scanner support and existing hook configuration. Existing custom hooks are never overwritten; integrate them explicitly.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
