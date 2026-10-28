#!/usr/bin/env bash
#
# Build AFL++ from source (a pinned release tag) into $AFLPP_DIR. Nothing is
# installed system-wide: build_ardupilot.sh and run_fuzz.sh put $AFLPP_DIR first
# on PATH. Safe to re-run; an existing build is reused.
#
# Config (override via environment):
#   AP_FUZZ_ROOT   workspace root                (default ~/apfuzz)
#   AFLPP_DIR      AFL++ checkout and build      (default $AP_FUZZ_ROOT/AFLplusplus)
#   AFL_VERSION    AFL++ release tag             (default v5.03c)
#   LLVM_CONFIG    llvm-config for LLVM mode     (default llvm-config-14, Ubuntu 22.04's)
#   JOBS           parallel compile jobs         (default nproc)
#
set -euo pipefail

: "${AP_FUZZ_ROOT:=$HOME/apfuzz}"
: "${AFLPP_DIR:=$AP_FUZZ_ROOT/AFLplusplus}"
: "${AFL_VERSION:=v5.03c}"
: "${LLVM_CONFIG:=llvm-config-14}"
: "${JOBS:=$(nproc)}"

AFL_REPO="https://github.com/AFLplusplus/AFLplusplus.git"
LLVM_VER=${LLVM_CONFIG##*-}
# Build-time needs only; LLVM/clang provide afl-clang-fast's instrumentation.
APT_PKGS=(build-essential git python3-dev "clang-$LLVM_VER" "llvm-$LLVM_VER-dev")

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

AFL_TOOLS=(afl-fuzz afl-clang-fast afl-clang-fast++ afl-showmap afl-whatsup)
built() { for t in "${AFL_TOOLS[@]}"; do [[ -x "$AFLPP_DIR/$t" ]] || return 1; done; }

if built && [[ "$(git -C "$AFLPP_DIR" describe --tags --exact-match 2>/dev/null)" == "$AFL_VERSION" ]]; then
    log "AFL++ $AFL_VERSION already built at $AFLPP_DIR"
    exit 0
fi

if ! command -v "$LLVM_CONFIG" >/dev/null || ! command -v make >/dev/null || ! command -v git >/dev/null; then
    command -v apt-get >/dev/null || die "missing build deps and no apt-get; install: ${APT_PKGS[*]}"
    log "Installing ${APT_PKGS[*]} (needs sudo)"
    sudo apt-get update
    sudo apt-get install -y "${APT_PKGS[@]}"
fi

if [[ ! -d "$AFLPP_DIR/.git" ]]; then
    log "Cloning AFL++ $AFL_VERSION into $AFLPP_DIR"
    git clone --depth 1 --branch "$AFL_VERSION" "$AFL_REPO" "$AFLPP_DIR"
else
    have=$(git -C "$AFLPP_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)
    [[ "$have" == "$AFL_VERSION" ]] \
        || die "$AFLPP_DIR is at '$have', not $AFL_VERSION; remove it or set AFLPP_DIR elsewhere"
    log "Reusing AFL++ $AFL_VERSION at $AFLPP_DIR"
fi

log "Building AFL++ (LLVM mode via $LLVM_CONFIG, -j$JOBS)"
# NO_NYX: Nyx is a hypervisor-based mode we don't use and needs extra deps.
make -C "$AFLPP_DIR" -j"$JOBS" all LLVM_CONFIG="$LLVM_CONFIG" NO_NYX=1

built || die "AFL++ build did not produce all of: ${AFL_TOOLS[*]}"
printf '\n  %s\n' "$("$AFLPP_DIR/afl-fuzz" -h 2>&1 | head -1)"
