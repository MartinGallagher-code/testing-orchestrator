#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# Deploy, the synchronised start, status, stop and clean -- exercised end
# to end against a fake fleet, so the whole workflow is covered without a
# network or a second machine.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# A job's command is single-quoted throughout this file on purpose: it has
# to reach the far side unexpanded, so that $TX_OUT means the out
# directory on the host rather than an empty variable in this shell. That
# non-expansion is SC2016's whole warning and is the behaviour under test.
# shellcheck disable=SC2016

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"


# A fleet with a working payload, ready to start. Echoes the plan path.
#
# It does NOT install the fake ssh: callers use it in a command
# substitution, and a subshell's `export PATH` reaches nobody. Every test
# below calls install_fake_ssh itself, in its own shell, first.
fleet_with_job() {
    mkdir -p bench
    cat > bench/bench.sh <<'SH'
#!/bin/sh
echo "ran on $TX_HOST"
echo "$TX_HOST" > "$TX_OUT/who"
SH
    chmod +x bench/bench.sh
    plan_for --payload ./bench --run ./bench.sh --tag job --timeout 30 -- "$@"
}

# Wait until every host has a finished run record, or give up.
await_fleet() {
    local plan="$1" n="$2" i=0
    while [ "$i" -lt 100 ]; do
        if [ "$(find "$FAKE_ROOT" -name run.json -exec grep -l '"state": "done"' {} + 2>/dev/null | wc -l)" -ge "$n" ]; then
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# agent_pid HOST [DIR] -- what the run out of DIR (default $TX_REMOTE_DIR)
# wrote as its agent's pid on HOST.
agent_pid() {
    cat "$FAKE_ROOT/$1${2:-$TX_REMOTE_DIR}/agent.pid" 2>/dev/null
}

# alive PID -- a live process, and not a zombie: a KILLed agent can sit
# in state Z until it is reaped, and kill -0 still answers for it.
alive() {
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
    ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null
}

# await_done HOST DIR -- the run out of DIR on HOST has finished.
await_done() {
    local f="$FAKE_ROOT/$1$2/run.json" i=0
    while [ "$i" -lt 100 ]; do
        grep -q '"state": "done"' "$f" 2>/dev/null && return 0
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# start_stray_agent DIR -- a real agent, armed five minutes out, started
# by hand out of DIR the way tx starts one (`python3 tx.py agent` from
# inside it), but written in no pid file. Echoes its pid.
start_stray_agent() {
    local at run
    at="$(python3 -c 'import time; print("%.3f" % (time.time() + 300))')"
    run="$(printf 'sleep 1' | base64)"
    (cd "$1" && exec python3 tx.py agent --host stray --at "$at" \
        --run "$run" --timeout 30 < /dev/null > /dev/null 2>&1) &
    echo $!
}

# Two runs on the same hosts, one out of $TX_REMOTE_DIR and one out of
# $TX_REMOTE_DIR-b, each a job that takes a few seconds and then says it
# finished. Sets $plan, and $a and $b to the two agents' pids on web01.
#
# The fake hosts share one kernel, so every agent of every "host" is
# visible from every other: that is the very situation a real host is in
# with two runs on it, and a test here passes only if tx tells them apart.
two_runs() {
    plan="$(plan_for --run 'sleep 5; echo done > "$TX_OUT/finished"' \
            --timeout 60 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC" "run A should start"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check \
        --remote-dir "$TX_REMOTE_DIR-b"
    assert_status 0 "$RUN_RC" "run B should start beside it"
    a="$(agent_pid web01)"
    b="$(agent_pid web01 "$TX_REMOTE_DIR-b")"
    alive "$a" || fail "run A's agent should be running"
    alive "$b" || fail "run B's agent should be running"
}

# B went on as though A had never been touched: its agent outlived A's
# stop, and its job ran to the end.
run_b_was_left_alone() {
    alive "$b" || fail "stopping run A took run B's agent down too"
    await_done web01 "$TX_REMOTE_DIR-b" || fail "run B never finished"
    assert_file_exists "$FAKE_ROOT/web01$TX_REMOTE_DIR-b/out/finished" \
        "run B's job should have run to the end"
}

# ---- deploy ----------------------------------------------------------------

t_the_payload_lands_unpacked_on_every_host() {
    # The deploy is the step that has to work before anything else can:
    # the agent and the payload both have to be there, and the payload
    # has to be *unpacked*, not left as the tarball it travelled in.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC" "start should succeed"
    for h in web01 web02; do
        d="$FAKE_ROOT/$h$TX_REMOTE_DIR"
        assert_file_exists "$d/tx.py" "the agent should be on $h"
        assert_file_exists "$d/bench.sh" "the payload should be unpacked on $h"
        assert_no_file "$d/payload.tar.gz" "the tarball should not be left behind"
    done
}

t_a_payload_keeps_its_shape_and_its_execute_bit() {
    install_fake_ssh
    mkdir -p bench/data
    printf 'x\n' > bench/data/input.txt
    cat > bench/bench.sh <<'SH'
#!/bin/sh
cat data/input.txt > "$TX_OUT/echoed"
SH
    chmod +x bench/bench.sh
    plan="$(plan_for --payload ./bench --run ./bench.sh --timeout 30 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    assert_file_exists "$d/data/input.txt" "a subdirectory should survive"
    [ -x "$d/bench.sh" ] || fail "the payload lost its execute bit"
    await_fleet "$plan" 1 || fail "the job never finished"
    assert_file_exists "$d/out/echoed" "the job should have read its own data"
}

t_a_job_with_no_payload_still_runs() {
    # Nothing to ship is a legitimate run: the job is whatever is already
    # on the hosts.
    install_fake_ssh
    plan="$(plan_for --run 'echo bare > "$TX_OUT/note"' --timeout 30 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC"
    await_fleet "$plan" 1 || fail "the job never finished"
    assert_file_exists "$FAKE_ROOT/web01$TX_REMOTE_DIR/out/note"
}

t_deploying_over_a_running_job_is_refused() {
    # Unpacking a new payload under a job that is still reading the old
    # one is how a run produces results nobody can account for. (A pid
    # file naming some other live process is not a job running here: see
    # "a stale agent.pid is not trusted".)
    install_fake_ssh
    plan="$(plan_for --run 'sleep 30' --timeout 60 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC" "the first start should succeed"
    pid="$(agent_pid web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 1 "$RUN_RC" "start should refuse to deploy over a live job"
    assert_contains "$RUN_OUT" "already running"
    alive "$pid" || fail "the refused start took the running job down"
    kill "$pid" 2>/dev/null
}

# ---- the synchronised start ------------------------------------------------

t_every_host_begins_at_the_same_instant() {
    # The whole point of arming rather than starting: each agent waits for
    # a wall-clock instant, so the spread across the fleet is milliseconds
    # rather than however long the ssh fan-out took.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02 web03 web04)"
    run_tx start --plan "$plan" --start-in 2 --no-skew-check
    assert_status 0 "$RUN_RC"
    await_fleet "$plan" 4 || fail "the fleet never finished"
    run_tx summarize --plan "$plan"
    assert_contains "$RUN_OUT" "START     spread"
    # Every host's recorded start must be within a hair of the instant it
    # was armed for. A second would already be too much.
    for h in web01 web02 web03 web04; do
        off="$(python3 -c 'import json,sys; print(abs(json.load(open(sys.argv[1]))["start_offset"]))' \
              "$FAKE_ROOT/$h$TX_REMOTE_DIR/run.json")"
        assert_between 0 0.5 "$off" "$h started $off s off the armed instant"
    done
}

t_the_armed_instant_is_the_same_one_for_everybody() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02 web03)"
    run_tx start --plan "$plan" --start-in 2 --no-skew-check
    assert_status 0 "$RUN_RC"
    await_fleet "$plan" 3 || fail "the fleet never finished"
    armed="$(for h in web01 web02 web03; do
        python3 -c 'import json,sys; print("%.3f" % json.load(open(sys.argv[1]))["armed_for"])' \
            "$FAKE_ROOT/$h$TX_REMOTE_DIR/run.json"
     done | sort -u | wc -l)"
    assert_eq "1" "$(echo "$armed" | tr -d ' ')" \
        "all hosts should be armed for one instant, not one each"
}

