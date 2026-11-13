<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Notes for Claude

## What this is

`tx` runs one benchmark or test on a whole fleet at once: it ships the job,
starts it at the same instant on every host, waits, brings back what each
host produced under names that say where it came from, and removes itself.
The whole tool is one file, `testing_orchestrator/tx.py`. The same file is
the orchestrator on the machine you drive from and the agent that is
`scp`'d to every host and run there. README.md is the manual; PUBLISHING.md
covers the version, releases and Read the Docs.

## Rules that hold everywhere

- **Standard library only, Python 3.6 floor**, on the orchestrator and on
  every host (`pyproject.toml`'s `dependencies = []` says why). The agent runs
  on whatever `python3` a long-lived fleet has, so the floor is real:
  `tests/check_python_compat.sh` byte-compiles, and CI adds vermin and a run
  of the whole suite under a real Python 3.6.
- **The public interface is more than the flags.** The exit codes, the
  `tag~host~path` collected-file names and the `tx export` results format
  are what people build scripts, `rm` globs and the datacenter viewer's
  overlays on. A change to any of them is a major version (PUBLISHING.md,
  *Version numbers*).
- `--help` stays a reference card; README.md is the manual.

## Every change moves the version

However small the change (code, tests, docs or CI), a pull request into
`main` raises the version in all three places it is written, and they must
agree:

- `pyproject.toml` → `version` (the one compared with the base branch)
- `testing_orchestrator/__init__.py` → `VERSION`
- `testing_orchestrator/tx.py` → `VERSION`, the one that travels: the agent
  stamps it into every run record as `agent_version`

In the same pull request `CHANGELOG.md` opens with that version's own
section, `## [X.Y.Z] - YYYY-MM-DD` (Keep a Changelog's form, as the file
already uses), never an "Unreleased" heading left for later. Patch for fixes,
docs, tests and CI; minor for anything new a user can use; major only when
something that worked stops working the way it did. PUBLISHING.md's
*Version numbers* says which is which for `tx`.

`tests/check_version.sh` (shared_tools' template; only its `places()` is this
repository's) fails when the three disagree or the changelog does not open
with the version. CI's **version** job also fails a pull request whose
version is not greater than its base branch's, and a push to `main` whose
version is not greater than what `main` had before it. If `main` moves while
a pull request is open, rebase and bump again. Publishing is a separate
step, and a person's call (PUBLISHING.md, *Cutting a release*). A number
that is never published is fine; a change with no number is not.

## Tests

```bash
bash tests/check_version.sh origin/main  # bumped everywhere, and past main's
./tests/run_tests.sh                     # the whole suite, against a fake fleet
./tests/check_python_compat.sh           # byte-compiles under this python3
```

The suite runs the real agent against a fake fleet (ssh and scp shims that
run each "remote" command in a sandbox per host), so it needs no network and
no second machine. CI (`.github/workflows/ci.yml`) also runs these; run the
ones you can before pushing:

```bash
vermin --eval-annotations --violations --target=3.6- testing_orchestrator/*.py
shellcheck -e SC1091 tests/*.sh tests/test_helper.bash
reuse lint
sphinx-build -W --keep-going -b html docs docs/_build/html
python -m build && python -m twine check dist/*
```

CI runs the suite on Python 3.9 to 3.13 and under a real 3.6 in a container,
and the version job above. Add or update tests for any behaviour you change;
a new test file is `tests/test_*.sh`, which `run_tests.sh` finds by itself.

## Every task is a ticket

Everything done here goes through a ticket in `MartinGallagher-code/shared_tools`,
which keeps every project's tickets as files and moves each one Backlog → In Progress
→ Review → Done (Adversarial Test only when the owner asks). Before any change:

1. Attach `MartinGallagher-code/shared_tools` with `add_repo` and push access, and
   clone it. If a clone is already here, pull it instead
   (`git -C <shared_tools clone> pull --ff-only`): a stale clone has a stale
   `CLAUDE.md` and a stale `ticket.py`.
2. Read the "Every task is a ticket" section of its `CLAUDE.md`. It sets out what each
   column requires, and none of it is optional.
3. Open the ticket with the shared_tools clone's script, not a path in this
   repository:

   ~~~bash
   <shared_tools clone>/scripts/ticket.py new testing-orchestrator "Imperative title" --request "the request, in the user's own words"
   ~~~

**Every change moves the version**, however small: a pull request into `main` raises
it in every place it is written and opens `CHANGELOG.md` with that version's own
dated section, never an "Unreleased" heading left for later. CI fails a pull request
whose version is not greater than its base branch's. This file's own section on the
version says where it is written.

The board: https://claude.ai/artifact/HrB3RpVpqGGQS7UZgZsMJm

## Bundling this repo

When packing this repository into a text bundle for handover, use the
canonical scripts in
[`shared_tools`](https://github.com/MartinGallagher-code/shared_tools)
(`scripts/handover.sh`, or `merge.sh`, `split.sh`, `b64bundle.sh`) and read
that repo's `CLAUDE.md` first. Its `repos/` notes say this repository has
gone over as a single plain packet before.

**Never include git internals in the bundle.** Export with
`git archive main | tar -x -C /tmp/tree`, never a working tree or a plain
`cp -r` of a live checkout; `.git/config` can carry credentials.
