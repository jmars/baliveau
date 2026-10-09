/* tools/fx-osier-share.c — the FIRST ORACLE of the baliveau harness.
 *
 * WHAT IT MEASURES (the decision, already made, restated so the number
 * cannot be silently redefined): CODE SHARE — the fraction of the SOURCE
 * BYTES of the components the ACTIVE GENERATION RUNS that are written in
 * Osier.  Not behaviour share; that needs held-out machinery nobody has
 * built.  "Osier source file" = a file whose name ends in one of the
 * frozen OSIER_EXTS below, and the chosen set PRINTS in this tool's own
 * output — a metric whose definition is invisible cannot be audited.
 *
 * IT READS THE STORE, NOT THE SOURCE TREE.  The run set comes from the
 * ACTIVE GENERATION's own provenance facts (svc_bin / provides / install /
 * srcstore, read as-of the resolved snapshot through `fxstore facts`), so a
 * component the generation builds but never runs cannot inflate the number,
 * and a wrapper whose source is .elm but which execs /bin/sh cannot either
 * (its victim shows up as a run entry with its own source).
 *
 * WHAT COUNTS AS "RUN" (the rule, stated so it cannot be silently
 * redefined): a svc_bin row whose argv[0] is store-relative names its
 * package directly; an ABSOLUTE argv[0] is attributed through the
 * activation's own install facts (target -> the store dir it came from)
 * or, failing that, through a store-prefixed spelling — because a config
 * can install /bin/<tool> from a C-sourced package and run it with
 * pkg=None, and silently dropping such rows removed those packages' bytes
 * from BOTH numerator and denominator (the share was inflatable to 1.0 by
 * config alone).  An absolute argv[0] that NOTHING attributes is
 * UNATTRIBUTABLE — a base-system binary whose source is not in the store:
 * it is counted as non-Osier with ZERO MEASURABLE source bytes (its bytes
 * cannot be measured in the right domain, and a fabricated count would be
 * worse), printed as its own `service ... NONSTORE-UNATTRIBUTED` row and
 * counted in `nonstore_run_unattributed`.  Whenever that count is non-zero
 * the printed fraction is therefore an UPPER BOUND of the Osier share over
 * ALL run components, not an exact fraction — the count is the caveat.
 *
 * THE "CLOSURE" NUMBER IS THE ACTIVE CLOSURE.  closure share is taken over
 * the packages the ACTIVE generation's provides rows name (cleared per
 * activation, so exactly the closure this generation builds), NOT over the
 * srcstore rows (srcstore is append-only and reaps only on name
 * unreachability, so a srcstore-driven closure counts packages a LATER
 * config dropped — store history, not the generation).
 *
 * SRCSTORE IS AMBIGUOUS ON REBUILD, AND THE ORACLE DOES NOT GUESS.  A
 * package whose source changed and was re-activated has SEVERAL live
 * srcstore rows for one name in the CURRENT snapshot; every row is a
 * candidate, narrowed by every independent check available (the -src
 * artifact exists AND hashes back to the candidate), and where more than
 * one candidate survives the tool REFUSES, naming the package and the
 * hashes: a number it cannot justify is worse than no number.  The real
 * fix — a fact binding each derivation hash to the src hash it was folded
 * from, committed by the activation — is recorded in todo.md §3.
 *
 * TWO NUMBERS, never averaged:
 *   (a) run-set share — over the components the generation RUNS.  THE
 *       OBJECTIVE (marked as such in the output).
 *   (b) closure share — over the whole active closure, for comparison
 *       only: (a) alone can be inflated by a thin wrapper; (b) alone is
 *       dead-code inflation.  Print both, let the reader differ.
 *
 * REFUSALS ARE LOAD-BEARING.  Every step before the count is a loud exit 1:
 * a store it cannot read, a version it cannot resolve, a service binary it
 * cannot classify, a run component whose source it cannot produce (no
 * verifying store artifact AND the host tree's clean-hash matches no
 * version-bound srcstore src_hash — an unverified tree is NEVER accepted,
 * including at the store-artifact origin: the artifact's own tree must
 * hash back to the srcstore row that names it).  A store it cannot
 * measure must produce an error, not a 0%.
 *
 * SOURCE CONTENT, in preference order per component:
 *   1. <store>/<src_hash>-<name>-src  — the clean-source artifact fxstore
 *      materializes in the store (fx_store_ensure_source), ACCEPTED ONLY IF
 *      this tool's own walk hashes it back to the src_hash that names it.
 *      Origin "store".
 *   2. the package set's src.path on the host, ACCEPTED ONLY IF this tool's
 *      own recomputation of fxstore's clean-tree hash
 *      (fx_content_hash_dir: sorted name|type|hash entries, u32-BE
 *      length-prefixed names, the global clean-exclude table) equals the
 *      version-bound srcstore src_hash.  Origin "host-verified".
 *      If the hash cannot be reproduced the tree is refused — the recompute
 *      can only cause false REFUSALS, never false acceptances.
 * The origin of every component's bytes is printed; "read from the store"
 * and "read from the host tree" are different claims.
 *
 * Host tool: the guest's i386-musl/stripped rules do NOT apply.  Links the
 * vendored dhall-c (package-set evaluation, the config.c house pattern) and
 * yyjson.  Usage:
 *     fx-osier-share [--store DIR] [--as-of N] [--package-set PATH]
 * --store default /fx/store (fxstore's own default).  --as-of pins the
 * snapshot; the default is the CURRENT one (what the boot runs), resolved
 * from `fxstore timeline`'s [CURRENT] mark.  --package-set is only needed
 * when a component falls back to origin 2.
 */

