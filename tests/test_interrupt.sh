#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# Ctrl-C during `tx run` (TX-005). Once the hosts are armed, Ctrl-C stops
# tx and not the job: the agents are detached, so tx leaves them running,
# says which hosts were still at it, and gives the next command for each
# choice. While arming, it stands back down every host it reached, so no
# host runs the job on its own. In a --muster wave it checks in what
# finished and puts back what never ran before it exits, leaving only
# what is still running to its lease.
#
# The SIGINT goes to the python process itself, as a terminal's Ctrl-C
# does, not to a shell around it. A command a script starts in the
# background inherits SIGINT ignored, and python then never raises
# KeyboardInterrupt at all, so tx_bg puts the default back first.

# shellcheck disable=SC2016
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# The muster double test_muster.sh defines (install_fake_muster), taken
# from there rather than copied, so the two cannot drift apart.
eval "$(sed -n '/^install_fake_muster() {/,/^}/p' \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_muster.sh")"

# tx_bg ARGS... -- tx in the background, taking SIGINT the way Ctrl-C
# delivers it. Its pid is $BG_PID (the exec keeps it), and what it says
# goes to $TEST_TMPDIR/bg.out.
tx_bg() {
    python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.executable, [sys.executable] + sys.argv[1:])' \
        "$TX" "$@" > "$TEST_TMPDIR/bg.out" 2>&1 &
    BG_PID=$!
}

# tx_bg_session ARGS... -- tx_bg, leading a process group of its own, so
# `kill -INT -- -$BG_PID` reaches it and every ssh it has in flight, as
# Ctrl-C at a terminal does. (setsid execs in place here: a script's
# background job is not a group leader, so the pid is still tx's.)
tx_bg_session() {
    setsid python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.executable, [sys.executable] + sys.argv[1:])' \
        "$TX" "$@" > "$TEST_TMPDIR/bg.out" 2>&1 &
    BG_PID=$!
}

# finish_bg -- wait for it: status in $BG_RC, output in $BG_OUT.
finish_bg() {
    wait "$BG_PID"
    BG_RC=$?
    BG_OUT="$(cat "$TEST_TMPDIR/bg.out")"
}

# until_true SECONDS CMD... -- CMD every tenth of a second until it
# succeeds; non-zero if it never does.
until_true() {
    local tries=$(($1 * 10)) i=0
    shift
    until "$@"; do
        i=$((i + 1))
        [ "$i" -ge "$tries" ] && return 1
        sleep 0.1
    done
}

said() { grep -qF -- "$1" "$TEST_TMPDIR/bg.out"; }

# slow SECONDS PATTERN -- every ssh whose command contains PATTERN takes
# that long before it runs: an arming, or a stand-down, slow enough to
# press Ctrl-C in the middle of.
slow() {
    [ -f "$FAKE_BIN/ssh.real" ] || mv "$FAKE_BIN/ssh" "$FAKE_BIN/ssh.real"
    printf '%s\t%s\n' "$1" "$2" >> "$FAKE_BIN/slow.tsv"
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
while IFS="$(printf '\t')" read -r secs pattern; do
    case "$*" in *"$pattern"*) sleep "$secs" ;; esac
done < "$FAKE_BIN/slow.tsv"
exec "$FAKE_BIN/ssh.real" "$@"
SHIM
    chmod +x "$FAKE_BIN/ssh"
}

ARMING="--run-id"               # in every arming's ssh, and nothing else's
STANDING_DOWN="status=not-deployed"     # the kill block's first line

remote() { echo "$FAKE_ROOT/$1$TX_REMOTE_DIR"; }

# ---- in the wait: the job is left running ---------------------------------

t_in_the_wait_the_job_is_left_running() {
    install_fake_ssh
    plan="$(plan_for --run 'sleep 3; echo "$TX_HOST" > "$TX_OUT/who"' \
                     --tag ci --timeout 30 -- a b c)"
    tx_bg run --plan "$plan" --start-in 1 --no-skew-check --poll 0.5 \
        -d results --quiet
    until_true 20 said "hosts finished" || fail "the wait never began"
    kill -INT "$BG_PID"
    finish_bg
    assert_status 130 "$BG_RC"
    assert_contains "$BG_OUT" "the hosts are left as they are"
    assert_contains "$BG_OUT" "3 of 3 host(s) had not finished: a b c"
    # The next command for each choice, able to reach this fleet as typed.
    assert_contains "$BG_OUT" "next: tx status --plan $plan"
    assert_contains "$BG_OUT" "tx collect --plan $plan -d results"
    assert_contains "$BG_OUT" "tx stop --plan $plan"
    # Said once, by what knew what was running: no generic line after it.
    assert_eq "1" "$(grep -cx '\[tx\] interrupted' "$TEST_TMPDIR/bg.out")"
    # Not stopped: every host finishes the job on its own...
    for h in a b c; do
        until_true 20 test -f "$(remote "$h")/out/who" \
            || fail "$h was stopped, or never finished"
    done
    # ...and the collect it named brings the results back.
    run_tx collect --plan "$plan" -d results --quiet
    assert_status 0 "$RUN_RC"
    for h in a b c; do
        assert_file_exists "results/ci~$h~out~who"
    done
}

