#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# `tx export`: run records -> overlay samples for the datacenter layout
# viewer (github.com/MartinGallagher-code/datacenter_visualization). The same
# tab-separated `!test`/sample file `mx` and iperf write, from what tx
# measures per host.
#
# Most of these read hand-written run.json records with `--from`, so the
# arithmetic can be asserted exactly; the last runs a real fleet and exports
# it live.

# shellcheck disable=SC2016
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# A collection directory holding the records passed as `host:json` pairs,
# named the way `tx collect` names them (tag~host~run.json). Echoes the dir.
write_collection() {
    local dir="$TEST_TMPDIR/coll"
    mkdir -p "$dir"
    local pair host json
    for pair in "$@"; do
        host="${pair%%:*}"; json="${pair#*:}"
        printf '%s\n' "$json" > "$dir/bench~$host~run.json"
    done
    echo "$dir"
}

# A plan naming HOST..., so export has a roll call and a tag. plan_for writes
# --remote-dir $TX_REMOTE_DIR, which install_fake_ssh normally sets; the
# --from tests here never ssh, so give it a value of its own.
export_plan() {
    export TX_REMOTE_DIR="${TX_REMOTE_DIR:-/var/tmp/tx-test}"
    plan_for --run './bench.sh' --tag bench --timeout 60 -- "$@"
}

# sample TEXT TEST TARGET -- the value of one sample, or "" if absent.
sample() {
    printf '%s\n' "$1" | awk -F'\t' -v t="$2" -v g="$3" \
        '$1==t && $2==g {print $3; exit}'
}

# A pass, a fail and a timeout, with durations 10/20/30 so the median is 20.
STD_A='{"host":"web01","tag":"bench","state":"done","exit":0,"timed_out":false,"duration":10.0,"start_offset":0.012,"setup_exit":0,"teardown_exit":0}'
STD_B='{"host":"web02","tag":"bench","state":"done","exit":7,"timed_out":false,"duration":20.0,"start_offset":0.031,"setup_exit":0,"teardown_exit":null}'
STD_C='{"host":"web03","tag":"bench","state":"timeout","exit":124,"timed_out":true,"duration":30.0,"start_offset":0.004}'

# ---- the overlay file's shape --------------------------------------------

t_declares_a_test_line_and_files_every_overlay() {
    coll="$(write_collection "web01:$STD_A" "web02:$STD_B" "web03:$STD_C")"
    plan="$(export_plan web01 web02 web03)"
    run_tx export --plan "$plan" --from "$coll"
    assert_status 0 "$RUN_RC"
    # The !test lines are what make an overlay readable the moment it loads.
    assert_contains "$RUN_OUT" "!test	tx_duration	unit=s higher=bad"
    assert_contains "$RUN_OUT" "!test	tx_start_offset	unit=ms higher=bad"
    assert_contains "$RUN_OUT" "!test	tx_state	agg=last"
    local t
    for t in tx_state tx_duration tx_rel_median tx_start_offset tx_exit \
             tx_timed_out; do
        assert_contains "$RUN_OUT" "$t	web01	" "$t sampled for web01"
    done
}

t_computes_the_numbers_the_record_holds() {
    coll="$(write_collection "web01:$STD_A" "web02:$STD_B" "web03:$STD_C")"
    plan="$(export_plan web01 web02 web03)"
    run_tx export --plan "$plan" --from "$coll"
    assert_status 0 "$RUN_RC"
    assert_eq "10" "$(sample "$RUN_OUT" tx_duration web01)" "wall-clock"
    # median duration is 20, so 10/20 and 30/20 are 50% and 150%.
    assert_eq "50" "$(sample "$RUN_OUT" tx_rel_median web01)" "half the median"
    assert_eq "150" "$(sample "$RUN_OUT" tx_rel_median web03)" "half again over"
    # start_offset is seconds in the record, milliseconds on the floor.
    assert_eq "12" "$(sample "$RUN_OUT" tx_start_offset web01)" "0.012s -> 12ms"
    assert_eq "7" "$(sample "$RUN_OUT" tx_exit web02)" "the job's exit code"
    assert_eq "1" "$(sample "$RUN_OUT" tx_timed_out web03)" "web03 timed out"
    assert_eq "0" "$(sample "$RUN_OUT" tx_timed_out web01)" "web01 did not"
}

