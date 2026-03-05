#!/usr/bin/env bash
#
# verify-agave-sync.sh — Verify SVM repo is correctly synced with Agave
#
# Performs two independent verifications:
#
#   1. TREE COMPARISON: For each SVM-owned crate path that also exists in
#      Agave, compare git tree hashes (and file-level content for mismatches)
#      between Agave at the pinned rev and SVM at HEAD. This verifies the
#      end-state is correct.
#
#   2. COMMIT AUDIT: List all Agave commits between old-pin and new-pin that
#      touch SVM-owned paths, cross-reference with cherry-picks in the SVM
#      branch by PR number, and report any missing or unmatched commits.
#
# Usage:
#   verify-agave-sync.sh [OPTIONS]
#
# Options:
#   --agave-repo PATH   Path to local Agave checkout (default: ~/work/agave)
#   --base-ref REF      SVM ref for determining old Agave pin
#                        (default: merge-base of HEAD and master)
#   --head-ref REF      SVM ref to verify (default: HEAD)
#   --tree-only         Only run tree comparison
#   --commits-only      Only run commit audit
#   --diff              Show unified diffs for mismatched files
#   --help              Show this help
#
# Exit codes:
#   0  Everything matches
#   1  Divergences found (review output)
#   2  Usage / configuration error

set -euo pipefail

# Defaults.
# AGAVE_REPO: path to a local Agave checkout, needed for tree and commit lookups.
# BASE_REF: the SVM "before" ref — resolved later to merge-base with master
#   if not provided. Used to extract the old Agave pin for the commit audit.
# HEAD_REF: the SVM "after" ref — what we're verifying. Defaults to HEAD.
# MODE: which verification parts to run (both | tree | commits).
# SHOW_DIFF: when true, print unified diffs for mismatched files.
AGAVE_REPO="${AGAVE_REPO:-$HOME/work/agave}"
BASE_REF=""
HEAD_REF="HEAD"
MODE="both"
SHOW_DIFF=false

# Every crate directory in the SVM repo, in display order. Each is verified
# against its Agave counterpart (same path, or overridden in AGAVE_PATH below).
SVM_PATHS=(
    callback
    compute-budget
    feature-set
    log-collector
    measure
    program-binaries
    program-runtime
    programs/bpf_loader
    programs/compute-budget
    programs/loader-v4
    programs/sbf
    programs/system
    svm
    svm-test-harness
    timings
    transaction
    transaction-context
    type-overrides
)

# Some crates live under different directory names in Agave (typically prefixed
# with svm-). This map translates SVM path -> Agave path for those cases.
# Crates not listed here have the same path in both repos.
declare -A AGAVE_PATH=(
    [callback]=svm-callback
    [feature-set]=svm-feature-set
    [log-collector]=svm-log-collector
    [measure]=svm-measure
    [timings]=svm-timings
    [transaction]=svm-transaction
    [type-overrides]=svm-type-overrides
)

# Look up the Agave-side path for a given SVM path. Returns the override if
# one exists, otherwise returns the input unchanged.
agave_path_for() { echo "${AGAVE_PATH[$1]:-$1}"; }

red()    { printf '\033[1;31m%s\033[0m' "$*"; }
green()  { printf '\033[1;32m%s\033[0m' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m' "$*"; }
dim()    { printf '\033[2m%s\033[0m' "$*"; }
bold()   { printf '\033[1m%s\033[0m' "$*"; }

die() { echo "ERROR: $*" >&2; exit 2; }

usage() {
    sed -n '/^# Usage:/,/^[^#]/{/^[^#]/q; s/^# \?//p;}' "$0"
    exit 0
}

# Extract the Agave rev pin from Cargo.toml at a given git ref. The workspace
# Cargo.toml has git dependencies like:
#   agave-foo = { git = "...", rev = "abc123" }
# This grabs the first `rev = "..."` value, which is the Agave commit SHA that
# the SVM workspace is pinned to.
get_agave_pin() {
    git show "$1:Cargo.toml" 2>/dev/null \
        | grep -m1 'rev = "' \
        | sed 's/.*rev = "\([^"]*\)".*/\1/'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agave-repo)   AGAVE_REPO="$2"; shift 2 ;;
        --base-ref)     BASE_REF="$2";   shift 2 ;;
        --head-ref)     HEAD_REF="$2";   shift 2 ;;
        --tree-only)    MODE="tree";     shift ;;
        --commits-only) MODE="commits";  shift ;;
        --diff)         SHOW_DIFF=true;  shift ;;
        --help|-h)      usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -d "$AGAVE_REPO/.git" ]] || die "Agave repo not found at $AGAVE_REPO"
git rev-parse --git-dir >/dev/null 2>&1 || die "Not inside an SVM git repository"

