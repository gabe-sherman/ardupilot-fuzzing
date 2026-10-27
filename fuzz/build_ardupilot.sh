#!/usr/bin/env bash
#
# Build the fuzz_handle_message harness, with ArduPilot's libraries compiled
# under AFL++ instrumentation.
#
# The harness is ArduCopter itself (its sources compiled unchanged, see
# harness/fuzz_handle_message/wscript) running in SITL, with MAVLink messages
# injected at the point the wire parser hands them to the GCS layer.
#
# Config (override via environment):
#   AP_FUZZ_ROOT   workspace root                  (default ~/apfuzz)
#   ARDUPILOT_DIR  ardupilot checkout              (default $AP_FUZZ_ROOT/ardupilot)
#   AP_COMMIT      ArduPilot commit to build       (default: the one the harness
#                  was verified against; it relies on SITL/scheduler internals)
#   USE_ASAN       1 = build with AddressSanitizer (default 1)
#   LAF            1 = AFL++ laf-intel transforms, better at magic bytes/strcmp
#                      but slower to build and run                 (default 0)
#   JOBS           parallel compile jobs           (default nproc)
#
set -euo pipefail

: "${AP_FUZZ_ROOT:=$HOME/apfuzz}"
: "${ARDUPILOT_DIR:=$AP_FUZZ_ROOT/ardupilot}"
: "${AP_COMMIT:=dc78bc54b855af03597d03e0a6c9ec13b05f41a2}"
: "${USE_ASAN:=1}"
: "${LAF:=0}"
: "${JOBS:=$(nproc)}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VENV="$AP_FUZZ_ROOT/venv"
AP_REPO="https://github.com/ArduPilot/ardupilot.git"
HARNESS_NAME="fuzz_handle_message"
HARNESS_SRC="$SCRIPT_DIR/harness/$HARNESS_NAME"
HARNESS_DIR="libraries/GCS_MAVLink/examples/$HARNESS_NAME"
# program_groups=['tool','fuzz'] in the harness's wscript -> program_dir
# defaults to the first group, 'tool' (see Tools/ardupilotwaf/ardupilotwaf.py
# ap_program()), so the waf target name is "tool/<dir name>".
HARNESS_TARGET="tool/$HARNESS_NAME"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. toolchain
TOOLS=(git python3 afl-clang-fast afl-clang-fast++ afl-fuzz clang clang++)
# Verified with Ubuntu 22.04's afl++ 4.00c (clang-14 backend).
APT_PKGS=(afl++ clang git python3 python3-venv)
toolchain_ok() {
    for t in "${TOOLS[@]}"; do command -v "$t" >/dev/null || return 1; done
    python3 -c 'import ensurepip' 2>/dev/null  # absent without python3-venv
}

log "Checking toolchain"
if ! toolchain_ok; then
    command -v apt-get >/dev/null || die "missing toolchain and no apt-get; install: ${APT_PKGS[*]}"
    log "Installing ${APT_PKGS[*]} (needs sudo)"
    sudo apt-get update
    sudo apt-get install -y "${APT_PKGS[@]}"
fi
for t in "${TOOLS[@]}"; do
    command -v "$t" >/dev/null || die "still missing '$t' after install"
done
afl-clang-fast --version >/dev/null 2>&1 || die "afl-clang-fast cannot run its backing clang"
printf '  afl-fuzz        : %s\n' "$(afl-fuzz -h 2>&1 | head -1)"
printf '  afl backend     : %s\n' "$(afl-clang-fast --version 2>&1 | head -1)"

