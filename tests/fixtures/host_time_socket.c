/* tests/fixtures/host_time_socket.c — S1 SECCOMP-LAYER PROBE: a MUTANT
 * fx-host-time that calls socket(AF_INET, SOCK_STREAM, 0).
 *
 * The host_time FLOOR's pledge is "stdio rpath exec prot_exec" — the `inet`
 * token is ABSENT, so the vendored cosmocc pledge's seccomp filter must deny
 * the socket(2) syscall.  MEASURED on this host (and by the gate): the
 * vendored pledge's default penalty is PLEDGE_PENALTY_RETURN_EPERM, so the
 * syscall is refused with errno EPERM, NOT a SIGSYS kill (see the gate's S1
 * escape arms and the SIGSYS-rendering arm, which drives a real SIGSYS
 * through the no-stage3 build to prove the spawn's DISTINCT refusal).
 *
 *   pre-fix (no sandbox): socket() succeeds -> S1-SOCKET-OK.
 *   post-fix (the S1 proxy): socket() returns -1/EPERM -> S1-SOCKET-DENIED.
 *
 * A gate fixture, never a product binary. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

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

    errno = 0;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        printf("S1-SOCKET-DENIED: socket() failed: %s (errno %d)\n",
               strerror(errno), errno);
        fflush(stdout);
        return 0;
    }
    close(s);
    printf("S1-SOCKET-OK: socket() returned fd %d\n", s);
    fflush(stdout);
    return 0;
}
