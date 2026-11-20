# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Martin J. Gallagher
#
# Shared helpers for the tx test suite.
#
# Each test file sources this, defines test_* functions, and calls
# run_test for each. Tests run in subshells so one failed assertion
# cannot abort the rest of the file.
#
# $TX is the tool under test (set by run_tests.sh). Each test gets a
# fresh temp dir at $TEST_TMPDIR and is run with that as its cwd.

set -u

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TX="${TX:-$REPO_ROOT/testing_orchestrator/tx.py}"
export REPO_ROOT TX

# ---- Per-test environment ---------------------------------------------------

setup_env() {
    TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/tx-tests-XXXXXX")"
    export TEST_TMPDIR
    export FAKE_BIN="$TEST_TMPDIR/bin"
    export FAKE_ROOT="$TEST_TMPDIR/hosts"
    mkdir -p "$FAKE_BIN" "$FAKE_ROOT"
    # Never let a stray environment leak into a test run.
    unset TX_PLAN TX_SERVERS TX_REMOTE_DIR TX_DIR TX_JOBS TX_USER \
          TX_PYTHON TX_SSH TX_SCP SSH_USER TX_ALLOW_SHARED_REMOTE_DIR
    # tx refuses a --remote-dir its group can write to (TX-002), so a test
    # that makes one by hand must not get a group-writable one just because
    # the runner's umask is 002.
    umask 022
}

teardown_env() {
    # Anything the tests started is a child of this shell; make sure a
    # crashed test cannot leave agents blasting packets at the runner.
    pkill -f "[t]x[.]py agent --host" 2>/dev/null
    if [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# Run tx as a subprocess. Captures stdout+stderr in $RUN_OUT, status in $RUN_RC.
run_tx() {
    RUN_OUT="$(python3 "$TX" "$@" 2>&1)"
    RUN_RC=$?
    export RUN_OUT RUN_RC
}

# tx, with its output on stdout and its status left in $?.
tx() {
    python3 "$TX" "$@"
}

# write_servers NAME... -- a server list. The fake ssh keys off the name,
# so name=name is what makes a shim run in that host's own sandbox.
write_servers() {
    : > "$TEST_TMPDIR/servers.txt"
    local h
    for h in "$@"; do
        printf '%s\n' "$h" >> "$TEST_TMPDIR/servers.txt"
    done
    echo "$TEST_TMPDIR/servers.txt"
}

# A plan over NAME..., with the job flags already in $@ before the --.
# plan_for --run 'echo hi' -- web01 web02
plan_for() {
    local flags=() hosts=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --) shift; break ;;
            *) flags+=("$1"); shift ;;
        esac
    done
    hosts=("$@")
    local servers
    servers="$(write_servers "${hosts[@]}")"
    python3 "$TX" gen --servers "$servers" --plan "$TEST_TMPDIR/plan.ini" \
        --remote-dir "$TX_REMOTE_DIR" "${flags[@]}" > /dev/null || return 1
    echo "$TEST_TMPDIR/plan.ini"
}

# Install fake ssh/scp that execute the "remote" commands locally inside
# $FAKE_ROOT/<addr>, so the whole fleet workflow (deploy, start, status,
# stop, clean) can be exercised without a network or a second machine.
install_fake_ssh() {
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
set -u
target=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        -*) shift ;;
        *) target="$1"; shift; break ;;
    esac
done
host="${target#*@}"
root="$FAKE_ROOT/$host"
mkdir -p "$root"
cmd="$*"
printf 'ssh\t%s\t%s\n' "$host" "$cmd" >> "$FAKE_ROOT/calls.log"
# Rewrite the remote working dir into this host's sandbox, and tell any
# per-host shims (e.g. a fake `ip`) which host they are running "on".
cmd="${cmd//$TX_REMOTE_DIR/$root$TX_REMOTE_DIR}"
export FAKE_HOST_ADDR="$host"
cd "$root" && bash -c "$cmd"
SHIM
    cat > "$FAKE_BIN/scp" <<'SHIM'
#!/usr/bin/env bash
set -u
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        -q|-r|-B) shift ;;
        *) args+=("$1"); shift ;;
    esac