t_a_fleet_where_nothing_can_start_reports_it() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02 web03)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check --no-deploy
    # --no-deploy on a fleet where nothing was deployed: no host can
    # start, and the run says so rather than reporting a success.
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "not started on the rest"
}

t_a_fleet_that_cannot_all_be_armed_is_not_half_started() {
    # A run that began on two hosts of three is not a fleet measurement,
    # and leaving those two going would be worse than not starting: they
    # would burn the machines and produce results nobody asked for.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02 web03)"
    # Deploy to all three, then take one host's working directory away,
    # so the next start arms two and fails on the third.
    run_tx start --plan "$plan" --start-in 10 --no-skew-check
    assert_status 0 "$RUN_RC" "the setup start should succeed"
    run_tx stop --plan "$plan"
    rm -rf "$FAKE_ROOT/web03$TX_REMOTE_DIR"
    for h in web01 web02; do
        rm -f "$FAKE_ROOT/$h$TX_REMOTE_DIR/run.json"
    done

    run_tx start --plan "$plan" --start-in 20 --no-skew-check --no-deploy
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "not started on the rest"
    # The two that were armed must have been stood back down: no agent
    # left waiting for an instant that is still twenty seconds away.
    sleep 1
    for h in web01 web02; do
        pidfile="$FAKE_ROOT/$h$TX_REMOTE_DIR/agent.pid"
        assert_no_file "$pidfile" "$h was left armed after the fleet failed"
        # The record exists from the moment the agent starts, so what
        # says the job never ran is the job's own output not being there.
        assert_no_file "$FAKE_ROOT/$h$TX_REMOTE_DIR/out/who" \
            "$h ran the job even though the fleet could not all start"
    done
}

