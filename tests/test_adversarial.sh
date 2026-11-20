#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# Regression tests for the defects shared_tools TX-004's adversarial pass
# found in tx's own sweeps and export: a host whose agent died mid-job,
# an earlier run's record answering for this one, a wait and a lease that
# did not count setup and teardown, and `export --from` reading files
# that are not run records. tests/test_adversarial_mutations.sh undoes
# each fix in a copy of tx.py and checks the test that guards it fails.
#
# ONLY=t_name runs that one test (the mutation tests use it).

# Job commands are single-quoted on purpose: they must reach the far side
# unexpanded (SC2016 is the behaviour under test, as in test_waves.sh).
# shellcheck disable=SC2016
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# The directory tx.py is in, so a unit test imports the copy under test
# (a mutant, in the mutation tests) rather than the checkout's. Not
# TX_DIR: that is tx's own -d default, and setup_env unsets it.
TX_SRC="$(cd "$(dirname "$TX")" && pwd)"

# ---- helpers ------------------------------------------------------------

# The state host H's run record is in, or "" when it has none.
record_state() {
    python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["state"])
except Exception: print("")' "$FAKE_ROOT/$1$TX_REMOTE_DIR/run.json"
}

# wait_for_state H STATE -- until host H's record says STATE (10 s at most).
wait_for_state() {
    local i=0
    while [ "$i" -lt 100 ]; do
        [ "$(record_state "$1")" = "$2" ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    fail "host $1 never reached state $2 (it is '$(record_state "$1")')"
}

# reboot_host H -- what a reboot or an OOM kill does to a host mid-job:
# its agent and the job's whole process group are gone at once, and the
# record is left saying whatever it said last.
reboot_host() {
    local pid kids k
    pid="$(cat "$FAKE_ROOT/$1$TX_REMOTE_DIR/agent.pid" 2>/dev/null)"
    [ -n "$pid" ] || { fail "host $1 has no agent.pid"; return 1; }
    # The agent's children, from /proc: CI's python:3.6-slim has no pgrep.
    kids="$(python3 -c 'import os, sys
for p in os.listdir("/proc"):
    try:
        f = open("/proc/%s/stat" % p).read()
    except (IOError, OSError, ValueError):
        continue
    if f.rsplit(")", 1)[-1].split()[1] == sys.argv[1]:
        print(p)' "$pid")"
    kill -9 "$pid" 2>/dev/null
    for k in $kids; do
        kill -9 -- "-$k" 2>/dev/null
        kill -9 "$k" 2>/dev/null
    done
    # SIGKILL lands asynchronously, and an orphan is reaped when its new
    # parent gets round to it: until then `kill -0` still finds it, and a
    # deploy would refuse the host as busy. A rebooted host has neither.
    local i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    kill -0 "$pid" 2>/dev/null && { fail "host $1's agent outlived the kill"; return 1; }
    return 0
}

# The orchestrator in the background, its own pid in $driver. Not echoed
# out of a $(...): the process would then be that subshell's child, and
# `wait` here could not collect its exit status.
in_background() {
    python3 "$TX" "$@" > "$TEST_TMPDIR/bg.log" 2>&1 &
    driver=$!
}

# The muster double test_muster.sh defines (install_fake_muster), taken
# from it so the two cannot drift apart.
eval "$(sed -n '/^install_fake_muster() {/,/^}/p' \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_muster.sh")"

# ---- a host whose agent died mid-job ---------------------------------------

t_run_fails_when_an_agent_dies_mid_job() {
    # The record says "running" for good, the agent is gone: nothing more
    # is coming. tx run reported that host as "still going" and exited 0.
    install_fake_ssh
    plan="$(plan_for --run 'sleep 4; echo "$TX_HOST" > "$TX_OUT/who"' \
            --tag t --timeout 30 -- a b)"
    in_background run --plan "$plan" --start-in 1 \
              --no-skew-check -d results --quiet
    wait_for_state a running
    reboot_host a
    wait "$driver"
    rc=$?
    out="$(cat "$TEST_TMPDIR/bg.log")"
    assert_status 1 "$rc" "a host that never finished is worth an exit code"
    assert_contains "$out" "GONE      1 host(s) stopped mid-job"
    assert_not_contains "$out" "still going: a"
    # summarize, asked afterwards, says the same.
    run_tx summarize --plan "$plan"
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "GONE"
}

t_resume_runs_again_a_host_whose_agent_died() {
    # --resume believed the record's "running" without asking whether the
    # agent was alive, so the host was waited on, never run, and the sweep
    # exited 0 -- on every resume after.
    install_fake_ssh
    plan="$(plan_for --run 'sleep 3; echo "$TX_HOST" > "$TX_OUT/who"' \
            --tag t --timeout 30 -- a b c d)"
    in_background run --plan "$plan" --batch 2 --start-in 1 \
              --no-skew-check -d results --quiet
    wait_for_state a running
    kill -9 "$driver" 2>/dev/null
    reboot_host a
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --resume --quiet
    assert_status 0 "$RUN_RC"
    assert_not_contains "$RUN_OUT" "still going"
    for h in a b c d; do
        assert_file_exists "results/t~$h~out~who" "$h was never covered"
    done
}

