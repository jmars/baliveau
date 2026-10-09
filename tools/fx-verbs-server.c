/* tools/fx-verbs-server.c — the fx-linux system verbs as an MCP stdio tool
 * server.
 *
 * A newline-delimited JSON-RPC 2.0 MCP server in the shape of vibe-runtime's
 * tests/mcp_echo_server.c (initialize -> notifications/initialized ->
 * tools/list -> tools/call, plus ping), driven by fx-harness's
 * src/llm2/mcp_client.c: fork+execvpe'd over stdio, id-matched replies,
 * bounded newline frames.  The whole verb surface is ONE table of rows
 * {name, argv template, description}:
 *
 *   fx_query         fxctl q <relation>   live datalog relations (generation,
 *                                         svc, svc_argv, install, provides,
 *                                         user, log)
 *   fx_status        fxctl status
 *   fx_activate      fx-activate <config>  the RUNNING ROOT's own activator
 *                                         (/bin/fx-activate, the binary PID1's
 *                                         activate handler execs) with the
 *                                         guest's persistent store + frozen
 *                                         package set.  NOT `fxctl activate`:
 *                                         fxctl has no transport in the guest
 *                                         (no socket layer; the virtio port's
 *                                         single input queue belongs to PID1).
 *   fx_rollback      fxctl rollback <version>
 *   fx_what          fxstore what <target>    provenance proof tree for an
 *                                             installed path
 *   fx_why           fxstore why <package>    closure + provided targets +
 *                                             pulling roots
 *   fx_store_verify  fxstore verify           reconcile the rootfs against the
 *                                             install facts; EXIT 1 ON DRIFT
 *   fx_read          read a file              (native: open/read under the root)
 *   fx_write         write a file             (native: open/write under the root)
 *   fx_ls            list a directory         (native: opendir under the root)
 *
 * ROOT RESOLUTION — never a hardcoded absolute path: every command is looked
 * up under FX_VERB_ROOT (env, read at call time so tests can set it; default
 * "/"): first <ROOT>/usr/fx-core/bin (where the fx-init payload stages fxsh +
 * the fx-* set), then <ROOT>/fx/store/bin (the store bin dir).  The file verbs
 * prefix paths with the same root, so the identical binary runs against a stub
 * root on the host (FX_VERB_ROOT=/tmp/stub) and against the real guest rootfs
 * (unset).
 *
 * EXEC RULES — fork + execvpe with an EXPLICIT whitelist env (the
 * secrets.c scrub-and-inject shape): PATH (rooted), FX_ROOT, FX_STORE, plus
 * HOME/LANG/LC_ALL/TZ/TERM/XDG_RUNTIME_DIR forwarded when present.  Everything
 * else — RATTAN_*, LD_*, and any other inherited key — is dropped by
 * construction.  NO shell, NO system(3), NO popen(3) (the guest has no
 * /bin/sh), and NO sockets anywhere (CONFIG_NET is unset; socket(2) is
 * ENOSYS).  The verb's stdin is /dev/null so a verb that reads stdin cannot
 * steal MCP frames.
 *
 * EXIT-CODE REPORTING — every tools/call reply text begins with "exit=<n>"
 * followed by the verb's stdout+stderr.  isError is NEVER set:
 * mcp_client.c:437-441 drops isError results entirely (returns -1, text
 * lost), so the model would never see fx_store_verify's drift report — the
 * exit line IS the drift gate.
 *
 * BOUNDS — request lines and captured verb output are capped at FXV_MAX_LINE,
 * the same 1 MiB cap the client enforces (MCP_MAX_LINE,
 * src/llm2/mcp_client.h).  Every JSON frame is parsed AND built with the
 * vendored yyjson — no sprintf'd JSON anywhere.
 *
 * Exit code: 0 on clean EOF on stdin; -1 on a stdin read error.
 */
#define _GNU_SOURCE  /* execvpe */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "yyjson.h"

extern char **environ; /* the server's own environment (pass-through source) */

/* Must match MCP_PROTOCOL_VERSION (src/mcp_stdio.h) — the client rejects a
 * failed/absent initialize result outright. */
#define FXV_PROTOCOL_VERSION "2025-06-18"
#define FXV_SERVER_NAME      "fx-verbs"
#define FXV_SERVER_VERSION   "0.1.0"

/* Line/output cap — SAME value the client enforces (MCP_MAX_LINE,
 * src/llm2/mcp_client.h). */
#define FXV_MAX_LINE (1024u * 1024u)

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/* ── the root ───────────────────────────────────────────────────────────── */

/* FX_VERB_ROOT: the filesystem root prefix every command lookup and file path
 * resolves under.  Read at call time so tests can set it per spawn. */
static const char *fx_root(void) {
    const char *r = getenv("FX_VERB_ROOT");
    return (r && *r) ? r : "/";
}

/* root_join: "<root>/<rel>" without a doubled slash.  Returns a malloc'd path
 * or NULL on OOM / overflow. */
static char *root_join(const char *rel) {
    const char *root = fx_root();
    size_t rl = strlen(root);
    while (rl > 0 && root[rl - 1] == '/') rl--; /* keep at most one slash */
    size_t llen = strlen(rel);
    if (llen > 0 && rel[0] == '/') { rel++; llen--; }
    if (rl + 1 + llen > PATH_MAX) return NULL;
    char *out = malloc(rl + 1 + llen + 1);
    if (!out) return NULL;
    memcpy(out, root, rl);
    out[rl] = '/';
    memcpy(out + rl + 1, rel, llen);
    out[rl + 1 + llen] = '\0';
    return out;
}

