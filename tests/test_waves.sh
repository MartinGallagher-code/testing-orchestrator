#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# Coverage mode: the whole fleet, a few hosts at a time. What has to hold
# is that every host is reached, each wave is still simultaneous in
# itself, and one sweep ends as one set of results.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# A job's command is single-quoted throughout this file on purpose: it has
# to reach the far side unexpanded, so that $TX_OUT means the out
# directory on the host rather than an empty variable in this shell. That
# non-expansion is SC2016's whole warning and is the behaviour under test.
# shellcheck disable=SC2016

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# A plan whose job records which host ran it. Echoes the plan path.
sweep_plan() {
    plan_for --run 'echo "$TX_HOST" > "$TX_OUT/who"' --tag sweep \
             --timeout 30 -- "$@"
}

# ---- coverage ---------------------------------------------------------------

t_every_host_is_reached_however_the_waves_fall() {
    # The whole promise: the fleet is used up, not sampled.
    install_fake_ssh
    plan="$(sweep_plan a b c d e)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    for h in a b c d e; do
        assert_file_exists "results/sweep~$h~out~who" "$h was never run"
        assert_eq "$h" "$(cat "results/sweep~$h~out~who")"
    done
    assert_contains "$RUN_OUT" "covered 5 of 5 hosts in 3 waves"
}

t_a_fleet_that_does_not_divide_evenly_still_finishes() {
    # Five hosts in waves of two is two full waves and a short one; the
    # remainder is where an off-by-one would drop a host silently.
    install_fake_ssh
    plan="$(sweep_plan a b c d e)"
    run_tx run --plan "$plan" --batch 3 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_eq "5" "$(find results -name 'sweep~*~out~who' | wc -l | tr -d ' ')"
    assert_contains "$RUN_OUT" "in 2 waves"
}

t_a_batch_bigger_than_the_fleet_is_one_wave() {
    install_fake_ssh
    plan="$(sweep_plan a b)"
    run_tx run --plan "$plan" --batch 50 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "in 1 wave of at most 50"
    assert_eq "2" "$(find results -name 'sweep~*~out~who' | wc -l | tr -d ' ')"
}

t_a_batch_of_one_walks_the_fleet() {
    install_fake_ssh
    plan="$(sweep_plan a b c)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "in 3 waves"
    assert_eq "3" "$(find results -name 'sweep~*~out~who' | wc -l | tr -d ' ')"
}

t_only_the_wave_is_running_at_any_moment() {
    # The reason coverage mode exists: something cannot take the whole
    # fleet at once. If more than a wave's worth ever ran together the
    # mode would be pointless, so the job records overlap itself.
    install_fake_ssh
    counter="$TEST_TMPDIR/live"
    mkdir -p "$counter"
    plan="$(plan_for --run "touch $counter/\$TX_HOST
ls $counter | wc -l > \"\$TX_OUT/seen\"
sleep 1
rm -f $counter/\$TX_HOST" --tag over --timeout 30 -- a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    # Each host counted how many were live when it started. With waves of
    # two, nobody should ever have seen three.
    worst="$(cat results/over~*~out~seen | sort -n | tail -1)"
    assert_between 1 2 "$worst" "a host saw $worst hosts running at once"
}

# ---- one sweep, one set of results ------------------------------------------

t_one_sweep_lands_in_one_directory() {
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    # One directory, not one per wave.
    assert_eq "1" "$(find . -maxdepth 1 -type d -name 'results*' | wc -l | tr -d ' ')"
    assert_eq "0" "$(find . -maxdepth 1 -type d -name 'tx-*' | wc -l | tr -d ' ')"
}

t_without_a_name_the_sweep_still_gets_one_directory() {
    # The default is stamped with the time, and a fresh one per wave would
    # scatter a single sweep across several.
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check --quiet
    assert_status 0 "$RUN_RC"
    assert_eq "1" "$(find . -maxdepth 1 -type d -name 'tx-*' | wc -l | tr -d ' ')" \
        "four waves should not make four directories"
    assert_eq "4" "$(find . -name 'sweep~*~out~who' | wc -l | tr -d ' ')"
}

