#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# Mutation tests for the --remote-dir guard's tests in test_fleet.sh
# (shared_tools TX-002): a suite that cannot fail proves nothing. Each
# record below undoes one part of the guard in a copy of tx.py -- the text
# as it is now ('---') becomes the text as it was, or as a wrong fix would
# make it ('+++') -- and runs the test that guards that part against the
# copy. The case passes only when that test FAILS.
#
# In a record, \n stands for a newline. A mutation whose '---' text is not
# in tx.py exactly once fails loudly ("no longer applies") rather than
# testing nothing.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MUTATIONS=$(cat <<'TABLE'
### t_a_symlinked_remote_dir_is_refused_and_its_target_left_alone
--- _tx_dir_check() {\n    _tx_bad=""
+++ _tx_dir_check() {\n    return 0\n    _tx_bad=""
### t_a_symlinked_remote_dir_is_refused_and_its_target_left_alone
---     return rdir.rstrip("/") or rdir
+++     return rdir
### t_a_group_or_world_writable_remote_dir_is_refused
---             ?????w*) _tx_why=
+++             ?????W*) _tx_why=
### t_a_group_or_world_writable_remote_dir_is_refused
---         ????????w*) _tx_why=
+++         ????????W*) _tx_why=
### t_a_remote_dir_another_user_owns_is_refused
--- [ "$_tx_du" = "$_tx_id" ] || _tx_why=
+++ true || _tx_why=
### t_a_planted_pid_in_a_refused_dir_is_never_signalled
---     script = _dir_guard(fleet) + _kill_block(fleet.dir) + 'echo
+++     script = _kill_block(fleet.dir) + 'echo
### t_a_planted_pid_in_a_refused_dir_is_never_signalled
---     script = _dir_guard(fleet) + _kill_block(fleet.dir) + """
+++     script = _kill_block(fleet.dir) + """
### t_a_new_remote_dir_is_made_private
---     mkdir -p -m 700 -- %s
+++     mkdir -p -- %s
### t_a_symlink_at_the_agent_payload_or_pid_file_is_replaced_not_followed
--- rm -f -- {agent} && mv -f -- "$s"/{agent} {agent}
+++ cp -- "$s"/{agent} {agent}
### t_a_symlink_at_the_agent_payload_or_pid_file_is_replaced_not_followed
--- rm -f -- "$t" {pid}\necho "$agent_pid" > "$t" && mv -f -- "$t" {pid}
+++ echo "$agent_pid" > {pid}
### t_a_symlink_at_the_agent_payload_or_pid_file_is_replaced_not_followed
--- fleet.push(host, [tarball], stage + "/payload.tar.gz")
+++ fleet.push(host, [tarball], "payload.tar.gz")
### t_a_tx_py_swapped_after_the_copy_is_not_run
---     return _dir_guard(fleet) + """
+++     return """
### t_a_tx_py_swapped_after_the_copy_is_not_run
--- fleet.sh(h, _dir_guard(fleet)\n
+++ fleet.sh(h, ""\n
### t_status_collect_logs_summarize_and_doctor_name_the_refusal
---     script = _dir_guard(fleet) + _status_script(fleet.dir)
+++     script = _status_script(fleet.dir)
### t_status_collect_logs_summarize_and_doctor_name_the_refusal
---     script = (_dir_guard(fleet, to_stderr=True)\n
+++     script = (""\n
### t_status_collect_logs_summarize_and_doctor_name_the_refusal
---         rc, out = fleet.sh(host, _dir_guard(fleet), timeout=30)
+++         rc, out = 0, ""
### t_status_collect_logs_summarize_and_doctor_name_the_refusal
--- if [ -n "$refused" ]; then echo "$refused"; exit 1; fi
+++ :
### t_the_shared_opt_out_lifts_the_group_check_only
---     if [ "$_tx_shared" != 1 ]; then
+++     if true; then
### t_the_shared_opt_out_lifts_the_group_check_only
--- default=_env("TX_ALLOW_SHARED_REMOTE_DIR", "") == "1",
+++ default=False,
### t_the_shared_opt_out_lifts_the_group_check_only
--- self.shared = bool(getattr(args, "allow_shared_remote_dir", False))
+++ self.shared = False
### t_check_hints_and_help_describe_the_guard
---     log("[tx] remote %s on each host:
+++     log("[tx] somewhere %s on each host:
TABLE
)
export MUTATIONS

# A test none of the mutations touch: it must still pass against every
# mutant, or the mutant is merely broken and its failure proves nothing.
SANE=t_a_job_with_no_payload_still_runs

# mutant_fails N: build the mutant from record N (0-based), run its test
# against it, and succeed only if that test fails there.
mutant_fails() {
    local n="$1" m="$TEST_TMPDIR/mutant/tx.py" t
    mkdir -p "${m%/*}"
    t=$(python3 - "$TX" "$m" "$n" <<'PYMUT'
import os, sys
src, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
def expand(s):
    return s.replace("\\n", "\n")
lines = os.environ["MUTATIONS"].split("\n")
recs = []
for i, line in enumerate(lines):
    if line.startswith("### "):
        assert lines[i + 1].startswith("--- ") and lines[i + 2].startswith("+++"), line
        recs.append((line[4:], expand(lines[i + 1][4:]), expand(lines[i + 2][4:])))
test, old, new = recs[n]
text = open(src).read()
if text.count(old) != 1:
    sys.exit("mutation no longer applies, text not found exactly once: " + old)
open(dst, "w").write(text.replace(old, new))
print(test)
PYMUT
) || return 1
    python3 -m py_compile "$m" || { echo "the mutant for $t does not compile" >&2; return 1; }
    if ! TX="$m" TX_ONLY="$SANE" bash "$DIR/test_fleet.sh" > "$TEST_TMPDIR/sane.out" 2>&1 \
            || ! grep -q "^    PASS  " "$TEST_TMPDIR/sane.out"; then
        echo "the mutant for $t also breaks $SANE, so it proves nothing:" >&2
        tail -n 20 "$TEST_TMPDIR/sane.out" >&2
        return 1
    fi
    if TX="$m" TX_ONLY="$t" bash "$DIR/test_fleet.sh" > "$TEST_TMPDIR/mutant.out" 2>&1; then
        echo "MUTANT SURVIVED: $t still passes with this part undone" >&2
        tail -n 20 "$TEST_TMPDIR/mutant.out" >&2
        return 1
    fi
    grep -q "^    FAIL  " "$TEST_TMPDIR/mutant.out" || {
        echo "$t did not run against the mutant:" >&2
        cat "$TEST_TMPDIR/mutant.out" >&2
        return 1
    }
}

t_every_guard_test_has_a_mutation() {
    # Every test in test_fleet.sh's TX-002 section has at least one
    # mutation, and every mutation names a test that exists there.
    local listed recorded
    listed=$(sed -n '/^# ---- TX-002/,/^# ---- end TX-002/p' "$DIR/test_fleet.sh" \
        | sed -n 's/^\(t_[a-z0-9_]*\)() {$/\1/p' | sort)
    recorded=$(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p' | sort -u)
    assert_eq "$listed" "$recorded" "the guard's tests vs the mutations"
}

echo "remote-dir guard mutations"
run_test "every guard test has a mutation" t_every_guard_test_has_a_mutation

n=0
while IFS= read -r t; do
    eval "mutation_${n}() { mutant_fails ${n}; }"
    run_test "mutant ${n} fails ${t#t_}" "mutation_${n}"
    n=$((n + 1))
done < <(printf '%s\n' "$MUTATIONS" | sed -n 's/^### //p')

report_tests
