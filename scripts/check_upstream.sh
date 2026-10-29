#!/usr/bin/env bash
# Report upstream PixelOS commits that the pixelos-redfin forks don't have
# yet, and flag keybox/attestation changes that must not be merged.
# Sends the result to the Telegram bot owner. Read-only: uses the GitHub
# API, never touches the tree.
#
# Usage: check_upstream.sh [--quiet]   (--quiet: no message when all forks are current)

set -uo pipefail

ORG=pixelos-redfin
BRANCH=seventeen
FORKS=(android_frameworks_base android_vendor_custom android_packages_apps_Updater android_packages_apps_Settings)
# Commits matching this are reported as "do not merge" (no keybox/attestation spoofing).
BLOCK='[Kk]eybox|[Aa]ttest|KeyMint|leaf[- ]hack|spoofSignature|TrickyStore'

quiet=0
[ "${1:-}" = --quiet ] && quiet=1

report=""
behind_total=0
errors=0

for repo in "${FORKS[@]}"; do
    parent=$(gh api "repos/$ORG/$repo" --jq '.parent.full_name' 2>/dev/null)
    if [ -z "$parent" ]; then
        report+="⚠️ $repo: can't read the fork parent"$'\n'
        errors=$((errors + 1))
        continue
    fi
    cmp=$(gh api "repos/$ORG/$repo/compare/$BRANCH...${parent%%/*}:$BRANCH" 2>/dev/null)
    if [ -z "$cmp" ]; then
        report+="⚠️ $repo: compare with $parent failed"$'\n'
        errors=$((errors + 1))
        continue
    fi
    behind=$(jq -r '.ahead_by' <<<"$cmp")
    [ "$behind" -eq 0 ] && continue
    behind_total=$((behind_total + behind))
    report+=$'\n'"📦 $repo: $behind new commit(s) in $parent"$'\n'
    while IFS=$'\t' read -r sha subject; do
        mark="•"
        grep -qE "$BLOCK" <<<"$subject" && mark="⛔ DO NOT MERGE:"
        report+="  $mark ${sha:0:10} $subject"$'\n'
    done < <(jq -r '.commits[] | [.sha, (.commit.message | split("\n")[0])] | @tsv' <<<"$cmp" | tail -20)
    [ "$behind" -gt 20 ] && report+="  … only the last 20 shown"$'\n'
done

if [ "$behind_total" -eq 0 ] && [ "$errors" -eq 0 ]; then
    msg="✅ Upstream check: all forks (${#FORKS[@]}) include upstream PixelOS $BRANCH."
    echo "$msg"
    [ "$quiet" -eq 1 ] && exit 0
else
    msg="🔄 Upstream check: $behind_total upstream commit(s) to merge"$'\n'"$report"
    grep -q '⛔' <<<"$report" && msg+=$'\n'"⛔ commits are keybox/attestation changes: revert them after merging."
    msg+=$'\n'"Merge in the project: git fetch https://github.com/<parent> $BRANCH && git merge FETCH_HEAD, then push to the $ORG fork."
    echo "$msg"
fi

[ -n "${NO_NOTIFY:-}" ] && exit 0
"$(dirname "$(readlink -f "$0")")/tg_notify.py" "$msg"
