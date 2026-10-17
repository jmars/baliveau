/* tests/fixtures/echo_argv_stdin.c — the S3 program-contract probe.
 *
 * A DECLARED-PROGRAM substitute the gate builds and names (via a mutant
 * proxy's -DFH_HOST_CAT_PROGRAM override) to PROVE the spawn's contract: the
 * call's arguments must reach the program VERBATIM ON STDIN and must NEVER be
 * interpolated into the command line.  This program echoes BOTH its argv and
 * its stdin so the gate can assert each half:
 *   ARGV:<count>:<arg0|arg1|...>   the spawn's command line — must carry ONLY
 *                                   the registry's program + fixed args, none
 *                                   of the call's own bytes;
 *   STDIN:<raw bytes>              the call's arguments AS JSON, verbatim.
 */
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    printf("ARGV:%d", argc);
    for (int i = 0; i < argc; i++) printf(":%s", argv[i]);
    printf("\nSTDIN:");
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, stdin)) > 0)
        fwrite(buf, 1, n, stdout);
    fflush(stdout);
    return 0;
}
