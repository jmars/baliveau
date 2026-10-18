/* tests/fixtures/host_time_sigsys.c — S1 SIGSYS-RENDERING PROBE: a MUTANT
 * fx-host-time that kills ITSELF with SIGSYS.
 *
 * The spawn's DISTINCT refusal (a SIGSYS death = the promise was escaped, a
 * different outcome from a non-zero exit and from a timeout) is a rendering
 * path in host_exec's reap logic.  The vendored pledge's default penalty is
 * EPERM (denied syscalls return errno, they do NOT kill — MEASURED), so a
 * sandboxed program cannot produce a SIGSYS death.  This fixture proves the
 * rendering is WIRED by dying SIGSYS through the FH_MUTANT_NO_STAGE3 build
 * (the spawn's stage3 wrap compiled out, so raise() is not itself blocked by
 * the seccomp filter).
 *
 * A gate fixture, never a product binary. */
#define _POSIX_C_SOURCE 200809L
#include <signal.h>
#include <stdio.h>
#include <time.h>

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

    printf("S1-SIGSYS: raising SIGSYS on self\n");
    fflush(stdout);
    raise(SIGSYS);
    /* unreachable; if the signal is somehow blocked, still die non-zero so the
     * arm's refusal-shape assertion (distinct from SIGSYS) cannot silently
     * pass. */
    return 1;
}
