#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# Mutation checks: each fix, taken back out of a copy of tx.py, makes the
# test written for it fail. A regression test that still passes with its
# fix reverted proves nothing, so every fix in TX-001 (stop, clean, doctor
# and status act only on this run's own agent and files) is checked here
# the same way: revert it, run its test against the copy, and see that
# test FAIL by name.
#
# A mutation that no longer matches tx.py exactly once fails loudly
# rather than testing nothing: when the code moves, move the mutation.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# The mutations are tx.py's own text, $-signs and all, so they are quoted
# literally on purpose: SC2016's warning is the point here.
# shellcheck disable=SC2016

# Each check runs a whole test (some wait out a ten-second kill), so the
# per-test limit is wider than the suite's usual minute.
: "${TX_TEST_TIMEOUT:=240}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# mutant OLD NEW -- $TEST_TMPDIR/mutant/tx.py: tx.py with OLD, which must
# occur exactly once, replaced by NEW.
mutant() {
    mkdir -p "$TEST_TMPDIR/mutant"
    python3 - "$TX" "$TEST_TMPDIR/mutant/tx.py" "$1" "$2" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src).read()
n = text.count(old)
if n != 1:
    sys.stderr.write("the mutation matches %d times in tx.py, not once: "
                     "the code has moved, so move the mutation\n" % n)
    sys.exit(3)
open(dst, "w").write(text.replace(old, new))
PY
}

# Some reverted fixes are the old code, which called pgrep and pkill. An
# image with no procps (CI's python:3.6-slim) would make those calls
# no-ops and hide the very bug, so stand them in from /proc there.
procps_stand_in() {
    command -v pkill > /dev/null 2>&1 && return 0
    local dir="$TEST_TMPDIR/procps"
    mkdir -p "$dir"
    cat > "$dir/pgrep" <<'PY'
#!/usr/bin/env python3
"""pgrep/pkill [-SIG] [-f] [-u UID] [-P PPID] PATTERN, read from /proc."""
import os, re, signal, sys
prog = os.path.basename(sys.argv[0])
sig, full, uid, ppid, pattern = signal.SIGTERM, False, None, None, None
args = sys.argv[1:]
i = 0
while i < len(args):
    a = args[i]
    if a == "-f":
        full = True
    elif a in ("-u", "-P"):
        i += 1
        if a == "-u":
            uid = args[i]
        else:
            ppid = args[i]
    elif prog == "pkill" and a.startswith("-") and len(a) > 1:
        name = a[1:]
        sig = int(name) if name.isdigit() else getattr(signal, "SIG" + name)
    else:
        pattern = a
    i += 1
found = []
for p in os.listdir("/proc"):
    if not p.isdigit() or int(p) == os.getpid():
        continue
    try:
        with open("/proc/%s/cmdline" % p, "rb") as fh:
            cmd = fh.read().replace(b"\0", b" ").decode("utf-8", "replace")
        with open("/proc/%s/stat" % p) as fh:
            stat = fh.read()
        owner = os.stat("/proc/%s" % p).st_uid
    except (IOError, OSError):
        continue
    comm, rest = stat.split("(", 1)[1].rsplit(")", 1)
    fields = rest.split()
    if fields[0] == "Z":
        continue
    if ppid is not None and fields[1] != ppid:
        continue
    if uid is not None and str(owner) != uid:
        continue
    if pattern is not None and not re.search(pattern, cmd if full else comm):
        continue
    found.append(int(p))
for p in found:
    if prog == "pgrep":
        print(p)
    else:
        try:
            os.kill(p, sig)
        except OSError:
            pass
sys.exit(0 if found else 1)
PY
    chmod +x "$dir/pgrep"
    ln -s pgrep "$dir/pkill"
    export PATH="$dir:$PATH"
}

# caught FILE LABEL... -- run those tests of FILE against the mutant, and
# each must FAIL. Matching "FAIL  label" rather than the exit status: a
# label that no longer exists would run nothing and exit 0, and a test
# that broke for some other reason must not pass for this one.
caught() {
    local file="$1"; shift
    local only out label
    only="$(IFS='|'; echo "$*")"
    out="$(TX="$TEST_TMPDIR/mutant/tx.py" TX_TEST_ONLY="$only" \
           bash "$REPO_ROOT/tests/$file" 2>&1)"
    for label in "$@"; do
        assert_contains "$out" "FAIL  $label" \
            "with the fix reverted, \"$label\" should fail"
    done
}

# ---- only this run's agent -------------------------------------------------

m_stop_waits_on_any_agent() {
    # The bug as it was: wait on *any* `tx.py agent`, then pkill -KILL
    # them all -- the other run's included.
    procps_stand_in
    mutant '        while :; do
            left=""
            for p in $targets; do tx_ours "$p" && left="$left $p"; done
            [ -z "$left" ] && break
            [ "$i" -ge 20 ] && break
            sleep 0.5
            i=$((i+1))
        done
        if [ -n "$left" ]; then' '        while [ "$i" -lt 20 ]; do
            pgrep -f '"'"'[t]x[.]py agent'"'"' >/dev/null 2>&1 || break
            sleep 0.5
            i=$((i+1))
        done
        left=""
        if pgrep -f '"'"'[t]x[.]py agent'"'"' >/dev/null 2>&1; then
            pkill -KILL -f '"'"'[t]x[.]py agent'"'"' 2>/dev/null' || return 1
    caught test_fleet.sh "two runs: stop leaves the other"
}