t_state_names_how_each_host_finished() {
    coll="$(write_collection "web01:$STD_A" "web02:$STD_B" "web03:$STD_C")"
    plan="$(export_plan web01 web02 web03)"
    run_tx export --plan "$plan" --from "$coll"
    assert_eq "PASSED" "$(sample "$RUN_OUT" tx_state web01)" "exit 0"
    assert_eq "FAILED" "$(sample "$RUN_OUT" tx_state web02)" "nonzero exit"
    assert_eq "TIMEOUT" "$(sample "$RUN_OUT" tx_state web03)"
}

t_setup_and_launch_failures_get_their_own_state() {
    local sf lf run
    sf='{"host":"s1","tag":"bench","state":"setup-failed","setup_exit":3}'
    lf='{"host":"l1","tag":"bench","state":"launch-failed"}'
    run='{"host":"r1","tag":"bench","state":"running"}'
    coll="$(write_collection "s1:$sf" "l1:$lf" "r1:$run")"
    plan="$(export_plan s1 l1 r1)"
    run_tx export --plan "$plan" --from "$coll"
    assert_eq "SETUP-FAILED" "$(sample "$RUN_OUT" tx_state s1)"
    assert_eq "NEVER-RAN" "$(sample "$RUN_OUT" tx_state l1)" "launch-failed"
    assert_eq "RUNNING" "$(sample "$RUN_OUT" tx_state r1)" "still going"
    # A setup that failed has a setup exit but no duration and no job exit.
    assert_eq "3" "$(sample "$RUN_OUT" tx_setup_exit s1)"
    assert_eq "" "$(sample "$RUN_OUT" tx_duration s1)" "never got to the job"
}

t_a_blank_field_is_not_measured_not_zero() {
    coll="$(write_collection "web02:$STD_B")"
    plan="$(export_plan web02)"
    run_tx export --plan "$plan" --from "$coll"
    # web02's teardown_exit is null, and a null is dropped rather than filed
    # as a passing 0 -- the one mistake that flatters a report.
    assert_eq "0" "$(sample "$RUN_OUT" tx_setup_exit web02)" "setup did run"
    assert_eq "" "$(sample "$RUN_OUT" tx_teardown_exit web02)" "null is dropped"
}

t_a_host_in_the_plan_with_no_record_is_named() {
    coll="$(write_collection "web01:$STD_A")"
    plan="$(export_plan web01 web02)"        # web02 has no record
    run_tx export --plan "$plan" --from "$coll"
    assert_status 0 "$RUN_RC"
    assert_eq "NO-DATA" "$(sample "$RUN_OUT" tx_state web02)" "never came back"
    assert_eq "" "$(sample "$RUN_OUT" tx_duration web02)" "no number for it"
    assert_contains "$RUN_OUT" "1 host(s) have no record"
}

# ---- the portable flags every one of these exports shares -----------------

t_json_writes_ndjson() {
    coll="$(write_collection "web01:$STD_A")"
    plan="$(export_plan web01)"
    run_tx export --plan "$plan" --from "$coll" --json
    assert_status 0 "$RUN_RC"
    # json.dumps(sort_keys=True): keys come out target, test, value.
    assert_contains "$RUN_OUT" '{"!test": "tx_duration"'
    assert_contains "$RUN_OUT" '"test": "tx_duration", "value": 10'
    assert_contains "$RUN_OUT" '"target": "web01", "test": "tx_state", "value": "PASSED"'
}

t_no_meta_drops_the_test_lines() {
    coll="$(write_collection "web01:$STD_A")"
    plan="$(export_plan web01)"
    run_tx export --plan "$plan" --from "$coll" --no-meta
    assert_not_contains "$RUN_OUT" "!test"
    assert_contains "$RUN_OUT" "tx_duration	web01	10"
}

t_names_and_prefix_and_run_reshape_the_line() {
    coll="$(write_collection "web01:$STD_A")"
    plan="$(export_plan web01)"
    printf 'web01 = R01/u07\n' > "$TEST_TMPDIR/names.map"
    run_tx export --plan "$plan" --from "$coll" --names "$TEST_TMPDIR/names.map" \
        --target-prefix 'DH1/A/' --run nightly --no-meta
    assert_contains "$RUN_OUT" "tx_state	DH1/A/R01/u07	PASSED	run=nightly"
}

t_test_prefix_keeps_two_tools_apart() {
    coll="$(write_collection "web01:$STD_A")"
    plan="$(export_plan web01)"
    run_tx export --plan "$plan" --from "$coll" --test-prefix bench_ --no-meta
    assert_contains "$RUN_OUT" "bench_duration	web01	10"
    assert_not_contains "$RUN_OUT" "tx_duration"
}

