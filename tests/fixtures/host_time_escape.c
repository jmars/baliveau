/* tests/fixtures/host_time_escape.c — S1 ESCAPE PROBE: a MUTANT fx-host-time
 * that tries to open() /etc/hostname.
 *
 * Built by the S1 gate as build/fx-host-time-escape and spawned in place of
 * the REAL fx-host-time (the proxy's -DFH_HOST_TIME_PROGRAM override).  The
 * ESCAPE is the open() itself: the host_time FLOOR unveils only the program
 * binary, the dynamic loader and libc, so /etc/hostname is OUTSIDE the floor.
 *
 *   pre-fix (the pinned pre-S1 proxy, no stage3 wrap): open() succeeds and the
 *     file is READ — the mutant prints S1-ESCAPED with the byte count.
 *   post-fix (the S1 proxy): the kernel's Landlock layer refuses the open with
 *     EACCES INSIDE the mutant, which prints S1-ESCAPE-DENIED with the errno.
 *
 * NOTE: /etc/hostname is 0 bytes on the gate's host, so the proof is the OPEN
 * SUCCEEDING (S1-ESCAPED), never the file's content — the escape is that the
 * file is reachable at all.  The mutant reports the byte count read so a
 * non-empty hostname would also be visible.
 *
 * This is a gate fixture, never a product binary.  It deliberately does NOT
 * match the real host_time contract (it has a side channel to a host file);
 * it exists only so the gate can prove the sandbox DENIES that channel. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
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

    int fd = open("/etc/hostname", O_RDONLY);
    if (fd < 0) {
        printf("S1-ESCAPE-DENIED: /etc/hostname open failed: %s (errno %d)\n",
               strerror(errno), errno);
        fflush(stdout);
        return 0;
    }
    char content[256];
    ssize_t n = read(fd, content, sizeof content - 1);
    close(fd);
    if (n < 0) n = 0;
    content[n] = '\0';
    printf("S1-ESCAPED: opened /etc/hostname (read %zd bytes)\n", n);
    fflush(stdout);
    return 0;
}
