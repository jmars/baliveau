/* tools/fx-host-cat.c — the host_cat DECLARED PROGRAM (egress S3).
 *
 * The host-tool program the proxy's registry names for host_cat.  THE
 * CONTRACT is the one fx-host-time.c states: stdin = the call's arguments as
 * JSON verbatim, stdout = the RESULT (the refusal text IS the result), exit 0
 * for a well-formed call, exit != 0 for a hard parse error.
 *
 * THIS FILE CARRIES THE EXECUTOR'S OWN HARDENING, MOVED HERE FROM THE PROXY
 * (the S2-fix work that used to live in tools/fx-hostgate.c host_exec_cat):
 *   - the class governs the SPELLING, the OPEN follows the kernel: O_NOFOLLOW
 *     + O_NONBLOCK + fstat S_ISREG on the OPENED fd refuse a final-component
 *     symlink and every non-regular object BY NAME before any read (a
 *     writerless FIFO would otherwise block the whole lane, and a data-classed
 *     symlink would read a protected object);
 *   - NUL content is REFUSED BY NAME, never silently truncated;
 *   - the PATH is bounded (FH_HOST_PATH_MAX) so the result always fits the
 *     record's 512-byte outcome cap (the record and the wire must agree);
 *   - the CONTENT is bounded (FH_HOST_CAT_MAX) — refuse, never truncate.
 * STATED RESIDUALS (unchanged from S2-fix, not fixed): an INTERMEDIATE-dir
 * symlink (openat2/RESOLVE_* territory), a HARDLINK (a regular file at a
 * classed name — the operator's dir-trust is transitive over hardlinks), and
 * a REGULAR file on a hung backing store (the SPAWN's deadline is the bound
 * now, not this file's).  The hardlink residual is PINNED by the gate
 * (tests/test_hostgate.sh phase 92b).
 *
 * THE NORMALISER: this file carries its own copy of the proxy's fh_canon_abs
 * (tools/fx-hostgate.c) — the SAME lexical resolution — because the judge
 * (ops_judge, in the proxy) classifies the CANONICAL spelling and this
 * program must open the SAME spelling.  The S2 "ONE canonicalizer" property
 * is now "the SAME canonicalizer compiled into the proxy AND the program";
 * the FH_MUTANT_OPS_NO_CANON blind (proxy-side) still exposes the
 * classifier/executor disagreement: the proxy classes the RAW spelling while
 * this program still canonicalizes.
 *
 * FH_MUTANT_NO_PLAINFILE (build/fx-host-cat-noplainfile) compiles the open
 * hardening OUT — a plain O_RDONLY open, exactly as S2 shipped — for the
 * gate's phase-92/93 blind.  The MUTANT PROXY (build/fx-hostgate-noplainfile)
 * names THIS mutant child via -DFH_HOST_CAT_PROGRAM='"fx-host-cat-noplainfile"',
 * so the blind's asymmetry is real (the real proxy spawns the hardened child).
 */
#define _POSIX_C_SOURCE 200809L
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "yyjson.h"

#define FH_HOST_CAT_MAX 256u
#define FH_HOST_PATH_MAX 200u
#define FH_BOUND 512u /* mirrors the proxy's record outcome cap (tools/fx-hostgate.c) */

static void die_errno(const char *what) {
    fprintf(stderr, "fx-host-cat: FATAL: %s: errno=%d\n", what, errno);
    exit(1);
}

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) die_errno("malloc");
    return p;
}

/* Read all of stdin (the args JSON), bounded.  Returns a malloc'd NUL-
 * terminated buffer, or NULL on read error / absurd input. */
static char *read_stdin(void) {
    size_t cap = 4096, len = 0;
    char *buf = xmalloc(cap);
    for (;;) {
        if (len + 4096 > cap) {
            cap *= 2;
            char *nb = realloc(buf, cap);
            if (!nb) { free(buf); return NULL; }
            buf = nb;
        }
        ssize_t n = read(0, buf + len, cap - len - 1);
        if (n < 0) {
            if (errno == EINTR) continue;
            free(buf);
            return NULL;
        }
        if (n == 0) break;
        len += (size_t)n;
    }
    buf[len] = '\0';
    return buf;
}

/* The SAME lexical canonicalization the proxy's ops_judge runs (a copy of
 * fh_canon_abs, tools/fx-hostgate.c): resolve "." and ".." lexically, drop
 * empty components, refuse a ".." that climbs above the root and any
 * non-absolute spelling (returns NULL). */
