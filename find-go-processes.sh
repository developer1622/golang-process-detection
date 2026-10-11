#!/usr/bin/env bash

# Find running Linux processes whose executable has a Go signature.
# This script does not require Go to be installed.
# Run as root for the widest process visibility:
#   sudo ./find-go-processes.sh

set -u
export LC_ALL=C

if ! command -v readlink >/dev/null 2>&1; then
    echo "readlink is required" >&2
    exit 2
fi

have_strings=0
if command -v strings >/dev/null 2>&1; then
    have_strings=1
fi

# Bash 4 associative arrays are available on Ubuntu 24.04.
declare -A result_by_exe

detect_executable() {
    local exe=$1

    if [[ ${result_by_exe[$exe]+yes} ]]; then
        printf '%s' "${result_by_exe[$exe]}"
        return 0
    fi

    # Go's embedded build-info header. This survives normal static linking,
    # CGO_ENABLED=0, -trimpath, and the usual -s -w stripping.
    if grep -a -q -F -- $'\xff Go buildinf:' "$exe" 2>/dev/null; then
        result_by_exe[$exe]=BUILDINFO
        printf 'BUILDINFO'
        return 0
    fi

    # Weaker fallback. It can miss aggressively transformed binaries and can
    # theoretically produce false positives, so it is reported separately.
    if (( have_strings )); then
        if strings -a "$exe" 2>/dev/null |
            grep -Eiq '(^|[^[:alnum:]_])runtime\.(main|gopark|goexit)([^[:alnum:]_]|$)'; then
            result_by_exe[$exe]=RUNTIME_HINT
            printf 'RUNTIME_HINT'
            return 0
        fi
    fi

    result_by_exe[$exe]=NONE
    printf 'NONE'
}

printf '%-8s %-12s %-28s %s\n' "PID" "DETECTION" "PROCESS" "EXECUTABLE"
printf '%-8s %-12s %-28s %s\n' "---" "---------" "-------" "----------"

found=0
for proc in /proc/[0-9]*; do
    [[ -d "$proc" ]] || continue

    pid=${proc##*/}
    exe="$proc/exe"
    [[ -r "$exe" ]] || continue

    path=$(readlink "$exe" 2>/dev/null) || continue
    detection=$(detect_executable "$exe")
    [[ "$detection" != NONE ]] || continue

    comm=$(<"$proc/comm") 2>/dev/null || comm='?'
    printf '%-8s %-12s %-28.28s %s\n' \
        "$pid" "$detection" "$comm" "$path"
    found=$((found + 1))
done

echo
echo "Candidates detected: $found"
echo "BUILDINFO = strong Go signature; RUNTIME_HINT = heuristic."
echo "No candidates does not prove that no Go processes exist."
