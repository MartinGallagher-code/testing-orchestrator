#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# Mutation checks: each fix, taken back out of a copy of tx.py, makes the
# test written for it fail. A regression test that still passes with its
# fix reverted proves nothing, so every fix in TX-001 (stop, clean, doctor
# and status act only on this run's own agent and files) is checked here
# the same way: revert it, run its test against the copy, and see that
# test FAIL by name.
#
# A mutation that no longer matches tx.py exactly once fails loudly
# rather than testing nothing: when the code moves, move the mutation.

# The helper is deliberately not declared with `# shellcheck source=`:
# following it makes every test function below look unreachable, since
# run_test invokes them by name.
# The mutations are tx.py's own text, $-signs and all, so they are quoted
# literally on purpose: SC2016's warning is the point here.
# shellcheck disable=SC2016

# Each check runs a whole test (some wait out a ten-second kill), so the
# per-test limit is wider than the suite's usual minute.
: "${TX_TEST_TIMEOUT:=240}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# mutant OLD NEW -- $TEST_TMPDIR/mutant/tx.py: tx.py with OLD, which must
# occur exactly once, replaced by NEW.
mutant() {
    mkdir -p "$TEST_TMPDIR/mutant"
    python3 - "$TX" "$TEST_TMPDIR/mutant/tx.py" "$1" "$2" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src).read()
n = text.count(old)
if n != 1:
    sys.stderr.write("the mutation matches %d times in tx.py, not once: "
                     "the code has moved, so move the mutation\n" % n)
    sys.exit(3)
open(dst, "w").write(text.replace(old, new))
PY
}

# Some reverted fixes are the old code, which called pgrep and pkill. An
# image with no procps (CI's python:3.6-slim) would make those calls
# no-ops and hide the very bug, so stand them in from /proc there.
procps_stand_in() {
    command -v pkill > /dev/null 2>&1 && return 0
    local dir="$TEST_TMPDIR/procps"
    mkdir -p "$dir"
    cat > "$dir/pgrep" <<'PY'
#!/usr/bin/env python3
"""pgrep/pkill [-SIG] [-f] [-u UID] [-P PPID] PATTERN, read from /proc."""
import os, re, signal, sys
prog = os.path.basename(sys.argv[0])
sig, full, uid, ppid, pattern = signal.SIGTERM, False, None, None, None
args = sys.argv[1:]
i = 0
while i < len(args):
    a = args[i]
    if a == "-f":
        full = True
    elif a in ("-u", "-P"):
        i += 1
        if a == "-u":
            uid = args[i]
        else:
            ppid = args[i]
    elif prog == "pkill" and a.startswith("-") and len(a) > 1:
        name = a[1:]
        sig = int(name) if name.isdigit() else getattr(signal, "SIG" + name)
    else:
        pattern = a
    i += 1
found = []
for p in os.listdir("/proc"):
    if not p.isdigit() or int(p) == os.getpid():
        continue
    try:
        with open("/proc/%s/cmdline" % p, "rb") as fh:
            cmd = fh.read().replace(b"\0", b" ").decode("utf-8", "replace")
        with open("/proc/%s/stat" % p) as fh:
            stat = fh.read()
        owner = os.stat("/proc/%s" % p).st_uid
    except (IOError, OSError):
        continue
    comm, rest = stat.split("(", 1)[1].rsplit(")", 1)
    fields = rest.split()
    if fields[0] == "Z":
        continue
    if ppid is not None and fields[1] != ppid:
        continue
    if uid is not None and str(owner) != uid:
        continue
    if pattern is not None and not re.search(pattern, cmd if full else comm):
        continue
    found.append(int(p))
for p in found:
    if prog == "pgrep":
        print(p)
    else:
        try:
            os.kill(p, sig)
        except OSError:
            pass
sys.exit(0 if found else 1)
PY
    chmod +x "$dir/pgrep"
    ln -s pgrep "$dir/pkill"
    export PATH="$dir:$PATH"
}

# caught FILE LABEL... -- run those tests of FILE against the mutant, and
# each must FAIL. Matching "FAIL  label" rather than the exit status: a
# label that no longer exists would run nothing and exit 0, and a test
# that broke for some other reason must not pass for this one.
caught() {
    local file="$1"; shift
    local only out label
    only="$(IFS='|'; echo "$*")"
    out="$(TX="$TEST_TMPDIR/mutant/tx.py" TX_TEST_ONLY="$only" \
           bash "$REPO_ROOT/tests/$file" 2>&1)"
    for label in "$@"; do
        assert_contains "$out" "FAIL  $label" \
            "with the fix reverted, \"$label\" should fail"
    done
}

