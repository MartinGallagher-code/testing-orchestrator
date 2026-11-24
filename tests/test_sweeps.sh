#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# A sweep's results are its own (shared_tools TX-008). The fleet keeps no
# history: a host holds whatever ran there last, finished and exit 0, and
# tx compared no run id anywhere. So --resume took an earlier sweep's
# records for this sweep's, ran a --clean sweep's finished waves a second
# time, and a --no-deploy start collected the last run's out/ as its own.
# Every sweep now has an id, in its collection directory and in every
# record, and a start clears the last run's outputs.
#
# tests/test_mutations.sh takes each fix back out of a copy of tx.py and
# checks that the test here written for it fails.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# A job's command is single-quoted where it must reach the far side
# unexpanded ($TX_OUT is the host's, not this shell's), which is SC2016's
# whole warning.
# shellcheck disable=SC2016

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# json_field FILE KEY -- one field of a JSON object, as Python prints it
# (None for null or missing).
json_field() {
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' \
        "$1" "$2"
}

# A plan whose job writes one line to $TEST_TMPDIR/ran/HOST every time it
# runs, takes two seconds, and leaves out/who. The count is the point:
# how many times each host really ran, whatever the records say.
counting_plan() {
    local ran="$TEST_TMPDIR/ran"
    mkdir -p "$ran"
    plan_for --run "echo x >> $ran/\$TX_HOST; sleep 2; echo \"\$TX_HOST\" > \"\$TX_OUT/who\"" \
             --tag t --timeout 30 -- "$@"
}

runs_of() {
    if [ -f "$TEST_TMPDIR/ran/$1" ]; then
        wc -l < "$TEST_TMPDIR/ran/$1" | tr -d ' '
    else
        echo 0
    fi
}

# wait_until_ran HOST N -- until HOST's job has started N times (20s).
wait_until_ran() {
    local i=0
    while [ "$i" -lt 200 ]; do
        [ "$(runs_of "$1")" -ge "$2" ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    fail "$1 never started its run number $2"
}

# The orchestrator itself in the background, and its pid: python, not the
# `tx` shell function, whose pid would be a subshell's (test_waves.sh).
sweep_in_background() {
    python3 "$TX" "$@" > "$TEST_TMPDIR/sweep.log" 2>&1 &
    echo $!
}

# kill_driver PID -- kill -9 the orchestrator, and see it gone. The agents
# are detached, so the work it started goes on.
kill_driver() {
    kill -9 "$1" 2>/dev/null
    local i=0
    while [ "$i" -lt 50 ]; do
        kill -0 "$1" 2>/dev/null || return 0
        sleep 0.1
        i=$((i + 1))
    done
    fail "the orchestrator outlived the kill"
}

# ---- the id ----------------------------------------------------------------

t_a_sweep_has_one_id_on_every_record() {
    install_fake_ssh
    plan="$(plan_for --run 'echo "${TX_SWEEP_ID-unset}" > "$TX_OUT/sweep"' \
            --tag t --timeout 10 -- a b)"
    # Left in the ssh user's environment, it must not pass a run off as
    # some sweep's.
    export TX_SWEEP_ID=leaked
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    sweep="$(json_field results/.tx-sweep sweep_id)"
    case "$sweep" in
        ''|None|leaked) fail "results/.tx-sweep holds no sweep id of its own: $sweep" ;;
    esac
    assert_contains "$RUN_OUT" "(sweep $sweep)"
    # Two waves, two starts, one sweep.
    for h in a b; do
        assert_eq "$sweep" "$(json_field "results/t~$h~run.json" sweep_id)" \
            "$h's record should carry the sweep's id"
        assert_eq "$sweep" "$(cat "results/t~$h~out~sweep")" \
            "$h's job should be told the sweep's id"
    done

    # Outside a sweep there is none, in the record or the job's environment.
    run_tx run --plan "$plan" --start-in 1 --no-skew-check -d plain --quiet
    assert_status 0 "$RUN_RC"
    for h in a b; do
        assert_eq "None" "$(json_field "plain/t~$h~run.json" sweep_id)"
        assert_eq "unset" "$(cat "plain/t~$h~out~sweep")"
    done
}