# ArduPilot's own ./waf configure runs a handful of compiler feature probes
# (header presence, SLP-vectorizer workaround detection) that get false
# negatives when the compiler-under-test is afl-cc's wrapper rather than a
# real clang binary -- e.g. byteswap.h gets reported "not found" under
# afl-clang-fast even though it exists, which then makes ArduPilot's own
# byteswap.h compatibility shim collide with the real system header
# ("redefinition of '__bswap_16'"). So: configure with a *real* clang/clang++
# (ideally the exact version afl-cc wraps, so e.g. the clang++-specific
# -fno-slp-vectorize workaround is correctly detected too), then swap in the
# AFL wrappers for the actual build via the cached waf environment. Since
# both are the same underlying clang, this is a true drop-in for the build
# step -- only configure-time *probing* used the unwrapped compiler.
AFL_CLANG_VER=$(afl-clang-fast --version 2>&1 | grep -oE 'version [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
CONF_CC=clang
CONF_CXX=clang++
if [[ -n "$AFL_CLANG_VER" ]] && command -v "clang-$AFL_CLANG_VER" >/dev/null 2>&1; then
    CONF_CC="clang-$AFL_CLANG_VER"
    CONF_CXX="clang++-$AFL_CLANG_VER"
    log "Configuring with $CONF_CXX (exact version match for afl-cc's clang $AFL_CLANG_VER backend)"
else
    log "Configuring with system $CONF_CXX (could not find a clang-$AFL_CLANG_VER to exact-match afl-cc's backend; same compiler family, so still correct for the feature probes that matter)"
fi

# ------------------------------------------------------------------- 2. source
mkdir -p "$AP_FUZZ_ROOT"
if [[ ! -d "$ARDUPILOT_DIR/.git" ]]; then
    log "Cloning ArduPilot $AP_COMMIT into $ARDUPILOT_DIR"
    # Shallow fetch of exactly one commit: we want to compile it, not bisect it.
    git init -q "$ARDUPILOT_DIR"
    git -C "$ARDUPILOT_DIR" remote add origin "$AP_REPO"
    git -C "$ARDUPILOT_DIR" fetch --depth 1 origin "$AP_COMMIT"
    git -C "$ARDUPILOT_DIR" checkout -q FETCH_HEAD
else
    log "Reusing existing checkout at $ARDUPILOT_DIR"
    HEAD_COMMIT=$(git -C "$ARDUPILOT_DIR" rev-parse HEAD)
    if [[ "$HEAD_COMMIT" != "$AP_COMMIT" ]]; then
        printf '\033[1;33m  checkout is at %s, not the verified %s; building it anyway\033[0m\n' \
            "$HEAD_COMMIT" "$AP_COMMIT"
    fi
fi
git -C "$ARDUPILOT_DIR" submodule update --init --recursive --depth 1

[[ -d "$HARNESS_SRC" ]] || die "harness source not found: $HARNESS_SRC"
log "Installing harness into checkout: $HARNESS_DIR"
mkdir -p "$ARDUPILOT_DIR/$HARNESS_DIR"
cp "$HARNESS_SRC"/* "$ARDUPILOT_DIR/$HARNESS_DIR/"

# ---------------------------------------------------- 3. build-time generators
# These Python packages are code generators used by waf at build time; none of
# them are linked into the fuzz target:
#   pymavlink -> mavgen, generates the MAVLink C headers from XML definitions
#   empy      -> template engine for generated board/config headers (must be
#                3.3.4; the 4.x API is incompatible with ArduPilot's wscript)
#   dronecan  -> compiles DSDL definitions for the CAN stack
#   future    -> required by pymavlink's generator
if [[ ! -x "$VENV/bin/python" ]]; then
    log "Creating build venv at $VENV"
    python3 -m venv --system-site-packages "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet "empy==3.3.4" future pymavlink dronecan pexpect
else
    log "Reusing build venv at $VENV"
fi
export PATH="$VENV/bin:$PATH"
"$VENV/bin/python" -c "import em, pymavlink" \
    || die "build venv is missing empy/pymavlink"

cd "$ARDUPILOT_DIR"

# ------------------------------------------------------------------ 4. configure
log "Configuring waf (board=sitl) with the real compiler"
CC="$CONF_CC" CXX="$CONF_CXX" "$VENV/bin/python" ./waf configure --board sitl --debug

CACHE="build/c4che/sitl_cache.py"
[[ -f "$CACHE" ]] || die "waf cache not found at $CACHE after configure"

log "Swapping in AFL++ compiler wrappers for the build step"
python3 - "$CACHE" <<'PYEOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
subs = {
    r"^CC = \[.*\]$":       "CC = ['afl-clang-fast']",
    r"^CXX = \[.*\]$":      "CXX = ['afl-clang-fast++']",
    r"^LINK_CC = \[.*\]$":  "LINK_CC = ['afl-clang-fast']",
    r"^LINK_CXX = \[.*\]$": "LINK_CXX = ['afl-clang-fast++']",
}
for pat, repl in subs.items():
    text, n = re.subn(pat, repl, text, flags=re.M)
    if n != 1:
        sys.exit(f"expected exactly one match for {pat!r}, got {n}")
open(path, "w").write(text)
PYEOF
grep -nE "^(CC|CXX|LINK_CC|LINK_CXX) =" "$CACHE" | sed 's/^/  /'

# ------------------------------------------------------------ 5. instrument it
# AFL++ reads these at *build* time, not configure time:
#   AFL_USE_ASAN         add -fsanitize=address (so ASan flags stay consistent
#                        across every object; mixing is a link-time trap)
#   AFL_LLVM_LAF_ALL     split comparisons so the fuzzer can walk magic values
#   AFL_QUIET            one banner per TU across ~1500 files is unreadable
export AFL_QUIET=1
export AFL_LLVM_INSTRUMENT=PCGUARD
[[ "$USE_ASAN" == "1" ]] && export AFL_USE_ASAN=1
[[ "$LAF"      == "1" ]] && export AFL_LLVM_LAF_ALL=1

log "Building $HARNESS_TARGET (ASAN=$USE_ASAN, LAF=$LAF, -j$JOBS)"
"$VENV/bin/python" ./waf build --targets "$HARNESS_TARGET" --jobs "$JOBS"

# ------------------------------------------------------------------- 6. install
BIN_SRC=$(find build/sitl -type f -name "$HARNESS_NAME" -perm -u+x 2>/dev/null | head -1)
[[ -n "$BIN_SRC" && -x "$BIN_SRC" ]] || die "built binary not found under build/sitl (expected name: $HARNESS_NAME)"
mkdir -p "$AP_FUZZ_ROOT/out"
cp "$BIN_SRC" "$AP_FUZZ_ROOT/out/fuzz_handle_message"
# The harness loads <binary>.parm as SITL --defaults.
cp "$HARNESS_SRC/fuzz_overrides.parm" "$AP_FUZZ_ROOT/out/fuzz_handle_message.parm"

cat <<EOF

$(printf '\033[1;32m')Harness built.$(printf '\033[0m')

  checkout : $ARDUPILOT_DIR
  binary   : $AP_FUZZ_ROOT/out/fuzz_handle_message

Next:
  ./fuzz/run_fuzz.sh fuzz_handle_message
EOF