t_arming_that_overruns_its_window_is_reported() {
    # A start window shorter than the fan-out means the last hosts begin
    # late, which is exactly the failure the arming exists to prevent --
    # so it must be said out loud rather than silently tolerated.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    # A shim that takes longer than the window to contact each host.
    cat > "$FAKE_BIN/slowssh" <<'SHIM'
#!/usr/bin/env bash
sleep 1.2
exec ssh "$@"
SHIM
    chmod +x "$FAKE_BIN/slowssh"
    run_tx start --plan "$plan" --start-in 0.5 --no-skew-check \
        --ssh "$FAKE_BIN/slowssh" --jobs 1
    assert_contains "$RUN_OUT" "started late"
}

# ---- clocks ----------------------------------------------------------------

t_a_fleet_whose_clocks_agree_is_started() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    skew_host web01 0
    skew_host web02 0
    run_tx start --plan "$plan" --start-in 1
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "clocks agree"
}

t_a_fleet_whose_clocks_disagree_is_refused() {
    # "At the same instant" means nothing if the instants are not the
    # same, so this is a refusal rather than a warning.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    skew_host web01 0
    skew_host web02 45
    run_tx start --plan "$plan" --start-in 1
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "clocks disagree"
    assert_contains "$RUN_OUT" "web02"
    # And nothing was armed.
    assert_no_file "$FAKE_ROOT/web01$TX_REMOTE_DIR/run.json"
}

t_a_skew_you_have_decided_to_accept_is_accepted() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    skew_host web02 5
    run_tx start --plan "$plan" --start-in 1 --max-skew 30
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "clocks agree"
}

t_the_skew_check_can_be_skipped_entirely() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    skew_host web02 900
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC"
    assert_not_contains "$RUN_OUT" "clocks"
}

# ---- status ----------------------------------------------------------------

t_status_says_what_each_host_is_doing() {
    install_fake_ssh
    plan="$(plan_for --run 'sleep 3' --timeout 30 -- web01 web02)"
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "NOT-DEPLOYED"

    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC"
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "ARMED"

    sleep 2
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "RUNNING"
}

t_status_reports_the_exit_code_of_a_finished_job() {
    install_fake_ssh
    plan="$(plan_for --run 'exit 7' --timeout 30 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 1 || fail "the job never finished"
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "FAILED"
    assert_contains "$RUN_OUT" "exit 7"
}

# ---- stop and clean --------------------------------------------------------