# ---- 1. an earlier sweep's results are not this sweep's -------------------

t_an_earlier_sweeps_hosts_run_again() {
    # Week one covers the fleet. Week two is killed in its first wave and
    # resumed. b and c still hold week one's records, done and exit 0 --
    # resume used to count those as week two's, say "0 left to cover" and
    # "every host ran the job", and never run them.
    install_fake_ssh
    plan="$(counting_plan a b c)"
    run_tx run --plan "$plan" --batch 3 --start-in 1 --no-skew-check \
        -d week1 --quiet
    assert_status 0 "$RUN_RC" "week one"

    driver="$(sweep_in_background run --plan "$plan" --batch 1 --start-in 1 \
              --no-skew-check -d week2 --quiet)"
    wait_until_ran a 2
    kill_driver "$driver"

    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d week2 --resume --quiet
    assert_status 0 "$RUN_RC"
    # a is week two's either way -- still running, or (on a slow runner)
    # finished by the time resume asks -- so only the rest is asserted.
    assert_contains "$RUN_OUT" ", 2 left to cover"
    assert_contains "$RUN_OUT" "2 of those hold an earlier run's result"
    sweep="$(json_field week2/.tx-sweep sweep_id)"
    for h in a b c; do
        assert_eq 2 "$(runs_of "$h")" "$h should have run once each week"
        assert_eq "$sweep" "$(json_field "week2/t~$h~run.json" sweep_id)" \
            "week two's collection holds another sweep's record for $h"
    done
}

# ---- 2. a --clean sweep resumes without running anything twice -------------

t_a_clean_sweep_resumes_without_running_a_host_twice() {
    # --clean removes each wave from its hosts once it is collected, so
    # asking the fleet found nothing on a and b, and resume ran them again.
    # The collection is their record now.
    install_fake_ssh
    plan="$(counting_plan a b c)"
    driver="$(sweep_in_background run --plan "$plan" --batch 1 --start-in 1 \
              --no-skew-check -d results --clean --quiet)"
    wait_until_ran c 1
    kill_driver "$driver"
    assert_no_file "$FAKE_ROOT/a$TX_REMOTE_DIR" \
        "a's wave should have been collected and cleaned before c started"

    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --clean --resume --quiet
    assert_status 0 "$RUN_RC"
    # c may still be running or may have finished by now; a and b are in
    # results/ and nowhere else, and nothing is left to cover.
    assert_contains "$RUN_OUT" ", 0 left to cover"
    assert_contains "$RUN_OUT" "2 finished host(s) are already in results/"
    assert_contains "$RUN_OUT" "3 of 3 hosts finished: 3 passed"
    for h in a b c; do
        assert_eq 1 "$(runs_of "$h")" "$h ran more than once"
        assert_file_exists "results/t~$h~out~who"
        # --clean holds for the hosts resume picked up, too: c was the
        # interrupted sweep's, and was left on the fleet.
        assert_no_file "$FAKE_ROOT/$h$TX_REMOTE_DIR" "$h was left on the fleet"
    done
}

t_another_sweeps_record_in_the_collection_does_not_count() {
    # Week one and week two collect into the same -d, both with --clean.
    # Week two is killed in its first wave: b is clean on the fleet, and the
    # only t~b~run.json in results/ is week one's. That is not week two's.
    install_fake_ssh
    plan="$(counting_plan a b)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --clean --quiet
    assert_status 0 "$RUN_RC" "week one"
    week1="$(json_field results/.tx-sweep sweep_id)"

    driver="$(sweep_in_background run --plan "$plan" --batch 1 --start-in 1 \
              --no-skew-check -d results --clean --quiet)"
    wait_until_ran a 2
    kill_driver "$driver"
    assert_eq "$week1" "$(json_field results/t~b~run.json sweep_id)" \
        "b's record in results/ should still be week one's"

    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --clean --resume --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" ", 1 left to cover"
    assert_not_contains "$RUN_OUT" "already in results/" \
        "week one's record for b was counted as week two's"
    assert_eq 2 "$(runs_of b)" "b should have run once each week"
    week2="$(json_field results/.tx-sweep sweep_id)"
    assert_eq "$week2" "$(json_field results/t~b~run.json sweep_id)"
}

