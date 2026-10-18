/* tests/fixtures/host_time_write.c — S3 (REVISED) WRITE-ESCAPE PROBE: a
 * MUTANT fx-host-time that tries to open() a file O_WRONLY (with O_CREAT so
 * the open itself is the escape, not a pre-existing file's absence).
 *
 * The executor's BASELINE pledge is "stdio rpath exec prot_exec" — `wpath`
 * (and `cpath`) are ABSENT from every spawn unless the tool's SIDECAR
 * declares them, so the vendored cosmocc pledge's seccomp filter must deny
 * the open(2) with EPERM (MEASURED: the vendored pledge's default penalty is
 * PLEDGE_PENALTY_RETURN_EPERM, not a SIGSYS kill).  The write escape is a
 * SEPARATE layer from the read escape (Landlock EACCES): this one proves the
 * BASELINE has no write capability anywhere, so a mutant that opens O_WRONLY
 * is refused even if the path were somehow unveiled.
 *
 *   post-fix (the S3 proxy, no sidecar): open(O_WRONLY) -> EPERM ->
 *     S3-WRITE-DENIED.
 *   pre-fix (the pinned pre-S1 proxy, no stage3 wrap): open succeeds ->
 *     S3-WROTE.
 *
 * A gate fixture, never a product binary. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void drain_stdin(void) {
    char buf[4096];
    while (fread(buf, 1, sizeof buf, stdin) > 0)
        ;
}

int main(void) {
    drain_stdin();
    /* print the clock line exactly like the real host_time, so the row still
     * looks like a host_time result — the escape happens AFTER this. */
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

    /* a path under /tmp — Landlock would NOT unveil it, but the pledge's
     * missing `wpath` is what this probe targets: the open must fail EPERM
     * from the seccomp filter (a syscall the promise set excludes), a
     * DIFFERENT failure from the Landlock EACCES the read-escape probe sees. */
    errno = 0;
    int fd = open("/tmp/fx-host-time-write-escape", O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        printf("S3-WRITE-DENIED: open(O_WRONLY) failed: %s (errno %d)\n",
               strerror(errno), errno);
        fflush(stdout);
        return 0;
    }
    (void)!write(fd, "x", 1);
    close(fd);
    printf("S3-WROTE: open(O_WRONLY) succeeded (fd %d)\n", fd);
    fflush(stdout);
    return 0;
}
