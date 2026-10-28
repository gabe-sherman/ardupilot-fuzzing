#!/usr/bin/env bash
#
# Launch afl-fuzz against a built harness.
#
# Usage:
#   ./fuzz/run_fuzz.sh [harness_name] [-- extra afl-fuzz args]
#
# Config (override via environment):
#   AP_FUZZ_ROOT   workspace root        (default ~/apfuzz)
#   AFLPP_DIR      AFL++ build           (default $AP_FUZZ_ROOT/AFLplusplus)
#   CORES          parallel fuzzers      (default 1)
#   TIMEOUT        per-exec timeout, ms  (default 1000; a 64-message input
#                  runs ~250 vehicle main-loop iterations)
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${AP_FUZZ_ROOT:=$HOME/apfuzz}"
: "${AFLPP_DIR:=$AP_FUZZ_ROOT/AFLplusplus}"
# The AFL++ that build_afl++.sh built, matching the harness instrumentation.
export PATH="$AFLPP_DIR:$PATH"
: "${CORES:=1}"
: "${TIMEOUT:=1000}"

HARNESS_NAME="${1:-fuzz_handle_message}"
shift || true
[[ "${1:-}" == "--" ]] && shift || true

BIN="$AP_FUZZ_ROOT/out/$HARNESS_NAME"
CORPUS="$HERE/corpus/$HARNESS_NAME"
DICT="$HERE/dict/$HARNESS_NAME.dict"
FINDINGS="$AP_FUZZ_ROOT/findings/$HARNESS_NAME"

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -x "$BIN" ]] || die "harness not built: $BIN  (run ./fuzz/build_ardupilot.sh)"
[[ -d "$CORPUS" ]] || die "no corpus at $CORPUS"
[[ -x "$AFLPP_DIR/afl-fuzz" ]] || die "AFL++ not built at $AFLPP_DIR (run ./fuzz/build_ardupilot.sh)"

# AFL++ refuses to start if crashes get piped to an external handler, because it
# can no longer tell a crash from a hang. WSL2 commonly ships a piped pattern.
PATTERN=$(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo core)
if [[ "$PATTERN" == \|* ]]; then
    cat >&2 <<EOF
$(printf '\033[1;33m')core_pattern is '$PATTERN', which AFL++ will reject.$(printf '\033[0m')
Fix it for this boot with:
    sudo sysctl -w kernel.core_pattern=core
EOF
    exit 1
fi

mkdir -p "$FINDINGS"
# SITL writes eeprom.bin (wiped at each fuzzer start) into its working
# directory, and --instance spaces its UDP ports, so each fuzzer gets both.
WORK="$AP_FUZZ_ROOT/work/$HARNESS_NAME"

# ASan must abort (not exit 1) or AFL++ cannot see the crash. Leak detection is
# off because the harness _exit()s without tearing down the vehicle.
export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:detect_odr_violation=0:handle_abort=1"
export AFL_SKIP_CPUFREQ=1          # WSL2 exposes no cpufreq governor
export AFL_IGNORE_PROBLEMS=1       # tolerate late dlopen in the SITL HAL
export AFL_AUTORESUME=1            # re-running resumes instead of erroring
export AFL_CMPLOG_ONLY_NEW=1
# The harness boots Copter and simulates 60s of warm-up before the fork
# server comes up (~15s wall time, more on a loaded machine).
export AFL_FORKSRV_INIT_TMOUT=120000

AFL_ARGS=( -i "$CORPUS" -o "$FINDINGS" -t "$TIMEOUT" )
# ASan maps a huge shadow region, so the usual RSS cap must come off.
AFL_ARGS+=( -m none )
[[ -f "$DICT" ]] && AFL_ARGS+=( -x "$DICT" )

if [[ "$CORES" -le 1 ]]; then
    printf '\033[1;34m==> afl-fuzz %s (single core)\033[0m\n' "$HARNESS_NAME"
    mkdir -p "$WORK/0" && cd "$WORK/0"
    AP_FUZZ_INSTANCE=0 exec afl-fuzz "${AFL_ARGS[@]}" "$@" -- "$BIN"
fi

# Parallel: one primary (-M) doing deterministic stages, rest secondary (-S).
printf '\033[1;34m==> afl-fuzz %s on %s cores\033[0m\n' "$HARNESS_NAME" "$CORES"
for ((i = 0; i < CORES; i++)); do
    if [[ $i -eq 0 ]]; then ROLE=( -M "primary" ); else ROLE=( -S "sec$i" ); fi
    mkdir -p "$WORK/$i"
    (cd "$WORK/$i" && AP_FUZZ_INSTANCE=$i setsid afl-fuzz "${AFL_ARGS[@]}" "${ROLE[@]}" "$@" -- "$BIN" \
        >"$FINDINGS/fuzzer$i.log" 2>&1) &
    sleep 1
done

cat <<EOF

Started $CORES fuzzers. Monitor with:
    afl-whatsup $FINDINGS
Crashes land in:
    $FINDINGS/*/crashes/
Stop everything with:
    pkill afl-fuzz
EOF
wait