/* Look a verb command up under the root: first <ROOT>/usr/fx-core/bin (where
 * fx-init stages fxsh + the fx-* set), then <ROOT>/fx/store/bin (the store
 * bin dir), then <ROOT>/bin — the RUNNING root's bin dir, where the
 * activation materializes one symlink per tool + service package into the
 * store (`activate.zig` collect /bin symlinks: init, fxctl, dhake,
 * fx-activate, fxstore for a pkg that declares it).  Without "bin" the verbs
 * that only exist there (notably /bin/fx-activate, which is the binary
 * fx-init's OWN activate handler execs) resolve to nothing in the guest.
 * Returns a malloc'd absolute path, or NULL when nothing executable matches. */
static char *resolve_command(const char *cmd) {
    static const char *const DIRS[] = {
        "usr/fx-core/bin",
        "fx/store/bin",
        "bin",
    };
    for (size_t i = 0; i < sizeof(DIRS) / sizeof(DIRS[0]); i++) {
        char *dir = root_join(DIRS[i]);
        if (!dir) return NULL;
        size_t dl = strlen(dir);
        char *path = malloc(dl + 1 + strlen(cmd) + 1);
        if (!path) { free(dir); return NULL; }
        memcpy(path, dir, dl);
        path[dl] = '/';
        strcpy(path + dl + 1, cmd);
        free(dir);
        if (access(path, X_OK) == 0) return path;
        free(path);
    }
    return NULL;
}

/* ── the child env (whitelist scrub) ────────────────────────────────────── */

/* Build the verb child's envp as an explicit whitelist — the same
 * scrub-and-inject shape as secrets_build_child_env / mcp_client's child:
 * only the keys the verbs need, never the server's full environment.
 * RATTAN_*, LD_* and every other inherited key are dropped by construction.
 * Returns a malloc'd NULL-terminated array of malloc'd "K=V" strings. */
static char **build_verb_envp(void) {
    const char *root = fx_root();
    char *bin1 = root_join("usr/fx-core/bin");
    char *bin2 = root_join("fx/store/bin");
    if (!bin1 || !bin2) { free(bin1); free(bin2); return NULL; }

    char path[4 * PATH_MAX];
    snprintf(path, sizeof(path), "%s:%s:/bin:/usr/bin", bin1, bin2);
    free(bin1);
    free(bin2);

    char *entries[10];
    size_t n = 0;
    char buf[4 * PATH_MAX];
    bool ok = true;

    /* keyed entries first: duplicates resolve first-match-wins via getenv */
    ok = ok && snprintf(buf, sizeof(buf), "PATH=%s", path) > 0
         && (entries[n++] = strdup(buf)) != NULL;
    ok = ok && snprintf(buf, sizeof(buf), "FX_ROOT=%s", root) > 0
         && (entries[n++] = strdup(buf)) != NULL;
    char *store = root_join("fx/store");
    ok = ok && store && snprintf(buf, sizeof(buf), "FX_STORE=%s", store) > 0
         && (entries[n++] = strdup(buf)) != NULL;
    free(store);

    /* forwarded when present (same list secrets.c forwards) */
    static const char *const FWD[] = { "HOME", "LANG", "LC_ALL", "TZ", "TERM",
                                       "XDG_RUNTIME_DIR" };
    for (size_t i = 0; ok && i < sizeof(FWD) / sizeof(FWD[0]); i++) {
        const char *v = getenv(FWD[i]);
        if (!v || !*v) continue;
        size_t need = strlen(FWD[i]) + 1 + strlen(v) + 1;
        char *e = malloc(need);
        ok = ok && e && snprintf(e, need, "%s=%s", FWD[i], v) > 0;
        entries[n++] = e;
    }
    if (!ok) {
        for (size_t i = 0; i < n; i++) free(entries[i]);
        return NULL;
    }

    char **envp = malloc((n + 1) * sizeof(char *));
    if (!envp) { for (size_t i = 0; i < n; i++) free(entries[i]); return NULL; }
    for (size_t i = 0; i < n; i++) envp[i] = entries[i];
    envp[n] = NULL;
    return envp;
}

static void envp_free(char **envp) {
    if (!envp) return;
    for (size_t i = 0; envp[i]; i++) free(envp[i]);
    free(envp);
}

/* ── bounded capture ────────────────────────────────────────────────────── */

typedef struct {
    char *data;
    size_t len;
    bool trunc; /* hit FXV_MAX_LINE and dropped the rest */
} Capture;

static bool cap_append(Capture *c, const char *bytes, size_t n) {
    if (c->trunc) return true; /* keep absorbing, drop bytes */
    if (c->len + n > FXV_MAX_LINE) {
        size_t room = FXV_MAX_LINE - c->len;
        memcpy(c->data + c->len, bytes, room);
        c->len = FXV_MAX_LINE;
        c->trunc = true;
        return true;
    }
    memcpy(c->data + c->len, bytes, n);
    c->len += n;
    return true;
}

static bool cap_append_str(Capture *c, const char *s) {
    return cap_append(c, s, strlen(s));
}

static bool cap_init(Capture *c) {
    c->data = malloc(FXV_MAX_LINE + 1);
    c->len = 0;
    c->trunc = false;
    return c->data != NULL;
}

static void cap_free(Capture *c) { free(c->data); c->data = NULL; c->len = 0; }

/* Cut at the first NUL and note it — the client joins text with strlen, so
 * bytes after a NUL would be silently lost there; the note makes the loss
 * explicit in the text the model sees. */