t_stop_ends_the_job_and_keeps_what_it_made() {
    install_fake_ssh
    plan="$(plan_for --run 'echo early > "$TX_OUT/note"; sleep 60' --timeout 120 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2
    run_tx stop --plan "$plan"
    assert_status 0 "$RUN_RC"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    assert_file_exists "$d/out/note" "stop must not delete the results"
    assert_no_file "$d/agent.pid" "the pid file should be gone"
}

t_stop_takes_the_jobs_children_with_it() {
    # A benchmark is almost always a script that starts other things.
    # Killing only the agent leaves the machine still working, and the
    # files we are about to collect still being written.
    install_fake_ssh
    marker="$TEST_TMPDIR/still-alive"
    plan="$(plan_for --run "sh -c 'while true; do touch $marker; sleep 0.2; done' &
sleep 60" --timeout 120 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2
    [ -f "$marker" ] || fail "the grandchild never started; the test proves nothing"
    run_tx stop --plan "$plan"
    rm -f "$marker"
    sleep 1.5
    assert_no_file "$marker" "a grandchild of the job outlived the stop"
}

# Put a pgrep on the fake hosts' PATH that answers however the test needs:
# 1 for "no such process", 0 for "one is still running", 127 for a host with
# no procps at all.
#
# Every clean test says which of the three it wants, because inheriting the
# image's own pgrep makes the result depend on where the suite runs: the CI
# matrix has one and `python:3.6-slim` does not, so the same test passed on
# the runners and failed in the container -- on the very distinction this
# command was changed to draw.
fake_pgrep() {
    printf '#!/bin/sh\nexit %s\n' "$1" > "$FAKE_BIN/pgrep"
    chmod +x "$FAKE_BIN/pgrep"
}

t_clean_leaves_nothing_behind() {
    install_fake_ssh
    fake_pgrep 1        # a host that can check, and finds nothing
    plan="$(fleet_with_job web01 web02)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 2 || fail "the fleet never finished"
    run_tx clean --plan "$plan" --yes
    assert_status 0 "$RUN_RC"
    for h in web01 web02; do
        assert_no_file "$FAKE_ROOT/$h$TX_REMOTE_DIR" \
            "$h should have nothing left"
    done
    assert_contains "$RUN_OUT" "nothing of tx remains"
}

t_clean_asks_before_deleting_anything() {
    install_fake_ssh
    plan="$(fleet_with_job web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 1 || fail "the job never finished"
    # No --yes and nothing on stdin: the prompt gets EOF and must refuse.
    RUN_OUT="$(python3 "$TX" clean --plan "$plan" < /dev/null 2>&1)"
    RUN_RC=$?
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "nothing done"
    assert_file_exists "$FAKE_ROOT/web01$TX_REMOTE_DIR/run.json"
}

t_clean_does_not_claim_what_it_could_not_check() {
    # `pgrep` absent looks exactly like `pgrep` finding nothing, so
    # reading a missing one as "no agents" is how the run came to promise
    # a clean fleet it never inspected. Three answers out of one exit
    # status: 0 found, 1 none, 127 nothing to ask.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 2 || fail "the fleet never finished"

    fake_pgrep 127      # a host without procps
    run_tx clean --plan "$plan" --yes
    assert_status 0 "$RUN_RC" "the directory still went, so this is not a failure"
    assert_contains "$RUN_OUT" "UNVERIFIED"
    assert_contains "$RUN_OUT" "could not be ruled out"
    assert_not_contains "$RUN_OUT" "nothing of tx remains"
    # It really did remove the working directory.
    for h in web01 web02; do
        assert_no_file "$FAKE_ROOT/$h$TX_REMOTE_DIR" "$h was not cleaned"
    done
}

t_clean_says_so_plainly_when_it_could_check() {
    install_fake_ssh
    fake_pgrep 1        # a host that can check, and finds nothing
    plan="$(fleet_with_job web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 1 || fail "the job never finished"
    run_tx clean --plan "$plan" --yes
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "nothing of tx remains"
    assert_not_contains "$RUN_OUT" "UNVERIFIED"
}