#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "dhall.h"
#include "yyjson.h"

/* ── the frozen definition ─────────────────────────────────────────────── */

/* The ONE place the extension set is defined.  Single frozen constant; the
 * oracle prints it verbatim on every run.  MEASURED 2026-10: the Osier repo
 * holds 210 .elm sources and no .os or other extension (withe/tools/
 * osier-numbers.sh is its own measurement chain). */
static const char *const OSIER_EXTS[] = { ".elm" };
#define OSIER_NEXTS (sizeof OSIER_EXTS / sizeof OSIER_EXTS[0])

static const char *g_store = "/fx/store";
static const char *g_pkgset = NULL; /* --package-set, lazily loaded */
static unsigned g_asof = 0;         /* 0 = resolve CURRENT */
static int g_have_asof = 0;

/* ── loud failure ──────────────────────────────────────────────────────── */

static void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("fx-osier-share: FAIL: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    exit(1);
}

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) die("out of memory");
    return p;
}

static char *xstrdup(const char *s) {
    char *p = xmalloc(strlen(s) + 1);
    strcpy(p, s);
    return p;
}

/* ── tiny string-pair table (facts rows) ────────────────────────────────── */

/* An INSERTION-ORDER row list: duplicates are KEPT.  srcstore is append-only
 * (fxstore reaps a row only when its NAME becomes unreachable), so ONE name
 * can carry SEVERAL live src hashes in the CURRENT snapshot — a first-wins
 * map would silently pick one, which is exactly the arbitrary pick this tool
 * must not make (see the srcstore refusal below). */
typedef struct {
    char **k, **v;
    size_t n, cap;
} rows_t;

static void rows_add(rows_t *m, const char *k, const char *v) {
    if (m->n == m->cap) {
        m->cap = m->cap ? m->cap * 2 : 16;
        m->k = realloc(m->k, m->cap * sizeof *m->k);
        m->v = realloc(m->v, m->cap * sizeof *m->v);
        if (!m->k || !m->v) die("out of memory");
    }
    m->k[m->n] = xstrdup(k);
    m->v[m->n] = xstrdup(v);
    m->n++;
}

/* First row whose key matches (the old first-wins lookup), or NULL. */
static const char *rows_get(const rows_t *m, const char *k) {
    for (size_t i = 0; i < m->n; i++)
        if (!strcmp(m->k[i], k)) return m->v[i];
    return NULL;
}

/* Every DISTINCT value bound to k, in row order.  Returns the count; a value
 * equal to an already-collected one is skipped (fxstore's facts do not print
 * duplicate rows, but the pair (name, hash) could in principle repeat across
 * snapshots — same value twice is one candidate, not two). */
static size_t rows_get_all(const rows_t *m, const char *k, const char **out, size_t max) {
    size_t n = 0;
    for (size_t i = 0; i < m->n; i++) {
        if (strcmp(m->k[i], k) != 0) continue;
        size_t j;
        for (j = 0; j < n; j++)
            if (!strcmp(out[j], m->v[i])) break;
        if (j == n && n < max) out[n++] = m->v[i];
    }
    return n;
}

/* ── running fxstore (read-only subcommands only) ──────────────────────── */

/* Paths interpolated into a popen'd command: refuse shell metacharacters
 * rather than quote (store/pkgset paths are the caller's own flags). */
static void check_safe_path(const char *p, const char *what) {
    if (!p[0]) die("empty %s path", what);
    for (const char *q = p; *q; q++)
        if (*q == '\'' || *q == '"' || *q == '\\' || *q == ';' ||
            *q == '$' || *q == '`' || strchr(" \t\n", *q))
            die("unsafe character in %s path: %s", what, p);
}

/* Run `fxstore <args...> --store S`, die on non-zero, append each stdout
 * line (chomped) to out as (col1 -> col2), or REVERSED when flip (the
 * oracle looks provides up BY store_dir -> pkg and srcstore BY name ->
 * src_hash; both relations store the lookup key as their SECOND column).
 * fxstore's own stderr passes through to ours.  The binary is $FXSTORE_BIN
 * when set (the gate pins the freshly built one), else PATH's fxstore. */
static void fxstore_lines(const char *args, rows_t *out, int flip, const char *what) {
    check_safe_path(g_store, "--store");
    static char fxcmd[4096];
    if (!fxcmd[0]) {
        const char *fb = getenv("FXSTORE_BIN");
        const char *fx = (fb && *fb) ? fb : "fxstore";
        check_safe_path(fx, "FXSTORE_BIN");
        snprintf(fxcmd, sizeof fxcmd, "'%s'", fx);
    }
    char *cmd;
    if (asprintf(&cmd, "%s %s --as-of %u --store '%s'", fxcmd, args, g_asof, g_store) < 0)
        die("out of memory");
    FILE *p = popen(cmd, "r");
    if (!p) die("cannot popen fxstore (%s)", strerror(errno));
    char line[8192];
    while (fgets(line, sizeof line, p)) {
        size_t l = strlen(line);
        while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        if (!l) continue;
        char *tab = strchr(line, '\t');
        if (!tab) die("%s: fxstore %s produced a line with no tab: %s", what, args, line);
        *tab = 0;
        /* the value is the SECOND column ONLY: install rows are 4-col
         * (target, origin, mode, genhash) and the mode/genhash tail must
         * not ride along in the lookup value */
        char *tab2 = strchr(tab + 1, '\t');
        if (tab2) *tab2 = 0;
        if (flip) rows_add(out, tab + 1, line);
        else rows_add(out, line, tab + 1);
    }
    int rc = pclose(p);
    if (rc != 0)
        die("%s: 'fxstore %s' failed (exit %d)", what, args,
            WIFEXITED(rc) ? WEXITSTATUS(rc) : -1);
    free(cmd);
}

