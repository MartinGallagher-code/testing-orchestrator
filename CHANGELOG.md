<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.1] - 2026-11-23

An adversarial pass over the sweeps (`--batch`, `--resume`, `--muster`),
`tx export`, the exit codes and Ctrl-C (shared_tools TX-004). Every fix
has a regression test in `tests/test_adversarial.sh`, and
`tests/test_adversarial_mutations.sh` undoes each one in a copy of `tx.py`
and checks its test fails. It was numbered 1.1.3 on its pull request,
and was rebased onto 1.1.1 (TX-001) and 1.2.0 (TX-002), which merged
first; 1.1.2 is the number TX-003 took while this was open beside it.

### Fixed

- **A host whose agent died mid-job no longer reads as "still going".**
  A reboot or an OOM kill leaves `running` in `run.json` for good. `tx run`
  reported that host as `RUNNING ... still going` and exited 0; it is now
  `GONE ... stopped mid-job and left no result`, and the run exits 1, as
  the exit-status table always said. `tx summarize` likewise.
- **`--resume` runs such a host again** instead of waiting on it: it
  believed the record's "running" without asking whether the agent was
  alive, so the host was never covered, on every resume after. A
  `--muster` wave likewise puts the item back for somebody else rather
  than holding it, with nothing running, until its lease ran out.
- **An earlier run's record no longer answers for this one.** With
  `--no-deploy` the last run's `run.json` stayed on the host, and an
  agent that died on startup read as "ran already" — and its old exit 0
  as this run passing everywhere (`tx run` and `--muster`, which checked
  the items in as done). The start now removes it before launching.
- **The wait, and the default `--lease`, count setup and teardown.** Each
  has the job's timeout of its own, so a host can take three times the
  timeout. Counting only the job, a `--batch` wave was given up on while
  its hosts were still in teardown and the next wave started over them —
  two waves running at once — and from a timeout of about seven minutes the
  default lease could run out under a host still working. Plans without
  setup or teardown wait exactly as long as before.
- **`tx export --from` reads only run records.**
  - JSON that is not an object (an array, a string), a host that is not a
    name, or a record with no state crashed it with a traceback, or was
    read as a host. Each is now skipped with a message.
  - A job's own `run.json` (collected as `tag~host~out~run.json`, or from
    a `collect=` glob) was taken for the record, and one that sorted after
    it replaced it. Only `tag~host~run.json` is the record now.
  - A directory several tagged runs share was read as one run, each host's
    numbers taken from whichever record sorted last. It is read for the
    plan's tag, and refused (exit 2) without a plan to say which.
  - Records for hosts the plan does not name — a `--muster` sweep's items
    — were dropped without a word. The plan is the roll call, not a filter.
  - `--test-prefix` with whitespace or a quote is refused, as `--run` is:
    a space split the field, and a newline wrote lines of its own.
- **A host name ssh would read as an option is refused.** A host or
  address starting with `-` went to ssh and scp as an option, not a
  destination (`-oProxyCommand=...` runs a command on this machine, `-F`
  reads another config); a name with a `/` crashed the collection with a
  traceback. `tx gen` and every command that reads the plan refuse them,
  and a `--user` starting with `-`, before any ssh. A `--muster` pool item
  like that is not run: it is named, put back, and the sweep exits 1.

### Documentation

- The exit-status table lists 130 (interrupted with Ctrl-C), and says the
  agents already started keep running. What Ctrl-C should do is the
  owner's decision, filed separately.

## [1.2.0] - 2026-11-23

The `--remote-dir` is checked on every host before tx writes to it, runs
from it, reads from it, signals what its pid file names or deletes it
(shared_tools ticket TX-002). The same checks as matrix_orchestrator
1.12.0 (MX-006) and iperf_orchestrator 2.7.0 (IO-003). Built on 1.1.1
(TX-001): the check runs in front of 1.1.1's `stop`, `clean`, `status` and
`doctor`, which still act only on this run's own agent and files, and the
staged copy below keeps 1.1.1's `.tx-manifest` record of what the payload
created.

### Changed