# ---- while arming: the hosts reached are stood back down ------------------

t_while_arming_the_armed_hosts_are_stood_down() {
    install_fake_ssh
    slow 0.5 "$ARMING"
    plan="$(plan_for --run 'echo ran > "$TX_OUT/ran"' --tag ci \
                     --timeout 30 -- a b c d)"
    # --jobs 1: the hosts are armed one after another, so Ctrl-C lands
    # with a armed and the rest not.
    tx_bg run --plan "$plan" --start-in 6 --no-skew-check --jobs 1 \
        -d results --quiet
    until_true 20 test -f "$(remote a)/agent.pid" || fail "a was never armed"
    kill -INT "$BG_PID"
    finish_bg
    assert_status 130 "$BG_RC"
    assert_contains "$BG_OUT" "interrupted while arming"
    assert_contains "$BG_OUT" "stood back down: nothing of this start is running"
    # Past the instant a was armed for: nobody ran the job alone.
    sleep 6
    for h in a b c d; do
        assert_no_file "$(remote "$h")/out/ran" "$h ran the job on its own"
    done
}

t_a_second_ctrl_c_does_not_cut_the_stand_down_short() {
    install_fake_ssh
    slow 0.5 "$ARMING"
    slow 1.5 "$STANDING_DOWN"
    plan="$(plan_for --run 'echo ran > "$TX_OUT/ran"' --tag ci \
                     --timeout 30 -- a b c d)"
    tx_bg run --plan "$plan" --start-in 9 --no-skew-check --jobs 1 \
        -d results --quiet
    # Two hosts reached, so a stand-down cut short would leave one armed.
    until_true 20 test -f "$(remote b)/agent.pid" || fail "b was never armed"
    kill -INT "$BG_PID"
    until_true 20 said "standing the armed hosts back down" \
        || fail "the stand-down never began"
    kill -INT "$BG_PID"
    finish_bg
    assert_status 130 "$BG_RC"
    assert_contains "$BG_OUT" "after reaching 2 of 4 host(s)"
    assert_contains "$BG_OUT" "stood back down: nothing of this start is running"
    sleep 6
    for h in a b c d; do
        assert_no_file "$(remote "$h")/out/ran" "$h ran the job on its own"
    done
}

t_a_terminal_ctrl_c_stands_down_the_host_whose_ssh_it_killed() {
    # At a terminal, Ctrl-C reaches the ssh in flight too: it dies, and
    # its host may have been armed already without tx being told. Here
    # the arming's ssh is a client in tx's process group, which the
    # Ctrl-C kills, and the command on the "host" runs in a session of
    # its own, out of reach, as a real host's would be. The client lingers
    # a second after the host is armed, so the Ctrl-C lands while b's
    # arming is armed but unanswered.
    command -v setsid > /dev/null 2>&1 || { echo "no setsid: skipped"; return 0; }
    install_fake_ssh
    mv "$FAKE_BIN/ssh" "$FAKE_BIN/ssh.real"
    cat > "$FAKE_BIN/ssh" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
    *--run-id*)
        setsid "$FAKE_BIN/ssh.real" "$@" &
        wait "$!"
        rc=$?
        sleep 1
        exit "$rc" ;;
    *) exec "$FAKE_BIN/ssh.real" "$@" ;;
esac
SHIM
    chmod +x "$FAKE_BIN/ssh"
    plan="$(plan_for --run 'echo ran > "$TX_OUT/ran"' --tag ci \
                     --timeout 30 -- a b c d)"
    tx_bg_session run --plan "$plan" --start-in 6 --no-skew-check --jobs 1 \
        -d results --quiet
    until_true 20 test -f "$(remote b)/agent.pid" || fail "b was never armed"
    kill -INT -- "-$BG_PID"
    finish_bg
    assert_status 130 "$BG_RC"
    assert_contains "$BG_OUT" "after reaching 2 of 4 host(s)"
    assert_contains "$BG_OUT" "stood back down: nothing of this start is running"
    sleep 6
    for h in a b c d; do
        assert_no_file "$(remote "$h")/out/ran" "$h ran the job on its own"
    done
}

# ---- a --batch sweep: the command that carries it on ----------------------

