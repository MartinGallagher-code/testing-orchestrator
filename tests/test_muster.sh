#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# --muster: draw the work from a binnacle muster pool a wave at a time,
# check each lot back in, until the pool has nothing left to hand out.
# What has to hold is that the pool decides which items and in what order,
# that an item that ran is checked in done and one nothing reached is put
# back, and that a second worker's held items are left strictly alone.
#
# testing-orchestrator does not depend on binnacle, and CI has no `muster` on
# it, so a small faithful double stands in -- the same idea as the fake
# ssh/scp shims. It implements only the contract tx uses (take/done/
# release/status, leases, the ticket's lease header), which is exactly
# what makes it a useful test: it is the pool's side of the conversation.

# shellcheck disable=SC2016
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# A muster test double on PATH. A CSV pool with a lease, and just the
# verbs tx calls. Not binnacle's muster -- the real thing expands ranges,
# reports STUCK items and much else -- but the same wire contract.
install_fake_muster() {
    cat > "$FAKE_BIN/muster" <<'PYEOF'
#!/usr/bin/env python3
import csv, os, sys, time, argparse, random

FIELDS = ["item", "state", "holder", "lease_id", "taken_ts",
          "expires_ts", "done_ts", "attempts", "note"]

def dur(text):
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    text = str(text).strip().lower()
    if text and text[-1] in units:
        return float(text[:-1]) * units[text[-1]]
    return float(text)

def read_pool(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as fh:
        return [dict(r) for r in csv.DictReader(fh)]

def write_pool(path, rows):
    tmp = path + ".tmp"
    with open(tmp, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS)
        w.writeheader()
        for r in rows:
            w.writerow(dict((k, r.get(k, "")) for k in FIELDS))
    os.rename(tmp, path)

def expire(rows, now):
    # An expired lease is not a lease: worked out from the timestamps as
    # the pool is opened, exactly as the real muster does.
    for r in rows:
        if r["state"] == "held" and r["expires_ts"] and \
                float(r["expires_ts"]) <= now:
            r["state"] = "available"
            r["holder"] = r["lease_id"] = r["taken_ts"] = ""
            r["expires_ts"] = ""

def names_in(text):
    out = []
    for line in text.splitlines():
        line = line.split("#", 1)[0]
        for tok in line.replace(",", " ").split():
            out.append(tok)
    return out

def ticket_items(path):
    lease, items = "", []
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("#"):
                parts = line.split()
                if len(parts) >= 3 and parts[1] == "lease":
                    lease = parts[2]
            elif line.strip():
                items.extend(line.split())
    return items, lease

def main():
    # Subparsers, like the real muster: a positional count can then follow
    # the --pool/--quiet flags tx puts first, which a single flat parser
    # rejects as an unrecognized argument.
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="verb")

    def common(p):
        p.add_argument("--pool", default="muster.csv")
        p.add_argument("--quiet", action="store_true")
        p.add_argument("--as", dest="holder", default="")
        return p

    p = common(sub.add_parser("add"))
    p.add_argument("count", nargs="?")
    p = common(sub.add_parser("take"))
    p.add_argument("count", nargs="?")
    p.add_argument("--lease", default="1h")
    p.add_argument("-o", "--output")
    p.add_argument("--item", action="append", default=[])
    for v in ("done", "release"):
        p = common(sub.add_parser(v))
        p.add_argument("count", nargs="?")      # the ticket path
        p.add_argument("--item", action="append", default=[])
    p = common(sub.add_parser("list"))
    p.add_argument("--state", default="any")
    p = common(sub.add_parser("status"))
    p.add_argument("--csv", action="store_true")
    a = ap.parse_args()
    for attr, default in (("lease", "1h"), ("output", None), ("item", []),
                          ("state", "any"), ("csv", False), ("count", None)):
        if not hasattr(a, attr):
            setattr(a, attr, default)
    rows = read_pool(a.pool)
    now = time.time()
    holder = a.holder or "tester@box:1"

    if a.verb == "add":
        have = set(r["item"] for r in rows)
        for name in names_in(a.count or ""):
            if name not in have:
                rows.append({"item": name, "state": "available",
                             "attempts": "0"})
                have.add(name)
        write_pool(a.pool, rows)
        return 0

    expire(rows, now)
    by = dict((r["item"], r) for r in rows)

    if a.verb == "take":
        lease_id = "L%06x" % random.randrange(1 << 24)
        exp = now + dur(a.lease)
        taken = []
        if a.item:
            for name in names_in(" ".join(a.item)):
                r = by.get(name)
                if r and r["state"] == "available":
                    taken.append(r)
        else:
            want = int(a.count) if a.count else 1
            for r in rows:
                if len(taken) >= want:
                    break
                if r["state"] == "available":
                    taken.append(r)
        for r in taken:
            r.update(state="held", holder=holder, lease_id=lease_id,
                     taken_ts="%d" % now, expires_ts="%d" % exp,
                     attempts="%d" % (int(r.get("attempts") or 0) + 1))
        write_pool(a.pool, rows)
        lines = ["# muster ticket (test double) -- %d item(s)" % len(taken),
                 "# lease %s expires %d" % (lease_id, exp)]
        lines += [r["item"] for r in taken]
        text = "\n".join(lines) + "\n"
        if a.output:
            with open(a.output, "w") as fh:
                fh.write(text)
        else:
            sys.stdout.write(text)
        return 0

    if a.verb in ("done", "release"):
        items, lease = (names_in(" ".join(a.item)), "") if a.item \
            else ticket_items(a.count)
        findings = 0
        for name in items:
            r = by.get(name)
            if r is None:
                sys.stderr.write("  UNKNOWN   %s not in the pool\n" % name)
                findings += 1
                continue
            mine = (not lease) or r["lease_id"] == lease
            if a.verb == "done":
                if not mine and r["state"] == "held":
                    sys.stderr.write("  CONFLICT  %s held by %s\n"
                                     % (name, r["holder"]))
                    findings += 1
                r.update(state="done", done_ts="%d" % now, lease_id="",
                         expires_ts="")
            else:
                if r["state"] == "done":
                    continue
                if not mine and r["state"] == "held":
                    sys.stderr.write("  CONFLICT  %s held by %s -- left "
                                     "alone\n" % (name, r["holder"]))
                    findings += 1
                    continue
                r.update(state="available", holder="", lease_id="",
                         taken_ts="", expires_ts="")
        write_pool(a.pool, rows)
        return 1 if findings else 0

    if a.verb == "list":
        w = csv.DictWriter(sys.stdout, fieldnames=FIELDS, lineterminator="\n")
        w.writeheader()
        for r in rows:
            if a.state in ("any", r["state"]):
                w.writerow(dict((k, r.get(k, "")) for k in FIELDS))
        return 0

    if a.verb == "status":
        total = len(rows)
        done = sum(1 for r in rows if r["state"] == "done")
        held = sum(1 for r in rows if r["state"] == "held")
        avail = total - done - held
        if a.csv:
            sys.stdout.write("pool,total,done,held,available,done_pct,stuck\n")
            pct = "%.2f" % (100.0 * done / total) if total else ""
            sys.stdout.write("%s,%d,%d,%d,%d,%s,0\n"
                             % (os.path.basename(a.pool), total, done, held,
                                avail, pct))
        else:
            pct = int(round(100.0 * done / total)) if total else 0
            sys.stdout.write("  PROGRESS   %d of %d done (%d%%), %d held, "
                             "%d available\n" % (done, total, pct, held, avail))
        return 0

    sys.stderr.write("fake muster: unknown verb %s\n" % a.verb)
    return 2

sys.exit(main())
PYEOF
    chmod +x "$FAKE_BIN/muster"
}

