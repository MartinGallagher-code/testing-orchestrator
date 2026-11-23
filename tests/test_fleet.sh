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
# in state Z until it is reaped, and kill -0 still answers for it. A killed
# orphan stays one wherever init does not reap it (as in some containers),
# which would read every kill as a miss. The TX-002 tests below use it too.
alive() {
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$1/status" 2>/dev/null
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

# ---- TX-002: a --remote-dir another user owns or can write to --------------
#
# The default /var/tmp/tx sits in a world-writable directory, so any user on
# a host can make it first; whoever owns or can write to it could swap tx.py
# before it runs, or plant an agent.pid for stop to kill. Each test from here
# to the end marker failed on 1.1.0, and test_remote_dir_mutations.sh undoes
# each part of the guard in a copy of tx.py and checks that its test fails.

# ls, not stat: stat's flags differ between GNU and BSD.
# shellcheck disable=SC2012
dir_mode() { ls -ld -- "$1" | cut -c1-10; }

host_dir() { printf '%s\n' "$FAKE_ROOT/$1$TX_REMOTE_DIR"; }

# plant DIR -- what somebody else would leave there: their own tx.py, and a
# run record and an agent log that are not this run's.
plant() {
    mkdir -p "$1"
    printf 'planted\n' > "$1/tx.py"
    printf '{"state": "done", "host": "planted", "exit": 0}\n' > "$1/run.json"
    printf 'planted\n' > "$1/agent.log"
}

# victim DIR -- a process nothing tx does may signal: the one a planted
# agent.pid names. Echoes its pid; the caller kills it. It works in DIR and
# its command line says `tx.py agent`, which is what 1.1.1's own test of an
# agent (tx_ours: alive, `tx.py agent`, working in --remote-dir) takes for
# this run's -- so in these tests only the --remote-dir guard stands
# between it and a signal. A plain `sleep` would be spared by that test
# alone, and a test using one could not tell the guard was gone.
victim() {
    (cd "$1" && exec -a "python3 tx.py agent --decoy" sleep 60) \
        < /dev/null > /dev/null 2>&1 &
    local p=$! i=0
    # Handed back only once it is the decoy: until the exec, it is still
    # the subshell, and nothing would take that for an agent.
    while [ "$i" -lt 100 ] \
            && ! tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'tx[.]py agent'; do
        sleep 0.05
        i=$((i + 1))
    done
    echo "$p"
}

# untouched DIR -- the planted files are as they were left.
untouched() {
    assert_eq planted "$(cat "$1/tx.py")" "tx.py in $1 was replaced"
    assert_eq planted "$(cat "$1/agent.log")" "agent.log in $1 was replaced"
    [ -z "$(find "$1" -name '.tx-incoming.*')" ] \
        || fail "tx made a staging directory in $1"
}

# give_away DIR -- make DIR another user's: chown it to nobody when this run
# is root (as in CI's Python 3.6 container), and otherwise stand another user
# in with an `id` on the hosts' PATH that gives the ssh user a uid that does
# not own it. Prints which it did.
give_away() {
    if [ "$(id -u)" = 0 ] && chown nobody "$1" 2>/dev/null; then
        echo chown
        return 0
    fi
    printf '#!/bin/sh\n[ "${1:-}" = -u ] && { echo 4242; exit 0; }\nexec env PATH=/usr/bin:/bin id "$@"\n' \
        > "$FAKE_BIN/id"
    chmod +x "$FAKE_BIN/id"
    echo id
}

t_a_symlinked_remote_dir_is_refused_and_its_target_left_alone() {
    # A symlink at --remote-dir points the whole run somewhere else: start
    # used to deploy through it and clean to delete through it.
    install_fake_ssh
    plan="$(fleet_with_job web01)"
    d="$(host_dir web01)"
    target="$TEST_TMPDIR/elsewhere"
    plant "$target"
    chmod 0700 "$target"
    v="$(victim "$target")"
    echo "$v" > "$target/agent.pid"
    mkdir -p "$(dirname "$d")"
    ln -s "$target" "$d"
    local cmd
    for cmd in "start --start-in 1 --no-skew-check" \
               "start --no-deploy --start-in 1 --no-skew-check" \
               "stop" "clean --yes" "collect -d got" "logs -d got"; do
        # shellcheck disable=SC2086
        run_tx $cmd --plan "$plan"
        assert_status 1 "$RUN_RC" "tx $cmd through a symlink"
        assert_contains "$RUN_OUT" \
            "REFUSED: --remote-dir $d is a symlink or not a directory (lrw" "tx $cmd"
    done
    # With a trailing slash the path names what the link points to; it is
    # still the link that is checked.
    run_tx start --plan "$plan" --remote-dir "$TX_REMOTE_DIR/" --start-in 1 --no-skew-check
    assert_status 1 "$RUN_RC" "start with a trailing slash"
    assert_contains "$RUN_OUT" "REFUSED: --remote-dir $d is a symlink"
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "web01  REFUSED: --remote-dir $d is a symlink"
    alive "$v" || fail "the pid planted behind the symlink was signalled"
    kill "$v" 2>/dev/null
    untouched "$target"
    assert_eq "$v" "$(cat "$target/agent.pid")" "agent.pid behind the symlink was touched"
    [ -L "$d" ] || fail "the symlink itself was removed"
    assert_eq "" "$(ls -A got 2>/dev/null)" "something was collected through the symlink"
}

t_a_group_or_world_writable_remote_dir_is_refused() {
    # The ssh user's own directory, but one somebody else can write to:
    # whoever can write there can swap tx.py, so it is refused just the same.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    a="$(host_dir web01)"
    b="$(host_dir web02)"
    plant "$a"
    plant "$b"
    chmod 0770 "$a"
    chmod 0707 "$b"
    local cmd
    for cmd in "start --start-in 1 --no-skew-check" "stop" "clean --yes"; do
        # shellcheck disable=SC2086
        run_tx $cmd --plan "$plan"
        assert_status 1 "$RUN_RC" "tx $cmd"
        assert_contains "$RUN_OUT" \
            "REFUSED: --remote-dir $a is owned by $(id -un) (uid $(id -u)), mode drwxrwx---; the ssh user is uid $(id -u): its group can write to it." "tx $cmd"
        assert_contains "$RUN_OUT" \
            "REFUSED: --remote-dir $b is owned by $(id -un) (uid $(id -u)), mode drwx---rwx; the ssh user is uid $(id -u): others can write to it." "tx $cmd"
        assert_contains "$RUN_OUT" "chmod go-w it" "tx $cmd says what to do"
        assert_contains "$RUN_OUT" "FAILED on 2/2 hosts" "tx $cmd"
    done
    untouched "$a"
    untouched "$b"
}

t_a_remote_dir_another_user_owns_is_refused() {
    # Not writable by anybody else, but not the ssh user's: its owner can
    # put anything in it. Every command refuses it, naming the owner.
    install_fake_ssh
    plan="$(fleet_with_job web01)"
    d="$(host_dir web01)"
    plant "$d"
    chmod 0755 "$d"
    v="$(victim "$d")"
    echo "$v" > "$d/agent.pid"
    how="$(give_away "$d")"
    local cmd
    for cmd in "start --start-in 1 --no-skew-check" \
               "start --no-deploy --start-in 1 --no-skew-check" \
               "stop" "clean --yes" "collect -d got" "logs -d got" "doctor"; do
        # shellcheck disable=SC2086
        run_tx $cmd --plan "$plan"
        assert_status 1 "$RUN_RC" "tx $cmd in another user's directory"
        assert_contains "$RUN_OUT" "REFUSED: --remote-dir $d is owned by" "tx $cmd"
        assert_contains "$RUN_OUT" "it is not owned by the ssh user" "tx $cmd"
    done
    if [ "$how" = chown ]; then
        assert_contains "$RUN_OUT" "is owned by nobody (uid" "it names the owner"
    else
        assert_contains "$RUN_OUT" "the ssh user is uid 4242" "it names the ssh user's uid"
    fi
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "web01  REFUSED: --remote-dir $d is owned by"
    alive "$v" || fail "the pid planted in another user's directory was signalled"
    kill "$v" 2>/dev/null
    untouched "$d"
    assert_eq "" "$(ls -A got 2>/dev/null)" "something was collected from another user's directory"
}

t_a_planted_pid_in_a_refused_dir_is_never_signalled() {
    # stop and clean kill what agent.pid names. In a directory anybody can
    # write to, that is whatever process somebody else chose.
    install_fake_ssh
    plan="$(fleet_with_job web01)"
    d="$(host_dir web01)"
    plant "$d"
    chmod 0777 "$d"
    v="$(victim "$d")"
    echo "$v" > "$d/agent.pid"
    run_tx stop --plan "$plan"
    assert_status 1 "$RUN_RC" "stop in a world-writable directory"
    assert_contains "$RUN_OUT" "REFUSED: --remote-dir $d"
    alive "$v" || fail "stop signalled the planted pid"
    run_tx clean --plan "$plan" --yes
    assert_status 1 "$RUN_RC" "clean in a world-writable directory"
    assert_contains "$RUN_OUT" "REFUSED: --remote-dir $d"
    alive "$v" || fail "clean signalled the planted pid"
    [ -d "$d" ] || fail "clean deleted a directory it refused"
    kill "$v" 2>/dev/null
    untouched "$d"
}

t_a_new_remote_dir_is_made_private() {
    # When tx makes the directory, it makes it 0700 whatever the umask. One
    # that is already there keeps its mode, and so does the parent.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    a="$(host_dir web01)"
    b="$(host_dir web02)"
    mkdir -p "$(dirname "$a")" "$b"
    chmod 0755 "$(dirname "$a")"
    chmod 0750 "$b"
    (umask 000 && python3 "$TX" start --plan "$plan" --start-in 1 --no-skew-check) \
        > start.out 2>&1
    assert_status 0 $? "start: $(cat start.out)"
    assert_eq drwx------ "$(dir_mode "$a")" "the new directory"
    assert_eq drwxr-xr-x "$(dir_mode "$(dirname "$a")")" "its parent"
    assert_eq drwxr-x--- "$(dir_mode "$b")" "a directory that was already there"
    assert_file_exists "$a/tx.py"
    [ -z "$(find "$FAKE_ROOT" -name '.tx-incoming.*')" ] || fail "a staging directory was left behind"
    await_fleet "$plan" 2 || fail "the job never finished"
}

t_clean_takes_a_leftover_staging_directory() {
    # A deploy cut short between the copy and the rename (the ssh dropped)
    # leaves its stage, .tx-incoming.*, and a start cut short its temporary
    # pid file. Both are tx's: clean removes them with the rest, rather than
    # refusing the host over "a thing tx did not put there" (1.1.1's rule).
    install_fake_ssh
    fake_pgrep 1
    plan="$(fleet_with_job web01)"
    d="$(host_dir web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC" "start"
    await_fleet "$plan" 1 || fail "the job never finished"
    mkdir -m 700 "$d/.tx-incoming.4242.deadbeef"
    printf 'half a copy\n' > "$d/.tx-incoming.4242.deadbeef/tx.py"
    printf '4242\n' > "$d/.tx-incoming.pid.4243"
    run_tx clean --plan "$plan" --yes
    assert_status 0 "$RUN_RC" "clean: $RUN_OUT"
    assert_not_contains "$RUN_OUT" "REFUSED"
    assert_no_file "$d" "the directory, stage and all, should be gone"
}

t_a_symlink_at_the_agent_payload_or_pid_file_is_replaced_not_followed() {
    # scp and `>` both write through a symlink at the name they write to,
    # into whatever it points at. The agent and the payload go into a
    # private stage and are renamed into place, and agent.pid is written
    # under a name of its own and renamed: each link is replaced.
    install_fake_ssh
    plan="$(fleet_with_job web01)"
    d="$(host_dir web01)"
    mkdir -p "$d"
    chmod 0700 "$d"
    local f
    for f in tx.py payload.tar.gz; do
        printf 'keep me\n' > "$TEST_TMPDIR/victim.$f"
        ln -s "$TEST_TMPDIR/victim.$f" "$d/$f"
    done
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC" "start"
    for f in tx.py payload.tar.gz; do
        assert_eq "keep me" "$(cat "$TEST_TMPDIR/victim.$f")" "the link at $f was written through"
    done
    if [ -L "$d/tx.py" ] || [ ! -f "$d/tx.py" ]; then
        fail "the link at tx.py was not replaced by the agent"
    fi
    [ -L "$d/payload.tar.gz" ] && fail "the link at payload.tar.gz was left"
    await_fleet "$plan" 1 || fail "the job never finished"
    assert_file_exists "$d/out/who" "the job ran"
    # agent.pid is written by the launch, which --no-deploy runs alone.
    printf 'keep me\n' > "$TEST_TMPDIR/victim.pid"
    rm -f "$d/agent.pid"
    ln -s "$TEST_TMPDIR/victim.pid" "$d/agent.pid"
    run_tx start --plan "$plan" --no-deploy --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC" "start --no-deploy"
    assert_eq "keep me" "$(cat "$TEST_TMPDIR/victim.pid")" "the link at agent.pid was written through"
    if [ -L "$d/agent.pid" ] || [ ! -f "$d/agent.pid" ]; then
        fail "the link at agent.pid was not replaced"
    fi
    await_fleet "$plan" 1 || fail "the second run never finished"
}

t_a_tx_py_swapped_after_the_copy_is_not_run() {
    # The copy and the launch are separate ssh round trips, and whoever can
    # write to the directory swaps tx.py in between: the launch checks the
    # directory again, in the same breath as it runs the agent. A wrapper
    # around the fake ssh plays them, just before web01's launch. Then,
    # just before the stand-down that follows, they plant an agent.pid
    # naming a process of their choosing, which must not be signalled.
    # (Planted any earlier, it would make the launch say "already running"
    # and hide whether the swapped tx.py would have run.)
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    a="$(host_dir web01)"
    # The decoy works in web01's directory, so it is there first (private,
    # as start would make it).
    mkdir -p "$(dirname "$a")"
    mkdir -m 0700 "$a"
    v="$(victim "$a")"
    mv "$FAKE_BIN/ssh" "$FAKE_BIN/ssh.real"
    cat > "$FAKE_BIN/ssh" <<SHIM
#!/usr/bin/env bash
case "\$*" in
    *nohup*--host\ web01\ *)
        if [ ! -e "$TEST_TMPDIR/swapped" ] && [ -d "$a" ]; then
            touch "$TEST_TMPDIR/swapped"
            chmod 0777 "$a"
            printf 'open("$TEST_TMPDIR/MARK", "w")\\n' > "$a/tx.py"
        fi ;;
    *\ web01\ *status=not-deployed*)
        touch "$TEST_TMPDIR/planted"
        echo "$v" > "$a/agent.pid" ;;
