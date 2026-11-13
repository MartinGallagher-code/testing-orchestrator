<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Publishing

`testing-orchestrator` publishes to PyPI through **trusted publishing** (OIDC),
so no API token is stored as a repository secret. The workflow in
`.github/workflows/publish.yml` runs on a published GitHub Release, or
manually via `workflow_dispatch`.

## One-time PyPI setup

Do this **before** the first release, or the first publish run fails OIDC
with `invalid-publisher`.

1. Sign in at [pypi.org](https://pypi.org) and go to
   *Your projects → Publishing* (or *Account settings → Publishing* for a
   project that does not exist yet).
2. Add a **GitHub** trusted publisher:

   | Field | Value |
   |---|---|
   | Owner | `MartinGallagher-code` |
   | Repository | `testing-orchestrator` |
   | Workflow name | `publish.yml` |
   | Environment | `pypi` |

3. In the GitHub repository, create an environment named `pypi`
   (*Settings → Environments*). Adding required reviewers there gives you a
   manual approval gate before anything is pushed to PyPI.

The workflow name and environment must match exactly. A mismatch is the
usual cause of `invalid-publisher`.

## Every change moves the version

Every pull request into `main` raises the version, however small the change:
code, tests, docs or CI. That is the owner's rule for every repository in the
suite (shared_tools BN-002). Nothing waits for a release to be numbered, so in
the same pull request:

1. Raise the version in **all three** places. They must agree:
   `tests/check_version.sh` and the test suite (`tests/test_version.sh`) fail
   if they do not, and so does the publish workflow if the tag disagrees:
   - `pyproject.toml` → `version`
   - `testing_orchestrator/__init__.py` → `VERSION`
   - `testing_orchestrator/tx.py` → `VERSION`

   `tx.py`'s is not redundant with the packaging version. `tx.py` is the
   whole tool in one file, and it is `scp`'d to every host and run there as
   the agent — where its own `VERSION` is the only version there is. It
   stamps that number into each run record as `agent_version`, so a `tx.py`
   left behind at the old number reports a fleet that disagrees with itself
   about what it ran, not a release that was cut carelessly.

   ```bash
   sed -i 's/^VERSION = "1\.1\.0"$/VERSION = "1.2.0"/' \
       testing_orchestrator/__init__.py testing_orchestrator/tx.py
   sed -i 's/^version = "1\.1\.0"$/version = "1.2.0"/' pyproject.toml
   ```

2. Open `CHANGELOG.md` with that version's own section,
   `## [x.y.z] - YYYY-MM-DD`, saying what changed. Never an "Unreleased"
   heading left for later.

`bash tests/check_version.sh origin/main` checks both before you push. CI's
`version` job runs the same check, and fails a pull request whose version is
not greater than its base branch's, or whose changelog does not open with it.
If `main` moves while a pull request is open, rebase and bump again. Which
part to raise is under *Version numbers* below.

## Cutting a release

Publishing is a separate step, and a person's call. A version that is never
published is fine; a change with no version is not. `main` already carries
the version and its changelog section, so a release is only:

1. Let CI go green on `main`.
2. Tag and push the version `main` has:

   ```bash
   v=$(sed -n 's/^version = "\(.*\)"$/\1/p' pyproject.toml)
   git tag -a "v$v" -m "testing-orchestrator $v"
   git push origin "v$v"
   ```

3. Publish a GitHub Release for that tag. That triggers `publish.yml`, which
   builds an sdist and a wheel, checks the metadata with `twine`, installs
   the wheel and smoke-tests both console scripts (`tx`, `testing-orchestrator`)
   before uploading.

## Checking before you tag

```bash
python -m pip install --upgrade build twine
python -m build
python -m twine check dist/*

# The published artifact must be a working tool, not just valid metadata.
python -m pip install dist/*.whl
tx --version                 # and testing-orchestrator --version agrees
tx hints
```

`twine check` catches a README that PyPI will not render, which is the most
common cosmetic failure.

## Running the publish twice

Harmless. The upload passes `skip-existing: true`, so a file PyPI already
holds is skipped rather than failing the run.

That matters because **PyPI never lets a filename be reused**. Re-running
the publish against a version that is already up could otherwise only ever
fail, and it is an easy run to start by accident: the version comes from the
tree, not from the dispatch form, so nothing about starting the run tells you
which version it is about to upload.

What it does not do is hide a mistake. Bumping the version is what makes an
upload new; an unbumped one has nothing to publish, and is now skipped
quietly instead of ending the run red. If you expected new files and see
every one skipped, the version was not bumped.

## Version numbers

[Semantic versioning](https://semver.org). For this project specifically:

- **patch** — a bug fix, or a change to the docs, the tests or CI
- **minor** — a new command, a new flag, or a new export overlay
- **major** — a removed or renamed flag, a changed exit code, a changed
  collected-file naming scheme, or a changed `tx export` overlay format

The exit codes, the `tag~host~path` collected-file names, and the `tx export`
results format are the public interface as much as the flags are: people
build scripts, `rm` globs and the datacenter viewer's overlays on them, so a
change there is breaking even when no flag moved.

## Read the Docs

`.readthedocs.yaml` configures the build; importing the repository once on
readthedocs.org is all the setup needed. `ci.yml` builds the same docs with
`-W` (warnings as errors) on every pull request, so a docs break fails the
PR rather than surfacing later on RTD.

The CLI reference is generated from the live argparse parsers during that
build, so a new flag that would render badly also fails CI.