/* ── the version: CURRENT from timeline, or --as-of ────────────────────── */

static unsigned resolve_version(void) {
    /* resolve_version runs BEFORE --as-of is pinned */
    if (g_have_asof) return g_asof;
    check_safe_path(g_store, "--store");
    static char fxcmd[4096];
    if (!fxcmd[0]) {
        const char *fb = getenv("FXSTORE_BIN");
        const char *fx = (fb && *fb) ? fb : "fxstore";
        check_safe_path(fx, "FXSTORE_BIN");
        snprintf(fxcmd, sizeof fxcmd, "'%s'", fx);
    }
    char *cmd;
    if (asprintf(&cmd, "%s timeline --store '%s'", fxcmd, g_store) < 0)
        die("out of memory");
    FILE *p = popen(cmd, "r");
    if (!p) die("cannot popen fxstore timeline (%s)", strerror(errno));
    char line[8192];
    unsigned cur = 0, any = 0;
    while (fgets(line, sizeof line, p)) {
        unsigned v;
        if (sscanf(line, " %u", &v) == 1) {
            any = v;
            if (strstr(line, "[CURRENT]")) cur = v;
        }
    }
    int rc = pclose(p);
    free(cmd);
    if (rc != 0)
        die("'fxstore timeline --store %s' failed (exit %d) — cannot resolve the active generation",
            g_store, WIFEXITED(rc) ? WEXITSTATUS(rc) : -1);
    if (!any) die("store %s has no published snapshot", g_store);
    if (!cur)
        die("store %s marks no CURRENT snapshot (newest is %u) — pass --as-of to pin one",
            g_store, any);
    return cur;
}

/* ── the clean-tree hash (fx_content_hash_dir, ported fail-safe) ───────── */

/* fxstore's global clean-exclude table (derivation.zig fx_clean_excluded),
 * ported verbatim: the fallback tree must hash EXACTLY as fxstore would
 * hash it or the tree is refused. */
static int clean_excluded(const char *basename, int is_dir) {
    if (!strcmp(basename, ".git")) return 1;
    if (is_dir) {
        static const char *dirs[] = { ".cache", "build", "build-tmp", "__pycache__", ".py-site", "pydl" };
        for (size_t i = 0; i < sizeof dirs / sizeof *dirs; i++)
            if (!strcmp(basename, dirs[i])) return 1;
        return !strncmp(basename, "dl-test-", 8);
    }
    static const char *exts[] = { ".o", ".a", ".so", ".com", ".dbg", ".elf", ".wasm" };
    for (size_t i = 0; i < sizeof exts / sizeof *exts; i++) {
        size_t bl = strlen(basename), el = strlen(exts[i]);
        if (bl > el && !strcmp(basename + bl - el, exts[i])) return 1;
    }
    return !strncmp(basename, ".ape-", 5);
}

/* per-package path-prefix excludes (fx_excluded_by_rel): entry matches rel
 * exactly or as a path prefix at a '/' boundary */
static int excluded_by_rel(const char *rel, char **excludes, size_t nex) {
    for (size_t i = 0; i < nex; i++) {
        size_t el = strlen(excludes[i]);
        if (!el) continue;
        if (!strncmp(rel, excludes[i], el) && (rel[el] == 0 || rel[el] == '/')) return 1;
    }
    return 0;
}

typedef struct {
    unsigned long osier_bytes, total_bytes;
    unsigned long osier_files, total_files;
} tally_t;

static void tally_file(tally_t *t, const char *name, unsigned long sz) {
    size_t nl = strlen(name);
    for (size_t i = 0; i < OSIER_NEXTS; i++) {
        size_t el = strlen(OSIER_EXTS[i]);
        if (nl > el && !strcmp(name + nl - el, OSIER_EXTS[i])) {
            t->osier_bytes += sz;
            t->osier_files++;
        }
    }
    t->total_bytes += sz;
    t->total_files++;
}

typedef struct { char *name; int type; char hash[65]; } dent_t;

static int dent_cmp(const void *a, const void *b) {
    return strcmp(((const dent_t *)a)->name, ((const dent_t *)b)->name);
}

/* buf: u32-BE length + bytes (derivation.zig Buf.str) */
static void buf_str(char **b, size_t *bl, size_t *bc, const char *s, size_t n) {
    if (*bc + 4 + n > *bl) {
        *bl = (*bc + 4 + n) * 2;
        *b = realloc(*b, *bl);
        if (!*b) die("out of memory");
    }
    (*b)[(*bc)++] = (char)((n >> 24) & 0xff);
    (*b)[(*bc)++] = (char)((n >> 16) & 0xff);
    (*b)[(*bc)++] = (char)((n >> 8) & 0xff);
    (*b)[(*bc)++] = (char)(n & 0xff);
    memcpy(*b + *bc, s, n);
    *bc += n;
}