static void cap_cut_at_nul(Capture *c) {
    char *nul = c->data ? memchr(c->data, '\0', c->len) : NULL;
    if (!nul) return;
    size_t off = (size_t)(nul - c->data);
    char note[96];
    int nn = snprintf(note, sizeof(note),
                      "\n[fx-verbs: NUL byte at output offset %zu; "
                      "content after it dropped]\n", off);
    if (nn < 0) return;
    c->len = off;
    cap_append(c, note, (size_t)nn);
}

/* ── exec verbs ─────────────────────────────────────────────────────────── */

/* Read the verb's stdout+stderr (both dup2'd onto one pipe) to EOF, bounded
 * by FXV_MAX_LINE. */
static void capture_fd(int fd, Capture *c) {
    char tmp[4096];
    for (;;) {
        ssize_t n = read(fd, tmp, sizeof(tmp));
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (n == 0) break;
        cap_append(c, tmp, (size_t)n);
    }
}

/* fork + execvpe argv[0] with the whitelist env; capture stdout+stderr; reap.
 * Returns 0 with *exitcode set (127 on exec failure, 128+sig on a signal). */
static int run_verb(char **argv, Capture *out, int *exitcode) {
    char **envp = build_verb_envp();
    if (!envp) return -1;

    int pfd[2];
    if (pipe(pfd) != 0) { envp_free(envp); return -1; }
    int devnull = open("/dev/null", O_RDONLY); /* the verb's stdin */

    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    if (pid < 0) {
        close(pfd[0]); close(pfd[1]);
        if (devnull >= 0) close(devnull);
        envp_free(envp);
        return -1;
    }
    if (pid == 0) {
        /* child: stdin /dev/null (a verb reading stdin must not steal MCP
         * frames), stdout+stderr both onto the capture pipe. */
        if (devnull >= 0) { dup2(devnull, 0); close(devnull); }
        dup2(pfd[1], 1);
        dup2(pfd[1], 2);
        close(pfd[0]);
        close(pfd[1]);
        execvpe(argv[0], argv, envp);
        /* exec failed: say why on the capture pipe, then 127 */
        char msg[PATH_MAX + 128];
        int n = snprintf(msg, sizeof(msg), "fx-verbs: cannot exec %s: %s\n",
                         argv[0], strerror(errno));
        if (n > 0) {
            ssize_t wr = write(2, msg, (size_t)n);
            (void)wr;
        }
        _exit(127);
    }
    close(pfd[1]);
    if (devnull >= 0) close(devnull);
    envp_free(envp);

    capture_fd(pfd[0], out);
    close(pfd[0]);

    int st = 0;
    pid_t w;
    do {
        w = waitpid(pid, &st, 0);
    } while (w < 0 && errno == EINTR);
    if (w == pid && WIFEXITED(st)) *exitcode = WEXITSTATUS(st);
    else if (w == pid && WIFSIGNALED(st)) *exitcode = 128 + WTERMSIG(st);
    else *exitcode = 127;
    return 0;
}

/* ── native file verbs (no external command; the guest has no shell) ────── */

static int native_read(const char *path, Capture *out, int *exitcode) {
    char *full = root_join(path);
    if (!full) { cap_append_str(out, "fx-verbs: path too long\n"); *exitcode = 1; return 0; }
    int fd = open(full, O_RDONLY);
    if (fd < 0) {
        char msg[PATH_MAX + 128];
        snprintf(msg, sizeof(msg), "fx-verbs: cannot open %s: %s\n",
                 full, strerror(errno));
        cap_append_str(out, msg);
        *exitcode = 1;
        free(full);
        return 0;
    }
    free(full);
    char tmp[8192];
    for (;;) {
        ssize_t n = read(fd, tmp, sizeof(tmp));
        if (n < 0) {
            if (errno == EINTR) continue;
            char msg[256];
            snprintf(msg, sizeof(msg), "fx-verbs: read failed: %s\n",
                     strerror(errno));
            cap_append_str(out, msg);
            *exitcode = 1;
            break;
        }
        if (n == 0) { close(fd); *exitcode = 0; return 0; }
        cap_append(out, tmp, (size_t)n);
    }
    close(fd);
    return 0;
}

static int native_write(const char *path, const char *content, size_t clen,
                        Capture *out, int *exitcode) {
    char *full = root_join(path);
    if (!full) { cap_append_str(out, "fx-verbs: path too long\n"); *exitcode = 1; return 0; }
    int fd = open(full, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        char msg[PATH_MAX + 128];
        snprintf(msg, sizeof(msg), "fx-verbs: cannot create %s: %s\n",
                 full, strerror(errno));
        cap_append_str(out, msg);
        *exitcode = 1;
        free(full);
        return 0;
    }
    size_t off = 0;
    while (off < clen) {
        ssize_t n = write(fd, content + off, clen - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            char msg[PATH_MAX + 128];
            snprintf(msg, sizeof(msg), "fx-verbs: write to %s failed: %s\n",
                     full, strerror(errno));
            cap_append_str(out, msg);
            *exitcode = 1;
            close(fd);
            free(full);
            return 0;
        }
        off += (size_t)n;
    }
    if (close(fd) != 0) {
        char msg[PATH_MAX + 128];
        snprintf(msg, sizeof(msg), "fx-verbs: close %s failed: %s\n",
                 full, strerror(errno));
        cap_append_str(out, msg);
        *exitcode = 1;
        free(full);
        return 0;
    }
    char msg[PATH_MAX + 64];
    snprintf(msg, sizeof(msg), "wrote %zu bytes to %s\n", clen, full);
    cap_append_str(out, msg);
    *exitcode = 0;
    free(full);
    return 0;
}