t_in_a_sweep_it_gives_the_command_that_resumes_it() {
    install_fake_ssh
    plan="$(plan_for --run 'sleep 2; echo x >> "$FAKE_ROOT/$TX_HOST.runs"; echo "$TX_HOST" > "$TX_OUT/who"' \
                     --tag ci --timeout 30 -- a b c)"
    tx_bg run --plan "$plan" --batch 2 --start-in 1 --no-skew-check \
        --poll 0.5 -d results --quiet
    until_true 20 said "hosts finished" || fail "wave 1 never began waiting"
    kill -INT "$BG_PID"
    finish_bg
    assert_status 130 "$BG_RC"
    assert_contains "$BG_OUT" "interrupted in wave 1 of 2"
    assert_contains "$BG_OUT" "2 of 2 host(s) had not finished: a b"
    again="$(sed -n 's/^\[tx\] next: \(tx run .*\)  # carry the sweep on.*/\1/p' \
             "$TEST_TMPDIR/bg.out" | sed 's/ *$//')"
    assert_contains "$again" "--resume" "the command it gives must resume"
    # Run exactly as given, it finishes the sweep: wave 1 is waited for,
    # not run again, and c is covered.
    out="$(eval "$again" 2>&1)"
    assert_status 0 $? "the command it gave: $again"$'\n'"$out"
    for h in a b c; do
        assert_eq "1" "$(wc -l < "$FAKE_ROOT/$h.runs" | tr -d ' ')" \
            "$h should have run exactly once"
        assert_file_exists "results/ci~$h~out~who"
    done
}

# ---- a --muster wave: the pool is told what happened ----------------------

t_in_a_muster_wave_what_finished_is_checked_in() {
    install_fake_ssh
    install_fake_muster
    pool="$TEST_TMPDIR/pool.csv"
    muster add "a b c d" --pool "$pool" > /dev/null
    plan="$(plan_for --run '[ "$TX_HOST" = c ] && sleep 30; echo "$TX_HOST" > "$TX_OUT/who"' \
                     --tag pool --timeout 60 -- a b c d)"
    # --start-in 5: time to kill d's agent before the instant it is armed for.
    tx_bg run --plan "$plan" --muster "$pool" --batch 4 --start-in 5 \
        --no-skew-check --poll 0.5 -d results --quiet
    until_true 20 said "hosts finished" || fail "the wave never began waiting"
    # d's agent dies before the instant: d never runs and has no result.
    kill -KILL "$(cat "$(remote d)/agent.pid")"
    # a and b finish; c is still running when Ctrl-C comes.
    for h in a b; do
        until_true 20 grep -q '"state": "done"' "$(remote "$h")/run.json" \
            || fail "$h never finished"
    done
    kill -INT "$BG_PID"
    finish_bg
    assert_status 130 "$BG_RC"
    list="$(muster list --pool "$pool")"
    assert_contains "$list" "a,done" "a finished, so it is done"
    assert_contains "$list" "b,done" "b finished, so it is done"
    assert_contains "$list" "c,held" "c is still running: left to its lease"
    assert_contains "$list" "d,available" "d never ran: back in the pool"
    # Collected before it was checked in: a done item's results are here.
    assert_file_exists "results/pool~a~out~who"
    assert_file_exists "results/pool~b~out~who"
    assert_contains "$BG_OUT" "1 item(s) still running are left to their lease"
    assert_contains "$BG_OUT" "tx run --plan $plan --muster $pool"
    tx stop --plan "$plan" > /dev/null 2>&1
}

t_while_a_muster_wave_arms_its_items_go_back() {
    install_fake_ssh
    install_fake_muster
    slow 0.5 "$ARMING"
    pool="$TEST_TMPDIR/pool.csv"
    muster add "a b c" --pool "$pool" > /dev/null
    plan="$(plan_for --run 'echo ran > "$TX_OUT/ran"' --tag pool \
                     --timeout 30 -- a b c)"
    tx_bg run --plan "$plan" --muster "$pool" --batch 3 --start-in 6 \
        --no-skew-check --jobs 1 -d results --quiet
    until_true 20 test -f "$(remote a)/agent.pid" || fail "a was never armed"
    kill -INT "$BG_PID"
    finish_bg
    assert_status 130 "$BG_RC"
    # Stood down, so nothing ran: every item is back, none held or done.
    assert_eq "pool.csv,3,0,0,3,0.00,0" \
        "$(muster status --pool "$pool" --csv | tail -1)"
    sleep 6
    for h in a b c; do
        assert_no_file "$(remote "$h")/out/ran" "$h ran the job on its own"
    done
}

echo "interrupt"
run_test "in the wait, the job is left running"   t_in_the_wait_the_job_is_left_running
run_test "while arming, the armed stand down"     t_while_arming_the_armed_hosts_are_stood_down
run_test "a second ctrl-c waits for the stand-down" t_a_second_ctrl_c_does_not_cut_the_stand_down_short
run_test "a terminal ctrl-c, ssh killed too"      t_a_terminal_ctrl_c_stands_down_the_host_whose_ssh_it_killed
run_test "a sweep says how to resume it"          t_in_a_sweep_it_gives_the_command_that_resumes_it
run_test "a muster wave checks in what finished"  t_in_a_muster_wave_what_finished_is_checked_in
run_test "a muster wave arming puts items back"   t_while_a_muster_wave_arms_its_items_go_back
report_tests