# A plan whose job records that it ran, over NAME... Echoes the plan path.
sweep_plan() {
    plan_for --run 'echo "$TX_HOST" > "$TX_OUT/who"' --tag pool \
             --timeout 30 -- "$@"
}

# A pool file at $TEST_TMPDIR/pool.csv holding the named items.
make_pool() {
    muster add "$*" --pool "$TEST_TMPDIR/pool.csv" > /dev/null
    echo "$TEST_TMPDIR/pool.csv"
}

# ---- the pool is drawn down, once each ------------------------------------

t_every_pool_item_is_run_and_checked_in_done() {
    install_fake_ssh
    install_fake_muster
    pool="$(make_pool a b c d e)"
    plan="$(sweep_plan a b c d e)"
    run_tx run --plan "$plan" --muster "$pool" --batch 2 --start-in 1 \
        --no-skew-check -d results --quiet
    assert_status 0 "$RUN_RC"
    for h in a b c d e; do
        assert_file_exists "results/pool~$h~out~who" "$h was never run"
    done
    # muster's own last word: everything done.
    assert_eq "pool.csv,5,5,0,0,100.00,0" \
        "$(muster status --pool "$pool" --csv | tail -1)"
}

t_a_pool_bigger_than_the_batch_takes_several_waves() {
    install_fake_ssh
    install_fake_muster
    pool="$(make_pool a b c d e f g)"
    plan="$(sweep_plan a b c d e f g)"
    run_tx run --plan "$plan" --muster "$pool" --batch 3 --start-in 1 \
        --no-skew-check -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_eq "7" "$(find results -name 'pool~*~out~who' | wc -l | tr -d ' ')"
    # Three waves (3+3+1), and one directory for the lot.
    assert_contains "$RUN_OUT" "wave 3"
    assert_contains "$RUN_OUT" "in 3 waves"
}