static int name_cmp(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static int native_ls(const char *path, Capture *out, int *exitcode) {
    char *full = root_join(path);
    if (!full) { cap_append_str(out, "fx-verbs: path too long\n"); *exitcode = 1; return 0; }
    DIR *d = opendir(full);
    if (!d) {
        char msg[PATH_MAX + 128];
        snprintf(msg, sizeof(msg), "fx-verbs: cannot list %s: %s\n",
                 full, strerror(errno));
        cap_append_str(out, msg);
        *exitcode = 1;
        free(full);
        return 0;
    }
    /* collect, sort, emit (one entry per line, dirs suffixed '/') */
    size_t n = 0, cap = 64;
    char **names = malloc(cap * sizeof(char *));
    if (!names) { closedir(d); cap_append_str(out, "fx-verbs: out of memory\n"); *exitcode = 1; free(full); return 0; }
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) continue;
        if (n == cap) {
            size_t ncap = cap * 2;
            char **nn = realloc(names, ncap * sizeof(char *));
            if (!nn) break;
            names = nn;
            cap = ncap;
        }
        names[n] = strdup(de->d_name);
        if (!names[n]) break;
        n++;
    }
    closedir(d);
    qsort(names, n, sizeof(char *), name_cmp);
    char line[PATH_MAX + 2];
    for (size_t i = 0; i < n; i++) {
        struct stat st;
        bool isdir = false;
        char *child = malloc(strlen(full) + 1 + strlen(names[i]) + 1);
        if (child) {
            sprintf(child, "%s/%s", full, names[i]);
            isdir = (stat(child, &st) == 0 && S_ISDIR(st.st_mode));
            free(child);
        }
        int ln = snprintf(line, sizeof(line), "%s%s\n", names[i], isdir ? "/" : "");
        if (ln > 0) cap_append(out, line, (size_t)ln);
        free(names[i]);
    }
    free(names);
    free(full);
    *exitcode = 0;
    return 0;
}

/* ── the verb table ─────────────────────────────────────────────────────── */

typedef struct {
    const char *name;
    const char *cmd;      /* resolved under the root; NULL -> native verb */
    const char *fixed[6]; /* fixed argv between cmd and the argument: MAX 5
                           * args, NULL-TERMINATED (call_exec_verb walks it
                           * to the NULL — a row that fills every slot MUST
                           * carry the terminator explicitly; the shorter
                           * rows zero-fill it) */
    const char *desc;
} Verb;

/* fx_write (path+content), fx_store_verify (optional rootfs) and fx_ls
 * (optional path) take their arguments by name in handle_tools_call; every
 * other exec verb takes exactly the one string argument named in its
 * description. */
static const Verb VERBS[] = {
    { "fx_query", "fxctl", { "q", NULL },
      "Run `fxctl q <relation>`: read one live datalog relation. Known relations: "
      "generation, svc, svc_argv, install, provides, user, log. Argument: relation." },
    { "fx_status", "fxctl", { "status", NULL },
      "Run `fxctl status`: the live system status (current generation, services, "
      "store state). Takes no arguments." },
    /* fx_activate execs the RUNNING ROOT's /bin/fx-activate DIRECTLY — the
     * same binary, with the same arguments, that fx-init's own activate
     * handler uses (init.zig handle_request "activate": exec
     * <store>/<hash>-fx-activate/fx-activate --store <g_store> --package-set
     * /usr/fx/package-set.dhall --config <path>).
     *
     * WHY NOT `fxctl activate` (the pre-2026-10 row): fxctl's ONLY transports
     * are $FX_RUN/control.sock and an explicit --chardev/FX_CHARDEV path.  In
     * the guest CONFIG_NET is unset, so socket(2) is ENOSYS and there is no
     * control.sock at all; and the only chardev is the virtio control port,
     * which PID1 ITSELF reads (init.zig handle_virtio; the port has ONE input
     * queue — the same property that forces the g_shell_pid latch, "while the
     * child owns the port, handle_virtio must not read it").  A second reader
     * on that port races PID1 for the request bytes, so an in-guest fxctl
     * cannot be the loop's activation path.  The store/package-set are the
     * guest's own: /fx/disk/store is the persistent store (g_store — a ramfs
     * /fx/store activate would be lost on the restart) and
     * /usr/fx/package-set.dhall is the frozen package set mkinitramfs ships.
     * Argument: config (the path of the config to activate). */
    { "fx_activate", "fx-activate", { "--store", "/fx/disk/store",
                                      "--package-set", "/usr/fx/package-set.dhall",
                                      "--config", NULL },
      "ACTIVATE service configuration <config> on the running system (reconfigures "
      "it; the new generation becomes CURRENT on the persistent store). Runs the "
      "root's /bin/fx-activate with the image's frozen package set. Argument: "
      "config (a path, e.g. /fx/disk/agent-config.dhall)." },
    { "fx_rollback", "fxctl", { "rollback", NULL },
      "Run `fxctl rollback <version>`: roll the system back to generation <version>. "
      "Argument: version." },
    { "fx_what", "fxstore", { "what", NULL },
      "Run `fxstore what <target>`: the install fact (provenance proof tree) "
      "managing installed path <target>. Argument: target." },
    { "fx_why", "fxstore", { "why", NULL },
      "Run `fxstore why <package>`: why <package> is in the store — its closure, the "
      "targets it provides, and the roots pulling it in. Argument: package." },
    { "fx_store_verify", "fxstore", { "verify", NULL },
      "Run `fxstore verify`: reconcile the rootfs against the recorded install "
      "facts and report every drift. The first line of the reply text is `exit=1` "
      "exactly when drift was found — that exit line is the drift gate. Optional "
      "argument: rootfs (default /)." },
    { "fx_read", NULL, { NULL, NULL },
      "Read a file and return its content. Paths resolve under FX_VERB_ROOT. "
      "Capped at 1 MiB. Argument: path." },
    { "fx_write", NULL, { NULL, NULL },
      "Write a file (truncate-or-create; paths resolve under FX_VERB_ROOT like "
      "fx_read). Arguments: path, content." },
    { "fx_ls", NULL, { NULL, NULL },
      "List a directory: one entry per line, directories suffixed '/'. Paths resolve "
      "under FX_VERB_ROOT. Argument: path (default: the root itself)." },
};

