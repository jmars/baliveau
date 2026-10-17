/* tests/fixtures/spawn_flood.c — the S3 spawn-cap probe: floods stdout.
 * The spawn's OUTPUT CAP must refuse it; never silently truncate. */
#include <stdio.h>
#include <string.h>
int main(void) {
    char b[4096];
    memset(b, 'F', sizeof b);
    for (int i = 0; i < 4096; i++) fwrite(b, 1, sizeof b, stdout);
    fflush(stdout);
    return 0;
}