- **A `--remote-dir` that another user owns, or can write to, is
  refused.** The default `/var/tmp/tx` sits in a world-writable directory,
  so any user on a host can create it before tx does, and nothing checked
  who owned it: `tx start` ran `mkdir -p` (taking the directory as it found
  it), copied `tx.py` into it and ran it with `python3`. Whoever owned or
  could write to that directory could swap `tx.py` or the payload between
  the copy and the launch and so run their code as the ssh user, plant an
  `agent.pid` for `tx stop` to signal, or leave a symlink where scp writes.
  Now `start` (its copy, its rename into place and its launch, each checked
  again), the stand-down after a failed arming, `status`, `stop`, `clean`,
  `collect`, `logs`, `doctor`, `export`, `run` and every `--batch` or
  `--muster` wave first check, on each host, that the directory is a real
  directory (not a symlink, not a file), owned by the ssh user (`id -u`)
  and not writable by group or others. If it is not, that host fails with
  a `REFUSED:` line naming the directory, its owner and uid, its mode and
  the ssh user's uid, and nothing in it is read, written, run, signalled or
  deleted. **This refuses directories that worked before**: one another
  user owns, one made group- or world-writable by hand (`chmod go-w` it),
  and a symlinked `--remote-dir`, which `start` used to deploy through and
  `clean` to delete through; give the real path instead.
- **`tx status` prints a refused host's `REFUSED:` line where its state
  would be.** It is a report, so it still exits 0, as it does for an
  unreachable host; every other command fails that host and exits 1. No
  exit code changed.
- **A new `--remote-dir` is created private**, `mkdir -p -m 700`. A
  directory that already exists keeps its mode, and so does any parent.
- **The agent and the payload are copied into a private staging directory
  (`.tx-incoming.*`) and renamed into place**, after whatever stood at the
  agent's name is removed, so a symlink planted at `tx.py` is replaced,
  never written through. The payload is unpacked straight out of the
  stage, so `payload.tar.gz` is never written at its fixed name at all.
  `agent.pid` is written to a temporary name and renamed into place too.
- **`tx start` no longer replaces `tx.py` under a job that is still
  running.** The "a job is already running here" check now comes before
  the rename rather than after the copy.
- **`tx doctor` reports each host's `--remote-dir`**: `remote_dir=ok(...)`
  with its mode, `absent(start makes it, mode 700)`, or `REFUSED` with the
  reason, and a refused host is not called ready. It does not read a
  refused directory's `agent.pid`, so its `agent_running` there is `no`.
  `tx check`, which contacts no host, says what will be checked and points
  at `tx doctor`.
- **`tx clean` counts a leftover staging directory (`.tx-incoming.*`) as
  tx's own** and deletes it, rather than refusing the host over a "thing
  tx did not put there". A deploy cut short between the copy and the
  rename leaves one behind.

### Added

- **`--allow-shared-remote-dir`** (or `TX_ALLOW_SHARED_REMOTE_DIR=1`) on
  every fleet command lets `--remote-dir` be group-writable, for a
  directory a group shares on purpose. It lifts that one check: the
  directory must still be the ssh user's, not a symlink, and not writable
  by others. `tx hints` has an entry for it.

## [1.1.1] - 2026-11-20

`tx stop`, `tx clean`, `tx doctor` and `tx status` act on this run's own
agent and this run's own files, and nothing else (TX-001). These are the
fixes `matrix_orchestrator` made in 1.11.2 to 1.11.7 and
`iperf_orchestrator` in 2.8.0, ported, with the owner's decisions for
those two taken as made for `tx`. No flag, exit code, collected-file name
or export format changes.

### Fixed

- **`tx stop` of one run no longer kills another run's agent.** It waited
  on *any* `tx.py agent` on the host, found the second run's (out of
  another `--remote-dir`, running as it should), and after ten seconds
  `pkill -KILL`ed it. `stop`, `clean`, `run --clean`, each wave's clean and
  the stand-down after a failed start all went through that code. Now a pid
  is signalled, waited on and killed only once it is shown to be a live
  `tx.py agent` whose working directory (`/proc/PID/cwd`) is this
  `--remote-dir`; an agent that will not go is KILLed with its own
  children, not with every agent on the host.
- **A stale `agent.pid` is not trusted.** The default `/var/tmp/tx`
  survives a reboot, and the pid in it could have been reused by anything
  of the ssh user's. `tx start` refused to deploy over it ("already
  running"), `tx status` called the host alive, and `tx stop` ran
  `kill -TERM -<pid>` — that process's whole process group. Now such a pid
  is "not running", and is never signalled — nor is a pid of 0 or 1,
  which to `kill -<pid>` mean this process group or every process.
