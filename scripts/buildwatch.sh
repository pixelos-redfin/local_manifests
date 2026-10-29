#!/usr/bin/env bash
# Show the progress of an Android build from its log (output of `m ... > log 2>&1`).
#
#   buildwatch.sh [LOG]            live progress bar, redrawn every 2s (Ctrl-C to quit)
#   buildwatch.sh --events [LOG]   one line per 10% step, per error and at the end (for logs/monitors)
#   buildwatch.sh --once [LOG]     print the current state once
#   buildwatch.sh --status         one short line for the Claude Code status line:
#                                  the running build, or the result for 10 min after it ends
#
# Without LOG, the newest of ~/telegram_bot/logs/*.log and ~/logs/build-*.log is used.
# Soong's own "remaining" estimate is often nonsense, so the ETA here comes
# from the measured rate.

set -uo pipefail

mode=follow
case "${1:-}" in
    --events) mode=events; shift ;;
    --once) mode=once; shift ;;
    --status) mode=status; shift ;;
esac

log="${1:-}"
if [ -z "$log" ]; then
    log=$(ls -t ~/telegram_bot/logs/*.log ~/logs/build-*.log 2>/dev/null | head -1)
fi
if [ -z "$log" ] || [ ! -f "$log" ]; then
    [ "$mode" = status ] && exit 0
    echo "buildwatch: no build log found" >&2
    exit 1
fi

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
        *successfully*) echo "ok $(grep -oE '[0-9]+(:[0-9]+)+' <<<"$end" | head -1)" ;;
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
status)
    # Called every few seconds: keep it cheap and quiet. The ETA needs a rate,
    # so remember when each phase was first seen.
    now=$(date +%s)
    age=$((now - $(stat -c %Y "$log")))
    f=$(finished)
    name=$(basename "$log" .log)
    if [ -n "$f" ]; then
        [ "$age" -gt 600 ] && exit 0
        case $f in
            ok*) printf '\033[32m✅ %s built (%s)\033[0m\n' "$name" "${f#ok }" ;;
            *) printf '\033[31m❌ %s failed: %s\033[0m\n' "$name" "$(errors 1 | cut -c1-80)" ;;
        esac
        exit 0
    fi
    [ "$age" -gt 300 ] && exit 0   # stale log, build no longer running
    p=$(progress)
    if [ -z "$p" ]; then
        printf '🔨 %s: starting\n' "$name"
        exit 0
    fi
    read -r pct done total target <<<"$p"
    state=${XDG_CACHE_HOME:-$HOME/.cache}/buildwatch.state
    read -r s_log s_total s_t s_done 2>/dev/null < "$state" || true
    if [ "${s_log:-}" != "$log" ] || [ "${s_total:-}" != "$total" ]; then
        s_t=$now s_done=$done
        mkdir -p "$(dirname "$state")"
        echo "$log $total $s_t $s_done" > "$state"
    fi
    eta=""
    if [ $((now - s_t)) -ge 20 ] && [ "$done" -gt "$s_done" ]; then
        eta=" ETA $(fmt_time $(( (total - done) * (now - s_t) / (done - s_done) )))"
    fi
    err=$(errors 1)
    [ -n "$err" ] && err=$' \033[31m⚠ errors\033[0m'
    printf '🔨 %s [\033[36m%s\033[0m] %d%% %d/%d%s%s  %s\n' "$name" "$(bar "$pct")" "$pct" "$done" "$total" \
        "$eta" "$err" "${target:0:50}"
    ;;
once)
    f=$(finished)
    [ -n "$f" ] && echo "build $f" || line
    errors 3
    ;;
events)
    last_step=-1 last_total="" seen_err=""
    while true; do
        f=$(finished)
        p=$(progress)
        if [ -n "$p" ]; then
            read -r pct _ total _ <<<"$p"
            # soong bootstrap, kati and ninja each count their own steps
            if [ "$total" != "$last_total" ]; then
                last_total=$total
                last_step=-1
                start_t=$(date +%s)
                start_done=""
            fi
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