# Resolve base ref. If not provided, find where the current branch forked from
# master (or main). This is the "before" state of the sync — the commit whose
# Cargo.toml contains the old Agave pin. On a sync PR branch, this is the
# merge-base with master; on master itself, this would be HEAD (meaning old pin
# == new pin and the commit audit range is empty).
if [[ -z "$BASE_REF" ]]; then
    BASE_REF=$(git merge-base "$HEAD_REF" master 2>/dev/null) \
        || BASE_REF=$(git merge-base "$HEAD_REF" main 2>/dev/null) \
        || die "Could not determine merge-base. Use --base-ref."
fi

# Extract the Agave pins from both refs. NEW_PIN is what we're verifying
# against (tree comparison uses this). OLD_PIN is needed for the commit audit
# to know which Agave commits fall in the sync range.
NEW_PIN=$(get_agave_pin "$HEAD_REF")
OLD_PIN=$(get_agave_pin "$BASE_REF")

[[ -n "$NEW_PIN" ]] || die "Could not extract Agave rev pin from Cargo.toml at $HEAD_REF"
[[ -n "$OLD_PIN" ]] || die "Could not extract Agave rev pin from Cargo.toml at $BASE_REF"

# Make sure the local Agave checkout actually has both pin commits. If not,
# the user needs to fetch.
git -C "$AGAVE_REPO" cat-file -t "$NEW_PIN" >/dev/null 2>&1 \
    || die "Agave repo does not contain new pin commit $NEW_PIN — try: git -C $AGAVE_REPO fetch"
git -C "$AGAVE_REPO" cat-file -t "$OLD_PIN" >/dev/null 2>&1 \
    || die "Agave repo does not contain old pin commit $OLD_PIN — try: git -C $AGAVE_REPO fetch"

# Print what we resolved so the user knows exactly what's being compared.
echo "$(bold 'SVM <-> Agave Sync Verification')"
echo ""
echo "  SVM base ref:   $(echo "$BASE_REF" | head -c 12)"
echo "  SVM head ref:   $HEAD_REF"
echo "  Old Agave pin:  $OLD_PIN"
echo "  New Agave pin:  $NEW_PIN"
echo "  Agave repo:     $AGAVE_REPO"
echo ""

EXIT_CODE=0