t_the_report_counts_the_whole_fleet_not_the_last_wave() {
    # The final report is rendered from what each wave recorded while it
    # could -- by the end the early waves have been collected and maybe
    # cleaned, and polling then would read them as hosts that never
    # answered.
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --clean --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "4 of 4 hosts finished: 4 passed"
    assert_contains "$RUN_OUT" "covered 4 of 4 hosts"
    # --clean really did remove them, which is what makes the above a
    # statement about the record rather than about the fleet.
    for h in a b c d; do
        assert_no_file "$FAKE_ROOT/$h$TX_REMOTE_DIR" "$h was not cleaned"
    done
}

t_the_spread_does_not_claim_the_waves_were_simultaneous() {
    # Each host's offset is measured against its own wave's instant. The
    # report must not read as though the whole fleet started together,
    # because in wave mode it deliberately did not.
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_contains "$RUN_OUT" "within each wave"
    assert_contains "$RUN_OUT" "not with each other"
    assert_not_contains "$RUN_OUT" "spread 0ms across 4 hosts"
}

# ---- when a wave goes wrong --------------------------------------------------

t_a_failing_job_does_not_stop_the_sweep() {
    # One bad host should not cost the rest of the fleet its coverage.
    install_fake_ssh
    plan="$(plan_for --run 'test "$TX_HOST" != b' --tag t --timeout 30 \
            -- a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 1 "$RUN_RC" "a failed host is worth an exit code"
    assert_contains "$RUN_OUT" "covered 4 of 4 hosts"
    assert_contains "$RUN_OUT" "FAILED"
    # The wave after the failure still ran.
    assert_file_exists "results/t~d~run.json"
}

t_stop_on_fail_stops_and_says_who_was_never_reached() {
    # Stopping is a choice, and the hosts nobody asked must not read as
    # hosts that passed.
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    # Take the second wave's hosts away so their wave cannot start.
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --stop-on-fail --quiet --no-deploy
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "NOT REACHED"
    assert_contains "$RUN_OUT" "not starting the remaining waves"
}

t_a_wave_that_cannot_start_is_named_not_skipped_silently() {
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --quiet --no-deploy
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "WAVE DID NOT START"
    # Both waves were tried, since --stop-on-fail was not given.
    assert_contains "$RUN_OUT" "wave 2 of 2"
}

# A file of somebody else's in HOST's working directory, put there before
# the sweep reaches it: the clean after that host's wave refuses over it.
strangers_file() {
    mkdir -p "$FAKE_ROOT/$1$TX_REMOTE_DIR"
    echo mine > "$FAKE_ROOT/$1$TX_REMOTE_DIR/notes.txt"
}

t_a_wave_that_cannot_be_cleaned_is_counted() {
    # Each wave's --clean used to be fire-and-forget: a host left exactly
    # as it was still ended in exit 0. It counts now, and the sweep goes
    # on -- the next wave is other hosts.
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    strangers_file a
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --clean --quiet
    assert_status 1 "$RUN_RC" "a wave that could not be cleaned is worth an exit code"
    assert_contains "$RUN_OUT" "REFUSED"
    assert_contains "$RUN_OUT" "covered 4 of 4 hosts"
    assert_file_exists "results/sweep~d~out~who" "the next wave should still run"
    for h in b c d; do
        assert_no_file "$FAKE_ROOT/$h$TX_REMOTE_DIR" "$h was not cleaned"
    done
    assert_file_exists "$FAKE_ROOT/a$TX_REMOTE_DIR/notes.txt"
}

t_stop_on_fail_stops_at_a_wave_that_cannot_be_cleaned() {
    install_fake_ssh
    plan="$(sweep_plan a b c d)"
    strangers_file a
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --clean --stop-on-fail --quiet
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "not starting the remaining waves"
    assert_contains "$RUN_OUT" "NOT REACHED"
    assert_no_file "results/sweep~c~out~who" "the sweep should have stopped"
}