esac
exec "\$(dirname "\$0")/ssh.real" "\$@"
SHIM
    chmod +x "$FAKE_BIN/ssh"
    run_tx start --plan "$plan" --start-in 3 --no-skew-check
    mv "$FAKE_BIN/ssh.real" "$FAKE_BIN/ssh"
    [ -e "$TEST_TMPDIR/swapped" ] || fail "the swap never happened, so this tested nothing"
    [ -e "$TEST_TMPDIR/planted" ] || fail "the stand-down never reached web01, so this tested nothing"
    sleep 0.5
    assert_no_file "$TEST_TMPDIR/MARK" "start ran the swapped tx.py"
    assert_status 1 "$RUN_RC" "start"
    assert_contains "$RUN_OUT" "web01  REFUSED: --remote-dir $a"
    assert_contains "$RUN_OUT" "others can write to it"
    assert_contains "$RUN_OUT" "standing the armed hosts back down"
    alive "$v" || fail "the stand-down signalled the pid planted in the refused directory"
    kill "$v" 2>/dev/null
    chmod 0700 "$a"
}

t_status_collect_logs_summarize_and_doctor_name_the_refusal() {
    # The commands that only read: each says why it will not, rather than
    # reading somebody else's record as this run's or calling it unreachable.
    install_fake_ssh
    plan="$(fleet_with_job web01 web02)"
    run_tx doctor --plan "$plan"
    assert_contains "$RUN_OUT" "remote_dir=absent(start makes it, mode 700)" "doctor before a deploy"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC" "start"
    await_fleet "$plan" 2 || fail "the job never finished"
    a="$(host_dir web01)"
    chmod 0777 "$a"
    run_tx status --plan "$plan"
    assert_status 0 "$RUN_RC" "status is a report, and still exits 0"
    assert_contains "$RUN_OUT" "web01  REFUSED: --remote-dir $a is owned by"
    assert_contains "$RUN_OUT" "web02  DONE"
    run_tx summarize --plan "$plan"
    assert_status 1 "$RUN_RC" "summarize with a refused host"
    assert_contains "$RUN_OUT" "NO RESULT"
    assert_contains "$RUN_OUT" "REFUSED: --remote-dir $a"
    run_tx collect --plan "$plan" -d got
    assert_status 1 "$RUN_RC" "collect"
    assert_contains "$RUN_OUT" "REFUSED: --remote-dir $a"
    assert_eq "" "$(find got -name '*~web01~*')" "collect read the refused directory"
    assert_file_exists "got/job~web02~out~who" "the other host still came back"
    run_tx logs --plan "$plan" -d logs
    assert_status 1 "$RUN_RC" "logs"
    assert_contains "$RUN_OUT" "REFUSED: --remote-dir $a"
    assert_no_file "logs/job~web01~agent.log" "logs read the refused directory"
    run_tx doctor --plan "$plan"
    assert_status 1 "$RUN_RC" "doctor"
    assert_contains "$RUN_OUT" "remote_dir=REFUSED"
    assert_contains "$RUN_OUT" "web01  REFUSED: --remote-dir $a"
    assert_contains "$RUN_OUT" "remote_dir=ok(drwx------)"
    assert_contains "$RUN_OUT" "must be the ssh user's own"
    chmod 0700 "$a"
}