# ---- 3. a start does not collect the last run's files -----------------------

t_no_deploy_does_not_collect_what_the_last_run_wrote() {
    # --no-deploy copies nothing, so nothing else cleared the last run's
    # outputs: its out/ and logs came back in this run's collection as if
    # this run had written them.
    install_fake_ssh
    plan="$(plan_for --setup 'echo built' \
            --run 'echo one > "$TX_OUT/first-only.txt"' \
            --tag t --timeout 10 -- a)"
    run_tx run --plan "$plan" --start-in 1 --no-skew-check -d first --quiet
    assert_status 0 "$RUN_RC" "first run"
    assert_file_exists "first/t~a~out~first-only.txt"
    assert_file_exists "first/t~a~setup.log"

    plan="$(plan_for --run 'echo two > "$TX_OUT/second.txt"' \
            --tag t --timeout 10 -- a)"
    run_tx run --plan "$plan" --start-in 1 --no-skew-check --no-deploy \
        -d second --quiet
    assert_status 0 "$RUN_RC" "second run"
    assert_file_exists "second/t~a~out~second.txt"
    assert_no_file "second/t~a~out~first-only.txt" \
        "the last run's out/ came back as this run's"
    assert_no_file "second/t~a~setup.log" \
        "the last run's setup log came back as this run's"
}

# ---- refusals ----------------------------------------------------------------

t_resume_needs_the_sweeps_own_directory() {
    install_fake_ssh
    plan="$(plan_for --run 'true' --tag t --timeout 10 -- a b)"
    run_tx run --plan "$plan" --batch 1 --resume
    assert_status 2 "$RUN_RC" "no -d"
    assert_contains "$RUN_OUT" "give the -d the sweep was started with"

    run_tx run --plan "$plan" --batch 1 --resume -d nowhere
    assert_status 2 "$RUN_RC" "a directory no sweep made"
    assert_contains "$RUN_OUT" "holds no sweep"
    assert_no_file nowhere "a refused resume should not make the directory"

    mkdir garbled
    echo '{"tag": "t"}' > garbled/.tx-sweep
    run_tx run --plan "$plan" --batch 1 --resume -d garbled
    assert_status 2 "$RUN_RC" "a sweep record with no id"
    assert_contains "$RUN_OUT" "names no sweep id"
    echo 'not json' > garbled/.tx-sweep
    run_tx run --plan "$plan" --batch 1 --resume -d garbled
    assert_status 2 "$RUN_RC" "a sweep record that is not JSON"
    assert_contains "$RUN_OUT" "is not a sweep record"

    # Refused before anything touched the fleet.
    assert_no_file "$FAKE_ROOT/a$TX_REMOTE_DIR"
}

echo "sweeps"
run_test "one id on every record"               t_a_sweep_has_one_id_on_every_record
run_test "an earlier sweep's hosts run again"   t_an_earlier_sweeps_hosts_run_again
run_test "a clean sweep resumes, no host twice" t_a_clean_sweep_resumes_without_running_a_host_twice
run_test "another sweep's filed record"         t_another_sweeps_record_in_the_collection_does_not_count
run_test "no-deploy collects only this run"     t_no_deploy_does_not_collect_what_the_last_run_wrote
run_test "resume needs the sweep's directory"   t_resume_needs_the_sweeps_own_directory
report_tests
