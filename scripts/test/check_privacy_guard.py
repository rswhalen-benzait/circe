#!/usr/bin/env python3
"""Exercise privacy guards with synthetic canaries and temporary Git repositories only."""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("circe_privacy_check", ROOT / "scripts/privacy_check.py")
assert SPEC is not None and SPEC.loader is not None
privacy = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = privacy
SPEC.loader.exec_module(privacy)


def private_email() -> str:
    # Never contact this synthetic address. Fragments keep a deliberate negative-test canary
    # from looking like real data in the test source itself.
    return "canary-person" + "@" + "nonexample-canary" + ".dev"


def token_canary() -> str:
    return "gh" + "p" + "_" + "aB3" * 12


def key_canary() -> str:
    return "-----" + "BEGIN " + "PRIVATE KEY" + "-----\n" + "Zml4dHVyZQ==\n"


class BlobChecks(unittest.TestCase):
    def scan(self, text: str, *, path: str = "fixture.swift", terms: tuple[str, ...] = ()):
        return privacy.scan_blob(path, text.encode(), list(terms))

    def test_reserved_example_domains_are_allowed(self):
        domains = [
            "example.com", "example.org", "example.net", "vm.example.net",
            "work.example", "example.invalid", "service.test", "app.localhost",
        ]
        for domain in domains:
            with self.subTest(domain=domain):
                self.assertEqual([], self.scan("developer@" + domain))

    def test_nonexample_email_and_subdomain_confusion_are_blocked(self):
        for address in [private_email(), "person@" + "example.org" + ".dev"]:
            with self.subTest(case="nonexample address"):
                self.assertTrue(self.scan(address))

    def test_user_home_paths_are_blocked(self):
        for base in ["/" + "Users/", "/" + "home/"]:
            with self.subTest(platform=base):
                self.assertTrue(self.scan(base + "canary-user/.ssh/id_test"))
        self.assertEqual([], self.scan('$HOME/.ssh/google_compute_engine'))

    def test_private_key_and_token_are_blocked_without_echoing_values(self):
        for secret in [key_canary(), token_canary()]:
            with self.subTest(case="synthetic secret"):
                findings = self.scan("safe line\n" + secret)
                self.assertTrue(findings)
                self.assertNotIn(secret, repr(findings))
                self.assertTrue(all(isinstance(f.line, int) and f.line >= 1 for f in findings))
                self.assertTrue(all(f.path == "fixture.swift" and f.rule for f in findings))

    def test_credential_and_cache_paths_are_blocked_even_when_empty(self):
        paths = [
            ".env", ".ssh/id_test", "nested/identity.json", "nested/known_hosts",
            "nested/credentials.db", "nested/application_default_credentials.json",
            "cache/" + "__pycache__" + "/module.pyc",
        ]
        for path in paths:
            with self.subTest(path=path):
                self.assertTrue(privacy.scan_blob(path, b"", []))

    def test_unknown_binary_is_not_silently_skipped(self):
        with patch.object(privacy, "approved_binaries", return_value={}):
            self.assertTrue(privacy.scan_blob("new-image.png", bytes([0, 255, 17, 254, 128]), []))

    def test_binary_approval_is_tied_to_exact_path_and_hash(self):
        data = bytes([0, 255, 17, 254, 128])
        reviewed = {"reviewed.bin": hashlib.sha256(data).hexdigest()}
        with patch.object(privacy, "approved_binaries", return_value=reviewed):
            self.assertEqual([], privacy.scan_blob("reviewed.bin", data, []))
            self.assertTrue(privacy.scan_blob("reviewed.bin", data + b"changed", []))
            self.assertTrue(privacy.scan_blob("different.bin", data, []))

    def test_oversized_blob_is_not_silently_skipped(self):
        with patch.object(privacy, "MAX_BLOB", 32):
            self.assertTrue(privacy.scan_blob("oversized.txt", b"x" * 33, []))

    def test_utf16_email_is_not_silently_skipped(self):
        self.assertTrue(privacy.scan_blob("fixture.txt", private_email().encode("utf-16"), []))

    def test_private_terms_are_case_insensitive_and_findings_are_redacted(self):
        term = "private" + "-" + "canary" + "-" + "identifier"
        findings = self.scan("description: " + term.upper(), terms=(term,))
        self.assertTrue(findings)
        self.assertNotIn(term, repr(findings).lower())
        self.assertEqual([], self.scan("fictional demo-workstations", terms=(term,)))

    def test_private_terms_inside_os_login_style_names_are_blocked(self):
        term = "canary" + "person"
        findings = self.scan("login=" + "prefix_" + term.upper() + "_org", terms=(term,))
        self.assertTrue(findings)
        self.assertEqual([], self.scan("longer" + term + "word", terms=(term,)))

    def test_displayed_paths_redact_private_terms_addresses_and_newlines(self):
        term = "private" + "term"
        rendered = privacy.safe_path("notes/" + term + "/" + private_email() + "\nfile.txt", [term])
        self.assertNotIn(term, rendered.lower())
        self.assertNotIn(private_email(), rendered)
        self.assertNotIn("\n", rendered)

    def test_sensitive_filename_is_examined(self):
        address = private_email()
        findings = privacy.scan_blob("notes/" + address + ".txt", b"harmless", [])
        self.assertTrue(findings)


class GitFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="circe-privacy-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.git("init", "--quiet", "--object-format=sha1")
        self.git("config", "user.name", "Fixture Developer")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        # This repository exists only inside the test; avoid inheriting a developer's global hooks.
        self.git("config", "core.hooksPath", os.devnull)
        self.git("remote", "add", "origin", "https://example.invalid/demo/repository.git")
        self.base = self.commit("initial", {"note.txt": b"safe example\n"})
        self.git("update-ref", "refs/remotes/origin/main", self.base)

    def git(self, *arguments: str) -> str:
        env = os.environ.copy()
        env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})
        result = subprocess.run(
            ["git", "-C", str(self.repo), *arguments], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        if result.returncode:
            self.fail("Temporary Git fixture command failed: " + arguments[0])
        return result.stdout.strip()

    def commit(self, message: str, files: dict[str, bytes | None]) -> str:
        for path, contents in files.items():
            file = self.repo / path
            if contents is None:
                file.unlink(missing_ok=True)
            else:
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(contents)
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", message)
        return self.git("rev-parse", "HEAD")

    def outgoing(self, local: str, remote: str, *, local_ref: str = "refs/heads/main"):
        return privacy.outgoing_commits(
            self.repo, [(local_ref, local, "refs/heads/main", remote)], "origin"
        )

    def test_staged_blob_wins_over_clean_worktree(self):
        staged = private_email().encode()
        (self.repo / "note.txt").write_bytes(staged)
        self.git("add", "note.txt")
        (self.repo / "note.txt").write_text("safe example\n")
        tree = privacy.git_tree(self.repo, self.git("write-tree"))
        self.assertEqual(staged, tree["note.txt"])
        self.assertTrue(privacy.scan_blob("note.txt", tree["note.txt"], []))

    def test_unstaged_bad_data_cannot_replace_clean_index_for_scan(self):
        (self.repo / "note.txt").write_text(private_email())
        tree = privacy.git_tree(self.repo, self.git("write-tree"))
        self.assertEqual(b"safe example\n", tree["note.txt"])
        self.assertEqual([], privacy.scan_blob("note.txt", tree["note.txt"], []))

    def test_add_then_delete_is_in_outgoing_history(self):
        bad = self.commit("fixture canary", {"note.txt": private_email().encode()})
        clean = self.commit("remove fixture canary", {"note.txt": b"safe again\n"})
        outgoing = self.outgoing(clean, self.base)
        self.assertEqual({bad, clean}, set(outgoing))
        self.assertNotIn(self.base, outgoing)
        self.assertTrue(privacy.scan_blob("note.txt", privacy.git_tree(self.repo, bad)["note.txt"], []))
        self.assertEqual([], privacy.scan_blob("note.txt", privacy.git_tree(self.repo, clean)["note.txt"], []))

    def test_new_branch_excludes_history_already_published_to_that_remote(self):
        new = self.commit("new branch change", {"note.txt": b"new safe example\n"})
        self.assertEqual([new], self.outgoing(new, "0" * 40))

    def test_deleting_remote_ref_has_no_new_commit(self):
        self.assertEqual([], self.outgoing("0" * 40, self.base))

    def test_multiple_refs_do_not_duplicate_commits(self):
        new = self.commit("new safe revision", {"note.txt": b"updated example\n"})
        records = [
            ("refs/heads/main", new, "refs/heads/main", self.base),
            ("refs/heads/other", new, "refs/heads/other", "0" * 40),
        ]
        self.assertEqual([new], privacy.outgoing_commits(self.repo, records, "origin"))

    def test_annotated_tag_resolves_to_its_commits(self):
        new = self.commit("tagged safe revision", {"note.txt": b"updated example\n"})
        self.git("tag", "-a", "fixture-release", "-m", "Fixture release")
        tag = self.git("rev-parse", "refs/tags/fixture-release")
        records = [("refs/tags/fixture-release", tag, "refs/tags/fixture-release", "0" * 40)]
        self.assertEqual([new], privacy.outgoing_commits(self.repo, records, "origin"))

    def test_unknown_remote_commit_fails_closed(self):
        new = self.commit("safe revision", {"note.txt": b"updated example\n"})
        with self.assertRaises(Exception):
            self.outgoing(new, "f" * 40)

    def install_fixture_controls(self):
        names = ["scripts/privacy_check.py", "scripts/install-privacy-hooks.py",
                 "scripts/privacy-approved-assets.json", ".gitleaks.toml",
                 ".githooks/pre-commit", ".githooks/pre-push", ".github/workflows/privacy.yml"]
        for name in names:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fictional fixture control\n")
            if name.startswith(".githooks/"):
                path.chmod(0o755)
        self.git("add", "--all")
        return self.git("write-tree")

    def test_controls_must_match_exact_staged_bytes(self):
        tree = self.install_fixture_controls()
        with patch.object(privacy, "ROOT", self.repo):
            privacy.verify_controls(self.repo, tree)
            path = self.repo / "scripts/privacy_check.py"
            path.write_bytes(b"unstaged control replacement\n")
            with self.assertRaises(Exception):
                privacy.verify_controls(self.repo, tree)
            self.git("add", "scripts/privacy_check.py")
            privacy.verify_controls(self.repo, self.git("write-tree"))

    def test_clean_worktree_cannot_hide_a_different_staged_control(self):
        self.install_fixture_controls()
        path = self.repo / "scripts/privacy_check.py"
        path.write_bytes(b"staged control replacement\n")
        self.git("add", "scripts/privacy_check.py")
        path.write_bytes(b"fictional fixture control\n")
        with patch.object(privacy, "ROOT", self.repo):
            with self.assertRaises(Exception):
                privacy.verify_controls(self.repo, self.git("write-tree"))

    def test_staged_hook_must_keep_execution_permission(self):
        self.install_fixture_controls()
        self.git("update-index", "--chmod=-x", ".githooks/pre-commit")
        with patch.object(privacy, "ROOT", self.repo):
            with self.assertRaises(Exception):
                privacy.verify_controls(self.repo, self.git("write-tree"))
            self.git("update-index", "--chmod=+x", ".githooks/pre-commit")
            privacy.verify_controls(self.repo, self.git("write-tree"))

    def test_working_hook_must_keep_execution_permission(self):
        tree = self.install_fixture_controls()
        (self.repo / ".githooks/pre-push").chmod(0o644)
        with patch.object(privacy, "ROOT", self.repo):
            with self.assertRaises(Exception):
                privacy.verify_controls(self.repo, tree)

    def test_missing_staged_control_fails_closed(self):
        self.install_fixture_controls()
        self.git("rm", "--cached", "scripts/privacy_check.py")
        with patch.object(privacy, "ROOT", self.repo):
            with self.assertRaises(Exception):
                privacy.verify_controls(self.repo, self.git("write-tree"))

    def test_tracked_missing_file_fails_without_echoing_private_paths(self):
        (self.repo / "note.txt").unlink()
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(privacy, "check") as check:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                result = privacy.main(["--tracked", "--repo", str(self.repo)])
        self.assertEqual(2, result)
        check.assert_not_called()
        self.assertNotIn(str(self.repo), stderr.getvalue())
        self.assertIn("no data was approved", stderr.getvalue())

    def test_metadata_export_cannot_overwrite_tracked_content(self):
        files = {"audit-metadata/commit-message.txt": b"tracked original\n",
                 "metadata/commit-message.txt": b"second tracked original\n"}
        metadata = {"commit-message": b"separate commit message\n"}
        snapshots = []

        def scanner(arguments, **kwargs):
            snapshot = Path(arguments[2])
            snapshots.append({str(path.relative_to(snapshot)): path.read_bytes()
                              for path in snapshot.rglob("*") if path.is_file()})
            records = [
                {"File": str(snapshot / "files/audit-metadata/commit-message.txt"),
                 "StartLine": 1, "RuleID": "fixture-rule"},
                {"File": str(snapshot / "metadata/commit-message.txt"),
                 "StartLine": 1, "RuleID": "fixture-rule"},
            ]
            report = Path(arguments[arguments.index("--report-path") + 1])
            report.write_text(json.dumps(records))
            return subprocess.CompletedProcess(arguments, 1, stdout=b"", stderr=b"")

        with patch.object(privacy, "common_dir", return_value=self.repo / ".git"):
            with patch.object(privacy.shutil, "which", return_value="fixture-scanner"):
                with patch.object(privacy.subprocess, "run", side_effect=scanner):
                    findings = privacy.gitleaks(self.repo, files, [], metadata)
        self.assertEqual(1, len(snapshots))
        self.assertEqual(files["audit-metadata/commit-message.txt"],
                         snapshots[0]["files/audit-metadata/commit-message.txt"])
        self.assertEqual(files["metadata/commit-message.txt"],
                         snapshots[0]["files/metadata/commit-message.txt"])
        self.assertEqual(metadata["commit-message"], snapshots[0]["metadata/commit-message.txt"])
        self.assertEqual(["audit-metadata/commit-message.txt", "<commit-message>"],
                         [finding.path for finding in findings])

    def test_secret_scanner_failure_is_not_treated_as_clean(self):
        def scanner(arguments, **kwargs):
            return subprocess.CompletedProcess(arguments, 2, stdout=b"", stderr=private_email().encode())

        with patch.object(privacy, "common_dir", return_value=self.repo / ".git"):
            with patch.object(privacy.shutil, "which", return_value="fixture-scanner"):
                with patch.object(privacy.subprocess, "run", side_effect=scanner):
                    with self.assertRaises(RuntimeError) as raised:
                        privacy.gitleaks(self.repo, {"note.txt": b"safe"}, [])
        self.assertNotIn(private_email(), str(raised.exception))

    def test_secret_scanner_missing_report_is_not_treated_as_clean(self):
        def scanner(arguments, **kwargs):
            return subprocess.CompletedProcess(arguments, 0, stdout=b"", stderr=b"")

        with patch.object(privacy, "common_dir", return_value=self.repo / ".git"):
            with patch.object(privacy.shutil, "which", return_value="fixture-scanner"):
                with patch.object(privacy.subprocess, "run", side_effect=scanner):
                    with self.assertRaises(RuntimeError):
                        privacy.gitleaks(self.repo, {"note.txt": b"safe"}, [])

    def test_main_redacts_exception_contents(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(privacy, "local_terms", side_effect=RuntimeError(private_email())):
            with redirect_stdout(stdout), redirect_stderr(stderr):
                result = privacy.main(["--tracked", "--repo", str(self.repo)])
        self.assertEqual(2, result)
        self.assertNotIn(private_email(), stdout.getvalue() + stderr.getvalue())
        self.assertIn("no data was approved", stderr.getvalue())

    def run_push_check(self, records):
        captures = []

        def check(repo, files, terms, metadata=None):
            captures.append(dict(metadata or {}))
            return not any(privacy.scan_blob("metadata.txt", data, terms)
                           for data in (metadata or {}).values())

        incoming = "".join(" ".join(record) + "\n" for record in records)
        with patch.object(privacy, "verify_controls"), patch.object(privacy, "local_terms", return_value=[]):
            with patch.object(privacy, "check", side_effect=check), patch.object(sys, "stdin", io.StringIO(incoming)):
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    result = privacy.main(["--pre-push", "--repo", str(self.repo)])
        return result, captures

    def test_pushed_ref_names_are_audited_even_when_no_commits_are_new(self):
        private_ref = "refs/heads/" + private_email()
        records = [(private_ref, self.base, "refs/heads/main", self.base)]
        result, captures = self.run_push_check(records)
        self.assertEqual(1, result)
        self.assertTrue(any(data.get("local-ref") == private_ref.encode() for data in captures))

    def test_nested_annotated_tag_messages_are_all_audited(self):
        self.git("tag", "-a", "inner-fixture", "-m", private_email())
        self.git("tag", "-a", "outer-fixture", "inner-fixture", "-m", "Fictional outer message")
        tip = self.git("rev-parse", "refs/tags/outer-fixture")
        records = [("refs/tags/outer-fixture", tip, "refs/tags/outer-fixture", "0" * 40)]
        result, captures = self.run_push_check(records)
        self.assertEqual(1, result)
        self.assertTrue(any(data.get("tag-message", b"").strip() == private_email().encode()
                            for data in captures))
        self.assertTrue(any(data.get("tag-message", b"").strip() == b"Fictional outer message"
                            for data in captures))

    def test_annotated_tag_object_name_is_audited(self):
        name = private_email()
        self.git("tag", "-a", name, "-m", "Fictional message")
        tip = self.git("rev-parse", "refs/tags/" + name)
        records = [("refs/tags/release", tip, "refs/tags/release", "0" * 40)]
        result, captures = self.run_push_check(records)
        self.assertEqual(1, result)
        self.assertTrue(any(data.get("tag-name") == name.encode() for data in captures))

    def test_unknown_local_tree_fails_closed(self):
        with self.assertRaises(Exception):
            privacy.git_tree(self.repo, "f" * 40)

    def test_oversized_git_object_fails_closed(self):
        with patch.object(privacy, "MAX_BLOB", 4):
            with self.assertRaises(Exception):
                privacy.git_tree(self.repo, self.base)

    def test_symlink_does_not_escape_snapshot_audit(self):
        (self.repo / "linked.txt").symlink_to("note.txt")
        self.git("add", "linked.txt")
        with self.assertRaises(Exception):
            privacy.git_tree(self.repo, self.git("write-tree"))

    def test_submodule_is_not_silently_skipped(self):
        self.git("update-index", "--add", "--cacheinfo", "160000," + self.base + ",submodule")
        with self.assertRaises(Exception):
            privacy.git_tree(self.repo, self.git("write-tree"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