#define NVERBS (sizeof(VERBS) / sizeof(VERBS[0]))

static const Verb *find_verb(const char *name) {
    for (size_t i = 0; i < NVERBS; i++) {
        if (strcmp(VERBS[i].name, name) == 0) return &VERBS[i];
    }
    return NULL;
}

/* ── JSON-RPC wire helpers (yyjson for every frame) ─────────────────────── */

static int write_all(const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(STDOUT_FILENO, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        off += (size_t)n;
    }
    return 0;
}

/* Serialize the mut doc as one newline-terminated reply line. */
static int send_doc(yyjson_mut_doc *md) {
    bool ok = false;
    size_t len = 0;
    char *json = yyjson_mut_write(md, 0, &len);
    if (json) {
        ok = (write_all(json, len) == 0 && write_all("\n", 1) == 0);
        free(json);
    }
    yyjson_mut_doc_free(md);
    return ok ? 0 : -1;
}

static int send_error(yyjson_val *idv, int code, const char *msg) {
    yyjson_mut_doc *md = yyjson_mut_doc_new(NULL);
    if (!md) return -1;
    yyjson_mut_val *err = yyjson_mut_obj(md);
    yyjson_mut_val *root = yyjson_mut_obj(md);
    if (!err || !root) { yyjson_mut_doc_free(md); return -1; }
    yyjson_mut_doc_set_root(md, root);
    yyjson_mut_obj_add_str(md, root, "jsonrpc", "2.0");
    if (idv) {
        yyjson_mut_val *mid = yyjson_val_mut_copy(md, idv);
        if (mid) yyjson_mut_obj_add_val(md, root, "id", mid);
    } else {
        yyjson_mut_obj_add_null(md, root, "id");
    }
    yyjson_mut_obj_add_int(md, err, "code", code);
    yyjson_mut_obj_add_str(md, err, "message", msg);
    yyjson_mut_obj_add_val(md, root, "error", err);
    return send_doc(md);
}

/* tools/call success: {"content":[{"type":"text","text":<payload>}]} */
static int send_tool_text(yyjson_val *idv, const char *text, size_t len) {
    yyjson_mut_doc *md = yyjson_mut_doc_new(NULL);
    yyjson_mut_val *res = md ? yyjson_mut_obj(md) : NULL;
    yyjson_mut_val *arr = res ? yyjson_mut_arr(md) : NULL;
    yyjson_mut_val *blk = arr ? yyjson_mut_obj(md) : NULL;
    yyjson_mut_val *root = res ? yyjson_mut_obj(md) : NULL;
    if (!res || !arr || !blk || !root) {
        if (md) yyjson_mut_doc_free(md);
        return -1;
    }
    yyjson_mut_doc_set_root(md, root);
    yyjson_mut_obj_add_str(md, root, "jsonrpc", "2.0");
    if (idv) {
        yyjson_mut_val *mid = yyjson_val_mut_copy(md, idv);
        if (mid) yyjson_mut_obj_add_val(md, root, "id", mid);
    }
    yyjson_mut_obj_add_str(md, blk, "type", "text");
    yyjson_mut_obj_add_strn(md, blk, "text", text, len);
    yyjson_mut_arr_add_val(arr, blk);
    yyjson_mut_obj_add_val(md, res, "content", arr);
    yyjson_mut_obj_add_val(md, root, "result", res);
    return send_doc(md);
}

/* ── tools/call ─────────────────────────────────────────────────────────── */

/* Extract a string argument; rejects embedded NULs (yyjson strings carry a
 * length, exec argv does not) and over-long values.  Returns 0 and sets
 * *out; -1 when absent/not-a-string/too long/contains NUL. */
static int arg_string(yyjson_val *args, const char *key, const char **out) {
    yyjson_val *v = yyjson_obj_get(args, key);
    if (!v || !yyjson_is_str(v)) return -1;
    const char *s = yyjson_get_str(v);
    size_t len = yyjson_get_len(v);
    if (len > FXV_MAX_LINE) return -1;
    if (strlen(s) != len) return -1; /* embedded NUL */
    *out = s;
    return 0;
}

/* Frame a finished capture as the tool reply: "exit=<n>\n" + payload.  Cuts
 * at the first NUL (with an explicit note — the client joins text with
 * strlen) and marks truncation. */
static int send_capture_reply(yyjson_val *idv, Capture *out, int exitcode) {
    cap_cut_at_nul(out);
    if (out->trunc)
        cap_append_str(out, "\n[fx-verbs: output truncated at 1048576 bytes]\n");
    char head[32];
    int hn = snprintf(head, sizeof(head), "exit=%d\n", exitcode);
    char *text = malloc((size_t)hn + out->len);
    if (!text) return send_error(idv, -32603, "out of memory");
    memcpy(text, head, (size_t)hn);
    memcpy(text + hn, out->data, out->len);
    int sret = send_tool_text(idv, text, (size_t)hn + out->len);
    free(text);
    return sret;
}