# pgrep_lists PID... -- a pgrep on the fake hosts that finds exactly
# these agents, as a real one would on a host where they are running.
# Spelled out rather than left to the image's own pgrep for the reason
# fake_pgrep gives; clean puts each pid it names to its own test of
# whose run the agent is.
pgrep_lists() {
    printf '#!/bin/sh\necho "%s"\nexit 0\n' "$*" > "$FAKE_BIN/pgrep"
    chmod +x "$FAKE_BIN/pgrep"
}

t_clean_names_an_agent_that_outlived_it() {
    # The third answer, and the one that must not be quiet: an agent of
    # *this* run still running out of the directory. The pid file names
    # one agent; a second was started by hand out of the same directory,
    # so stopping the first leaves it -- and clean must say so and delete
    # nothing, rather than pull the directory out from under it.
    install_fake_ssh
    plan="$(plan_for --run 'sleep 30' --timeout 60 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    first="$(agent_pid web01)"
    stray="$(start_stray_agent "$d")"
    pgrep_lists "$first" "$stray"
    run_tx clean --plan "$plan" --yes
    assert_status 1 "$RUN_RC" "a fleet with an agent still on it is not clean"
    assert_contains "$RUN_OUT" "LEFTOVER"
    assert_contains "$RUN_OUT" "still running"
    assert_contains "$RUN_OUT" "$stray"
    assert_not_contains "$RUN_OUT" "nothing of tx remains"
    assert_not_contains "$RUN_OUT" "UNVERIFIED"
    assert_file_exists "$d/tx.py" "nothing should be deleted under a live agent"
    alive "$first" && fail "the agent the pid file named should have been stopped"
    kill "$stray" 2>/dev/null
}

t_doctor_says_whether_the_fleet_can_be_checked() {
    install_fake_ssh
    plan="$(fleet_with_job web01)"
    run_tx doctor --plan "$plan"
    assert_contains "$RUN_OUT" "pgrep=" \
        "doctor should say whether stop and clean can verify themselves"
}

# ---- only this run's agent -------------------------------------------------

t_stopping_one_run_leaves_another_running() {
    # The bug that started this: `tx stop` of one run waited on *any*
    # `tx.py agent`, found the second run's, and after ten seconds
    # pkill -KILLed it.
    install_fake_ssh
    two_runs
    run_tx stop --plan "$plan"
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "stopped"
    alive "$a" && fail "run A's agent should be gone"
    run_b_was_left_alone
    assert_no_file "$FAKE_ROOT/web01$TX_REMOTE_DIR/out/finished" \
        "run A's job should not have finished"
}

t_cleaning_one_run_leaves_another_running() {
    install_fake_ssh
    two_runs
    pgrep_lists "$a" "$b"      # a host with procps sees both
    run_tx clean --plan "$plan" --yes
    assert_status 0 "$RUN_RC"
    assert_not_contains "$RUN_OUT" "LEFTOVER"
    assert_no_file "$FAKE_ROOT/web01$TX_REMOTE_DIR" "run A should be cleaned"
    alive "$a" && fail "run A's agent should be gone"
    run_b_was_left_alone
}

t_a_lost_pid_file_still_finds_only_this_runs_agent() {
    # With agent.pid gone the agent is found by its working directory,
    # read from /proc -- never by name, which is both runs.
    install_fake_ssh
    two_runs
    rm -f "$FAKE_ROOT/web01$TX_REMOTE_DIR/agent.pid"
    run_tx stop --plan "$plan"
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "stopped"
    alive "$a" && fail "run A's agent should have been found and stopped"
    run_b_was_left_alone
}

t_clean_beside_another_run_is_clean() {
    # Another run's agent on the host is not a LEFTOVER of this one.
    install_fake_ssh
    two_runs
    await_done web01 "$TX_REMOTE_DIR" || fail "run A never finished"
    pgrep_lists "$b"
    run_tx clean --plan "$plan" --yes
    assert_status 0 "$RUN_RC" "another run's agent is not this run's leftover"
    assert_not_contains "$RUN_OUT" "LEFTOVER"
    assert_contains "$RUN_OUT" "nothing of tx remains"
    run_b_was_left_alone
}

