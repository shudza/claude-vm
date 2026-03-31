#!/usr/bin/env bash
# boot-timer.sh — Boot performance measurement and validation
#
# Measures and validates that subsequent VM launches meet the
# 20-second performance target. Logs timing data for diagnostics.

set -euo pipefail

# Performance threshold in seconds
BOOT_TARGET_SECONDS=20

# Timing log file
TIMING_LOG="${CLAUDE_VM_DIR:-${HOME}/.claude-vm}/timing.log"

# Record a boot timing event
# Args:
#   $1 = project hash/name
#   $2 = boot type ("resume" or "coldboot")
#   $3 = elapsed milliseconds
#   $4 = result ("ok" or "slow")
log_boot_timing() {
    local project="$1"
    local boot_type="$2"
    local elapsed_ms="$3"
    local result="$4"

    local log_dir
    log_dir=$(dirname "$TIMING_LOG")
    mkdir -p "$log_dir"

    local timestamp
    timestamp=$(date -Iseconds)

    echo "${timestamp} ${project} ${boot_type} ${elapsed_ms}ms ${result}" >> "$TIMING_LOG"
}

# Check if elapsed time meets the 20-second target
# Args: $1 = elapsed milliseconds
# Returns: 0 if within target, 1 if exceeded
check_boot_target() {
    local elapsed_ms="$1"
    local target_ms=$((BOOT_TARGET_SECONDS * 1000))

    if [[ $elapsed_ms -le $target_ms ]]; then
        return 0
    else
        return 1
    fi
}

# Get average resume time for a project from the timing log
# Args: $1 = project hash/name
# Returns: prints average milliseconds
get_avg_resume_time() {
    local project="$1"

    if [[ ! -f "$TIMING_LOG" ]]; then
        echo "0"
        return
    fi

    awk -v proj="$project" '
        $2 == proj && $3 == "resume" {
            sub(/ms$/, "", $4)
            sum += $4
            count++
        }
        END {
            if (count > 0) printf "%d\n", sum/count
            else print "0"
        }
    ' "$TIMING_LOG"
}

# Show boot timing statistics
# Args: optional $1 = project filter
show_boot_stats() {
    local project="${1:-}"

    if [[ ! -f "$TIMING_LOG" ]]; then
        echo "No boot timing data available."
        return
    fi

    echo "Boot Performance Summary"
    echo "========================"

    if [[ -n "$project" ]]; then
        echo "Project: $project"
        echo ""
        awk -v proj="$project" '
            $2 == proj {
                sub(/ms$/, "", $4)
                printf "  %s  %-10s %6dms  %s\n", $1, $3, $4, $5
            }
        ' "$TIMING_LOG"
    else
        echo ""
        awk '
            {
                sub(/ms$/, "", $4)
                type = $3
                ms = $4
                if (type == "resume") { rsum += ms; rcount++ }
                else { csum += ms; ccount++ }
            }
            END {
                if (rcount > 0)
                    printf "Resume:    avg %dms across %d boots\n", rsum/rcount, rcount
                if (ccount > 0)
                    printf "Cold boot: avg %dms across %d boots\n", csum/ccount, ccount
                printf "Target:    %ds (%dms)\n", '"$BOOT_TARGET_SECONDS"', '"$BOOT_TARGET_SECONDS"' * 1000
            }
        ' "$TIMING_LOG"
    fi
}

# Timed wrapper that measures a command and logs the result
# Args:
#   $1 = project hash/name
#   $2 = boot type ("resume" or "coldboot")
#   $3+ = command to run
# Returns: exit code of the command
timed_boot() {
    local project="$1"
    local boot_type="$2"
    shift 2

    local start_ns
    start_ns=$(date +%s%N)

    # Run the actual command
    "$@"
    local rc=$?

    local end_ns
    end_ns=$(date +%s%N)
    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

    local result="ok"
    if ! check_boot_target "$elapsed_ms"; then
        result="slow"
    fi

    log_boot_timing "$project" "$boot_type" "$elapsed_ms" "$result"

    if [[ "$result" == "slow" && "$boot_type" == "resume" ]]; then
        echo "⚠️  Resume took ${elapsed_ms}ms — exceeds ${BOOT_TARGET_SECONDS}s target" >&2
        echo "   Run 'claude-vm stats' for boot timing history" >&2
    fi

    return $rc
}