# ---- what --stop-on-fail counts as a failed wave (TX-007) --------------------
#
# Any wave that makes the sweep exit 1: a host that failed in any of the
# report's ways, or a wave that could not start, ran out its wait, or could
# not be collected or cleaned. Each kind has its own test, and the one thing
# the report warns about without failing the run -- a teardown that failed --
# has one of its own that shows it does not stop the sweep.

# stopped_after_wave_one WHY [COVERED] -- the sweep of a, b and c, a wave
# of one each, stopped after a's wave for WHY, and b and c were never
# reached. COVERED (default 1) is how many hosts left a run record.
stopped_after_wave_one() {
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "--stop-on-fail: wave 1 failed ($1)"
    assert_contains "$RUN_OUT" "not starting the remaining waves"
    assert_not_contains "$RUN_OUT" "wave 2 of 3" "the sweep should have stopped"
    assert_contains "$RUN_OUT" "NOT REACHED"
    assert_contains "$RUN_OUT" "covered ${2:-1} of 3 hosts"
}

t_stop_on_fail_stops_when_every_job_fails() {
    # The ticket's own case: exit 3 on every host ran all three waves.
    install_fake_ssh
    plan="$(plan_for --run 'exit 3' --tag t --timeout 30 -- a b c)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --stop-on-fail --quiet
    stopped_after_wave_one "1 exited non-zero"
}

t_stop_on_fail_stops_when_one_job_in_the_wave_fails() {
    # One host's failure fails its wave, however many passed beside it.
    install_fake_ssh
    plan="$(plan_for --run 'test "$TX_HOST" != b' --tag t --timeout 30 \
            -- a b c d e f)"
    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --stop-on-fail --quiet
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "--stop-on-fail: wave 1 failed (1 exited non-zero)"
    assert_contains "$RUN_OUT" "covered 2 of 6 hosts"
    assert_no_file "results/t~c~run.json" "the sweep should have stopped"
}

t_stop_on_fail_stops_at_a_timeout() {
    install_fake_ssh
    plan="$(plan_for --run 'sleep 20' --tag t --timeout 2 -- a b c)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --stop-on-fail --quiet
    stopped_after_wave_one "1 timed out"
}

t_stop_on_fail_stops_at_a_failed_setup() {
    install_fake_ssh
    plan="$(plan_for --setup 'exit 4' --run 'true' --tag t --timeout 30 \
            -- a b c)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --stop-on-fail --quiet
    stopped_after_wave_one "1 failed setup"
}

t_stop_on_fail_stops_at_a_job_that_could_not_start() {
    # No payload holds nowhere.txt, so the job cannot be given its stdin.
    install_fake_ssh
    plan="$(plan_for --run 'cat' --stdin nowhere.txt --tag t --timeout 30 \
            -- a b c)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --stop-on-fail --quiet
    stopped_after_wave_one "1 could not start the job"
}

t_stop_on_fail_stops_at_a_host_gone_mid_job() {
    # The job kills its own agent, so the record says running and nothing
    # is left to finish it: GONE.
    install_fake_ssh
    plan="$(plan_for --run 'kill -9 $PPID; sleep 1' --tag t --timeout 30 \
            -- a b c)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --stop-on-fail --quiet
    stopped_after_wave_one "1 stopped mid-job"
}

# run_tx_waiting_4s ARGS... -- run_tx, with each wave's wait cut to 4s.
run_tx_waiting_4s() {
    RUN_OUT="$(python3 - "$(dirname "$TX")" "$@" 2>&1 <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import tx
tx._wait_deadline = lambda args, plan: time.time() + 4
sys.exit(tx.main(sys.argv[2:]))
PY
)"
    RUN_RC=$?
}