t_doctor_reports_only_this_runs_agent() {
    install_fake_ssh
    two_runs
    await_done web01 "$TX_REMOTE_DIR" || fail "run A never finished"
    pgrep_lists "$b"
    run_tx doctor --plan "$plan"
    assert_contains "$RUN_OUT" "agent_running=no" \
        "run B's agent is not run A's"
    run_tx doctor --plan "$plan" --remote-dir "$TX_REMOTE_DIR-b"
    assert_contains "$RUN_OUT" "agent_running=yes" \
        "run B's own doctor should see its agent"
    run_b_was_left_alone
}

t_a_stale_pid_file_is_not_trusted() {
    # The default --remote-dir survives a reboot, so agent.pid can name a
    # pid since reused by something else of the same user's. That is not a
    # job running here: start must not refuse over it, status must not
    # call it alive, and stop and clean must not signal it -- least of all
    # its whole process group, which is what `kill -TERM -<pid>` was.
    install_fake_ssh
    fake_pgrep 1
    plan="$(fleet_with_job web01)"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 1 || fail "the job never finished"

    # A process group of somebody else's: a leader and a child in it.
    python3 -c 'import os, subprocess, sys, time
os.setpgid(0, 0)
kid = subprocess.Popen(["sleep", "60"])
open(sys.argv[1], "w").write("%d\n" % kid.pid)
time.sleep(60)' "$TEST_TMPDIR/kid" &
    leader=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$TEST_TMPDIR/kid" ] && break
        sleep 0.2
    done
    kid="$(cat "$TEST_TMPDIR/kid")"
    echo "$leader" > "$d/agent.pid"

    rm -f "$d/run.json"
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "NOT-RUNNING" "a reused pid is not this run"
    assert_not_contains "$RUN_OUT" "NOT-STARTED-YET"

    run_tx stop --plan "$plan"
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "not-running"
    alive "$leader" || fail "stop signalled a process that was never tx's"
    alive "$kid" || fail "stop signalled the whole process group"

    echo "$leader" > "$d/agent.pid"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC" "start should deploy over a stale pid file"
    assert_not_contains "$RUN_OUT" "already running"
    await_fleet "$plan" 1 || fail "the job never finished"

    echo "$leader" > "$d/agent.pid"
    run_tx clean --plan "$plan" --yes
    assert_status 0 "$RUN_RC"
    assert_no_file "$d" "clean should still remove the directory"
    alive "$leader" || fail "clean signalled a process that was never tx's"
    alive "$kid" || fail "clean signalled the whole process group"
    kill -TERM -- "-$leader" 2>/dev/null
}

t_without_proc_a_lost_pid_file_is_refused() {
    # macOS has no /proc, so with agent.pid gone nothing on the host can
    # say which agent is this run's. Killing by name is how the wrong run
    # died, so tx refuses, says to do it by hand, and touches nothing.
    install_fake_ssh
    export TX_PROC_ROOT="$TEST_TMPDIR/no-proc-here"
    plan="$(plan_for --run 'sleep 30' --timeout 60 -- web01)"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC"
    pid="$(agent_pid web01)"
    rm -f "$d/agent.pid"
    pgrep_lists "$pid"         # a host where a tx agent of yours runs

    run_tx stop --plan "$plan"
    assert_status 1 "$RUN_RC" "stop should fail on a host it cannot check"
    assert_contains "$RUN_OUT" "kill it by hand"
    alive "$pid" || fail "stop killed an agent it could not identify"

    run_tx clean --plan "$plan" --yes
    assert_status 1 "$RUN_RC" "clean should fail on a host it cannot check"
    assert_contains "$RUN_OUT" "kill it by hand"
    alive "$pid" || fail "clean killed an agent it could not identify"
    assert_file_exists "$d/tx.py" "clean should leave the directory in place"
    kill "$pid" 2>/dev/null
}

t_without_proc_the_pid_file_still_stops_the_job() {
    # The other half: with agent.pid there, a host with no /proc stops
    # its job as before.
    install_fake_ssh
    export TX_PROC_ROOT="$TEST_TMPDIR/no-proc-here"
    plan="$(plan_for --run 'sleep 30' --timeout 60 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    pid="$(agent_pid web01)"
    run_tx stop --plan "$plan"
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "stopped"
    sleep 0.5
    alive "$pid" && fail "the agent the pid file names should be stopped"
    return 0
}

