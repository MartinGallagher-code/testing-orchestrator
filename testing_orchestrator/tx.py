#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""tx -- run one benchmark on a whole fleet at once, and bring the results back.

One file. One command per thing you want to do. Every host runs the same
job, started at the same instant, and everything it produced comes back
into one directory whose names say which machine each file came from.

    tx gen --servers servers.txt --payload ./bench --run ./bench.sh
                                               # 1. build plan.ini
    tx start                                   # 2. deploy + start together
    tx status                                  # 3. running? finished? how?
    tx collect                                 # 4. results, named by host
    tx summarize                               # 5. who passed, who was slow
    tx clean                                   # 6. remove every trace

`tx run` does steps 2-5 in one shot and waits for the fleet to finish.
`tx hints` turns "I want X" into the command that gets you X.

Everything the run needs lives in plan.ini -- the host list, the command,
what to ship with it, the timeout and what to collect -- so no other
command needs those flags again. Edit the file and re-run `tx start`.

What it is for
  You have a benchmark, a stress test, a conformance suite or a one-off
  reproduction script, and you need it run on forty machines rather than
  one. Doing that by hand is forty scp commands, forty ssh sessions you
  have to start close enough together to mean anything, and forty sets of
  results that all land on top of each other because they are all called
  `results.json`.

  This is the non-network sibling of `mx` and `iperf_orchestrator`. Those
  two generate traffic and measure the fabric. This one does not care
  what the job is: it ships it, starts it everywhere at one instant,
  waits, brings back what it produced, and removes itself.

At the same instant, and able to prove it
  Starting forty ssh sessions takes seconds, and a benchmark that starts
  on host 1 five seconds before host 40 is not a fleet measurement -- it
  is forty measurements of different moments. So `tx start` does not
  start anything: it *arms* every host with a wall-clock instant a few
  seconds out, and each agent sleeps until then.

  That makes the claim depend on the hosts' clocks agreeing, so the
  deploy measures each host's offset against this machine and refuses a
  fleet that disagrees by more than --max-skew. Every agent records the
  time it actually began, and `tx summarize` reports the spread across
  the fleet -- so "at the same time" is a measured number in the report,
  not a hope.

Results that stay apart
  One directory per collection, and everything in it is told apart by
  its *name* rather than by where it sits:

      tx-20260911-201500/bench~web01~out~results.json
      tx-20260911-201500/bench~web02~out~results.json
      tx-20260911-201500/bench~web02~stdout

  Rebuilding each host's directory tree locally reads well and greps
  badly. The command you actually want next is `grep -l FAIL *`, or
  `jq . *results.json`, and both want one directory of distinctly-named
  files, not forty identical paths under forty host directories.