# ---- only this run's agent -------------------------------------------------

m_stop_waits_on_any_agent() {
    # The bug as it was: wait on *any* `tx.py agent`, then pkill -KILL
    # them all -- the other run's included.
    procps_stand_in
    mutant '        while :; do
            left=""
            for p in $targets; do tx_ours "$p" && left="$left $p"; done
            [ -z "$left" ] && break
            [ "$i" -ge 20 ] && break
            sleep 0.5
            i=$((i+1))
        done
        if [ -n "$left" ]; then' '        while [ "$i" -lt 20 ]; do
            pgrep -f '"'"'[t]x[.]py agent'"'"' >/dev/null 2>&1 || break
            sleep 0.5
            i=$((i+1))
        done
        left=""
        if pgrep -f '"'"'[t]x[.]py agent'"'"' >/dev/null 2>&1; then
            pkill -KILL -f '"'"'[t]x[.]py agent'"'"' 2>/dev/null' || return 1
    caught test_fleet.sh "two runs: stop leaves the other"
}

m_a_live_pid_is_trusted() {
    # agent.pid trusted on `kill -0` alone, as the kill block had it.
    #
    # The pid file's own check, and not tx_ours itself: tx_scan puts every
    # pid on the machine to tx_ours, so a tx_ours that says yes to any live
    # pid makes a lost pid file "kill everything" -- pid 1 included, which
    # on a test runner is the whole container. No mutation here may widen
    # what tx_ours accepts.
    mutant '    if tx_ours "$pid"; then
        targets=$pid' '    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        targets=$pid' || return 1
    caught test_fleet.sh "a stale agent.pid is not trusted"
}

m_a_lost_pid_file_is_not_searched() {
    mutant '        tx_scan
        targets=$tx_found' '        targets=""' || return 1
    caught test_fleet.sh "two runs: lost pid file"
}

m_without_proc_kill_by_name() {
    procps_stand_in
    mutant '        if [ "$found" -eq 0 ]; then
            refused="REFUSED: $d has no {pid} and' '        if [ "$found" -eq 0 ]; then
            pkill -TERM -f '"'"'[t]x[.]py agent'"'"'
            status=stopped
        elif false; then
            refused="REFUSED: $d has no {pid} and' || return 1
    caught test_fleet.sh "no /proc: lost pid file refused"
}

m_any_agent_is_a_leftover() {
    mutant '        for p in $mine; do tx_ours "$p" && left="$left $p"; done' \
           '        for p in $mine; do left="$left $p"; done' || return 1
    caught test_fleet.sh "two runs: clean is clean"
}

m_doctor_counts_any_agent() {
    mutant 'running=no
if [ -n "$here" ]; then' 'running=no
pgrep -f '"'"'[t]x[.]py agent'"'"' >/dev/null 2>&1 && running=yes
if [ -n "$here" ]; then' || return 1
    caught test_fleet.sh "two runs: doctor sees its own"
}

# ---- clean deletes only what tx put there ---------------------------------