# ---- clean deletes only what tx put there ---------------------------------

t_clean_will_not_delete_a_strangers_file() {
    # `rm -rf "$d"` deleted whatever --remote-dir named. A file tx did not
    # put there stops the clean on that host, by name, with nothing gone.
    install_fake_ssh
    fake_pgrep 1
    plan="$(fleet_with_job web01 web02)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 2 || fail "the fleet never finished"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    echo mine > "$d/notes.txt"
    run_tx clean --plan "$plan" --yes
    assert_status 1 "$RUN_RC" "a host clean refused is a failure"
    assert_contains "$RUN_OUT" "REFUSED"
    assert_contains "$RUN_OUT" "'notes.txt'"
    assert_contains "$RUN_OUT" "nothing deleted"
    assert_eq "mine" "$(cat "$d/notes.txt")" "the stranger's file must survive"
    for f in tx.py bench.sh run.json stdout out/who; do
        assert_file_exists "$d/$f" "nothing should be deleted on a refused host"
    done
    # The host without a stranger in it is cleaned all the same.
    assert_no_file "$FAKE_ROOT/web02$TX_REMOTE_DIR" "web02 should be clean"
}

t_clean_takes_everything_the_run_made() {
    # The other side of the record: what the payload unpacked, what setup
    # built, and what the job wrote beside itself rather than in $TX_OUT
    # (`collect = *.csv` is in the README) are all the run's, and go.
    install_fake_ssh
    fake_pgrep 1
    mkdir -p bench/src
    printf 'x\n' > bench/src/main.c
    printf 'x\n' > bench/.hidden
    cat > bench/bench.sh <<'SH'
#!/bin/sh
echo ok > results.csv
mkdir -p scratch && echo x > scratch/tmp
echo "$TX_HOST" > "$TX_OUT/who"
SH
    chmod +x bench/bench.sh
    plan="$(plan_for --payload ./bench --setup 'echo obj > src/main.o; echo bin > built' \
            --run ./bench.sh --timeout 30 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 1 || fail "the job never finished"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    assert_file_exists "$d/results.csv" "the job should have written beside itself"
    run_tx clean --plan "$plan" --yes
    assert_status 0 "$RUN_RC"
    assert_not_contains "$RUN_OUT" "REFUSED"
    assert_no_file "$d" "everything the run made should be gone"
}

t_clean_will_not_take_a_directory_it_did_not_make() {
    # A payload directory that was already there -- somebody's, under the
    # same name -- is unpacked into, but stays theirs: clean names it.
    install_fake_ssh
    fake_pgrep 1
    mkdir -p bench/data
    printf 'x\n' > bench/data/input.txt
    printf '#!/bin/sh\ntrue\n' > bench/bench.sh
    chmod +x bench/bench.sh
    plan="$(plan_for --payload ./bench --run ./bench.sh --timeout 30 -- web01)"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    mkdir -p "$d/data"
    echo precious > "$d/data/precious.txt"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    await_fleet "$plan" 1 || fail "the job never finished"
    run_tx clean --plan "$plan" --yes
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "'data'"
    assert_eq "precious" "$(cat "$d/data/precious.txt")"
}

t_a_payload_may_not_bring_its_own_record() {
    install_fake_ssh
    mkdir -p bench
    printf 'x\n' > bench/.tx-manifest
    plan="$(plan_for --payload ./bench --run true --timeout 30 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" ".tx-manifest"
    assert_no_file "$FAKE_ROOT/web01$TX_REMOTE_DIR/tx.py" "nothing should travel"
}

t_a_run_whose_clean_fails_says_so() {
    # `tx run --clean` used to drop clean's answer, so a host left as it
    # was still exited 0.
    install_fake_ssh
    fake_pgrep 1
    plan="$(fleet_with_job web01 web02)"
    mkdir -p "$FAKE_ROOT/web02$TX_REMOTE_DIR"
    echo mine > "$FAKE_ROOT/web02$TX_REMOTE_DIR/notes.txt"
    run_tx run --plan "$plan" --start-in 1 --no-skew-check -d results \
        --clean --quiet
    assert_status 1 "$RUN_RC" "a clean that failed is worth an exit code"
    assert_contains "$RUN_OUT" "REFUSED"
    assert_file_exists "results/job~web02~out~who" "the run itself went fine"
    assert_no_file "$FAKE_ROOT/web01$TX_REMOTE_DIR"
    assert_file_exists "$FAKE_ROOT/web02$TX_REMOTE_DIR/notes.txt"
}

