# ArduCopter MAVLink fuzzing

AFL++ fuzzing of ArduCopter's MAVLink message handling. The target is the
real ArduCopter vehicle (its sources compiled unchanged) running in SITL with
the built-in quad physics model. Each fuzz input is a sequence of MAVLink
messages, so multi-message protocols such as mission/fence/rally upload and
parameter or FTP sessions are reachable.

## Quick start

Tested on Ubuntu 22.04 (native or WSL2). Needs about 3 GB of disk.

```sh
./fuzz/build_ardupilot.sh                     # builds AFL++ from source, clones + builds ArduPilot
sudo sysctl -w kernel.core_pattern=core       # once per boot, see below
./fuzz/run_fuzz.sh                            # one core
CORES=4 ./fuzz/run_fuzz.sh                    # or several
```

- The first build runs `fuzz/build_afl++.sh`, which clones AFL++ `v5.03c`
  from GitHub and builds it (about 8 minutes on an 8-core machine; apt
  supplies only build dependencies such as clang-14 and llvm-14-dev). It then
  clones ArduPilot (pinned commit, see `AP_COMMIT` in
  `fuzz/build_ardupilot.sh`) and compiles all of ArduCopter with AFL
  instrumentation and AddressSanitizer, roughly another 7 minutes.
  Re-running it skips AFL++ and `waf configure` and only rebuilds what
  changed. Changing `USE_ASAN`, `LAF`, `AFLPP_DIR` or the ArduPilot commit
  forces a clean ArduPilot build, since waf can't see those.
- Everything it produces lives under `~/apfuzz` (override with
  `AP_FUZZ_ROOT`): the AFL++ build in `AFLplusplus/`, the ArduPilot checkout,
  a Python venv for the build-time code generators, the binary in `out/`, and
  fuzzer output in `findings/`. Nothing is installed system-wide; the scripts
  put `~/apfuzz/AFLplusplus` first on `PATH` themselves.
- `core_pattern`: AFL++ refuses to run when crashes are piped to a crash
  handler, which Ubuntu (apport) and WSL2 both do. The setting resets on
  reboot. `run_fuzz.sh` checks it and tells you if it needs fixing.

Each fuzzer takes about 15 seconds to start: the vehicle boots and simulates
60 seconds of flight-controller time (so the EKF and GPS are healthy and it can
arm) before AFL's fork server takes over. After that, every testcase starts
from that same warmed-up state.

## Watching and stopping

```sh
afl-whatsup ~/apfuzz/findings/fuzz_handle_message
pkill afl-fuzz
```

Expect a few dozen execs/sec per core. Speed falls as inputs get longer, since
every message also runs the vehicle's main loop.

## Triaging a crash

Crashes are in `~/apfuzz/findings/fuzz_handle_message/*/crashes/`. Reproduce
from a scratch directory (SITL writes `eeprom.bin` to the current directory):

```sh
mkdir -p /tmp/repro && cd /tmp/repro
ASAN_OPTIONS=detect_leaks=0 AP_FUZZ_DEBUG=1 ~/apfuzz/out/fuzz_handle_message <crash-file>
```

- `ERROR: AddressSanitizer` is a memory-safety bug.
- `PANIC:` is an ArduPilot internal error or failed invariant. SITL panics on
  these and the harness turns panics into crashes. Worth reporting, but triage
  separately from memory bugs.
- For a stack trace on a panic: `gdb -batch -ex run -ex bt --args ~/apfuzz/out/fuzz_handle_message <crash-file>`.
- `AP_FUZZ_DEBUG=1` prints armed state, flight mode and mission size after the
  input runs.

Floating-point traps are off (`SIM_FLOAT_EXCEPT 0` in
`fuzz/harness/fuzz_handle_message/fuzz_overrides.parm`). SITL normally aborts on
NaN/overflow operations that flight hardware tolerates, and fuzzed float fields
hit those within minutes, burying everything else. Set it to 1 and rebuild to
hunt that class on purpose. Known reproducers of it are in
`~/apfuzz/findings/fpe_known/` on the machine that found them.

## Reproducing CVE-2026-38971

```sh
./fuzz/reproduce_CVE.sh
```

A SERIAL_CONTROL message with `count` larger than its 70-byte data buffer made
the handler read past the buffer on the stack (fixed upstream in `ee7c410`,
PR #32587). The script builds the harness at the last vulnerable commit
(`fe1471c`) in `~/apfuzz/cve-2026-38971`, feeds it `fuzz/pocs/CVE-2026-38971.bin`
(one SERIAL_CONTROL message, `device=100`, `count=255`), and checks for an ASan
`stack-buffer-overflow` in `GCS_MAVLINK::handle_serial_control`. If the regular
build exists it also runs the input there, where it should be clean. The first
run does a full ArduPilot build (about 7 minutes).

## Files

- `fuzz/build_afl++.sh` builds AFL++ `v5.03c` from source into
  `~/apfuzz/AFLplusplus` (called by `build_ardupilot.sh`).
- `fuzz/build_ardupilot.sh` builds AFL++, checks out ArduPilot, copies the
  harness into it and builds `~/apfuzz/out/fuzz_handle_message`.
- `fuzz/reproduce_CVE.sh` and `fuzz/pocs/` reproduce a known CVE (see above).
- `fuzz/run_fuzz.sh` starts `afl-fuzz` (`CORES`, `TIMEOUT` env vars), giving each
  fuzzer its own working directory and SITL port range.
- `fuzz/harness/fuzz_handle_message/` holds the harness source, its waf build
  script and the parameter overrides. The header comment in the `.cpp` documents
  the input format and design.
- `fuzz/corpus/fuzz_handle_message/` holds the seeds, generated by
  `fuzz/make_seeds.py`
  (run it with `~/apfuzz/venv/bin/python fuzz/make_seeds.py` after a build).
- `fuzz/dict/fuzz_handle_message.dict` is the AFL dictionary (message IDs, GCS
  sender ID).

## Input format

Repeated until the input runs out, up to 64 messages:

| bytes | field |
|---|---|
| 1 | sender system ID (255 is the GCS by default) |
| 1 | sender component ID |
| 3 | message ID, little-endian |
| 1 | payload length |
| n | payload (MAVLink2 layout, no framing or CRC) |

## Known limits

- MAVLink framing, CRC and signing are bypassed by design. Messages enter where
  the wire parser hands them to the GCS layer.
- Only ArduCopter, quad frame. Vehicle-specific handlers for Plane/Rover/Sub
  are not exercised.
- The logger's I/O thread does not survive AFL's fork. Stability is around
  97%, and this is the likely (unconfirmed) cause of the rest.
- Whether FTP requests are fully serviced within one testcase is unverified.
- No CMPLOG build, so magic values inside payloads rely on random mutation and
  the dictionary.
