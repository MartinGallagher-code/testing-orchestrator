<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

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
