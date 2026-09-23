#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher

#
# One version, in three places. `pyproject.toml` is what PyPI publishes;
# `testing_orchestrator/__init__.py` is what `import testing_orchestrator` reports;
# and `tx.py`'s own `VERSION` is the one that actually travels -- the agent is
# scp'd to every host and run there, and it stamps that number into each run
# record as `agent_version`. A release that bumps one and forgets another
# ships a fleet that disagrees with itself about what it is running, so the
# publish workflow refuses a tag that does not match, and this refuses a
# commit that does not agree with itself before it ever gets tagged.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.bash"

# The version pyproject.toml will publish under.
pyproject_version() {
    sed -n 's/^version = "\(.*\)"$/\1/p' "$REPO_ROOT/pyproject.toml" | head -n 1
}

# A module's VERSION = "..." line, read without importing (the 3.6 floor
# means we cannot rely on this interpreter being able to import the agent).
module_version() {
    sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$REPO_ROOT/testing_orchestrator/$1" \
        | head -n 1
}

t_all_three_versions_agree() {
    local pyproj init tx
    pyproj="$(pyproject_version)"
    init="$(module_version __init__.py)"
    tx="$(module_version tx.py)"
    # Each is present at all -- a missing one would read as an empty string
    # and quietly match another empty string.
    [ -n "$pyproj" ] || fail "no version in pyproject.toml"
    [ -n "$init" ] || fail "no VERSION in __init__.py"
    [ -n "$tx" ] || fail "no VERSION in tx.py"
    assert_eq "$pyproj" "$init" "pyproject.toml vs __init__.py"
    assert_eq "$pyproj" "$tx" "pyproject.toml vs tx.py (the agent's version)"
}

t_the_reported_version_is_that_version() {
    # `tx --version` is what a user and `agree`-style tooling read; it must be
    # the same string, not merely a parallel constant that happens to match.
    run_tx --version
    assert_status 0 "$RUN_RC"
    assert_contains "$RUN_OUT" "testing-orchestrator $(pyproject_version)"
}

echo "version"
run_test "all three versions agree"            t_all_three_versions_agree
run_test "the reported version is that one"    t_the_reported_version_is_that_version
report_tests
