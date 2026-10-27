/*
 * AFL++ harness for ArduCopter's MAVLink message handling.
 *
 * The real ArduCopter vehicle (Copter.cpp and friends, compiled unchanged,
 * see wscript) boots in SITL with its internal quad physics model, runs a
 * warm-up so the EKF and simulated GPS settle, and only then hands control to
 * AFL's deferred forkserver. Each testcase therefore starts from the same
 * fully-initialised vehicle, with every singleton a real vehicle has.
 *
 * Each testcase is a *sequence* of MAVLink messages, so stateful protocols
 * (mission/fence/rally upload, parameter and FTP sessions) are reachable.
 * Messages enter at GCS_MAVLINK::raw_packetReceived() on channel 0: the same
 * call the wire parser makes after a frame decodes (GCS_Common.cpp,
 * update_receive), so routing, GCS_MAVLINK_Copter's overrides and the common
 * handlers all run. Framing/CRC are skipped: they guard nothing an attacker
 * on an unsigned link can't forge, and finding valid CRCs is pure fuzzer
 * overhead. Between messages the vehicle's main loop runs, so replies,
 * timeouts and mode/mission logic advance as they would in flight.
 *
 * Input format, repeated until the input runs out (all fields AFL-mutable):
 *   u8  sysid      sender system id (the GCS is 255 by default; RC override,
 *                  manual control and GCS failsafe only accept that)
 *   u8  compid
 *   u24 msgid      little-endian
 *   u8  len        payload length; truncated to what remains of the input
 *   len bytes      payload
 *
 * AP_HAL::panic() (which SITL also uses for INTERNAL_ERROR) is wrapped at
 * link time to abort(), so it reaches AFL as a crash instead of SITL's
 * infinite loop. Triage those separately from memory errors: the output
 * starts with "PANIC:".
 *
 * Build: fuzz/build_ardupilot.sh. Run: fuzz/run_fuzz.sh. Seeds:
 * fuzz/make_seeds.py.
 * Reproduce: ./fuzz_handle_message <crash-file>   (run from a scratch dir:
 * SITL writes eeprom.bin to the cwd). AP_FUZZ_DEBUG=1 prints the vehicle's
 * armed state, mode and mission size after the testcase.
 */

#include <AP_HAL/AP_HAL.h>
#include <AP_Mission/AP_Mission.h>
#include <AP_Scheduler/AP_Scheduler.h>
#include <AP_Vehicle/AP_Vehicle.h>
#include <GCS_MAVLink/GCS.h>

#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern const AP_HAL::HAL& hal;  // defined in ArduCopter/Copter.cpp

// Simulated time before forking; long enough for EKF/GPS to be healthy so
// arming and mode changes can actually succeed (30s was too short to arm in
// GUIDED). Costs ~15s wall time once per fuzzer start, not per exec.
static const uint32_t WARMUP_MS = 60000;
// Main-loop iterations (400Hz, so 2.5ms of simulated time each) after each
// message, letting replies and state machines advance.
static const uint8_t LOOPS_PER_MESSAGE = 4;
static const uint8_t MAX_MESSAGES = 64;
static const size_t HEADER_LEN = 6;

static const char *input_path;

extern "C" [[noreturn]] void __wrap__ZN6AP_HAL5panicEPKcz(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "PANIC: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    abort();
}

static size_t read_input(uint8_t *buf, size_t size)
{
    FILE *f = input_path ? fopen(input_path, "rb") : stdin;
    if (f == nullptr) {
        perror(input_path);
        _exit(1);
    }
    const size_t len = fread(buf, 1, size, f);
    if (input_path) {
        fclose(f);
    }
    return len;
}

