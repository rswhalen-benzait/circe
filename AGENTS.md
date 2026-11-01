# Instructions for every agent working in this repository

This is a public repository. These instructions apply to code, tests, fixtures,
previews, documentation, screenshots, generated assets, commit messages, and any
diagnostic output that might be committed or published. Claude, Codex, other
assistants, and their subagents must follow the same policy.

## Keep personal data outside Git

- Never copy real account emails, personal names, company or customer names,
  cloud project or instance identifiers, machine names, Linux login names, home
  paths, IP addresses, account records, or connection settings into repository
  examples or fixtures. Use clearly fictional data instead.
- Use reserved example domains: `example.com`, `example.org`, `example.net`,
  their subdomains, or names under `.example`, `.invalid`, `.test`, or
  `.localhost`. Use generic names such as `developer`, `demo-workstations`, and
  `vm-1`. Prefer runtime temporary directories and `$HOME` over literal home
  paths. Preserve public protocol constants and documentation IP ranges only
  when they are actually required.
- Never add passwords, private keys, access or refresh tokens, service-account
  credentials, cookies, Keychain exports, SSH state, cloud CLI credential stores,
  application preferences, logs, crash dumps, or real desktop screenshots.
  Keep runtime data in the application's private storage or the appropriate
  system credential store, not in this repository.
- Redact diagnostics before sharing them. Report a finding's rule, line number,
  and sanitized file path; do not repeat the matched secret or personal value.
  Do not run commands that print secrets merely to inspect them.
- Check generated files and binary assets too. Screenshots, image metadata,
  archives, bytecode, and caches can contain personal information even when
  the visible source code is clean.

## Required checks

Install this checkout's local protections before making commits:

```sh
python3 scripts/install-privacy-hooks.py
```

Before committing, inspect the intended changes and run:

```sh
python3 scripts/privacy_check.py --staged
```

For a full repository check, also run:

```sh
python3 scripts/privacy_check.py --tracked
```

The commit check reads the staged Git blobs, not an unstaged substitute. The
push protection checks every outgoing commit, so adding private data in one
commit and removing it in another is still a failure. Leave the protections
enabled for commits and pushes, including automated ones.

The installer keeps private known terms and the checksum-pinned secret scanner
inside Git's local metadata. Personal terms belong in
`circe-privacy/private-terms.json` under the Git common directory, never in a
tracked denylist or test. See [the privacy guide](docs/PRIVACY.md).

Do not bypass hooks with `--no-verify`, disable scanners or CI, remove checks,
broaden exclusions, or suppress a finding just to make a commit or push pass.
Doing so requires an explicit request from the repository owner. If a check
fails, fix the data, keep the protections intact, and report the problem using
redacted diagnostics. A scanner error is not a successful scan.

## Publication and limits

Never claim that these checks prove the absence of every kind of personal
information. Review the actual changes as well as the automated results. If a
secret was published, revoke or rotate it; deleting the current file is not a
remedy by itself. Do not rewrite published history without explicit owner
authorization. Git commit-author metadata is public independently of the files
in a commit.

Local hooks and instructions help prevent accidents; they cannot restrain an
agent that can deliberately edit or bypass them. Keep the privacy CI check
required by the repository's server-side branch policy for stronger protection.

## Delegation

The owner authorizes useful delegation to assistants and subagents. Pass these
instructions to every delegate. Delegation does not authorize unrelated cloud
changes, publication, secret access, or other consequential actions.
