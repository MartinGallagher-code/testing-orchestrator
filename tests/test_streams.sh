#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# What the job reads and what it says: stdin going in, and stderr coming
# back far enough to be read without going and fetching it. A run that
# went wrong is exactly when its output must not be the thing that got
# lost.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# A job's command is single-quoted throughout this file on purpose: it has
# to reach the far side unexpanded, so that $TX_OUT means the out
# directory on the host rather than an empty variable in this shell. That
# non-expansion is SC2016's whole warning and is the behaviour under test.
# shellcheck disable=SC2016

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# Run one job on one fake host and wait for its record to settle.
settle() {
    plan="$(plan_for "$@" -- web01)" || return 1
    WD="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    REC="$WD/run.json"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check || return 1
    local i=0
    while [ "$i" -lt 150 ]; do
        [ -f "$REC" ] && grep -q '"state": "\(done\|timeout\|setup-failed\|launch-failed\)"' "$REC" && return 0
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

field() {
    python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); sys.stdout.write("" if v is None else str(v))' \
        "$REC" "$1"
}

# ---- stdin ------------------------------------------------------------------

t_a_job_can_be_fed_a_file_on_stdin() {
    # A benchmark driven by a workload file wants it on stdin, and the
    # file travels in the payload like everything else the job needs.
    install_fake_ssh
    mkdir -p bench
    printf 'alpha\nbeta\ngamma\n' > bench/workload.txt
    settle --payload ./bench --run 'wc -l > "$TX_OUT/lines"' \
           --stdin workload.txt --timeout 20 || fail "the job never finished"
    assert_eq "0" "$(field exit)"
    assert_eq "3" "$(tr -d ' ' < "$WD/out/lines")"
}

t_without_a_stdin_the_job_reads_nothing_rather_than_waiting() {
    # /dev/null, not an open pipe: a command that waits on input must
    # fail at once instead of hanging until the timeout and reporting
    # nothing useful.
    install_fake_ssh
    settle --run 'cat > "$TX_OUT/got"; echo done > "$TX_OUT/finished"' \
           --timeout 20 || fail "the job never finished"
    assert_eq "0" "$(field exit)"
    assert_eq "" "$(cat "$WD/out/got")"
    assert_file_exists "$WD/out/finished" "the job should not have waited"
}

t_binary_on_stdin_is_not_mangled() {
    install_fake_ssh
    mkdir -p bench
    printf '\x00\x01\xff\xfe' > bench/blob.bin
    settle --payload ./bench --run 'cat > "$TX_OUT/echoed"' \
           --stdin blob.bin --timeout 20 || fail "the job never finished"
    printf '\x00\x01\xff\xfe' > want.bin
    cmp -s want.bin "$WD/out/echoed" || fail "the bytes did not survive stdin"
}

t_a_stdin_file_that_is_not_there_is_caught_before_any_ssh() {
    # The most common way this goes wrong is forgetting to put the file
    # in the payload, and that fails identically on every host -- so it
    # is worth catching without contacting one.
    install_fake_ssh
    mkdir -p bench && : > bench/bench.sh
    servers="$(write_servers web01 web02)"
    run_tx gen --servers "$servers" --plan plan.ini --payload ./bench \
        --run ./bench.sh --stdin nowhere.txt
    : > "$FAKE_ROOT/calls.log"
    run_tx check --plan plan.ini
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "not in the payload"
    assert_eq "0" "$(wc -l < "$FAKE_ROOT/calls.log" | tr -d ' ')"
}

# ---- a run that never started ----------------------------------------------

t_a_job_that_cannot_start_is_a_result_not_a_host_stuck_running() {
    # The record is written before the job is launched, so a launch that
    # throws used to leave the host reading RUNNING for ever -- a machine
    # doing nothing, reported as one still working.
    install_fake_ssh
    settle --run 'echo hi' --stdin nowhere.txt --timeout 20 \
        || fail "the agent never settled"
    assert_eq "launch-failed" "$(field state)"
    assert_contains "$(field detail)" "nowhere.txt"
    assert_eq "" "$(field exit)" "nothing ran, so there is no exit status"
}

t_a_job_with_no_bash_to_run_it_is_a_result_too() {
    # The original bug, and the one the stdin check does not reach: the
    # launch itself throwing. The record is written before the job
    # starts, so an exception escaping left the host reading RUNNING for
    # ever -- a machine doing nothing, reported as one still working.
    #
    # The agent is given a python that has emptied PATH, so the bash it
    # launches the job with cannot be found. Nothing else on the host
    # changes.
    install_fake_ssh
    real_py="$(command -v python3)"
    cat > "$FAKE_BIN/blind-python" <<SHIM
#!/bin/sh
PATH=/var/empty-for-this-test exec "$real_py" "\$@"
SHIM
    chmod +x "$FAKE_BIN/blind-python"

    plan="$(plan_for --run 'echo hi' --timeout 20 -- web01)"
    WD="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    REC="$WD/run.json"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check \
        --python "$FAKE_BIN/blind-python"
    assert_status 0 "$RUN_RC"
    local i=0
    while [ "$i" -lt 100 ]; do
        [ -f "$REC" ] && grep -q '"state": "launch-failed"' "$REC" && break
        sleep 0.2
        i=$((i + 1))
    done
    assert_eq "launch-failed" "$(field state)" \
        "a launch that threw must be recorded, not left reading running"
    assert_contains "$(field detail)" "bash"
    # And what it said is in the record and in the collected stderr, not
    # only in a traceback nobody fetches.
    assert_contains "$(field stderr_tail)" "would not start"
    assert_contains "$(cat "$WD/stderr")" "would not start"
}

