#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

# Mutation tests for tests/test_adversarial.sh (shared_tools TX-004): a
# suite that cannot fail proves nothing. Each record below undoes ONE part
# of a fix in a copy of tx.py -- the line as it is now ('---') becomes the
# line as it was, or as a wrong fix would make it ('+++') -- and runs the
# test that guards that part against the copy. The case passes only when
# that test FAILS. A mutation whose '---' line is no longer in tx.py fails
# loudly ("no longer applies") rather than testing nothing.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helper.bash
source "$DIR/test_helper.bash"
ORIG_TX="$TX"

MUTATIONS=$(cat <<'TABLE'
### t_resume_runs_again_a_host_whose_agent_died
---         return alive and report.get("state") in UNFINISHED
+++         return report.get("state") in UNFINISHED
### t_muster_puts_back_an_item_whose_agent_died
---         return alive and report.get("state") in UNFINISHED
+++         return report.get("state") in UNFINISHED
### t_run_fails_when_an_agent_dies_mid_job
---         if not alive and report.get("state") in UNFINISHED:
+++         if False:
### t_run_fails_when_an_agent_dies_mid_job
---     ("gone", "stopped mid-job"),
+++     # ("gone", "stopped mid-job"),
### t_an_earlier_runs_record_does_not_answer_for_this_one
--- rm -rf {out} {report} {stdout} {stderr} {setuplog} {teardownlog} {log}
+++ : rm -rf {out} {report} {stdout} {stderr} {setuplog} {teardownlog} {log}
### t_the_wait_and_the_lease_count_setup_and_teardown
---     extra = (1 if plan.setup else 0) + (1 if plan.teardown else 0)
+++     extra = 0
### t_the_wait_and_the_lease_count_setup_and_teardown
---     bound = _job_bound(plan, args.batch, args.start_in) + 60
+++     bound = plan.timeout + arm_delay(args.batch, args.start_in) + 60
### t_the_wait_and_the_lease_count_setup_and_teardown
---     return (time.time() + _job_bound(plan, len(plan.hosts), args.start_in)
+++     return (time.time() + plan.timeout + arm_delay(len(plan.hosts), args.start_in)
### t_export_skips_json_that_is_not_a_run_record
---         if not isinstance(report, dict):
+++         if False:
### t_export_skips_json_that_is_not_a_run_record
---         if not host or not isinstance(host, str):
+++         if not host:
### t_export_skips_json_that_is_not_a_run_record
---         if not isinstance(report.get("state"), str):
+++         if False:
### t_export_does_not_take_a_jobs_own_run_json_for_the_record
---         tag = _record_tag(name, host)
+++         tag = name.split(FLAT_SEP, 1)[0] if FLAT_SEP in name else ""
### t_export_reads_one_run_of_a_shared_directory
---     if len(by_tag) == 1:
+++     if True:
### t_export_keeps_records_for_hosts_the_plan_does_not_name
---             hosts = list(plan.hosts) + [h for h in hosts
+++             hosts = list(plan.hosts) + [h for h in ()
### t_a_name_ssh_would_read_as_an_option_is_refused
---     if name.startswith("-") or addr.startswith("-"):
+++     if False:
### t_a_name_ssh_would_read_as_an_option_is_refused
---             die("%s: host %r %s" % (path, name if name == addr
+++             None and die("%s: host %r %s" % (path, name if name == addr
### t_a_name_ssh_would_read_as_an_option_is_refused
---             die("%s: host %r %s" % (args.servers, tok, why))
+++             pass
### t_a_name_ssh_would_read_as_an_option_is_refused
---         if (self.user or "").startswith("-"):
+++         if False:
### t_a_pool_item_that_cannot_be_a_host_is_not_run
---     if name.startswith("-") or addr.startswith("-"):
+++     if False:
### t_a_pool_item_that_cannot_be_a_host_is_not_run
---     if "/" in name:
+++     if False:
### t_a_pool_item_that_cannot_be_a_host_is_not_run
---             unusable = [i for i in fresh
+++             unusable = [i for i in ()
### t_export_refuses_a_test_prefix_that_breaks_the_file
---     if any(c in args.test_prefix for c in BAD_IN_FIELD):
+++     if False:
TABLE
)
export MUTATIONS

# mutant_fails N: build the mutant from record N (0-based), run its test
# against it, and succeed only if that test fails there.
mutant_fails() {
    local n="$1" m="$TEST_TMPDIR/mutant/tx.py" t
    mkdir -p "${m%/*}"
    t=$(python3 - "$ORIG_TX" "$m" "$n" <<'PYMUT'
import os, sys
src, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
lines = os.environ["MUTATIONS"].split("\n")
recs = []
for i, line in enumerate(lines):
    if line.startswith("### "):
        assert lines[i + 1].startswith("--- ") and lines[i + 2].startswith("+++ "), line
        recs.append((line[4:], lines[i + 1][4:], lines[i + 2][4:]))
test, old, new = recs[n]
text = open(src).read()
if text.count(old + "\n") != 1:
    sys.exit("mutation no longer applies, line not found once: " + old)
open(dst, "w").write(text.replace(old + "\n", new + "\n"))
print(test)
PYMUT
) || return 1
    python3 -m py_compile "$m" || { echo "the mutant for $t does not compile" >&2; return 1; }
    # A mutant that is merely broken would fail every test; a quick test
    # the mutation does not touch must still pass against it.
    local sane=t_export_keeps_records_for_hosts_the_plan_does_not_name
    [ "$t" = "$sane" ] && sane=t_export_skips_json_that_is_not_a_run_record
    TX="$m" ONLY="$sane" bash "$DIR/test_adversarial.sh" > "$TEST_TMPDIR/sane.out" 2>&1 || {
        echo "the mutant for $t also breaks $sane, so it proves nothing:" >&2
        tail -n 20 "$TEST_TMPDIR/sane.out" >&2; return 1
    }
    if TX="$m" ONLY="$t" bash "$DIR/test_adversarial.sh" > "$TEST_TMPDIR/mutant.out" 2>&1; then
        echo "MUTANT SURVIVED: $t still passes with this fix reverted" >&2
        tail -n 20 "$TEST_TMPDIR/mutant.out" >&2
        return 1
    fi
    grep -q "FAIL  $t " "$TEST_TMPDIR/mutant.out" || {
        echo "$t did not run against the mutant:" >&2
        cat "$TEST_TMPDIR/mutant.out" >&2; return 1
    }
}

# Every test in test_adversarial.sh has at least one mutation, and every
# mutation names a test that exists.
t_every_test_has_a_mutation() {
    local listed recorded
    listed=$(sed -n '/^TESTS=(/,/^)/p' "$DIR/test_adversarial.sh" | grep -E '^ +t_' | tr -d ' ' | sort)
    recorded=$(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p' | sort -u)
    assert_eq "$listed" "$recorded" "tests vs mutations"
}

echo "adversarial mutations (TX-004)"
run_test "every test has a mutation" t_every_test_has_a_mutation
n=0
while IFS= read -r t; do
    eval "mutation_${n}() { mutant_fails $n; }"
    run_test "mutation $n undoes what ${t#t_} guards" "mutation_${n}"
    n=$((n + 1))
done < <(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p')

report_tests