/* Run one exec verb and send the exit-code-framed reply. */
static int call_exec_verb(yyjson_val *idv, const Verb *v, char **argv_tail) {
    Capture out;
    if (!cap_init(&out)) return send_error(idv, -32603, "out of memory");
    char *cmd = resolve_command(v->cmd);
    if (!cmd) {
        /* report like the child would have: visible text, exit 127 */
        cap_append_str(&out, "fx-verbs: ");
        cap_append_str(&out, v->cmd);
        cap_append_str(&out, " not found under FX_VERB_ROOT (");
        cap_append_str(&out, fx_root());
        cap_append_str(&out, ")\n");
        int sret = send_capture_reply(idv, &out, 127);
        cap_free(&out);
        return sret;
    }
    /* argv = [resolved, fixed..., tail..., NULL] */
    size_t nfix = 0;
    while (v->fixed[nfix]) nfix++;
    size_t ntail = 0;
    while (argv_tail[ntail]) ntail++;
    char **argv = malloc((1 + nfix + ntail + 1) * sizeof(char *));
    if (!argv) { free(cmd); cap_free(&out); return send_error(idv, -32603, "out of memory"); }
    size_t k = 0;
    argv[k++] = cmd;
    for (size_t i = 0; i < nfix; i++) argv[k++] = (char *)v->fixed[i];
    for (size_t i = 0; i < ntail; i++) argv[k++] = argv_tail[i];
    argv[k] = NULL;

    int exitcode = 127;
    int rc = run_verb(argv, &out, &exitcode);
    free(argv);
    free(cmd);
    if (rc != 0) { cap_free(&out); return send_error(idv, -32603, "failed to run verb"); }
    int sret = send_capture_reply(idv, &out, exitcode);
    cap_free(&out);
    return sret;
}

static int handle_tools_call(yyjson_val *root, yyjson_val *idv) {
    yyjson_val *params = yyjson_obj_get(root, "params");
    yyjson_val *namev = params ? yyjson_obj_get(params, "name") : NULL;
    if (!namev || !yyjson_is_str(namev))
        return send_error(idv, -32602, "tools/call requires params.name");
    const char *name = yyjson_get_str(namev);
    const Verb *v = find_verb(name);
    if (!v) {
        char msg[128];
        snprintf(msg, sizeof(msg), "unknown tool: %.80s", name);
        return send_error(idv, -32602, msg);
    }
    /* arguments may be absent; yyjson_obj_get(NULL, ...) is NULL-safe */
    yyjson_val *arguments = params ? yyjson_obj_get(params, "arguments") : NULL;
    if (arguments && !yyjson_is_obj(arguments))
        return send_error(idv, -32602, "tools/call arguments must be an object");

    if (strcmp(name, "fx_write") == 0) {
        const char *path = NULL, *content = NULL;
        if (arg_string(arguments, "path", &path) != 0 ||
            arg_string(arguments, "content", &content) != 0)
            return send_error(idv, -32602,
                              "fx_write requires string arguments 'path' and 'content'");
        Capture out;
        if (!cap_init(&out)) return send_error(idv, -32603, "out of memory");
        int exitcode = 1;
        native_write(path, content, strlen(content), &out, &exitcode);
        int sret = send_capture_reply(idv, &out, exitcode);
        cap_free(&out);
        return sret;
    }

    if (strcmp(name, "fx_read") == 0) {
        const char *path = NULL;
        if (arg_string(arguments, "path", &path) != 0)
            return send_error(idv, -32602, "fx_read requires string argument 'path'");
        Capture out;
        if (!cap_init(&out)) return send_error(idv, -32603, "out of memory");
        int exitcode = 1;
        native_read(path, &out, &exitcode);
        int sret = send_capture_reply(idv, &out, exitcode);
        cap_free(&out);
        return sret;
    }

    if (strcmp(name, "fx_ls") == 0) {
        const char *path = "";
        /* optional: absent -> the root itself */
        if (yyjson_obj_get(arguments, "path")) {
            if (arg_string(arguments, "path", &path) != 0)
                return send_error(idv, -32602, "fx_ls argument 'path' must be a string");
        }
        Capture out;
        if (!cap_init(&out)) return send_error(idv, -32603, "out of memory");
        int exitcode = 1;
        native_ls(path, &out, &exitcode);
        int sret = send_capture_reply(idv, &out, exitcode);
        cap_free(&out);
        return sret;
    }

    if (strcmp(name, "fx_store_verify") == 0) {
        /* optional rootfs (fxstore verify [<rootfs>], default /) */
        char *tail[2] = { NULL, NULL };
        yyjson_val *rv = yyjson_obj_get(arguments, "rootfs");
        if (rv) {
            const char *rootfs = NULL;
            if (arg_string(arguments, "rootfs", &rootfs) != 0)
                return send_error(idv, -32602,
                                  "fx_store_verify argument 'rootfs' must be a string");
            tail[0] = (char *)rootfs;
        }
        return call_exec_verb(idv, v, tail);
    }

    /* every remaining exec verb takes exactly one string argument */
    {
        static const struct { const char *verb, *key, *what; } REQ[] = {
            { "fx_query",    "relation", "relation" },
            { "fx_activate", "config",   "config"   },
            { "fx_rollback", "version",  "version"  },
            { "fx_what",     "target",   "target"   },
            { "fx_why",      "package",  "package"  },
        };
        const char *key = NULL, *what = NULL;
        for (size_t i = 0; i < sizeof(REQ) / sizeof(REQ[0]); i++) {
            if (strcmp(name, REQ[i].verb) == 0) { key = REQ[i].key; what = REQ[i].what; }
        }
        if (!key) {
            /* found in the table but not in REQ: a no-argument verb (fx_status) */
            char *tail[1] = { NULL };
            return call_exec_verb(idv, v, tail);
        }

        char verbuf[32];
        const char *val = NULL;
        yyjson_val *av = yyjson_obj_get(arguments, key);
        if (strcmp(key, "version") == 0 && av && yyjson_is_int(av)) {
            snprintf(verbuf, sizeof(verbuf), "%d", yyjson_get_int(av));
            val = verbuf; /* the model may send the generation as a number */
        } else if (arg_string(arguments, key, &val) != 0) {
            char msg[160];
            snprintf(msg, sizeof(msg), "%s requires string argument '%s' (%s)",
                     name, key, what);
            return send_error(idv, -32602, msg);
        }
        char *tail[2] = { (char *)val, NULL };
        return call_exec_verb(idv, v, tail);
    }
}

