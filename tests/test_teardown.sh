#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# The suite's own teardown: after each test it stops any agent that test
# left running, and only those. It used to `pkill -f` every tx agent on
# the machine, so two suites at once, or a suite beside a real tx, killed
# each other's agents mid-test (TX-010; it cost TX-004 a contaminated
# reproduction).
#
# The agents here are stand-ins: a script called tx.py that only sleeps,
# run as `python3 tx.py agent --host NAME`, which is what the teardown
# looks for. Nothing here can touch a real agent: the new teardown only
# reaches agents under the directory it is given, and the reverted one is
# run against a pkill that signals these stand-ins and nothing else.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# Each teardown below runs in a ( ) subshell with its own $TEST_TMPDIR,
# so that it can never remove this test's directory: the change being
# local to the subshell is SC2030/SC2031's warning, and the point.
# shellcheck disable=SC2030,SC2031
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# stand_in DIR -- start a stand-in agent working in DIR; echoes its pid.
stand_in() {
    mkdir -p "$1"
    printf 'import time\ntime.sleep(60)\n' > "$1/tx.py"
    (cd "$1" && exec python3 tx.py agent --host stand-in) > /dev/null 2>&1 &
    local pid=$! i=0
    # Until the exec has happened, its command line is this shell's.
    while [ "$i" -lt 50 ] && ! tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null \
            | grep -q 'tx[.]py agent'; do
        sleep 0.1
        i=$((i + 1))
    done
    echo "$pid"
}

# alive PID -- running, and not a zombie waiting to be reaped.
alive() {
    kill -0 "$1" 2>/dev/null \
        && ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$1/status" 2>/dev/null
}

# gone PID -- wait up to three seconds for it to stop.
gone() {
    local i=0
    while [ "$i" -lt 30 ]; do
        alive "$1" || return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# torn_down HELPER -- one stand-in under a test's directory and one under
# somebody else's, then that test's teardown_env, as HELPER defines it.
# Sets MINE and THEIRS to their pids; the caller judges what survived.
torn_down() {
    local helper="$1" run="$TEST_TMPDIR/run"
    OTHER="$(mktemp -d "${TMPDIR:-/tmp}/tx-other-run-XXXXXX")"
    MINE="$(stand_in "$run/hosts/web01")"
    THEIRS="$(stand_in "$OTHER/hosts/web01")"
    # shellcheck disable=SC1090
    (source "$helper"; TEST_TMPDIR="$run"; teardown_env)
}

# Stop the stand-ins, whatever the teardown did, and remove the other run.
tidy_stand_ins() {
    kill "$MINE" "$THEIRS" 2>/dev/null
    wait "$MINE" "$THEIRS" 2>/dev/null
    rm -rf "$OTHER"
}

t_teardown_stops_only_its_own_agents() {
    [ -d /proc ] || { echo "    (no /proc: nothing to check)"; return 0; }
    torn_down "$REPO_ROOT/tests/test_helper.bash"
    gone "$MINE" || fail "the test's own agent was left running"
    alive "$THEIRS" || fail "another run's agent was killed"
    assert_no_file "$TEST_TMPDIR/run" "the test's directory was not removed"
    tidy_stand_ins
}

t_teardown_with_no_test_dir_stops_nothing() {
    # An unset $TEST_TMPDIR is nobody's: never "everything".
    [ -d /proc ] || { echo "    (no /proc: nothing to check)"; return 0; }
    OTHER="$(mktemp -d "${TMPDIR:-/tmp}/tx-other-run-XXXXXX")"
    MINE="$(stand_in "$TEST_TMPDIR/run")"
    THEIRS="$(stand_in "$OTHER/w")"
    (TEST_TMPDIR=""; teardown_env)
    (unset TEST_TMPDIR; teardown_env)
    kill_agents_under /
    sleep 0.3
    alive "$MINE" || fail "an empty test directory killed an agent"
    alive "$THEIRS" || fail "/ killed an agent"
    tidy_stand_ins
}

# A pkill that matches as procps does, but signals only the stand-ins
# listed in $TEST_TMPDIR/stand-ins: the reverted teardown below is the
# bug itself, and must not reach a real agent while it shows it.
safe_pkill() {
    local dir="$TEST_TMPDIR/procps"
    mkdir -p "$dir"
    cat > "$dir/pkill" <<'PY'
#!/usr/bin/env python3
import os, re, signal, sys
pattern = [a for a in sys.argv[1:] if not a.startswith("-")][-1]
allowed = set(open(os.environ["STAND_INS"]).read().split())
for p in os.listdir("/proc"):
    if not p.isdigit():
        continue
    try:
        with open("/proc/%s/cmdline" % p, "rb") as fh:
            cmd = fh.read().replace(b"\0", b" ").decode("utf-8", "replace")
    except (IOError, OSError):
        continue
    if re.search(pattern, cmd) and p in allowed:
        os.kill(int(p), signal.SIGTERM)
PY
    chmod +x "$dir/pkill"
    export PATH="$dir:$PATH" STAND_INS="$TEST_TMPDIR/stand-ins"
}

m_the_old_teardown_kills_every_agent() {
    # The fix reverted in a copy of the helper: kill by name alone. The
    # test above, run against it, must see the other run's agent die.
    [ -d /proc ] || { echo "    (no /proc: nothing to check)"; return 0; }
    local mutant="$TEST_TMPDIR/mutant/test_helper.bash"
    mkdir -p "$(dirname "$mutant")"
    python3 - "$REPO_ROOT/tests/test_helper.bash" "$mutant" <<'PY' || return 1
import sys
src, dst = sys.argv[1:3]
text = open(src).read()
old = '''    if [ -n "${TEST_TMPDIR:-}" ]; then
        kill_agents_under "$TEST_TMPDIR"
    fi
'''
new = '''    pkill -f "[t]x[.]py agent --host" 2>/dev/null
'''
if text.count(old) != 1:
    sys.stderr.write("the mutation matches %d times, not once: the helper "
                     "has moved, so move the mutation\n" % text.count(old))
    sys.exit(3)
open(dst, "w").write(text.replace(old, new))
PY
    safe_pkill
    OTHER="$(mktemp -d "${TMPDIR:-/tmp}/tx-other-run-XXXXXX")"
    MINE="$(stand_in "$TEST_TMPDIR/run/hosts/web01")"
    THEIRS="$(stand_in "$OTHER/hosts/web01")"
    printf '%s\n%s\n' "$MINE" "$THEIRS" > "$TEST_TMPDIR/stand-ins"
    # shellcheck disable=SC1090
    (source "$mutant"; TEST_TMPDIR="$TEST_TMPDIR/run"; teardown_env)
    gone "$THEIRS" || fail "with the fix reverted, the other run's agent should die"
    tidy_stand_ins
}

echo "teardown"
run_test "teardown stops only its own agents"  t_teardown_stops_only_its_own_agents
run_test "no test dir stops nothing"           t_teardown_with_no_test_dir_stops_nothing
run_test "the old teardown is caught"          m_the_old_teardown_kills_every_agent
report_tests
