#!/usr/bin/env bash
# Show the progress of an Android build from its log (output of `m ... > log 2>&1`).
#
#   buildwatch.sh [LOG]            live progress bar, redrawn every 2s (Ctrl-C to quit)
#   buildwatch.sh --events [LOG]   one line per 10% step, per error and at the end (for logs/monitors)
#   buildwatch.sh --once [LOG]     print the current state once
#
# Without LOG, the newest *.log in ~/telegram_bot/logs and ~/logs is used.
# Soong's own "remaining" estimate is often nonsense, so the ETA here comes
# from the measured rate.

set -uo pipefail

mode=follow
case "${1:-}" in
    --events) mode=events; shift ;;
    --once) mode=once; shift ;;
esac

log="${1:-}"
if [ -z "$log" ]; then
    log=$(ls -t ~/telegram_bot/logs/*.log ~/logs/*.log 2>/dev/null | head -1)
fi
[ -n "$log" ] && [ -f "$log" ] || { echo "buildwatch: no build log found" >&2; exit 1; }

# Prints: percent done total target
progress() {
    tail -c 200000 "$log" | tr '\r' '\n' | grep -aoE '^\[ *[0-9]+% [0-9]+/[0-9]+[^]]*\] .*' | tail -1 |
        sed -nE 's/^\[ *([0-9]+)% ([0-9]+)\/([0-9]+)[^]]*\] (.*)$/\1 \2 \3 \4/p'
}

# Prints "ok <time>", "failed" or nothing while running
finished() {
    local end
    end=$(tail -c 4000 "$log" | grep -aE '#### (build completed successfully|failed to build some targets)' | tail -1)
    case "$end" in
        *successfully*) echo "ok $(sed -nE 's/.*\(([^)]*)\).*/\1/p' <<<"$end")" ;;
        *failed*) echo failed ;;
    esac
}

errors() {
    grep -aE '^FAILED: |error: |^ninja: error|Killed|OutOfMemoryError' "$log" | tail -"${1:-3}"
    return 0
}

bar() {
    local pct=$1 width=30 fill
    fill=$((pct * width / 100))
    printf '%s%s' "$(printf '%*s' "$fill" '' | tr ' ' '#')" "$(printf '%*s' $((width - fill)) '' | tr ' ' '.')"
}

fmt_time() {
    local s=$1
    if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
    else printf '%dm%02ds' $((s / 60)) $((s % 60)); fi
}

start_t=$(date +%s)
start_done=""

line() {
    local p pct done total target eta="" rate now
    p=$(progress)
    [ -z "$p" ] && { echo "starting (soong/kati) $(basename "$log")"; return; }
    read -r pct done total target <<<"$p"
    now=$(date +%s)
    [ -z "$start_done" ] && start_done=$done
    if [ $((now - start_t)) -ge 20 ] && [ "$done" -gt "$start_done" ]; then
        rate=$(( (done - start_done) * 1000 / (now - start_t) ))
        [ "$rate" -gt 0 ] && eta=" ETA $(fmt_time $(( (total - done) * 1000 / rate )))"
    fi
    printf '[%s] %3d%% %d/%d%s  %s\n' "$(bar "$pct")" "$pct" "$done" "$total" "$eta" "${target:0:70}"
}

case $mode in
once)
    f=$(finished)
    [ -n "$f" ] && echo "build $f" || line
    errors 3
    ;;
events)
    last_step=-1 seen_err=""
    while true; do
        f=$(finished)
        p=$(progress)
        if [ -n "$p" ]; then
            read -r pct _ <<<"$p"
            step=$((pct / 10 * 10))
            if [ "$step" -gt "$last_step" ]; then
                last_step=$step
                line
            fi
        fi
        err=$(errors 1)
        if [ -n "$err" ] && [ "$err" != "$seen_err" ]; then
            seen_err=$err
            echo "ERROR: ${err:0:200}"
        fi
        if [ -n "$f" ]; then
            case $f in
                ok*) echo "✅ build completed successfully (${f#ok })" ;;
                *) echo "❌ build failed"; errors 5 ;;
            esac
            exit 0
        fi
        sleep 5
    done
    ;;
follow)
    trap 'tput cnorm 2>/dev/null; echo; exit 0' INT TERM
    tput civis 2>/dev/null
    while true; do
        f=$(finished)
        out=$(line)
        printf '\r\033[K%s' "$out"
        if [ -n "$f" ]; then
            echo
            case $f in
                ok*) echo "✅ build completed successfully (${f#ok })" ;;
                *) echo "❌ build failed"; errors 5 ;;
            esac
            tput cnorm 2>/dev/null
            exit 0
        fi
        sleep 2
    done
    ;;
esac