Python 3.6+, standard library only, on the orchestrator and on every host.
"""

import argparse
import base64
import configparser
import errno
import io
import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

VERSION = "2.0.0"

DEFAULT_PLAN = "plan.ini"
DEFAULT_SERVERS = "servers.txt"
DEFAULT_REMOTE_DIR = "/var/tmp/tx"
DEFAULT_TIMEOUT = 3600.0

# Per file, on collection. A benchmark's results are usually small and
# the thing this stops is the exception: a core dump, a heap profile, a
# log that ran away. Refused on the host, so the bytes never travel --
# and always named, because a result silently not collected is worse
# than one you were told about.
DEFAULT_MAX_BYTES = 100 << 20
DEFAULT_JOBS = 64

# How far ahead of now the synchronised start is armed. Every host has to
# be contacted, the agent has to be launched, and the launch has to have
# happened *before* the instant arrives -- so this is the ssh fan-out's
# budget. It grows with the fleet in `arm_delay` below.
DEFAULT_START_IN = 5.0

# A fleet whose clocks disagree by more than this cannot be started
# together in any meaningful sense, so the deploy refuses rather than
# producing a run whose "simultaneous" is a fiction.
DEFAULT_MAX_SKEW = 1.0

# Files the agent always writes, and which are therefore always collected.
# They are the run's own record, as opposed to whatever the job produced.
REPORT_NAME = "run.json"
STDOUT_NAME = "stdout"
STDERR_NAME = "stderr"
SETUP_LOG = "setup.log"
TEARDOWN_LOG = "teardown.log"
PID_NAME = "agent.pid"
LOG_NAME = "agent.log"
OUT_NAME = "out"
STDIN_DEFAULT = ""
# The agent's own log is in here because a run that went wrong is exactly
# when you need it: anything the agent could not turn into a record --
# a job that would not launch at all -- lands there and nowhere else.
ALWAYS = (REPORT_NAME, STDOUT_NAME, STDERR_NAME, SETUP_LOG, TEARDOWN_LOG,
          LOG_NAME)

# A --batch sweep's own record, in the directory it collects into: the
# sweep's id, which the agent also stamps into every host's run record
# (`sweep_id`). The id is what tells this sweep's results from an earlier
# run's in the same --remote-dir -- the fleet keeps no history, so a host
# a sweep never reached still holds whatever ran there last, done and
# exit 0. --resume reads the id from here and counts only records that
# carry it. A dot name, so `grep -l FAIL *` and `jq . *` pass it by.
SWEEP_NAME = ".tx-sweep"

# The states a run record ends in: the host has run the job (or failed to)
# and nothing more is coming from it.
FINISHED = ("done", "timeout", "setup-failed", "launch-failed")

# The separator between the parts of a collected file's name. `~` is legal
# in a filename everywhere, needs no shell quoting, and does not occur in
# ordinary paths -- so a name can be read back apart unambiguously.
FLAT_SEP = "~"

SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]

# What a host says when it could not check whether an agent survived --
# no pgrep there, and a missing pgrep is indistinguishable from "none
# found". The difference matters: one is a clean host, the other is an
# unanswered question.
UNVERIFIED = "UNVERIFIED"

# Every tx agent of the ssh user, as candidates only: pgrep cannot say
# whose run an agent belongs to, so nothing is ever killed or reported on
# this alone -- each pid it names is put to `tx_ours` (below) first. `-u`
# because another user's agent is never this run's, and the pattern is
# bracketed so the very shell running it is not itself a match: that
# shell's command line contains the literal "[t]x.py agent", which the
# regex "tx.py agent" does not match.
PGREP_MINE = "pgrep -u \"$(id -u)\" -f '[t]x[.]py agent'"

# The payload travels under this one name and is unpacked from it.
PAYLOAD_NAME = "payload.tar.gz"

# What tx put in the working directory besides its own fixed names: the
# payload's top-level entries that the unpack created, and whatever the
# run (setup, job, teardown) left beside them. `tx clean` deletes those
# and nothing else, so the record is what stands between a mistyped
# --remote-dir and somebody's files. One name per line; a name tx keeps
# for itself, so a payload may not bring its own.
MANIFEST_NAME = ".tx-manifest"

# How a snippet on a host tells this run's agent from anybody else's.
#
# A pid alone is not enough. The default working directory survives a
# reboot, so agent.pid can name a pid long since reused -- by a login
# shell, a tmux server -- and `kill -TERM -<pid>` on that is a whole
# process group that was never tx's. And "any `tx.py agent`" is not
# enough either: a second run out of another --remote-dir is one too, and
# so is another user's. The agent `cd`s into its working directory before
# it starts and never leaves it, so the directory says whose it is: a pid
# is this run's only if it is alive, is `tx.py agent`, and works in $here
# (the remote dir, as `pwd -P` resolves it).
#
# Read from /proc itself, so it needs no procps. Without /proc (macOS)
# there is no working directory to read: the pid file and the command
# line (`ps`) are all there is, and a lost pid file is answered by
# refusing rather than by killing anything by name (_kill_block).
# TX_PROC_ROOT stands in a host with no /proc for the tests.
#
# Plain POSIX sh -- the ssh user's login shell runs it -- and no
# `local`, so every helper's variables carry a tx_ prefix.
AGENT_PROBE = r"""
proc=${TX_PROC_ROOT:-/proc}
have_proc=no
[ -e "$proc/$$/cwd" ] && have_proc=yes
# tx_ours PID: is PID a live tx agent working in $here? Never 0, 1 or
# this shell: a pid of 0 or 1 is a whole process group, or every process,
# to `kill -<pid>`, and tx_scan puts every pid on the host to this test.
tx_ours() {
    case "$1" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$1" = "$$" ] && return 1
    kill -0 "$1" 2>/dev/null || return 1
    if [ "$have_proc" = yes ]; then
        [ -n "$here" ] && [ "$proc/$1/cwd" -ef "$here" ] || return 1
        tx_cmd=$(tr '\000' ' ' < "$proc/$1/cmdline" 2>/dev/null)
    elif command -v ps >/dev/null 2>&1; then
        tx_cmd=$(ps -o args= -p "$1" 2>/dev/null)
    else
        # No /proc and no ps: the pid file is the only handle there is.
        return 0
    fi
    case " $tx_cmd " in *" "@AGENT@" agent "*|*/@AGENT@" agent "*) return 0 ;; esac
    return 1
}
# tx_scan: every agent working in $here, found by reading /proc -- for
# when the pid file is gone or names somebody else.
tx_scan() {
    tx_found=""
    for tx_p in "$proc"/[0-9]*; do
        tx_p=${tx_p##*/}
        tx_ours "$tx_p" && tx_found="$tx_found $tx_p"
    done
}
# tx_kids PID: PID's children, read before PID is killed (after, they
# belong to init and nothing says they were the agent's). Each is a job
# phase, which the agent starts in a session of its own.
tx_kids() {
    tx_kids=""
    if [ "$have_proc" = yes ]; then
        tx_parent=$1
        for tx_s in "$proc"/[0-9]*/stat; do
            tx_line=""
            read -r tx_line 2>/dev/null < "$tx_s" || continue
            # The command name can hold spaces and parentheses, so the
            # fields are counted from after its closing ") ".
            set -- ${tx_line##*") "}
            [ "${2:-}" = "$tx_parent" ] || continue
            tx_c=${tx_s%/stat}
            tx_kids="$tx_kids ${tx_c##*/}"
        done
    else
        tx_kids=$(pgrep -P "$1" 2>/dev/null)
    fi
}
"""


def _agent_name():
    """The agent's file name on the hosts: what `tx start` copies there,
    and what its command line says it is running."""
    return os.path.basename(_agent_source())


def _probe():
    """AGENT_PROBE, for this agent's name."""
    return AGENT_PROBE.replace("@AGENT@", shlex.quote(_agent_name()))


def _own_names():
    """Everything tx itself writes in the working directory, by name.

    These are tx's whatever the record says. Anything else there is tx's
    only if the record (MANIFEST_NAME) names it.
    """
    return (_agent_name(), PAYLOAD_NAME, OUT_NAME, REPORT_NAME,
            REPORT_NAME + ".tmp", STDOUT_NAME, STDERR_NAME, SETUP_LOG,
            TEARDOWN_LOG, LOG_NAME, PID_NAME, MANIFEST_NAME)

# The guard on --remote-dir (TX-002, as mx 1.12.0's MX-006). The default
# /var/tmp/tx sits in a world-writable directory, so any user on a host can
# make it first. Whoever owns it, or can write to it, can swap tx.py or the
# payload between the copy and the launch (separate ssh round trips) and so
# run their code as the ssh user, plant an agent.pid for `tx stop` to
# signal, or leave a symlink where scp writes. So before tx writes to it,
# runs from it, signals what its pid file names, reads from it or deletes
# it, each host checks that it is:
#   * a real directory -- not a symlink (a trailing slash is dropped first,
#     so `link/` is the link), not a file;
#   * owned by the ssh user (`id -u` there);
#   * writable by nobody else: no group-write, no other-write bit.
#     --allow-shared-remote-dir (TX_ALLOW_SHARED_REMOTE_DIR=1) lifts the
#     group-write rule only, for a directory a group shares on purpose; the
#     symlink, owner and other-write rules always hold.
# `ls -ldn` rather than stat, whose flags differ between GNU and BSD.
# Missing is not refused here: start makes it (mkdir -m 700), and stop,
# clean and status report it as never deployed, as they always did.
# A plain function, not a format template: it is put in front of snippets
# whose own braces are already formatted.
DIR_CHECK_FN = """
_tx_dir_check() {
    _tx_bad=""
    if [ -L "$1" ] || { [ -e "$1" ] && [ ! -d "$1" ]; }; then
        _tx_bad="$1 is a symlink or not a directory ($(ls -ld -- "$1" 2>/dev/null | cut -c1-10))"
        return 1
    fi
    [ -d "$1" ] || return 0
    _tx_dm=$(ls -ldn -- "$1" | awk 'NR==1 {print $1}')
    _tx_du=$(ls -ldn -- "$1" | awk 'NR==1 {print $3}')
    _tx_dn=$(ls -ld -- "$1" | awk 'NR==1 {print $3}')
    _tx_id=$(id -u)
    _tx_why=""
    [ "$_tx_du" = "$_tx_id" ] || _tx_why="it is not owned by the ssh user"
    case "$_tx_dm" in
        ????????w*) _tx_why="${_tx_why:+$_tx_why; }others can write to it" ;;
    esac
    if [ "$_tx_shared" != 1 ]; then
        case "$_tx_dm" in
            ?????w*) _tx_why="${_tx_why:+$_tx_why; }its group can write to it" ;;
        esac
    fi
    [ -n "$_tx_why" ] || return 0
    _tx_bad="$1 is owned by $_tx_dn (uid $_tx_du), mode $_tx_dm; the ssh user is uid $_tx_id: $_tx_why"
    return 1
}
"""

REFUSED_HOW = ("tx will not deploy to it, run from it, stop what it names, "
               "collect from it or clean it: remove it, chmod go-w it, or "
               "pick another --remote-dir (a group-shared one needs "
               "--allow-shared-remote-dir)")

# Where a deploy copies to: a directory of tx's own inside --remote-dir,
# made private, whose contents are then renamed over the real names. scp
# follows a symlink at the name it writes to, so a symlink planted at tx.py
# (possible in a group-shared directory) would have it overwrite the file
# the link points to; rm -f then mv replaces the link instead.
STAGE_PREFIX = ".tx-incoming."


def _env(name, default):
    v = os.environ.get(name)
    return v if v else default


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def die(msg, code=2):
    sys.stderr.write("tx: %s\n" % msg)
    sys.exit(code)


def log(msg):
    sys.stdout.write("%s\n" % msg)
    sys.stdout.flush()


class Interrupted(KeyboardInterrupt):
    """Ctrl-C, once tx has done and said what it does about one.

    Raised in place of the KeyboardInterrupt it answers, by the code that
    knew what was going on when the key was pressed: it has already left
    the hosts the way a Ctrl-C at that moment leaves them, and told the
    person what is still running and what to type next. `main` exits 130
    without adding a word. `left` names the hosts that may still be
    running this run's job, which a sweep drawing from a pool must not
    hand out again.
    """

    def __init__(self, left=()):
        KeyboardInterrupt.__init__(self)
        self.left = list(left)


def fmt_secs(s):
    if s is None:
        return "?"
    if s < 1:
        return "%dms" % round(s * 1000)
    if s < 60:
        return "%.1fs" % s
    if s < 3600:
        return "%dm%02ds" % (int(s) // 60, int(s) % 60)
    return "%dh%02dm" % (int(s) // 3600, (int(s) % 3600) // 60)


def fmt_bytes(n):
    for unit, size in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if n >= size:
            return "%.1f%s" % (float(n) / size, unit)
    return "%dB" % n


def b64(text):
    """Text as base64, for anything that has to cross a shell untouched."""
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def unb64(text):
    return base64.b64decode(text.encode("ascii")).decode("utf-8")


# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------
#
# One file describes the whole run, the way matrix.csv does for mx: the
# job, what ships with it, and the hosts it runs on. Every command reads
# it, so no command but `gen` needs those flags.

PLAN_KEYS = ("run", "setup", "teardown", "payload", "timeout", "collect",
             "tag", "remote_dir", "stdin")


class Plan(object):
    __slots__ = ("path", "hosts", "addrs", "run", "setup", "teardown",
                 "payload", "timeout", "collect", "tag", "remote_dir",
                 "stdin")

    def __init__(self, path, hosts, addrs, run, setup, teardown, payload,
                 timeout, collect, tag, remote_dir, stdin=""):
        self.path = path
        self.hosts = hosts
        self.addrs = addrs
        self.run = run
        self.setup = setup
        self.teardown = teardown
        self.payload = payload
        self.timeout = timeout
        self.collect = collect
        self.tag = tag
        self.remote_dir = remote_dir
        self.stdin = stdin


def parse_token(tok):
    """`name`, `name=addr` or a bare address. Returns (name, addr).

    A name that is not an address is what every report, every collected
    filename and every error message uses, so a fleet can be renamed
    without the results changing shape.
    """
    tok = tok.strip()
    if not tok:
        return None, None
    if "=" in tok:
        name, addr = tok.split("=", 1)
        name, addr = name.strip(), addr.strip()
        if not name or not addr:
            return None, None
        return name, addr
    return tok, tok


def host_problem(name, addr):
    """Why a host's name or address cannot be used, or "" when it can.

    The address is ssh's and scp's destination argument, and one that
    starts with '-' is read as an option instead: `-oProxyCommand=...`
    runs a command on this machine, `-F FILE` reads another ssh config.
    The name goes to the agent as `--host NAME` and into every collected
    file's name, where a '/' is a directory that does not exist.
    """
    if name.startswith("-") or addr.startswith("-"):
        return "starts with '-', which ssh would read as an option"
    if "/" in name:
        return "has a '/', which cannot be part of a collected file's name"
    return ""


TAG_RE = re.compile(r"[^A-Za-z0-9._+-]+")


def clean_tag(tag):
    """A tag reduced to something safe as part of a filename.

    The tag is the one part of a collected name the caller writes freely,
    so it is the one part that could carry a slash and quietly mean a
    directory.
    """
    cleaned = TAG_RE.sub("-", (tag or "").strip()).strip("-")
    return cleaned or "tx"


def default_tag(run_cmd):
    """A tag for a job nobody named: the command's own first word.

    `--run ./fio-seq.sh` becomes `fio-seq.sh`, which is what somebody
    reading the results directory later would have called it anyway.
    """
    first = (run_cmd or "").strip().split()
    if not first:
        return "tx"
    return clean_tag(first[0].rsplit("/", 1)[-1])


def load_plan(path):
    if not os.path.isfile(path):
        die("plan not found: %s  (make one with: tx gen --servers %s "
            "--run './bench.sh')" % (path, DEFAULT_SERVERS))
    cp = configparser.RawConfigParser()
    # Case matters in host names and in nothing else configparser touches,
    # so stop it from lowercasing keys.
    cp.optionxform = str
    try:
        with open(path) as fh:
            text = fh.read()
        if hasattr(cp, "read_string"):
            cp.read_string(text)
        else:                                       # pragma: no cover
            cp.readfp(io.StringIO(text))
    except configparser.Error as exc:
        die("%s: %s" % (path, exc))

    if not cp.has_section("job") or not cp.has_section("hosts"):
        die("%s: needs a [job] and a [hosts] section -- regenerate it with "
            "`tx gen`" % path)

    def get(key, default=""):
        if cp.has_option("job", key):
            return cp.get("job", key).strip()
        return default

    for key in cp.options("job"):
        if key not in PLAN_KEYS:
            die("%s: unknown key %r in [job] -- known keys are: %s"
                % (path, key, ", ".join(PLAN_KEYS)))

    run = get("run")
    if not run:
        die("%s: [job] run= is empty -- there is nothing to run" % path)

    try:
        timeout = float(get("timeout", str(DEFAULT_TIMEOUT)))
    except ValueError:
        die("%s: bad timeout=%r" % (path, get("timeout")))
    if timeout <= 0:
        die("%s: timeout must be positive; a job with no bound is a fleet "
            "nobody can get back" % path)

    hosts, addrs = [], {}
    for name in cp.options("hosts"):
        addr = cp.get("hosts", name).strip() or name
        if name in addrs:
            die("%s: duplicate host %r" % (path, name))
        why = host_problem(name, addr)
        if why:
            die("%s: host %r %s" % (path, name if name == addr
                                     else "%s = %s" % (name, addr), why))
        hosts.append(name)
        addrs[name] = addr
    if not hosts:
        die("%s: [hosts] is empty" % path)

    collect = [p for p in get("collect").split() if p]
    return Plan(path, hosts, addrs, run, get("setup"), get("teardown"),
                get("payload"), timeout, collect,
                clean_tag(get("tag") or default_tag(run)),
                get("remote_dir", DEFAULT_REMOTE_DIR),
                get("stdin", STDIN_DEFAULT))


def _ini_value(text):
    """A value as configparser will read it back.

    A benchmark command is quite often several lines. configparser joins
    a value's *indented* continuation lines with newlines and treats an
    unindented one as the next key, so writing the command out verbatim
    would silently truncate it at the first newline -- and a truncated
    command is a wrong run on every host at once.
    """
    return (text or "").replace("\n", "\n\t")


def write_plan(path, tokens, run, setup, teardown, payload, timeout,
               collect, tag, remote_dir, stdin=""):
    out = sys.stdout if path == "-" else open(path, "w")
    try:
        out.write("# tx plan v%s -- one job, run on every host at the same "
                  "instant.\n" % VERSION.split(".")[0])
        out.write("# Edit this file and re-run `tx start`; nothing else "
                  "needs those flags again.\n")
        out.write("\n[job]\n")
        out.write("# The command. It runs under bash in the working "
                  "directory, with the\n"
                  "# payload unpacked around it and $TX_OUT naming where "
                  "results should go.\n")
        out.write("run = %s\n" % _ini_value(run))
        out.write("\n# Run before the job on each host (build, install, warm "
                  "a cache). A host\n"
                  "# whose setup fails does not run the job, and says so.\n")
        out.write("setup = %s\n" % _ini_value(setup))
        out.write("\n# Run after the job, pass or fail, so a host is left as "
                  "it was found.\n")
        out.write("teardown = %s\n" % _ini_value(teardown))
        out.write("\n# A file or directory shipped to every host and "
                  "unpacked into the working\n"
                  "# directory: the benchmark itself, its data, whatever it "
                  "needs.\n")
        out.write("payload = %s\n" % payload)
        out.write("\n# A file in the working directory to feed the job on "
                  "stdin. Ship it in\n# the payload; without one the job "
                  "reads /dev/null.\n")
        out.write("stdin = %s\n" % stdin)
        out.write("\n# Seconds before a host's job is killed. Not optional: "
                  "a job with no\n# bound is a fleet nobody can get back.\n")
        out.write("timeout = %g\n" % timeout)
        out.write("\n# Extra things to collect, as globs relative to the "
                  "working directory.\n"
                  "# Everything under out/ and the run's own record come "
                  "back regardless.\n")
        out.write("collect = %s\n" % " ".join(collect))
        out.write("\n# Leads every collected file's name, so several runs "
                  "can share a directory.\n")
        out.write("tag = %s\n" % tag)
        out.write("\n# The working directory on each host. `tx clean` "
                  "deletes exactly this.\n")
        out.write("remote_dir = %s\n" % remote_dir)
        out.write("\n[hosts]\n")
        out.write("# name = address. The name is what reports and collected "
                  "filenames use.\n")
        for tok in tokens:
            name, addr = parse_token(tok)
            out.write("%s = %s\n" % (name, addr))
    finally:
        if out is not sys.stdout:
            out.close()


def slice_plan(plan, hosts):
    """The same job, over some of the fleet.

    Coverage mode is built out of this: a wave is an ordinary run over a
    smaller plan, so every command it uses -- start, collect, clean --
    is the one already tested against a whole fleet, not a second code
    path that only waves take.
    """
    return Plan(plan.path, list(hosts),
                dict((h, plan.addrs[h]) for h in hosts),
                plan.run, plan.setup, plan.teardown, plan.payload,
                plan.timeout, plan.collect, plan.tag, plan.remote_dir,
                plan.stdin)


def read_server_list(path):
    if not os.path.isfile(path):
        die("server list not found: %s" % path)
    tokens = []
    with open(path) as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            # `reachable`'s output is "host  OK  1.2ms"; take the first
            # field so its output can be piped straight in.
            tokens.append(line.split()[0])
    if not tokens:
        die("%s: no hosts in it" % path)
    return tokens


# ---------------------------------------------------------------------------
# The fleet
# ---------------------------------------------------------------------------

class Fleet(object):
    def __init__(self, plan, args):
        self.plan = plan
        self.user = args.user
        if (self.user or "").startswith("-"):
            die("--user %r starts with '-', which ssh would read as an "
                "option" % self.user)
        self.jobs = max(1, args.jobs)
        self.dir = getattr(args, "remote_dir", "") or plan.remote_dir
        self.python = args.python
        self.ssh = (args.ssh or "ssh").split()
        self.scp = (args.scp or "scp").split()
        self.dry_run = getattr(args, "dry_run", False)
        # --allow-shared-remote-dir: a group-writable --remote-dir is let
        # through (TX-002); every other check of `_dir_guard` still holds.
        self.shared = bool(getattr(args, "allow_shared_remote_dir", False))

    def target(self, host):
        addr = self.plan.addrs[host]
        return "%s@%s" % (self.user, addr) if self.user else addr

    def rpath(self, name):
        return "%s/%s" % (self.dir, name)

    def sh(self, host, script, timeout=120):
        """Run a shell snippet on one host. Returns (rc, output)."""
        cmd = self.ssh + SSH_OPTS + [self.target(host), script]
        return self._run(cmd, timeout)

    def push(self, host, local_paths, remote_name=None, timeout=900):
        dest = "%s:%s" % (self.target(host), self.rpath(remote_name or ""))
        cmd = self.scp + SSH_OPTS + ["-q"] + list(local_paths) + [dest]
        return self._run(cmd, timeout)

    def pull(self, host, remote_name, local_path, timeout=900):
        src = "%s:%s" % (self.target(host), self.rpath(remote_name))
        cmd = self.scp + SSH_OPTS + ["-q", src, local_path]
        return self._run(cmd, timeout)

    def stream(self, host, script, timeout=900):
        """Run a snippet and hand back its raw stdout as bytes.

        Collection uses this: a tar stream is bytes, and decoding it as
        text on the way past would corrupt every binary a job produced.
        """
        if self.dry_run:
            return 0, b"", "DRY-RUN"
        cmd = self.ssh + SSH_OPTS + [self.target(host), script]
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE,
                                 stdin=subprocess.DEVNULL)
            out, err = p.communicate(timeout=timeout)
            return p.returncode, out or b"", (err or b"").decode(
                "utf-8", "replace").strip()
        except subprocess.TimeoutExpired:
            p.kill()
            p.communicate()
            return 124, b"", "timed out after %ss" % timeout
        except OSError as exc:
            return 127, b"", str(exc)

    def _run(self, cmd, timeout):
        if self.dry_run:
            return 0, "DRY-RUN %s" % " ".join(shlex.quote(c) for c in cmd)
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT,
                                 stdin=subprocess.DEVNULL,
                                 universal_newlines=True)
            out, _ = p.communicate(timeout=timeout)
            return p.returncode, (out or "").strip()
        except subprocess.TimeoutExpired:
            p.kill()
            p.communicate()
            return 124, "timed out after %ss" % timeout
        except OSError as exc:
            return 127, str(exc)

    def each(self, fn, label=None, quiet=False, hosts=None):
        """Run fn(host) on every host, at most --jobs at a time.

        fn returns (rc, text). Output is printed host-prefixed in plan
        order rather than completion order, so two runs are diffable.
        Returns the number of failures.
        """
        hosts = list(hosts) if hosts is not None else self.plan.hosts
        if label:
            log("[tx] %s on %d hosts" % (label, len(hosts)))
        with ThreadPoolExecutor(max_workers=self.jobs) as pool:
            results = list(pool.map(fn, hosts))
        return self.report(hosts, dict(zip(hosts, results)), quiet)

    def report(self, hosts, results, quiet=False):
        """Print one host per line, in plan order, and count the failures.

        Separate from each() so a command can read what the fleet said
        *and* print it the usual way, without asking twice.
        """
        width = max(len(h) for h in hosts)
        failed = []
        for host in hosts:
            rc, text = results[host]
            if rc != 0:
                failed.append(host)
            if quiet and rc == 0:
                continue
            for line in (text or "").splitlines() or [""]:
                log("  %-*s  %s" % (width, host, line))
        if failed:
            log("[tx] FAILED on %d/%d hosts: %s"
                % (len(failed), len(hosts), " ".join(failed)))
        return len(failed)

    def gather(self, fn, hosts=None):
        """each(), without printing: returns {host: (rc, text)}."""
        hosts = list(hosts) if hosts is not None else self.plan.hosts
        with ThreadPoolExecutor(max_workers=self.jobs) as pool:
            results = list(pool.map(fn, hosts))
        return dict(zip(hosts, results))


def _agent_source():
    """This file, resolved through any symlink -- it is what gets copied
    to the hosts, so the fleet always runs exactly this version."""
    return os.path.realpath(os.path.abspath(__file__))


# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------

def measure_skew(fleet, hosts=None):
    """Each host's clock offset from this machine, in seconds.

    Asking a host what time it is over ssh costs a round trip, so the
    answer is already stale when it arrives. Halving the measured round
    trip is the standard correction and is good to a few milliseconds --
    far tighter than the skew that actually breaks a synchronised start,
    which is whole seconds of untended clock drift.

    Returns {host: (offset, rtt, error)}; offset is None if the host
    could not be asked.
    """
    def one(host):
        t0 = time.time()
        rc, out = fleet.sh(host, "date +%s.%N", timeout=30)
        t1 = time.time()
        if rc != 0:
            return None, t1 - t0, out or "could not read the clock"
        try:
            remote = float(out.strip().split()[0])
        except (ValueError, IndexError):
            return None, t1 - t0, "unreadable clock: %r" % out[:40]
        # The reading was taken somewhere inside [t0, t1]; the midpoint is
        # the best single guess, and the interval's width is the error bar.
        return remote - (t0 + t1) / 2.0, t1 - t0, ""

    return fleet.gather(one, hosts)


def arm_delay(nhosts, floor):
    """How far ahead to arm the start.

    Every host must be contacted and its agent launched *before* the
    instant arrives, or that host misses it and starts late. The fan-out
    is bounded by --jobs, so the cost grows with the number of waves, not
    with the fleet; a flat second per wave plus the floor has been enough,
    and --start-in raises it when a slow fleet needs more.
    """
    return max(floor, floor + 0.5 * (nhosts / 32.0))


# ---------------------------------------------------------------------------
# The agent: what runs on each host
# ---------------------------------------------------------------------------

def _write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(obj, fh, sort_keys=True, indent=1)
        fh.write("\n")
    os.replace(tmp, path)


# How much of a job's stderr is carried back inside the record. Enough to
# say what went wrong, not so much that a chatty job turns every host's
# record into a log file -- the whole stderr is collected regardless.
TAIL_BYTES = 2000
TAIL_LINES = 5


def _tail_text(path, nbytes=TAIL_BYTES, nlines=TAIL_LINES):
    """The last few lines of a file, for putting in the record.

    Read from the end rather than whole: a job that wrote a gigabyte of
    warnings should not be loaded into memory to find out it failed on
    the last line.
    """
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > nbytes:
                fh.seek(size - nbytes)
            blob = fh.read()
    except (OSError, IOError):
        return ""
    text = blob.decode("utf-8", "replace")
    lines = [ln for ln in text.splitlines() if ln.strip()]
    return "\n".join(lines[-nlines:])


def _open_stdin(name, workdir):
    """What the job reads on stdin. Returns (file-or-DEVNULL, error).

    A job given nothing reads /dev/null, which is what makes a command
    that waits on input fail at once instead of hanging until the
    timeout. A job given a file reads that -- it travels in the payload
    like everything else the job needs, so the name is relative to the
    working directory.
    """
    if not name:
        return subprocess.DEVNULL, ""
    path = os.path.join(workdir, name)
    if not os.path.isfile(path):
        return None, ("stdin file %r is not on this host -- ship it in the "
                      "payload, or drop stdin= from the plan" % name)
    try:
        return open(path, "rb"), ""
    except (OSError, IOError) as exc:
        return None, "cannot read stdin file %r: %s" % (name, exc)


def _run_phase(command, cwd, env, logpath, timeout):
    """Run one phase (setup/teardown) and record what it said.

    Both phases are bookkeeping around the job rather than the
    measurement, so their output goes to one file each and only their
    exit status reaches the report.
    """
    with open(logpath, "wb") as fh:
        p = subprocess.Popen(["bash", "-c", command], cwd=cwd, env=env,
                             stdout=fh, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL,
                             start_new_session=True)
        _RUNNING.append(p)
        try:
            p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_group(p)
            p.communicate()
            return 124
        finally:
            _RUNNING.remove(p)
    return p.returncode


# How long a phase that hit its timeout is given to go after SIGTERM,
# before SIGKILL.
KILL_GRACE = 5.0


def _kill_group(p):
    """Kill the process *group*, not just the child.

    A benchmark is almost always a shell script that starts other things.
    Killing bash alone leaves its children running, holding the machine
    and the files we are about to collect -- so the agent gives each
    phase a session of its own and takes the whole group down.
    """
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
    except OSError:
        try:
            p.terminate()
        except OSError:
            pass
    deadline = time.time() + KILL_GRACE
    while time.time() < deadline:
        if p.poll() is not None:
            return
        time.sleep(0.1)
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    except OSError:
        try:
            p.kill()
        except OSError:
            pass


# The phase currently running, so a SIGTERM arriving from `tx stop` can
# be carried down to it.
_RUNNING = []


def _forward_term(_signum, _frame):
    """Take the job down with us.

    `tx stop` kills the agent. The job is deliberately in a session of
    its own -- that is what lets the agent kill a benchmark's whole tree
    of children rather than just the shell at the top of it -- and the
    price of that separation is that killing the agent does not reach it.
    So the agent forwards the signal itself, and only then goes.
    """
    for p in list(_RUNNING):
        _kill_group(p)
    sys.exit(143)


def _entries(workdir):
    """The working directory's top-level names, as bytes: a name a job
    made need not be text in any encoding, and it is compared and written
    back exactly as the filesystem has it."""
    try:
        return set(os.listdir(os.fsencode(workdir)))
    except OSError:
        return set()


def _note_created(workdir, before):
    """Add what this run left in the working directory to the record.

    `tx clean` deletes tx's own files and what the record names, and
    refuses when anything else is there. A job's own files are tx's to
    remove -- a build in setup, a `collect = *.csv` the job writes beside
    itself -- but only the agent can tell them from a stranger's: it
    knows what was there before it began. So what is new since then is
    written down here, as the run ends, however it ends (finished, timed
    out, or stopped by `tx stop`, whose SIGTERM unwinds through this).

    A name with a newline in it cannot be one line of the record, so it
    is left out and `clean` will name it rather than delete it.
    """
    try:
        own = set(os.fsencode(n) for n in _own_names())
        new = sorted(n for n in _entries(workdir) - before - own
                     if b"\n" not in n)
        if not new:
            return
        path = os.path.join(os.fsencode(workdir), os.fsencode(MANIFEST_NAME))
        try:
            with open(path, "rb") as fh:
                had = fh.read()
        except (IOError, OSError):
            had = b""
        known = set(had.split(b"\n"))
        add = [n for n in new if n not in known]
        if not add:
            return
        lead = b"\n" if had and not had.endswith(b"\n") else b""
        with open(path, "ab") as fh:
            fh.write(lead + b"".join(n + b"\n" for n in add))
    except (IOError, OSError) as exc:
        sys.stderr.write("tx agent: could not record what the run made "
                         "(%s); tx clean will name it instead\n" % exc)


def cmd_agent(args):
    """Run the job here, at the armed instant, and write down what happened.

    This is the half of tx that lives on the servers. It is the same file
    -- copied there by `tx start` -- so there is never a version of the
    agent that is not the version of the orchestrator that deployed it.
    """
    signal.signal(signal.SIGTERM, _forward_term)
    signal.signal(signal.SIGINT, _forward_term)
    workdir = os.getcwd()
    before = _entries(workdir)
    try:
        return _run_agent(args, workdir)
    finally:
        _note_created(workdir, before)


def _run_agent(args, workdir):
    """cmd_agent's work, inside the bracket that records what it made."""
    outdir = os.path.join(workdir, OUT_NAME)
    try:
        os.makedirs(outdir)
    except OSError as exc:
        if exc.errno != errno.EEXIST:
            raise

    run_cmd = unb64(args.run)
    setup_cmd = unb64(args.setup) if args.setup else ""
    teardown_cmd = unb64(args.teardown) if args.teardown else ""

    # The sweep this run is part of, if any. It comes in the environment
    # rather than as a flag: `tx start --no-deploy` runs whatever agent is
    # already on the host, and one an older tx put there would refuse an
    # unknown flag and die on startup. That agent just ignores this, and
    # its record then carries no sweep id -- which --resume reads, rightly,
    # as not this sweep's.
    sweep_id = os.environ.get("TX_SWEEP_ID", "")

    env = os.environ.copy()
    env["TX_HOST"] = args.host
    env["TX_OUT"] = outdir
    env["TX_TAG"] = args.tag
    env["TX_RUN_ID"] = args.run_id
    if sweep_id:
        env["TX_SWEEP_ID"] = sweep_id
    else:
        env.pop("TX_SWEEP_ID", None)
    env["TX_INDEX"] = str(args.index)
    env["TX_NHOSTS"] = str(args.nhosts)
    if args.peers:
        env["TX_HOSTS"] = unb64(args.peers)

    report = {
        "host": args.host,
        "tag": args.tag,
        "run_id": args.run_id,
        "sweep_id": sweep_id or None,
        "command": run_cmd,
        "armed_for": args.at,
        "index": args.index,
        "nhosts": args.nhosts,
        "agent_version": VERSION,
        "uname": " ".join(os.uname()),
        "setup_exit": None,
        "teardown_exit": None,
        "stderr_tail": "",
        "detail": "",
        "started_at": None,
        "finished_at": None,
        "duration": None,
        "exit": None,
        "timed_out": False,
        "state": "setup",
    }
    _write_json(REPORT_NAME, report)

    # Setup runs immediately, not at the armed instant: it is preparation,
    # and a build or a package install would otherwise eat the very
    # synchronisation it was scheduled around.
    if setup_cmd:
        rc = _run_phase(setup_cmd, workdir, env, SETUP_LOG,
                        max(1.0, args.at - time.time() + args.timeout))
        report["setup_exit"] = rc
        if rc != 0:
            report["state"] = "setup-failed"
            _write_json(REPORT_NAME, report)
            sys.stderr.write("tx agent: setup failed (exit %d); the job was "
                             "not run\n" % rc)
            return 1
        _write_json(REPORT_NAME, report)

    # Wait for the instant. Sleeping the whole delta in one call would
    # ignore a clock the system steps while we wait, so re-read it.
    report["state"] = "armed"
    _write_json(REPORT_NAME, report)
    while True:
        remaining = args.at - time.time()
        if remaining <= 0:
            break
        time.sleep(min(remaining, 0.25))

    started = time.time()
    report["started_at"] = started
    report["state"] = "running"
    _write_json(REPORT_NAME, report)
    # How far off the armed instant this host actually was. It is the
    # measurement that makes "at the same time" checkable rather than
    # claimed, so it is recorded even when it is tiny.
    report["start_offset"] = started - args.at

    # What the job reads. /dev/null unless the plan named a file, so a
    # command that waits on input finds EOF rather than hanging until the
    # timeout and reporting nothing.
    fin, stdin_err = _open_stdin(args.stdin, workdir)
    if stdin_err:
        report["state"] = "launch-failed"
        report["detail"] = stdin_err
        _write_json(REPORT_NAME, report)
        with open(STDERR_NAME, "ab") as fh:
            fh.write(("tx agent: %s\n" % stdin_err).encode("utf-8"))
        sys.stderr.write("tx agent: %s\n" % stdin_err)
        return 1

    fout = open(STDOUT_NAME, "wb")
    ferr = open(STDERR_NAME, "wb")
    try:
        try:
            p = subprocess.Popen(["bash", "-c", run_cmd], cwd=workdir,
                                 env=env, stdout=fout, stderr=ferr,
                                 stdin=fin, start_new_session=True)
        except OSError as exc:
            # The job never started -- no bash, a working directory that
            # went away. Letting this escape left the record saying
            # "running" for a host that was doing nothing at all, and put
            # the only explanation in the agent's log where `tx collect`
            # could not see it. It is a result, so it is recorded as one.
            report["state"] = "launch-failed"
            report["detail"] = str(exc)
            report["finished_at"] = time.time()
            report["duration"] = report["finished_at"] - started
            _write_json(REPORT_NAME, report)
            ferr.write(("tx agent: the job would not start: %s\n"
                        % exc).encode("utf-8"))
            ferr.flush()
            report["stderr_tail"] = _tail_text(STDERR_NAME)
            _write_json(REPORT_NAME, report)
            return 1
        _RUNNING.append(p)
        try:
            p.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            report["timed_out"] = True
            _kill_group(p)
            p.communicate()
        finally:
            _RUNNING.remove(p)
        rc = p.returncode
    finally:
        fout.close()
        ferr.close()
        if fin not in (None, subprocess.DEVNULL):
            fin.close()

    report["finished_at"] = time.time()
    report["duration"] = report["finished_at"] - started
    report["exit"] = rc
    # The last of the job's stderr, carried in the record so `tx status`
    # and `tx summarize` can say *why* a host failed without anybody
    # having to collect the run and go looking. The file still comes back
    # whole; this is the part you read first.
    report["stderr_tail"] = _tail_text(STDERR_NAME)

    # Teardown runs whether the job passed, failed or was killed: leaving
    # a host as it was found is not conditional on the run going well.
    #
    # The host is not *finished* until it has been put back, and saying
    # so before then is not a wording problem: `tx run` collects the
    # moment a host reports finished, so a teardown still writing into
    # $TX_OUT would have its output collected halfway or not at all.
    # Hence a state of its own while it runs.
    if teardown_cmd:
        report["state"] = "tidying"
        _write_json(REPORT_NAME, report)
        report["teardown_exit"] = _run_phase(
            teardown_cmd, workdir, env, TEARDOWN_LOG, args.timeout)

    report["state"] = "timeout" if report["timed_out"] else "done"
    _write_json(REPORT_NAME, report)

    return 0 if rc == 0 and not report["timed_out"] else 1


# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

def _pack_payload(payload):
    """The payload as one gzipped tar, in a temp file.

    One transfer rather than `scp -r`: a recursive scp opens a channel
    per file, which on a payload of a thousand small files is a thousand
    round trips, and it silently follows symlinks out of the tree.
    """
    names = _payload_names(payload)
    fd, path = tempfile.mkstemp(prefix="tx-payload-", suffix=".tar.gz")
    os.close(fd)
    tf = tarfile.open(path, "w:gz")
    try:
        if os.path.isdir(payload):
            for name in names:
                tf.add(os.path.join(payload, name), arcname=name)
        else:
            tf.add(payload, arcname=names[0])
    finally:
        tf.close()
    return path


def _payload_names(payload):
    """The top-level names the payload unpacks to on each host.

    The deploy records the ones it creates, so `tx clean` knows them for
    tx's. MANIFEST_NAME is where that record is kept, so a payload that
    brings its own would overwrite it -- refused here, before anything
    travels.
    """
    if not os.path.exists(payload):
        die("payload not found: %s" % payload)
    if os.path.isdir(payload):
        names = sorted(os.listdir(payload))
    else:
        names = [os.path.basename(payload)]
    if MANIFEST_NAME in names:
        die("the payload has its own %s, a name tx keeps for its record of "
            "what it put on each host; rename it" % MANIFEST_NAME)
    return names


def _dir_path(rdir):
    """--remote-dir with any trailing slash dropped: `link/` names the
    directory a symlink points to, and it is the link that is checked."""
    return rdir.rstrip("/") or rdir


def _dir_guard(fleet, create=False, to_stderr=False):
    """Shell that refuses this host's --remote-dir unless it is safe to use
    (`DIR_CHECK_FN`), printing one REFUSED line naming the directory, its
    owner, its mode and the ssh user's uid, and exiting 1 so nothing after
    it runs. With `create`, a directory that does not exist yet is made
    first, mode 700 (any missing parents get the login shell's umask).
    `to_stderr` is for a snippet whose stdout is data -- collect's tar."""
    d = shlex.quote(_dir_path(fleet.dir))
    s = DIR_CHECK_FN + "_tx_shared=%s\n" % ("1" if fleet.shared else "0")
    out = " >&2" if to_stderr else ""
    if create:
        s += ("if [ ! -e %s ] && [ ! -L %s ]; then\n"
              "    mkdir -p -m 700 -- %s || { echo 'could not create "
              "--remote-dir' %s%s; exit 1; }\n"
              "fi\n" % (d, d, d, d, out))
    s += ("_tx_dir_check %s || { echo \"REFUSED: --remote-dir $_tx_bad. "
          "%s\"%s; exit 1; }\n" % (d, REFUSED_HOW, out))
    return s


def _refused(text):
    """The REFUSED line out of a host's reply, or "" if it is not one."""
    for line in (text or "").splitlines():
        if line.startswith("REFUSED: "):
            return line
    return ""


def _stage_name():
    """A staging directory name no other deploy will pick."""
    return STAGE_PREFIX + "%d.%s" % (os.getpid(), os.urandom(4).hex())


def _deploy_script(rdir, stage, agent, names=None):
    """The second half of a deploy, once the files are in `stage`: refuse
    a directory this run's agent is still running in, clear the last run's
    outputs, rename the agent over its real name, record what the payload
    is about to create, and unpack it straight out of the stage.
    `_dir_guard` goes in front of it.

    `names` is the payload's top-level names (None: no payload). Each one
    not already there is written into the record, because this unpack is
    what makes it -- and only those: a name that was there before, and
    that the record does not already hold, is somebody else's, and stays
    theirs however the unpack changes it, so `tx clean` names it rather
    than deleting it.
    """
    # The unpack is formatted once, on its own, and then passed as a
    # *value* to the call below -- so its braces are doubled for its own
    # format call and for no other. Doubling them again would leave a
    # literal `{{` in the shell, which bash reads as a command named `{{`,
    # making the `exit 1` after it unconditional.
    unpack = ""
    if names is not None:
        # A name with a newline cannot be a line of the record; it is
        # left out, and `tx clean` names it rather than deleting it.
        quoted = [shlex.quote(n) for n in names if "\n" not in n]
        record = ""
        if quoted:
            record = """
for n in %s; do
    [ -e "$n" ] || [ -L "$n" ] || printf '%%s\\n' "$n" >> %s
done""" % (" ".join(quoted), MANIFEST_NAME)
        unpack = """{record}
tar xzf "$s"/{payload} || {{ rm -rf -- "$s"; echo 'payload would not unpack'; exit 1; }}
""".format(record=record, payload=PAYLOAD_NAME)
    return """
d={d}
s={stage}
cd "$d" || exit 1
here=$(pwd -P)
{probe}
if [ -f {pid} ] && tx_ours "$(cat {pid} 2>/dev/null)"; then
    rm -rf -- "$s"
    echo 'a job is already running here -- tx stop first'; exit 1
fi
# payload.tar.gz too: an older tx unpacked from that fixed name, and one
# cut short could have left it (or a symlink at it) behind.
rm -rf {out} {report} {stdout} {stderr} {setuplog} {teardownlog} {log} {pid} {payload}
# Whatever stands at the agent's name goes first, then the staged copy is
# renamed onto it: a symlink there is replaced, never written through, and
# a directory there makes the rm fail rather than the mv move into it.
rm -f -- {agent} && mv -f -- "$s"/{agent} {agent} || {{
    rm -rf -- "$s"; echo 'could not put the agent in place'; exit 1; }}
{unpack}
rm -rf -- "$s"
echo deployed
""".format(d=shlex.quote(_dir_path(rdir)), stage=shlex.quote(stage),
           agent=shlex.quote(agent), pid=PID_NAME, out=OUT_NAME,
           report=REPORT_NAME, stdout=STDOUT_NAME, stderr=STDERR_NAME,
           setuplog=SETUP_LOG, teardownlog=TEARDOWN_LOG, log=LOG_NAME,
           unpack=unpack, probe=_probe(), payload=PAYLOAD_NAME)


def _deploy(fleet, host, tarball, names=None):
    """Copy the agent (and the packed payload) to one host, through a
    private staging directory, and unpack it. Returns (rc, text).
    `names` is the payload's top-level names, for the record
    (`_deploy_script`); None when there is no payload.

    Three round trips, each checking --remote-dir first: make and check
    the directory and make the stage; scp into the stage (scp writes
    before any shell runs, so it cannot check anything itself); then
    check again and rename into place."""
    stage = _stage_name()
    agent = _agent_name()
    d = shlex.quote(_dir_path(fleet.dir))
    rc, out = fleet.sh(host, _dir_guard(fleet, create=True)
                       + "cd %s && mkdir -m 700 -- %s\n" % (d, stage))
    if rc != 0:
        return rc, out if _refused(out) else "mkdir failed: %s" % out

    def drop_stage():
        fleet.sh(host, _dir_guard(fleet) + "cd %s && rm -rf -- %s\n"
                 % (d, stage))

    rc, out = fleet.push(host, [_agent_source()], stage + "/")
    if rc != 0:
        drop_stage()
        return rc, "copy failed: %s" % out
    if tarball:
        # scp lands a file under its own basename, and the deploy script
        # unpacks one fixed name.
        rc, out = fleet.push(host, [tarball], stage + "/" + PAYLOAD_NAME)
        if rc != 0:
            drop_stage()
            return rc, "payload copy failed: %s" % out
    # A refusal here means the directory changed under the copy, and it is
    # not tx's to tidy any more: the stage is left where it is.
    return fleet.sh(host, _dir_guard(fleet)
                    + _deploy_script(fleet.dir, stage, agent, names))


def _start_script(fleet, plan, args, host, at, index, run_id):
    agent = _agent_name()
    flags = [
        "agent",
        "--host", host,
        "--at", "%.3f" % at,
        "--timeout", "%g" % plan.timeout,
        "--tag", plan.tag,
        "--run-id", run_id,
        "--index", str(index),
        "--nhosts", str(len(plan.hosts)),
        "--run", b64(plan.run),
    ]
    if plan.setup:
        flags += ["--setup", b64(plan.setup)]
    if plan.teardown:
        flags += ["--teardown", b64(plan.teardown)]
    if plan.stdin:
        flags += ["--stdin", plan.stdin]
    if args.peers:
        flags += ["--peers", b64(" ".join(plan.hosts))]

    # The agent is backgrounded as a *simple* command with all three
    # descriptors redirected: $! is then the agent's own pid, and nothing
    # is left holding ssh's channel open -- background an `A && B` list
    # instead and ssh hangs until the agent exits.
    #
    # -I (isolated mode, 3.4+) keeps the payload out of the agent. tx.py
    # sits in the directory the payload unpacks into, and a plain
    # `python3 tx.py` puts that directory first on sys.path, so a job that
    # shipped its own json.py or queue.py had the agent import it and die
    # on startup on every host. -I leaves the script's directory off the
    # path and ignores PYTHON* variables, for this interpreter only:
    # os.environ is untouched, so the job, which the agent starts in that
    # same directory with that environment, sees exactly what it did.
    #
    # TX_SWEEP_ID is set on every launch, empty outside a --batch sweep,
    # so a value left in the ssh user's environment cannot pass this run
    # off as some sweep's (the agent reads it: `_run_agent`).
    launch = ("TX_SWEEP_ID=%s nohup %s -I %s %s < /dev/null >> %s 2>&1 &"
              % (shlex.quote(getattr(args, "sweep_id", "") or ""),
                 shlex.quote(fleet.python), shlex.quote(agent),
                 " ".join(shlex.quote(f) for f in flags), LOG_NAME))
    # The directory is checked again first, in this same ssh: what runs is
    # what is in it now, not what the deploy saw a round trip ago. The pid
    # file is written to a private name and renamed into place, so a
    # symlink at agent.pid is replaced, never written through.
    return _dir_guard(fleet) + """
d={d}
cd "$d" 2>/dev/null || {{ echo 'not deployed (run tx start without --no-deploy)'; exit 1; }}
here=$(pwd -P)
{probe}
if [ -f {pid} ] && tx_ours "$(cat {pid} 2>/dev/null)"; then
    echo 'already running -- tx stop first'; exit 1
fi
# An earlier run's outputs must not answer for this one. With --no-deploy
# nothing else removes them: its record made an agent that died on
# startup read as 'ran already' -- and its old exit 0 as this run passing
# -- and its out/ and logs came back in this run's collection, as if this
# run had written them. The deploy removes the same names; a start does
# too, so the two cannot drift apart.
rm -rf {out} {report} {stdout} {stderr} {setuplog} {teardownlog} {log}
{launch}
agent_pid=$!
t={stage}pid.$$
rm -f -- "$t" {pid}
echo "$agent_pid" > "$t" && mv -f -- "$t" {pid}
sleep 0.3
if kill -0 "$agent_pid" 2>/dev/null; then
    echo armed
elif [ -f {report} ]; then
    # Gone already, but it left a record: a job short enough to finish
    # inside this check has run, not crashed. Reading the absence of a
    # process as a failure would fail every fast job.
    echo 'ran already'
else
    echo 'the agent died on startup:'
    tail -n 5 {log} 2>/dev/null
    rm -f {pid}
    exit 1
fi
""".format(d=shlex.quote(_dir_path(fleet.dir)), pid=PID_NAME, launch=launch,
           log=LOG_NAME, report=REPORT_NAME, stage=STAGE_PREFIX,
           out=OUT_NAME, stdout=STDOUT_NAME, stderr=STDERR_NAME,
           setuplog=SETUP_LOG, teardownlog=TEARDOWN_LOG, probe=_probe())


def _kill_block(rdir):
    """Shell that stops this run's agent and leaves $status set. Falls
    through in every case -- `clean` appends the removal to it, so it must
    never exit early. $refused is set, and nothing is touched, when the
    host cannot say which agent is this run's.

    Only this run's agent: a pid is signalled, waited on and killed only
    once `tx_ours` says it is a `tx.py agent` working in this --remote-dir
    (AGENT_PROBE). The pid file is the primary handle; with it gone, or
    naming somebody else, /proc is searched for an agent working here.
    Never `pkill -f`: that is every run's agent on the host, and another
    user's -- one `tx stop` used to take down a second run beside it.

    The agent forwards the TERM to the job's whole process group, which is
    what actually stops the job: the agent is a python process whose child
    is a shell whose children are the benchmark, and killing only the
    first of those leaves the machine still working. An agent that will
    not go is KILLed, and so are its children's groups, read before it
    dies.
    """
    return """
d={d}
status=not-deployed
refused=""
here=""
{probe}
if [ -d "$d" ]; then
    status=not-running
    here=$(CDPATH= cd -- "$d" 2>/dev/null && pwd -P)
    pid=""
    [ -f "$d/{pid}" ] && pid=$(cat "$d/{pid}" 2>/dev/null)
    targets=""
    if tx_ours "$pid"; then
        targets=$pid
    elif [ "$have_proc" = yes ]; then
        tx_scan
        targets=$tx_found
    elif [ ! -f "$d/{pid}" ]; then
        # No pid file and no /proc: nothing here can say which agent is
        # this run's, so nothing is killed. Only a host where an agent of
        # this user is running (or might be) is refused; with none at
        # all there is nothing to stop.
        mine=$({pgrep} 2>/dev/null)
        found=$?
        if [ "$found" -eq 0 ]; then
            refused="REFUSED: $d has no {pid} and this host has no /proc, so tx cannot tell whether a tx agent of yours (pid $(echo $mine)) is this run's -- nothing was stopped; kill it by hand"
        elif [ "$found" -ne 1 ]; then
            refused="REFUSED: $d has no {pid}, and this host has no /proc and no pgrep, so tx cannot tell whether this run's agent is still running -- nothing was stopped; check by hand"
        fi
    fi
    if [ -n "$targets" ]; then
        for p in $targets; do
            kill -TERM -"$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
        done
        status=stopped
        i=0
        while :; do
            left=""
            for p in $targets; do tx_ours "$p" && left="$left $p"; done
            [ -z "$left" ] && break
            [ "$i" -ge 20 ] && break
            sleep 0.5
            i=$((i+1))
        done
        if [ -n "$left" ]; then
            for p in $left; do
                tx_kids "$p"
                kill -KILL "$p" 2>/dev/null
                for c in $tx_kids; do
                    case "$c" in ''|*[!0-9]*|0|1) continue ;; esac
                    kill -KILL -"$c" 2>/dev/null || kill -KILL "$c" 2>/dev/null
                done
            done
            status=killed
        fi
    fi
    [ -n "$refused" ] || rm -f "$d/{pid}"
fi
""".format(d=shlex.quote(_dir_path(rdir)), pid=PID_NAME, pgrep=PGREP_MINE,
           probe=_probe())


# What `stop` (and the stand-down after a failed arming) says after the
# kill block: the host's status, or why it was left alone.
STOP_TAIL = """
if [ -n "$refused" ]; then echo "$refused"; exit 1; fi
echo "$status"
"""


def _run_id():
    return time.strftime("%Y%m%d-%H%M%S")


def cmd_start(args, plan=None):
    plan = plan or load_plan(args.plan)
    fleet = Fleet(plan, args)

    if not args.no_deploy:
        tarball = None
        try:
            names = None
            if plan.payload:
                names = _payload_names(plan.payload)
                tarball = _pack_payload(plan.payload)
                log("[tx] payload %s -> %s packed"
                    % (plan.payload, fmt_bytes(os.path.getsize(tarball))))
            def deploy(host):
                return _deploy(fleet, host, tarball, names)

            if fleet.each(deploy, "deploying the job", quiet=True):
                return 1
        except KeyboardInterrupt:
            raise _interrupted_arming(args, fleet, [])
        finally:
            if tarball:
                os.unlink(tarball)

    if not args.no_skew_check and not fleet.dry_run:
        try:
            rc = _report_skew(fleet, args)
        except KeyboardInterrupt:
            raise _interrupted_arming(args, fleet, [])
        if rc:
            return rc

    delay = arm_delay(len(plan.hosts), args.start_in)
    at = time.time() + delay
    run_id = _run_id()
    log("[tx] arming %d hosts for a start %s from now (%s)"
        % (len(plan.hosts), fmt_secs(delay),
           time.strftime("%H:%M:%S", time.localtime(at))))

    index = dict((h, i) for i, h in enumerate(plan.hosts))
    begun = []          # every host whose arming has started

    def start(host):
        begun.append(host)
        return fleet.sh(host, _start_script(fleet, plan, args, host, at,
                                            index[host], run_id))

    try:
        failed = fleet.each(start, "arming agents", quiet=True)
    except KeyboardInterrupt:
        raise _interrupted_arming(args, fleet,
                                  [h for h in plan.hosts if h in begun])
    if failed:
        log("[tx] some hosts were not armed; the run would not be "
            "simultaneous, so it was not started on the rest either")
        _stand_down(fleet, plan.hosts)
        return 1

    late = time.time() - at
    if late > 0:
        log("[tx] WARNING: arming took %s longer than the %s window, so the "
            "last hosts started late. Raise --start-in."
            % (fmt_secs(late), fmt_secs(delay)))
    log("[tx] running: %d hosts, %s, timeout %s"
        % (len(plan.hosts), plan.run, fmt_secs(plan.timeout)))
    log("[tx] next: tx status      # who is running, who has finished")
    log("[tx]       tx collect     # bring the results back")
    log("[tx]       tx clean       # when you are done")
    return 0


def _stand_down(fleet, hosts):
    """Stop this run's agent on `hosts`, with Ctrl-C held off until that
    is done. Returns the hosts it could not be stopped on.

    A stand-down abandoned halfway leaves the partly armed fleet it exists
    to prevent, so a Ctrl-C meanwhile is ignored rather than obeyed. (An
    ssh started now inherits the ignoring, so a Ctrl-C at the terminal
    does not cut its connection either.) Guarded like `tx stop`: a host
    refused at arming has nothing of this run's to stand down, and its
    pid file is not to be trusted.
    """
    script = _dir_guard(fleet) + _kill_block(fleet.dir) + STOP_TAIL
    held = signal.signal(signal.SIGINT, signal.SIG_IGN)
    try:
        log("[tx] standing the armed hosts back down on %d hosts" % len(hosts))
        results = fleet.gather(lambda h: fleet.sh(h, script), hosts)
    finally:
        signal.signal(signal.SIGINT, signal.default_int_handler
                      if held is None else held)
    fleet.report(hosts, results, quiet=True)
    return [h for h in hosts if results[h][0] != 0]


def _interrupted_arming(args, fleet, begun):
    """Ctrl-C before the start was armed everywhere: stand down every host
    it reached. Returns the Interrupted to raise.

    A fleet armed on some hosts and not the rest runs the job on those
    alone at the armed instant -- what a failed arming already refuses to
    leave behind. Interrupted, tx used to exit with them armed (TX-005).

    `begun` is every host whose arming had started, not only those that
    answered "armed": at a terminal, Ctrl-C reaches the ssh in flight too,
    and its host may have been armed before that ssh died without saying.
    """
    log("")
    if not begun:
        log("[tx] interrupted before any host was armed: nothing was started")
        return Interrupted()
    log("[tx] interrupted while arming, after reaching %d of %d host(s). A "
        "run armed on only some of them would not be simultaneous, so they "
        "are stood back down (Ctrl-C is ignored until that is done)"
        % (len(begun), len(fleet.plan.hosts)))
    left = _stand_down(fleet, begun)
    if left:
        log("[tx] %d host(s) could not be stood down, and may still run the "
            "job on their own: %s" % (len(left), _hosts_line(left)))
        _next_steps([("tx stop" + _fleet_flags(args), "stop it there")])
    else:
        log("[tx] stood back down: nothing of this start is running")
    return Interrupted(left)


def _report_skew(fleet, args):
    """Check the fleet's clocks, and refuse a start they cannot support."""
    skews = measure_skew(fleet)
    unreadable = [h for h in fleet.plan.hosts if skews[h][0] is None]
    if unreadable:
        for host in unreadable:
            log("[tx] %s: %s" % (host, skews[host][2]))
        log("[tx] a clock that cannot be read cannot be trusted to start a "
            "job at an agreed instant")
        return 1
    worst = max(abs(skews[h][0]) for h in fleet.plan.hosts)
    spread = (max(skews[h][0] for h in fleet.plan.hosts)
              - min(skews[h][0] for h in fleet.plan.hosts))
    if worst > args.max_skew:
        log("[tx] clocks disagree by up to %s (spread %s across the fleet), "
            "over the --max-skew of %s:"
            % (fmt_secs(worst), fmt_secs(spread), fmt_secs(args.max_skew)))
        for host in sorted(fleet.plan.hosts,
                           key=lambda h: -abs(skews[h][0]))[:8]:
            log("    %-16s %+.3fs" % (host, skews[host][0]))
        log("[tx] a synchronised start means nothing on a fleet whose clocks "
            "do not agree. Fix ntp/chrony (binnacle's `skew` diagnoses it), "
            "or pass --max-skew to accept it.")
        return 1
    log("[tx] clocks agree to within %s (spread %s)"
        % (fmt_secs(worst), fmt_secs(spread)))
    return 0


# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

# ALIVE is this run's agent only: a pid file naming a reused pid, or
# another run's agent beside this one, is not this host still working.
STATUS_SCRIPT_TMPL = """
d={d}
[ -d "$d" ] || {{ echo NOT-DEPLOYED; exit 0; }}
cd "$d"
here=$(pwd -P)
{probe}
alive=no
if [ -f {pid} ] && tx_ours "$(cat {pid} 2>/dev/null)"; then
    alive=yes
fi
if [ -f {report} ]; then
    echo "ALIVE=$alive"
    cat {report}
else
    [ "$alive" = yes ] && echo NOT-STARTED-YET || echo NOT-RUNNING
fi
"""


def _status_script(rdir):
    return STATUS_SCRIPT_TMPL.format(d=shlex.quote(_dir_path(rdir)),
                                     pid=PID_NAME, report=REPORT_NAME,
                                     probe=_probe())


def _parse_status(text):
    """(alive, report-or-None, plain-word-or-None) out of one host's reply."""
    text = (text or "").strip()
    if not text:
        return False, None, "NO-ANSWER"
    if not text.startswith("ALIVE="):
        return False, None, text.splitlines()[0].strip()
    head, _, rest = text.partition("\n")
    alive = head.strip() == "ALIVE=yes"
    try:
        return alive, json.loads(rest), None
    except ValueError:
        return alive, None, "UNREADABLE-REPORT"


def _state_line(alive, report, word):
    if word:
        return word
    state = report.get("state", "?")
    if state == "done" or state == "timeout":
        bits = "exit %s in %s" % (report.get("exit"),
                                  fmt_secs(report.get("duration")))
        if report.get("timed_out"):
            return "TIMEOUT   %s" % bits
        if report.get("exit") == 0:
            return "DONE      %s" % bits
        return "FAILED    %s" % bits
    if state == "setup-failed":
        return "SETUP-FAILED  exit %s" % report.get("setup_exit")
    if state == "launch-failed":
        return "NEVER RAN  %s" % (report.get("detail") or "the job would "
                                  "not start")
    if not alive:
        return "GONE      the agent is not running and left no result"
    if state == "tidying":
        return "TIDYING   exit %s, running the teardown" % report.get("exit")
    if state == "running":
        began = report.get("started_at")
        if began:
            return "RUNNING   %s so far" % fmt_secs(time.time() - began)
        return "RUNNING"
    if state == "armed":
        waiting = report.get("armed_for", 0) - time.time()
        if waiting > 0:
            return "ARMED     starts in %s" % fmt_secs(waiting)
        return "ARMED"
    return state.upper()


def _collect_status(fleet):
    script = _dir_guard(fleet) + _status_script(fleet.dir)
    results = fleet.gather(lambda h: fleet.sh(h, script, timeout=30))
    out = {}
    for host in fleet.plan.hosts:
        rc, text = results[host]
        if rc != 0:
            # A refused directory is not an unreachable host: the host
            # answered, and said why nothing there can be trusted.
            out[host] = (False, None, _refused(text) or "UNREACHABLE")
            continue
        out[host] = _parse_status(text)
    return out


# The states a run record is in while its agent is still at work.
UNFINISHED = ("armed", "running", "setup", "tidying")


def _has_result(entry):
    """Has this host already run the job and recorded how it went?

    Different from _is_finished, which also counts a host nothing is
    coming from -- not deployed, no agent, no record. That is "stop
    waiting"; this is "there is an answer here", which is what makes a
    sweep resumable without the orchestrator remembering anything.
    """
    _alive, report, _word = entry
    if report is None:
        return False
    return report.get("state") in FINISHED


def _still_working(entry):
    """Is this host busy with a job right now?

    The third answer resume needs. Agents are detached, so an
    interrupted sweep leaves its last wave still running: those hosts
    have no result yet, but starting them again would trample live work
    and throw away the run that is already most of the way done. They
    are waited for, not restarted.

    A record that says it is still working is believed only while its
    agent is alive. One that stopped mid-job -- a reboot, an OOM kill --
    leaves "running" in run.json for good; reading that as live work
    left the host out of every resumed sweep, waited on and never run.
    """
    alive, report, word = entry
    if report is not None:
        return alive and report.get("state") in UNFINISHED
    return alive or word == "NOT-STARTED-YET"


def _is_finished(entry):
    alive, report, word = entry
    if word in ("NOT-DEPLOYED", "NOT-RUNNING"):
        return True
    if report is None:
        return False
    if report.get("state") in FINISHED:
        return True
    # No result and no agent: nothing more is coming from this host.
    return not alive


# What a host with no run record can say and still not have failed: tx was
# never run there, or was deployed and never started, or its agent is up
# and about to write its record. Any other word -- UNREACHABLE, a REFUSED
# --remote-dir, NO-ANSWER, UNREADABLE-REPORT -- is a host tx cannot read.
STATUS_NOTHING_YET = ("NOT-DEPLOYED", "NOT-RUNNING", "NOT-STARTED-YET")


def _status_failed(entry):
    """Does this host's `tx status` line say something went wrong?

    The same reading as _state_line, line for line: FAILED, TIMEOUT,
    SETUP-FAILED, NEVER RAN and GONE, and a host that could not be read.
    A host still at work is not a failure, and nor is a pass.
    """
    alive, report, word = entry
    if report is None:
        return word not in STATUS_NOTHING_YET
    state = report.get("state")
    if state == "done" or state == "timeout":
        return bool(report.get("timed_out")) or report.get("exit") != 0
    if state in FINISHED:
        # setup-failed, launch-failed: the job never ran.
        return True
    # Still at work, unless nothing is left to do it: GONE.
    return not alive


def cmd_status(args):
    plan = load_plan(args.plan)
    fleet = Fleet(plan, args)
    failed = False
    while True:
        if args.watch:
            sys.stdout.write("\033[2J\033[H")
            log("tx status -- %s (every %gs, ctrl-c to stop)"
                % (time.strftime("%H:%M:%S"), args.watch))
        states = _collect_status(fleet)
        width = max(len(h) for h in plan.hosts)
        for host in plan.hosts:
            log("  %-*s  %s" % (width, host, _state_line(*states[host])))
        # Exit 1 as every other fleet command does when a host failed or
        # could not be read (TX-006): a script reads status's exit, not its
        # lines. Hosts still running are not a failure. A --dry-run asked
        # nobody, so it has nothing to fail on.
        failed = not fleet.dry_run and any(
            _status_failed(states[h]) for h in plan.hosts)
        if not args.watch:
            break
        try:
            time.sleep(args.watch)
        except KeyboardInterrupt:
            # --watch is stopped with Ctrl-C; what it exits with is what
            # the last look at the fleet found.
            break
    return 1 if failed else 0


POLL_FLOOR = 2.0
POLL_CEILING = 30.0


def poll_interval(waited, pinned=None):
    """How long to wait before asking the fleet again.

    Asking is not free and it is not neutral: every poll is an ssh
    connection per host, and those land on the very machines whose
    benchmark is being measured. A fixed two seconds costs sixty
    thousand connections over a ten-minute run on two hundred hosts --
    to learn nothing, most of them, while perturbing the thing under
    test.

    So the interval grows with how long we have already been waiting. A
    job that finishes in seconds is still noticed in seconds; one that
    has been running an hour is asked about twice a minute. Nobody needs
    two-second resolution on a benchmark that takes ten minutes.
    """
    if pinned:
        return pinned
    return min(max(POLL_FLOOR, waited / 10.0), POLL_CEILING)


def _wait_for_fleet(fleet, deadline, quiet=False, pinned=None, seen=None):
    """Poll until every host has finished, or the deadline passes.

    Each poll is a fresh short ssh per host, closed as soon as it has
    answered -- nothing is held between polls, and the agents do not
    care whether anybody is watching. Killing this loop loses the
    waiting, not the run.

    `seen`, a dict, is given each poll's answer as it comes ("states",
    and "at" when): what a Ctrl-C in the middle of the wait reports.
    """
    last = None
    began = time.time()
    while True:
        states = _collect_status(fleet)
        if seen is not None:
            seen["states"], seen["at"] = states, time.time()
        done = sum(1 for h in fleet.plan.hosts if _is_finished(states[h]))
        if not quiet and done != last:
            log("[tx] %d/%d hosts finished" % (done, len(fleet.plan.hosts)))
            last = done
        if done == len(fleet.plan.hosts):
            return states, True
        if time.time() > deadline:
            return states, False
        time.sleep(poll_interval(time.time() - began, pinned))


# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------

def default_dir(base=None):
    """A directory of this collection's own, stamped with the time.

    Collecting the same job twice an hour apart is the normal way to use
    this, and the second run quietly replacing the first is not a result
    anybody wants to find later. Two collections inside one second get
    -2, -3 rather than sharing.
    """
    if base:
        return base
    stamp = time.strftime("tx-%Y%m%d-%H%M%S")
    if not os.path.exists(stamp):
        return stamp
    for n in range(2, 100):
        cand = "%s-%d" % (stamp, n)
        if not os.path.exists(cand):
            return cand
    return "%s-%d" % (stamp, os.getpid())


# What a host says on stderr about a file it did not send. stdout is the
# tar, so the report of what was left behind travels beside it.
OVERSIZE_MARK = "tx-oversize"


def _collect_script(rdir, patterns, max_bytes):
    """A tar of everything worth bringing back, on stdout.

    One round trip per host, whole files, framed by tar itself. The file
    list is built on the far side because that is the only side that
    knows what the job produced -- and the size ceiling is applied there
    too, so an oversized file is never put on the wire at all. What was
    left behind is named on stderr, which the tar on stdout leaves free.
    """
    extra = " ".join(shlex.quote(p) for p in patterns)
    return """
d={d}
cd "$d" 2>/dev/null || {{ echo 'tx: not deployed' >&2; exit 1; }}
# Globbing is off while the patterns are still words, so an unmatched
# one stays literal and is skipped by the -e test below. The `:` closes
# the subshell with a success: every test in there is allowed to find
# nothing, and letting the last one decide the subshell's status once
# threw a whole host's collection away because one --collect glob
# matched no files.
set -f
list=$(
    for f in {always}; do [ -e "$f" ] && printf '%s\\n' "$f"; done
    [ -d {out} ] && find {out} -type f -print
    set +f
    for pat in {extra}; do
        for f in $pat; do [ -e "$f" ] && printf '%s\\n' "$f"; done
    done
    :
)
set +f
[ -n "$list" ] || {{ echo 'tx: nothing to collect' >&2; exit 3; }}
# The ceiling. `ls -ln` reads the inode, not the file, so measuring a
# four-gigabyte core dump costs nothing -- and refusing it here means it
# never crosses the network, which is the whole point of a ceiling.
max={max}
keep=""
if [ "$max" -gt 0 ]; then
    for f in $(printf '%s\\n' "$list" | sort -u); do
        sz=$(ls -ln "$f" 2>/dev/null | awk '{{print $5}}')
        [ -z "$sz" ] && sz=0
        if [ "$sz" -gt "$max" ]; then
            printf '{mark}\\t%s\\t%s\\n' "$f" "$sz" >&2
        else
            keep="$keep$f
"
        fi
    done
else
    keep=$(printf '%s\\n' "$list" | sort -u)
fi
[ -n "$keep" ] || exit 0
printf '%s\\n' "$keep" | sort -u | tar cf - -T - 2>/dev/null
""".format(d=shlex.quote(_dir_path(rdir)), always=" ".join(ALWAYS),
           out=OUT_NAME, extra=extra or "''", max=int(max_bytes),
           mark=OVERSIZE_MARK)


def _clean_relpath(name):
    """A remote name reduced to a safe relative path.

    Nothing a host says is used as a local path. `..` segments, absolute
    paths and leading slashes are stripped here, so a host answering with
    `../../etc/cron.d/x` writes inside the collection directory or not at
    all.
    """
    parts = []
    for part in name.replace("\\", "/").split("/"):
        if not part or part == "." or part == "..":
            continue
        parts.append(part)
    return "/".join(parts)


def local_name(tag, host, relpath):
    """Where one collected file lands: one directory, the name says which.

    The tag leads, then the host, then the path it had on that host with
    its separators folded in. That is the order that makes a shared
    directory readable -- `ls` groups by run, `rm bench~*` clears one of
    them -- and it is why the collection is a flat directory rather than
    forty rebuilt trees.
    """
    rel = _clean_relpath(relpath) or "unnamed"
    return FLAT_SEP.join([clean_tag(tag), host, rel.replace("/", FLAT_SEP)])


def _extract(blob, dest, tag, host, taken):
    """Unpack one host's tar into the collection directory, flattened."""
    written, total, clashes = [], 0, []
    tf = tarfile.open(fileobj=io.BytesIO(blob), mode="r|")
    try:
        for member in tf:
            if not member.isfile():
                continue
            name = local_name(tag, host, member.name)
            path = os.path.join(dest, name)
            if name in taken:
                clashes.append(member.name)
                continue
            taken.add(name)
            src = tf.extractfile(member)
            if src is None:
                continue
            with open(path, "wb") as fh:
                shutil.copyfileobj(src, fh)
            # Keep the execute bit and nothing else: a collected result is
            # data, and a remote uid/gid means nothing here.
            if member.mode & stat.S_IXUSR:
                os.chmod(path, 0o755)
            written.append((name, member.size))
            total += member.size
    finally:
        tf.close()
    return written, total, clashes


def _split_oversize(err):
    """Pull the host's oversize report out of its stderr.

    stdout carries the tar, so what a host refused to send travels on
    stderr beside it. Returns (skipped, whatever else stderr said) --
    the rest still matters, because a real error can arrive on the same
    stream.
    """
    skipped, rest = [], []
    for line in (err or "").splitlines():
        if line.startswith(OVERSIZE_MARK + "\t"):
            parts = line.split("\t")
            if len(parts) >= 3:
                try:
                    skipped.append((parts[1], int(parts[2])))
                    continue
                except ValueError:
                    pass
        rest.append(line)
    return skipped, "\n".join(rest).strip()


class Collected(object):
    __slots__ = ("host", "files", "bytes", "error", "clashes", "skipped")

    def __init__(self, host):
        self.host = host
        self.files = []
        self.bytes = 0
        self.error = ""
        self.clashes = []
        # (path, size) for anything over --max-bytes, so the report can
        # name what it did not bring back.
        self.skipped = []


def cmd_collect(args, plan=None):
    plan = plan or load_plan(args.plan)
    fleet = Fleet(plan, args)
    dest = default_dir(args.dir)
    if fleet.dry_run:
        log("# %d host(s): %s" % (len(plan.hosts), " ".join(plan.hosts[:8])))
        sys.stdout.write(_dir_guard(fleet, to_stderr=True)
                         + _collect_script(fleet.dir, plan.collect,
                                           args.max_bytes))
        return 0
    try:
        os.makedirs(dest)
    except OSError as exc:
        if exc.errno != errno.EEXIST:
            die("cannot create %s: %s" % (dest, exc))

    # The guard speaks on stderr: stdout is the tar.
    script = (_dir_guard(fleet, to_stderr=True)
              + _collect_script(fleet.dir, plan.collect, args.max_bytes))
    # Names are claimed under a lock-free protocol only because each host
    # owns a disjoint slice of the namespace (the host name is in every
    # name); the set is filled in plan order below, off the threads.
    blobs = fleet.gather(lambda h: fleet.stream(h, script,
                                                timeout=args.timeout))

    taken = set()
    results = []
    for host in plan.hosts:
        r = Collected(host)
        rc, blob, err = blobs[host]
        r.skipped, err = _split_oversize(err)
        if rc == 3:
            r.error = "nothing to collect (did the job run?)"
        elif rc != 0 or (not blob and not r.skipped):
            r.error = err or "collection failed (exit %s)" % rc
        else:
            try:
                r.files, r.bytes, r.clashes = _extract(blob, dest, plan.tag,
                                                       host, taken)
            except tarfile.TarError as exc:
                r.error = "unreadable stream: %s" % exc
        results.append(r)

    return _render_collection(results, dest, args)


def _render_collection(results, dest, args):
    good = [r for r in results if r.files and not r.error]
    bad = [r for r in results if r.error]
    empty = [r for r in results
             if not r.files and not r.error and not r.skipped]
    nfiles = sum(len(r.files) for r in results)
    nbytes = sum(r.bytes for r in results)

    log("")
    log("tx collect -- %d file%s from %d of %d hosts, %s -> %s/"
        % (nfiles, "" if nfiles == 1 else "s", len(good), len(results),
           fmt_bytes(nbytes), dest))
    log("")
    for r in bad:
        log("  FAILED    %s: %s" % (r.host, r.error))
    for r in empty:
        log("  EMPTY     %s: the job produced nothing" % r.host)
    clashed = [r for r in results if r.clashes]
    for r in clashed:
        log("  COLLISION %s: %d file(s) folded onto a name already taken: %s"
            % (r.host, len(r.clashes), " ".join(r.clashes[:3])))
    # Named, with sizes, because "we did not bring this back" is only
    # useful if you can tell what and decide whether you wanted it.
    big = [r for r in results if r.skipped]
    if big:
        n = sum(len(r.skipped) for r in big)
        log("  OVERSIZE  %d file%s over --max-bytes (%s), left where they are:"
            % (n, "" if n == 1 else "s", fmt_bytes(args.max_bytes)))
        shown = 0
        for r in big:
            for path, size in r.skipped:
                if shown >= 6:
                    break
                log("            %-12s %8s  %s"
                    % (r.host, fmt_bytes(size), path))
                shown += 1
        if n > shown:
            log("            ... and %d more" % (n - shown))
        log("            raise --max-bytes, or have the job write less.")
    if bad or empty or clashed or big:
        log("")

    if not args.quiet:
        shown = [n for r in good for n, _s in r.files]
        for name in shown[:12]:
            log("  %s/%s" % (dest, name))
        if len(shown) > 12:
            log("  ... and %d more" % (len(shown) - 12))

    if args.csv:
        _write_csv(results, dest, args.csv)
        log("[tx] %s" % args.csv)

    # Exit 1 on an empty collection is deliberate: a script that fans out
    # to gather results and gathers none should stop, not carry on with
    # an empty directory.
    return 1 if (bad or clashed or big or not nfiles) else 0


CSV_FIELDS = ["host", "local_path", "bytes"]


def _write_csv(results, dest, path):
    import csv as _csv
    fh = sys.stdout if path == "-" else open(path, "w", newline="")
    try:
        w = _csv.DictWriter(fh, fieldnames=CSV_FIELDS, lineterminator="\n")
        w.writeheader()
        for r in results:
            if not r.files:
                w.writerow({"host": r.host, "local_path": "", "bytes": 0})
                continue
            for name, size in r.files:
                w.writerow({"host": r.host,
                            "local_path": os.path.join(dest, name),
                            "bytes": size})
    finally:
        if fh is not sys.stdout:
            fh.close()


# ---------------------------------------------------------------------------
# Summarize
# ---------------------------------------------------------------------------

def _median(values):
    if not values:
        return None
    s = sorted(values)
    mid = len(s) // 2
    if len(s) % 2:
        return s[mid]
    return (s[mid - 1] + s[mid]) / 2.0


def cmd_summarize(args, plan=None):
    plan = plan or load_plan(args.plan)
    fleet = Fleet(plan, args)
    return render_summary(plan, _collect_status(fleet), args)


def render_summary(plan, states, args, waves=0):
    """The report, from states already gathered.

    Kept separate from the polling because coverage mode cannot poll at
    the end: by then the earlier waves have been collected and possibly
    cleaned, and a host that was wiped an hour ago would read as one that
    never answered. So a wave records what it saw while it could, and
    this renders the lot.
    """
    reports, missing, gone = [], [], []
    for host in plan.hosts:
        alive, report, word = states[host]
        if report is None:
            missing.append((host, word or "no result"))
            continue
        reports.append(report)
        # A record that stopped mid-job with no agent behind it: a reboot,
        # an OOM kill. Nothing more is coming from that host, so it is a
        # host without a result -- not one "still going", which is what
        # it was reported as, with an exit status of 0.
        if not alive and report.get("state") in UNFINISHED:
            gone.append((host, report))

    passed = [r for r in reports if r.get("exit") == 0
              and not r.get("timed_out")]
    failed = [r for r in reports if r.get("exit") not in (0, None)
              and not r.get("timed_out")]
    timed = [r for r in reports if r.get("timed_out")]
    setup_bad = [r for r in reports if r.get("state") == "setup-failed"]
    never = [r for r in reports if r.get("state") == "launch-failed"]
    gone_ids = set(id(r) for _h, r in gone)
    unfinished = [r for r in reports if r.get("state") in UNFINISHED
                  and id(r) not in gone_ids]

    log("")
    log("tx -- %s   [%s]" % (plan.run, plan.tag))
    log("      %d of %d hosts finished: %d passed, %d failed, %d timed out"
        % (len(passed) + len(failed) + len(timed), len(plan.hosts),
           len(passed), len(failed), len(timed)))
    if waves:
        # The whole point of coverage mode is the denominator, so say what
        # fraction of the fleet was actually reached.
        reached = len(reports)
        log("      covered %d of %d hosts in %d wave%s of at most %d"
            % (reached, len(plan.hosts), waves, "" if waves == 1 else "s",
               args.batch))
    log("")

    # The synchronisation is a measurement, so report it as one. Without
    # this the claim "they all started together" is untestable.
    offsets = [r["start_offset"] for r in reports
               if r.get("start_offset") is not None]
    if offsets:
        spread = max(offsets) - min(offsets)
        # Each offset is measured against that host's *own* armed instant,
        # and in wave mode every wave has its own. So this is how tightly
        # each wave began, not a claim that the whole fleet started
        # together -- which in wave mode it deliberately did not.
        where = "within each wave" if waves else "across %d hosts" % len(offsets)
        log("  START     spread %s %s (worst %+.3fs off the armed instant)"
            % (fmt_secs(spread), where, max(offsets, key=abs)))
        if waves:
            log("            waves are simultaneous in themselves, not with "
                "each other -- that is what --batch trades away")
        if spread > 1.0:
            log("            that is wide enough to matter; raise "
                "--start-in, or check the fleet's clocks")

    durations = [r["duration"] for r in reports if r.get("duration")]
    if durations:
        med = _median(durations)
        log("  DURATION  median %s, fastest %s, slowest %s"
            % (fmt_secs(med), fmt_secs(min(durations)),
               fmt_secs(max(durations))))
        # An outlier here is the usual reason a fleet benchmark is being
        # run at all, so name the hosts rather than only the number.
        slow = sorted([r for r in reports if r.get("duration")],
                      key=lambda r: -r["duration"])
        # A ratio on its own calls a 9ms job "slow" against a 6ms median,
        # which is scheduler noise wearing a finding's clothes. Below a
        # second, the ratio is not measuring the job.
        if med >= 1.0 and slow and slow[0]["duration"] > 1.5 * med:
            out = [r for r in slow if r["duration"] > 1.5 * med][:args.top]
            log("  SLOW      %d host(s) took over 1.5x the median:"
                % len(out))
            for r in out:
                log("            %-16s %s" % (r["host"],
                                              fmt_secs(r["duration"])))

    if setup_bad:
        log("  SETUP     %d host(s) never ran the job, setup failed:"
            % len(setup_bad))
        for r in setup_bad[:args.top]:
            log("            %-16s exit %s" % (r["host"],
                                               r.get("setup_exit")))
        log("            tx collect brings back setup.log from each.")
    if never:
        log("  NEVER RAN %d host(s) could not start the job at all:"
            % len(never))
        for r in never[:args.top]:
            log("            %-16s %s" % (r["host"], r.get("detail") or "?"))
        log("            nothing ran there, so there is no result to read "
            "as a failure.")
    if failed:
        log("  FAILED    %d host(s) exited non-zero:" % len(failed))
        for r in failed[:args.top]:
            log("            %-16s exit %s after %s"
                % (r["host"], r.get("exit"), fmt_secs(r.get("duration"))))
            # What the job said on its way out, so the report answers
            # "why" rather than only "which".
            for line in (r.get("stderr_tail") or "").splitlines()[-2:]:
                log("            %-16s   %s" % ("", line[:96]))
        if len(failed) > args.top:
            log("            ... and %d more" % (len(failed) - args.top))
    if timed:
        log("  TIMEOUT   %d host(s) hit the %s limit: %s"
            % (len(timed), fmt_secs(plan.timeout),
               " ".join(r["host"] for r in timed[:8])))
        log("            raise timeout= in %s, or find out why they are "
            "slower." % plan.path)
    if unfinished:
        log("  RUNNING   %d host(s) are still going: %s"
            % (len(unfinished),
               " ".join(r["host"] for r in unfinished[:8])))
    if gone:
        log("  GONE      %d host(s) stopped mid-job and left no result: %s"
            % (len(gone), " ".join(h for h, _r in gone[:8])))
        log("            the agent is not running (a reboot? an OOM "
            "kill?); tx logs brings back what it said.")
    if missing:
        log("  NO RESULT %d host(s) said nothing:" % len(missing))
        for host, why in missing[:args.top]:
            log("            %-16s %s" % (host, why))

    teardown_bad = [r for r in reports
                    if r.get("teardown_exit") not in (0, None)]
    if teardown_bad:
        log("  TEARDOWN  %d host(s) failed to clean up after themselves: %s"
            % (len(teardown_bad),
               " ".join(r["host"] for r in teardown_bad[:8])))
        log("            those hosts may not be as you found them.")

    log("")
    if not (failed or timed or missing or setup_bad or unfinished or never
            or gone):
        log("[tx] every host ran the job and exited zero.")
    if not waves:
        log("[tx] next: tx collect     # the results themselves")
        log("[tx]       tx clean       # remove every trace")
    return 0 if not (failed or timed or missing or setup_bad or never
                     or gone) else 1


# ---------------------------------------------------------------------------
# Stop, logs, clean
# ---------------------------------------------------------------------------

def cmd_stop(args, plan=None):
    plan = plan or load_plan(args.plan)
    fleet = Fleet(plan, args)
    script = _dir_guard(fleet) + _kill_block(fleet.dir) + STOP_TAIL
    failed = fleet.each(lambda h: fleet.sh(h, script), "stopping the job")
    log("[tx] whatever the job produced is still on the hosts:")
    log("[tx]   tx collect     # bring it back")
    log("[tx]   tx clean       # delete every trace")
    return 1 if failed else 0


def cmd_logs(args):
    plan = load_plan(args.plan)
    fleet = Fleet(plan, args)
    dest = default_dir(args.dir)
    try:
        os.makedirs(dest)
    except OSError as exc:
        if exc.errno != errno.EEXIST:
            die("cannot create %s: %s" % (dest, exc))

    def one(host):
        name = local_name(plan.tag, host, LOG_NAME)
        # scp reads before any shell runs, so the directory is checked
        # first, in a round trip of its own.
        rc, out = fleet.sh(host, _dir_guard(fleet), timeout=30)
        if rc != 0:
            return rc, out
        rc, out = fleet.pull(host, LOG_NAME, os.path.join(dest, name))
        if rc != 0:
            return rc, "no agent log: %s" % out
        return 0, "-> %s/%s" % (dest, name)

    failed = fleet.each(one, "collecting agent logs into %s/" % dest)
    return 1 if failed else 0


# What `clean` runs after the kill block. In order, and each step stops
# the host where it is with nothing deleted:
#
#   1. The kill block refused (no /proc, no pid file): tx cannot tell this
#      run's agent from another's, so it leaves everything for a person.
#   2. An agent of this run is still running out of the directory: the
#      LEFTOVER. Another run's agent, or another user's, is not one --
#      pgrep only lists candidates, and each is put to tx_ours.
#   3. Anything in the directory that tx did not put there -- not one of
#      its own names, not in the record (MANIFEST_NAME) -- is named, and
#      the host is refused. This is what `rm -rf "$d"` used to delete,
#      whatever --remote-dir happened to name.
#
# Only then are tx's own entries deleted, the record last, and the
# directory itself `rmdir`ed -- which fails, rather than deletes, if
# anything appeared in the meantime.
CLEAN_TAIL = """
if [ -n "$refused" ]; then echo "$refused"; exit 1; fi
if [ -e "$d" ] && [ ! -d "$d" ]; then
    echo "REFUSED: $d is not a directory, so not one tx made -- nothing deleted"
    exit 1
fi
unsure=""
if [ -d "$d" ]; then
    mine=$({pgrep} 2>/dev/null)
    found=$?
    # Three answers out of one exit status, which is the distinction that
    # was missing once: 0 means agents of yours are running (whose is
    # asked next), 1 means none is, and anything else means there is no
    # pgrep to ask -- and reading that as "none found" is how the run came
    # to claim a clean fleet it never checked.
    if [ "$found" -eq 0 ] && [ "$have_proc" = yes ]; then
        left=""
        for p in $mine; do tx_ours "$p" && left="$left $p"; done
        if [ -n "$left" ]; then
            echo "LEFTOVER: an agent is still running out of $d (pid$left) -- nothing deleted"
            exit 1
        fi
    elif [ "$found" -eq 0 ]; then
        unsure="no /proc here, so whether a tx agent of yours (pid $(echo $mine)) belonged to this run could not be ruled out"
    elif [ "$found" -ne 1 ]; then
        unsure="no pgrep here, so a stray agent could not be ruled out"
    fi
    (
        cd "$d" || {{ echo "LEFTOVER: cannot enter $d"; exit 1; }}
        nl='
'
        # tx_own NAME: did tx put NAME here?
        tx_own() {{
            case "$1" in
                {own}) return 0 ;;
                *"$nl"*) return 1 ;;
            esac
            [ -f {manifest} ] && LC_ALL=C grep -qxF -e "$1" {manifest} 2>/dev/null
        }}
        n=0
        names=""
        for e in * .[!.]* ..?*; do
            [ -e "$e" ] || [ -L "$e" ] || continue
            tx_own "$e" && continue
            n=$((n+1))
            [ "$n" -le 8 ] && names="$names '$e'"
        done
        if [ "$n" -gt 0 ]; then
            [ "$n" -gt 8 ] && names="$names and $((n-8)) more"
            echo "REFUSED: tx did not put $n thing(s) in $d:$names -- nothing deleted; move them out or delete them, then tx clean again"
            exit 1
        fi
        for e in * .[!.]* ..?*; do
            [ -e "$e" ] || [ -L "$e" ] || continue
            [ "$e" = {manifest} ] && continue
            tx_own "$e" && rm -rf -- "$e"
        done
        rm -f {manifest}
    ) || exit 1
    rmdir -- "$d" 2>/dev/null || {{ echo "LEFTOVER: $d still exists"; exit 1; }}
fi
if [ -n "$unsure" ]; then
    echo "clean (was: $status) -- {mark}: $unsure"
else
    echo "clean (was: $status)"
fi
"""


def _clean_script(rdir):
    # A deploy's staging directory (and the start's temporary pid file)
    # is tx's too: one cut short -- the ssh dropped between the copy and
    # the rename -- leaves it behind, and it is not a stranger's file.
    # `_dir_guard` runs first, so only the ssh user (or, with
    # --allow-shared-remote-dir, its group) could have made one.
    own = [shlex.quote(n) for n in _own_names()]
    own.append(shlex.quote(STAGE_PREFIX) + "*")
    return _kill_block(rdir) + CLEAN_TAIL.format(
        pgrep=PGREP_MINE, mark=UNVERIFIED, manifest=MANIFEST_NAME,
        own="|".join(own))


def cmd_clean(args, plan=None):
    plan = plan or load_plan(args.plan)
    fleet = Fleet(plan, args)
    if not args.yes and not args.dry_run:
        log("[tx] this stops the job and deletes what tx put in %s on %d "
            "hosts." % (fleet.dir, len(plan.hosts)))
        log("[tx] collect anything you want first (tx collect, tx logs).")
        try:
            reply = input("[tx] type 'yes' to continue: ")
        except EOFError:
            reply = ""
        if reply.strip().lower() != "yes":
            log("[tx] nothing done")
            return 1
    script = _dir_guard(fleet) + _clean_script(fleet.dir)
    log("[tx] removing every trace on %d hosts" % len(plan.hosts))
    results = fleet.gather(lambda h: fleet.sh(h, script))
    failed = fleet.report(plan.hosts, results)
    if failed:
        refused = [h for h in plan.hosts
                   if (results[h][1] or "").startswith("REFUSED")]
        if refused:
            log("[tx] %d host(s) left exactly as they were: tx deletes only "
                "what it put there, and says what else it found (above)"
                % len(refused))
        return 1
    # A host with no pgrep cannot be asked whether an agent survived, and
    # a missing pgrep looks exactly like "no agents found" -- so it says
    # so rather than letting the run claim a clean fleet it never checked.
    unsure = [h for h in plan.hosts if UNVERIFIED in (results[h][1] or "")]
    if unsure:
        log("[tx] the working directory is gone from every host. On %d of "
            "them whether an agent outlived it could not be checked (no "
            "pgrep, or no /proc to say whose an agent is): %s"
            % (len(unsure), " ".join(unsure[:8])))
        return 0
    log("[tx] nothing of tx remains on the fleet -- no packages, no services, "
        "no leftover payload (there never were any)")
    return 0


# ---------------------------------------------------------------------------
# run: the whole thing
# ---------------------------------------------------------------------------

def _job_bound(plan, nhosts, start_in):
    """The longest a host can take, from arming to its last record.

    The job's timeout, and the arming window -- but setup and teardown
    are bounded separately, each by the same timeout (setup by whatever
    of it is left at the armed instant), and each can be killed at its
    limit and given KILL_GRACE to go. A bound that counted only the job
    gave up on hosts still within their budget: a wave reported them
    unfinished and started the next wave over them, which is the one
    thing --batch exists to prevent.
    """
    extra = (1 if plan.setup else 0) + (1 if plan.teardown else 0)
    return (arm_delay(nhosts, start_in) + plan.timeout
            + extra * (plan.timeout + KILL_GRACE))


def _wait_deadline(args, plan):
    """When to stop waiting for a set of hosts.

    A fleet cannot take longer than its own bound (`_job_bound`), so
    waiting past that means something is wrong rather than slow -- and
    an unbounded wait is how a script hangs forever.
    """
    return (time.time() + _job_bound(plan, len(plan.hosts), args.start_in)
            + 60)


# ---------------------------------------------------------------------------
# Ctrl-C: what it leaves running, and what to type next (TX-005)
# ---------------------------------------------------------------------------
#
# Once the hosts are armed, Ctrl-C stops tx and not the job. The agents are
# detached by design: each finishes the job and keeps its results without
# tx, and that is what lets `--resume` pick a sweep up. So tx leaves them
# be and says what is still running and the next command for each choice.
# Two moments are different. While arming, the hosts already reached are
# stood back down (`_interrupted_arming`): a fleet armed on some hosts and
# not the rest would run the job on those alone. And a --muster wave
# finishes its bookkeeping with the pool first (`_muster_interrupted`).

def _next_steps(steps):
    """Print (command, what it is for) pairs, as `tx start` does its own.
    The notes line up, except after a command too long to line up with:
    a sweep's own command line would push every other note off the
    screen."""
    width = max([len(cmd) for cmd, _why in steps if len(cmd) <= 48] or [0])
    for n, (cmd, why) in enumerate(steps):
        log("[tx] %s %-*s  # %s" % ("next:" if n == 0 else "     ", width,
                                    cmd, why))


def _fleet_flags(args):
    """What a follow-up command needs, as text, to reach the fleet this one
    did: each fleet option given here that it would not pick up by itself,
    from the environment or by default."""
    words = []
    if args.plan != _env("TX_PLAN", DEFAULT_PLAN):
        words += ["--plan", args.plan]
    if (getattr(args, "remote_dir", "") or "") != _env("TX_REMOTE_DIR", ""):
        words += ["--remote-dir", args.remote_dir]
    if (args.user or "") != _env("TX_USER", _env("SSH_USER", "")):
        words += ["--user", args.user]
    if (getattr(args, "allow_shared_remote_dir", False)
            and _env("TX_ALLOW_SHARED_REMOTE_DIR", "") != "1"):
        words.append("--allow-shared-remote-dir")
    return "".join(" " + shlex.quote(w) for w in words)


def _as_typed(args, extra=()):
    """This command again, as it was typed, with `extra` on the end."""
    words = list(getattr(args, "argv", None) or [args.cmd]) + list(extra)
    return " ".join(["tx"] + [shlex.quote(w) for w in words])


def _last_check(seen, hosts):
    """Say which of `hosts` the wait's last status check found unfinished,
    and return them. With no check back yet, that is all of them."""
    states = seen.get("states")
    if states is None:
        log("[tx] no status check had come back yet, so all %d host(s) may "
            "still be running: %s" % (len(hosts), _hosts_line(hosts)))
        return list(hosts)
    left = [h for h in hosts if h in states and not _is_finished(states[h])]
    ago = fmt_secs(time.time() - seen["at"])
    if left:
        log("[tx] at the last check, %s ago, %d of %d host(s) had not "
            "finished: %s" % (ago, len(left), len(hosts), _hosts_line(left)))
    else:
        log("[tx] at the last check, %s ago, every host had finished" % ago)
    return left


def _interrupted_run(headline, hosts, seen):
    """Ctrl-C once `hosts` were armed: leave them as they are, and say which
    were still running. Returns those."""
    log("")
    log(headline)
    log("[tx] the hosts are left as they are: the agents are detached, so a "
        "host still running finishes the job, and keeps its results, "
        "without tx")
    return _last_check(seen, hosts)


def cmd_run(args):
    plan = load_plan(args.plan)
    if args.muster is not None:
        return run_from_muster(args, plan)
    if args.batch is not None:
        return run_in_waves(args, plan)

    rc = cmd_start(args, plan)
    if rc:
        return rc
    fleet = Fleet(plan, args)
    deadline = _wait_deadline(args, plan)
    log("[tx] waiting for the fleet (up to %s)"
        % fmt_secs(deadline - time.time()))
    seen = {}
    try:
        _states, finished = _wait_for_fleet(fleet, deadline,
                                            pinned=args.poll, seen=seen)
        if not finished:
            log("[tx] some hosts had not finished when the wait ran out; "
                "collecting what there is")
        summary = cmd_summarize(args, plan)
        collected = cmd_collect(args, plan)
        cleaned = 0
        if args.clean:
            args.yes = True
            # A clean that was refused, or found an agent still going, is a
            # host left as it was -- worth an exit code, not a silent zero.
            cleaned = cmd_clean(args, plan)
    except KeyboardInterrupt:
        left = _interrupted_run("[tx] interrupted", plan.hosts, seen)
        flags = _fleet_flags(args)
        steps = [("tx status" + flags, "who is running, who has finished"),
                 ("tx collect" + flags + (" -d " + shlex.quote(args.dir)
                                          if args.dir else ""),
                  "bring the results back" + (", once they finish"
                                              if left else ""))]
        if left:
            steps.append(("tx stop" + flags, "or stop the job now"))
        if args.clean:
            steps.append(("tx clean" + flags, "then remove what tx put there"))
        _next_steps(steps)
        raise Interrupted(left)
    return 1 if (summary or collected or cleaned or not finished) else 0


# ---------------------------------------------------------------------------
# Coverage: the whole fleet, a few hosts at a time
# ---------------------------------------------------------------------------

def waves_of(hosts, size):
    """The fleet cut into waves of at most `size`, in plan order.

    Plan order rather than anything cleverer: two sweeps of the same
    fleet then cover it the same way, which is what makes a second run
    comparable to the first.
    """
    return [hosts[i:i + size] for i in range(0, len(hosts), size)]


def _new_sweep_id():
    """A new sweep's id: when it began, and enough randomness that two
    sweeps begun in the same second are still two."""
    return time.strftime("%Y%m%d-%H%M%S-") + os.urandom(3).hex()


def _begin_sweep(args, plan):
    """Give a new sweep its id, written into its collection directory
    before the first wave is armed. Returns the id.

    Before, not after: a sweep killed in its first wave has collected
    nothing yet, and --resume still has to know which records are its. A
    directory that held an earlier sweep's id gets this one's: a sweep run
    into it without --resume is a new sweep, and what the old one left
    there no longer counts as done for anybody.
    """
    sweep = _new_sweep_id()
    if getattr(args, "dry_run", False):
        return sweep
    try:
        os.makedirs(args.dir)
    except OSError as exc:
        if exc.errno != errno.EEXIST:
            die("cannot create %s: %s" % (args.dir, exc))
    try:
        _write_json(os.path.join(args.dir, SWEEP_NAME),
                    {"sweep_id": sweep, "tag": plan.tag,
                     "began": time.strftime("%Y-%m-%d %H:%M:%S %z")})
    except (IOError, OSError) as exc:
        die("cannot write %s: %s" % (os.path.join(args.dir, SWEEP_NAME),
                                     exc))
    return sweep


def _sweep_of(dest):
    """The id of the sweep collecting into `dest`, or die saying why there
    is none to resume.

    Without it nothing on the fleet can be told apart: a host the sweep
    never reached still holds the last run's record, finished and exit 0,
    and counting that as done is how a resumed sweep reported hosts it
    never ran as passing.
    """
    path = os.path.join(dest, SWEEP_NAME)
    try:
        with open(path) as fh:
            sweep = json.load(fh)
    except (IOError, OSError) as exc:
        if exc.errno != errno.ENOENT:
            die("--resume: cannot read %s: %s" % (path, exc))
        die("--resume: %s/ holds no sweep (no %s in it). Give -d the "
            "directory the sweep was collecting into: it holds the sweep's "
            "id, which is how resume tells the sweep's results from an "
            "earlier run's. A sweep begun by tx 1.2.2 or older has no id; "
            "run it again without --resume." % (dest, SWEEP_NAME))
    except ValueError as exc:
        die("--resume: %s is not a sweep record (%s)" % (path, exc))
    sweep = sweep.get("sweep_id") if isinstance(sweep, dict) else None
    if not sweep or not isinstance(sweep, str):
        die("--resume: %s names no sweep id, so this sweep's results "
            "cannot be told from an earlier run's" % path)
    return sweep


def _of_sweep(report, sweep):
    """Is this run record one of `sweep`'s?"""
    return (bool(sweep) and isinstance(report, dict)
            and report.get("sweep_id") == sweep)


def _filed_result(dest, tag, host, sweep):
    """`host`'s finished record from `sweep`, as the collection directory
    already holds it, or None.

    A --clean sweep removes each wave from its hosts once it has been
    collected, so for those hosts the collection is the only record left.
    Asking the fleet alone found nothing there, and resume ran every
    finished wave a second time.
    """
    path = os.path.join(dest, local_name(tag, host, REPORT_NAME))
    try:
        with open(path) as fh:
            report = json.load(fh)
    except (IOError, OSError, ValueError):
        return None
    if (_of_sweep(report, sweep) and report.get("host") == host
            and report.get("state") in FINISHED):
        return report
    return None


def _hosts_line(hosts, most=8):
    return " ".join(hosts[:most]) + (" ..." if len(hosts) > most else "")


def _collect_wave(args, sub):
    """What a wave does once its hosts have finished: collect them into
    the sweep's directory and, with --clean, clean them. For the hosts a
    resumed sweep picks up from the interrupted one, which used to be
    collected and then left on the fleet whatever --clean said. True if
    either went wrong."""
    bad = bool(cmd_collect(args, sub))
    if args.clean:
        args.yes = True
        bad = bool(cmd_clean(args, sub)) or bad
    return bad


def run_in_waves(args, plan):
    """`_sweep`, and what a Ctrl-C in it leaves and says.

    The wave running is left to finish, as in a whole-fleet run, and the
    person is given the command that carries the sweep on: this one again,
    with --resume and the -d the sweep collects into. Resume then waits
    for that wave rather than starting it over.
    """
    given = bool(args.dir)
    where = {}
    try:
        return _sweep(args, plan, where)
    except KeyboardInterrupt as exc:
        left = list(getattr(exc, "left", ()))
        if not isinstance(exc, Interrupted):
            if where.get("hosts"):
                left = _interrupted_run(where["headline"], where["hosts"],
                                        where["seen"])
            else:
                log("")
                log("[tx] interrupted before the sweep had a wave running")
        if not getattr(args, "sweep_id", ""):
            log("[tx] the sweep had not begun, so there is nothing to "
                "resume: run it again")
            raise Interrupted(left)
        steps = [(_as_typed(args, ([] if given else ["-d", args.dir])
                            + ([] if args.resume else ["--resume"])),
                  "carry the sweep on from where it stopped")]
        if left:
            flags = _fleet_flags(args)
            steps += [("tx status" + flags, "who is running, who has finished"),
                      ("tx stop" + flags, "or stop the wave now")]
        _next_steps(steps)
        raise Interrupted(left)


def _sweep(args, plan, where):
    """Cover the whole fleet a few hosts at a time.

    Some jobs cannot run fleet-wide at once -- a licence with a seat
    count, a filer that only has so much throughput, a power envelope,
    a test fixture that handles twenty machines. The answer is not to
    give up the simultaneity but to narrow what it applies to: each wave
    is armed for its own instant and is as simultaneous as any whole-fleet
    run, and the waves march through the fleet until it is used up.

    Everything lands in **one** directory, because the point of covering
    the fleet is to end with one set of results for all of it. The names
    already carry the host, so a hundred hosts' results sit together and
    still read apart.
    """
    states = {}
    trouble = []
    hosts = plan.hosts
    # Chosen once, before the first wave: the default is stamped with the
    # time, and a fresh directory per wave would scatter one sweep's
    # results across ten of them.
    args.dir = default_dir(args.dir)

    if not args.resume:
        args.sweep_id = _begin_sweep(args, plan)
    else:
        # No progress file, no state in this process: the answer is
        # already on the hosts, in the same run.json every other command
        # reads, and in what the sweep has collected so far. One status
        # sweep says where the fleet stands, and that is what makes a
        # sweep survive its own orchestrator being killed.
        #
        # Only *this* sweep's records count, by the id the collection
        # directory holds and every record carries. The fleet keeps no
        # history: a host this sweep never reached still holds the last
        # run's record, finished and exit 0, and taking that for this
        # sweep's result reported hosts that never ran as passing.
        #
        # Three answers, not two. A host with a result is done -- on the
        # host, or already in the collection, where a --clean sweep left
        # it. A host still working is one the interrupted sweep left
        # running -- agents are detached, so the work outlived the
        # orchestrator -- and restarting it would trample a run that is
        # nearly finished. Only what is neither gets covered in waves.
        sweep = args.sweep_id = _sweep_of(args.dir)
        log("[tx] --resume: asking the fleet where it got to (sweep %s)"
            % sweep)
        seen = _collect_status(Fleet(plan, args))
        filed = {}
        for h in plan.hosts:
            report = _filed_result(args.dir, plan.tag, h, sweep)
            if report is not None:
                filed[h] = report
        held = [h for h in plan.hosts
                if _has_result(seen[h]) and _of_sweep(seen[h][1], sweep)]
        already = [h for h in plan.hosts if h in filed or h in held]
        # An agent that has not written its record yet cannot say whose it
        # is, so it is waited on and asked again when it has.
        busy = [h for h in plan.hosts
                if h not in already and _still_working(seen[h])
                and (seen[h][1] is None or _of_sweep(seen[h][1], sweep))]
        hosts = [h for h in plan.hosts
                 if h not in already and h not in busy]
        log("[tx] %d done, %d still running, %d left to cover"
            % (len(already), len(busy), len(hosts)))
        earlier = [h for h in hosts if _has_result(seen[h])]
        if earlier:
            log("[tx] %d of those hold an earlier run's result, not this "
                "sweep's, so they run again: %s"
                % (len(earlier), _hosts_line(earlier)))
        elsewhere = [h for h in hosts if _still_working(seen[h])]
        if elsewhere:
            log("[tx] %d host(s) are running another run's job, which this "
                "sweep neither waits for nor counts (tx stop it, or resume "
                "once it ends): %s" % (len(elsewhere), _hosts_line(elsewhere)))
        for h in already:
            states[h] = seen[h] if h in held else (False, filed[h], None)

        kept = [h for h in already if h not in held]
        if kept:
            log("[tx] %d finished host(s) are already in %s/ and need "
                "nothing more" % (len(kept), args.dir))
        if held:
            # Collect them again rather than assuming the interrupted
            # sweep got that far. A host that finished the job and was
            # killed before its results were fetched has a result *on
            # the host* and nothing here -- skipping it because it "has
            # a result" is how a resumed sweep quietly loses the very
            # hosts it is meant to be recovering. Re-fetching a host
            # that was already collected costs a transfer and rewrites
            # identical files; losing one costs the run.
            log("[tx] re-collecting the %d finished host(s), in case the "
                "interrupted sweep never got their results back"
                % len(held))
            if _collect_wave(args, slice_plan(plan, held)):
                trouble.append(0)

        if busy:
            log("[tx] waiting for the %d host(s) the interrupted sweep left "
                "running rather than starting them over" % len(busy))
            sub = slice_plan(plan, busy)
            where.update(hosts=busy, seen={}, headline="[tx] interrupted "
                         "while waiting for the hosts the earlier sweep "
                         "left running")
            busy_states, finished = _wait_for_fleet(
                Fleet(sub, args), _wait_deadline(args, sub),
                pinned=args.poll, seen=where["seen"])
            if not finished:
                trouble.append(0)
            mine = [h for h in busy if _of_sweep(busy_states[h][1], sweep)]
            states.update(dict((h, busy_states[h]) for h in mine))
            if mine and _collect_wave(args, slice_plan(plan, mine)):
                trouble.append(0)
            # One that turned out to be another run's is this sweep's to
            # cover, like any other host without its result.
            strays = set(busy) - set(mine)
            hosts = [h for h in plan.hosts if h in set(hosts) or h in strays]

        if not hosts:
            log("[tx] nothing left to cover.")
            for host in plan.hosts:
                states.setdefault(host, (False, None, "NOT REACHED"))
            rc = render_summary(plan, states, args, waves=0)
            log("[tx] results: %s/" % args.dir)
            return 1 if (rc or trouble) else 0

    waves = waves_of(hosts, args.batch)
    log("[tx] coverage: %d host%s in %d wave%s of at most %d -> %s/ "
        "(sweep %s)"
        % (len(hosts), "" if len(hosts) == 1 else "s", len(waves),
           "" if len(waves) == 1 else "s", args.batch, args.dir,
           args.sweep_id))
    for n, wave in enumerate(waves, 1):
        log("")
        log("[tx] === wave %d of %d: %s ==="
            % (n, len(waves), " ".join(wave[:8])
               + (" ..." if len(wave) > 8 else "")))
        sub = slice_plan(plan, wave)
        where.clear()
        if cmd_start(args, sub):
            # cmd_start has already stood this wave back down. The fleet
            # beyond it is untouched, so unless told otherwise carry on:
            # one unreachable rack should not cost the other nine.
            trouble.append(n)
            for host in wave:
                states[host] = (False, None, "WAVE DID NOT START")
            if args.stop_on_fail:
                log("[tx] --stop-on-fail: not starting the remaining waves")
                break
            continue

        deadline = _wait_deadline(args, sub)
        where.update(hosts=wave, seen={}, headline="[tx] interrupted in "
                     "wave %d of %d" % (n, len(waves)))
        wave_states, finished = _wait_for_fleet(Fleet(sub, args), deadline,
                                                pinned=args.poll,
                                                seen=where["seen"])
        # Recorded now, while the record is still on the hosts: the
        # collection below, and a --clean after it, are about to take it
        # away, and the final report is rendered from what we saw here.
        states.update(wave_states)
        if not finished:
            log("[tx] wave %d had hosts still running when the wait ran "
                "out; collecting what there is" % n)
            trouble.append(n)

        if cmd_collect(args, sub):
            trouble.append(n)
        unclean = False
        if args.clean:
            args.yes = True
            # Counted, and the sweep goes on: the next wave is other
            # hosts. Only --stop-on-fail makes a wave that could not be
            # cleaned the last one.
            unclean = bool(cmd_clean(args, sub))
            if unclean:
                trouble.append(n)
        if args.stop_on_fail and (unclean or not finished):
            log("[tx] --stop-on-fail: not starting the remaining waves")
            break

    # A sweep stopped early leaves hosts nobody ever asked. Saying so is
    # the difference between "they passed" and "they were never run".
    for host in plan.hosts:
        states.setdefault(host, (False, None, "NOT REACHED"))

    rc = render_summary(plan, states, args, waves=len(waves))
    log("[tx] results: %s/" % args.dir)
    return 1 if (rc or trouble) else 0


# ---------------------------------------------------------------------------
# Coverage: a pool of work, a few items at a time
# ---------------------------------------------------------------------------
#
# `--batch` marches through a fleet the plan names, and the plan is the
# whole world: the same sweep run twice covers the same hosts. `--muster`
# marches through a *pool* somebody else is keeping. binnacle's `muster`
# hands items out under a lease, once each, and is the one thing that
# knows what is still outstanding -- across however many machines are
# drawing from it. tx takes X of them, runs that lot as one wave, checks
# them back in, and asks for X more until the pool has nothing left.
#
# The division of labour is the point, and it is what makes this worth
# having over `--batch` on a longer list. muster owns what is outstanding.
# tx owns what happens to the items it is holding. Neither keeps a copy
# of the other's record, so there is nothing to reconcile when one of them
# is killed -- a sweep that dies holding twenty items does not have to be
# found and cleaned up after, because an expired lease is not a lease and
# those twenty are back in the pile without anything having to notice.

DEFAULT_MUSTER = "muster"


def _muster(args, verb, rest, quiet=True):
    """One muster verb, against the pool. Returns (rc, stdout).

    muster's exit codes are 0 for nothing wrong, 1 for something worth
    seeing -- a CONFLICT, an unknown item -- and 2 for a usage error or a
    pool that could not be locked. Only 2 means the bookkeeping did not
    happen, and carrying on from there would run work the pool has no
    record of being out, so that is the one that stops the sweep.
    """
    argv = (args.muster_cmd or DEFAULT_MUSTER).split() + [verb]
    argv += ["--pool", args.muster]
    if quiet:
        argv.append("--quiet")
    argv += list(rest)
    try:
        p = subprocess.Popen(argv, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
        out, err = p.communicate()
    except OSError as exc:
        die("cannot run %s: %s\n"
            "    --muster wants binnacle's `muster` on PATH (pip install "
            "binnacle), or name it with --muster-cmd" % (argv[0], exc))
    out = (out or b"").decode("utf-8", "replace")
    err = (err or b"").decode("utf-8", "replace")
    # With --quiet, what is left on stderr is what muster thought was
    # worth saying anyway: a CONFLICT naming two holders, an item that is
    # not in the pool. Passing it through is the difference between a
    # sweep that quietly did work twice and one that said so.
    for line in err.splitlines():
        if line.strip():
            log("  muster: %s" % line.rstrip())
    if p.returncode >= 2:
        die("muster %s: the pool could not be read or written, so nothing "
            "was leased and nothing was run" % verb)
    return p.returncode, out


def _ticket_parts(path):
    """A ticket's comment header and its items, kept apart.

    The header is not decoration: it carries the lease line, and that is
    how `muster done` tells this sweep's completion from somebody else's.
    So a wave that checks in only some of what it took writes a fresh
    ticket with the same header and fewer items, rather than naming them
    with --item and throwing the lease away -- which would turn a
    reportable CONFLICT into a silent one.
    """
    head, items = [], []
    try:
        with open(path) as fh:
            for line in fh:
                line = line.rstrip("\n").rstrip("\r")
                if line.startswith("#"):
                    head.append(line)
                elif line.strip():
                    items.extend(line.split())
    except (IOError, OSError) as exc:
        die("cannot read the ticket muster wrote (%s): %s" % (path, exc))
    return head, items


def _check_in(args, path, verb, head, items):
    """Hand a lot of items back, under the lease they were taken on."""
    if not items:
        return 0
    try:
        with open(path, "w") as fh:
            fh.write("\n".join(head + list(items)) + "\n")
    except (IOError, OSError) as exc:
        die("cannot write %s: %s" % (path, exc))
    rc, _out = _muster(args, verb, [path])
    return rc


def _plan_over(plan, items, addrs):
    """The same job, over hosts the plan need not have named.

    slice_plan narrows a plan to hosts it already lists. This builds one
    over names that came from somewhere else, which is what a pool is.
    """
    return Plan(plan.path, list(items),
                dict((i, addrs[i]) for i in items),
                plan.run, plan.setup, plan.teardown, plan.payload,
                plan.timeout, plan.collect, plan.tag, plan.remote_dir,
                plan.stdin)


def muster_addr(plan, item):
    """Where to ssh to for a pool item.

    The pool decides *which* work is done and in what order; the plan
    stays the address book. An item the plan names is reached at the
    address the plan gives it, so a fleet can sit behind aliases or be
    renamed without the pool being told. An item the plan does not name
    is its own address, which is what makes a pool of bare hostnames work
    against a plan that lists none of them.
    """
    return plan.addrs.get(item, item)


def muster_lease(args, plan):
    """How long to hold a wave's items for, if nobody said.

    The lease has to outlast the wave or the items go back in the pile
    while tx is still working on them, and somebody else runs the same
    benchmark on the same host -- which is the one thing the pool exists
    to prevent. muster's own default is an hour, and a job with a
    two-hour timeout would quietly outlive it, so the default here is the
    wave's own bound with room on top rather than a number picked flat.
    """
    if args.lease:
        return args.lease
    # The whole of the agent's own bound, setup and teardown included: a
    # host that overran a job-only bound was still working when its item
    # went back to the pool.
    bound = _job_bound(plan, args.batch, args.start_in) + 60
    return "%ds" % int(bound * 2 + 300)


def _muster_interrupted(args, sub, wave, wave_states, collected):
    """Ctrl-C in a --muster wave once it was armed: finish its bookkeeping.
    Returns (wave_states, unclean) for the check-in that follows.

    The pool is only as good as what tx tells it. Exiting on the spot left
    every item of the wave held until its lease lapsed -- the finished ones
    too -- and the pool then handed them out to be run again (TX-005). So
    the wave is treated like one whose wait ran out: the fleet is asked
    where each item got to (unless the wait had already finished), what has
    a result is collected, and the check-in then marks it done, puts back
    what never ran, and leaves only what is still running to its lease.

    A second Ctrl-C abandons this, which is safe: everything still held
    goes back when its lease lapses, as it always did.
    """
    log("")
    log("[tx] interrupted in wave %d. Finishing its bookkeeping before "
        "stopping: what ran is collected and checked in as done, what never "
        "ran goes back to the pool, and only what is still running is left "
        "to its lease (Ctrl-C again leaves the whole wave to its lease)"
        % wave)
    if wave_states is None:
        wave_states = _collect_status(Fleet(sub, args))
    unclean = False
    if not collected:
        ran = [h for h in sub.hosts if _has_result(wave_states[h])]
        if ran:
            part = slice_plan(sub, ran)
            cmd_collect(args, part)
            if args.clean:
                args.yes = True
                unclean = bool(cmd_clean(args, part))
    return wave_states, unclean


def run_from_muster(args, plan):
    """Cover a pool of work, X items at a time, checking each lot back in.

    One loop: take X, run them as a wave, and give them back -- items
    that ran are done, items nothing ran on are released for somebody
    else. It ends when the pool has nothing left to hand out.

    "Nothing left to hand out" is deliberately not "the pool is
    complete". Other workers may be holding the rest, and a sweep that
    waited around for them would be inventing a coordination problem the
    lease already solves. So this covers what it can get, and prints
    muster's own account of the pool at the end rather than claiming to
    know the job is finished.
    """
    states = {}
    trouble = []
    addrs = {}
    taken = []          # every item this sweep ran, in the order taken
    seen = set()
    # Items that were leased and never run: released in one go at the
    # end, not as they happen. Released immediately they would be
    # available again at once, and the very next take would hand the
    # same unreachable host straight back -- a sweep that never ends,
    # spinning on the one rack that is down.
    holding = []
    # Chosen once, before the first wave: the default is stamped with
    # the time, and a fresh directory per wave would scatter one sweep
    # across ten of them.
    args.dir = default_dir(args.dir)
    lease = muster_lease(args, plan)

    tmp = tempfile.mkdtemp(prefix="tx-muster-")
    ticket = os.path.join(tmp, "ticket.txt")
    handback = os.path.join(tmp, "handback.txt")
    log("[tx] drawing from the pool %s, %d at a time, lease %s -> %s/"
        % (args.muster, args.batch, lease, args.dir))
    wave = 0
    stopped = False     # a Ctrl-C ended the sweep after this wave
    leased = []         # items left still running, to their lease
    try:
        while True:
            _rc, _out = _muster(args, "take",
                                [str(args.batch), "-o", ticket,
                                 "--lease", lease])
            head, items = _ticket_parts(ticket)
            # An item we have already run coming back means its lease
            # lapsed mid-sweep and the pool offered it to us again.
            # Running it twice is exactly what the pool is for
            # preventing, so it is held rather than re-run, and goes
            # back with the rest at the end.
            again = [i for i in items if i in seen]
            fresh = [i for i in items if i not in seen]
            if again:
                log("[tx] %d item(s) came back with a lapsed lease; holding "
                    "them rather than running them a second time" % len(again))
                holding.append((head, again))
            # An item the pool hands out is not necessarily something ssh
            # can be pointed at: '-oProxyCommand=...' as a destination is
            # an option, and a '/' crashed the collection with the item
            # still held. Those are not run; they go back with the rest.
            unusable = [i for i in fresh
                        if host_problem(i, muster_addr(plan, i))]
            if unusable:
                for item in unusable:
                    log("[tx] not running pool item %r: it %s"
                        % (item, host_problem(item, muster_addr(plan, item))))
                holding.append((head, unusable))
                seen.update(unusable)
                trouble.append(0)
                fresh = [i for i in fresh if i not in set(unusable)]
                if not fresh:
                    continue
            if not fresh:
                if not items:
                    log("[tx] the pool has nothing available.")
                break

            wave += 1
            for item in fresh:
                addrs[item] = muster_addr(plan, item)
            seen.update(fresh)
            taken.extend(fresh)
            sub = _plan_over(plan, fresh, addrs)

            log("")
            log("[tx] === wave %d: %d item(s) from the pool: %s ==="
                % (wave, len(fresh), " ".join(fresh[:8])
                   + (" ..." if len(fresh) > 8 else "")))

            try:
                started = cmd_start(args, sub)
            except Interrupted as exc:
                # cmd_start stood the wave back down, or never armed it,
                # and said so: nothing ran on its items, bar any host it
                # could not stand down, whose item is left to its lease.
                stopped = True
                trouble.append(wave)
                for item in fresh:
                    states[item] = (False, None, "WAVE DID NOT START")
                holding.append((head, [i for i in fresh
                                       if i not in exc.left]))
                leased.extend(exc.left)
                break
            if started:
                # cmd_start has already stood this wave back down, so
                # nothing ran on any of them. They go back unfinished:
                # marking them done would report a benchmark that never
                # happened as a host that passed.
                trouble.append(wave)
                for item in fresh:
                    states[item] = (False, None, "WAVE DID NOT START")
                holding.append((head, fresh))
                if args.stop_on_fail:
                    log("[tx] --stop-on-fail: not taking any more from the "
                        "pool")
                    break
                continue

            wave_states = None
            collected = False
            unclean = False
            try:
                deadline = _wait_deadline(args, sub)
                wave_states, finished = _wait_for_fleet(
                    Fleet(sub, args), deadline, pinned=args.poll)
                # Recorded now, while the record is still on the hosts: the
                # collection below, and a --clean after it, are about to
                # take it away.
                states.update(wave_states)
                if not finished:
                    log("[tx] wave %d had hosts still running when the wait "
                        "ran out; collecting what there is" % wave)
                    trouble.append(wave)
                if cmd_collect(args, sub):
                    trouble.append(wave)
                collected = True
                if args.clean:
                    args.yes = True
                    # Counted, and the sweep goes on unless --stop-on-fail:
                    # the items ran either way, and are checked in below by
                    # what ran, not by whether the host was tidied after.
                    unclean = bool(cmd_clean(args, sub))
                    if unclean:
                        trouble.append(wave)
            except KeyboardInterrupt:
                # Ctrl-C: the wave is checked in below as if its wait had
                # run out, and then the sweep stops.
                stopped = True
                trouble.append(wave)
                wave_states, unclean = _muster_interrupted(
                    args, sub, wave, wave_states, collected)
                states.update(wave_states)
                finished = False

            # The check-in, and the whole judgement in this mode, in
            # three parts:
            #
            #   ran      -- the host has a run record. Done: the work
            #               happened, and a job that ran and failed is a
            #               measurement, not an item to hand to the next
            #               worker to fail identically.
            #   working  -- no record yet and the agent is still going.
            #               This is only reached on a wait that timed out;
            #               the agent is detached, so the work outlived
            #               the wait. Neither done nor released -- letting
            #               its lease expire is the one safe answer, since
            #               handing a still-running host to a second
            #               worker is the duplicate the pool exists to
            #               prevent.
            #   idle     -- reached, nothing running, no record. Never
            #               measured, so it goes back for somebody else.
            ran = [i for i in fresh
                   if _has_result(states.get(i, (False, None, "")))]
            done_set = set(ran)
            working = [i for i in fresh if i not in done_set
                       and _still_working(states.get(i, (False, None, "")))]
            work_set = set(working)
            idle = [i for i in fresh
                    if i not in done_set and i not in work_set]
            if ran:
                log("[tx] checking %d item(s) back in as done" % len(ran))
                if _check_in(args, handback, "done", head, ran):
                    trouble.append(wave)
            if working:
                log("[tx] leaving %d item(s) still running to their lease "
                    "rather than handing them out again" % len(working))
                leased.extend(working)
            if idle:
                holding.append((head, idle))
            if stopped:
                break
            if args.stop_on_fail and (unclean or not finished):
                log("[tx] --stop-on-fail: not taking any more from the pool")
                break

        # Everything that was leased and never measured, put back in one
        # go now that no further take can pick it up again.
        stranded = sum(len(items) for _h, items in holding)
        if stranded:
            log("")
            log("[tx] putting %d item(s) back: nothing ran on them"
                % stranded)
            for head, items in holding:
                if _check_in(args, handback, "release", head, items):
                    trouble.append(0)
    except KeyboardInterrupt:
        # Ctrl-C while tx talks to the pool, or a second one while a wave's
        # bookkeeping is being finished: nothing more is done, and whatever
        # this sweep still holds goes back when its lease lapses.
        log("")
        log("[tx] interrupted%s: the items this sweep still holds are left "
            "to their lease (%s), and go back to the pool when it lapses"
            % (" again" if stopped else "", lease))
        _next_steps([(_as_typed(args), "carry on: the pool is the record "
                      "of what is left")])
        raise Interrupted()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if not taken:
        log("[tx] nothing was taken, so nothing was run.")
        _muster(args, "status", [], quiet=False)
        return 1 if trouble else 0

    for item in taken:
        states.setdefault(item, (False, None, "NOT REACHED"))
    rc = render_summary(_plan_over(plan, taken, addrs), states, args,
                        waves=wave)
    log("[tx] results: %s/" % args.dir)
    # The pool's own last word, printed rather than paraphrased: how much
    # is left is muster's number, and a second opinion from tx -- which
    # has only ever seen what it was handed -- would be a worse one.
    log("")
    _rc, out = _muster(args, "status", [], quiet=False)
    sys.stdout.write(out)
    if stopped:
        log("")
        log("[tx] interrupted: the sweep stopped after wave %d" % wave)
        if leased:
            log("[tx] %d item(s) still running are left to their lease (%s): "
                "nothing more is done with them here, and once it lapses the "
                "pool hands them out again: %s"
                % (len(leased), lease, _hosts_line(leased)))
        _next_steps([(_as_typed(args), "carry on: the pool is the record "
                      "of what is left")])
        return 130
    return 1 if (rc or trouble) else 0



# ---------------------------------------------------------------------------
# export: a run as an overlay for the datacenter layout viewer
# ---------------------------------------------------------------------------
#
# The viewer (github.com/MartinGallagher-code/datacenter_visualization) draws
# a floor from a `.dc` layout and colours it from a results file: one sample
# per line,
#
#     <test>  <target>  <value>  [key=value ...]
#
# tab separated, append-only, with `!test` lines carrying each overlay's
# units and palette direction. `tx export >> results.tsv` after every run is
# the whole integration; `--json` writes the same samples as NDJSON for a
# pipeline rather than a person. It is the same file `mx` and iperf write, so
# a floor can carry a benchmark's timings beside the fabric's numbers.
#
# The numbers are the ones `tx summarize` reads: each host's own run record,
# by the report's own rules -- a blank is "not measured" and never zero, a
# host still running has no duration to export rather than a misleading one,
# and a host that never reported is said to be missing rather than counted as
# a pass. That is why this is an export and not somebody else's importer: the
# run record already knows what happened to each host, and this only recolours
# it onto the floor.

# (test, `!test` metadata). One sample per host, from each host's run record.
EXPORT_HOST_TESTS = [
    ("duration", 'unit=s higher=bad decimals=2 short=DUR label="Job wall-clock time"'),
    # Each host's runtime against the fleet's own median, on a diverging ramp
    # pinned at 0-200%: 100% is "normal for this fleet", so a slow outlier
    # reddens without anyone knowing what the job should take on this hardware.
    ("rel_median", 'unit=% higher=bad palette=rdbu min=0 max=200 agg=median decimals=0 short=REL label="Runtime vs fleet median"'),
    # tx's signature number: how far each host was from the instant they were
    # all armed for. It is what "they started together" means as a measurement
    # rather than a hope, so it belongs on the floor where a late rack shows.
    ("start_offset", 'unit=ms higher=bad decimals=1 short=SYNC label="Start offset from the armed instant"'),
    ("exit", 'higher=bad decimals=0 short=EXIT label="Job exit code"'),
    ("setup_exit", 'higher=bad decimals=0 short=SET label="Setup exit code"'),
    ("teardown_exit", 'higher=bad decimals=0 short=TDN label="Teardown exit code"'),
    ("timed_out", 'higher=bad min=0 max=1 decimals=0 short=TMO label="Hit the timeout"'),
    ("state", 'agg=last short=STATE label="How this host finished"'),
]

EXPORT_META = dict(EXPORT_HOST_TESTS)

# A results line is whitespace separated, and a double quote is how a value
# with a space in it is written -- so neither can appear inside a field.
BAD_IN_FIELD = ' \t\n\r"'


def pct(part, whole):
    """part as a percentage of whole, or None when whole is zero."""
    return 100.0 * part / whole if whole else None


def _median(values):
    ordered = sorted(values)
    n = len(ordered)
    if not n:
        return None
    mid = n // 2
    return ordered[mid] if n % 2 else (ordered[mid - 1] + ordered[mid]) / 2.0


def _fmt_num(value):
    """A number for a results file: four significant digits, fixed notation.
    `%g` would write a long runtime as 1.235e+04, which is correct and
    unreadable in a file people grep."""
    text = "%.4g" % value
    if "e" in text or "E" in text:
        text = "%.0f" % value
    return text


def _export_number(value):
    """A finite float, or None when the value is missing or not a number."""
    if value is None:
        return None
    try:
        num = float(value)
    except (TypeError, ValueError):
        return None
    if num != num or num in (float("inf"), float("-inf")):
        return None
    return num


def _meta_pairs(text):
    """`unit=s higher=bad label="Job time"` -> a dict, quotes removed."""
    pairs = {}
    for token in shlex.split(text):
        if "=" in token:
            key, value = token.split("=", 1)
            pairs[key] = value
    return pairs


def _load_names(path):
    """`--names`: tx host name -> the name the layout knows it by.

    One mapping per line, `txname target`, separated by whitespace or '='.
    Blank lines and '#' comments are ignored, and a host the file does not
    mention keeps its plan name -- so the file only carries the exceptions.
    """
    names = {}
    try:
        with open(path) as fh:
            for lineno, raw in enumerate(fh, 1):
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                parts = line.replace("=", " ").split()
                if len(parts) != 2:
                    die("%s line %d: want `txname target`, got %r"
                        % (path, lineno, line))
                names[parts[0]] = parts[1]
    except (IOError, OSError) as exc:
        die("cannot read %s: %s" % (path, exc))
    return names


class Overlay(object):
    """The results file being built: `!test` declarations, then samples.

    A test is declared the first time something is filed under it, so an
    overlay never appears in the file with no data behind it.
    """

    def __init__(self, test_prefix="tx_", target_prefix="", names=None,
                 run=None, meta_table=None):
        self.meta_table = EXPORT_META if meta_table is None else meta_table
        self.test_prefix = test_prefix
        self.target_prefix = target_prefix
        self.names = names or {}
        self.run = run
        self.meta = []          # [(test, "key=value ...")]
        self.samples = []       # [(test, target, value, [key=value ...])]
        self._declared = set()

    def target(self, host):
        """The layout's name for a tx host: mapped by --names, then prefixed
        by --target-prefix. The viewer resolves a bare name, a path, or any
        unique tail of a path, so `web01`, `R01/web01` and `DH1/A/R01/web01`
        can all land on the same node."""
        name = self.target_prefix + self.names.get(host, host)
        if not name or any(c in name for c in BAD_IN_FIELD):
            die("target %r: a results file is whitespace separated and quote "
                "aware, so a target can hold neither (host %r)" % (name, host))
        return name

    def add(self, test, host, value, extras=()):
        """File one sample. `None` is dropped: not measured is not zero."""
        if value is None:
            return
        if not isinstance(value, str):
            num = _export_number(value)
            if num is None:
                return
            value = _fmt_num(num)
        name = self.test_prefix + test
        if test not in self._declared:
            self._declared.add(test)
            meta = self.meta_table.get(test)
            if meta:
                self.meta.append((name, meta))
        extras = list(extras)
        if self.run:
            extras.append("run=%s" % self.run)
        self.samples.append((name, self.target(host), value, extras))

    def tsv_lines(self, with_meta=True):
        out = []
        if with_meta:
            for test, meta in self.meta:
                out.append("!test\t%s\t%s" % (test, meta))
        for test, target, value, extras in self.samples:
            out.append("\t".join([test, target, value] + extras))
        return out

    def json_lines(self, with_meta=True):
        """NDJSON: one object per line, so concatenating two runs is still a
        valid file -- which a top-level `[ ... ]` array would not be."""
        out = []
        if with_meta:
            for test, meta in self.meta:
                entry = {"!test": test}
                entry.update(_meta_pairs(meta))
                out.append(json.dumps(entry, sort_keys=True))
        for test, target, value, extras in self.samples:
            number = _export_number(value)
            entry = {"test": test, "target": target,
                     "value": value if number is None else number}
            if extras:
                entry["meta"] = _meta_pairs(" ".join(extras))
            out.append(json.dumps(entry, sort_keys=True))
        return out


# How a host's run record becomes the one categorical overlay. Every other
# overlay is a number that is either measured or not; this one is always
# knowable, because "we never heard from it" is itself an answer.
def _export_state(report, word):
    if report is None:
        # No record at all. The status word says why, and the difference
        # matters to whoever has to go and look: a host that was never
        # deployed is a plan that did not reach it, an unreachable one is a
        # network or a key.
        return {
            "NOT-DEPLOYED": "NOT-RUN",
            "NOT-RUNNING": "NOT-RUN",
            "NOT-STARTED-YET": "RUNNING",
            "UNREACHABLE": "UNREACHABLE",
        }.get(word, "NO-DATA")
    state = report.get("state")
    if state == "done":
        return "PASSED" if report.get("exit") == 0 else "FAILED"
    if state == "timeout":
        return "TIMEOUT"
    if state == "setup-failed":
        return "SETUP-FAILED"
    if state == "launch-failed":
        return "NEVER-RAN"
    # armed / running / setup / tidying: still going.
    return "RUNNING"


def _record_tag(name, host):
    """The tag in a collected record's file name, or None when `name` is not
    where `tx collect` puts `host`'s record.

    A collection also holds whatever the job wrote, flattened the same way,
    so a job's own `out/run.json` lands as `tag~host~out~run.json`. Only
    `tag~host~run.json` (or a lone `run.json`) is the agent's record; the
    rest is the job's, whatever it holds.
    """
    if name == REPORT_NAME:
        return ""
    suffix = FLAT_SEP + host + FLAT_SEP + REPORT_NAME
    if not name.endswith(suffix):
        return None
    tag = name[:-len(suffix)]
    if not tag or FLAT_SEP in tag:
        return None
    return tag


def _read_collected_reports(path, want_tag=None):
    """`--from DIR`: {host: report} from the run.json files a collection holds.

    `tx collect` writes each host's record as `tag~host~run.json`, so the
    records are already here -- export reads them rather than ssh'ing the
    fleet again. The host is taken from inside the record, and the file
    has to be where collect would have put that host's record, so a tag or
    a host with an unusual character cannot misfile a sample and a job's
    own file called run.json is not taken for one.

    The tag is what lets several runs share a directory, so a directory
    holding more than one is read for `want_tag` (the plan's) alone: taking
    whichever record sorted last mixed two runs' numbers into one export.
    """
    if not os.path.isdir(path):
        die("--from %s: not a directory (point it at a `tx collect` "
            "directory)" % path)
    by_tag = {}
    for name in sorted(os.listdir(path)):
        if not name.endswith(FLAT_SEP + REPORT_NAME) and name != REPORT_NAME:
            continue
        full = os.path.join(path, name)
        try:
            with open(full) as fh:
                report = json.load(fh)
        except (IOError, OSError, ValueError) as exc:
            sys.stderr.write("[tx] export: skipping %s: %s\n" % (name, exc))
            continue
        if not isinstance(report, dict):
            sys.stderr.write("[tx] export: skipping %s: not a run record "
                             "(JSON, but not an object)\n" % name)
            continue
        host = report.get("host")
        if not host or not isinstance(host, str):
            sys.stderr.write("[tx] export: %s has no host name, skipping\n"
                             % name)
            continue
        if not isinstance(report.get("state"), str):
            sys.stderr.write("[tx] export: skipping %s: no state field, so "
                             "not a run record\n" % name)
            continue
        tag = _record_tag(name, host)
        if tag is None:
            sys.stderr.write("[tx] export: skipping %s: not where tx collect "
                             "puts %s's record\n" % (name, host))
            continue
        by_tag.setdefault(tag, {})[host] = report
    if not by_tag:
        die("no run.json records in %s/ -- is it a `tx collect` directory?"
            % path, code=1)
    if len(by_tag) == 1:
        return list(by_tag.values())[0]
    tags = ", ".join(sorted(t or "(untagged)" for t in by_tag))
    if want_tag in by_tag:
        return by_tag[want_tag]
    die("%s/ holds the records of %d runs (tags: %s); export reads one -- "
        "give --plan the plan whose tag you mean"
        % (path, len(by_tag), tags))


def cmd_export(args):
    have_plan = os.path.isfile(args.plan)
    plan = load_plan(args.plan) if have_plan else None

    # {host: (report-or-None, word-or-None)}, and the host order to walk.
    entries = {}
    if args.from_dir:
        reports = _read_collected_reports(args.from_dir,
                                          plan.tag if plan else None)
        for host, report in reports.items():
            entries[host] = (report, None)
        # The plan, when there is one, is the roll call: a host it names that
        # the collection has no record of never made it back. It is not a
        # filter -- a --muster sweep runs items the plan never names, and
        # their records are as much the run's as any.
        hosts = sorted(reports)
        if plan:
            hosts = list(plan.hosts) + [h for h in hosts
                                        if h not in plan.addrs]
        for host in hosts:
            entries.setdefault(host, (None, "NO-DATA"))
    else:
        if plan is None:
            die("plan not found: %s -- export reads the fleet named in the "
                "plan; make one with `tx gen`, or read a collection with "
                "`tx export --from DIR`" % args.plan)
        seen = _collect_status(Fleet(plan, args))
        hosts = list(plan.hosts)
        for host in hosts:
            _alive, report, word = seen[host]
            entries[host] = (report, word)

    if args.run and any(c in args.run for c in BAD_IN_FIELD):
        die("--run %r: the label is written onto every sample line, so it "
            "can hold no whitespace or quotes" % args.run)
    if any(c in args.test_prefix for c in BAD_IN_FIELD):
        die("--test-prefix %r: it leads every test name in a whitespace "
            "separated file, so it can hold no whitespace or quotes"
            % args.test_prefix)

    out = Overlay(test_prefix=args.test_prefix,
                  target_prefix=args.target_prefix,
                  names=_load_names(args.names) if args.names else None,
                  run=args.run)

    # The fleet's own median runtime, which is what makes a host's time
    # readable without knowing the hardware. One host is not a fleet, and a
    # median of one would paint it a confident 100%.
    durations = []
    for host in hosts:
        report, _word = entries[host]
        if report is not None:
            d = _export_number(report.get("duration"))
            if d is not None and d > 0:
                durations.append(d)
    fleet_median = _median(durations) if len(durations) > 1 else None

    ran = 0
    for host in hosts:
        report, word = entries[host]
        out.add("state", host, _export_state(report, word))
        if report is None:
            continue
        ran += 1
        duration = _export_number(report.get("duration"))
        if duration is not None:
            out.add("duration", host, duration)
            if fleet_median and duration > 0:
                out.add("rel_median", host, pct(duration, fleet_median))
        offset = _export_number(report.get("start_offset"))
        if offset is not None:
            out.add("start_offset", host, offset * 1000.0)
        out.add("exit", host, _export_number(report.get("exit")))
        out.add("setup_exit", host, _export_number(report.get("setup_exit")))
        out.add("teardown_exit", host,
                _export_number(report.get("teardown_exit")))
        # Only meaningful once the job itself ran; before that "did it hit the
        # timeout" has no answer, so it is left unmeasured rather than 0.
        if report.get("state") in ("done", "timeout"):
            out.add("timed_out", host, 1.0 if report.get("timed_out") else 0.0)

    # Counted by host, not by sample: tx_state is written for every host,
    # record or not, so the samples are never empty and this refusal could
    # never fire -- a fleet with no record anywhere exported its NOT-RUN and
    # UNREACHABLE states and exited 0 (TX-006). A host that is down while
    # others have records is still exported, its state as data, and exit 0.
    if not ran:
        die("nothing to export -- none of the %d host(s) has a run record "
            "yet (tx status says why)" % len(hosts), code=1)

    missing = sorted(h for h in hosts if entries[h][0] is None)
    stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    tag = plan.tag if plan else (
        next((r.get("tag") for r, _w in entries.values() if r), "") or "tx")
    header = [
        "# tx %s export -- %s, %d host(s) with a record, %d sample(s)"
        % (VERSION, "[%s]" % tag, ran, len(out.samples)),
        "# read %s at %s"
        % ("collection %s" % args.from_dir if args.from_dir
           else "the fleet", stamp),
    ]
    if missing:
        header.append("# %d host(s) have no record (tx_state NO-DATA/NOT-RUN): "
                      "%s" % (len(missing), " ".join(missing[:8])))
    lines = (header +
             (out.json_lines(not args.no_meta) if args.json
              else out.tsv_lines(not args.no_meta)))

    stdout = args.output in ("-", "")
    if stdout:
        for line in lines:
            sys.stdout.write(line + "\n")
        sys.stdout.flush()
    else:
        try:
            with open(args.output, "a" if args.append else "w") as fh:
                for line in lines:
                    fh.write(line + "\n")
        except (IOError, OSError) as exc:
            die("cannot write %s: %s" % (args.output, exc))

    tests = sorted(set(t for t, _target, _v, _e in out.samples))
    sys.stderr.write("[tx] export: %d sample(s) over %d overlay(s) on %d "
                     "host(s) -> %s\n"
                     % (len(out.samples), len(tests), ran,
                        "stdout" if stdout else args.output))
    if missing:
        sys.stderr.write("[tx] export: %d host(s) have no record, so only "
                         "tx_state carries them (NO-DATA/NOT-RUN): %s\n"
                         % (len(missing), " ".join(missing[:8])))
    return 0



# ---------------------------------------------------------------------------
# gen, check, doctor
# ---------------------------------------------------------------------------

def cmd_gen(args):
    tokens = read_server_list(args.servers)
    seen = set()
    for tok in tokens:
        name, addr = parse_token(tok)
        if name is None:
            die("%s: cannot read host token %r" % (args.servers, tok))
        if name in seen:
            die("%s: %r is listed twice; a host's results would land on top "
                "of each other" % (args.servers, name))
        why = host_problem(name, addr)
        if why:
            die("%s: host %r %s" % (args.servers, tok, why))
        seen.add(name)

    if not args.run:
        die("--run is what every host will execute; there is no default")
    if args.payload and not os.path.exists(args.payload):
        die("--payload %s does not exist" % args.payload)
    if args.timeout <= 0:
        die("--timeout must be positive, got %g" % args.timeout)

    tag = clean_tag(args.tag) if args.tag else default_tag(args.run)
    write_plan(args.plan, tokens, args.run, args.setup or "",
               args.teardown or "", args.payload or "", args.timeout,
               args.collect or [], tag, args.remote_dir, args.stdin or "")
    if args.plan == "-":
        return 0
    log("[tx] %s: %d hosts, tag %r" % (args.plan, len(tokens), tag))
    log("[tx]   run: %s" % args.run)
    if args.payload:
        log("[tx]   payload: %s" % args.payload)
    log("[tx] next: tx doctor      # is the fleet ready?")
    log("[tx]       tx start       # deploy and run it everywhere")
    return 0


def cmd_check(args):
    """Everything that can be checked without touching the fleet."""
    plan = load_plan(args.plan)
    log("[tx] plan   %s: %d hosts, tag %r" % (plan.path, len(plan.hosts),
                                              plan.tag))
    log("[tx] run    %s" % plan.run)
    if plan.setup:
        log("[tx] setup  %s" % plan.setup)
    if plan.teardown:
        log("[tx] teardn %s" % plan.teardown)
    log("[tx] limit  %s per host" % fmt_secs(plan.timeout))

    problems = 0
    if plan.payload:
        if not os.path.exists(plan.payload):
            log("[tx] payload MISSING: %s" % plan.payload)
            problems += 1
        else:
            total, count = 0, 0
            if os.path.isdir(plan.payload):
                for root, _dirs, files in os.walk(plan.payload):
                    for f in files:
                        try:
                            total += os.path.getsize(os.path.join(root, f))
                            count += 1
                        except OSError:
                            pass
            else:
                total, count = os.path.getsize(plan.payload), 1
            log("[tx] payload %s: %d file(s), %s -- %s over the fleet"
                % (plan.payload, count, fmt_bytes(total),
                   fmt_bytes(total * len(plan.hosts))))
            if total > 256 << 20:
                log("[tx] that is a large payload to send to every host; "
                    "consider staging it once and fetching it in setup=")
    else:
        log("[tx] payload none -- the job must already be on the hosts")

    # A command that names a file the payload does not carry is the most
    # common way a fleet run fails on all forty hosts at once, so say so
    # here rather than after the deploy.
    first = plan.run.strip().split()[0] if plan.run.strip() else ""
    if first.startswith("./") and plan.payload:
        want = first[2:]
        have = (os.path.isdir(plan.payload)
                and os.path.exists(os.path.join(plan.payload, want)))
        if not have:
            log("[tx] run starts with %r, which is not in the payload -- the "
                "job would fail on every host" % first)
            problems += 1
    if plan.stdin:
        log("[tx] stdin   %s, fed to the job" % plan.stdin)
        if plan.payload and os.path.isdir(plan.payload) and not os.path.exists(
                os.path.join(plan.payload, plan.stdin)):
            log("[tx] stdin %r is not in the payload -- the job would find "
                "nothing to read on every host" % plan.stdin)
            problems += 1
    log("[tx] collect out/ and the run record, plus: %s"
        % (" ".join(plan.collect) if plan.collect else "(nothing extra)"))
    # The --remote-dir guard (TX-002) is a property of each host, which
    # this command does not contact; so it says what will be checked and
    # where the per-host answer is, and catches the one thing it can see.
    log("[tx] remote %s on each host: must be a real directory the ssh "
        "user owns, not writable by %s (tx doctor checks each host)"
        % (plan.remote_dir,
           "others (its group may: TX_ALLOW_SHARED_REMOTE_DIR=1)"
           if _env("TX_ALLOW_SHARED_REMOTE_DIR", "") == "1"
           else "group or others"))
    if problems:
        log("[tx] %d problem(s) above would break the run" % problems)
        return 1
    log("[tx] the plan looks runnable: tx doctor, then tx start")
    return 0


def cmd_doctor(args):
    plan = load_plan(args.plan)
    fleet = Fleet(plan, args)
    log("[tx] local checks")
    log("  python      %d.%d.%d" % sys.version_info[:3])
    for tool in ("ssh", "scp"):
        found = any(os.access(os.path.join(p, tool), os.X_OK)
                    for p in os.environ.get("PATH", "").split(os.pathsep) if p)
        log("  %-11s %s" % (tool, "found" if found else "MISSING"))
    log("  plan        %s: %d hosts, timeout %s"
        % (plan.path, len(plan.hosts), fmt_secs(plan.timeout)))

    # The --remote-dir is checked first, as start will check it (TX-002),
    # so a host whose directory start would refuse is not called ready, and
    # the refusal shows here rather than half way into a run. A refused
    # directory is not looked into: its agent.pid is not read.
    #
    # agent_running is this --remote-dir's agent, by the same test stop and
    # clean use: another run's agent on the host, or another user's, is
    # not this run still going. proc= says whether a lost agent.pid can be
    # traced -- without /proc, stop and clean refuse rather than guess.
    script = DIR_CHECK_FN + """
py=$({py} -V 2>&1 || echo 'MISSING python3')
bash=$(bash --version 2>/dev/null | head -1 || echo 'MISSING bash')
d={rdir}
_tx_shared={shared}
refused=""
here=""
if ! _tx_dir_check "$d"; then
    rd=REFUSED
    refused="REFUSED: --remote-dir $_tx_bad. {how}"
elif [ -d "$d" ]; then
    rd="ok($(ls -ld -- "$d" | cut -c1-10))"
    here=$(CDPATH= cd -- "$d" 2>/dev/null && pwd -P)
else
    rd="absent(start makes it, mode 700)"
fi
{probe}
running=no
if [ -n "$here" ]; then
    if [ -f "$d/{pid}" ] && tx_ours "$(cat "$d/{pid}" 2>/dev/null)"; then
        running=yes
    elif [ "$have_proc" = yes ]; then
        tx_scan
        [ -n "$tx_found" ] && running=yes
    fi
fi
free=$(df -Pk {parent} 2>/dev/null | awk 'NR==2{{print $4}}')
[ -z "$free" ] && free=$(df -Pk / 2>/dev/null | awk 'NR==2{{print $4}}')
echo "$py; cores=$(nproc 2>/dev/null || echo ?); free=${{free:-?}}KB; tar=$(command -v tar >/dev/null && echo yes || echo NO); pgrep=$(command -v pgrep >/dev/null && echo yes || echo 'no (clean cannot rule out a stray agent)'); proc=$([ "$have_proc" = yes ] && echo yes || echo 'no (a lost agent.pid cannot be traced)'); agent_running=$running; remote_dir=$rd"
if [ -n "$refused" ]; then echo "$refused"; exit 1; fi
""".format(py=shlex.quote(fleet.python),
           rdir=shlex.quote(_dir_path(fleet.dir)),
           parent=shlex.quote(os.path.dirname(fleet.dir) or "/"),
           pid=PID_NAME, probe=_probe(),
           shared="1" if fleet.shared else "0", how=REFUSED_HOW)
    log("")
    failed = fleet.each(lambda h: fleet.sh(h, script, timeout=30),
                        "checking hosts (ssh, python, bash, tar, pgrep, disk, "
                        "--remote-dir)")
    if failed:
        log("[tx] fix those hosts first: key-based ssh must work "
            "non-interactively (ssh-copy-id), `%s` must exist, and a "
            "--remote-dir marked REFUSED must be the ssh user's own."
            % fleet.python)
        return 1

    log("")
    log("[tx] checking the clocks, which is what a synchronised start "
        "depends on")
    if _report_skew(fleet, args):
        return 1
    log("[tx] fleet looks ready: tx start")
    return 0


# ---------------------------------------------------------------------------
# hints
# ---------------------------------------------------------------------------

HINTS = [
    ("run a benchmark on every host at once",
     "tx gen --servers servers.txt --payload ./bench --run ./bench.sh",
     "tx run",
     "gen writes plan.ini; run deploys, starts everywhere at one instant, "
     "waits, summarizes and collects."),
    ("ship a benchmark that has to be built first",
     "tx gen --servers servers.txt --payload ./src --setup 'make -s' "
     "--run ./bench",
     "tx run",
     "setup= runs on each host before the job, and a host whose setup "
     "fails does not run the job -- it says so instead of reporting a "
     "failure that was never the benchmark's."),
    ("get the results into one directory, named by host",
     "tx collect",
     "tx collect -d before-the-change",
     "everything under out/ plus each host's stdout, stderr and run "
     "record, named tag~host~path. -d names the directory; without it "
     "each collection gets one of its own, stamped with the time."),
    ("run the same job again and keep both sets",
     "tx gen ... --tag before && tx run",
     "tx gen ... --tag after && tx run -d results",
     "the tag leads every filename, so two runs can share one directory "
     "and still be told apart -- and `rm before~*` clears one of them."),
    ("check the fleet before committing to a long run",
     "tx check",
     "tx doctor",
     "check reads the plan and needs no ssh; doctor asks every host about "
     "python, bash, tar, disk and its clock."),
    ("find out why one host failed",
     "tx status",
     "tx collect && grep -l . *~stderr",
     "status gives exit codes without moving any files; the collection "
     "carries each host's stdout and stderr back under its own name."),
    ("stop a run that is going wrong",
     "tx stop",
     "tx clean",
     "stop kills this run's job -- never another run's beside it -- and "
     "leaves what it produced; clean removes what tx put on the hosts, and "
     "names anything else it finds there rather than deleting it."),
    ("run something on hosts where nothing is installed",
     "tx gen --servers servers.txt --run 'uname -a; free -m'",
     "tx run",
     "no payload is needed when the job is only what is already there. "
     "Python 3.6, bash and tar on each host is the whole requirement."),
    ("give the job its own idea of the fleet",
     "tx gen ... --run './shard.sh $TX_INDEX $TX_NHOSTS' --peers",
     "tx run",
     "every job gets TX_HOST, TX_INDEX, TX_NHOSTS, TX_OUT and TX_TAG; "
     "--peers adds TX_HOSTS, the whole list, for a job that shards work "
     "across the fleet."),
    ("run on a fleet bigger than what can run at once",
     "tx run --batch 20 -d results",
     "tx run --batch 20 --stop-on-fail",
     "a licence seat count, a filer, a power envelope: --batch covers the "
     "whole fleet a few hosts at a time, each wave armed for its own "
     "instant, everything landing in one directory. It is not --jobs, "
     "which is only how many ssh connections are open."),
    ("draw the work from a shared pool, once each, across many machines",
     "muster add 'web[01-40]' && tx run --muster --batch 10 -d results",
     "tx run --muster patching.csv --batch 10 --lease 2h -d results",
     "binnacle's muster hands items out under a lease and knows what is "
     "still outstanding; tx takes --batch of them, runs them as one wave, "
     "and checks them back in (done if they ran, released if nothing "
     "reached them) until the pool is empty. Several tx's can draw from "
     "one pool at once and never take the same item twice."),
    ("colour a floor plan with the run",
     "tx run -d results",
     "tx export >> results.tsv",
     "tx export writes the datacenter layout viewer's results file -- one "
     "sample per host: duration, exit, how far each host was from the armed "
     "instant, and a pass/fail state. Append after every run and the viewer "
     "aggregates the history; `tx export --from results` re-exports a "
     "collection without ssh."),
    ("run from a working directory a group shares on purpose",
     "tx gen ... --remote-dir /srv/bench/tx",
     "tx run --allow-shared-remote-dir",
     "tx refuses a --remote-dir that is a symlink, is not the ssh user's "
     "own, or that its group or others can write to: whoever can write "
     "there could swap the agent before it runs. --allow-shared-remote-dir "
     "(TX_ALLOW_SHARED_REMOTE_DIR=1) lets a group-writable one through; a "
     "world-writable one, a symlink or another user's is still refused. "
     "tx doctor shows each host's answer before a run."),
    ("prove the runs really were simultaneous",
     "tx summarize",
     "",
     "every agent records the instant it actually began; summarize "
     "reports the spread across the fleet. If it is wide, --start-in was "
     "too short or the clocks disagree."),
]


def cmd_hints(args):
    log("tx hints -- what you want, and the command that gets it")
    log("")
    for goal, first, second, why in HINTS:
        log("  %s" % goal)
        log("      %s" % first)
        if second:
            log("      %s" % second)
        for line in _wrap("      ", why):
            log(line)
        log("")
    log("  every switch of every command:  tx help")
    return 0


def _wrap(prefix, text, width=76):
    import textwrap
    return textwrap.wrap(text, width=width, initial_indent=prefix,
                         subsequent_indent=prefix) or [prefix + text]


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

USAGE = """\
testing-orchestrator (short name: tx) runs one job on every host at the
same instant and collects the results.

  %(prog)s gen --servers servers.txt --payload ./bench --run ./bench.sh
  %(prog)s run          # start, wait, summarize, collect

Options for one command:  %(prog)s CMD --help
Options for every command:  %(prog)s help
Goal-to-command examples:  %(prog)s hints"""


def _prog():
    """The name to show in help: `tx` when that is what was typed, the
    package's own name otherwise."""
    name = os.path.basename(sys.argv[0] or "")
    return "tx" if name == "tx" else "testing-orchestrator"

def _add_fleet_flags(p):
    p.add_argument("--plan", default=_env("TX_PLAN", DEFAULT_PLAN),
                   help="plan file (default: %(default)s)")
    p.add_argument("--user", default=_env("TX_USER", _env("SSH_USER", "")),
                   help="ssh user (default: your ssh config)")
    p.add_argument("--jobs", type=int,
                   default=int(_env("TX_JOBS", str(DEFAULT_JOBS))),
                   metavar="N",
                   help="ssh fan-out concurrency (default: %(default)s)")
    p.add_argument("--remote-dir", default=_env("TX_REMOTE_DIR", ""),
                   metavar="DIR",
                   help="working directory on each host (default: from "
                        "the plan)")
    p.add_argument("--allow-shared-remote-dir", action="store_true",
                   default=_env("TX_ALLOW_SHARED_REMOTE_DIR", "") == "1",
                   help="let --remote-dir be group-writable, for a directory "
                        "a group shares on purpose")
    p.add_argument("--python", default=_env("TX_PYTHON", "python3"),
                   help="python on the hosts (default: %(default)s)")
    p.add_argument("--ssh", default=_env("TX_SSH", "ssh"),
                   help=argparse.SUPPRESS)
    p.add_argument("--scp", default=_env("TX_SCP", "scp"),
                   help=argparse.SUPPRESS)
    p.add_argument("--dry-run", action="store_true",
                   help="print the ssh/scp commands instead of running them")


def _add_start_flags(p):
    p.add_argument("--start-in", type=float, default=DEFAULT_START_IN,
                   metavar="S",
                   help="arm the start this many seconds ahead (default: "
                        "%(default)s, more for big fleets)")
    p.add_argument("--max-skew", type=float, default=DEFAULT_MAX_SKEW,
                   metavar="S",
                   help="max clock difference allowed (default: "
                        "%(default)s)")
    p.add_argument("--no-skew-check", action="store_true",
                   help="start without asking the fleet what time it is")
    p.add_argument("--no-deploy", action="store_true",
                   help="start what is already on the hosts, copy nothing")
    p.add_argument("--peers", action="store_true",
                   help="put the whole host list in $TX_HOSTS for the job")


def _add_collect_flags(p):
    p.add_argument("-d", "--dir", default=_env("TX_DIR", ""), metavar="DIR",
                   help="where results land (default: tx-<timestamp>)")
    p.add_argument("--timeout", type=float, default=900.0, metavar="S",
                   help="per-host limit on the transfer (default: "
                        "%(default)s)")
    p.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES,
                   metavar="N",
                   help="skip files larger than N bytes (default: %d, "
                        "0 = no limit)" % DEFAULT_MAX_BYTES)
    p.add_argument("--csv", metavar="PATH", nargs="?", const="-",
                   help="also write one row per collected file")
    p.add_argument("--quiet", action="store_true",
                   help="no file listing, just the findings")


def build_parser():
    prog = _prog()
    ap = argparse.ArgumentParser(
        prog=prog, description=USAGE % {"prog": prog},
        formatter_class=lambda prog: argparse.RawDescriptionHelpFormatter(
            prog, max_help_position=30))
    ap.add_argument("--version", action="version",
                    version="testing-orchestrator %s\n"
                            "Copyright (C) 2026 Martin J. Gallagher\n"
                            "License: GPL-3.0-or-later "
                            "<https://www.gnu.org/licenses/gpl-3.0.html>\n"
                            "This is free software: you are free to change "
                            "and redistribute it.\n"
                            "There is no warranty, to the extent permitted "
                            "by law." % VERSION)
    sub = ap.add_subparsers(dest="cmd", metavar="COMMAND")

    g = sub.add_parser("gen", help="build plan.ini from a server list")
    g.add_argument("--servers", default=_env("TX_SERVERS", DEFAULT_SERVERS),
                   help="one host per line: name[=addr] (default: "
                        "%(default)s)")
    g.add_argument("--plan", default=_env("TX_PLAN", DEFAULT_PLAN),
                   help="where to write it, or - for stdout (default: "
                        "%(default)s)")
    g.add_argument("--run", metavar="CMD",
                   help="the command every host runs, under bash")
    g.add_argument("--setup", metavar="CMD",
                   help="run on each host before the job")
    g.add_argument("--teardown", metavar="CMD",
                   help="run on each host after the job, pass or fail")
    g.add_argument("--payload", metavar="PATH",
                   help="file or directory to ship to every host")
    g.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                   metavar="S",
                   help="seconds before a host's job is killed (default: "
                        "%(default)s)")
    g.add_argument("--stdin", metavar="NAME",
                   help="file (in the payload) to feed the job on stdin")
    g.add_argument("--collect", action="append", metavar="GLOB",
                   help="extra files to collect, repeatable")
    g.add_argument("--tag", metavar="NAME",
                   help="prefix for collected filenames")
    g.add_argument("--remote-dir", default=_env("TX_REMOTE_DIR",
                                                DEFAULT_REMOTE_DIR),
                   metavar="DIR",
                   help="working directory on each host (default: "
                        "%(default)s)")

    c = sub.add_parser("check", help="will this plan work? no ssh")
    c.add_argument("--plan", default=_env("TX_PLAN", DEFAULT_PLAN),
                   help="plan file (default: %(default)s)")

    d = sub.add_parser("doctor", help="is the fleet ready?")
    _add_fleet_flags(d)
    d.add_argument("--max-skew", type=float, default=DEFAULT_MAX_SKEW,
                   metavar="S", help="clock tolerance (default: %(default)s)")

    s = sub.add_parser("start", help="deploy and start everywhere at once")
    _add_fleet_flags(s)
    _add_start_flags(s)

    st = sub.add_parser(
        "status", help="one line per host",
        epilog="exit status: 1 if any host is FAILED, TIMEOUT, SETUP-FAILED, "
               "NEVER RAN or GONE, or could not be read (UNREACHABLE, "
               "REFUSED, NO-ANSWER); 0 while the rest are running, passed, "
               "or have nothing there yet. --watch exits with what its last "
               "look found.")
    _add_fleet_flags(st)
    st.add_argument("--watch", type=float, nargs="?", const=2.0, metavar="S",
                    help="repeat every S seconds (default: 2)")

    co = sub.add_parser("collect", help="bring the results back")
    _add_fleet_flags(co)
    _add_collect_flags(co)

    su = sub.add_parser("summarize", help="who passed, who was slow")
    _add_fleet_flags(su)
    su.add_argument("--top", type=int, default=10, metavar="N",
                    help="hosts to name in each finding (default: "
                         "%(default)s)")

    sp = sub.add_parser("stop", help="stop this run's job, keep what it made")
    _add_fleet_flags(sp)

    lg = sub.add_parser("logs", help="collect the agents' own logs")
    _add_fleet_flags(lg)
    lg.add_argument("-d", "--dir", default="", metavar="DIR",
                    help="where they land (default: a tx-<timestamp>)")

    cl = sub.add_parser("clean", help="stop, then delete what tx put there")
    _add_fleet_flags(cl)
    cl.add_argument("--yes", action="store_true",
                    help="do not ask for confirmation")

    r = sub.add_parser("run", help="start, wait, summarize and collect")
    _add_fleet_flags(r)
    _add_start_flags(r)
    _add_collect_flags(r)
    r.add_argument("--top", type=int, default=10, metavar="N",
                   help=argparse.SUPPRESS)
    r.add_argument("--clean", action="store_true",
                   help="also tx clean once the results are back")
    r.add_argument("-b", "--batch", type=int, default=None, metavar="N",
                   help="run N hosts at a time, in waves")
    r.add_argument("--resume", action="store_true",
                   help="with --batch and the sweep's -d, skip hosts that "
                        "already have that sweep's result")
    r.add_argument("--muster", nargs="?",
                   const=_env("MUSTER_POOL", "muster.csv"), default=None,
                   metavar="POOL",
                   help="take hosts from a muster pool, --batch at a time "
                        "(default: muster.csv)")
    r.add_argument("--muster-cmd", default=_env("TX_MUSTER", ""),
                   metavar="CMD",
                   help="how to invoke muster (default: muster)")
    r.add_argument("--lease", default="", metavar="DUR",
                   help="with --muster, lease length, e.g. 30m, 2h, 90")
    r.add_argument("--poll", type=float, default=None, metavar="S",
                   help="seconds between status checks (default: 2 "
                        "backing off to 30)")
    r.add_argument("--stop-on-fail", action="store_true",
                   help="with --batch, stop after a failed wave")

    ex = sub.add_parser(
        "export", help="write results for the layout viewer",
        epilog="exit status: 1 if no host has a run record, and nothing is "
               "written. A host that is down is exported as UNREACHABLE and "
               "does not change the exit.")
    _add_fleet_flags(ex)
    ex.add_argument("--from", dest="from_dir", metavar="DIR",
                    help="read a collected directory instead of the fleet")
    ex.add_argument("-o", "--output", default="-", metavar="FILE",
                    help="results file to write ('-' for stdout, the default)")
    ex.add_argument("--append", action="store_true",
                    help="append to --output instead of replacing it")
    ex.add_argument("--json", action="store_true",
                    help="write NDJSON instead of TSV")
    ex.add_argument("--names", metavar="FILE",
                    help="host name map, one `txname target` per line")
    ex.add_argument("--target-prefix", default="", metavar="STR",
                    help="prefix for every target, e.g. 'DH1/A/'")
    ex.add_argument("--test-prefix", default="tx_", metavar="STR",
                    help="prefix for every test name (default: %(default)s)")
    ex.add_argument("--run", metavar="LABEL",
                    help="tag every sample with run=LABEL")
    ex.add_argument("--no-meta", action="store_true",
                    help="do not write the !test metadata lines")

    sub.add_parser("hints", help="a goal, and the command that gets it")
    sub.add_parser("help", help="every command and its options")

    a = sub.add_parser("agent", help=argparse.SUPPRESS)
    a.add_argument("--host", required=True)
    a.add_argument("--at", type=float, required=True,
                   help="unix time to begin at")
    a.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    a.add_argument("--tag", default="tx")
    a.add_argument("--run-id", dest="run_id", default="")
    a.add_argument("--index", type=int, default=0)
    a.add_argument("--nhosts", type=int, default=1)
    a.add_argument("--run", required=True, help="base64 of the command")
    a.add_argument("--setup", default="")
    a.add_argument("--teardown", default="")
    a.add_argument("--stdin", default="")
    a.add_argument("--peers", default="")
    # Internal: what `tx start` runs on each host, not for people.
    sub._choices_actions = [c for c in sub._choices_actions
                            if c.dest != "agent"]
    return ap


def cmd_full_help(ap):
    """`tx help`: every command and its options, one line each, generated
    from the real parsers so it cannot drift from what the code accepts."""
    sub_action = next(a for a in ap._actions
                      if isinstance(a, argparse._SubParsersAction))
    helps = {c.dest: c.help for c in sub_action._choices_actions}
    common = argparse.ArgumentParser(add_help=False)
    _add_fleet_flags(common)
    shared = set(o for a in common._actions for o in a.option_strings)

    def rows(actions):
        for a in actions:
            if a.help == argparse.SUPPRESS or "-h" in a.option_strings:
                continue
            name = ", ".join(a.option_strings)
            if a.nargs != 0:
                name += " " + (a.metavar or a.dest.upper())
            yield "    %-22s %s" % (name, (a.help or "") % vars(a))

    log("usage: %s COMMAND [options]" % ap.prog)
    log("")
    log("fleet options, taken by every command that talks to the hosts:")
    for line in rows(common._actions):
        log(line)
    for name, parser in sub_action.choices.items():
        if name not in helps or name == "help":
            continue
        log("")
        log("%s %-10s %s" % (ap.prog, name, helps[name]))
        own = [a for a in parser._actions
               if not shared.intersection(a.option_strings)
               or name in ("gen", "check")]
        for line in rows(own):
            log(line)
    log("")
    log("the job runs with: TX_HOST TX_OUT TX_TAG TX_RUN_ID TX_INDEX "
        "TX_NHOSTS")
    log("                   TX_HOSTS (with --peers) TX_SWEEP_ID (with "
        "--batch, not --muster)")
    log("flag defaults from: TX_PLAN TX_SERVERS TX_REMOTE_DIR TX_DIR TX_USER "
        "TX_JOBS")
    log("                    TX_PYTHON TX_MUSTER MUSTER_POOL "
        "TX_ALLOW_SHARED_REMOTE_DIR=1")
    return 0


COMMANDS = {
    "gen": cmd_gen, "check": cmd_check, "doctor": cmd_doctor,
    "start": cmd_start, "status": cmd_status, "collect": cmd_collect,
    "summarize": cmd_summarize, "stop": cmd_stop, "logs": cmd_logs,
    "clean": cmd_clean, "run": cmd_run, "hints": cmd_hints,
    "export": cmd_export, "agent": cmd_agent,
}


def main(argv=None):
    ap = build_parser()
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_help()
        return 2
    if args.cmd == "help":
        return cmd_full_help(ap)
    # A wave of nought hosts never ends and a wave of minus three is not a
    # number of hosts, so neither is quietly read as "all of them".
    if getattr(args, "batch", None) is not None and args.batch < 1:
        die("--batch is how many hosts run at once, so it wants at least 1, "
            "got %d (leave it out to run the whole fleet together)"
            % args.batch)
    if getattr(args, "max_bytes", 0) < 0:
        die("--max-bytes is a size, so it cannot be negative; got %d "
            "(0 means no ceiling)" % args.max_bytes)
    if getattr(args, "poll", None) is not None and args.poll <= 0:
        die("--poll is how many seconds to wait between status checks, so "
            "it wants a positive number, got %g (leave it out to let it "
            "back off on its own)" % args.poll)
    if getattr(args, "resume", False) and getattr(args, "batch", None) is None:
        die("--resume picks up a --batch sweep where it stopped; without "
            "--batch there are no waves to resume")
    if (getattr(args, "stop_on_fail", False)
            and getattr(args, "batch", None) is None
            and getattr(args, "muster", None) is None):
        die("--stop-on-fail is about the waves --batch makes; without it "
            "there is only one wave and nothing to stop")
    if getattr(args, "muster", None) is not None:
        if getattr(args, "batch", None) is None:
            die("--muster draws the work a wave at a time, so it needs "
                "--batch N to say how many items each wave takes from the "
                "pool")
        if getattr(args, "resume", False):
            die("--muster and --resume do not go together: the pool is "
                "already the record of what is left, so a muster sweep "
                "resumes itself -- just run it again")
    elif getattr(args, "lease", ""):
        die("--lease sets how long a --muster wave holds its items; "
            "without --muster there is no pool and no lease to set")
    # Without -d the collection directory is a new tx-<timestamp>, which no
    # sweep has collected into and which holds no sweep's id.
    if getattr(args, "resume", False) and not getattr(args, "dir", ""):
        die("--resume picks up the sweep collecting into -d DIR, which "
            "holds that sweep's id: give the -d the sweep was started with")
    # As typed, for the commands a Ctrl-C suggests running next.
    args.argv = list(sys.argv[1:] if argv is None else argv)
    try:
        return COMMANDS[args.cmd](args) or 0
    except Interrupted:
        # Already said what it left running and what to type next.
        return 130
    except KeyboardInterrupt:
        log("")
        log("[tx] interrupted")
        return 130


if __name__ == "__main__":
    sys.exit(main())
