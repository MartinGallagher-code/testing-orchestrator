#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# The agent: the half of tx that runs on the servers. It is what makes a
# job's result a result -- the environment it runs in, the bound it runs
# under, and the record it leaves behind.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# A job's command is single-quoted throughout this file on purpose: it has
# to reach the far side unexpanded, so that $TX_OUT means the out
# directory on the host rather than an empty variable in this shell. That
# non-expansion is SC2016's whole warning and is the behaviour under test.
# shellcheck disable=SC2016

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"


# Run one job on one fake host and wait for its record. Echoes nothing;
# the record is at $REC and the working directory at $WD.
one_job() {
    plan="$(plan_for "$@" -- web01)" || return 1
    WD="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    REC="$WD/run.json"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check || return 1
    local i=0
    while [ "$i" -lt 150 ]; do
        [ -f "$REC" ] && grep -q '"state": "\(done\|timeout\|setup-failed\)"' "$REC" && return 0
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# field NAME -- one value out of the run record.
field() {
    python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); sys.stdout.write("" if v is None else str(v))' \
        "$REC" "$1"
}

# ---- what the job is told ---------------------------------------------------

t_the_job_knows_where_it_is_and_where_to_write() {
    # A benchmark that cannot tell one host from another produces forty
    # identical files, and one that does not know where to put its output
    # produces results nobody collects.
    install_fake_ssh
    one_job --run 'echo "$TX_HOST $TX_INDEX/$TX_NHOSTS $TX_TAG" > "$TX_OUT/env"' \
            --tag runA --timeout 30 || fail "the job never finished"
    assert_eq "web01 0/1 runA" "$(cat "$WD/out/env")"
}

t_the_whole_fleet_is_offered_but_not_forced() {
    # A job that shards work needs the list; one that does not should not
    # have to care, so it is opt-in.
    install_fake_ssh
    plan="$(plan_for --run 'echo "${TX_HOSTS:-unset}" > "$TX_OUT/peers"' --timeout 30 -- web01 web02)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check --peers
    sleep 2
    assert_eq "web01 web02" "$(cat "$FAKE_ROOT/web01$TX_REMOTE_DIR/out/peers")"

    run_tx clean --plan "$plan" --yes
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2
    assert_eq "unset" "$(cat "$FAKE_ROOT/web01$TX_REMOTE_DIR/out/peers")"
}

t_each_host_gets_its_own_index() {
    install_fake_ssh
    plan="$(plan_for --run 'echo "$TX_INDEX" > "$TX_OUT/i"' --timeout 30 -- a b c)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2
    assert_eq "0" "$(cat "$FAKE_ROOT/a$TX_REMOTE_DIR/out/i")"
    assert_eq "1" "$(cat "$FAKE_ROOT/b$TX_REMOTE_DIR/out/i")"
    assert_eq "2" "$(cat "$FAKE_ROOT/c$TX_REMOTE_DIR/out/i")"
}

t_one_run_id_is_shared_by_the_whole_fleet() {
    install_fake_ssh
    plan="$(plan_for --run 'echo "$TX_RUN_ID" > "$TX_OUT/id"' --timeout 30 -- a b)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2
    assert_eq "$(cat "$FAKE_ROOT/a$TX_REMOTE_DIR/out/id")" \
              "$(cat "$FAKE_ROOT/b$TX_REMOTE_DIR/out/id")" \
              "every host in one start should share the run id"
}

# ---- the command itself -----------------------------------------------------

t_a_command_arrives_exactly_as_typed() {
    # It travels base64'd from the plan to the agent, so no shell parses
    # it on the way -- not the local one, not ssh, not the remote login
    # shell. What these guard is the property; what they catch is a
    # version that interpolates the command into the ssh script.
    install_fake_ssh
    one_job --run 'printf "%s\n" "it'\''s \"quoted\" a\b" > "$TX_OUT/txt"' \
            --timeout 30 || fail "the job never finished"
    assert_eq 'it'\''s "quoted" a\b' "$(cat "$WD/out/txt")"
}

t_a_command_spanning_lines_is_one_command() {
    install_fake_ssh
    one_job --run 'echo one > "$TX_OUT/f"
echo two >> "$TX_OUT/f"' --timeout 30 || fail "the job never finished"
    assert_eq "one|two|" "$(tr '\n' '|' < "$WD/out/f")"
}

