/* tests/fixtures/host_cat_sibling.c — the S2 sibling-path ESCAPE PROBE.
 *
 * A MUTANT host_cat that reads a DIFFERENT file than the judged path: it
 * reads the judged path's SIBLING (the judged path with ".sibling" appended).
 * The S2 sandbox unveils EXACTLY the per-call judged path `:r` and nothing
 * else, so this mutant's open of the sibling must fail EACCES inside the
 * sandbox — and must succeed through the PRE-S2 proxy (host_cat unsandboxed,
 * floor NULL), which is the asymmetry the gate asserts.
 *
 * The mutant is named in place of the real fx-host-cat via the proxy's
 * -DFH_HOST_CAT_PROGRAM override (the same same-source discipline as the
 * S1 host_time escape probes).  It is a GATE FIXTURE, never a product binary.
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
#include <unistd.h>

#include "yyjson.h"

#define FH_HOST_CAT_MAX 256u

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) exit(1);
    return p;
}

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
 * fh_canon_abs), so the sibling is computed from the canonical judged path. */
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
        printf("(host_cat_sibling: no canonical path)\n");
        fflush(stdout);
        return 0;
    }
    /* the ESCAPE: read the SIBLING, not the judged path. */
    size_t plen = strlen(path);
    char *sibling = xmalloc(plen + strlen(".sibling") + 1);
    memcpy(sibling, path, plen);
    memcpy(sibling + plen, ".sibling", strlen(".sibling") + 1);
    int fd = open(sibling, O_RDONLY);
    if (fd < 0) {
        if (errno == EACCES) {
            printf("SIBLING-DENIED: Permission denied\n");
        } else {
            printf("SIBLING-OPEN-FAILED: %s\n", strerror(errno));
        }
        free(path); free(sibling);
        fflush(stdout);
        return 0;
    }
    char *buf = xmalloc(FH_HOST_CAT_MAX + 2);
    size_t total = 0;
    for (;;) {
        ssize_t n = read(fd, buf + total, FH_HOST_CAT_MAX + 1 - total);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd); free(buf);
            printf("SIBLING-READ-FAILED: %s\n", strerror(errno));
            free(path); free(sibling);
            fflush(stdout);
            return 0;
        }
        if (n == 0) break;
        total += (size_t)n;
        if (total > FH_HOST_CAT_MAX) break;
    }
    close(fd);
    buf[total] = '\0';
    printf("SIBLING-READ: %s\n", buf);
    free(buf);
    free(path);
    free(sibling);
    fflush(stdout);
    return 0;
}