static void hash_hex_of(char *data, size_t n, char out[65]) { sha256_hex(data, n, out); }

/* One recursive walk doing BOTH jobs:
 *   - always: tally regular files' bytes by extension into *t
 *   - hash_out != NULL: compute the clean-tree hash (fx_clean_tree_rel
 *     hash-only mode): sorted (u32be name, type, 64-hex) per entry.
 * rel is the path relative to the tree root ("" at root); excludes apply to
 * rel (host trees carry the package's excludes; store artifacts are already
 * clean and pass none).  Returns 0 / -1 with a message. */
static int walk(const char *dir, const char *rel, char **excludes, size_t nex,
                tally_t *t, char hash_out[65], char *err, size_t errsz) {
    DIR *d = opendir(dir);
    if (!d) { snprintf(err, errsz, "cannot open '%s': %s", dir, strerror(errno)); return -1; }
    dent_t *ents = NULL;
    size_t nents = 0, cap = 0;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
        char child[4096], crel[4096];
        if (snprintf(child, sizeof child, "%s/%s", dir, de->d_name) >= (int)sizeof child ||
            snprintf(crel, sizeof crel, "%s%s%s", rel, *rel ? "/" : "", de->d_name) >= (int)sizeof crel) {
            closedir(d); free(ents);
            snprintf(err, errsz, "path too long under %s", dir);
            return -1;
        }
        struct stat st;
        if (lstat(child, &st) != 0) {
            closedir(d); free(ents);
            snprintf(err, errsz, "cannot stat '%s': %s", child, strerror(errno));
            return -1;
        }
        int is_dir = S_ISDIR(st.st_mode);
        if (clean_excluded(de->d_name, is_dir) || excluded_by_rel(crel, excludes, nex)) continue;
        if (nents == cap) {
            cap = cap ? cap * 2 : 16;
            ents = realloc(ents, cap * sizeof *ents);
            if (!ents) die("out of memory");
        }
        dent_t e;
        e.name = xstrdup(de->d_name);
        e.hash[0] = 0;
        if (is_dir) {
            e.type = 'd';
            char sub[65];
            if (walk(child, crel, excludes, nex, t, sub, err, errsz) != 0) {
                closedir(d); free(ents);
                return -1;
            }
            memcpy(e.hash, sub, 65);
        } else if (S_ISLNK(st.st_mode)) {
            e.type = 'l';
            char tgt[4096];
            ssize_t tl = readlink(child, tgt, sizeof tgt - 1);
            if (tl < 0) {
                closedir(d); free(ents);
                snprintf(err, errsz, "readlink '%s': %s", child, strerror(errno));
                return -1;
            }
            tgt[tl] = 0;
            hash_hex_of(tgt, (size_t)tl, e.hash);
        } else if (S_ISREG(st.st_mode)) {
            e.type = 'f';
            FILE *f = fopen(child, "rb");
            if (!f) {
                closedir(d); free(ents);
                snprintf(err, errsz, "cannot open '%s': %s", child, strerror(errno));
                return -1;
            }
            char *data = xmalloc((size_t)st.st_size + 1);
            if (fread(data, 1, (size_t)st.st_size, f) != (size_t)st.st_size) {
                closedir(d); free(ents); fclose(f); free(data);
                snprintf(err, errsz, "short read on '%s'", child);
                return -1;
            }
            fclose(f);
            hash_hex_of(data, (size_t)st.st_size, e.hash);
            free(data);
            /* the metric: regular files only */
            tally_file(t, de->d_name, (unsigned long)st.st_size);
        } else {
            closedir(d); free(ents);
            snprintf(err, errsz, "unsupported special source entry '%s'", child);
            return -1;
        }
        ents[nents++] = e;
    }
    closedir(d);
    if (hash_out) {
        qsort(ents, nents, sizeof *ents, dent_cmp);
        char *b = NULL;
        size_t bl = 0, bc = 0;
        for (size_t i = 0; i < nents; i++) {
            buf_str(&b, &bl, &bc, ents[i].name, strlen(ents[i].name));
            if (bc + 1 > bl) {
                bl = (bc + 1) * 2;
                b = realloc(b, bl);
                if (!b) die("out of memory");
            }
            b[bc++] = (char)ents[i].type;
            /* the hash is written through the same length-prefixed str:
             * u32be(64) + 64 hex bytes (derivation.zig b.str(ent.hash)) */
            buf_str(&b, &bl, &bc, ents[i].hash, 64);
        }
        hash_hex_of(b, bc, hash_out);
        free(b);
    }
    for (size_t i = 0; i < nents; i++) free(ents[i].name);
    free(ents);
    return 0;
}

/* ── the package set (origin-2 fallback only; dhall-c + yyjson) ────────── */

typedef struct {
    char *name;
    char *src_path;   /* ABSOLUTE, resolved against the package-set file */
    char **excludes;
    size_t nex;
} pkg_t;

static pkg_t *g_pkgs = NULL;
static size_t g_npkgs = 0;
static int g_pkgset_loaded = 0;