t_a_batch_bigger_than_the_pool_is_one_wave() {
    install_fake_ssh
    install_fake_muster
    pool="$(make_pool a b)"
    plan="$(sweep_plan a b)"
    run_tx run --plan "$plan" --muster "$pool" --batch 50 --start-in 1 \
        --no-skew-check -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_eq "2" "$(find results -name 'pool~*~out~who' | wc -l | tr -d ' ')"
}

# ---- the pool decides the work; the plan is the address book --------------

t_pool_items_the_plan_does_not_name_are_still_run() {
    # The point of a pool over --batch: the work is not the plan's host
    # list. An item the plan does not name is reached at its own address.
    install_fake_ssh
    install_fake_muster
    pool="$(make_pool a b c d e)"
    plan="$(sweep_plan a b)"          # the plan names only two of the five
    run_tx run --plan "$plan" --muster "$pool" --batch 2 --start-in 1 \
        --no-skew-check -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_eq "5" "$(find results -name 'pool~*~out~who' | wc -l | tr -d ' ')"
    assert_file_exists "results/pool~e~out~who" "an unnamed pool item was dropped"
    assert_eq "pool.csv,5,5,0,0,100.00,0" \
        "$(muster status --pool "$pool" --csv | tail -1)"
}

# ---- checking back in: done if it ran, back if it did not -----------------

t_an_item_that_ran_is_done_and_the_report_agrees() {
    install_fake_ssh
    install_fake_muster
    pool="$(make_pool a b c)"
    plan="$(sweep_plan a b c)"
    run_tx run --plan "$plan" --muster "$pool" --batch 3 --start-in 1 \
        --no-skew-check -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "checking 3 item(s) back in as done"
    assert_eq "3" "$(muster list --pool "$pool" --state "done" | tail -n +2 | wc -l | tr -d ' ')"
}