t_append_builds_a_history() {
    coll="$(write_collection "web01:$STD_A")"
    plan="$(export_plan web01)"
    out="$TEST_TMPDIR/results.tsv"
    run_tx export --plan "$plan" --from "$coll" -o "$out" --run r1
    assert_status 0 "$RUN_RC"
    run_tx export --plan "$plan" --from "$coll" -o "$out" --append --run r2
    assert_status 0 "$RUN_RC"
    # Two runs, one file: the viewer aggregates the history.
    assert_eq "2" "$(grep -c '^tx_state	web01' "$out" | tr -d ' ')" "one per run"
    assert_contains "$(cat "$out")" "tx_duration	web01	10	run=r1"
    assert_contains "$(cat "$out")" "tx_duration	web01	10	run=r2"
}

# ---- guardrails -----------------------------------------------------------

t_a_run_label_with_a_space_is_refused() {
    coll="$(write_collection "web01:$STD_A")"
    plan="$(export_plan web01)"
    run_tx export --plan "$plan" --from "$coll" --run 'two words'
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "no whitespace"
}

t_live_export_without_a_plan_is_refused() {
    # No --from, and no plan: there is no fleet to read and no roll call.
    run_tx export --plan "$TEST_TMPDIR/nope.ini"
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "plan not found"
}

t_an_empty_collection_is_refused() {
    mkdir -p "$TEST_TMPDIR/empty"
    plan="$(export_plan web01)"
    run_tx export --plan "$plan" --from "$TEST_TMPDIR/empty"
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "no run.json records"
}

# ---- what a results file cannot hold, and what it must not blur (TX-010) ---

# A host named with a space runs, is collected and is summarized; only the
# results file cannot carry its name. One record of the kind, by --from.
SPACED='{"host":"c d","tag":"bench","state":"done","exit":0,"timed_out":false,"duration":30.0}'

t_a_host_named_with_a_space_is_left_out() {
    # It used to stop the whole export: rc 2, every host refused for one.
    coll="$(write_collection "web01:$STD_A" "c d:$SPACED")"
    out="$(python3 "$TX" export --plan "$TEST_TMPDIR/none.ini" --from "$coll" \
           2> "$TEST_TMPDIR/err")"
    assert_status 0 "$?" "one unusable name does not stop the export"
    assert_eq "PASSED" "$(sample "$out" tx_state web01)" "the others are exported"
    assert_not_contains "$out" "c d	" "no sample for the host left out"
    assert_contains "$out" "# 1 host(s) left out, their names holding whitespace or a quote: 'c d'"
    assert_contains "$(cat "$TEST_TMPDIR/err")" "left out, as a results file cannot hold their names: 'c d' (map each to a target with --names, as \`NAME = target\`)"
    # Left out of the file, not out of the fleet: the median is 10 and 30's.
    assert_eq "50" "$(sample "$out" tx_rel_median web01)" "its time still counts"
}

t_names_maps_a_host_named_with_a_space() {
    coll="$(write_collection "web01:$STD_A" "c d:$SPACED")"
    printf '# the plan'"'"'s own form, so the tx name can hold a space\nc d = R01/u09\n' \
        > "$TEST_TMPDIR/names.map"
    run_tx export --plan "$TEST_TMPDIR/none.ini" --from "$coll" \
        --names "$TEST_TMPDIR/names.map"
    assert_status 0 "$RUN_RC"
    assert_eq "PASSED" "$(sample "$RUN_OUT" tx_state R01/u09)" "mapped onto the floor"
    assert_not_contains "$RUN_OUT" "left out"
}

t_only_hosts_named_with_a_space_is_nothing_to_export() {
    coll="$(write_collection "c d:$SPACED")"
    run_tx export --plan "$TEST_TMPDIR/none.ini" --from "$coll"
    assert_status 1 "$RUN_RC"
    assert_contains "$RUN_OUT" "the only host(s) with a run record have names a target cannot hold: 'c d'"
}

t_a_names_target_that_cannot_be_one_is_refused() {
    # A mapping somebody wrote is a mistake to point out, not a host to drop.
    coll="$(write_collection "web01:$STD_A")"
    printf 'web01 = R01"u07\n' > "$TEST_TMPDIR/names.map"
    run_tx export --plan "$TEST_TMPDIR/none.ini" --from "$coll" \
        --names "$TEST_TMPDIR/names.map"
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "--names maps 'web01' to 'R01\"u07'"
}