t_a_host_that_never_ran_is_reported_as_such() {
    install_fake_ssh
    plan="$(plan_for --run 'echo hi' --stdin nowhere.txt --timeout 20 \
            -- web01 web02)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2.5
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "NEVER RAN"
    assert_status 1 "$RUN_RC" "status with hosts that never ran (TX-006)"

    run_tx summarize --plan "$plan"
    assert_status 1 "$RUN_RC" "a fleet that never ran is not a pass"
    assert_contains "$RUN_OUT" "NEVER RAN 2 host(s)"
    assert_contains "$RUN_OUT" "no result to read as a failure"
    assert_not_contains "$RUN_OUT" "every host ran the job and exited zero"
}

# ---- stderr coming back -----------------------------------------------------

t_the_report_says_why_a_host_failed_not_only_which() {
    # Without this you know host web01 exited 3, and to find out why you
    # collect the run and go looking. The last of its stderr rides back
    # in the record.
    install_fake_ssh
    # The message lives in a script rather than in the command, because
    # summarize echoes the command in its own header -- asserting on a
    # string that appears there too would pass with no tail at all.
    mkdir -p bench
    cat > bench/boom.sh <<'SH'
#!/bin/sh
echo "the widget exploded" >&2
exit 3
SH
    chmod +x bench/boom.sh
    plan="$(plan_for --payload ./bench --run ./boom.sh --tag j \
            --timeout 20 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2.5
    run_tx summarize --plan "$plan"
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "exit 3"
    assert_not_contains "$RUN_OUT" "echo"
    assert_contains "$RUN_OUT" "the widget exploded"
}

t_a_chatty_job_does_not_put_a_log_file_in_its_record() {
    # The whole stderr is collected regardless; the record carries only
    # enough to say what went wrong.
    install_fake_ssh
    settle --run 'i=0; while [ $i -lt 400 ]; do echo "line $i of noise" >&2; i=$((i+1)); done; exit 1' \
           --timeout 20 || fail "the job never finished"
    tail_len="$(field stderr_tail | wc -c | tr -d ' ')"
    assert_between 1 2200 "$tail_len" "the tail should be bounded, got $tail_len bytes"
    # It is the *last* of it, which is the part that says how it ended.
    assert_contains "$(field stderr_tail)" "line 399 of noise"
    # And the whole thing is still on the host, untruncated.
    assert_eq "400" "$(wc -l < "$WD/stderr" | tr -d ' ')"
}

t_the_agents_own_log_comes_back_with_the_results() {
    # It is where anything the agent could not turn into a record ends
    # up, so a run that went wrong is exactly when it is needed -- and
    # `tx logs` being a separate command is no help to somebody reading a
    # collection later.
    install_fake_ssh
    plan="$(plan_for --run 'echo fine' --tag j --timeout 20 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2.5
    run_tx collect --plan "$plan" -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_file_exists "results/j~web01~agent.log"
}

t_a_failed_jobs_output_is_still_collected_whole() {
    install_fake_ssh
    plan="$(plan_for --run 'echo out; echo err >&2; exit 9' --tag j \
            --timeout 20 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2.5
    run_tx collect --plan "$plan" -d results --quiet
    assert_eq "out" "$(cat results/j~web01~stdout)"
    assert_eq "err" "$(cat results/j~web01~stderr)"
}

echo "streams"
run_test "a job can be fed stdin"              t_a_job_can_be_fed_a_file_on_stdin
run_test "no stdin means nothing, not a wait"  t_without_a_stdin_the_job_reads_nothing_rather_than_waiting
run_test "binary on stdin is not mangled"      t_binary_on_stdin_is_not_mangled
run_test "a missing stdin file is caught"      t_a_stdin_file_that_is_not_there_is_caught_before_any_ssh
run_test "a job that cannot start is a result" t_a_job_that_cannot_start_is_a_result_not_a_host_stuck_running
run_test "no bash to run it is a result too"   t_a_job_with_no_bash_to_run_it_is_a_result_too
run_test "a host that never ran is reported"   t_a_host_that_never_ran_is_reported_as_such
run_test "the report says why, not only which" t_the_report_says_why_a_host_failed_not_only_which
run_test "a chatty job does not fill a record" t_a_chatty_job_does_not_put_a_log_file_in_its_record
run_test "the agent log comes back too"        t_the_agents_own_log_comes_back_with_the_results
run_test "a failed job's output is collected"  t_a_failed_jobs_output_is_still_collected_whole
report_tests
