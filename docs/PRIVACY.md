# Preventing private data from entering the public repository

Circe's saved computers, sign-in state, passwords, and other runtime settings
belong on the device using the application. Development examples must not be
copies of those settings. The repository's checks operate on repository data;
they do not remove or reset the application's local connections or credentials.

The policy applies to people and agents alike. [AGENTS.md](../AGENTS.md) is the
shared instruction file; [CLAUDE.md](../CLAUDE.md) directs Claude to that same
policy rather than maintaining a second version.

## Install the local protections

From the repository root, run:

```sh
python3 scripts/install-privacy-hooks.py
```

The installer sets up this checkout's commit and push checks and downloads a
checksum-pinned Gitleaks executable into Git's local metadata. The downloaded
tool is not an application dependency and is not committed to the repository.
Install the protections in each new clone; Git hooks are not activated merely
by cloning a repository.

Before committing, run:

```sh
python3 scripts/privacy_check.py --staged
```

This checks what Git will actually commit, including staged versions that differ
from the files currently open in an editor. For a full tracked-file check, run:

```sh
python3 scripts/privacy_check.py --tracked
```

Push checks examine every outgoing commit, not just the final version of the
branch. Private data added and then deleted in separate commits would still be
published in history, so that sequence must fail the check.

## Private terms specific to a developer

Automated patterns cannot recognize every personal name, employer, cloud project,
or device name. The local setup seeds a private list from the developer's local
identity and, on macOS, saved Circe cloud/SSH target identifiers. It reads only
those saved identifiers, not Keychain passwords or cloud credential databases,
and does not change application settings. Review and extend that list with
identifiers that must not be published.

Keep those values in `circe-privacy/private-terms.json` inside the Git common
directory. Locate that directory with:

```sh
git rev-parse --git-common-dir
```

For a normal clone, the private file is inside `.git`; linked worktrees share
the common Git directory. The file is local configuration and must not be copied
into source files, tests, reports, issue comments, or tracked policy files.
Treat the terms themselves as private. Do not print them in check output.

## Safe examples and assets

Use clearly fictional values such as `developer@example.org`, `vm-1`, and
`demo-workstations`. Reserved domains include `example.com`, `example.org`,
`example.net`, their subdomains, and names under `.example`, `.invalid`, `.test`,
or `.localhost`. Do not substitute a made-up address at an unrelated real domain.

Read home directories and connection details at runtime. For tests, prefer a
temporary directory over a path copied from a developer's machine. Real provider
protocol constants can remain when necessary; real user accounts and private
infrastructure identifiers cannot become fixtures simply because a test uses
them.

Review more than text source. Screenshots can show account badges and open
documents, image metadata can identify a person, and caches or archives can
contain paths and credentials. Keep generated caches out of version control.
Review new or changed binary assets before approving them for publication.

When a check reports a finding, remove or replace the private data and rerun it.
Use only the rule, line number, and sanitized path when discussing the finding.
Do not paste the matched value into chat transcripts, commit messages, logs, or
public reports. A tool failure, skipped file, or unavailable scanner is not a
clean result. Do not bypass hooks, disable CI, or weaken exclusions to get a
passing result without an explicit owner request.

## Server-side protection

The privacy workflow provides a check independent of an agent's local hooks.
Configure the repository's GitHub branch rules to require that check before a
change can land on protected branches. Keep the rules scoped to the branches
that are published, and restrict who can bypass them.

Instructions and local hooks prevent many accidental leaks, but any agent with
write access can attempt to change them. CI also needs protection from being
disabled or replaced in the same change. Server-side branch rules and review of
changes to privacy controls provide stronger enforcement than local hooks alone.

## Existing history and exposed secrets

These checks do not erase previously published content. Removing data from the
latest version leaves older commits intact; other clones or caches may retain
copies even after a history rewrite. Review older history separately when there
is reason to suspect an earlier exposure.

If a password, private key, or token was published, revoke or rotate it first.
Deleting a file or rewriting history does not make the exposed credential safe.
Any history rewrite needs explicit owner authorization and coordination with
other contributors.

Git commit-author names and email addresses are public metadata independent of
source files. Configure a suitable public identity, such as a provider's private
commit email option, before making commits if that metadata must be limited.
These repository checks do not silently change a developer's Git identity.

No automated scan can guarantee that arbitrary personal information is absent.
Review the intended files and history as well as the check results, and keep
real runtime data outside the repository in the first place.