t_a_dry_run_contacts_nothing() {
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    : > "$FAKE_ROOT/calls.log"
    run_tx start --plan "$plan" --dry-run
    assert_eq "0" "$(wc -l < "$FAKE_ROOT/calls.log" | tr -d ' ')" \
        "--dry-run should not touch the fleet"
}

echo "fleet"
run_test "the payload lands unpacked"          t_the_payload_lands_unpacked_on_every_host
run_test "a payload keeps its shape"           t_a_payload_keeps_its_shape_and_its_execute_bit
run_test "a job with no payload still runs"    t_a_job_with_no_payload_still_runs
run_test "deploying over a running job"        t_deploying_over_a_running_job_is_refused
run_test "every host begins together"          t_every_host_begins_at_the_same_instant
run_test "one instant, not one each"           t_the_armed_instant_is_the_same_one_for_everybody
run_test "a fleet with no starter reports it"  t_a_fleet_where_nothing_can_start_reports_it
run_test "a fleet is not half started"         t_a_fleet_that_cannot_all_be_armed_is_not_half_started
run_test "arming that overruns is reported"    t_arming_that_overruns_its_window_is_reported
run_test "agreeing clocks are started"         t_a_fleet_whose_clocks_agree_is_started
run_test "disagreeing clocks are refused"      t_a_fleet_whose_clocks_disagree_is_refused
run_test "a skew you accept is accepted"       t_a_skew_you_have_decided_to_accept_is_accepted
run_test "the skew check can be skipped"       t_the_skew_check_can_be_skipped_entirely
run_test "status says what each host does"     t_status_says_what_each_host_is_doing
run_test "status reports the exit code"        t_status_reports_the_exit_code_of_a_finished_job
run_test "stop keeps what the job made"        t_stop_ends_the_job_and_keeps_what_it_made
run_test "stop takes the children too"         t_stop_takes_the_jobs_children_with_it
run_test "clean leaves nothing behind"         t_clean_leaves_nothing_behind
run_test "clean asks first"                    t_clean_asks_before_deleting_anything
run_test "clean does not overclaim"            t_clean_does_not_claim_what_it_could_not_check
run_test "clean says so when it could check"   t_clean_says_so_plainly_when_it_could_check
run_test "clean names an agent left running"   t_clean_names_an_agent_that_outlived_it
run_test "doctor reports pgrep"                t_doctor_says_whether_the_fleet_can_be_checked
run_test "two runs: stop leaves the other"     t_stopping_one_run_leaves_another_running
run_test "two runs: clean leaves the other"    t_cleaning_one_run_leaves_another_running
run_test "two runs: lost pid file"             t_a_lost_pid_file_still_finds_only_this_runs_agent
run_test "two runs: clean is clean"            t_clean_beside_another_run_is_clean
run_test "two runs: doctor sees its own"       t_doctor_reports_only_this_runs_agent
run_test "a stale agent.pid is not trusted"    t_a_stale_pid_file_is_not_trusted
run_test "no /proc: lost pid file refused"     t_without_proc_a_lost_pid_file_is_refused
run_test "no /proc: pid file still stops"      t_without_proc_the_pid_file_still_stops_the_job
run_test "clean spares a stranger's file"      t_clean_will_not_delete_a_strangers_file
run_test "clean takes what the run made"       t_clean_takes_everything_the_run_made
run_test "clean spares a directory not made"   t_clean_will_not_take_a_directory_it_did_not_make
run_test "a payload brings no record"          t_a_payload_may_not_bring_its_own_record
run_test "run --clean that fails says so"      t_a_run_whose_clean_fails_says_so
run_test "a dry run contacts nothing"          t_a_dry_run_contacts_nothing
report_tests