t_a_target_prefix_with_a_space_is_refused() {
    coll="$(write_collection "web01:$STD_A")"
    run_tx export --plan "$TEST_TMPDIR/none.ini" --from "$coll" \
        --target-prefix 'DH1 A/'
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "--target-prefix 'DH1 A/'"
}

t_two_hosts_on_one_target_are_refused() {
    # Both hosts' samples on one node, with nothing to say whose: refused.
    coll="$(write_collection "web01:$STD_A" "web02:$STD_B" "web03:$STD_C")"
    plan="$(export_plan web01 web02 web03)"
    printf 'web01 R01/u07\nweb02 R01/u07\n' > "$TEST_TMPDIR/names.map"
    run_tx export --plan "$plan" --from "$coll" --names "$TEST_TMPDIR/names.map"
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "--names puts 'web01' and 'web02' on the one target 'R01/u07'"
    assert_not_contains "$RUN_OUT" "tx_state	R01/u07" "nothing written"
    # A host mapped onto another host's own name is the same mistake.
    printf 'web01 web03\n' > "$TEST_TMPDIR/names.map"
    run_tx export --plan "$plan" --from "$coll" --names "$TEST_TMPDIR/names.map"
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "--names puts 'web01' and 'web03' on the one target 'web03'"
}

t_a_names_file_for_other_hosts_is_not_a_collision() {
    # Mappings for hosts this run does not have collide with nothing.
    coll="$(write_collection "web01:$STD_A")"
    plan="$(export_plan web01)"
    printf 'web01 R01/u07\nweb09 R01/u07\n' > "$TEST_TMPDIR/names.map"
    run_tx export --plan "$plan" --from "$coll" --names "$TEST_TMPDIR/names.map"
    assert_status 0 "$RUN_RC"
    assert_eq "PASSED" "$(sample "$RUN_OUT" tx_state R01/u07)"
}

t_an_unreadable_record_is_a_host_with_no_record() {
    # A record cut short: with a plan the host was NO-DATA; without one it
    # vanished, with only a line on stderr. Now it is NO-DATA either way.
    coll="$(write_collection "web01:$STD_A" \
                             'web02:{"host":"web02","tag":"bench","sta')"
    # A job's own run.json, cut short, is the job's: not a host called
    # web01~out.
    printf '{"x":' > "$coll/bench~web01~out~run.json"
    run_tx export --plan "$TEST_TMPDIR/none.ini" --from "$coll"
    assert_status 0 "$RUN_RC"
    assert_eq "NO-DATA" "$(sample "$RUN_OUT" tx_state web02)" "no plan, still named"
    assert_contains "$RUN_OUT" "# 1 host(s) have no record (tx_state NO-DATA/NOT-RUN): web02"
    assert_not_contains "$RUN_OUT" "web01~out	" "a job's file is not a host"
    # Another run's broken record, in the same directory, is not this one's.
    printf '{"host":' > "$coll/other~web05~run.json"
    run_tx export --plan "$TEST_TMPDIR/none.ini" --from "$coll"
    assert_status 0 "$RUN_RC"
    assert_eq "" "$(sample "$RUN_OUT" tx_state web05)" "another tag's host"
    assert_contains "$RUN_OUT" "# 1 host(s) have no record (tx_state NO-DATA/NOT-RUN): web02"
}

# ---- the whole way through, against a real run ----------------------------

t_exports_a_real_run_read_from_the_fleet() {
    install_fake_ssh
    plan="$(plan_for --run 'echo hi > "$TX_OUT/who"' --tag live --timeout 30 \
            -- a b c)"
    run_tx run --plan "$plan" --start-in 1 --no-skew-check -d results --quiet
    assert_status 0 "$RUN_RC"
    # export reads the same run.json the fleet still holds -- no --from.
    run_tx export --plan "$plan"
    assert_status 0 "$RUN_RC"
    local h
    for h in a b c; do
        assert_eq "PASSED" "$(sample "$RUN_OUT" tx_state "$h")" "$h passed"
        assert_contains "$RUN_OUT" "tx_start_offset	$h	" "$h has a sync sample"
        assert_contains "$RUN_OUT" "tx_exit	$h	0" "$h exited zero"
    done
}