static char *read_whole(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return NULL; }
    rewind(f);
    char *b = xmalloc((size_t)sz + 1);
    if (fread(b, 1, (size_t)sz, f) != (size_t)sz) { fclose(f); free(b); return NULL; }
    fclose(f);
    b[sz] = 0;
    return b;
}

/* Evaluate a package-set to JSON exactly the way config.c evaluates the
 * runtime config (parse -> normalize -> term_to_json), then walk the
 * packages list.  infer_type is deliberately skipped: the packageset house
 * judgment (packageset.zig's header) is that the structural walk is the
 * source of truth and the typecheck mis-fires on this very file shape.
 * KNOWN LIMIT (MEASURED, dhall-c serialize.c): normalize does not reduce
 * union PROJECTIONS, so a src written `Src.Path "..."` fails term_to_json —
 * loudly.  The shorthand `< Path = "..." >` (what the real m3 package-set
 * uses) serializes fine. */
static void load_pkgset(void) {
    if (g_pkgset_loaded) return;
    g_pkgset_loaded = 1;
    if (!g_pkgset)
        die("a component has no store source artifact and no --package-set was given to verify a host tree against");

    char *src = read_whole(g_pkgset);
    if (!src) die("cannot read package-set '%s': %s", g_pkgset, strerror(errno));

    if (!dhall_arena) dhall_arena = arena_new();
    arena_reset(dhall_arena);
    ImportLoader *loader = import_loader_new();
    import_loader_push_root(loader, NULL);
    Parser p;
    memset(&p, 0, sizeof p);
    p.loader = loader;
    DhallError err;
    dhall_error_clear(&err);
    Term *t = parse_source(&p, src, "<package-set>", &err);
    if (!t) { import_loader_free(loader); die("package-set parse failed"); }
    normalize_clear_error();
    Term *val = normalize(t);
    if (normalize_has_error() || !val) {
        import_loader_free(loader);
        die("package-set normalize failed");
    }
    FILE *jf = tmpfile();
    if (!jf) { import_loader_free(loader); die("tmpfile failed"); }
    if (!term_to_json(jf, val, &err)) {
        import_loader_free(loader); fclose(jf);
        die("package-set to json failed: %s", err.msg[0] ? err.msg : "(no message)");
    }
    fflush(jf);
    rewind(jf);

    /* dirname of the package-set (src paths are relative to its location) */
    char *psdir = xstrdup(g_pkgset);
    char *slash = strrchr(psdir, '/');
    if (slash) *slash = 0;
    else strcpy(psdir, ".");

    yyjson_doc *doc = yyjson_read_fp(jf, 0, NULL, NULL);
    fclose(jf);
    import_loader_free(loader);
    if (!doc) die("package-set json did not re-parse");
    yyjson_val *root = yyjson_doc_get_root(doc);
    yyjson_val *pkgs = yyjson_obj_get(root, "packages");
    if (!pkgs || !yyjson_is_arr(pkgs)) die("package-set json has no packages array");
    g_npkgs = yyjson_arr_size(pkgs);
    g_pkgs = xmalloc(sizeof(pkg_t) * (g_npkgs ? g_npkgs : 1));
    yyjson_val *it;
    size_t idx, mx;
    yyjson_arr_foreach(pkgs, idx, mx, it) {
        const char *nm = yyjson_get_str(yyjson_obj_get(it, "name"));
        pkg_t *P = &g_pkgs[idx];
        memset(P, 0, sizeof *P);
        if (!nm) die("package-set package %zu has no name", idx);
        P->name = xstrdup(nm);
        yyjson_val *s = yyjson_obj_get(it, "src");
        yyjson_val *sp = s ? yyjson_obj_get(s, "Path") : NULL;
        if (sp && yyjson_is_str(sp)) {
            const char *rp = yyjson_get_str(sp);
            char *abs;
            if (rp[0] == '/') {
                abs = xstrdup(rp); /* already absolute */
            } else { /* src paths are relative to the package-set file */
                abs = xmalloc(strlen(psdir) + strlen(rp) + 2);
                sprintf(abs, "%s/%s", psdir, rp);
            }
            P->src_path = abs;
        }
        yyjson_val *ex = yyjson_obj_get(it, "excludes");
        if (ex && yyjson_is_arr(ex)) {
            P->nex = yyjson_arr_size(ex);
            P->excludes = xmalloc(sizeof(char *) * (P->nex ? P->nex : 1));
            yyjson_val *eit;
            size_t eidx, emx;
            yyjson_arr_foreach(ex, eidx, emx, eit) {
                const char *es = yyjson_get_str(eit);
                P->excludes[eidx] = xstrdup(es ? es : "");
            }
        }
    }
    /* the doc owns the strings yyjson points at — we dup'd everything */
    yyjson_doc_free(doc);
    free(psdir);
    free(src);
}

static const pkg_t *pkgset_find(const char *name) {
    load_pkgset();
    for (size_t i = 0; i < g_npkgs; i++)
        if (!strcmp(g_pkgs[i].name, name)) return &g_pkgs[i];
    return NULL;
}

/* ── the measurement ───────────────────────────────────────────────────── */

typedef struct {
    const char *pkg;      /* component name */
    const char *src_hash; /* version-bound srcstore hash */
    const char *origin;   /* store | host-verified */
    tally_t t;
    int resolved;
    int run;
} comp_t;