- **A lost `agent.pid` is traced by working directory**, read from `/proc`
  itself (no procps needed), rather than `pkill -TERM`ing every tx agent of
  the ssh user. On a host with no `/proc` (macOS), with `agent.pid` gone and
  a tx agent of yours running, `stop` and `clean` fail on that host and say
  to kill it by hand; nothing is killed by name, and `clean` leaves the
  directory in place.
- **`tx clean` deletes only what tx put there.** It ran `rm -rf` on
  whatever `--remote-dir` named. It now removes tx's own files, what the
  payload unpacked (each top-level name the deploy *created*, recorded in
  `.tx-manifest`), and what the run left beside them (recorded by the agent
  as the run ends) — and then `rmdir`s the directory. Anything else there
  makes it refuse on that host, name what it found, and delete nothing. A
  payload that brings its own `.tx-manifest` is refused by `tx start`.
  *Upgrading:* a directory deployed by 1.1.0 or earlier has no record, so
  the first `tx clean` of one names its contents and leaves it; delete it
  by hand once.
- **`tx clean` reports `LEFTOVER` only for an agent of this run** still
  running out of its directory, and deletes nothing under it. Another
  run's agent, or another user's, made it exit 1 before.
- **`tx doctor`'s `agent_running`** is this `--remote-dir`'s agent, not any
  tx agent on the host. It also reports `proc=`: whether a lost
  `agent.pid` can be traced there.
- **`tx run --clean` exits 1 when its clean failed** on any host — plain,
  `--batch` and `--muster` alike. It dropped clean's answer. In a sweep the
  next wave still runs; with `--stop-on-fail` a wave that could not be
  cleaned is the last.

### Tests

- Two runs on the same fake hosts: stopping, cleaning, or stopping with a
  lost pid file one of them leaves the other running to the end; `clean`
  and `doctor` beside another run; a stale pid file naming a process group
  of somebody else's; a host with no `/proc`; a stranger's file, a
  directory the payload did not create, and everything a run made;
  `run --clean` (plain, `--batch`, `--muster`) whose clean fails.
- `tests/test_mutations.sh`: each fix reverted in a copy of `tx.py`, and the
  test written for it shown to fail by name. `TX_TEST_ONLY` runs chosen
  tests of a file, which is how it runs one test against a copy.

## [1.1.0] - 2026-11-13

Everything since 1.0.0, numbered and dated: what had collected under an
"Unreleased" heading, and the rule that ends that heading (ST-030). From
here on every change moves the version.

### Changed

- **Every change moves the version.** A pull request into `main` raises the
  version in all three places it is written (`pyproject.toml`,
  `testing_orchestrator/__init__.py`, `testing_orchestrator/tx.py`) and opens
  this file with that version's own dated section, never an "Unreleased"
  heading left for later: the owner's rule for every repository in the suite
  (shared_tools BN-002). `PUBLISHING.md` says so too. Bumping is now part of
  every pull request, and publishing stays a separate, manual step.

- **Shorter help.** `--help` no longer prints the whole README: it gives the
  quick-start commands and the list of commands. Each option's help now fits on
  one line. `tx help` lists the shared fleet options once, then each command's
  own options, one line each.
- **The help and `--version` use the package name, `testing-orchestrator`.**
  `tx` is still installed as its short name, and the usage lines show `tx`
  when you run it as `tx`.

- **Licensing and attribution are now identical across every repository in
  the suite.** The notice said the same thing eleven slightly different ways —
  different badge text, different `--version` wording, five styles of file
  header, and in places a different holder or even a different licence. All of
  it is now one form:
  - **Holder:** `Martin J. Gallagher` everywhere (several places said
    "Martin Gallagher", dropping the middle initial).
  - **Licence:** `GPL-3.0-or-later` everywhere, with `LICENSE` and
    `LICENSES/GPL-3.0-or-later.txt` the same verbatim FSF text in every repo.
  - **File headers:** the two-line SPDX pair
    (`SPDX-License-Identifier` then `SPDX-FileCopyrightText`), replacing the
    `Copyright (C) …` variants and the long inline GPL notices.
  - **`--version`:** the same five-line GNU-style block under every tool's own
    name and version.
  - **README:** the same licence badge and the same `## License` section.
  - **REUSE:** a `REUSE.toml` of the same shape in every repo; `reuse lint`
    passes in all of them.