t_muster_puts_back_an_item_whose_agent_died() {
    # Left "to its lease", the item was held for hours with nothing
    # running on it. Nothing ran to the end there, so it goes back.
    install_fake_ssh
    install_fake_muster
    muster add "a b" --pool "$TEST_TMPDIR/pool.csv" > /dev/null
    plan="$(plan_for --run 'sleep 3; echo "$TX_HOST" > "$TX_OUT/who"' \
            --tag t --timeout 30 -- a b)"
    in_background run --plan "$plan" --muster \
              "$TEST_TMPDIR/pool.csv" --batch 2 --start-in 1 \
              --no-skew-check -d results --quiet
    wait_for_state a running
    reboot_host a
    wait "$driver"
    rc=$?
    out="$(cat "$TEST_TMPDIR/bg.log")"
    assert_status 1 "$rc"
    assert_contains "$out" "putting 1 item(s) back"
    assert_contains "$(muster list --pool "$TEST_TMPDIR/pool.csv")" \
        "a,available" "a should be back in the pool"
    assert_contains "$(muster list --pool "$TEST_TMPDIR/pool.csv")" "b,done"
}

# ---- an earlier run's record ---------------------------------------------------

t_an_earlier_runs_record_does_not_answer_for_this_one() {
    # --no-deploy leaves the last run's run.json where it was. An agent
    # that then died on startup read as "ran already", and the old exit 0
    # as this run passing on every host.
    install_fake_ssh
    plan="$(plan_for --run 'echo "$TX_HOST" > "$TX_OUT/who"' --tag t \
            --timeout 10 -- a b)"
    run_tx run --plan "$plan" --start-in 1 --no-skew-check -d first --quiet
    assert_status 0 "$RUN_RC"
    run_tx stop --plan "$plan"
    run_tx run --plan "$plan" --start-in 1 --no-skew-check --no-deploy \
        --python python3.99 -d second --quiet
    assert_status 1 "$RUN_RC" "no agent started, so nothing passed"
    assert_contains "$RUN_OUT" "died on startup"
    assert_not_contains "$RUN_OUT" "every host ran the job"
}

# ---- how long a host can take ---------------------------------------------

t_the_wait_and_the_lease_count_setup_and_teardown() {
    # Setup and teardown each have the job's timeout of their own. A wait
    # that counted only the job gave up on hosts still inside their
    # budget, and started the next wave over them; a lease built on it
    # ran out under a host that was still working.
    out="$(python3 - "$TX_SRC" <<'PY'
import sys, time, types
sys.path.insert(0, sys.argv[1])
import tx
def plan(setup="", teardown=""):
    return tx.Plan("p", ["a"], {"a": "a"}, "run", setup, teardown, "",
                   600.0, [], "t", "/d")
args = types.SimpleNamespace(start_in=5.0, batch=1, lease="")
arm = tx.arm_delay(1, 5.0)
g = tx.KILL_GRACE
both = plan("make", "rm -rf x")
print(round(tx._job_bound(plan(), 1, 5.0) - arm))
print(round(tx._job_bound(plan("make"), 1, 5.0) - arm))
print(round(tx._job_bound(both, 1, 5.0) - arm))
print(round(tx._wait_deadline(args, both) - time.time()
            - tx._job_bound(both, 1, 5.0)))
print(tx.muster_lease(args, plan()))
print(tx.muster_lease(args, both))
PY
)"
    { read -r job; read -r with_setup; read -r with_both; read -r slack
      read -r lease_job; read -r lease_both; } <<< "$out"
    assert_eq "600" "$job" "a job alone is bounded by its timeout"
    assert_eq "1205" "$with_setup" "setup has a timeout of its own"
    assert_eq "1810" "$with_both" "so has teardown"
    assert_eq "60" "$slack" "the wait is the bound and a minute"
    # 2 x (bound + 60) + 300, for a bound of arm + 600 and arm + 1810.
    assert_eq "1630s" "$lease_job" "no setup or teardown: as before"
    assert_eq "4050s" "$lease_both" \
        "the lease outlasts setup, job and teardown"
}

# ---- export --from: only run records are run records ------------------------

# A collection directory holding NAME:JSON pairs, file by file.
collection() {
    local dir="$TEST_TMPDIR/coll" pair
    mkdir -p "$dir"
    for pair in "$@"; do
        printf '%s\n' "${pair#*:}" > "$dir/${pair%%:*}"
    done
    echo "$dir"
}