/* ── frame dispatch ─────────────────────────────────────────────────────── */

static int handle_frame(const char *buf, size_t len) {
    yyjson_doc *doc = yyjson_read(buf, len, 0);
    if (!doc) return send_error(NULL, -32700, "parse error: request is not valid JSON");
    yyjson_val *root = yyjson_doc_get_root(doc);
    if (!root || !yyjson_is_obj(root)) {
        yyjson_doc_free(doc);
        return send_error(NULL, -32600, "invalid request: not a JSON-RPC object");
    }
    yyjson_val *idv = yyjson_obj_get(root, "id"); /* NULL when absent (notification) */
    yyjson_val *method = yyjson_obj_get(root, "method");
    if (!method || !yyjson_is_str(method)) {
        yyjson_doc_free(doc);
        if (idv) return send_error(idv, -32600, "invalid request: missing method");
        return 0; /* notification without a method: ignore */
    }
    const char *m = yyjson_get_str(method);
    int ret = 0;

    if (strcmp(m, "initialize") == 0) {
        if (!idv) { yyjson_doc_free(doc); return 0; }
        yyjson_mut_doc *md = yyjson_mut_doc_new(NULL);
        yyjson_mut_val *res = md ? yyjson_mut_obj(md) : NULL;
        yyjson_mut_val *rr = res ? yyjson_mut_obj(md) : NULL;
        yyjson_mut_val *sinfo = res ? yyjson_mut_obj(md) : NULL;
        yyjson_mut_val *mroot = res ? yyjson_mut_obj(md) : NULL;
        if (!res || !rr || !sinfo || !mroot) {
            if (md) yyjson_mut_doc_free(md);
            yyjson_doc_free(doc);
            return send_error(idv, -32603, "out of memory");
        }
        yyjson_mut_doc_set_root(md, mroot);
        yyjson_mut_obj_add_str(md, mroot, "jsonrpc", "2.0");
        yyjson_mut_val *mid = yyjson_val_mut_copy(md, idv);
        if (mid) yyjson_mut_obj_add_val(md, mroot, "id", mid);
        yyjson_mut_obj_add_str(md, res, "protocolVersion", FXV_PROTOCOL_VERSION);
        yyjson_mut_obj_add_val(md, res, "capabilities", yyjson_mut_obj(md));
        yyjson_mut_obj_add_str(md, sinfo, "name", FXV_SERVER_NAME);
        yyjson_mut_obj_add_str(md, sinfo, "version", FXV_SERVER_VERSION);
        yyjson_mut_obj_add_val(md, res, "serverInfo", sinfo);
        yyjson_mut_obj_add_val(md, mroot, "result", res);
        ret = send_doc(md);
    } else if (strcmp(m, "notifications/initialized") == 0) {
        /* notification: no reply */
    } else if (strcmp(m, "ping") == 0) {
        if (!idv) { yyjson_doc_free(doc); return 0; }
        yyjson_mut_doc *md = yyjson_mut_doc_new(NULL);
        yyjson_mut_val *res = md ? yyjson_mut_obj(md) : NULL;
        yyjson_mut_val *mroot = res ? yyjson_mut_obj(md) : NULL;
        if (!res || !mroot) {
            if (md) yyjson_mut_doc_free(md);
            yyjson_doc_free(doc);
            return send_error(idv, -32603, "out of memory");
        }
        yyjson_mut_doc_set_root(md, mroot);
        yyjson_mut_obj_add_str(md, mroot, "jsonrpc", "2.0");
        yyjson_mut_val *mid = yyjson_val_mut_copy(md, idv);
        if (mid) yyjson_mut_obj_add_val(md, mroot, "id", mid);
        yyjson_mut_obj_add_val(md, mroot, "result", res);
        ret = send_doc(md);
    } else if (strcmp(m, "tools/list") == 0) {
        if (!idv) { yyjson_doc_free(doc); return 0; }
        yyjson_mut_doc *md = yyjson_mut_doc_new(NULL);
        yyjson_mut_val *res = md ? yyjson_mut_obj(md) : NULL;
        yyjson_mut_val *arr = res ? yyjson_mut_arr(md) : NULL;
        yyjson_mut_val *mroot = res ? yyjson_mut_obj(md) : NULL;
        if (!res || !arr || !mroot) {
            if (md) yyjson_mut_doc_free(md);
            yyjson_doc_free(doc);
            return send_error(idv, -32603, "out of memory");
        }
        yyjson_mut_doc_set_root(md, mroot);
        yyjson_mut_obj_add_str(md, mroot, "jsonrpc", "2.0");
        yyjson_mut_val *mid = yyjson_val_mut_copy(md, idv);
        if (mid) yyjson_mut_obj_add_val(md, mroot, "id", mid);
        for (size_t i = 0; i < NVERBS; i++) {
            yyjson_mut_val *t = yyjson_mut_obj(md);
            if (!t || !yyjson_mut_arr_add_val(arr, t) ||
                !yyjson_mut_obj_add_str(md, t, "name", VERBS[i].name) ||
                !yyjson_mut_obj_add_str(md, t, "description", VERBS[i].desc)) {
                yyjson_mut_doc_free(md);
                yyjson_doc_free(doc);
                return send_error(idv, -32603, "out of memory");
            }
        }
        yyjson_mut_obj_add_val(md, res, "tools", arr);
        yyjson_mut_obj_add_val(md, mroot, "result", res);
        ret = send_doc(md);
    } else if (strcmp(m, "tools/call") == 0) {
        ret = handle_tools_call(root, idv);
    } else {
        if (idv) {
            char msg[128];
            snprintf(msg, sizeof(msg), "Method not found: %.80s", m);
            ret = send_error(idv, -32601, msg);
        }
        /* unknown notification: silent */
    }
    yyjson_doc_free(doc);
    return ret;
}

