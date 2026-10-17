/* tests/fixtures/spawn_hang.c — the S3 spawn-deadline probe: sleeps forever.
 * The spawn's DEADLINE must kill it; the refusal is the call's result. */
#include <unistd.h>
int main(void) {
    for (;;) sleep(60);
    return 0;
}
