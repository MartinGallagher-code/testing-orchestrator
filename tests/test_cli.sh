#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# The command line itself: the things a person types before they know
# what they are doing, and the things a script parses afterwards.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# A job's command is single-quoted throughout this file on purpose: it has
# to reach the far side unexpanded, so that $TX_OUT means the out
# directory on the host rather than an empty variable in this shell. That
# non-expansion is SC2016's whole warning and is the behaviour under test.
# shellcheck disable=SC2016

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"


t_version_leads_with_a_line_a_script_can_parse() {
    run_tx --version
    assert_status 0 "$RUN_RC"
    assert_eq "testing-orchestrator" "$(printf '%s' "$RUN_OUT" | head -1 | cut -d' ' -f1)"
    assert_contains "$RUN_OUT" "GPL-3.0-or-later"
}

t_no_arguments_points_somewhere_useful() {
    run_tx
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "testing-orchestrator run"
    assert_contains "$RUN_OUT" "testing-orchestrator hints"
}

t_hints_maps_goals_to_commands() {
    run_tx hints
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "run a benchmark on every host at once"
    assert_contains "$RUN_OUT" "tx gen"
    assert_contains "$RUN_OUT" "tx collect"
}

t_help_lists_every_command_and_its_switches() {
    # It is generated from the real parsers, so it cannot drift from what
    # the code accepts.
    run_tx help
    assert_status 0 "$RUN_RC"
    for verb in gen check doctor start status collect summarize stop logs \
                clean run hints; do
        assert_contains "$RUN_OUT" "testing-orchestrator $verb" \
            "help should cover $verb"
    done
    # And the environment a job runs under is part of the interface.
    assert_contains "$RUN_OUT" "TX_OUT"
    assert_contains "$RUN_OUT" "TX_INDEX"
}

t_every_verb_answers_its_own_help() {
    for verb in gen check doctor start status collect summarize stop logs \
                clean run hints; do
        run_tx "$verb" --help
        assert_status 0 "$RUN_RC" "tx $verb --help should work"
    done
}

t_an_unknown_verb_is_a_usage_error() {
    run_tx frobnicate
    assert_status 2 "$RUN_RC"
}

t_the_plan_can_come_from_the_environment() {
    servers="$(write_servers web01)"
    run_tx gen --servers "$servers" --plan elsewhere.ini --run true
    assert_status 0 "$RUN_RC"
    TX_PLAN=elsewhere.ini run_tx check
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "elsewhere.ini"
}

t_the_server_list_can_come_from_the_environment() {
    servers="$(write_servers web01 web02)"
    TX_SERVERS="$servers" run_tx gen --plan plan.ini --run true
    assert_status 0 "$RUN_RC"
    assert_contains "$(cat plan.ini)" "web02"
}

# ---- a reader that goes away (TX-010) --------------------------------------

# closed_stdout ARGS... -- tx with its stdout a pipe nobody reads any more,
# as `tx ... | head -3` is by the fourth line. The reader is gone before tx
# writes a byte, so the pipe breaks every time rather than when a race
# says. tx's stderr is left in $RUN_ERR and its exit status in $RUN_RC.
closed_stdout() {
    RUN_ERR="$(python3 - "$TX" "$@" <<'PY2'
import os, subprocess, sys
r, w = os.pipe()
os.close(r)
p = subprocess.Popen([sys.executable] + sys.argv[1:], stdout=w,
                     stderr=subprocess.PIPE)
os.close(w)
_out, err = p.communicate()
sys.stdout.write(err.decode("utf-8", "replace"))
sys.exit(p.returncode if p.returncode >= 0 else 128 - p.returncode)
PY2
)"
    RUN_RC=$?
}

t_a_closed_pipe_ends_tx_quietly() {
    # `tx start --dry-run | head -3` was a BrokenPipeError traceback.
    servers="$(write_servers web01 web02 web03)"
    run_tx gen --servers "$servers" --plan plan.ini --run true \
        --remote-dir /var/tmp/tx-test
    assert_status 0 "$RUN_RC"
    closed_stdout start --dry-run --plan plan.ini
    assert_eq "" "$RUN_ERR" "nothing at all on stderr"
    # 1, which the traceback gave: a new code would be a major version.
    assert_status 1 "$RUN_RC" "the exit status the traceback had"
    # The same for the other ways out: a command that returns, and --help.
    closed_stdout status --dry-run --plan plan.ini
    assert_eq "" "$RUN_ERR" "status: nothing on stderr"
    closed_stdout --help
    assert_eq "" "$RUN_ERR" "--help: nothing on stderr"
    closed_stdout help
    assert_eq "" "$RUN_ERR" "help: nothing on stderr"
}

t_a_closed_pipe_partway_says_so() {
    # Cut off while it changes the fleet, tx has stopped partway, and a
    # silent exit would hide that: one line on stderr, and no traceback.
    install_fake_ssh
    plan="$(plan_for --run 'true' --timeout 30 -- web01)"
    closed_stdout start --plan "$plan" --start-in 1 --no-skew-check
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_ERR" "tx: the output was closed (broken pipe), so \`tx start\` stopped partway; \`tx status\` shows where it left the fleet"
    assert_not_contains "$RUN_ERR" "Traceback"
}

# ---- the source itself -------------------------------------------------------

t_no_function_is_defined_twice() {
    # `_median` was defined twice, identically; the second quietly replaced
    # the first, so a fix to one would have been no fix at all. Every name
    # tx.py defines at the top level is defined once.
    out="$(python3 - "$TX" <<'PY2'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
seen = {}
for node in tree.body:
    if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
        if node.name in seen:
            print("%s: line %d and line %d" % (node.name, seen[node.name],
                                               node.lineno))
        seen.setdefault(node.name, node.lineno)
PY2
)"
    assert_eq "" "$out" "a name defined twice"
}

echo "cli"
run_test "version leads with a parsable line"  t_version_leads_with_a_line_a_script_can_parse
run_test "no arguments points somewhere"       t_no_arguments_points_somewhere_useful
run_test "hints maps goals to commands"        t_hints_maps_goals_to_commands
run_test "help lists every command"            t_help_lists_every_command_and_its_switches
run_test "every verb answers --help"           t_every_verb_answers_its_own_help
run_test "an unknown verb is a usage error"    t_an_unknown_verb_is_a_usage_error
run_test "the plan can come from the env"      t_the_plan_can_come_from_the_environment
run_test "the servers can come from the env"   t_the_server_list_can_come_from_the_environment
run_test "a closed pipe ends tx quietly"       t_a_closed_pipe_ends_tx_quietly
run_test "a closed pipe partway says so"       t_a_closed_pipe_partway_says_so
run_test "no function is defined twice"        t_no_function_is_defined_twice
report_tests