REC='{"host":"web01","tag":"bench","state":"done","exit":0,"timed_out":false,"duration":10.0}'

t_export_skips_json_that_is_not_a_run_record() {
    # A JSON array, a string, a host that is not a name, a record with no
    # state: each crashed export with a traceback, or was read as a host.
    coll="$(collection "bench~web01~run.json:$REC" \
            'bench~x1~run.json:[1, 2]' \
            'bench~x2~run.json:"x"' \
            'bench~7~run.json:{"host": 7, "state": "done", "exit": 0}' \
            'bench~x3~run.json:{"host": "x3", "exit": 0}')"
    run_tx export --plan "$TEST_TMPDIR/none.ini" --from "$coll"
    assert_status 0 "$RUN_RC"
    assert_not_contains "$RUN_OUT" "Traceback"
    assert_contains "$RUN_OUT" "skipping bench~x1~run.json: not a run record"
    assert_contains "$RUN_OUT" "skipping bench~x2~run.json: not a run record"
    assert_contains "$RUN_OUT" "bench~7~run.json has no host name"
    assert_contains "$RUN_OUT" "skipping bench~x3~run.json: no state field"
    assert_contains "$RUN_OUT" "tx_state	web01	PASSED"
    assert_contains "$RUN_OUT" "on 1 host(s)"
}

t_export_does_not_take_a_jobs_own_run_json_for_the_record() {
    # The job's work/run.json is collected as bench~web01~work~run.json,
    # which sorts after the record and so replaced it.
    coll="$(collection "bench~web01~run.json:$REC" \
            'bench~web01~work~run.json:{"host":"web01","state":"done","exit":3,"duration":99}')"
    run_tx export --plan "$TEST_TMPDIR/none.ini" --from "$coll" --no-meta
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "tx_duration	web01	10"
    assert_contains "$RUN_OUT" "tx_exit	web01	0"
    assert_contains "$RUN_OUT" "not where tx collect puts web01's record"
}

t_export_reads_one_run_of_a_shared_directory() {
    # Tags exist so two runs can share a directory. export read both and
    # kept whichever record sorted last, mixing the runs.
    local alpha zeta
    alpha='{"host":"web01","tag":"alpha","state":"done","exit":0,"duration":10.0}'
    zeta='{"host":"web01","tag":"zeta","state":"done","exit":0,"duration":50.0}'
    coll="$(collection "alpha~web01~run.json:$alpha" "zeta~web01~run.json:$zeta")"
    export TX_REMOTE_DIR="${TX_REMOTE_DIR:-/var/tmp/tx-test}"
    plan="$(plan_for --run './bench.sh' --tag zeta --timeout 60 -- web01)"
    run_tx export --plan "$plan" --from "$coll" --no-meta
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "tx_duration	web01	50" "the plan's run, zeta"
    assert_not_contains "$RUN_OUT" "tx_duration	web01	10"
    # Without a plan nothing says which run is meant, so it is refused.
    run_tx export --plan "$TEST_TMPDIR/none.ini" --from "$coll"
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "records of 2 runs (tags: alpha, zeta)"
}