t_stdout_and_stderr_are_kept_apart() {
    # Unlike a one-shot command, a benchmark's stdout is usually its
    # result and its stderr is usually its complaints; merging them would
    # mean parsing the result out of the noise.
    install_fake_ssh
    one_job --run 'echo result; echo complaint >&2' --timeout 30 \
        || fail "the job never finished"
    assert_eq "result" "$(cat "$WD/stdout")"
    assert_eq "complaint" "$(cat "$WD/stderr")"
}

t_the_exit_status_is_recorded_not_inferred() {
    install_fake_ssh
    one_job --run 'echo out; exit 7' --timeout 30 || fail "the job never finished"
    assert_eq "7" "$(field exit)"
    assert_eq "done" "$(field state)"
    assert_eq "out" "$(cat "$WD/stdout")" "a failed job's output is still a result"
}

t_binary_output_is_not_mangled() {
    install_fake_ssh
    one_job --run 'printf "\x00\x01\xff\xfe" > "$TX_OUT/blob"' --timeout 30 \
        || fail "the job never finished"
    printf '\x00\x01\xff\xfe' > want.bin
    cmp -s want.bin "$WD/out/blob" || fail "the bytes did not survive"
}

# ---- setup and teardown -----------------------------------------------------

t_setup_runs_before_the_job() {
    install_fake_ssh
    one_job --setup 'echo built > marker' --run 'cat marker > "$TX_OUT/seen"' \
            --timeout 30 || fail "the job never finished"
    assert_eq "0" "$(field setup_exit)"
    assert_eq "built" "$(cat "$WD/out/seen")"
}

t_a_host_whose_setup_failed_does_not_run_the_job() {
    # Reporting a benchmark failure that was really a build failure is
    # worse than reporting nothing: it is a wrong answer rather than a
    # missing one.
    install_fake_ssh
    one_job --setup 'exit 3' --run 'echo ran > "$TX_OUT/ran"' --timeout 30 \
        || fail "the agent never settled"
    assert_eq "3" "$(field setup_exit)"
    assert_eq "setup-failed" "$(field state)"
    assert_no_file "$WD/out/ran" "the job must not run after a failed setup"
    assert_eq "" "$(field exit)" "there is no job exit status to report"
}

t_setup_output_is_kept_for_reading_later() {
    install_fake_ssh
    one_job --setup 'echo "cannot find the compiler" >&2; exit 1' --run true \
            --timeout 30 || fail "the agent never settled"
    assert_contains "$(cat "$WD/setup.log")" "cannot find the compiler"
}

t_teardown_runs_even_when_the_job_failed() {
    # Leaving a host as it was found is not conditional on the run going
    # well -- that is exactly when cleanup matters most.
    install_fake_ssh
    one_job --run 'exit 9' --teardown 'echo tidied > "$TX_OUT/tidied"' \
            --timeout 30 || fail "the job never finished"
    assert_eq "9" "$(field exit)"
    assert_eq "0" "$(field teardown_exit)"
    assert_file_exists "$WD/out/tidied"
}

t_a_host_is_not_finished_until_it_has_been_put_back() {
    # `tx run` collects the moment a host reports finished. If the record
    # said "done" before teardown had run, the collection would race a
    # teardown still writing into $TX_OUT -- and the files it produced
    # would be left on the host. Caught by the 3.6 job, which is slow
    # enough to lose the race every time.
    install_fake_ssh
    plan="$(plan_for --run 'echo early > "$TX_OUT/early"' \
            --teardown 'sleep 3; echo late > "$TX_OUT/late"' \
            --tag t --timeout 30 -- web01)"
    run_tx run --plan "$plan" --start-in 1 --no-skew-check -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_file_exists "results/t~web01~out~early"
    assert_file_exists "results/t~web01~out~late" \
        "the collection raced the teardown and left its output behind"
}

t_a_host_running_its_teardown_says_so() {
    install_fake_ssh
    plan="$(plan_for --run true --teardown 'sleep 4' --tag t --timeout 30 \
            -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2.5
    run_tx status --plan "$plan"
    assert_contains "$RUN_OUT" "TIDYING"
}

t_a_teardown_that_failed_is_said_out_loud() {
    install_fake_ssh
    plan="$(plan_for --run true --teardown 'exit 4' --timeout 30 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2.5
    run_tx summarize --plan "$plan"
    assert_contains "$RUN_OUT" "TEARDOWN"
    assert_contains "$RUN_OUT" "may not be as you found them"
}

# ---- the bound --------------------------------------------------------------