### Added

- **`tests/check_version.sh`, and a `version` job in CI.** The check fails
  when the three places disagree, or when this file does not open with that
  version, numbered and dated, or still holds an "Unreleased" heading. Given
  a commit it also fails unless the version is greater than that commit's.
  CI's `version` job runs it on every pull request against the base branch,
  and on every push to `main` against what `main` was before the push. The
  script is shared_tools' `templates/check_version.sh`: only its list of
  places is this repository's.

- **`CLAUDE.md`**, notes for a Claude session working here. Its work goes
  through a ticket on the shared board in `MartinGallagher-code/shared_tools`.
  It is not shipped: `MANIFEST.in` leaves it out of the sdist.

- **Ready to publish on PyPI, with docs on Read the Docs.** A trusted-
  publishing workflow (`.github/workflows/publish.yml`, OIDC, no stored
  token) builds an sdist and wheel on a GitHub Release, checks the metadata
  with `twine`, and smoke-tests both console scripts (`tx`,
  `testing-orchestrator`) before uploading; it refuses a release tag that does
  not match the version in the tree. `.readthedocs.yaml` builds the docs
  (the CLI reference generated from the live parsers), and `PUBLISHING.md`
  is the release runbook. `tests/test_version.sh` holds the one version in
  its three places -- `pyproject.toml`, `__init__.py`, and `tx.py` (the
  agent's own, stamped into every run record) -- in agreement.

- **`tx export` turns a run into an overlay for the datacenter layout
  viewer.** The same tab-separated `!test`/sample results file `mx` and
  iperf write, so a benchmark's timings colour the floor plan beside the
  fabric's numbers. One sample per host from each host's run record:
  `tx_duration`, `tx_rel_median` (runtime against the fleet's own median,
  a slow rack reddening whatever the absolute seconds are),
  `tx_start_offset` (how far off the armed instant each host actually
  started -- the one overlay only tx can draw), `tx_exit`,
  `tx_setup_exit`/`tx_teardown_exit`, `tx_timed_out`, and a categorical
  `tx_state`. A blank field is "not measured" and never a flattering
  zero, and a host in the plan that never reported is named `NO-DATA`
  rather than dropped. Reads the fleet like `tx status` by default, or a
  `tx collect` directory with `--from` (no ssh, and it works after
  `tx clean`); `--json` writes NDJSON, and `--names`/`--target-prefix`/
  `--test-prefix`/`--run` reshape the lines for the layout and for
  sharing a results file with another tool.

- **`tx run --muster` draws the work from a binnacle muster pool instead
  of the plan's host list.** `--batch` walks a fleet the plan names;
  `--muster` walks a pool `muster` is keeping, which hands items out
  under a lease, once each, and knows what is still outstanding across
  every machine drawing from it. tx takes `--batch` items, runs them as
  one armed-together wave, and checks them back in -- done if the host
  has a run record (a job that ran and failed is a measurement, not an
  item to hand to the next worker), released if nothing reached it --
  and asks for more until the pool has nothing left.

  The division of labour is the point: muster owns what is outstanding,
  tx owns what happens to the items it holds, and neither keeps a copy
  of the other's record. So several `tx run --muster` can share one pool
  and never take the same item twice, and a sweep that is killed leaves
  leases that simply expire -- there is nothing local to lose and no
  `--resume` to run. The plan stays the address book: an item it names
  is reached at the address it gives, an item it does not name is its
  own address, so a pool of bare hostnames needs no plan hosts at all.
  `--lease` sets how long a wave holds its items (default: twice the
  wave's own time bound); `--muster-cmd` names how to invoke muster when
  it is not `muster` on the `PATH`.

- **`--max-bytes`, a ceiling on what a host hands back.** 100 MB per
  file by default, `0` for none. A benchmark's results are usually small
  and what this stops is the exception -- a core dump, a heap profile, a
  log that ran away -- so until now a single runaway file could fill the
  orchestrator's disk. It is applied on the host, so an oversized file
  never crosses the network, and it is always named with its size rather
  than silently dropped: a result you were told about is a decision, one
  you were not is a surprise a week later.

- **`tx run --batch --resume` picks a sweep up from the fleet's own
  record.** A ten-wave sweep can take hours and `tx run` has to stay
  alive to sequence it; if it does not, nothing local is lost, because
  nothing was kept locally. Resume asks the fleet where it got to and
  reads three answers, not two: a host with a result is done, a host
  still working is one the interrupted sweep left running -- agents are
  detached, so the work outlived the orchestrator, and restarting it
  would trample a run that is nearly finished -- and only what is
  neither gets covered in fresh waves.

  Hosts already done are collected again rather than assumed collected.
  A host that finished the job and was killed before its results were
  fetched has them on the host and nothing here, and skipping it because
  it "has a result" is how a resumed sweep quietly loses the very hosts
  it is meant to be recovering.

- **`--poll S`, and a status poll that backs off on its own.** Every
  check is an ssh per host, and those land on the machines whose
  benchmark is being measured. The fixed two-second poll was sixty
  thousand connections over a ten-minute run on two hundred hosts, to
  learn nothing most of the time, while perturbing the thing under test.
  The interval now grows with the wait -- two seconds at first, thirty
  once it has been going five minutes -- so a quick job is still noticed
  quickly and a long one is asked about twice a minute. `--poll` pins it.

- **The job can be fed a file on stdin.** `stdin = NAME` in the plan
  (`tx gen --stdin NAME`) hands the job a file from the working
  directory, which ships in the payload like everything else it needs.
  Without one the job still reads `/dev/null`, so a command that waits
  on input fails at once rather than hanging until the timeout and
  reporting nothing. `tx check` catches a `stdin` the payload does not
  carry before any ssh -- forgetting to ship it fails identically on
  every host, so it is worth finding without contacting one.

- **The report says why a host failed, not only which.** The last few
  lines of a job's stderr now ride back inside the run record, so
  `tx summarize` prints them under the failing host instead of leaving
  you to collect the run and go looking. The whole stderr still comes
  back untouched; the record carries a bounded tail, read from the end
  of the file so a job that wrote a gigabyte of warnings is not loaded
  into memory to find out it failed on the last line.

- **`agent.log` is collected with the results.** It is where anything
  the agent could not turn into a record ends up, which makes a run that
  went wrong exactly when it is needed -- and `tx logs` being a separate
  command was no help to somebody reading a collection later.

- **`tx run --batch N` covers a fleet bigger than what can run at once.**
  Some jobs cannot go fleet-wide in one go -- a licence with a seat
  count, a filer with only so much throughput, a power envelope, a test
  fixture that takes twenty machines. The answer is not to give up the
  simultaneity but to narrow what it applies to: each wave of N hosts is
  armed for its own instant and is as simultaneous as any whole-fleet
  run, and the waves march through the fleet in plan order until it is
  used up.

  Everything lands in **one** directory, chosen before the first wave,
  because the point of covering the fleet is to end with one set of
  results for all of it -- the names already carry the host, so a
  hundred hosts' results sit together and still read apart.

  A wave is an ordinary run over a smaller plan, so start, collect and
  clean are the same code a whole-fleet run uses rather than a second
  path that only waves take.

  The report says what fraction of the fleet was reached, and is
  rendered from what each wave recorded while its hosts still held the
  record -- by the end the early waves have been collected and possibly
  cleaned, and polling then would read them as hosts that never
  answered. Hosts a stopped sweep never got to are reported as
  `NOT REACHED`, not counted as passes.

  By default a wave that fails does not stop the sweep: one unreachable
  rack should not cost the other nine their coverage. `--stop-on-fail`
  stops instead.

### Fixed

- **CI's Python 3.9 job installs Python 3.9 again.** `ubuntu-latest` became
  Ubuntu 26.04, for which `setup-python` has no 3.9 build, so the job failed
  before running a test. 3.9 now runs on `ubuntu-24.04`; the other versions
  stay on `ubuntu-latest`.

- **`tx clean` claimed a clean fleet it had not checked.** It removes
  the working directory and then asks `pgrep` whether any agent outlived
  it -- but on a host without procps a missing `pgrep` returns 127,
  which the old test read as "no agents found". So the run ended
  "nothing of tx remains on the fleet" having verified nothing. Three
  answers now come out of that one exit status (0 found, 1 none, 127
  nothing to ask), and a host that could not be checked is named rather
  than counted as clean. `tx doctor` reports `pgrep=` per host, so the
  gap is visible before the run rather than after it.

- **A host reported itself finished before its teardown had run**, so
  `tx run` collected while the teardown was still writing into `$TX_OUT`
  and left its output on the host. Leaving a machine as it was found is
  part of the run, so a host is not finished until it has been put back:
  the record now says `tidying` while the teardown runs, and only then
  `done`. `tx status` shows it, and `tx summarize` counts such a host as
  still going rather than as one that has finished.

  Found by the Python 3.6 CI job, which runs in a container slow enough
  to lose the race every time; on faster interpreters the teardown
  usually won.

- **A job that could not start left its host reading `RUNNING` for
  ever.** The record is written before the job is launched, so a launch
  that threw -- no `bash`, a working directory that went away -- escaped
  with the record still saying `running`: a machine doing nothing,
  reported as one still working. The only explanation went to the
  agent's log, which `tx collect` did not bring back, so the run's
  stderr was genuinely lost. It is now its own outcome, `NEVER RAN`,
  with the reason in the record, in the collected stderr, and in
  `tx status` and `tx summarize`.

- **The start spread no longer claims waves were simultaneous with each
  other.** Each host's offset is measured against its *own* wave's
  instant, so in `--batch` mode the figure is how tightly each wave
  began -- reporting it as "spread across N hosts" read as a claim about
  the whole fleet that `--batch` deliberately does not make. It now says
  "within each wave", and names the trade.

- **`SLOW` no longer fires on scheduler noise.** The finding was a bare
  ratio against the median, so a 9ms job against a 6ms median was
  reported as an outlier. Below a one-second median the ratio is not
  measuring the job, and the finding is withheld.

## [1.0.0] - 2026-09-11

First release. `tx` runs one benchmark or test on a whole fleet at once
and brings the results back.

### Added

- **The six commands.** `tx gen` builds `plan.ini` from a server list;
  `tx start` deploys the job and arms every host; `tx status` says what
  each is doing; `tx collect` brings the results back; `tx summarize`
  says who passed and who was slow; `tx clean` removes every trace.
  `tx run` does all of it in one shot, and `tx check`, `tx doctor`,
  `tx stop`, `tx logs` and `tx hints` fill in around them.

- **A start that is simultaneous, and says how simultaneous.** Starting
  forty ssh sessions takes seconds, so `tx start` arms every host with a
  wall-clock instant a few seconds out rather than starting anything.
  Each agent sleeps until then. Because that depends on the fleet's
  clocks agreeing, the deploy measures each host's offset (round-trip
  corrected) and refuses a fleet outside `--max-skew`; every agent
  records the instant it actually began, and `tx summarize` reports the
  spread. Arming that overruns its window is reported rather than
  quietly producing a staggered run, and a fleet that cannot all be
  armed is stood back down rather than left half-started.

- **The job, and everything it needs.** `--payload` is a file or
  directory, packed once and unpacked into the working directory on
  every host. `--setup` runs first -- a host whose setup fails does not
  run the job, because reporting a benchmark failure that was really a
  build failure is a wrong answer rather than a missing one --
  and `--teardown` runs afterwards whether the job passed or not. The
  job is given `TX_OUT`, `TX_HOST`, `TX_INDEX`, `TX_NHOSTS`, `TX_TAG`,
  `TX_RUN_ID`, and `TX_HOSTS` with `--peers`.

- **Results that stay apart.** One directory per collection, flat, with
  the tag leading every name: `bench~web01~out~results.json`. Several
  runs can share a directory and still be told apart. Nothing a remote
  host says is used as a local path, and two files that would fold onto
  one name are reported rather than written over each other. Everything
  under `TX_OUT` comes back, plus each host's stdout, stderr, setup and
  teardown logs and the run's own JSON record; `collect =` globs add
  anything else.

- **Bounds that hold.** Every plan carries a timeout, because a job with
  no bound is a fleet nobody can get back. The agent gives each phase a
  session of its own and kills the whole process group, so a benchmark
  that spawned helpers does not outlive its own timeout -- and `tx stop`
  is forwarded down to the job for the same reason.

- **77 tests** across five bash suites, run against a fake fleet so the
  whole workflow -- deploy, arm, run, collect, stop, clean -- is covered
  without a network or a second machine. CI runs them on Python 3.9
  through 3.13 and under a real Python 3.6, with vermin, shellcheck,
  REUSE and a wheel build.