t_export_keeps_records_for_hosts_the_plan_does_not_name() {
    # A --muster sweep runs items the plan never names; with a plan in the
    # directory their records were dropped without a word.
    coll="$(collection "bench~web01~run.json:$REC" \
            "bench~web09~run.json:${REC//web01/web09}")"
    export TX_REMOTE_DIR="${TX_REMOTE_DIR:-/var/tmp/tx-test}"
    plan="$(plan_for --run './bench.sh' --tag bench --timeout 60 -- web01)"
    run_tx export --plan "$plan" --from "$coll" --no-meta
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "tx_state	web01	PASSED"
    assert_contains "$RUN_OUT" "tx_state	web09	PASSED"
}

# ---- names ssh would read as options, or a collection cannot hold ----------

# An ssh/scp stand-in that writes each argv to argv.log, then hands over to
# the fake fleet: whatever reaches ssh's command line is on record.
install_argv_logger() {
    local t
    for t in ssh scp; do
        cat > "$FAKE_BIN/$t-logged" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" | head -n 1 >> "$TEST_TMPDIR/argv.log"
exec "$FAKE_BIN/$t" "\$@"
SH
        chmod +x "$FAKE_BIN/$t-logged"
    done
    : > "$TEST_TMPDIR/argv.log"
}

t_a_name_ssh_would_read_as_an_option_is_refused() {
    # A destination that starts with '-' is an ssh option: -F reads another
    # config, -oProxyCommand= runs a command here. Nothing tx can mean by it.
    install_fake_ssh
    install_argv_logger
    printf '%s\n' '-F/tmp/evil_config' > "$TEST_TMPDIR/bad.txt"
    run_tx gen --servers "$TEST_TMPDIR/bad.txt" --plan "$TEST_TMPDIR/bad.ini" \
        --run true
    assert_status 2 "$RUN_RC" "gen should refuse it"
    assert_contains "$RUN_OUT" "starts with '-'"
    # A plan written by hand is refused when it is read, before any ssh.
    plan="$(plan_for --run true --tag t --timeout 10 -- web)"
    sed -i 's/^web = web$/web = -oProxyCommand=touch${IFS}PWNED/' "$plan"
    run_tx status --plan "$plan" --ssh "$FAKE_BIN/ssh-logged"
    assert_status 2 "$RUN_RC" "a plan naming it should be refused"
    assert_contains "$RUN_OUT" "starts with '-'"
    # And --user goes in front of the address, so it is the same argument.
    plan="$(plan_for --run true --tag t --timeout 10 -- web)"
    TX_USER='-F/tmp/evil_config' run_tx status --plan "$plan" \
        --ssh "$FAKE_BIN/ssh-logged"
    assert_status 2 "$RUN_RC" "a --user starting with '-' should be refused"
    assert_eq "" "$(cat "$TEST_TMPDIR/argv.log")" "ssh was run"
}

t_a_pool_item_that_cannot_be_a_host_is_not_run() {
    # The pool is somebody else's file. An item '-oProxyCommand=...' went
    # to ssh as an option; an item with a '/' crashed the collection with
    # a traceback and was left held. Neither is run; both go back.
    install_fake_ssh
    install_fake_muster
    install_argv_logger
    printf '%s\n' 'item,state,holder,lease_id,taken_ts,expires_ts,done_ts,attempts,note' \
        '-oProxyCommand=touch${IFS}PWNED,available,,,,,,0,' \
        'r1/n1,available,,,,,,0,' 'a,available,,,,,,0,' \
        > "$TEST_TMPDIR/pool.csv"
    plan="$(plan_for --run 'echo "$TX_HOST" > "$TX_OUT/who"' --tag t \
            --timeout 10 -- a)"
    run_tx run --plan "$plan" --muster "$TEST_TMPDIR/pool.csv" --batch 3 \
        --start-in 1 --no-skew-check --ssh "$FAKE_BIN/ssh-logged" \
        --scp "$FAKE_BIN/scp-logged" -d results --quiet
    assert_status 1 "$RUN_RC" "items that could not be run are worth saying so"
    assert_not_contains "$RUN_OUT" "Traceback"
    assert_not_contains "$(cat "$TEST_TMPDIR/argv.log")" "ProxyCommand" \
        "the item reached ssh's command line"
    assert_contains "$RUN_OUT" "not running pool item '-oProxyCommand"
    assert_contains "$RUN_OUT" "not running pool item 'r1/n1'"
    assert_file_exists "results/t~a~out~who" "the usable item was not run"
    pool="$(muster list --pool "$TEST_TMPDIR/pool.csv")"
    assert_contains "$pool" "a,done"
    assert_contains "$pool" "r1/n1,available"
    assert_contains "$pool" 'PWNED,available'
}

t_export_refuses_a_test_prefix_that_breaks_the_file() {
    # The prefix leads every test name in a whitespace-separated file: a
    # space split the field, a newline wrote lines of its own.
    coll="$(collection "bench~web01~run.json:$REC")"
    run_tx export --plan "$TEST_TMPDIR/none.ini" --from "$coll" \
        --test-prefix 'my tx_'
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "--test-prefix"
    run_tx export --plan "$TEST_TMPDIR/none.ini" --from "$coll" \
        --test-prefix $'x\n!test\tfake\tunit=s\n'
    assert_status 2 "$RUN_RC"
    assert_not_contains "$RUN_OUT" "fake	unit=s"
}

TESTS=(
    t_run_fails_when_an_agent_dies_mid_job
    t_resume_runs_again_a_host_whose_agent_died
    t_muster_puts_back_an_item_whose_agent_died
    t_an_earlier_runs_record_does_not_answer_for_this_one
    t_the_wait_and_the_lease_count_setup_and_teardown
    t_export_skips_json_that_is_not_a_run_record
    t_export_does_not_take_a_jobs_own_run_json_for_the_record
    t_export_reads_one_run_of_a_shared_directory
    t_export_keeps_records_for_hosts_the_plan_does_not_name
    t_a_name_ssh_would_read_as_an_option_is_refused
    t_a_pool_item_that_cannot_be_a_host_is_not_run
    t_export_refuses_a_test_prefix_that_breaks_the_file
)

echo "adversarial (TX-004)"
for t in "${TESTS[@]}"; do
    [ -n "${ONLY:-}" ] && [ "$ONLY" != "$t" ] && continue
    run_test "$t" "$t"
done
report_tests