t_stop_on_fail_stops_when_the_wait_runs_out() {
    # a is still working when its wait runs out.
    install_fake_ssh
    plan="$(plan_for --run 'sleep 8' --tag t --timeout 30 -- a b c)"
    run_tx_waiting_4s run --plan "$plan" --batch 1 --start-in 1 \
        --no-skew-check -d results --stop-on-fail --quiet
    stopped_after_wave_one "its wait ran out"
}

t_stop_on_fail_stops_at_a_host_that_gives_no_result() {
    # The job takes its own host off the network, so nothing more is heard
    # from it: no result, a wait that runs out and nothing to collect. The
    # host comes first, as the report lists it.
    install_fake_ssh
    plan="$(plan_for --run 'echo "$TX_HOST" >> "$FAKE_ROOT/down.hosts"' \
            --tag t --timeout 30 -- a b c)"
    run_tx_waiting_4s run --plan "$plan" --batch 1 --start-in 1 \
        --no-skew-check -d results --stop-on-fail --quiet
    assert_contains "$RUN_OUT" "UNREACHABLE"
    stopped_after_wave_one \
        "1 gave no result; its wait ran out; the collection did not all come back" 0
}

t_stop_on_fail_stops_when_the_collection_fails() {
    # A file over --max-bytes is left on the host, and the collection says
    # so and fails; the job itself passed.
    install_fake_ssh
    plan="$(plan_for --run 'head -c 50000 /dev/zero > "$TX_OUT/big"' \
            --tag t --timeout 30 -- a b c)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --max-bytes 20000 --stop-on-fail --quiet
    assert_contains "$RUN_OUT" "OVERSIZE"
    stopped_after_wave_one "the collection did not all come back"
}

t_stop_on_fail_goes_on_past_a_failed_teardown() {
    # The report warns about a teardown that failed, and the run still
    # exits 0: it is not a failed wave, so the sweep goes on.
    install_fake_ssh
    plan="$(plan_for --run 'echo "$TX_HOST" > "$TX_OUT/who"' \
            --teardown 'exit 5' --tag sweep --timeout 30 -- a b c)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --stop-on-fail --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "TEARDOWN"
    assert_not_contains "$RUN_OUT" "--stop-on-fail:"
    assert_contains "$RUN_OUT" "covered 3 of 3 hosts"
    for h in a b c; do
        assert_file_exists "results/sweep~$h~out~who" "$h was never run"
    done
}

# ---- resume: the fleet is the record ----------------------------------------

# Start a sweep in the background and return the ORCHESTRATOR's pid.
#
# The python process itself, not `tx` -- that is a shell function here, so
# backgrounding it would give the pid of a subshell, and killing that
# leaves the real orchestrator running to race whatever comes next. This
# cost a while to find, so it is written down.
sweep_in_background() {
    python3 "$TX" "$@" > "$TEST_TMPDIR/sweep.log" 2>&1 &
    echo $!
}

t_a_killed_sweep_is_resumed_from_the_fleets_own_record() {
    # The point of --resume: nothing is remembered here, so there is
    # nothing to lose when this process dies. The hosts hold the record.
    install_fake_ssh
    # Each wave takes a couple of seconds, so killing at 7s genuinely
    # lands mid-sweep. With an instant job the whole thing finishes
    # first and the test proves nothing.
    plan="$(plan_for --run 'sleep 2; echo "$TX_HOST" > "$TX_OUT/who"' \
            --tag sweep --timeout 40 -- a b c d e f)"
    driver="$(sweep_in_background run --plan "$plan" --batch 2 --start-in 1 \
              --no-skew-check -d results --quiet)"
    sleep 7
    # The orchestrator is orphaned by the command substitution that
    # started it, so `wait` does not apply and kill -9 is asynchronous:
    # give it a moment to actually go before claiming it has.
    kill -9 "$driver" 2>/dev/null
    i=0
    while [ "$i" -lt 50 ]; do
        kill -0 "$driver" 2>/dev/null || break
        sleep 0.1
        i=$((i + 1))
    done
    kill -0 "$driver" 2>/dev/null && fail "the orchestrator outlived the kill"
    # The sweep really was interrupted: somebody is still missing.
    covered="$(find results -name 'sweep~*~out~who' 2>/dev/null | wc -l | tr -d ' ')"
    assert_between 1 5 "$covered" \
        "the kill should land mid-sweep, but $covered of 6 were already done"

    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --resume --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "asking the fleet where it got to"
    for h in a b c d e f; do
        assert_file_exists "results/sweep~$h~out~who" \
            "$h was never covered by the resumed sweep"
    done
    assert_contains "$RUN_OUT" "re-collecting"
}