t_items_nothing_reached_go_back_not_done() {
    # --no-deploy leaves no agent to arm, so no wave can start and nothing
    # runs. Those items must return to the pool for another worker, not be
    # reported done -- a benchmark that never happened is not a pass.
    install_fake_ssh
    install_fake_muster
    pool="$(make_pool a b c)"
    plan="$(sweep_plan a b c)"
    run_tx run --plan "$plan" --muster "$pool" --batch 2 --start-in 1 \
        --no-skew-check --no-deploy -d results --quiet
    assert_status 1 "$RUN_RC" "nothing ran, so it is worth an exit code"
    assert_contains "$RUN_OUT" "putting 3 item(s) back"
    # Back to available, none done, and the attempt is recorded.
    assert_eq "pool.csv,3,0,0,3,0.00,0" \
        "$(muster status --pool "$pool" --csv | tail -1)"
    assert_contains "$(muster list --pool "$pool")" "a,available"
}

t_a_wave_that_cannot_be_cleaned_is_counted() {
    # The clean after a wave used to be fire-and-forget. A host it left as
    # it was is worth an exit code now -- and changes nothing about the
    # check-in: the item ran, so it is done.
    install_fake_ssh
    install_fake_muster
    pool="$(make_pool a b)"
    plan="$(sweep_plan a b)"
    mkdir -p "$FAKE_ROOT/a$TX_REMOTE_DIR"
    echo mine > "$FAKE_ROOT/a$TX_REMOTE_DIR/notes.txt"
    run_tx run --plan "$plan" --muster "$pool" --batch 1 --start-in 1 \
        --no-skew-check -d results --clean --quiet
    assert_status 1 "$RUN_RC" "a wave that could not be cleaned is worth an exit code"
    assert_contains "$RUN_OUT" "REFUSED"
    assert_eq "pool.csv,2,2,0,0,100.00,0" \
        "$(muster status --pool "$pool" --csv | tail -1)"
    assert_no_file "$FAKE_ROOT/b$TX_REMOTE_DIR" "b should be cleaned"
}

# ---- a shared pool: another worker's items are left alone -----------------

t_items_another_worker_holds_are_left_alone() {
    # The whole reason the pool is worth more than a longer --batch: many
    # workers draw from it and never collide. If somebody else holds two
    # of the four, tx runs the other two and does not touch theirs.
    install_fake_ssh
    install_fake_muster
    pool="$(make_pool a b c d)"
    plan="$(sweep_plan a b c d)"
    # Another worker leases a and b under a long lease and never finishes.
    muster take --item a,b --pool "$pool" --as other@box:9 --lease 2h \
        -o "$TEST_TMPDIR/theirs.txt" > /dev/null
    run_tx run --plan "$plan" --muster "$pool" --batch 10 --start-in 1 \
        --no-skew-check -d results --quiet
    assert_status 0 "$RUN_RC"
    # tx ran exactly the two it could take.
    assert_eq "2" "$(find results -name 'pool~*~out~who' | wc -l | tr -d ' ')"
    assert_file_exists "results/pool~c~out~who"
    assert_file_exists "results/pool~d~out~who"
    assert_no_file "results/pool~a~out~who" "tx ran an item another worker held"
    # a and b are still held by the other worker; only c and d are done.
    assert_eq "pool.csv,4,2,2,0,50.00,0" \
        "$(muster status --pool "$pool" --csv | tail -1)"
}

t_an_empty_pool_runs_nothing() {
    install_fake_ssh
    install_fake_muster
    pool="$(make_pool)"               # add nothing
    : > "$pool"                       # a pool with not even a header
    muster add "" --pool "$pool" > /dev/null 2>&1 || true
    plan="$(sweep_plan a b)"
    run_tx run --plan "$plan" --muster "$pool" --batch 2 --start-in 1 \
        --no-skew-check -d results --quiet
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "nothing"
    assert_eq "0" "$(find results -name 'pool~*~out~who' 2>/dev/null | wc -l | tr -d ' ')"
}

t_the_pools_own_status_is_printed_at_the_end() {
    # tx does not paraphrase how much is left -- that is muster's number,
    # and a second opinion from a tool that has only seen what it was
    # handed would be a worse one. So it prints the pool's own page.
    install_fake_ssh
    install_fake_muster
    pool="$(make_pool a b c)"
    plan="$(sweep_plan a b c)"
    run_tx run --plan "$plan" --muster "$pool" --batch 3 --start-in 1 \
        --no-skew-check -d results --quiet
    assert_contains "$RUN_OUT" "PROGRESS"
    assert_contains "$RUN_OUT" "3 of 3 done"
}

