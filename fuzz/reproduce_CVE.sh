#!/usr/bin/env bash
#
# Reproduce CVE-2026-38971 with the fuzz harness.
#
# SERIAL_CONTROL's handler wrote packet.count bytes from the 70-byte
# packet.data without checking count, so count=255 reads 185 bytes past the
# buffer (off the stack) and sends them out the serial port. Fixed upstream in
# ee7c410 (PR #32587); this builds the harness at its parent, fe1471c, in a
# separate workspace and feeds it pocs/CVE-2026-38971.bin: one SERIAL_CONTROL
# message, device=100 (SERIAL0), flags=0, count=255.
#
# Expected: ASan stack-buffer-overflow in GCS_MAVLINK::handle_serial_control.
# If the regular (fixed) build exists, the same input is run against it too
# and should come back clean.
#
# Config (override via environment):
#   AP_FUZZ_ROOT   main workspace (default ~/apfuzz); the vulnerable build
#                  goes in $AP_FUZZ_ROOT/cve-2026-38971 and shares the main
#                  workspace's AFL++ build
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${AP_FUZZ_ROOT:=$HOME/apfuzz}"
VULN_COMMIT=fe1471c9809736d52624e1e7494d1553950141e6
VULN_ROOT="$AP_FUZZ_ROOT/cve-2026-38971"
POC="$HERE/pocs/CVE-2026-38971.bin"

AFLPP_DIR="${AFLPP_DIR:-$AP_FUZZ_ROOT/AFLplusplus}"
AP_FUZZ_ROOT="$VULN_ROOT" AFLPP_DIR="$AFLPP_DIR" AP_COMMIT="$VULN_COMMIT" \
    "$HERE/build_ardupilot.sh"

# Ubuntu only ships versioned symbolizers (llvm-symbolizer-14); without one
# ASan prints bare addresses instead of function/file:line.
SYMBOLIZER=$(command -v llvm-symbolizer llvm-symbolizer-14 2>/dev/null | head -1 || true)

# Run a build on the PoC from a scratch dir (SITL writes eeprom.bin to cwd);
# print its output, return its exit status.
run_poc() {
    local scratch rc=0
    scratch=$(mktemp -d)
    (cd "$scratch" && ASAN_OPTIONS=detect_leaks=0:detect_odr_violation=0 \
        ASAN_SYMBOLIZER_PATH="$SYMBOLIZER" \
        timeout 300 "$1" "$POC" 2>&1) || rc=$?
    rm -rf "$scratch"
    return $rc
}

printf '\n\033[1;34m==> Running PoC against vulnerable %s\033[0m\n' "${VULN_COMMIT:0:7}"
out=$(run_poc "$VULN_ROOT/out/fuzz_handle_message") || true
if grep -q "stack-buffer-overflow" <<<"$out" && grep -q "handle_serial_control" <<<"$out"; then
    sed -n '/ERROR: AddressSanitizer/,/SUMMARY: AddressSanitizer/p' <<<"$out" \
        | sed -E 's#/home/[^ ]*/(libraries|ArduCopter)/#\1/#'
    printf '\033[1;32mREPRODUCED: CVE-2026-38971\033[0m\n'
else
    tail -20 <<<"$out"
    printf '\033[1;31mNOT REPRODUCED: no stack-buffer-overflow in handle_serial_control\033[0m\n'
    exit 1
fi

FIXED_BIN="$AP_FUZZ_ROOT/out/fuzz_handle_message"
if [[ -x "$FIXED_BIN" ]]; then
    printf '\n\033[1;34m==> Running PoC against the regular (fixed) build\033[0m\n'
    if run_poc "$FIXED_BIN" >/dev/null; then
        printf '\033[1;32mfixed build: clean\033[0m\n'
    else
        printf '\033[1;31mfixed build: did not exit cleanly\033[0m\n'
        exit 1
    fi
fi
