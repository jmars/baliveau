/* tests/fixtures/spawn_nonzero.c — the S3 spawn probe: exits non-zero.
 * A non-zero exit is a REFUSAL (never a silent empty success). */
int main(void) {
    return 3;
}