# PART 1: TREE COMPARISON
#
# For each crate in SVM_PATHS, compare the git tree object hash between
# Agave@NEW_PIN and SVM@HEAD_REF. If the tree SHA matches, the directory is
# byte-for-byte identical — zero ambiguity. For mismatches, drill down to
# individual files and optionally show unified diffs.
#
# This is a direct end-state check. It does NOT depend on prior sync being
# correct — it only asks "does SVM match Agave right now?"
verify_tree() {
    echo "$(bold '=== Part 1: Tree Comparison ===')"
    echo ""
    echo "Comparing SVM-owned crate directories between:"
    echo "  Agave @ $NEW_PIN"
    echo "  SVM   @ $HEAD_REF"
    echo ""

    local match_count=0
    local mismatch_count=0
    local mismatch_svm_paths=()
    local mismatch_agave_paths=()

    for svm_path in "${SVM_PATHS[@]}"; do
        local agave_p
        agave_p=$(agave_path_for "$svm_path")

        local agave_hash svm_hash
        agave_hash=$(git -C "$AGAVE_REPO" rev-parse "$NEW_PIN:$agave_p" 2>/dev/null || echo "MISSING")
        svm_hash=$(git rev-parse "$HEAD_REF:$svm_path" 2>/dev/null || echo "MISSING")

        local label="$svm_path"
        [[ "$agave_p" != "$svm_path" ]] && label="$svm_path (agave: $agave_p)"

        if [[ "$agave_hash" == "$svm_hash" ]]; then
            printf "  %s %-35s %s\n" "$(green 'OK')" "$label/" "${agave_hash:0:12}"
            match_count=$((match_count + 1))
        else
            printf "  %s %-35s %s\n" "$(red '!!')" "$label/" "agave=${agave_hash:0:12} svm=${svm_hash:0:12}"
            mismatch_count=$((mismatch_count + 1))
            mismatch_svm_paths+=("$svm_path")
            mismatch_agave_paths+=("$agave_p")
        fi
    done

    local checked=$((match_count + mismatch_count))
    echo ""
    echo "  Matched: $match_count / $checked checked"
    if [[ $mismatch_count -gt 0 ]]; then
        echo "  $(red "Mismatched: $mismatch_count")"
    fi

    # Drill into mismatches: for each mismatched crate, list files relative to
    # the crate root and classify as agave-only, svm-only, or modified.
    if [[ ${#mismatch_svm_paths[@]} -gt 0 ]]; then
        echo ""
        echo "$(bold '--- File-level breakdown of mismatches ---')"

        for i in "${!mismatch_svm_paths[@]}"; do
            local svm_path="${mismatch_svm_paths[$i]}"
            local agave_p="${mismatch_agave_paths[$i]}"

            echo ""
            if [[ "$agave_p" != "$svm_path" ]]; then
                echo "  $(bold "$svm_path/") (agave: $agave_p/)"
            else
                echo "  $(bold "$svm_path/")"
            fi

            # List files relative to crate root (strip the crate prefix) so we
            # can compare across repos even when directory names differ.
            local agave_files svm_files
            agave_files=$(git -C "$AGAVE_REPO" ls-tree -r --name-only "$NEW_PIN" -- "$agave_p/" 2>/dev/null \
                | sed "s|^$agave_p/||" | sort)
            svm_files=$(git ls-tree -r --name-only "$HEAD_REF" -- "$svm_path/" 2>/dev/null \
                | sed "s|^$svm_path/||" | sort)

            # Files only in Agave
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                printf "    %s  %s\n" "$(red '+agave')" "$f"
            done < <(comm -23 <(echo "$agave_files") <(echo "$svm_files"))

            # Files only in SVM
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                printf "    %s    %s\n" "$(yellow '+svm')" "$f"
            done < <(comm -13 <(echo "$agave_files") <(echo "$svm_files"))

            # Shared files with content differences
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                local agave_blob svm_blob
                agave_blob=$(git -C "$AGAVE_REPO" rev-parse "$NEW_PIN:$agave_p/$f" 2>/dev/null || echo "")
                svm_blob=$(git rev-parse "$HEAD_REF:$svm_path/$f" 2>/dev/null || echo "")
                if [[ "$agave_blob" != "$svm_blob" ]]; then
                    printf "    %s %s\n" "$(yellow '~mod')" "$f"

                    if $SHOW_DIFF; then
                        diff --unified=3 \
                            --label "agave:$agave_p/$f" \
                            --label "svm:$svm_path/$f" \
                            <(git -C "$AGAVE_REPO" show "$NEW_PIN:$agave_p/$f" 2>/dev/null) \
                            <(git show "$HEAD_REF:$svm_path/$f" 2>/dev/null) \
                            | sed 's/^/        /' || true
                        echo ""
                    fi
                fi
            done < <(comm -12 <(echo "$agave_files") <(echo "$svm_files"))
        done

        EXIT_CODE=1
    fi
}

# PART 2: COMMIT AUDIT
#
# Lists all Agave commits in OLD_PIN..NEW_PIN that touch SVM-owned paths (using
# agave-side directory names), then classifies each:
#
#   OK  — Cherry-picked into SVM (PR number found in SVM branch commits)
#   --  — Dep bump, cargo-only, or non-source change (safe to skip)
#   ~~  — Large Agave commit that incidentally touches SVM paths (<1/3 of files)
#   ??  — Primarily SVM code, NOT cherry-picked — needs investigation
#   M   — SVM-only maintenance commit (not from Agave)
#
# NOTE: This assumes the old pin was properly synced. If prior sync was
# incomplete, commits before OLD_PIN could also be missing. Use the tree
# comparison (Part 1) as the authoritative end-state check.
verify_commits() {
    echo ""
    echo "$(bold '=== Part 2: Commit Audit ===')"
    echo ""
    echo "Agave commit range: $OLD_PIN..$NEW_PIN"
    echo "SVM commit range:   $(echo "$BASE_REF" | head -c 12)..$HEAD_REF"
    echo ""

    # Collect PR numbers from the SVM branch's commit messages. These are the
    # cherry-picks we expect to find in the Agave range.
    local svm_prs
    svm_prs=$(git log --format="%s" "$BASE_REF..$HEAD_REF" \
        | grep -oP '#\d+' | sort -u -t'#' -k1 -V)

    # Build Agave path args for git log (using agave-side paths).
    local path_args=""
    for p in "${SVM_PATHS[@]}"; do
        path_args="$path_args $(agave_path_for "$p")/"
    done

    local cherry_count=0
    local skip_dep_count=0
    local skip_other_count=0
    local missing_count=0
    local cherry_picked_prs=""

    echo "  $(bold 'Legend:')"
    echo "    [cherry-picked]  [dep-bump/cargo-only]  [?missing]  [non-SVM]"
    echo ""

    # Read all agave commits into an array to avoid subshell variable scoping.
    local -a agave_lines=()
    while IFS= read -r line; do
        agave_lines+=("$line")
    done < <(git -C "$AGAVE_REPO" log --format="%H %s" "$OLD_PIN..$NEW_PIN" -- $path_args)

    for line in "${agave_lines[@]}"; do
        [[ -n "$line" ]] || continue
        local sha="${line%% *}"
        local subject="${line#* }"
        local pr
        pr=$(echo "$subject" | grep -oP '#\d+' | head -1 || echo "")

        if [[ -n "$pr" ]] && echo "$svm_prs" | grep -q "^${pr}$"; then
            # PR number matches a cherry-pick in the SVM branch.
            printf "    %s  %s\n" "$(green 'OK')" "$subject"
            cherry_picked_prs="$cherry_picked_prs $pr"
            cherry_count=$((cherry_count + 1))
        elif echo "$subject" | grep -qP '^build\(deps\):|^chore\(deps\):'; then
            # Dependency bump — handled by workspace Cargo.toml, safe to skip.
            printf "    %s  %s\n" "$(dim '--')" "$subject"
            skip_dep_count=$((skip_dep_count + 1))
        else
            # Check if the commit only touches Cargo.toml/lock in SVM paths
            # (no source changes) — these are cargo-only, safe to skip.
            local touched_src
            touched_src=$(git -C "$AGAVE_REPO" diff-tree --no-commit-id --name-only -r "$sha" -- $path_args \
                | grep -v 'Cargo\.\(toml\|lock\)$' | head -1 || echo "")

            if [[ -z "$touched_src" ]]; then
                printf "    %s  %s\n" "$(dim '--')" "$subject"
                skip_dep_count=$((skip_dep_count + 1))
            else
                # Ratio check: if >3x more files outside SVM paths than inside,
                # this is a large Agave commit that incidentally touches SVM.
                local total_files_in_commit svm_files_in_commit
                total_files_in_commit=$(git -C "$AGAVE_REPO" diff-tree --no-commit-id --name-only -r "$sha" | wc -l)
                svm_files_in_commit=$(git -C "$AGAVE_REPO" diff-tree --no-commit-id --name-only -r "$sha" -- $path_args | wc -l)

                if [[ $total_files_in_commit -gt $((svm_files_in_commit * 3)) ]]; then
                    printf "    %s  %s  (%d SVM files / %d total)\n" \
                        "$(dim '~~')" "$subject" "$svm_files_in_commit" "$total_files_in_commit"
                    skip_other_count=$((skip_other_count + 1))
                else
                    # Primarily touches SVM code but not cherry-picked — flag it.
                    printf "    %s  %s\n" "$(red '??')" "$subject"

                    if $SHOW_DIFF; then
                        echo "        Files in SVM paths:"
                        git -C "$AGAVE_REPO" diff-tree --no-commit-id --name-only -r "$sha" -- $path_args \
                            | sed 's/^/          /'
                        echo ""
                    fi

                    missing_count=$((missing_count + 1))
                fi
            fi
        fi
    done

    echo ""
    echo "  $(bold 'Summary:')"
    printf "    Cherry-picked:         %d\n" "$cherry_count"
    printf "    Skipped (dep/cargo):   %d\n" "$skip_dep_count"
    printf "    Skipped (non-SVM):     %d\n" "$skip_other_count"
    if [[ $missing_count -gt 0 ]]; then
        printf "    $(red 'Unaccounted:           %d')\n" "$missing_count"
        EXIT_CODE=1
    else
        printf "    Unaccounted:           %d\n" "$missing_count"
    fi

    # Show SVM-only commits that don't correspond to any Agave cherry-pick.
    echo ""
    echo "  $(bold 'SVM-only maintenance commits:')"
    local has_maintenance=false
    local -a svm_lines=()
    while IFS= read -r line; do
        svm_lines+=("$line")
    done < <(git log --format="%H %s" "$BASE_REF..$HEAD_REF")

    for line in "${svm_lines[@]}"; do
        [[ -n "$line" ]] || continue
        local subject="${line#* }"

        local commit_prs
        commit_prs=$(echo "$subject" | grep -oP '#\d+' || echo "")

        local is_cherry=false
        for cpr in $commit_prs; do
            if echo "$cherry_picked_prs" | grep -qw "$cpr"; then
                is_cherry=true
                break
            fi
        done

        if ! $is_cherry; then
            printf "    %s  %s\n" "M " "$subject"
            has_maintenance=true
        fi
    done

    if ! $has_maintenance; then
        echo "    (none)"
    fi
}

case "$MODE" in
    tree)    verify_tree ;;
    commits) verify_commits ;;
    both)    verify_tree; verify_commits ;;
esac

echo ""
echo "$(bold '=== Result ===')"
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "$(green 'PASS') — SVM is in sync with Agave at $NEW_PIN"
else
    echo "$(yellow 'DIVERGENCES FOUND') — review output above"
    echo ""
    echo "Use --diff for file-level unified diffs."
fi

exit $EXIT_CODE
