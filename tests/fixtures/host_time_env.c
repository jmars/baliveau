/* tests/fixtures/host_time_env.c — S1 CHILD-ENV PROBE: a MUTANT fx-host-time
 * that prints the vendored pledge's environment variables.
 *
 * The sandbox spec is the WHOLE spec ONLY because the spawn scrubs the child
 * environment to a PATH-only env before exec'ing stage3: if RATTAN_EXTRA_PROMISES
 * or RATTAN_ALLOW_PTRACE survived, the program could WIDEN its own promises
 * (extra tokens) or SKIP seccomp entirely (ptrace) — the spec-completeness
 * precondition the gate must PROVE, not assume.  The mutant prints getenv() of
 * both; a NULL reading is the proof the scrub happened.
 *
 *   post-fix (the S1 proxy): both read NULL -> S1-ENV-...=NULL.
 *
 * A gate fixture, never a product binary. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static void drain_stdin(void) {
    char buf[4096];
    while (fread(buf, 1, sizeof buf, stdin) > 0)
        ;
}

static const char *show(const char *name) {
    const char *v = getenv(name);
    return v ? v : "NULL";
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

    printf("S1-ENV-RATTAN_ALLOW_PTRACE=%s\n", show("RATTAN_ALLOW_PTRACE"));
    printf("S1-ENV-RATTAN_EXTRA_PROMISES=%s\n", show("RATTAN_EXTRA_PROMISES"));
    fflush(stdout);
    return 0;
}