t_a_live_export_with_a_host_down_still_exports() {
    # A host that cannot be reached while the others have records is data
    # for the floor plan, not a failed export: it stays exit 0 (TX-006).
    install_fake_ssh
    plan="$(plan_for --run true --tag live --timeout 30 -- a b c)"
    run_tx run --plan "$plan" --start-in 1 --no-skew-check -d results --quiet
    assert_status 0 "$RUN_RC"
    host_down b
    run_tx export --plan "$plan" -o out.tsv
    assert_status 0 "$RUN_RC" "one host down, two with records"
    out="$(cat out.tsv)"
    assert_contains "$out" "2 host(s) with a record" "the header counts what ran"
    assert_eq "PASSED" "$(sample "$out" tx_state a)" "a passed"
    assert_eq "UNREACHABLE" "$(sample "$out" tx_state b)" "b is down"
    assert_eq "PASSED" "$(sample "$out" tx_state c)" "c passed"
}

t_a_live_export_with_no_record_is_refused() {
    # tx_state is written for every host, record or not, so the samples were
    # never empty: a fleet with no record anywhere exported its NOT-RUN and
    # UNREACHABLE states and exited 0, and the refusal never fired (TX-006).
    install_fake_ssh
    plan="$(plan_for --run true --tag live --timeout 30 -- a b)"
    # Nothing deployed: every host is NOT-RUN.
    run_tx export --plan "$plan" -o out.tsv
    assert_status 1 "$RUN_RC" "no host deployed"
    assert_contains "$RUN_OUT" "nothing to export -- none of the 2 host(s) has a run record"
    assert_no_file out.tsv "nothing is written when there is nothing to export"
    # --append leaves what is already there alone.
    printf 'history\n' > hist.tsv
    run_tx export --plan "$plan" -o hist.tsv --append
    assert_status 1 "$RUN_RC" "no host deployed, --append"
    assert_eq "history" "$(cat hist.tsv)" "the history was touched"
    # Every host unreachable: the same.
    host_down a b
    run_tx export --plan "$plan"
    assert_status 1 "$RUN_RC" "every host unreachable"
    assert_contains "$RUN_OUT" "nothing to export"
    assert_not_contains "$RUN_OUT" "tx_state" "a refused export wrote samples"
}

echo "export"
run_test "declares a test line per overlay"    t_declares_a_test_line_and_files_every_overlay
run_test "computes the record's numbers"       t_computes_the_numbers_the_record_holds
run_test "state names how each host finished"  t_state_names_how_each_host_finished
run_test "setup/launch failures get a state"   t_setup_and_launch_failures_get_their_own_state
run_test "a blank field is not zero"           t_a_blank_field_is_not_measured_not_zero
run_test "a host with no record is named"      t_a_host_in_the_plan_with_no_record_is_named
run_test "json writes ndjson"                  t_json_writes_ndjson
run_test "no-meta drops the test lines"        t_no_meta_drops_the_test_lines
run_test "names/prefix/run reshape the line"   t_names_and_prefix_and_run_reshape_the_line
run_test "test-prefix keeps two tools apart"   t_test_prefix_keeps_two_tools_apart
run_test "append builds a history"             t_append_builds_a_history
run_test "a run label with a space refused"    t_a_run_label_with_a_space_is_refused
run_test "live export needs a plan"            t_live_export_without_a_plan_is_refused
run_test "an empty collection is refused"      t_an_empty_collection_is_refused
run_test "a host named with a space left out"  t_a_host_named_with_a_space_is_left_out
run_test "names maps a host with a space"      t_names_maps_a_host_named_with_a_space
run_test "only spaced names: nothing to export" t_only_hosts_named_with_a_space_is_nothing_to_export
run_test "a names target with a quote refused" t_a_names_target_that_cannot_be_one_is_refused
run_test "a target prefix with a space refused" t_a_target_prefix_with_a_space_is_refused
run_test "two hosts on one target refused"     t_two_hosts_on_one_target_are_refused
run_test "names for other hosts no collision"  t_a_names_file_for_other_hosts_is_not_a_collision
run_test "an unreadable record has no record"  t_an_unreadable_record_is_a_host_with_no_record
run_test "exports a real run from the fleet"   t_exports_a_real_run_read_from_the_fleet
run_test "a live export with a host down"      t_a_live_export_with_a_host_down_still_exports
run_test "a live export with no record"        t_a_live_export_with_no_record_is_refused
report_tests