t_resume_waits_for_hosts_still_running_rather_than_restarting_them() {
    # Agents are detached, so an interrupted sweep leaves its last wave
    # still working. Starting those hosts again would trample a run that
    # is nearly done -- and the deploy would refuse anyway.
    install_fake_ssh
    plan="$(plan_for --run 'sleep 6; echo "$TX_HOST" > "$TX_OUT/who"' \
            --tag sweep --timeout 40 -- a b c d)"
    driver="$(sweep_in_background run --plan "$plan" --batch 2 --start-in 1 \
              --no-skew-check -d results --quiet)"
    # Long enough for wave 1 to be well underway, not long enough to end.
    sleep 4
    kill -9 "$driver" 2>/dev/null
    i=0
    while [ "$i" -lt 50 ]; do
        kill -0 "$driver" 2>/dev/null || break
        sleep 0.1
        i=$((i + 1))
    done

    run_tx run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        -d results --resume --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "still running"
    assert_contains "$RUN_OUT" "rather than starting them over"
    assert_not_contains "$RUN_OUT" "already running here"
    for h in a b c d; do
        assert_file_exists "results/sweep~$h~out~who" "$h was lost"
    done
}

t_resuming_a_finished_sweep_does_nothing() {
    install_fake_ssh
    plan="$(sweep_plan a b)"
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --quiet
    assert_status 0 "$RUN_RC"
    # The same -d: that directory holds the sweep's id, and resume counts
    # only results that carry it (TX-008).
    run_tx run --plan "$plan" --batch 1 --start-in 1 --no-skew-check \
        -d results --resume --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "nothing left to cover"
    assert_contains "$RUN_OUT" "2 done, 0 still running, 0 left"
}

t_resume_needs_waves_to_resume() {
    install_fake_ssh
    plan="$(sweep_plan a b)"
    run_tx run --plan "$plan" --resume
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "no waves to resume"
}

# ---- polling ----------------------------------------------------------------

t_the_poll_backs_off_the_longer_it_waits() {
    # Every poll is an ssh per host, landing on the machines under
    # measurement. A fixed two seconds is sixty thousand connections over
    # a ten-minute run on two hundred hosts, to learn nothing.
    out="$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1])
import tx
print(tx.poll_interval(0), tx.poll_interval(60), tx.poll_interval(600),
      tx.poll_interval(99999), tx.poll_interval(99999, 5.0))
' "$REPO_ROOT/testing_orchestrator")"
    read -r at0 at60 at600 far pinned <<< "$out"
    assert_eq "2.0" "$at0" "it should start responsive"
    assert_eq "6.0" "$at60" "and grow with the wait"
    assert_eq "30.0" "$at600" "up to a ceiling"
    assert_eq "30.0" "$far" "that it does not exceed"
    assert_eq "5.0" "$pinned" "--poll pins it"
}

t_a_poll_interval_that_cannot_mean_anything_is_refused() {
    install_fake_ssh
    plan="$(sweep_plan a b)"
    for bad in 0 -1; do
        run_tx run --plan "$plan" --poll "$bad"
        assert_status 2 "$RUN_RC" "--poll $bad should be refused"
        assert_contains "$RUN_OUT" "--poll"
    done
}

# ---- refusals ---------------------------------------------------------------

