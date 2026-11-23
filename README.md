<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: 2026 Martin J. Gallagher
-->

# testing-orchestrator (`tx`)

[![CI](https://github.com/MartinGallagher-code/testing-orchestrator/actions/workflows/ci.yml/badge.svg)](https://github.com/MartinGallagher-code/testing-orchestrator/actions/workflows/ci.yml)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](https://www.gnu.org/licenses/gpl-3.0.html)
[![REUSE status](https://api.reuse.software/badge/github.com/MartinGallagher-code/testing-orchestrator)](https://api.reuse.software/info/github.com/MartinGallagher-code/testing-orchestrator)

Run **one benchmark on a whole fleet at once**, started at the same
instant on every machine, and get every result back in one directory
with names that say which machine each came from.

Six commands drive it, one file configures it, and `tx clean` removes
every trace when you are done.

```bash
printf '%s\n' web01 web02 web03 > servers.txt

tx gen --servers servers.txt --payload ./bench --run ./bench.sh  # 1. plan.ini
tx start                    # 2. deploy, then start everywhere together
tx status                   # 3. running? finished? how?
tx collect                  # 4. the results, named by host
tx summarize                # 5. who passed, who was slow
tx clean                    # 6. leave no trace
```

Or all of it in one command:

```bash
tx run
```

Not sure what to ask for? `tx hints` turns a goal into the command that
gets you there.

---

## Why this exists

You have a benchmark, a stress test, a conformance suite or a one-off
reproduction script, and you need it run on forty machines rather than
one. By hand that is forty `scp` commands, forty `ssh` sessions you have
to start close enough together to mean anything, and forty sets of
results that all land on top of each other because every one of them is
called `results.json`.

[`matrix_orchestrator`](https://github.com/MartinGallagher-code/matrix_orchestrator)
and
[`iperf_orchestrator`](https://github.com/MartinGallagher-code/iperf_orchestrator)
answer questions about the *network*: they generate traffic and measure
the fabric. This one does not care what the job is. It ships it, starts
it everywhere at one instant, waits, brings back what it produced, and
removes itself.

---

## Install

```bash
pip install testing-orchestrator
```

That puts `testing-orchestrator` on your `PATH`, and `tx` as its short name. No
dependencies — the package is standard-library only.

Or skip installing entirely: `tx` is one self-contained file.

```bash
git clone https://github.com/MartinGallagher-code/testing-orchestrator
cd testing-orchestrator
./testing_orchestrator/tx.py hints
```

**Requirements.** Python 3.6+ and `ssh`/`scp` on the machine you drive
from; Python 3.6+, `bash` and `tar` on every server. Nothing else — no
agents to install, no packages, no root. Key-based SSH must already work
(`ssh-copy-id host`). Check the whole fleet at once with `tx doctor`.

---

## The six commands

| Command | What it does |
|---|---|
| `tx gen` | Build `plan.ini` from your server list. |
| `tx start` | Copy the job to every host and arm them all for one instant. |
| `tx status` | One line per host: `ARMED`, `RUNNING`, `TIDYING`, `DONE exit 0`, `TIMEOUT`. |
| `tx collect` | Bring the results back into one directory, named by host. |
| `tx summarize` | Who passed, who failed, who was slow — and how tight the start was. |
| `tx clean` | Stop, then delete what tx put there — and nothing else: anything it did not put there stops it, by name. It says "no trace" only if it could check. |

And more when you want them: `tx run` (all of the above in one shot, and
`--batch N` to cover the fleet a few hosts at a time), `tx export` (the
run as a floor-plan overlay — see [Draw it on the floor
plan](#draw-it-on-the-floor-plan-tx-export)), `tx check` (will this plan
work? no ssh needed), `tx doctor` (is the fleet ready, and is each host's
working directory safe to use?), `tx stop` (end this run's job, keep what
it made), `tx logs` (collect the agents' own logs), and `tx hints` (goal →
command).

`stop` and `clean` touch only **this run**: the agent working out of this
`--remote-dir`, and the files tx put there. A second run on the same hosts
out of another directory, or another user's, is left alone — see [What
`tx clean` will and won't promise](#what-tx-clean-will-and-wont-promise).

---

## At the same instant, and able to prove it

Starting forty `ssh` sessions takes seconds. A benchmark that starts on
host 1 five seconds before host 40 is not a fleet measurement — it is
forty measurements of different moments. Contention, thermal behaviour
and shared storage all depend on the machines being busy *together*.

So `tx start` does not start anything. It **arms** every host with a
wall-clock instant a few seconds out, and each agent sleeps until then:

```text
[tx] clocks agree to within 12ms (spread 18ms)
[tx] arming 40 hosts for a start 5.6s from now (14:22:09)
[tx] running: 40 hosts, ./bench.sh, timeout 10m00s
```

That makes the claim depend on the hosts' clocks agreeing, so the deploy
measures each host's offset against this machine and refuses a fleet that
disagrees by more than `--max-skew`:

```text
[tx] clocks disagree by up to 45.0s (spread 45.0s across the fleet), over the --max-skew of 1.0s:
    db07             +45.001s
[tx] a synchronised start means nothing on a fleet whose clocks do not agree.
     Fix ntp/chrony (binnacle's `skew` diagnoses it), or pass --max-skew to accept it.
```

And every agent records the instant it *actually* began, so the spread is
a measured number in the report rather than a hope:

```text
  START     spread 31ms across 40 hosts (worst +0.019s off the armed instant)
```

If arming overruns its window the run says so, rather than quietly
producing a staggered start:

```text
[tx] WARNING: arming took 1.4s longer than the 5.0s window, so the last hosts
     started late. Raise --start-in.
```

A host that cannot be armed does not leave the others running: the whole
fleet is stood back down, because a run that began on 39 hosts of 40 is
not the run you asked for.

---

## Coverage: the whole fleet, a few hosts at a time

Some jobs cannot run fleet-wide at once — a licence with a seat count, a
filer that only has so much throughput, a power envelope, a test fixture
that handles twenty machines. The answer is not to give up the
simultaneity but to narrow what it applies to:

```bash
tx run --batch 20 -d results        # 200 hosts, 10 waves of 20
```

Each wave is armed for its own instant and is as simultaneous as any
whole-fleet run. The waves then march through the fleet in plan order
until it is used up — and **everything lands in one directory**, because
the point of covering the fleet is to end with one set of results for
all of it:

```text
[tx] coverage: 200 hosts in 10 waves of at most 20 -> results/ (sweep 20260911-201500-3f9a1c)

[tx] === wave 1 of 10: web01 web02 web03 web04 web05 web06 web07 web08 ... ===
...
tx -- ./bench.sh   [bench]
      200 of 200 hosts finished: 198 passed, 2 failed, 0 timed out
      covered 200 of 200 hosts in 10 waves of at most 20

  START     spread 47ms within each wave (worst +0.031s off the armed instant)
            waves are simultaneous in themselves, not with each other -- that is what --batch trades away
```

That last line is the trade, stated rather than hidden: hosts within a
wave started together, hosts in different waves did not. The report says
so, because the spread is measured against each host's *own* wave's
instant.

`--batch` is not `--jobs`. `--jobs` is how many ssh connections are open
at once — a property of the machine you drive from. `--batch` is how many
hosts are *running the job* at once, which is the thing a seat count or a
filer actually constrains.

By default a wave that fails does not stop the sweep: one unreachable
rack should not cost the other nine their coverage. `--stop-on-fail`
stops instead, and the hosts nobody got to are reported as `NOT REACHED`
rather than quietly counted as passes.

**Every sweep has an id**, made when it begins: the time, and a few
random characters. It is written into the collection directory, as
`.tx-sweep`, before the first wave is armed. Every host's run record
carries it as `sweep_id`, and the job sees it as `$TX_SWEEP_ID`. It is
what tells this sweep's results from an earlier run's, which the next
section depends on. A `--muster` sweep has none: the pool is its record,
and it is never resumed (*Drawing the work from a pool*, below).

### A sweep survives its own orchestrator

A ten-wave sweep can take hours, and `tx run` has to stay alive to
sequence it. If it doesn't — you closed the laptop, the ssh session
dropped, somebody hit ^C — `--resume` picks it up from the fleet's own
record and the sweep's collection. Nothing else is remembered here, so
there is nothing to lose. Give it the same `-d` the sweep was started
with: that directory holds the sweep's id.

```bash
tx run --batch 20 -d results --resume
```

```text
[tx] --resume: asking the fleet where it got to (sweep 20260911-201500-3f9a1c)
[tx] 120 done, 20 still running, 60 left to cover
[tx] re-collecting the 120 finished host(s), in case the interrupted sweep never got their results back
[tx] waiting for the 20 host(s) the interrupted sweep left running rather than starting them over
```

Three answers, not two. A host with a result is **done** — and is
collected again anyway, because a host that finished the job and was
killed before its results were fetched has them on the host and nothing
here. A host still working is one the interrupted sweep left running:
agents are detached, so the work outlived the orchestrator, and
restarting it would trample a run that is nearly finished. Only what is
neither gets covered in fresh waves — including a host whose record
stopped mid-job with no agent left behind it (a reboot, an OOM kill):
that host has no result and nothing is coming, so it is run again
rather than waited on.

**Only this sweep's results count.** The fleet keeps no history: a host
the sweep never reached still holds whatever ran there last, finished
and exit 0. So a record counts as done only if it carries this sweep's
id. A host holding an earlier run's result is covered again, and resume
says how many of those it found. Before 1.3.0, resume counted any
finished record: a sweep killed in its first wave and resumed reported
hosts it never ran as passing.

**A `--clean` sweep resumes too.** `--clean` removes each wave from its
hosts once it has been collected, so for those hosts the collection is
the only record left. Resume reads it: a host whose finished record from
this sweep is already in the `-d` directory is done (`N finished host(s)
are already in results/ and need nothing more`), and is not run again.
With `--clean`, the hosts resume picks up from the interrupted sweep are
cleaned too, once they are collected.

`--resume` refuses rather than guess: without `-d`, or with a directory
that holds no `.tx-sweep` (a sweep begun by tx 1.2.2 or older, or not a
sweep's directory at all), nothing is started. Run that sweep again
without `--resume`. A sweep run into a directory without `--resume` is a
new sweep: it writes its own id there, and what an earlier sweep
collected into that directory no longer counts as done.

A host that is running another run's job when you resume is not this
sweep's work, so it is neither waited for nor counted. Resume names it,
and its wave does not start: the deploy says "a job is already running
here -- tx stop first". Stop that job, or resume again once it has ended.

### How often it asks

Every status check is an ssh per host, and those land on the machines
whose benchmark you are measuring. A fixed two-second poll is sixty
thousand connections over a ten-minute run on two hundred hosts — to
learn nothing, most of them, while perturbing the thing under test.

So the interval grows with how long the wait has already lasted: two
seconds at first, thirty seconds once it has been going five minutes.
A job that finishes quickly is still noticed quickly; one that takes an
hour is asked about twice a minute. `--poll S` pins it if you want a
fixed interval.

---

## Drawing the work from a pool

`--batch` walks a fleet the plan names, and the plan is the whole world:
run the same sweep twice and it covers the same hosts in the same order.
`--muster` walks a **pool** somebody else is keeping — [binnacle][b]'s
`muster`, which hands work out under a lease, once each, and is the one
thing that knows what is still outstanding across every machine drawing
from it.

```bash
muster add 'web[01-200]'                        # put the work in the pool
tx run --muster --batch 10 --lease 2h -d results
```

```text
[tx] drawing from the pool muster.csv, 10 at a time, lease 2h -> results/

[tx] === wave 1: 10 item(s) from the pool: web01 web02 web03 ... ===
...
[tx] checking 10 item(s) back in as done

[tx] === wave 2: 10 item(s) from the pool: web11 web12 web13 ... ===
...
[tx] the pool has nothing available.

  PROGRESS   200 of 200 done (100%), 0 held, 0 available
```

tx takes `--batch` items, runs that lot as one armed-together wave,
and checks them straight back in: an item the host has a run record for
is **done** — a job that ran and failed is a measurement, not an item to
hand to the next worker to fail identically — and one nothing reached is
**released** for somebody else. Then it asks for more, until the pool has
nothing left to give it.

The division of labour is the whole point. **muster owns what is
outstanding; tx owns what happens to the items it is holding.** Neither
keeps a copy of the other's record, so:

- **Many machines can run one sweep.** Point several `tx run --muster`
  at the same pool (a shared filesystem, or muster's own locking) and
  they draw from it without ever taking the same item twice. The pool
  is the coordination; tx does none of its own.

- **A killed sweep needs no `--resume`.** A sweep that dies holding
  twenty items leaves twenty leases that simply expire, and the items
  are back in the pool without anything having to notice — no reaper, no
  cleanup, nothing local that was lost. That is why `--muster` and
  `--resume` do not go together: the pool is already the record.

The pool decides *which* items and in what order; the plan stays the
**address book**. An item the plan names is reached at the address the
plan gives it (so a fleet can sit behind aliases); an item the plan does
not name is its own address, so a pool of bare hostnames works against a
plan that lists none of them. The pool is somebody else's file, so an item
that cannot be a host is not run: one starting with `-` (ssh would read it
as an option — `-oProxyCommand=…` runs a command on your machine) or one
with a `/` (it cannot be part of a collected file's name). It is named and
put back, and the sweep exits 1.

`--lease` sets how long each wave holds its items; the default is twice
the wave's own time bound, so a lease always outlasts the work it covers.
That bound is the job's timeout plus the arming window, and the timeout
again for `setup=` and again for `teardown=` when the plan has them: each
phase is bounded by the timeout on its own, so a host can legitimately
take that long, and `tx run` waits that long for a wave before calling it
unfinished.
Too short, and an item goes back to the pool while tx is still running it
— the one thing the lease exists to prevent. `--muster-cmd` names how to
invoke muster when it is not simply `muster` on the `PATH`.

[b]: https://github.com/MartinGallagher-code/binnacle

---

## Shipping the job

`--payload` is a file or a directory. It is packed once, sent to every
host, and unpacked into the working directory — so `--run ./bench.sh`
finds `bench.sh` right there, with its data next to it:

```bash
tx gen --servers servers.txt --payload ./bench --run './bench.sh --size 1M'
```

One transfer per host rather than `scp -r`'s one channel per file, which
on a payload of a thousand small files is a thousand round trips.

**`--setup` runs first**, on each host, for whatever the job needs before
it can run — a build, a package install, a warmed cache:

```bash
tx gen --servers servers.txt --payload ./src --setup 'make -s' --run ./bench
```

A host whose setup fails **does not run the job**. Reporting a benchmark
failure that was really a build failure is worse than reporting nothing:
it is a wrong answer rather than a missing one. The report says so, and
`setup.log` comes back with the collection.

**`--teardown` runs afterwards**, pass or fail, so a host is left as it
was found. That is not conditional on the run going well — it is exactly
when cleanup matters most.

A host is not *finished* until it has been put back: while the teardown
runs the host reads `TIDYING`, and `tx run` waits for that before
collecting. Otherwise the collection would race a teardown still writing
into `$TX_OUT` and leave its output behind.

### What the job reads, and what it says

The job's stdin is `/dev/null` unless the plan names a file, so a command
that waits on input fails at once instead of hanging until the timeout
and reporting nothing. `--stdin NAME` feeds it one — the file ships in
the payload like everything else the job needs:

```bash
tx gen --servers servers.txt --payload ./bench --run ./bench \
       --stdin workload.txt
```

`tx check` catches a `stdin` the payload does not carry, before any ssh:
forgetting to ship it fails identically on all forty hosts, so it is
worth finding without contacting one.

Its stdout and stderr go to files of their own — a benchmark's stdout is
usually its result and its stderr usually its complaints, so merging them
would mean parsing one out of the other. Both come back whole with the
collection, and **the last few lines of stderr ride back inside the
record**, so the report answers *why* rather than only *which*:

```text
  FAILED    2 host(s) exited non-zero:
            db03             exit 1 after 12.1s
                               fio: io_u error on file /dev/nvme1n1: Input/output error
```

A job that never started at all is its own outcome, not a host stuck on
`RUNNING`:

```text
  NEVER RAN 1 host(s) could not start the job at all:
            web12            [Errno 2] No such file or directory: 'bash'
            nothing ran there, so there is no result to read as a failure.
```

### What the job is told

Every job runs under `bash`, in the working directory, with:

| Variable | What it is |
|---|---|
| `TX_OUT` | Where results go. Everything under it is collected. |
| `TX_HOST` | This host's name in the plan. |
| `TX_INDEX` / `TX_NHOSTS` | This host's position in the fleet — for sharding work. |
| `TX_TAG` | The run's tag, which leads every collected filename. |
| `TX_RUN_ID` | The run's stamp, shared by every host in one start. |
| `TX_SWEEP_ID` | With `--batch`, the sweep's id, shared by every wave of one sweep. Unset otherwise, and in a `--muster` sweep. |
| `TX_HOSTS` | The whole host list, with `--peers`. |

and `stdin` from the plan's `stdin =` file, or `/dev/null`.

```bash
tx gen --servers servers.txt --run './shard.sh $TX_INDEX $TX_NHOSTS' --peers
```

### The payload cannot break the agent

The agent is `tx.py` itself, copied into the working directory beside the
unpacked payload. It never imports anything the job shipped: it is started
as `python3 -I tx.py agent …`, and Python's isolated mode leaves the
script's own directory off `sys.path` and ignores `PYTHON*` variables, for
the agent's interpreter only. Before 1.2.2 a payload with a top-level
`json.py`, `queue.py`, `signal.py` or `subprocess.py` replaced that
standard module in the agent, which died on startup on every host and said
only that it had.

The job is not isolated. It runs in the payload directory with the
environment the agent was given, `PYTHONPATH` included, so a `bench.py`
that does `import helper` finds the `helper.py` beside it, exactly as when
you run it there yourself. That is also why `tx check` does not warn about
a payload `json.py`: it can no longer reach the agent, and what the job
imports from its own directory behaves on the hosts as it does on your
machine.

`--python` (or `TX_PYTHON`) must accept `-I`, as every CPython since 3.4
does; the 3.6 floor already guarantees it.

---

## Results that stay apart

One directory per collection, and everything in it is told apart by its
**name** rather than by where it sits:

```text
tx-20260911-201500/bench~web01~out~results.json
tx-20260911-201500/bench~web02~out~results.json
tx-20260911-201500/bench~web02~stdout
```

Rebuilding each host's directory tree locally reads well and greps badly.
The command you actually want next is `grep -l FAIL *`, or
`jq .score *results.json`, and both want one directory of
distinctly-named files — not forty identical paths under forty host
directories.

The **tag leads**, so several runs can share one directory and still be
told apart — and `rm before~*` clears one of them:

```bash
tx gen ... --tag before && tx run -d results
tx gen ... --tag after  && tx run -d results
```

Without `-d` each collection gets a directory of its own, stamped with
the time: collecting the same job twice an hour apart is the normal way
to use this, and the second run quietly replacing the first is not a
result anybody wants to find later.

**What comes back:** everything under `TX_OUT`, plus each host's
`stdout`, `stderr`, `setup.log`, `teardown.log`, `agent.log` and the
run's own JSON record — always. The agent's log is in that list because
it is where anything the agent could not turn into a record ends up, and
a run that went wrong is exactly when you need it. `--collect GLOB` adds anything else you want, evaluated
on the host.

**Only this run's.** Every start — `tx start`, `tx run`, each wave of a
sweep, with `--no-deploy` as well as without — first removes the last
run's `out/`, run record, `stdout`, `stderr`, `setup.log`, `teardown.log`
and `agent.log` on each host. So collect what you want from one run
before you start the next on the same hosts. Before 1.3.0 a `--no-deploy`
start kept them, and its collection brought the last run's `out/` and
logs back as though this run had written them.

What `--collect GLOB` finds *beside* `TX_OUT` is not removed by a start
or a deploy: it is the job's own (or the payload's), not tx's. A file an
earlier run wrote there, and this run did not write again, comes back in
this run's collection. Have the job write its results into `$TX_OUT`, or
remove its own old files before it writes new ones.

**`--max-bytes` is the ceiling**, 100 MB per file by default. A benchmark's
results are usually small and what this stops is the exception — a core
dump, a heap profile, a log that ran away. It is applied *on the host*,
so an oversized file never crosses the network, and it is always named
rather than silently dropped:

```text
  OVERSIZE  1 file over --max-bytes (100.0MB), left where they are:
            web12         4.1GB  out/core.20260913
            raise --max-bytes, or have the job write less.
```

`--max-bytes 0` removes the ceiling.

Nothing a remote host says is used as a local path. Names are rebuilt
here from the host name and the path within its working directory, so a
host answering with `../../etc/cron.d/x` writes inside the collection
directory or not at all. Two files that would fold onto one name are
reported rather than written over each other.

---

## Reading the result

```bash
tx summarize
```

```text
tx -- ./bench.sh   [bench]
      40 of 40 hosts finished: 37 passed, 2 failed, 1 timed out

  START     spread 31ms across 40 hosts (worst +0.019s off the armed instant)
  DURATION  median 4m12s, fastest 3m58s, slowest 9m01s
  SLOW      2 host(s) took over 1.5x the median:
            web12            9m01s
            web31            7m44s
  FAILED    2 host(s) exited non-zero:
            db03             exit 1 after 12.1s
            db04             exit 1 after 11.8s
  TIMEOUT   1 host(s) hit the 10m00s limit: web12
            raise timeout= in plan.ini, or find out why they are slower.
```

An outlier is usually the reason a fleet benchmark is being run at all,
so the hosts are named rather than just counted.

---

## Draw it on the floor plan (`tx export`)

Which host was slow is a number; *which rack* it sits in is the question.
`tx export` turns a run into an overlay for the
[datacenter layout viewer](https://github.com/MartinGallagher-code/datacenter_visualization),
which draws your floor from a `.dc` file and colours every node by a
measured value — the same results file
[`mx`](https://github.com/MartinGallagher-code/matrix_orchestrator) and
[`iperf_orchestrator`](https://github.com/MartinGallagher-code/iperf_orchestrator)
write, so a benchmark's timings sit on the floor beside the fabric's numbers:

```bash
tx run -d results                  # measure
tx export >> results.tsv           # colour the floor plan with it
```

That is the whole integration. The viewer's results format is one sample
per line — `test  target  value  [key=value ...]` — so the file is
append-only: export after every run and the viewer aggregates the history
however you ask it to (mean, p95, max, last).

```text
!test	tx_duration	unit=s higher=bad decimals=2 short=DUR label="Job wall-clock time"
!test	tx_start_offset	unit=ms higher=bad decimals=1 short=SYNC label="Start offset from the armed instant"
tx_duration	web12r06u15	541.2	run=nightly-7
tx_start_offset	web12r06u15	31.4	run=nightly-7
tx_state	web12r06u15	PASSED	run=nightly-7
```

One sample per host:

| Overlay | What it is |
|---|---|
| `tx_duration` | the job's wall-clock time, seconds |
| `tx_rel_median` | its runtime against the fleet's own median, % — 100% is normal for this fleet |
| `tx_start_offset` | how far off the armed instant this host actually started, ms |
| `tx_exit` | the job's exit code |
| `tx_setup_exit` `tx_teardown_exit` | the setup and teardown exit codes, when they ran |
| `tx_timed_out` | 1 if the host hit the timeout, 0 if not |
| `tx_state` | `PASSED`, `FAILED`, `TIMEOUT`, `SETUP-FAILED`, `NEVER-RAN`, `RUNNING`, and `NO-DATA` for a host in the plan that never reported |

**Reading a runtime without knowing the hardware.** `tx_rel_median` puts
every host against the fleet's own median, on a diverging ramp where 100% is
"normal for this fleet" — so a slow rack stands out whatever the absolute
seconds are.

**The sync map.** `tx_start_offset` is the one number only `tx` can draw:
how far each host was from the instant they were all armed for. "They
started together" stops being a claim and becomes a colour on the floor,
where a late rack — a slow NTP, an overloaded hypervisor — shows.

By default `tx export` reads the fleet the way `tx status` does. After a
`tx clean`, or to re-export what you already brought back, point it at the
collection instead:

```bash
tx export --from results >> results.tsv
```

It reads each host's record from the name `tx collect` gives it,
`tag~host~run.json`; anything else called `run.json` — a job's own
`out/run.json`, say — is the job's, not a record, and is skipped. A
directory that several tagged runs share is read for the plan's tag, and
refused without a plan to say which. A host with a record that the plan
does not name (a `--muster` item) is exported too: the plan is the roll
call, not a filter.

`--names FILE` maps tx host names to the layout's, `--target-prefix DH1/A/`
addresses nodes by path, `--test-prefix` replaces `tx_`, `--run LABEL` tags
every sample, and `--json` writes NDJSON for a pipeline rather than a
person. The prefixes and the label land on every line of a
whitespace-separated file, so one holding whitespace or a quote is
refused.

---

## The plan file

Everything the run needs lives in `plan.ini`, so no command but `gen`
needs those flags again. Edit it and re-run `tx start`:

```ini
[job]
run = ./bench.sh --size 1M
setup = make -s
teardown =
payload = ./bench
timeout = 600
stdin = workload.txt
collect = *.csv
tag = bench
remote_dir = /var/tmp/tx

[hosts]
web01 = 10.0.0.11
web02 = 10.0.0.12
```

A host's name and address may not start with `-`, which ssh and scp
would read as an option rather than a destination, and a name may not
hold a `/`, since it is part of every collected file's name. `tx gen`
and every command that reads the plan refuse them, as they do a `--user`
starting with `-`.

A command spanning several lines is fine — continuation lines are
indented, and it arrives on the far side exactly as typed. It travels
base64'd from the plan to the agent, so no shell parses it on the way:
quotes, newlines, `$(...)` and backslashes all survive.

### Whose working directory it is

`remote_dir` (`--remote-dir`, default `/var/tmp/tx`) is where the agent and
the payload land, where the job runs and where its results wait to be
collected. `/var/tmp` is writable by every user on a host, so anyone could
make `/var/tmp/tx` before tx does — and whoever owns that directory, or can
write to it, could swap `tx.py` between the copy and the launch and have
their code run as you, plant an `agent.pid` for `tx stop` to kill, or leave
a symlink where the copy writes.

So before any command writes to it, runs from it, reads from it, stops
what it names or deletes it, each host checks that the directory is:

- a real directory — not a symlink, not a file;
- owned by the ssh user;
- writable by nobody else — no group-write, no other-write bit.

A host where it is not fails with a line that says why, and nothing in the
directory is touched:

```text
  web02  REFUSED: --remote-dir /var/tmp/tx is owned by mallory (uid 1002), mode drwxrwxrwx; the ssh user is uid 1000: it is not owned by the ssh user; others can write to it; its group can write to it. tx will not deploy to it, ...
[tx] FAILED on 1/2 hosts: web02
```

Remove it, `chmod go-w` it, or pick another `--remote-dir`. A directory tx
makes itself is made `0700`; one that is already there keeps its mode.
`tx doctor` gives every host's answer before a run (`remote_dir=ok`,
`absent`, or the `REFUSED:` line), and `tx status` shows the `REFUSED:` line
in place of that host's state.

The copy itself goes into a private `.tx-incoming.*` directory inside the
checked one and is renamed into place, and the launch checks the
directory again in the same breath as it runs the agent — so nothing that
changed between the copy and the start is run.

**A directory a group shares on purpose** can be let through with
`--allow-shared-remote-dir` (or `TX_ALLOW_SHARED_REMOTE_DIR=1`). It lifts
the group-write check only: the directory must still be the ssh user's
own, not a symlink, and not writable by everyone. Anyone in that group can
still change what runs, so use it only for a group you trust with your
login.

---

### What `tx clean` will and won't promise

**It deletes only what tx put there**, and refuses rather than delete
anything else. Before 1.1.1 it ran `rm -rf` on whatever `--remote-dir`
named; now it removes, by name:

- tx's own files: the agent (`tx.py`), `payload.tar.gz`, `out/`, the run
  record (`run.json`), `stdout`, `stderr`, `setup.log`, `teardown.log`,
  `agent.log`, `agent.pid`, and `.tx-manifest`, plus any `.tx-incoming.*`
  a deploy or start cut short left behind (see [Whose working directory it
  is](#whose-working-directory-it-is));
- what the payload unpacked — the deploy writes each top-level name it
  *creates* into `.tx-manifest` (a name already there is somebody else's,
  and stays theirs);
- what the run left beside them — whatever setup built, or a job wrote
  next to itself rather than into `$TX_OUT` (`collect = *.csv`): the agent
  notes what is new in the directory as the run ends, however it ends;

and then `rmdir`s the directory. If anything else is in it — a file of
somebody else's, a directory the payload was unpacked *into* but did not
create, or the files of a directory deployed by tx 1.1.0 or earlier,
which kept no record — that host is refused, the entries are named, and
nothing on it is deleted:

```text
  web01  REFUSED: tx did not put 1 thing(s) in /var/tmp/tx: 'notes.txt' -- nothing deleted; move them out or delete them, then tx clean again
[tx] 1 host(s) left exactly as they were: tx deletes only what it put there, and says what else it found (above)
```

A payload may not bring its own `.tx-manifest`: `tx start` refuses it,
since the deploy keeps its record under that name.

**It stops only this run's agent.** `tx stop`, `tx clean`, the stand-down
after a failed start, `tx status`'s `ALIVE` and `tx doctor`'s
`agent_running` all go by one test: a pid is this run's only if it is a
live `tx.py agent` whose working directory (`/proc/PID/cwd`) is this
`--remote-dir`. So a second run out of another `--remote-dir` on the same
hosts keeps running, another user's agent is never touched, and an
`agent.pid` naming a pid long since reused by something else — the default
`/var/tmp/tx` survives a reboot — is not "already running" and is never
signalled. With `agent.pid` gone, the agent is found by its working
directory, read from `/proc` itself (no procps needed), never by name.

**Without `/proc`** (macOS) there is no working directory to read, so tx
goes by `agent.pid` and the agent's command line. If `agent.pid` is gone
and a tx agent of yours is running, `stop` and `clean` fail on that host
and say to kill it by hand — they never kill by name — and `clean` leaves
the directory where it is.

**It says "nothing of tx remains" only if it could check.** After the stop
it asks whether an agent of this run outlived it. That question starts
with `pgrep`, and on a host without procps a missing `pgrep` looks
exactly like `pgrep` finding nothing — so rather than read that as a
clean host, it says what it actually knows:

```text
[tx] the working directory is gone from every host. On 2 of them whether an agent
     outlived it could not be checked (no pgrep, or no /proc to say whose an agent is): db07 db08
```

An agent still running out of the directory is a `LEFTOVER`: that host
fails and nothing on it is deleted. Another run's agent is not one.

`tx doctor` reports `pgrep=` and `proc=` per host, so you know before
the run whether `clean` can rule out a stray agent and whether a lost
`agent.pid` can be traced.

`tx run --clean` (with `--batch` and `--muster` too) exits 1 when the
clean failed on any host. In a sweep the next wave still runs, unless
`--stop-on-fail` makes that wave the last.

## Exit status

| Code | Meaning |
|---|---|
| `0` | every host ran the job and exited zero, and everything came back |
| `1` | a host failed, timed out, was never reachable, stopped mid-job without a result (`GONE`), or nothing was collected |
| `2` | usage error |
| `130` | interrupted (Ctrl-C). Agents already started are detached and keep running: `tx status` shows them, `tx collect` brings back what they made, `tx stop` stops them |

---

## Environment variables

Each is the default for the matching flag: `TX_PLAN`, `TX_SERVERS`,
`TX_REMOTE_DIR`, `TX_DIR`, `TX_USER` (or `SSH_USER`), `TX_JOBS`,
`TX_PYTHON`, and `TX_ALLOW_SHARED_REMOTE_DIR=1` for
`--allow-shared-remote-dir`.

---

## License

Copyright (C) 2026 Martin J. Gallagher

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see <https://www.gnu.org/licenses/>.

Full text: the `LICENSE` file at the repository root, or
<https://www.gnu.org/licenses/gpl-3.0.html> — SPDX identifier
`GPL-3.0-or-later`. This repository follows the
[REUSE Specification](https://reuse.software/): source files carry SPDX
copyright and licence headers, and the licence text lives in `LICENSES/`.