m_a_live_pid_is_trusted() {
    # agent.pid trusted on `kill -0` alone, as the kill block had it.
    #
    # The pid file's own check, and not tx_ours itself: tx_scan puts every
    # pid on the machine to tx_ours, so a tx_ours that says yes to any live
    # pid makes a lost pid file "kill everything" -- pid 1 included, which
    # on a test runner is the whole container. No mutation here may widen
    # what tx_ours accepts.
    mutant '    if tx_ours "$pid"; then
        targets=$pid' '    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        targets=$pid' || return 1
    caught test_fleet.sh "a stale agent.pid is not trusted"
}

m_a_lost_pid_file_is_not_searched() {
    mutant '        tx_scan
        targets=$tx_found' '        targets=""' || return 1
    caught test_fleet.sh "two runs: lost pid file"
}

m_without_proc_kill_by_name() {
    procps_stand_in
    mutant '        if [ "$found" -eq 0 ]; then
            refused="REFUSED: $d has no {pid} and' '        if [ "$found" -eq 0 ]; then
            pkill -TERM -f '"'"'[t]x[.]py agent'"'"'
            status=stopped
        elif false; then
            refused="REFUSED: $d has no {pid} and' || return 1
    caught test_fleet.sh "no /proc: lost pid file refused"
}

m_any_agent_is_a_leftover() {
    mutant '        for p in $mine; do tx_ours "$p" && left="$left $p"; done' \
           '        for p in $mine; do left="$left $p"; done' || return 1
    caught test_fleet.sh "two runs: clean is clean"
}

m_doctor_counts_any_agent() {
    mutant 'running=no
if [ -n "$here" ]; then' 'running=no
pgrep -f '"'"'[t]x[.]py agent'"'"' >/dev/null 2>&1 && running=yes
if [ -n "$here" ]; then' || return 1
    caught test_fleet.sh "two runs: doctor sees its own"
}

# ---- clean deletes only what tx put there ---------------------------------

m_clean_deletes_anything() {
    # Everything in the directory counted as tx's: `rm -rf "$d"` again.
    mutant '        tx_own() {{
' '        tx_own() {{
            return 0
' || return 1
    caught test_fleet.sh "clean spares a stranger's file" \
                         "clean spares a directory not made"
}

m_deploy_claims_what_was_there() {
    # The deploy recording every payload name, there before it or not.
    mutant '    [ -e "$n" ] || [ -L "$n" ] || printf '"'"'%%s\\n'"'"' "$n" >> %s' \
           '    printf '"'"'%%s\\n'"'"' "$n" >> %s' || return 1
    caught test_fleet.sh "clean spares a directory not made"
}

m_the_agent_records_nothing() {
    # Without the agent's record, what the job made is a stranger's.
    mutant '        new = sorted(n for n in _entries(workdir) - before - own' \
           '        new = [] and sorted(n for n in _entries(workdir) - before - own' \
        || return 1
    caught test_fleet.sh "clean takes what the run made"
}

# ---- run --clean says when its clean failed --------------------------------

m_run_ignores_its_clean() {
    mutant '        cleaned = cmd_clean(args, plan)' \
           '        cmd_clean(args, plan)' || return 1
    caught test_fleet.sh "run --clean that fails says so"
}

m_waves_ignore_their_clean() {
    mutant '            unclean = bool(cmd_clean(args, sub))
            if unclean:
                trouble.append(n)' '            cmd_clean(args, sub)' || return 1
    caught test_waves.sh "an uncleaned wave is counted" \
                         "stop-on-fail stops at an unclean"
}

m_muster_ignores_its_clean() {
    mutant '                unclean = bool(cmd_clean(args, sub))
                if unclean:
                    trouble.append(wave)' '                cmd_clean(args, sub)' \
        || return 1
    caught test_muster.sh "an uncleaned wave is counted"
}

echo "mutations"
run_test "stop waiting on any agent is caught"  m_stop_waits_on_any_agent
run_test "trusting a live pid is caught"        m_a_live_pid_is_trusted
run_test "not searching for it is caught"       m_a_lost_pid_file_is_not_searched
run_test "no /proc, kill by name is caught"     m_without_proc_kill_by_name
run_test "any agent a leftover is caught"       m_any_agent_is_a_leftover
run_test "doctor counting any agent is caught"  m_doctor_counts_any_agent
run_test "clean deleting anything is caught"    m_clean_deletes_anything
run_test "deploy claiming all is caught"        m_deploy_claims_what_was_there
run_test "an agent recording nothing is caught" m_the_agent_records_nothing
run_test "run ignoring its clean is caught"     m_run_ignores_its_clean
run_test "waves ignoring clean is caught"       m_waves_ignore_their_clean
run_test "muster ignoring clean is caught"      m_muster_ignores_its_clean
report_tests