t_a_wave_size_that_cannot_mean_anything_is_refused() {
    install_fake_ssh
    plan="$(sweep_plan a b)"
    for bad in 0 -3; do
        run_tx run --plan "$plan" --batch "$bad"
        assert_status 2 "$RUN_RC" "--batch $bad should be refused"
        assert_contains "$RUN_OUT" "--batch"
    done
}

t_stop_on_fail_without_waves_is_refused() {
    # Without --batch there is one wave and nothing to stop, so the flag
    # would silently do nothing.
    install_fake_ssh
    plan="$(sweep_plan a b)"
    run_tx run --plan "$plan" --stop-on-fail
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "only one wave"
}

echo "waves"
run_test "every host is reached"               t_every_host_is_reached_however_the_waves_fall
run_test "an uneven fleet still finishes"      t_a_fleet_that_does_not_divide_evenly_still_finishes
run_test "a batch bigger than the fleet"       t_a_batch_bigger_than_the_fleet_is_one_wave
run_test "a batch of one walks the fleet"      t_a_batch_of_one_walks_the_fleet
run_test "only a wave runs at any moment"      t_only_the_wave_is_running_at_any_moment
run_test "one sweep, one directory"            t_one_sweep_lands_in_one_directory
run_test "an unnamed sweep is one directory"   t_without_a_name_the_sweep_still_gets_one_directory
run_test "the report counts the whole fleet"   t_the_report_counts_the_whole_fleet_not_the_last_wave
run_test "the spread does not overclaim"       t_the_spread_does_not_claim_the_waves_were_simultaneous
run_test "a failing job does not stop it"      t_a_failing_job_does_not_stop_the_sweep
run_test "stop-on-fail names the unreached"    t_stop_on_fail_stops_and_says_who_was_never_reached
run_test "a wave that cannot start is named"   t_a_wave_that_cannot_start_is_named_not_skipped_silently
run_test "an uncleaned wave is counted"        t_a_wave_that_cannot_be_cleaned_is_counted
run_test "stop-on-fail stops at an unclean"    t_stop_on_fail_stops_at_a_wave_that_cannot_be_cleaned
run_test "stop-on-fail: every job fails"       t_stop_on_fail_stops_when_every_job_fails
run_test "stop-on-fail: one job fails"         t_stop_on_fail_stops_when_one_job_in_the_wave_fails
run_test "stop-on-fail: a timeout"             t_stop_on_fail_stops_at_a_timeout
run_test "stop-on-fail: a failed setup"        t_stop_on_fail_stops_at_a_failed_setup
run_test "stop-on-fail: a job that never ran"  t_stop_on_fail_stops_at_a_job_that_could_not_start
run_test "stop-on-fail: a host gone mid-job"   t_stop_on_fail_stops_at_a_host_gone_mid_job
run_test "stop-on-fail: the wait runs out"     t_stop_on_fail_stops_when_the_wait_runs_out
run_test "stop-on-fail: a host with no result" t_stop_on_fail_stops_at_a_host_that_gives_no_result
run_test "stop-on-fail: a failed collection"   t_stop_on_fail_stops_when_the_collection_fails
run_test "stop-on-fail: not a teardown"        t_stop_on_fail_goes_on_past_a_failed_teardown
run_test "a killed sweep is resumed"           t_a_killed_sweep_is_resumed_from_the_fleets_own_record
run_test "resume waits for live work"          t_resume_waits_for_hosts_still_running_rather_than_restarting_them
run_test "resuming a finished sweep"           t_resuming_a_finished_sweep_does_nothing
run_test "resume needs waves"                  t_resume_needs_waves_to_resume
run_test "the poll backs off"                  t_the_poll_backs_off_the_longer_it_waits
run_test "an impossible poll interval"         t_a_poll_interval_that_cannot_mean_anything_is_refused
run_test "an impossible wave size"             t_a_wave_size_that_cannot_mean_anything_is_refused
run_test "stop-on-fail needs waves"            t_stop_on_fail_without_waves_is_refused
report_tests