t_a_job_that_overruns_is_killed_and_marked() {
    install_fake_ssh
    one_job --run 'sleep 60' --timeout 2 || fail "the agent never settled"
    assert_eq "True" "$(field timed_out)"
    assert_eq "timeout" "$(field state)"
    d="$(field duration)"
    assert_between 1.5 12 "$d" "a 2s timeout should end the job at about 2s"
}

t_a_timeout_takes_the_whole_tree_with_it() {
    # The reason the job gets a session of its own: a benchmark is almost
    # always a script that starts other things, and killing the script
    # alone leaves the machine still working.
    install_fake_ssh
    marker="$TEST_TMPDIR/grandchild-alive"
    one_job --run "sh -c 'while true; do touch $marker; sleep 0.2; done' & sleep 60" \
            --timeout 2 || fail "the agent never settled"
    [ -f "$marker" ] || fail "the grandchild never started; the test proves nothing"
    rm -f "$marker"
    sleep 1.5
    assert_no_file "$marker" "a grandchild outlived the timeout"
}

t_the_record_is_readable_all_the_way_through() {
    # status reads it while the job is running, so it cannot be a file
    # that only becomes valid at the end.
    install_fake_ssh
    plan="$(plan_for --run 'sleep 4' --timeout 30 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    sleep 2.5
    rec="$FAKE_ROOT/web01$TX_REMOTE_DIR/run.json"
    assert_file_exists "$rec"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$rec" \
        || fail "the record was not valid json mid-run"
    assert_contains "$(cat "$rec")" '"state": "running"'
}

# ---- the agent and the payload ----------------------------------------------

# The agent is started in the directory the payload unpacks into, and a
# plain `python3 tx.py` puts the script's own directory first on
# sys.path -- so every top-level .py the job shipped would shadow the
# stdlib module of that name *in the agent*. These are modules tx.py
# imports (queue by way of concurrent.futures), each fatal on import, so
# an agent that loads one dies before it writes a record.
SHADOWED="json queue signal subprocess"

# shadowing_payload -- ./bench with those modules at its top level, a
# helper of the job's own beside them, and bench.py, which imports the
# helper (and the module named in its first argument, if any) and writes
# down what it found and where it ran.
shadowing_payload() {
    mkdir -p bench
    local m
    for m in $SHADOWED; do
        printf 'raise SystemExit("shadowed: the payload'\''s %s.py was imported")\n' \
            "$m" > "bench/$m.py"
    done
    printf 'WHO = "the payload'\''s own helper"\n' > bench/helper.py
    cat > bench/bench.py <<'PY'
import os
import sys

import helper

out = os.environ["TX_OUT"]
with open(os.path.join(out, "helper"), "w") as fh:
    fh.write(helper.WHO + "\n")
with open(os.path.join(out, "cwd"), "w") as fh:
    fh.write(os.getcwd() + "\n")
with open(os.path.join(out, "host"), "w") as fh:
    fh.write(os.environ["TX_HOST"] + "\n")
if len(sys.argv) > 1:
    __import__(sys.argv[1])
    with open(os.path.join(out, "pythonpath"), "w") as fh:
        fh.write(os.environ.get("PYTHONPATH", "") + "\n")
PY
}