t_the_shared_opt_out_lifts_the_group_check_only() {
    # --allow-shared-remote-dir (or TX_ALLOW_SHARED_REMOTE_DIR=1) lets a
    # group-writable directory through, as for one a team shares. A symlink
    # somebody in the group planted at tx.py is replaced, never followed. A
    # world-writable one is still refused.
    install_fake_ssh
    plan="$(fleet_with_job web01)"
    d="$(host_dir web01)"
    mkdir -p "$d"
    chmod 0770 "$d"
    printf 'keep me\n' > "$TEST_TMPDIR/important.py"
    ln -s "$TEST_TMPDIR/important.py" "$d/tx.py"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 1 "$RUN_RC" "a group-writable directory without the opt-out"
    assert_contains "$RUN_OUT" "its group can write to it"
    assert_contains "$RUN_OUT" "--allow-shared-remote-dir" "the refusal names the opt-out"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check --allow-shared-remote-dir
    assert_status 0 "$RUN_RC" "a group-writable directory with the opt-out"
    assert_eq "keep me" "$(cat "$TEST_TMPDIR/important.py")" "the planted symlink was followed"
    if [ -L "$d/tx.py" ] || [ ! -f "$d/tx.py" ]; then
        fail "the symlink was not replaced by the agent"
    fi
    await_fleet "$plan" 1 || fail "the job never finished"
    TX_ALLOW_SHARED_REMOTE_DIR=1 run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "web01  DONE" "status with TX_ALLOW_SHARED_REMOTE_DIR=1"
    chmod 0777 "$d"
    TX_ALLOW_SHARED_REMOTE_DIR=1 run_tx stop --plan "$plan"
    assert_status 1 "$RUN_RC" "a world-writable directory even with the opt-out"
    assert_contains "$RUN_OUT" "others can write to it"
    assert_not_contains "$RUN_OUT" "its group can write" "the group check is lifted"
    chmod 0770 "$d"
    run_tx clean --plan "$plan" --yes --allow-shared-remote-dir
    assert_status 0 "$RUN_RC" "clean with the opt-out"
    assert_no_file "$d" "clean removed the directory"
    assert_eq "keep me" "$(cat "$TEST_TMPDIR/important.py")" "clean followed the symlink"
}