# ---- a lease that lapses mid-sweep (TX-009) --------------------------------

t_a_lapsed_lease_does_not_end_the_sweep() {
    # TX-004's adversarial pass, suspect 3. down1 cannot start, so it is
    # held to be put back at the end. Its 1s lease lapses while a runs,
    # and the next take hands it straight back: tx held it rather than run
    # it twice, found nothing fresh in that take, and ended the sweep with
    # b to f still available and never run. A take that hands back only
    # what this sweep has already seen is not an empty pool.
    install_fake_ssh
    install_fake_muster
    host_down down1
    pool="$(make_pool down1 a b c d e f)"
    plan="$(sweep_plan down1 a b c d e f)"
    run_tx run --plan "$plan" --muster "$pool" --batch 1 --lease 1s \
        --start-in 1 --no-skew-check -d results --quiet
    assert_status 1 "$RUN_RC" "down1's wave did not start, which is worth an exit code"
    for h in a b c d e f; do
        assert_file_exists "results/pool~$h~out~who" "$h was left in the pool, never run"
    done
    assert_contains "$RUN_OUT" "came back with a lapsed lease"
    # Every reachable item done, and down1 back in the pile for somebody
    # else: nothing left held.
    assert_eq "pool.csv,7,6,0,1,85.71,0" \
        "$(muster status --pool "$pool" --csv | tail -1)"
    assert_contains "$(muster list --pool "$pool")" "down1,available"
}

t_a_lapsed_item_is_released_once_under_its_own_lease() {
    # The same sweep's check-in. down1 was held twice, under two leases,
    # and was put back twice: "putting 2 item(s) back" for one item, and
    # the release under the first lease drew a CONFLICT naming tx's own
    # second one. It is one item, released once, under the lease it is
    # held by now.
    install_fake_ssh
    install_fake_muster
    host_down down1
    pool="$(make_pool down1 a b c)"
    plan="$(sweep_plan down1 a b c)"
    run_tx run --plan "$plan" --muster "$pool" --batch 1 --lease 1s \
        --start-in 1 --no-skew-check -d results --quiet
    assert_contains "$RUN_OUT" "came back with a lapsed lease"
    assert_contains "$RUN_OUT" "putting 1 item(s) back"
    assert_not_contains "$RUN_OUT" "CONFLICT"
    assert_eq "pool.csv,4,3,0,1,75.00,0" \
        "$(muster status --pool "$pool" --csv | tail -1)"
}

t_an_item_still_running_stays_left_to_its_lease() {
    # A wave that stops waiting with a host still working leaves its item
    # to its lease: putting it back would hand a running host to the next
    # worker. When that lease lapses and the pool hands the item back, tx
    # holds it under the new lease and leaves it to that one the same
    # way, rather than putting it back at the end with what never ran.
    install_fake_ssh
    install_fake_muster
    pool="$(make_pool slow a b)"
    plan="$(plan_for --run '[ "$TX_HOST" = slow ] && sleep 8; echo "$TX_HOST" > "$TX_OUT/who"' \
            --tag pool --timeout 30 -- slow a b)"
    # The wait is cut to 4s, so slow is still working when it runs out.
    RUN_OUT="$(python3 - "$(dirname "$TX")" run --plan "$plan" \
        --muster "$pool" --batch 1 --lease 1s --start-in 1 \
        --no-skew-check -d results --quiet 2>&1 <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import tx
tx._wait_deadline = lambda args, plan: time.time() + 4
sys.exit(tx.main(sys.argv[2:]))
PY
)"
    RUN_RC=$?
    assert_status 1 "$RUN_RC" "a wave whose wait ran out is worth an exit code"
    assert_contains "$RUN_OUT" "leaving 1 item(s) still running to their lease"
    assert_contains "$RUN_OUT" "came back with a lapsed lease"
    assert_file_exists "results/pool~a~out~who" "a was never run"
    assert_file_exists "results/pool~b~out~who" "b was never run"
    assert_not_contains "$RUN_OUT" "putting" \
        "an item still running was put back for the next worker"
}