# await_done N -- until N hosts have a record that says done, or give up.
await_done() {
    local n="$1" i=0
    while [ "$i" -lt 150 ]; do
        if [ "$(find "$FAKE_ROOT" -name run.json -exec grep -l '"state": "done"' {} + 2>/dev/null | wc -l)" -ge "$n" ]; then
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

t_the_agent_never_imports_the_payloads_modules() {
    # A benchmark with its own json.py or queue.py is ordinary; a fleet
    # run that dies on every host because of it, reporting only that "the
    # agent died on startup", is not. The job still runs in the payload
    # directory and still finds its own helper there.
    install_fake_ssh
    shadowing_payload
    plan="$(plan_for --payload ./bench --run 'python3 bench.py' --tag sh \
            --timeout 30 -- web01 web02 web03)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC" "start should arm every host"
    assert_not_contains "$RUN_OUT" "died on startup"
    await_done 3 || fail "the job did not finish on every host"
    local h d
    for h in web01 web02 web03; do
        d="$FAKE_ROOT/$h$TX_REMOTE_DIR"
        REC="$d/run.json"
        assert_eq "done" "$(field state)" "the record on $h"
        assert_eq "0" "$(field exit)" "the job's exit status on $h"
        assert_eq "$h" "$(field host)" "the record names its host"
        assert_eq "$(python3 "$TX" --version | sed -n '1s/.* //p')" \
                  "$(field agent_version)" "the record carries the agent's version"
        assert_not_contains "$(cat "$d/agent.log" 2>/dev/null)" "shadowed"
        assert_eq "the payload's own helper" "$(cat "$d/out/helper")" \
            "the job should still import its own helper from the payload"
        assert_eq "$(cd "$d" && pwd -P)" "$(cat "$d/out/cwd")" \
            "the job should still run in the payload directory"
        assert_eq "$h" "$(cat "$d/out/host")"
    done
}

t_the_job_keeps_the_pythonpath_it_was_given() {
    # The agent's own interpreter ignores PYTHON* variables; the job is
    # not the agent, and inherits its environment exactly as before.
    install_fake_ssh
    shadowing_payload
    mkdir -p site
    printf 'X = 1\n' > site/from_pythonpath.py
    export PYTHONPATH="$TEST_TMPDIR/site"
    plan="$(plan_for --payload ./bench --run 'python3 bench.py from_pythonpath' \
            --timeout 30 -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 0 "$RUN_RC"
    await_done 1 || fail "the job never finished"
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    REC="$d/run.json"
    assert_eq "0" "$(field exit)" "the job should import a module from \$PYTHONPATH"
    assert_eq "$TEST_TMPDIR/site" "$(cat "$d/out/pythonpath")"
}

t_without_the_isolation_the_payload_kills_the_agent() {
    # The mutation: the same run from a copy of tx.py whose launch line
    # has lost -I. If this passes, the test above proves nothing.
    install_fake_ssh
    shadowing_payload
    mkdir -p mutant
    sed 's/nohup %s -I %s %s/nohup %s %s %s/' "$TX" > mutant/tx.py
    if cmp -s "$TX" mutant/tx.py; then
        fail "the mutation no longer applies to tx.py's launch line"
        return 1
    fi
    TX="$TEST_TMPDIR/mutant/tx.py"
    plan="$(plan_for --payload ./bench --run 'python3 bench.py' --timeout 30 \
            -- web01)"
    run_tx start --plan "$plan" --start-in 1 --no-skew-check
    d="$FAKE_ROOT/web01$TX_REMOTE_DIR"
    local i=0
    while [ "$i" -lt 50 ]; do
        grep -q shadowed "$d/agent.log" 2>/dev/null && break
        sleep 0.2
        i=$((i + 1))
    done
    assert_contains "$(cat "$d/agent.log" 2>/dev/null)" "shadowed: the payload's" \
        "without -I the agent should have imported the payload's module"
    sleep 1.5
    assert_no_file "$d/run.json" "a shadowed agent should never have written a record"
}

echo "agent"
run_test "the job knows where it is"           t_the_job_knows_where_it_is_and_where_to_write
run_test "the fleet list is opt-in"            t_the_whole_fleet_is_offered_but_not_forced
run_test "each host gets its own index"        t_each_host_gets_its_own_index
run_test "one run id for the whole fleet"      t_one_run_id_is_shared_by_the_whole_fleet
run_test "a command arrives as typed"          t_a_command_arrives_exactly_as_typed
run_test "a command spanning lines"            t_a_command_spanning_lines_is_one_command
run_test "stdout and stderr stay apart"        t_stdout_and_stderr_are_kept_apart
run_test "the exit status is recorded"         t_the_exit_status_is_recorded_not_inferred
run_test "binary output is not mangled"        t_binary_output_is_not_mangled
run_test "setup runs before the job"           t_setup_runs_before_the_job
run_test "a failed setup skips the job"        t_a_host_whose_setup_failed_does_not_run_the_job
run_test "setup output is kept"                t_setup_output_is_kept_for_reading_later
run_test "teardown runs after a failure"       t_teardown_runs_even_when_the_job_failed
run_test "not finished until put back"         t_a_host_is_not_finished_until_it_has_been_put_back
run_test "a host tidying says so"              t_a_host_running_its_teardown_says_so
run_test "a failed teardown is said"           t_a_teardown_that_failed_is_said_out_loud
run_test "an overrunning job is killed"        t_a_job_that_overruns_is_killed_and_marked
run_test "a timeout takes the whole tree"      t_a_timeout_takes_the_whole_tree_with_it
run_test "the record is readable throughout"   t_the_record_is_readable_all_the_way_through
run_test "the payload cannot shadow the agent" t_the_agent_never_imports_the_payloads_modules
run_test "the job keeps its PYTHONPATH"        t_the_job_keeps_the_pythonpath_it_was_given
run_test "mutation: no -I, a dead agent"       t_without_the_isolation_the_payload_kills_the_agent
report_tests