t_check_hints_and_help_describe_the_guard() {
    # check contacts no host, so it says what each will be asked and where
    # the answer is; hints and help name the opt-out.
    install_fake_ssh
    plan="$(fleet_with_job web01)"
    run_tx check --plan "$plan"
    assert_contains "$RUN_OUT" "remote $TX_REMOTE_DIR on each host: must be a real directory the ssh user owns"
    assert_contains "$RUN_OUT" "tx doctor checks each host"
    run_tx hints
    assert_contains "$RUN_OUT" "--allow-shared-remote-dir"
    run_tx help
    assert_contains "$RUN_OUT" "--allow-shared-remote-dir"
    assert_contains "$RUN_OUT" "TX_ALLOW_SHARED_REMOTE_DIR=1"
}

# ---- end TX-002 -------------------------------------------------------------

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
run_test "a symlinked remote dir is refused"   t_a_symlinked_remote_dir_is_refused_and_its_target_left_alone
run_test "a writable remote dir is refused"    t_a_group_or_world_writable_remote_dir_is_refused
run_test "another user's remote dir refused"   t_a_remote_dir_another_user_owns_is_refused
run_test "a planted pid is never signalled"    t_a_planted_pid_in_a_refused_dir_is_never_signalled
run_test "a new remote dir is made 0700"       t_a_new_remote_dir_is_made_private
run_test "clean takes a leftover stage"      t_clean_takes_a_leftover_staging_directory
run_test "a planted symlink is replaced"       t_a_symlink_at_the_agent_payload_or_pid_file_is_replaced_not_followed
run_test "a swapped tx.py is not run"          t_a_tx_py_swapped_after_the_copy_is_not_run
run_test "readers name the refusal"            t_status_collect_logs_summarize_and_doctor_name_the_refusal
run_test "the shared opt-out: group only"      t_the_shared_opt_out_lifts_the_group_check_only
run_test "check, hints and help say so"        t_check_hints_and_help_describe_the_guard
report_tests
