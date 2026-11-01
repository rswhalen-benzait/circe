#!/usr/bin/env python3
"""Check exact Git snapshots without printing matched private data. Python 3.9+."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

MAX_BLOB = 20 * 1024 * 1024
EMAIL = re.compile(r"(?<![\w.+%-])[\w.+%-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}")
HOME_PATH = re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+(?:/|\b)")
KEY = re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----")
TOKEN = re.compile(r"(?:AIza[\w-]{30,}|AKIA[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{15,}|ya29\.[\w-]{20,})")
SHA = re.compile(r"[0-9a-f]{40,64}\Z")
ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    rule: str


def git(repo, *args, input=None):
    result = subprocess.run(["git", "-C", str(repo), *args], input=input,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError("Git snapshot could not be read; fetch missing history or resolve the index and retry.")
    return result.stdout


def common_dir(repo):
    path = Path(git(repo, "rev-parse", "--git-common-dir").decode().strip())
    return path.resolve() if path.is_absolute() else (repo / path).resolve()


def local_terms(repo):
    path = common_dir(repo) / "circe-privacy/private-terms.json"
    if not path.exists():
        return []
    terms = json.loads(path.read_text())["terms"]
    if not isinstance(terms, list) or any(not isinstance(t, str) or len(t) < 3 for t in terms):
        raise RuntimeError("Private-term configuration is invalid; repair the local configuration before publishing.")
    return terms


def private_match(text, term):
    # Cloud/OS Login names often join personal terms with underscores.
    return re.search(r"(?<![^\W_])" + re.escape(term) + r"(?![^\W_])", text, re.IGNORECASE)


def reserved_email(value):
    domain = value.rsplit("@", 1)[1].lower()
    return (domain in {"example.com", "example.org", "example.net", "localhost"}
            or any(domain.endswith("." + d) for d in ["example.com", "example.org", "example.net"])
            or domain.endswith((".example", ".invalid", ".test", ".localhost")))


def safe_path(path, terms):
    path = EMAIL.sub("[redacted-email]", path)
    path = HOME_PATH.sub("[redacted-home]/", path)
    for term in sorted(terms, key=len, reverse=True):
        path = re.sub(re.escape(term), "[private]", path, flags=re.IGNORECASE)
    return json.dumps(path, ensure_ascii=True)


def approved_binaries():
    return json.loads((ROOT / "scripts/privacy-approved-assets.json").read_text())


def scan_blob(path, data, private_terms=()):
    findings = []
    parts = PurePosixPath(path).parts
    name = parts[-1] if parts else path
    forbidden = {".ssh", ".gnupg", ".aws", ".gcloud", "__pycache__", "Caches"}
    credentials = {"identity.json", "known_hosts", "credentials.db", "access_tokens.db", "private-terms.json",
                   "application_default_credentials.json", "credentials.json", "cookies.txt"}
    if (any(p in forbidden for p in parts) or name in credentials
            or name.endswith((".pyc", ".pyo", ".keychain", ".keychain-db", ".p12", ".pfx"))
            or (name.startswith(".env") and name not in {".env.example", ".env.sample"})
            or name in {"id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"}):
        findings.append(Finding(path, 0, "credential-or-cache-file"))
    if any(private_match(path, t) for t in private_terms):
        findings.append(Finding(path, 0, "private-identifier-in-path"))
    if any(not reserved_email(m.group()) for m in EMAIL.finditer(path)):
        findings.append(Finding(path, 0, "personal-email-in-path"))
    if len(data) > MAX_BLOB:
        return findings + [Finding(path, 0, "file-too-large-to-audit")]
    try:
        text = data.decode("utf-16") if data.startswith((b"\xff\xfe", b"\xfe\xff")) else data.decode("utf-8")
        if "\0" in text:
            raise UnicodeError()
    except UnicodeError:
        if approved_binaries().get(path) != hashlib.sha256(data).hexdigest():
            findings.append(Finding(path, 0, "unreviewed-binary-asset"))
        return findings
    for line_no, line in enumerate(text.splitlines(), 1):
        if any(not reserved_email(m.group()) for m in EMAIL.finditer(line)):
            findings.append(Finding(path, line_no, "non-example-email"))
        if HOME_PATH.search(line):
            findings.append(Finding(path, line_no, "literal-user-home-path"))
        if KEY.search(line) or TOKEN.search(line):
            findings.append(Finding(path, line_no, "credential-material"))
        if any(private_match(line, t) for t in private_terms):
            findings.append(Finding(path, line_no, "private-identifier"))
    return findings


def git_tree(repo, revision):
    result = {}
    for item in git(repo, "ls-tree", "-rz", "--full-tree", revision).split(b"\0"):
        if not item:
            continue
        meta, name = item.split(b"\t", 1)
        mode, kind, sha = meta.split()
        path = name.decode("utf-8", errors="surrogateescape")
        if kind != b"blob" or mode == b"120000":
            # Symlinks and submodules must not hide content outside the audited snapshot.
            raise RuntimeError("Snapshot contains an unaudited symlink or submodule; explicit review is required.")
        size = int(git(repo, "cat-file", "-s", sha.decode()))
        if size > MAX_BLOB:
            raise RuntimeError("Snapshot contains a file too large to audit; remove it before publishing.")
        result[path] = git(repo, "cat-file", "blob", sha.decode())
    return result


def outgoing_commits(repo, records, remote):
    commits = []
    remotes = git(repo, "remote").decode().splitlines()
    for local_ref, local_sha, remote_ref, remote_sha in records:
        if not SHA.fullmatch(local_sha) or not SHA.fullmatch(remote_sha):
            raise RuntimeError("Push supplied an invalid object ID.")
        if set(local_sha) == {"0"}:
            continue
        # Tags are peeled to commits; non-commit tags are rejected rather than skipped.
        tip = git(repo, "rev-parse", "--verify", local_sha + "^{commit}").decode().strip()
        args = ["rev-list", "--reverse", tip]
        if set(remote_sha) != {"0"}:
            git(repo, "cat-file", "-e", remote_sha)
            args.append("^" + remote_sha)
        elif remote in remotes:
            # A new branch must not re-audit already published history from this destination.
            args.extend(["--not", "--remotes=" + remote])
        for sha in git(repo, *args).decode().splitlines():
            if sha not in commits:
                commits.append(sha)
    return commits


def verify_controls(repo, revision):
    controls = ["scripts/privacy_check.py", "scripts/install-privacy-hooks.py",
                "scripts/privacy-approved-assets.json", ".gitleaks.toml",
                ".githooks/pre-commit", ".githooks/pre-push", ".github/workflows/privacy.yml"]
    for name in controls:
        if git(repo, "show", revision + ":" + name) != (ROOT / name).read_bytes():
            raise RuntimeError("Publication controls differ from the audited snapshot; stage or restore the controls first.")
        if name.startswith(".githooks/"):
            mode = git(repo, "ls-tree", revision, "--", name).split()[0]
            if mode != b"100755" or not ((ROOT / name).stat().st_mode & 0o111):
                raise RuntimeError("Privacy hook execution permission was removed; restore it before publication.")


def gitleaks(repo, files, terms, metadata=None):
    managed = common_dir(repo) / "circe-privacy/gitleaks"
    executable = str(managed) if managed.is_file() else shutil.which("gitleaks")
    if not executable:
        raise RuntimeError("Secret scanner is unavailable. Run python3 scripts/install-privacy-hooks.py first.")
    with tempfile.TemporaryDirectory(prefix="circe-private-audit-") as directory:
        base = Path(directory)
        snapshot = base / "input"
        snapshot.mkdir(mode=0o700)
        metadata_names = {}
        inputs = {"files/" + path: data for path, data in files.items()}
        # Gitleaks' defaults skip its own config filename. Audit its bytes under a
        # separate namespace, so accidental credentials inside policy are still checked.
        if ".gitleaks.toml" in files:
            mapped = "policy/secret-scanner-config.txt"
            inputs[mapped] = files[".gitleaks.toml"]
            metadata_names[mapped] = ".gitleaks.toml"
        for key, data in (metadata or {}).items():
            mapped = "metadata/" + key + ".txt"
            metadata_names[mapped] = "<" + key + ">"
            inputs[mapped] = data
        for path, data in inputs.items():
            target = snapshot / path
            if target.is_absolute() and not target.resolve().is_relative_to(snapshot.resolve()):
                raise RuntimeError("Unsafe path in Git snapshot.")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        report = base / "report.json"
        proc = subprocess.run([executable, "dir", str(snapshot), "--config", str(ROOT / ".gitleaks.toml"),
                               "--redact=100", "--no-banner", "--no-color", "--log-level=error",
                               "--ignore-gitleaks-allow", "--gitleaks-ignore-path", str(base / "no-ignores"),
                               "--report-format=json", "--report-path", str(report)],
                              cwd=base, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode not in (0, 1) or not report.is_file():
            raise RuntimeError("Secret scanner failed; no clean result can be claimed.")
        records = json.loads(report.read_text())
        if proc.returncode == 1 and not records:
            raise RuntimeError("Secret scanner returned an incomplete result.")
        findings = []
        for record in records:
            path = str(Path(record["File"]).relative_to(snapshot))
            display = metadata_names.get(path, path.removeprefix("files/"))
            findings.append(Finding(display, record["StartLine"], "secret-scanner/" + record["RuleID"]))
        return findings


def check(repo, files, terms, metadata=None):
    findings = [f for path, data in files.items() for f in scan_blob(path, data, terms)]
    for key, data in (metadata or {}).items():
        findings.extend(scan_blob("<" + key + ">", data, terms))
    findings.extend(gitleaks(repo, files, terms, metadata))
    if findings:
        for f in findings[:50]:
            print("BLOCKED {}:{} [{}]".format(safe_path(f.path, terms), f.line, f.rule), file=sys.stderr)
        print("Privacy check blocked publication. Replace private data with fictional examples; do not bypass the check.", file=sys.stderr)
        return False
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--staged", action="store_true")
    mode.add_argument("--tracked", action="store_true")
    mode.add_argument("--pre-push", action="store_true")
    mode.add_argument("--range", nargs=2, metavar=("BASE", "HEAD"))
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--repo", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    repo = args.repo.resolve()
    try:
        terms = local_terms(repo)
        if args.staged:
            revision = git(repo, "write-tree").decode().strip()
            verify_controls(repo, revision)
            files = git_tree(repo, revision)
            clean = check(repo, files, terms)
        elif args.tracked:
            files = {}
            for raw in git(repo, "ls-files", "--cached", "-z").split(b"\0"):
                if raw:
                    name = raw.decode("utf-8", errors="surrogateescape")
                    path = repo / name
                    if path.is_symlink():
                        raise RuntimeError("Tracked symlink requires explicit review.")
                    if not path.is_file():
                        raise RuntimeError("Tracked content is missing; audit the index or restore the working file first.")
                    files[name] = path.read_bytes()
            clean = check(repo, files, terms)
        else:
            verify_controls(repo, "HEAD")
            records = []
            if args.pre_push:
                for line in sys.stdin:
                    row = line.split()
                    if len(row) != 4:
                        raise RuntimeError("Push record could not be audited.")
                    records.append(tuple(row))
                commits = outgoing_commits(repo, records, args.remote)
            else:
                base, head = args.range
                if not SHA.fullmatch(base) or not SHA.fullmatch(head):
                    raise RuntimeError("CI range must contain exact commit IDs.")
                commits = git(repo, "rev-list", "--reverse", head, "^" + base).decode().splitlines()
                # Recheck the tip even for an empty range.
                if head not in commits:
                    commits.append(head)
            clean = True
            for sha in commits:
                files = git_tree(repo, sha)
                metadata = {"commit-message": git(repo, "show", "-s", "--format=%B", sha)}
                if not check(repo, files, terms, metadata):
                    print("Affected commit: " + sha[:12], file=sys.stderr)
                    clean = False
            for local_ref, sha, remote_ref, _ in records:
                if set(sha) == {"0"}:
                    continue
                if not check(repo, {}, terms, {"local-ref": local_ref.encode(), "remote-ref": remote_ref.encode()}):
                    clean = False
                seen = set()
                while git(repo, "cat-file", "-t", sha).strip() == b"tag":
                    if sha in seen or len(seen) >= 100:
                        raise RuntimeError("Tag chain could not be audited.")
                    seen.add(sha)
                    header, separator, message = git(repo, "cat-file", "tag", sha).partition(b"\n\n")
                    if not separator:
                        raise RuntimeError("Tag message could not be audited.")
                    fields = dict(line.split(b" ", 1) for line in header.splitlines() if b" " in line)
                    name = fields[b"tag"]
                    if not check(repo, {}, terms, {"tag-message": message, "tag-name": name}):
                        clean = False
                    sha = fields[b"object"].decode()
                    if not SHA.fullmatch(sha):
                        raise RuntimeError("Tag target could not be audited.")
        if clean:
            print("Privacy check passed.")
        return 0 if clean else 1
    except Exception:
        # Exception strings can contain paths, tokens or private configuration: never echo them.
        print("Privacy audit could not complete. Check Git history, local scanner installation and private-term configuration; no data was approved.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