m_clean_deletes_anything() {
    # Everything in the directory counted as tx's: `rm -rf "$d"` again.
    mutant '        tx_own() {{
' '        tx_own() {{
            return 0
' || return 1
    caught test_fleet.sh "clean spares a stranger's file" \
                         "clean spares a directory not made"
}

m_deploy_claims_what_was_there() {
    # The deploy recording every payload name, there before it or not.
    mutant '    [ -e "$n" ] || [ -L "$n" ] || printf '"'"'%%s\\n'"'"' "$n" >> %s' \
           '    printf '"'"'%%s\\n'"'"' "$n" >> %s' || return 1
    caught test_fleet.sh "clean spares a directory not made"
}

m_the_agent_records_nothing() {
    # Without the agent's record, what the job made is a stranger's.
    mutant '        new = sorted(n for n in _entries(workdir) - before - own' \
           '        new = [] and sorted(n for n in _entries(workdir) - before - own' \
        || return 1
    caught test_fleet.sh "clean takes what the run made"
}

# ---- run --clean says when its clean failed --------------------------------

m_run_ignores_its_clean() {
    mutant '        cleaned = cmd_clean(args, plan)' \
           '        cmd_clean(args, plan)' || return 1
    caught test_fleet.sh "run --clean that fails says so"
}

m_waves_ignore_their_clean() {
    mutant '            unclean = bool(cmd_clean(args, sub))
            if unclean:
                trouble.append(n)' '            cmd_clean(args, sub)' || return 1
    caught test_waves.sh "an uncleaned wave is counted" \
                         "stop-on-fail stops at an unclean"
}

m_muster_ignores_its_clean() {
    mutant '                    unclean = bool(cmd_clean(args, sub))
                    if unclean:
                        trouble.append(wave)' '                    cmd_clean(args, sub)' \
        || return 1
    caught test_muster.sh "an uncleaned wave is counted"
}

# ---- a sweep's results are its own (TX-008) --------------------------------

m_resume_counts_any_result() {
    # The bug as it was: any finished record on a host is this sweep's.
    mutant '                if _has_result(seen[h]) and _of_sweep(seen[h][1], sweep)]' \
           '                if _has_result(seen[h])]' || return 1
    caught test_sweeps.sh "an earlier sweep's hosts run again"
}

m_resume_ignores_the_collection() {
    # Only the fleet asked: a --clean sweep's finished waves run again.
    mutant '            report = _filed_result(args.dir, plan.tag, h, sweep)' \
           '            report = None' || return 1
    caught test_sweeps.sh "a clean sweep resumes, no host twice"
}

m_the_collection_counts_any_sweep() {
    mutant '    if (_of_sweep(report, sweep) and report.get("host") == host' \
           '    if (report.get("host") == host' || return 1
    caught test_sweeps.sh "another sweep's filed record"
}

m_resume_leaves_its_hosts() {
    # What resume picked up was collected, and never cleaned.
    mutant '    bad = bool(cmd_collect(args, sub))
    if args.clean:' '    bad = bool(cmd_collect(args, sub))
    if False:' || return 1
    caught test_sweeps.sh "a clean sweep resumes, no host twice"
}

m_the_agent_is_never_told_the_sweep() {
    # No TX_SWEEP_ID on the launch: no record carries the id, and a value
    # left in the environment passes for one.
    mutant '    launch = ("TX_SWEEP_ID=%s nohup' '    launch = (": %s; nohup' \
        || return 1
    caught test_sweeps.sh "one id on every record"
}

m_a_start_keeps_the_last_out() {
    mutant 'rm -rf {out} {report} {stdout} {stderr} {setuplog} {teardownlog} {log}
{launch}' 'rm -rf {report} {stdout} {stderr} {setuplog} {teardownlog} {log}
{launch}' || return 1
    caught test_sweeps.sh "no-deploy collects only this run"
}

m_a_start_keeps_the_last_logs() {
    mutant 'rm -rf {out} {report} {stdout} {stderr} {setuplog} {teardownlog} {log}
{launch}' 'rm -rf {out} {report} {stdout} {stderr} {teardownlog} {log}
{launch}' || return 1
    caught test_sweeps.sh "no-deploy collects only this run"
}

# ---- Ctrl-C during tx run (TX-005) ------------------------------------------

m_the_wait_says_nothing() {
    # The bug as it was: a bare "[tx] interrupted", naming nothing still
    # running and no next command.
    mutant '    except KeyboardInterrupt:
        left = _interrupted_run("[tx] interrupted", plan.hosts, seen)' \
           '    except ZeroDivisionError:
        left = _interrupted_run("[tx] interrupted", plan.hosts, seen)' \
        || return 1
    caught test_interrupt.sh "in the wait, the job is left running"
}

m_an_interrupted_arming_is_left_armed() {
    # The armed hosts are not stood down: they run the job alone.
    mutant '    left = _stand_down(fleet, begun)' '    left = []' || return 1
    caught test_interrupt.sh "while arming, the armed stand down" \
                             "a terminal ctrl-c, ssh killed too" \
                             "a muster wave arming puts items back"
}

m_a_second_ctrl_c_cuts_the_stand_down() {
    mutant '    held = signal.signal(signal.SIGINT, signal.SIG_IGN)' \
           '    held = signal.getsignal(signal.SIGINT)' || return 1
    caught test_interrupt.sh "a second ctrl-c waits for the stand-down"
}

m_a_sweep_gives_no_resume() {
    mutant '                            + ([] if args.resume else ["--resume"])),' \
           '                            + []),' || return 1
    caught test_interrupt.sh "a sweep says how to resume it"
}

m_a_muster_wave_is_left_to_its_lease() {
    # The bug as it was: exit on the spot, every item still held.
    mutant '                wave_states, unclean = _muster_interrupted(' \
           '                raise; wave_states, unclean = _muster_interrupted(' \
        || return 1
    caught test_interrupt.sh "a muster wave checks in what finished"
}

m_a_muster_wave_is_checked_in_uncollected() {
    mutant '            cmd_collect(args, part)' '            part = part' \
        || return 1
    caught test_interrupt.sh "a muster wave checks in what finished"
}

m_a_stood_down_muster_wave_stays_held() {
    mutant '                hold(head, [i for i in fresh if i not in exc.left])' \
           '                hold(head, [i for i in () if i not in exc.left])' \
        || return 1
    caught test_interrupt.sh "a muster wave arming puts items back"
}

# ---- status and export exit as the other fleet commands do (TX-006) -------

m_status_exits_0_whatever_it_found() {
    # The bug as it was: a report, so 0 whatever it found.
    mutant '            break
    return 1 if failed else 0' '            break
    return 0' || return 1
    caught test_fleet.sh "status reports the exit code" \
        "status: unreachable host exits 1" "status: a GONE host exits 1" \
        "status: timeout, setup exit 1" "readers name the refusal"
    caught test_streams.sh "a host that never ran is reported"
}

m_status_fails_a_host_still_at_work() {
    mutant '    # Still at work, unless nothing is left to do it: GONE.
    return not alive' '    # Still at work, unless nothing is left to do it: GONE.
    return True' || return 1
    caught test_fleet.sh "status says what each host does"
    caught test_agent.sh "a host tidying says so"
}

m_status_reads_gone_as_still_at_work() {
    mutant '    # Still at work, unless nothing is left to do it: GONE.
    return not alive' '    # Still at work, unless nothing is left to do it: GONE.
    return False' || return 1
    caught test_fleet.sh "status: a GONE host exits 1"
}

m_status_fails_a_fleet_with_nothing_yet() {
    mutant '        return word not in STATUS_NOTHING_YET' \
           '        return word is not None' || return 1
    caught test_fleet.sh "status says what each host does"
}

m_status_reads_unreachable_as_nothing_yet() {
    mutant 'STATUS_NOTHING_YET = ("NOT-DEPLOYED", "NOT-RUNNING", "NOT-STARTED-YET")' \
           'STATUS_NOTHING_YET = ("NOT-DEPLOYED", "NOT-RUNNING", "NOT-STARTED-YET",
                      "UNREACHABLE")' || return 1
    caught test_fleet.sh "status: unreachable host exits 1"
}

m_status_fails_a_dry_run() {
    mutant '        failed = not fleet.dry_run and any(' \
           '        failed = any(' || return 1
    caught test_fleet.sh "status says what each host does"
}

m_status_watch_exits_0() {
    mutant '            # the last look at the fleet found.
            break' '            # the last look at the fleet found.
            return 0' || return 1
    caught test_interrupt.sh "status --watch exits as it last saw"
}

m_status_watch_stops_on_a_failure() {
    mutant '        if not args.watch:
            break
        try:
            time.sleep(args.watch)' '        if not args.watch or failed:
            break
        try:
            time.sleep(args.watch)' || return 1
    caught test_interrupt.sh "status --watch exits as it last saw"
}

m_export_counts_samples_not_hosts() {
    # The bug as it was: tx_state is always written, so this never fired.
    mutant '    if not ran:
        die("nothing to export' '    if not out.samples:
        die("nothing to export' || return 1
    caught test_export.sh "a live export with no record"
}

m_export_refuses_a_host_down() {
    mutant '    if not ran:
        die("nothing to export' '    if ran < len(hosts):
        die("nothing to export' || return 1
    caught test_export.sh "a live export with a host down"
}

# ---- a lease that lapses in a --muster sweep (TX-009) -----------------------

m_a_lapsed_lease_ends_the_sweep() {
    # The bug as it was: a take that handed back only items whose lease
    # had lapsed was read as an empty pool, and the sweep ended.
    mutant '                    by_name = _fresh_in_pool(args, seen, args.batch)' \
           '                    by_name = []' || return 1
    caught test_muster.sh "a lapsed lease does not end it"
}

m_a_lapsed_item_is_released_under_its_first_lease() {
    # The bug as it was, in effect: released under the lease it was first
    # taken on, which no longer holds it, so muster refused the release
    # with a CONFLICT naming tx's own newer lease.
    mutant '            holding[item] = head' \
           '            holding.setdefault(item, head)' || return 1
    caught test_muster.sh "a lapsed item is released once"
}

m_a_running_item_is_put_back() {
    # An item left to its lease, handed back once that lapsed, was put
    # back at the end with the items that never ran.
    mutant '                    if item in leased:' \
           '                    if False:' || return 1
    caught test_muster.sh "a running item stays left"
}

m_an_item_by_name_is_an_option() {
    mutant '            want = (["--item=%s" % i for i in by_name] if by_name' \
           '            want = ([a for i in by_name for a in ("--item", i)] if by_name' \
        || return 1
    caught test_muster.sh "an item by name can start with -"
}

# ---- a --lease shorter than one wave (TX-011) -------------------------------

m_a_short_lease_is_not_warned_about() {
    # The warning taken back out: the sweep is as it was before TX-011.
    mutant '    short = muster_lease_warning(args, plan)' \
           '    short = None' || return 1
    caught test_muster.sh "a short lease warns once"
}

m_the_lease_comparison_is_turned_around() {
    # Warns about a lease that covers the wave, and not one that does not.
    mutant '    if given >= wave:' \
           '    if given < wave:' || return 1
    caught test_muster.sh "a short lease warns once" \
        "a long enough lease does not warn" "the lease reads as muster reads it"
}

echo "mutations"
run_test "stop waiting on any agent is caught"  m_stop_waits_on_any_agent
run_test "trusting a live pid is caught"        m_a_live_pid_is_trusted
run_test "not searching for it is caught"       m_a_lost_pid_file_is_not_searched
run_test "no /proc, kill by name is caught"     m_without_proc_kill_by_name
run_test "any agent a leftover is caught"       m_any_agent_is_a_leftover
run_test "doctor counting any agent is caught"  m_doctor_counts_any_agent
run_test "clean deleting anything is caught"    m_clean_deletes_anything
run_test "deploy claiming all is caught"        m_deploy_claims_what_was_there
run_test "an agent recording nothing is caught" m_the_agent_records_nothing
run_test "run ignoring its clean is caught"     m_run_ignores_its_clean
run_test "waves ignoring clean is caught"       m_waves_ignore_their_clean
run_test "muster ignoring clean is caught"      m_muster_ignores_its_clean
run_test "resume counting any result is caught" m_resume_counts_any_result
run_test "resume ignoring results/ is caught"   m_resume_ignores_the_collection
run_test "any sweep's filed record is caught"   m_the_collection_counts_any_sweep
run_test "resume leaving hosts is caught"       m_resume_leaves_its_hosts
run_test "an untold agent is caught"            m_the_agent_is_never_told_the_sweep
run_test "a start keeping out/ is caught"       m_a_start_keeps_the_last_out
run_test "a start keeping logs is caught"       m_a_start_keeps_the_last_logs
run_test "a silent ctrl-c wait is caught"       m_the_wait_says_nothing
run_test "an armed fleet left is caught"        m_an_interrupted_arming_is_left_armed
run_test "a cut stand-down is caught"           m_a_second_ctrl_c_cuts_the_stand_down
run_test "a sweep with no resume is caught"     m_a_sweep_gives_no_resume
run_test "a muster wave left held is caught"    m_a_muster_wave_is_left_to_its_lease
run_test "an uncollected check-in is caught"    m_a_muster_wave_is_checked_in_uncollected
run_test "a stood-down wave held is caught"     m_a_stood_down_muster_wave_stays_held
run_test "status exiting 0 is caught"           m_status_exits_0_whatever_it_found
run_test "status failing work is caught"        m_status_fails_a_host_still_at_work
run_test "status missing GONE is caught"        m_status_reads_gone_as_still_at_work
run_test "status failing nothing-yet is caught" m_status_fails_a_fleet_with_nothing_yet
run_test "status passing unreachable is caught" m_status_reads_unreachable_as_nothing_yet
run_test "status failing a dry run is caught"   m_status_fails_a_dry_run
run_test "a watch exiting 0 is caught"          m_status_watch_exits_0
run_test "a watch that stops is caught"         m_status_watch_stops_on_a_failure
run_test "export counting samples is caught"    m_export_counts_samples_not_hosts
run_test "export refusing a host down is caught" m_export_refuses_a_host_down
run_test "a lapsed lease ending it is caught"  m_a_lapsed_lease_ends_the_sweep
run_test "a release under the old lease caught" m_a_lapsed_item_is_released_under_its_first_lease
run_test "a running item put back is caught"   m_a_running_item_is_put_back
run_test "an item read as an option is caught" m_an_item_by_name_is_an_option
run_test "a short lease unwarned is caught"   m_a_short_lease_is_not_warned_about
run_test "a lease compared backwards caught" m_the_lease_comparison_is_turned_around
report_tests