t_a_pool_item_taken_by_name_can_start_with_a_dash() {
    # After a take that hands back only lapsed items, the next is taken by
    # name. An item that starts with '-' is never run, but it is still
    # taken, and as a separate argument muster read it as an option and
    # stopped the sweep. It is taken as --item=NAME, refused and put back.
    install_fake_ssh
    install_fake_muster
    host_down down1
    printf '%s\n' 'item,state,holder,lease_id,taken_ts,expires_ts,done_ts,attempts,note' \
        'down1,available,,,,,,0,' 'a,available,,,,,,0,' \
        '-oProxyCommand=true,available,,,,,,0,' 'b,available,,,,,,0,' \
        > "$TEST_TMPDIR/pool.csv"
    plan="$(sweep_plan down1 a b)"
    run_tx run --plan "$plan" --muster "$TEST_TMPDIR/pool.csv" --batch 1 \
        --lease 1s --start-in 1 --no-skew-check -d results --quiet
    assert_status 1 "$RUN_RC"
    assert_not_contains "$RUN_OUT" "could not be read or written"
    assert_contains "$RUN_OUT" "not running pool item '-oProxyCommand=true'"
    assert_file_exists "results/pool~b~out~who" "b was never run"
    pool="$(muster list --pool "$TEST_TMPDIR/pool.csv")"
    assert_contains "$pool" "a,done"
    assert_contains "$pool" "b,done"
}

# ---- the flag's own guardrails --------------------------------------------

t_muster_needs_a_batch_size() {
    install_fake_muster
    run_tx run --muster pool.csv --start-in 1
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "needs --batch"
}

t_muster_and_resume_do_not_go_together() {
    run_tx run --muster pool.csv --batch 3 --resume
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "do not go together"
}

t_a_lease_without_a_pool_is_refused() {
    run_tx run --lease 2h
    assert_status 2 "$RUN_RC"
    assert_contains "$RUN_OUT" "without --muster"
}

echo "muster"
run_test "every pool item is run and done"     t_every_pool_item_is_run_and_checked_in_done
run_test "a pool bigger than the batch"        t_a_pool_bigger_than_the_batch_takes_several_waves
run_test "a batch bigger than the pool"        t_a_batch_bigger_than_the_pool_is_one_wave
run_test "the pool decides the work"           t_pool_items_the_plan_does_not_name_are_still_run
run_test "an item that ran is done"            t_an_item_that_ran_is_done_and_the_report_agrees
run_test "items nothing reached go back"       t_items_nothing_reached_go_back_not_done
run_test "an uncleaned wave is counted"        t_a_wave_that_cannot_be_cleaned_is_counted
run_test "another worker's items are left"     t_items_another_worker_holds_are_left_alone
run_test "an empty pool runs nothing"          t_an_empty_pool_runs_nothing
run_test "the pool's own status is printed"    t_the_pools_own_status_is_printed_at_the_end
run_test "a lapsed lease does not end it"      t_a_lapsed_lease_does_not_end_the_sweep
run_test "a lapsed item is released once"      t_a_lapsed_item_is_released_once_under_its_own_lease
run_test "a running item stays left"           t_an_item_still_running_stays_left_to_its_lease
run_test "an item by name can start with -"    t_a_pool_item_taken_by_name_can_start_with_a_dash
run_test "muster needs a batch size"           t_muster_needs_a_batch_size
run_test "muster and resume are exclusive"     t_muster_and_resume_do_not_go_together
run_test "a lease without a pool is refused"   t_a_lease_without_a_pool_is_refused
report_tests