static void run_testcase(AP_Vehicle &vehicle)
{
    static uint8_t buf[MAX_MESSAGES * (HEADER_LEN + MAVLINK_MAX_PAYLOAD_LEN)];
    const size_t len = read_input(buf, sizeof(buf));

    GCS_MAVLINK *link = gcs().chan(0);
    if (link == nullptr) {
        fprintf(stderr, "no MAVLink channel 0\n");
        abort();
    }

    const mavlink_status_t status {};
    size_t off = 0;
    for (uint8_t n = 0; n < MAX_MESSAGES && len - off >= HEADER_LEN; n++) {
        const uint8_t *h = &buf[off];
        off += HEADER_LEN;

        mavlink_message_t msg {};
        msg.magic = MAVLINK_STX;
        msg.sysid = h[0];
        msg.compid = h[1];
        msg.msgid = h[2] | (h[3] << 8) | (uint32_t(h[4]) << 16);
        msg.len = MIN(size_t(h[5]), len - off);
        memcpy(_MAV_PAYLOAD_NON_CONST(&msg), &buf[off], msg.len);
        off += msg.len;

        link->raw_packetReceived(MAVLINK_FRAMING_OK, status, msg);
        for (uint8_t i = 0; i < LOOPS_PER_MESSAGE; i++) {
            vehicle.loop();
        }
    }
}

class FuzzCallbacks : public AP_HAL::HAL::Callbacks {
public:
    void setup() override {
        AP::vehicle()->setup();
    }

    // Called repeatedly by the SITL HAL; never returns.
    void loop() override {
        AP_Vehicle &vehicle = *AP::vehicle();
        while (AP_HAL::millis() < WARMUP_MS) {
            vehicle.loop();
        }
        // The scheduler holds its main-loop semaphore (a recursive pthread
        // mutex, owned by kernel TID) for the vehicle's lifetime. The forked
        // child has a new TID, so it must not inherit the lock as held:
        // release it across the fork and re-take it as the child.
        HAL_Semaphore &loop_sem = AP::scheduler().get_semaphore();
        loop_sem.give();
#ifdef __AFL_HAVE_MANUAL_CONTROL
        __AFL_INIT();
#endif
        loop_sem.take_blocking();
        run_testcase(vehicle);
        if (getenv("AP_FUZZ_DEBUG")) {
            fprintf(stderr, "AP_FUZZ_DEBUG armed=%d mode=%u mission_items=%u t=%ums\n",
                    hal.util->get_soft_armed(), vehicle.get_mode(),
                    unsigned(AP::mission().num_commands()),
                    unsigned(AP_HAL::millis()));
        }
        // Skip static destructors of the whole vehicle.
        _exit(0);
    }
};

static FuzzCallbacks callbacks;

int main(int argc, char *argv[])
{
    input_path = argc > 1 ? argv[1] : nullptr;

    // Parameter defaults are installed next to the binary by the build.
    static char defaults[PATH_MAX];
    const ssize_t n = readlink("/proc/self/exe", defaults, sizeof(defaults) - 32);
    if (n <= 0) {
        perror("readlink /proc/self/exe");
        return 1;
    }
    defaults[n] = '\0';
    strcat(defaults, ".parm");

    // Serial ports are "none" so nothing blocks in accept() or binds a TCP
    // port (parallel fuzzers would collide). SERIAL3/4 stay as the simulated
    // GPSes. --instance keeps the remaining UDP sim ports apart per fuzzer.
    const char *instance = getenv("AP_FUZZ_INSTANCE");
    const char *sitl_argv[] = {
        argv[0],
        "--model", "quad",
        "--speedup", "100000",
        "--wipe",
        "--instance", instance ? instance : "0",
        "--defaults", defaults,
        "--serial0", "none", "--serial1", "none", "--serial2", "none",
        "--serial5", "none", "--serial6", "none", "--serial7", "none",
        // Not --serial9: SITL accepts it but _serial_path has only 9 slots,
        // so it overwrites the neighbouring cmdline_param array.
        "--serial8", "none",
        nullptr,
    };
    hal.run(ARRAY_SIZE(sitl_argv) - 1, (char * const *)sitl_argv, &callbacks);
    return 0;
}
