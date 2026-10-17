/* tools/fx-host-time.c — the host_time DECLARED PROGRAM (egress S3).
 *
 * One of the host-tool programs the proxy's registry names.  THE CONTRACT
 * (the SAME for every host-tool program, stated once here and per program):
 *   stdin   the call's arguments AS JSON, VERBATIM (the model's own bytes —
 *           never interpolated into a command line, never re-encoded);
 *   stdout  the RESULT the proxy substitutes over the guest's sentinel as the
 *           call's own result (bounded by the SPAWN's cap, not by this file);
 *   exit 0  a well-formed call produced a result;
 *   exit != 0 a hard error (unparseable input) -> the SPAWN renders a named
 *           refusal, never a silent empty success.
 *
 * host_time READS NO ARGUMENT (its registry entry declares arg_key NULL and
 * reads_arg 0): it drains stdin and prints the host's wall clock.  The
 * output text is byte-pinned by the S1 gate (tests/test_hostgate.sh phase 75
 * and phase 95 assert the "(host_time:" prefix and the "HOST's wall clock"
 * phrase) — do not reword it without re-pinning those arms.
 *
 * THIS PROGRAM IS HOST-SIDE AND IS THE THING THE SPAWN RUNS.  It is NOT the
 * executor: the executor is the proxy's spawn (fork + execvpe + scrubbed env
 * + deadline + stdout cap).  This file only decides what the result IS. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Drain stdin (the args JSON, which host_time ignores) so the spawn's write
 * can never block on a full pipe; bounded to refuse a pathological input. */
static void drain_stdin(void) {
    char buf[4096];
    while (fread(buf, 1, sizeof buf, stdin) > 0)
        ;
}

int main(void) {
    drain_stdin();
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    gmtime_r(&ts.tv_sec, &tm);
    char clock[40];
    strftime(clock, sizeof clock, "%Y-%m-%dT%H:%M:%SZ", &tm);
    printf("%s (host_time: the HOST's wall clock, UTC; executed on the host "
           "side of the chardev, not in the guest)\n",
           clock);
    fflush(stdout);
    return 0;
}