done
n=${#args[@]}
[ "$n" -lt 2 ] && exit 2
dst="${args[$((n-1))]}"
srcs=("${args[@]:0:$((n-1))}")
remap() {
    case "$1" in
        *:*) local h="${1%%:*}"; h="${h#*@}"
             printf '%s\n' "$FAKE_ROOT/$h${1#*:}" ;;
        *)   printf '%s\n' "$1" ;;
    esac
}
d="$(remap "$dst")"
printf 'scp\t%s\t%s\n' "${srcs[*]}" "$dst" >> "$FAKE_ROOT/calls.log"
case "$d" in
    */) mkdir -p "$d" ;;
    *)  mkdir -p "$(dirname "$d")" ;;
esac
for s in "${srcs[@]}"; do
    cp -f "$(remap "$s")" "$d" || exit 1
done
SHIM
    chmod +x "$FAKE_BIN/ssh" "$FAKE_BIN/scp"
    : > "$FAKE_ROOT/calls.log"
    export PATH="$FAKE_BIN:$PATH"
    export TX_REMOTE_DIR="${TX_REMOTE_DIR:-/var/tmp/tx-test}"
}

# skew_host HOST SECONDS -- make that host's clock wrong, so the skew
# check has something to find. Only `date +%s.%N` is intercepted, which
# is the one reading tx takes; anything else falls through to the real
# date, so a shim cannot quietly change what other commands see.
skew_host() {
    printf '%s\n' "$2" > "$FAKE_ROOT/$1.skew"
    if [ ! -f "$FAKE_BIN/date" ]; then
        cat > "$FAKE_BIN/date" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-}" = "+%s.%N" ]; then
    off=0
    if [ -n "${FAKE_HOST_ADDR:-}" ] && [ -f "$FAKE_ROOT/$FAKE_HOST_ADDR.skew" ]; then
        off="$(cat "$FAKE_ROOT/$FAKE_HOST_ADDR.skew")"
    fi
    python3 -c 'import sys,time; sys.stdout.write("%.9f\n" % (time.time()+float(sys.argv[1])))' "$off"
    exit 0
fi
exec /usr/bin/env -i PATH=/usr/bin:/bin date "$@"
SHIM
        chmod +x "$FAKE_BIN/date"
    fi
}

# ---- Assertions ---------------------------------------------------------

# Every assertion routes its failure through here, which leaves a marker
# run_test reads afterwards. Returning non-zero is not enough on its own:
# a test's exit status is its *last* command's, so an assertion in the
# middle of a test would otherwise be printed and then forgotten -- which
# is a suite that reports PASS for a test it watched fail.
_note_failure() {
    [ -n "${TEST_TMPDIR:-}" ] && : > "$TEST_TMPDIR/.assert_failed"
    return 1
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-values differ}"
    [ "$expected" = "$actual" ] && return 0
    printf 'ASSERT_EQ FAILED: %s\n  expected: <%s>\n  actual:   <%s>\n' \
        "$msg" "$expected" "$actual" >&2
    _note_failure
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-substring missing}"
    [[ "$haystack" == *"$needle"* ]] && return 0
    printf 'ASSERT_CONTAINS FAILED: %s\n  needle: <%s>\n  haystack:\n%s\n' \
        "$msg" "$needle" "$haystack" >&2
    _note_failure
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-substring should be absent}"
    [[ "$haystack" != *"$needle"* ]] && return 0
    printf 'ASSERT_NOT_CONTAINS FAILED: %s\n  needle: <%s>\n' "$msg" "$needle" >&2
    _note_failure
}

assert_status() {
    local expected="$1" actual="$2" msg="${3:-exit status mismatch}"
    [ "$expected" -eq "$actual" ] && return 0
    printf 'ASSERT_STATUS FAILED: %s expected=%d actual=%d\n' \
        "$msg" "$expected" "$actual" >&2
    _note_failure
}

assert_file_exists() {
    local f="$1" msg="${2:-file missing}"
    [ -f "$f" ] && return 0
    printf 'ASSERT_FILE_EXISTS FAILED: %s (%s)\n' "$msg" "$f" >&2
    _note_failure
}