/* ── bounded line reader ────────────────────────────────────────────────── */

typedef struct {
    char *buf;
    size_t len;      /* bytes buffered */
    size_t cap;
    size_t pos;      /* start of the not-yet-returned line */
    char *line;      /* set by read_line: points into buf, NUL-terminated */
    size_t line_len;
} LineBuf;

/* Read one newline-delimited line off stdin.  Bytes AFTER the first newline
 * of a read stay buffered for the next call (frames coalesce in the pipe —
 * dropping them would silently eat requests).  Returns:
 *   1  a line was read (b->line/b->line_len valid until the next call; a
 *      final line without a trailing newline is returned at EOF)
 *   0  clean EOF with no pending bytes
 *  -1  the line exceeded FXV_MAX_LINE (drained; any bytes after its newline
 *      are kept as the next line) — the same cap the client enforces
 *  -2  read error */
static int read_line(LineBuf *b) {
    bool oversize = false;
    char scratch[4096];
    for (;;) {
        if (b->pos < b->len) {
            char *nl = memchr(b->buf + b->pos, '\n', b->len - b->pos);
            if (nl) {
                size_t nlpos = (size_t)(nl - b->buf);
                if (oversize) {
                    b->pos = nlpos + 1; /* keep the tail as the next line */
                    return -1;
                }
                *nl = '\0';
                b->line = b->buf + b->pos;
                b->line_len = nlpos - b->pos;
                b->pos = nlpos + 1;
                return 1;
            }
        }
        if (b->len - b->pos >= FXV_MAX_LINE) {
            /* everything buffered belongs to the oversize line: drop it and
             * drain in scratch until the line's newline; bytes after that
             * newline are the next request and must be kept */
            b->pos = 0;
            b->len = 0;
            oversize = true;
        }
        ssize_t n;
        if (oversize) {
            n = read(STDIN_FILENO, scratch, sizeof(scratch));
            if (n < 0) {
                if (errno == EINTR) continue;
                return -2;
            }
            if (n == 0) return -1;
            char *nl = memchr(scratch, '\n', (size_t)n);
            if (nl) {
                size_t tail = (size_t)(n - (nl + 1 - scratch));
                memmove(b->buf, nl + 1, tail); /* cap > sizeof(scratch) */
                b->pos = 0;
                b->len = tail;
                return -1;
            }
            continue; /* the whole chunk is part of the oversize line */
        }
        /* no full line pending: compact, grow if full, read more */
        if (b->pos > 0) {
            memmove(b->buf, b->buf + b->pos, b->len - b->pos);
            b->len -= b->pos;
            b->pos = 0;
        }
        if (b->len + 1 > b->cap) {
            size_t ncap = b->cap ? b->cap * 2 : 8192;
            if (ncap > FXV_MAX_LINE + 1) ncap = FXV_MAX_LINE + 1;
            char *nb = realloc(b->buf, ncap);
            if (!nb) return -2;
            b->buf = nb;
            b->cap = ncap;
        }
        n = read(STDIN_FILENO, b->buf + b->len, b->cap - b->len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -2;
        }
        if (n == 0) {
            if (b->len > b->pos) { /* final line without a trailing newline */
                b->buf[b->len] = '\0';
                b->line = b->buf + b->pos;
                b->line_len = b->len - b->pos;
                b->pos = b->len;
                return 1;
            }
            return 0;
        }
        b->len += (size_t)n;
    }
}

int main(void) {
    LineBuf lb = { NULL, 0, 0, 0, NULL, 0 };
    int rc = 0;
    for (;;) {
        int r = read_line(&lb);
        if (r == 0) break;
        if (r == -2) { rc = -1; break; }
        if (r == -1) {
            if (send_error(NULL, -32700, "request line exceeds cap") != 0) { rc = -1; break; }
            continue;
        }
        if (lb.line_len == 0) continue; /* blank line */
        if (handle_frame(lb.line, lb.line_len) != 0) { rc = -1; break; }
    }
    free(lb.buf);
    return rc;
}