static char *canon_abs(const char *abs) {
    if (!abs || abs[0] != '/') return NULL;
    size_t cap = strlen(abs) + 2;
    char *out = xmalloc(cap);
    size_t olen = 0;
    int depth = 0;
    const char *p = abs;
    while (*p) {
        while (*p == '/') p++;
        if (!*p) break;
        const char *seg = p;
        while (*p && *p != '/') p++;
        size_t sl = (size_t)(p - seg);
        if (sl == 1 && seg[0] == '.') continue;
        if (sl == 2 && seg[0] == '.' && seg[1] == '.') {
            if (depth == 0) { free(out); return NULL; }
            while (olen > 0 && out[olen - 1] != '/') olen--;
            if (olen > 0) olen--;
            depth--;
            continue;
        }
        if (olen + sl + 2 >= cap) { free(out); return NULL; }
        out[olen++] = '/';
        memcpy(out + olen, seg, sl);
        olen += sl;
        depth++;
    }
    if (olen == 0) out[olen++] = '/';
    out[olen] = '\0';
    return out;
}

/* The "not a plain file" refusal, named once (shared by the O_NOFOLLOW ELOOP
 * and the fstat type check).  The message is byte-pinned by the S2-fix gate
 * (phase 92/93 assert "not a plain file").  Compiled out under
 * FH_MUTANT_NO_PLAINFILE (the blind removes its callers too). */
#ifndef FH_MUTANT_NO_PLAINFILE
static void refuse_not_plain(const char *path) {
    printf("(host_cat: REFUSED to read %s: not a plain file — host_cat reads "
           "regular files only, so a symlink, FIFO, device or directory is "
           "refused BY NAME (the class governs the spelling; the spelling's "
           "resolution must not reach outside it)\n", path);
}
#endif /* !FH_MUTANT_NO_PLAINFILE */

int main(void) {
    char *in = read_stdin();
    if (!in) return 1;
    yyjson_doc *doc = yyjson_read(in, strlen(in), 0);
    free(in);
    yyjson_val *root = doc ? yyjson_doc_get_root(doc) : NULL;
    const char *raw = NULL;
    if (yyjson_is_obj(root)) {
        yyjson_val *pv = yyjson_obj_get(root, "path");
        if (pv) raw = yyjson_get_str(pv);
    }
    char *path = raw ? canon_abs(raw) : NULL;
    if (doc) yyjson_doc_free(doc);
    if (!path) {
        printf("(host_cat: REFUSED — no canonical path was handed to the "
               "executor; this cannot happen on the judged path)\n");
        fflush(stdout);
        return 0;
    }
    size_t plen = strlen(path);
    if (plen > FH_HOST_PATH_MAX) {
        printf("(host_cat: REFUSED — the canonical path is %zu bytes, over "
               "the %u-byte path bound: the result must fit the record's "
               "%u-byte outcome cap, so an over-long path is refused rather "
               "than truncated (the path is not echoed here for the same "
               "reason)\n", plen, FH_HOST_PATH_MAX, FH_BOUND);
        free(path);
        fflush(stdout);
        return 0;
    }
#ifdef FH_MUTANT_NO_PLAINFILE
    int fd = open(path, O_RDONLY);
#else
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
#endif
    if (fd < 0) {
#ifndef FH_MUTANT_NO_PLAINFILE
        if (errno == ELOOP) { refuse_not_plain(path); free(path); fflush(stdout); return 0; }
#endif
        printf("(host_cat: REFUSED to read %s: %s)\n", path, strerror(errno));
        free(path);
        fflush(stdout);
        return 0;
    }
#ifndef FH_MUTANT_NO_PLAINFILE
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        refuse_not_plain(path);
        free(path);
        fflush(stdout);
        return 0;
    }
#endif
    char *buf = xmalloc(FH_HOST_CAT_MAX + 2);
    size_t total = 0;
    for (;;) {
        ssize_t n = read(fd, buf + total, FH_HOST_CAT_MAX + 1 - total);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            free(buf);
            printf("(host_cat: REFUSED to read %s: %s)\n", path, strerror(errno));
            free(path);
            fflush(stdout);
            return 0;
        }
        if (n == 0) break;
        total += (size_t)n;
        if (total > FH_HOST_CAT_MAX) {
            close(fd);
            free(buf);
            printf("(host_cat: REFUSED to read %s: the file exceeds the %u-byte "
                   "bound — refuse, never truncate)\n", path, FH_HOST_CAT_MAX);
            free(path);
            fflush(stdout);
            return 0;
        }
    }
    close(fd);
    if (memchr(buf, '\0', total)) {
        free(buf);
        printf("(host_cat: REFUSED to read %s: the content contains NUL bytes "
               "(it is not text) — refuse, never silently truncate the bytes "
               "after the first NUL\n", path);
        free(path);
        fflush(stdout);
        return 0;
    }
    buf[total] = '\0';
    printf("(host_cat: %s: %s)\n", path, buf);
    free(buf);
    free(path);
    fflush(stdout);
    return 0;
}