assert_no_file() {
    local f="$1" msg="${2:-file should not exist}"
    [ ! -e "$f" ] && return 0
    printf 'ASSERT_NO_FILE FAILED: %s (%s)\n' "$msg" "$f" >&2
    _note_failure
}

# assert_between LOW HIGH VALUE MSG -- for the inherently noisy rate
# assertions, where CI runners make tight bounds a flake generator.
assert_between() {
    local low="$1" high="$2" value="$3" msg="${4:-value out of range}"
    if python3 -c "import sys; sys.exit(0 if $low <= $value <= $high else 1)"; then
        return 0
    fi
    printf 'ASSERT_BETWEEN FAILED: %s (%s not in [%s, %s])\n' \
        "$msg" "$value" "$low" "$high" >&2
    _note_failure
}

# fail MSG -- an assertion that is not about comparing two values: a
# state the test reached that it should not have. Without it those nine
# call sites would go silent on the one run where they matter.
fail() {
    printf 'FAILED: %s\n' "${1:-assertion failed}" >&2
    _note_failure
}

# ---- Test runner ------------------------------------------------------------

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# A per-test wall-clock limit, so one hung test -- a loopback agent that
# never exits, a start that blocks on a shim -- fails loudly instead of
# wedging the whole run (and, in CI, burning the job's time budget on a
# process nothing will ever reap). Override in seconds with TX_TEST_TIMEOUT;
# 0 turns it off. Kept generous: the slowest real-agent test finishes in a
# few seconds, so 60 only ever fires on a genuine hang.
: "${TX_TEST_TIMEOUT:=60}"

# run_test LABEL FUNC -- LABEL is what the report prints, FUNC is what
# runs. Two arguments rather than one so the report reads as sentences
# about the tool instead of a list of python-ish identifiers.
run_test() {
    local label="$1" name="$2"; shift 2
    # TX_ONLY=FUNC runs that one test of a file and skips the rest: how
    # test_remote_dir_mutations.sh runs one test against a mutant.
    if [ -n "${TX_ONLY:-}" ] && [ "$name" != "$TX_ONLY" ]; then
        return 0
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
    setup_env
    local rc=0 limit="${TX_TEST_TIMEOUT:-0}" timed_out=0
    (
        set +e
        cd "$TEST_TMPDIR" || exit 1
        "$name" "$@"
    ) &
    local pid=$!
    if [ "$limit" -gt 0 ]; then
        # Watchdog: give the test `limit` seconds, then TERM it, and KILL if
        # it will not go. A flag file -- not the exit status -- records that
        # the limit fired, since a test can exit non-zero on its own.
        local flag="$TEST_TMPDIR/.timed_out"
        (
            sleep "$limit"
            kill -0 "$pid" 2>/dev/null || exit 0
            : > "$flag"
            kill -TERM "$pid" 2>/dev/null
            sleep 2
            kill -KILL "$pid" 2>/dev/null
        ) &
        local watch=$!
        wait "$pid" 2>/dev/null
        rc=$?
        # The test finished on its own; stop the watchdog before it fires.
        kill "$watch" 2>/dev/null
        wait "$watch" 2>/dev/null
        [ -f "$flag" ] && timed_out=1
    else
        wait "$pid" 2>/dev/null
        rc=$?
    fi
    # An assertion that failed anywhere in the test fails the test, even
    # if what ran after it happened to succeed.
    [ -f "$TEST_TMPDIR/.assert_failed" ] && rc=1
    if [ "$timed_out" -eq 1 ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$label")
        printf '    FAIL  %s (timed out after %ds)\n' "$label" "$limit"
    elif [ "$rc" -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '    PASS  %s\n' "$label"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$label")
        printf '    FAIL  %s (rc=%d)\n' "$label" "$rc"
    fi
    # teardown_env's pkill sweeps up any agent a killed test left running.
    teardown_env
}

report_tests() {
    echo
    echo "  ----------------------------------------"
    echo "  ran:    $TESTS_RUN"
    echo "  passed: $TESTS_PASSED"
    echo "  failed: $TESTS_FAILED"
    if [ "$TESTS_FAILED" -ne 0 ]; then
        printf '    %s\n' "${FAILED_TESTS[@]}"
        exit 1
    fi
    exit 0
}