/* A store dir ("<hash>-<pkg>") -> its package name via provides, or NULL. */
static const char *pkg_of_dir(const rows_t *provides, const char *dir) {
    for (size_t i = 0; i < provides->n; i++)
        if (!strcmp(provides->k[i], dir)) return provides->v[i];
    return NULL;
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--store") && i + 1 < argc) g_store = argv[++i];
        else if (!strncmp(argv[i], "--store=", 8)) g_store = argv[i] + 8;
        else if (!strcmp(argv[i], "--as-of") && i + 1 < argc) { g_asof = (unsigned)strtoul(argv[++i], NULL, 10); g_have_asof = 1; }
        else if (!strncmp(argv[i], "--as-of=", 8)) { g_asof = (unsigned)strtoul(argv[i] + 8, NULL, 10); g_have_asof = 1; }
        else if (!strcmp(argv[i], "--package-set") && i + 1 < argc) g_pkgset = argv[++i];
        else if (!strncmp(argv[i], "--package-set=", 14)) g_pkgset = argv[i] + 14;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("usage: fx-osier-share [--store DIR] [--as-of N] [--package-set PATH]\n");
            return 0;
        } else {
            fprintf(stderr, "fx-osier-share: unknown arg '%s'\n", argv[i]);
            return 2;
        }
    }
    if (g_have_asof && g_asof == 0) die("--as-of must be >= 1");
    check_safe_path(g_store, "--store");

    unsigned ver = resolve_version();
    if (!g_have_asof) g_asof = ver; /* fxstore_lines pins --as-of */

    /* step 2-3: the facts of the ACTIVE GENERATION (version-bound).
     * provides rows are (pkg, store_dir) and srcstore rows are (src_hash,
     * name) — both flipped here so the lookups key on what the oracle
     * actually has in hand (a store_dir prefix from svc_bin; a pkg name).
     * install rows are (target, origin, mode, genhash): the first two name
     * every rootfs path the activation materialized and the store dir it
     * came FROM — the classification an absolute argv[0] needs. */
    rows_t provides = { 0 }, svcbin = { 0 }, srcstore = { 0 }, install = { 0 };
    fxstore_lines("facts provides", &provides, 1, "run set");
    fxstore_lines("facts svc_bin", &svcbin, 0, "run set");
    fxstore_lines("facts srcstore", &srcstore, 1, "closure set");
    fxstore_lines("facts install", &install, 0, "run set");

    /* Resolve a store dir ("<hash>-<pkg>") to its package name via
     * provides, or NULL when no provides row carries it. */
    /* every service row is PRINTED; classification refuses to guess */
    typedef struct { const char *svc, *bin, *pkg; int nonstore; } runs_t;
    runs_t *runs = xmalloc(sizeof(runs_t) * (svcbin.n ? svcbin.n : 1));
    size_t nruns = 0, nnonstore = 0, nunattr = 0;
    /* sized for the WORST case (every provides row + every distinct run
     * pkg, including run pkgs with no srcstore row — those must reach the
     * per-component stage so the missing-srcstore refusal can fire, never
     * be silently dropped) */
    comp_t *comps = xmalloc(sizeof(comp_t) * (provides.n + svcbin.n + 1));
    size_t ncomps = 0;

    for (size_t i = 0; i < svcbin.n; i++) {
        const char *svc = svcbin.k[i], *bin = svcbin.v[i];
        const char *slash = strchr(bin, '/');
        const char *pkg = NULL;
        int nonstore = 0;
        if (slash && slash != bin && bin[0] != '/') {
            size_t pl = (size_t)(slash - bin);
            char *pref = xmalloc(pl + 1);
            memcpy(pref, bin, pl);
            pref[pl] = 0;
            /* a pkg'd service records <hash>-<pkg>/<basename>; the prefix
             * MUST be a provides store_dir or the row is unclassifiable */
            for (size_t j = 0; j < provides.n; j++)
                if (!strcmp(provides.k[j], pref)) { pkg = provides.v[j]; break; }
            if (!pkg)
                die("service '%s' runs '%s' whose store prefix '%s' matches no provides row — cannot classify (as-of %u)",
                    svc, bin, pref, ver);
            free(pref);
        } else if (bin[0] == '/') {
            /* An ABSOLUTE argv[0] is NOT automatically outside the store.
             * A non-pkg'd service records argv[0] verbatim — and that path
             * can be (a) an INSTALL TARGET: the activation's own install
             * facts name every /bin link and the store dir it came from,
             * and a config can install /bin/<tool> from a C-sourced package
             * and run it with pkg=None, so dropping absolute paths silently
             * removed those packages' bytes from the run set and the share
             * was inflatable to 1.0 by config alone; or (b) a STORE path
             * spelled absolutely (<store>/<hash>-<pkg>/...).  Both are
             * resolved to their package FIRST.  Only what NOTHING
             * attributes is non-store — a base-system binary whose source
             * is not in the store at all — and it must be VISIBLE, never
             * silently dropped. */
            const char *org = rows_get(&install, bin);
            if (org) {
                /* refuse to guess between two origins for one target: the
                 * config built two packages with the same /bin basename and
                 * the rootfs link is ill-defined — a number read through
                 * either pick would be a guess */
                const char *alt = NULL;
                for (size_t j = 0; j < install.n; j++)
                    if (!strcmp(install.k[j], bin) &&
                        strcmp(install.v[j], org) != 0) { alt = install.v[j]; break; }
                if (alt)
                    die("service '%s' runs '%s' but the install facts bind that target to TWO store dirs ('%s' and '%s') — cannot attribute it to one package (as-of %u)",
                        svc, bin, org, alt, ver);
                pkg = pkg_of_dir(&provides, org);
                if (!pkg)
                    die("service '%s' runs '%s', install names origin '%s', but no provides row carries that store dir — cannot classify (as-of %u)",
                        svc, bin, org, ver);
            } else {
                size_t sl = strlen(g_store);
                if (strncmp(bin, g_store, sl) == 0 && bin[sl] == '/') {
                    const char *rest = bin + sl + 1;
                    const char *s2 = strchr(rest, '/');
                    if (s2 && s2 != rest) {
                        size_t pl = (size_t)(s2 - rest);
                        char *pref = xmalloc(pl + 1);
                        memcpy(pref, rest, pl);
                        pref[pl] = 0;
                        pkg = pkg_of_dir(&provides, pref);
                        free(pref);
                    }
                }
            }
            if (!pkg) {
                /* UNATTRIBUTABLE: counted as non-Osier with ZERO measurable
                 * source bytes (its source is not in the store; stat-ing a
                 * host binary would measure the wrong domain).  The row is
                 * PRINTED and counted, so the fraction is auditable as an
                 * UPPER BOUND whenever such entries exist — see the header. */
                nonstore = 2;
                nnonstore++;
                nunattr++;
            }
        } else {
            die("service '%s' records binary '%s' in neither store-relative nor absolute form — cannot classify", svc, bin);
        }
        runs[nruns++] = (runs_t){ svc, bin, pkg, nonstore };
        if (pkg) {
            size_t j;
            for (j = 0; j < ncomps; j++)
                if (!strcmp(comps[j].pkg, pkg)) { comps[j].run = 1; break; }
            if (j == ncomps) {
                memset(&comps[ncomps], 0, sizeof comps[ncomps]);
                comps[ncomps].pkg = pkg;
                comps[ncomps].run = 1;
                ncomps++;
            }
        }
    }
    /* closure-only components: every package the ACTIVE closure provides
     * that no service runs.  provides is cleared per activation, so it IS
     * the active generation's closure; srcstore is NOT (it is append-only,
     * reaped only when a NAME becomes unreachable), so a srcstore-driven
     * "closure" would keep counting packages a LATER config dropped — store
     * history, not the generation. */
    for (size_t i = 0; i < provides.n; i++) {
        size_t j;
        for (j = 0; j < ncomps; j++)
            if (!strcmp(comps[j].pkg, provides.v[i])) break;
        if (j == ncomps) {
            memset(&comps[ncomps], 0, sizeof comps[ncomps]);
            comps[ncomps].pkg = provides.v[i];
            comps[ncomps].run = 0;
            ncomps++;
        }
    }

    /* step 4: source content per component — every live srcstore row for
     * the name is a CANDIDATE, narrowed by every independent check this
     * tool has, and a survivor set larger than one is a LOUD refusal: the
     * store cannot attribute one src hash to this generation, and a number
     * read through an arbitrary pick would not be the quantity the label
     * names.  (srcstore is append-only and its rows are reaped only when
     * the NAME becomes unreachable, so a package whose source changed and
     * was re-activated genuinely has two live rows.  The real fix is a
     * fact binding each derivation hash to the src hash it was folded
     * from, committed by the activation — recorded in todo.md §3; it is
     * another repo's change.) */
    /* >= PATH_MAX + message + strerror so snprintf never truncates */
    char err[8192];
    for (size_t i = 0; i < ncomps; i++) {
        comp_t *c = &comps[i];
        const char *cand[64];
        size_t ncand = rows_get_all(&srcstore, c->pkg, cand, 64);
        if (ncand == 0) {
            if (c->run)
                die("RUN component '%s' has no srcstore row as-of version %u — cannot classify its source", c->pkg, ver);
            c->resolved = 0; /* closure-only: reported unresolved, not fatal */
            continue;
        }
        if (ncand == 64)
            die("component '%s' has 64+ live srcstore rows as-of version %u — refusing to enumerate", c->pkg, ver);
        /* origin 1: the store's own clean-source artifact.  A candidate
         * SURVIVES only if the artifact exists AND this tool's own walk
         * hashes it back to the candidate hash — an unverified tree is
         * never accepted, here at the PRIMARY origin too (the artifact is
         * not guest-writable, but a corrupted or misnamed -src dir must
         * die loudly, not tally silently). */
        const char *surv[64];
        tally_t survt[64];
        size_t nsurv = 0;
        for (size_t j = 0; j < ncand; j++) {
            char art[4096];
            if (snprintf(art, sizeof art, "%s/%s-%s-src", g_store, cand[j], c->pkg) >= (int)sizeof art)
                die("store artifact path too long for %s", c->pkg);
            struct stat st;
            if (stat(art, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
            tally_t t;
            memset(&t, 0, sizeof t);
            char h[65];
            if (walk(art, "", NULL, 0, &t, h, err, sizeof err) != 0)
                die("component '%s': walking store artifact %s: %s", c->pkg, art, err);
            if (strcmp(h, cand[j]) != 0) continue; /* exists but does not verify */
            surv[nsurv] = cand[j];
            survt[nsurv] = t;
            nsurv++;
        }
        if (nsurv > 1) {
            /* name every surviving candidate: the operator must see exactly
             * what the store failed to decide */
            char names[64 * 71];
            size_t nl = 0;
            for (size_t j = 0; j < nsurv; j++)
                nl += (size_t)snprintf(names + nl, sizeof names - nl, "%s%s",
                                       j ? ", " : "", surv[j]);
            die("component '%s': srcstore binds %zu live src hashes as-of version %u and %zu of them VERIFY against their store artifacts (%s) — the store cannot attribute this generation's source to one of them; refusing rather than guessing (the fix is a derivation->src fact committed at activation; todo.md §3)",
                c->pkg, ncand, ver, nsurv, names);
        }
        if (nsurv == 1) {
            c->src_hash = surv[0];
            c->t = survt[0];
            c->origin = "store";
            c->resolved = 1;
            continue;
        }
        /* origin 2: the host tree, accepted ONLY on hash equality with a
         * candidate — the recompute can only cause false REFUSALS, never
         * false acceptances. */
        const pkg_t *P = pkgset_find(c->pkg);
        if (!P || !P->src_path)
            die("component '%s': no verifying store artifact and no package-set src.path to verify against (as-of %u)", c->pkg, ver);
        tally_t t;
        memset(&t, 0, sizeof t);
        char h[65];
        if (walk(P->src_path, "", P->excludes, P->nex, &t, h, err, sizeof err) != 0)
            die("component '%s': walking host tree %s: %s", c->pkg, P->src_path, err);
        size_t match = 0;
        for (size_t j = 0; j < ncand; j++)
            if (strcmp(h, cand[j]) == 0) { match = j + 1; break; }
        if (!match) {
            if (c->run)
                die("component '%s': host tree %s clean-hashes to %s but version %u's srcstore candidates do not include it — unverified tree refused",
                    c->pkg, P->src_path, h, ver);
            c->resolved = 0;
            continue;
        }
        c->src_hash = cand[match - 1];
        c->t = t;
        c->origin = "host-verified";
        c->resolved = 1;
    }

    /* step 5: the numbers — both, printed separately, never averaged */
    tally_t ra = { 0, 0, 0, 0 }, cl = { 0, 0, 0, 0 };
    size_t run_n = 0, cl_res = 0;
    for (size_t i = 0; i < ncomps; i++) {
        comp_t *c = &comps[i];
        if (c->resolved) {
            cl.osier_bytes += c->t.osier_bytes;
            cl.total_bytes += c->t.total_bytes;
            cl.osier_files += c->t.osier_files;
            cl.total_files += c->t.total_files;
            cl_res++;
        }
        if (c->run && c->resolved) {
            ra.osier_bytes += c->t.osier_bytes;
            ra.total_bytes += c->t.total_bytes;
            ra.osier_files += c->t.osier_files;
            ra.total_files += c->t.total_files;
            run_n++;
        }
    }

    /* output: stable `key value...` lines, one field set per line; '#' is a
     * comment.  The DEFINITION prints on every run. */
    printf("metric osier-share\n");
    printf("store %s\n", g_store);
    printf("snapshot %u\n", ver);
    fputs("osier_extensions", stdout);
    for (size_t i = 0; i < OSIER_NEXTS; i++) printf(" %s", OSIER_EXTS[i]);
    putchar('\n');
    printf("counted regular source files only (clean-tree exclusion rules apply)\n");
    printf("objective run_set_share_fraction\n");
    printf("services %zu store_components_run %zu nonstore_run %zu nonstore_run_unattributed %zu\n",
           nruns, run_n, nnonstore, nunattr);
    for (size_t i = 0; i < nruns; i++)
        printf("service %s %s %s\n", runs[i].svc, runs[i].bin,
               runs[i].nonstore ? "NONSTORE-UNATTRIBUTED" : runs[i].pkg);
    for (size_t i = 0; i < ncomps; i++) {
        comp_t *c = &comps[i];
        if (!c->resolved) {
            printf("component %s %s unresolved %s\n", c->pkg,
                   c->src_hash ? c->src_hash : "-", c->run ? "RUN" : "closure-only");
            continue;
        }
        printf("component %s %s %s %lu %lu %lu %lu %s\n", c->pkg, c->src_hash, c->origin,
               c->t.osier_bytes, c->t.total_bytes, c->t.osier_files, c->t.total_files,
               c->run ? "run" : "closure-only");
    }
    printf("run_set_osier_bytes %lu\n", ra.osier_bytes);
    printf("run_set_total_bytes %lu\n", ra.total_bytes);
    printf("run_set_osier_files %lu\n", ra.osier_files);
    printf("run_set_total_files %lu\n", ra.total_files);
    printf("run_set_share_fraction %.6f\n",
           ra.total_bytes ? (double)ra.osier_bytes / (double)ra.total_bytes : 0.0);
    printf("closure_osier_bytes %lu\n", cl.osier_bytes);
    printf("closure_total_bytes %lu\n", cl.total_bytes);
    printf("closure_osier_files %lu\n", cl.osier_files);
    printf("closure_total_files %lu\n", cl.total_files);
    printf("closure_share_fraction %.6f\n",
           cl.total_bytes ? (double)cl.osier_bytes / (double)cl.total_bytes : 0.0);
    printf("closure_components_resolved %zu of %zu\n", cl_res, ncomps);
    return 0;
}
