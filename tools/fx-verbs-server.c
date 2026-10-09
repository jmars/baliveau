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
 *   fx_store_verify  fxstore verify --store /fx/disk/store
 *                                             reconcile the running rootfs
 *                                             against the LIVE generation's
 *                                             install facts; EXIT 1 ON DRIFT
 *   fx_outcome       <store>/.bootlog + <store>/.db/snapshots/CURRENT +
 *                    <store>/.recovery
 *                                             (native) THE OUTCOME OF PREVIOUS
 *                                             BOOTS: the boot history, the last
 *                                             verdict, the generation this
 *                                             boot is running, and the
 *                                             recovery journal (has this
 *                                             happened before?)
 *   fx_generation    <store>/.db/snapshots/CURRENT
 *                                             (native) the CURRENT generation,
 *                                             one number
 *   fx_read          read a file              (native: open/read under the root)
 *   fx_write         write a file             (native: ONLY inside the host-
 *                                         declared FX_AGENT_WRITABLE set; see
 *                                         THE WRITABLE SET above)
 *   fx_ls            list a directory         (native: opendir under the root)
 *
 * THE OUTCOME INSTRUMENT.  fx_outcome / fx_generation are HOW AN AGENT SEES THE
 * RESULT OF ITS OWN LAST ACTIVATION — the roll-forward signal.  They read the
 * store's PLAIN FILES (never the runtime DB, which PID1 holds under a
 * process-lifetime lock, so no channel is needed): <store>/.bootlog, one
 * "<version> <status> <epoch>" line per boot with status in
 * ok | failed | in-progress | shutdown; <store>/.db/snapshots/CURRENT, the
 * generation the running system came up in (fx-init's store_current_of parses
 * the same file); and <store>/.recovery, the RECOVERY JOURNAL (fx-init
 * 4d6a8c2): one data line per AUTOMATIC roll-forward — the store's only
 * answer to "has this happened BEFORE?", without which every recovery looks
 * like a first offence.  They are the READ side; the MECHANISED side is the
 * harness's own boot-time consume of its durable activation record
 * (src/llm2/outcome.h) — a model can be given judgement later, the machinery
 * must not re-act blindly.  BOTH verbs are STORE-SCOPED with NO store
 * argument: they read FX_STORE_PATH (or none at all), never a store a caller
 * names, so a model cannot be talked
 * into reading the initramfs snapshot's stale bootlog.
 *
 * ROOT RESOLUTION — never a hardcoded absolute path: every command is looked
 * up under FX_VERB_ROOT (env, read at call time so tests can set it; default
 * "/"): first <ROOT>/bin, then <ROOT>/usr/fx-core/bin (where the fx-init
 * payload stages fxsh + the fx-* set), then <ROOT>/fx/store/bin (the store bin
 * dir).  THE RULE: <ROOT>/bin is the RUNNING generation's own bin dir — the
 * activation materializes one symlink per tool/service package there, into the
 * store dir its install fact names — so it MUST win over any staged copy.
 * mkinitramfs -b copies the whole fx-* bindir into <ROOT>/usr/fx-core/bin, so
 * with the reverse order any lane shipping fx-activate via -b made this verb
 * exec the INITRAMFS copy instead of the generation's /bin/fx-activate (the
 * binary fx-init's own activate handler execs).  A <ROOT>/bin link that
 * dangles (a diskless guest whose store is not mounted) simply fails the X_OK
 * test and the lookup falls through to the staged copy.  The file verbs prefix
 * paths with the same root, so the identical binary runs against a stub root
 * on the host (FX_VERB_ROOT=/tmp/stub) and against the real guest rootfs
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
#include "llm2/outcome.h"   /* the store's outcome files — ONE reader, shared
                             * with the harness's own boot-time consume */

extern char **environ; /* the server's own environment (pass-through source) */

/* Must match MCP_PROTOCOL_VERSION (src/mcp_stdio.h) — the client rejects a
 * failed/absent initialize result outright. */
#define FXV_PROTOCOL_VERSION "2025-06-18"
#define FXV_SERVER_NAME      "fx-verbs"
#define FXV_SERVER_VERSION   "0.1.0"

/* Line/output cap — SAME value the client enforces (MCP_MAX_LINE,
 * src/llm2/mcp_client.h). */
#define FXV_MAX_LINE (1024u * 1024u)

/* ── the store path the STORE-SCOPED verbs carry ───────────────────────────── */

/* FX_STORE_PATH is the guests' PERSISTENT store: fx-init's g_store, which is
 * this path ONLY while the virtio DISK store is mounted.  On a diskless guest
 * PID1 falls back to the initramfs ramfs (/fx/store, a snapshot this verb does
 * not own), so the path is ABSENT there — and a verb row that carries it
 * (fx_activate, fx_store_verify) is STORE-SCOPED: call_exec_verb refuses it
 * with a message NAMING the path rather than letting the child fail downstream
 * with something unrelated, and it never silently guesses another store (the
 * ramfs snapshot would reconcile the running rootfs against STALE facts).
 * A guest that mounts the disk store, and every stub root a test builds for
 * these rows, carries <FX_VERB_ROOT>/fx/disk/store. */
#define FX_STORE_PATH "/fx/disk/store"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/* ── the root ───────────────────────────────────────────────────────────── */

/* THE WRITABLE SET — fx_write's write surface is a CLOSED, NAMED SET the
 * HOST fixes, not a policy the model negotiates.  Outside the guest a tool
 * vocabulary is a policy; inside it is a FACT, so the fact is enforced in
 * the table: fx_write may only create-or-truncate a path in FX_AGENT_WRITABLE
 * (env, read at call time like FX_VERB_ROOT: a colon-separated list of EXACT
 * file paths, each spelled either ABSOLUTELY (/fx/disk/agent-config.dhall) or
 * ROOT-RELATIVELY (fx/disk/agent-config.dhall) — no directories, no globs;
 * both spellings are canonicalized to the SAME root-relative form before
 * comparison, so a relative entry grants exactly the file the absolute
 * spelling names and nothing wider), and a write outside the set is REFUSED
 * loudly (exit 1, naming the path AND the set).
 * See FX_DEFAULT_WRITABLE below for the unset case.  WHY THE SET EXISTS: the
 * harness's observation loop rests on <VIBE_RUNTIME_DIR>/attempts.jsonl being
 * beyond the model's WRITE reach — a model that could rewrite the record
 * could erase its own failed activation and re-issue it blindly (the
 * oscillator the loop exists to stop).  fx_read stays OPEN: the record is
 * not a secret, a read settles and erases nothing, and the loop's input is
 * the harness's own boot-time consume, not the model's.  The closed set is
 * closed because the table has no other file-writing shape: fx_write can
 * only open/create/truncate a regular file (opened O_NOFOLLOW, so a
 * pre-planted symlink at the final path cannot redirect it — the table has
 * no verb that creates a symlink, renames, chmods or unlinks), and the only
 * other write-shaped rows (fx_activate, fx_rollback) write the STORE through
 * the activator's own pinned argv, never arbitrary file content. */

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

/* ── the writable set (fx_write's closed write surface) ─────────────────── */

/* The DEFAULT set when FX_AGENT_WRITABLE is UNSET: exactly the ONE path this
 * harness's own deployment contract tells the agent to write — the task
 * config the guest prompt names (/fx/disk/agent-config.dhall).  The default
 * is never "unrestricted" and never a directory: the harness's durable
 * record (<VIBE_RUNTIME_DIR>/attempts.jsonl), the store, the bootlog and
 * CURRENT are in NO default set, so a deployment that never sets the
 * variable cannot have its observation loop defeated by an fx_write.  A
 * SET-BUT-EMPTY FX_AGENT_WRITABLE means the host declares nothing writable
 * (fx_write refuses everything) — distinct from unset by construction.
 *
 * THE BOUND OF THE SET, stated exactly: it is a PATH gate, not an INODE
 * gate.  fx_write opens the canonical path O_NOFOLLOW, so a symlink at the
 * FINAL path cannot redirect it — but (a) a hardlink planted at an allowed
 * path IS that path (the write truncates the shared inode, whatever else
 * links to it), and (b) a symlinked INTERMEDIATE directory redirects an
 * allowed path to a different file than the host named.  Both are HOST-side
 * plantings: the verb table gives the model no link/rename/chmod shape to
 * create either (native_write's open/write is the only write syscall in the
 * server), so they are outside the model's reach and inside the host's
 * contract: do not plant a hardlink or a directory symlink on a
 * writable-set path. */
#define FX_DEFAULT_WRITABLE "/fx/disk/agent-config.dhall"

/* The set in force, read at call time.  Never NULL; may be "" (refuse all). */
static const char *writable_set(void) {
    const char *w = getenv("FX_AGENT_WRITABLE");
    return w ? w : FX_DEFAULT_WRITABLE;
}

/* Lexically canonicalize an ABSOLUTE path to its ROOT-RELATIVE form: resolve
 * "." and ".." components, drop empty ones.  A ".." that would climb above
 * the ROOT is a refusal (root_join only CONCATENATES strings, so
 * "/../../etc/passwd" under a stub root would resolve to the HOST's
 * /etc/passwd — and a ".." spelling must never reach around the writable
 * set either).  Returns a malloc'd "a/b/c" ("" for the root itself), or NULL
 * on a non-absolute / root-escaping / too-long path. */
static char *canon_root_rel(const char *abs) {
    if (!abs || abs[0] != '/') return NULL;
    size_t cap = strlen(abs) + 1;
    char *out = malloc(cap);
    if (!out) return NULL;
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
            if (depth == 0) { free(out); return NULL; } /* escapes the root */
            while (olen > 0 && out[olen - 1] != '/') olen--;
            if (olen > 0) olen--;
            depth--;
            continue;
        }
        if (olen + sl + 1 >= cap) { free(out); return NULL; } /* bounded */
        if (olen) out[olen++] = '/';
        memcpy(out + olen, seg, sl);
        olen += sl;
        depth++;
    }
    out[olen] = '\0';
    return out;
}

/* Is `canon` (a canonicalized root-relative path) an EXACT member of the
 * writable set?  Every entry is canonicalized the SAME way before the
 * comparison, so "/a//b/./c" in the set matches a request for "/a/b/c", and
 * no ".." spelling can reach around the set.  An entry may be spelled
 * root-RELATIVELY (the spelling the comments and the tool description have
 * always documented): a missing leading '/' is supplied before
 * canonicalization — prefixing '/' can only NAME a path inside the root
 * (root_join concatenates under FX_VERB_ROOT), and a relative entry with a
 * ".." that would climb above it is still refused by canon_root_rel, so the
 * normalization widens nothing.  An entry that fails to canonicalize is
 * dropped: the set stays CLOSED. */
static int in_writable_set(const char *canon, const char *set) {
    const char *e = set;
    while (e && *e) {
        while (*e == ':') e++; /* empty entries are ignored */
        if (!*e) break;
        const char *end = e;
        while (*end && *end != ':') end++;
        size_t el = (size_t)(end - e);
        char ent[PATH_MAX];
        if (el > 0 && el < sizeof ent) {
            memcpy(ent, e, el);
            ent[el] = '\0';
            char *cent;
            if (ent[0] == '/') {
                cent = canon_root_rel(ent);
            } else {
                /* the documented root-relative spelling: absolute-ize, then
                 * canonicalize EXACTLY as the request is */
                char abs[PATH_MAX];
                int n = snprintf(abs, sizeof abs, "/%s", ent);
                cent = (n > 0 && n < (int)sizeof abs) ? canon_root_rel(abs) : NULL;
            }
            if (cent) {
                int hit = (strcmp(cent, canon) == 0);
                free(cent);
                if (hit) return 1;
            }
        }
        e = end;
    }
    return 0;
}

/* Look a verb command up under the root: first <ROOT>/bin — the RUNNING
 * generation's own bin dir, where the activation materializes one symlink per
 * tool + service package into the store (`activate.zig` collect /bin symlinks:
 * init, fxctl, dhake, fx-activate, fxstore for a pkg that declares it), i.e.
 * the very binaries the machine itself runs — then <ROOT>/usr/fx-core/bin
 * (where the fx-init payload stages fxsh + the fx-* set; an initramfs COPY of
 * the same programs that must not shadow the running root's), then
 * <ROOT>/fx/store/bin (the store bin dir).  Without the leading "bin" a verb
 * like fx_activate resolves to the initramfs COPY — for a lane that stages
 * fx-activate via `mkinitramfs -b` a different binary from the one fx-init's
 * own activate handler execs.
 * Returns a malloc'd absolute path, or NULL when nothing executable matches. */
static char *resolve_command(const char *cmd) {
    static const char *const DIRS[] = {
        "bin",
        "usr/fx-core/bin",
        "fx/store/bin",
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
    /* the SAME precedence as resolve_command: the running root's own bin dir
     * first, the initramfs staging dir after it (a verb that spawns a helper
     * by name must not pick up the initramfs copy either). */
    char *bin0 = root_join("bin");
    char *bin1 = root_join("usr/fx-core/bin");
    char *bin2 = root_join("fx/store/bin");
    if (!bin0 || !bin1 || !bin2) { free(bin0); free(bin1); free(bin2); return NULL; }

    char path[4 * PATH_MAX];
    snprintf(path, sizeof(path), "%s:%s:%s:/bin:/usr/bin", bin0, bin1, bin2);
    free(bin0);
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

/* The STORE-SCOPE refusal, in ONE place: a store-scoped verb refuses to run when
 * <root>/fx/disk/store is absent, NAMING the path rather than letting the child
 * fail downstream with something unrelated — and it never silently guesses
 * another store (the initramfs ramfs snapshot would answer with STALE facts).
 * Shared by the exec rows that carry FX_STORE_PATH and by the native outcome
 * verbs, so the phrase a reader greps is the same for both. */
static void store_scope_refuse(Capture *out, const char *verb) {
    cap_append_str(out, "fx-verbs: ");
    cap_append_str(out, verb);
    cap_append_str(out, " is store-scoped: the store ");
    cap_append_str(out, FX_STORE_PATH);
    cap_append_str(out, " does not exist under FX_VERB_ROOT (");
    cap_append_str(out, fx_root());
    cap_append_str(out, ") — it is fx-init's g_store, present only while the "
                        "disk store is mounted; this verb will not guess "
                        "another store\n");
}

/* The store this server reads, resolved under the root.  Returns a malloc'd
 * path (caller frees) or NULL when it is not there. */
static char *store_if_present(void) {
    char *sp = root_join(FX_STORE_PATH);
    if (!sp) return NULL;
    if (access(sp, F_OK) != 0) {
        free(sp);
        return NULL;
    }
    return sp;
}

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
    if (!path || path[0] != '/') {
        cap_append_str(out, "fx-verbs: fx_write REFUSED: '");
        cap_append_str(out, path ? path : "(null)");
        cap_append_str(out, "' is not an absolute path (fx_write addresses files as "
                            "absolute paths under FX_VERB_ROOT)\n");
        *exitcode = 1;
        return 0;
    }
    char *full = root_join(path);
    if (!full) { cap_append_str(out, "fx-verbs: path too long\n"); *exitcode = 1; return 0; }
    /* THE WRITABLE SET GATE (see FX_DEFAULT_WRITABLE): canonicalize FIRST, so
     * no ".." or "//" spelling can reach around the set, then require EXACT
     * membership.  A refusal NAMES the path and the set and says the set is
     * host-declared: it must be loud, never a silent no-op. */
    char *canon = canon_root_rel(path);
    if (!canon) {
        cap_append_str(out, "fx-verbs: fx_write REFUSED: ");
        cap_append_str(out, path);
        cap_append_str(out, " does not name a path inside FX_VERB_ROOT (root=");
        cap_append_str(out, fx_root());
        cap_append_str(out, "); a '..' that climbs above the root is not a writable path\n");
        *exitcode = 1;
        free(full);
        return 0;
    }
    const char *set = writable_set();
    if (!in_writable_set(canon, set)) {
        cap_append_str(out, "fx-verbs: fx_write REFUSED: ");
        cap_append_str(out, full);
        cap_append_str(out, " is not in the host-declared writable set "
                            "FX_AGENT_WRITABLE='");
        cap_append_str(out, set);
        cap_append_str(out, "'. Only the exact files the HOST lists there may be "
                            "written (the harness's own record and the store are "
                            "deliberately outside every default set); to grant "
                            "more, the operator must change FX_AGENT_WRITABLE — "
                            "the model cannot widen it\n");
        *exitcode = 1;
        free(full);
        free(canon);
        return 0;
    }
    /* open the CANONICAL spelling, never the raw request: a granted path with
     * redundant "//", "." or ".." components then resolves exactly as the set
     * names it, and no '..' ever reaches open(). */
    free(full);
    full = root_join(canon);
    free(canon);
    if (!full) { cap_append_str(out, "fx-verbs: path too long\n"); *exitcode = 1; return 0; }
    /* O_NOFOLLOW: a pre-existing symlink at the final path must not redirect
     * the write (the table has no verb that creates one, but nothing stops a
     * symlink that is already there). */
    int fd = open(full, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0644);
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

/* ── the native OUTCOME verbs (fx_outcome / fx_generation) ──────────────── */

/* Print one bootlog line.  The bootlog is APPEND-ONLY and ordered: this is the
 * history as it would be read with `cat`, one "boot <v> <status> <epoch>" line
 * per recorded boot (fx_init's bootlog_append writes "<v> <status> <epoch>"). */
static int outcome_line_cb(void *u, unsigned long version, const char *status,
                           unsigned long epoch) {
    Capture *out = (Capture *)u;
    char line[160];
    int n = snprintf(line, sizeof line, "boot %lu %s %lu\n", version, status, epoch);
    if (n > 0) cap_append(out, line, (size_t)n);
    return 0;
}

/* fx_outcome: the WHOLE outcome picture a reader needs to answer "did what I did
 * last boot actually work?".  Reads, in this order: the store path (as the guest
 * names it, not as resolved), CURRENT (fail-closed: an unreadable CURRENT is
 * reported as UNREADABLE and the verb exits 1 rather than printing a guess), the
 * LAST VERDICT in the bootlog (ok|failed — i.e. what the previous boot did, the
 * roll-forward signal), THE RECOVERY JOURNAL (has this happened BEFORE? —
 * <store>/.recovery, one data line per AUTOMATIC roll-forward, the only line in
 * the store that can say "this machine has recovered before"; absent and
 * never-recovered are reported as the DISTINCT states they are, and a recurring
 * genhash is reported as the same fault RETURNING, never as a live oscillation —
 * the journal's own header limits it that far and this verb does not exceed it),
 * how many boots are recorded, and then every line.  THE BOOTLOG'S OWN READ
 * STATES are distinct here too, the same three the journal gets: ABSENT (no
 * .bootlog — the store predates it; never worded as "boots 0"), UNREADABLE (a
 * directory where the file belongs gets PAST fopen and fails the read — before
 * the distinct state existed it printed "boots 0", a measurement never made),
 * and a TORN tail (skipped lines said as a floor).  Exit 1 only when CURRENT
 * could not be read: a missing or unreadable bootlog or journal is reported in
 * place but is not itself fatal. */
static int native_outcome(Capture *out, int *exitcode) {
    char *store = store_if_present();
    if (!store) { store_scope_refuse(out, "fx_outcome"); *exitcode = 1; return 0; }

    char line[PATH_MAX + 128];
    int n = snprintf(line, sizeof line, "store %s\n", FX_STORE_PATH);
    if (n > 0) cap_append(out, line, (size_t)n);

    /* the bootlog is read ONCE, up front, so the `last` line, the `boots`
     * count and the history all describe the SAME read (a second read could
     * see a concurrently appended line and contradict itself); the history
     * lines are captured and spliced in at their usual place below. */
    Capture hist;
    int have_hist = cap_init(&hist); /* on OOM the state lines still print;
                                      * only the per-boot history is lost */
    FxBootlog bl;
    fx_outcome_bootlog_read(store, have_hist ? outcome_line_cb : NULL,
                            have_hist ? &hist : NULL, &bl);

    unsigned long cur = 0;
    char err[512] = {0};
    int have_cur = (fx_outcome_current(store, &cur, err, sizeof err) == 0);
    if (have_cur) snprintf(line, sizeof line, "current %lu\n", cur);
    else          snprintf(line, sizeof line, "current UNREADABLE: %s\n", err);
    cap_append_str(out, line);

    if (bl.unreadable)
        snprintf(line, sizeof line, "last UNKNOWN (the bootlog is UNREADABLE)\n");
    else if (bl.absent)
        snprintf(line, sizeof line, "last UNKNOWN (no %s on this store)\n",
                 FX_OUTCOME_BOOTLOG_FILE);
    else if (bl.have_last)
        snprintf(line, sizeof line, "last %lu %s\n", bl.last_version, bl.last_status);
    else
        snprintf(line, sizeof line, "last none\n");
    cap_append_str(out, line);

    /* THE RECOVERY JOURNAL — the "has this happened before?" half that neither
     * the bootlog nor CURRENT can answer.  Distinct states, distinct words:
     * an ABSENT journal (a store that predates it) is not a ZERO (a machine
     * that has never recovered), and the recurrence line carries the journal's
     * own honesty limit rather than implying a live oscillation. */
    {
        FxRecovery rj;
        char rerr[256] = {0};
        if (fx_outcome_recovery(store, &rj, rerr, sizeof rerr) != 0) {
            n = snprintf(line, sizeof line, "recovery UNREADABLE: %s\n", rerr);
            if (n > 0) cap_append(out, line, (size_t)n);
        } else if (rj.journal_absent) {
            n = snprintf(line, sizeof line,
                         "recovery absent (no %s — the store predates the journal;\n"
                         "             unknown, not zero)\n",
                         FX_OUTCOME_RECOVERY_FILE);
            if (n > 0) cap_append(out, line, (size_t)n);
        } else {
            n = snprintf(line, sizeof line, "recoveries %lu%s\n", rj.count,
                         rj.count == 0
                             ? " (journal present; no automatic roll-forward recorded)"
                             : "");
            if (n > 0) cap_append(out, line, (size_t)n);
            if (rj.have_last) {
                n = snprintf(line, sizeof line,
                             "recovery_last %lu published v%lu from v%lu genhash %s\n",
                             rj.last_epoch, rj.last_published, rj.last_from_failed,
                             rj.last_genhash[0] ? rj.last_genhash : "-");
                if (n > 0) cap_append(out, line, (size_t)n);
            }
            if (rj.have_recur) {
                n = snprintf(line, sizeof line,
                             "recovery_recur %s x%lu — the SAME fault returning "
                             "(not a live-oscillation claim; read the epochs and "
                             ".bootlog)\n",
                             rj.recur_genhash, rj.recur_count);
                if (n > 0) cap_append(out, line, (size_t)n);
            }
            if (rj.damaged_lines > 0) {
                n = snprintf(line, sizeof line,
                             "recovery_torn %d line(s) skipped (torn/unparsable) — "
                             "the count is a FLOOR\n",
                             rj.damaged_lines);
                if (n > 0) cap_append(out, line, (size_t)n);
            }
        }
    }

    /* THE BOOTLOG'S OWN READ STATES, in the journal's discipline: a count is
     * printed only for a bootlog that was actually READ — absent and
     * unreadable are their own words, never "boots 0" (which would be a
     * measurement never made). */
    if (bl.unreadable) {
        n = snprintf(line, sizeof line, "bootlog UNREADABLE: %s\n", bl.err);
        if (n > 0) cap_append(out, line, (size_t)n);
    } else if (bl.absent) {
        n = snprintf(line, sizeof line,
                     "bootlog absent (no %s on this store — the store predates it;\n"
                     "             whether any boot was judged is UNKNOWN, not zero)\n",
                     FX_OUTCOME_BOOTLOG_FILE);
        if (n > 0) cap_append(out, line, (size_t)n);
    } else {
        n = snprintf(line, sizeof line, "boots %d\n", bl.lines);
        if (n > 0) cap_append(out, line, (size_t)n);
        if (bl.torn > 0) {
            n = snprintf(line, sizeof line,
                         "bootlog_torn %d line(s) skipped (torn/unparsable) — "
                         "boots is a FLOOR\n", bl.torn);
            if (n > 0) cap_append(out, line, (size_t)n);
        }
        if (have_hist) cap_append(out, hist.data, hist.len);
    }
    if (have_hist) cap_free(&hist);
    *exitcode = have_cur ? 0 : 1;
    free(store);
    return 0;
}

/* fx_generation: the CURRENT generation alone — the machine's own answer to
 * "which generation am I running?".  One line, "current <N>"; exit 1 (naming the
 * file) when it cannot be read, NEVER a guessed version. */
static int native_generation(Capture *out, int *exitcode) {
    char *store = store_if_present();
    if (!store) { store_scope_refuse(out, "fx_generation"); *exitcode = 1; return 0; }
    unsigned long cur = 0;
    char err[512] = {0};
    char line[PATH_MAX + 128];
    if (fx_outcome_current(store, &cur, err, sizeof err) == 0) {
        snprintf(line, sizeof line, "current %lu\n", cur);
        *exitcode = 0;
    } else {
        snprintf(line, sizeof line, "fx-verbs: fx_generation: %s\n", err);
        *exitcode = 1;
    }
    cap_append_str(out, line);
    free(store);
    return 0;
}

/* ── the verb table ─────────────────────────────────────────────────────── */

/* fixed[] slots per row: at most VERB_FIXED_MAX-1 arguments + the NULL
 * terminator.  ONE definition shared by the array declaration and the bounded
 * walk in call_exec_verb, so the walk cannot drift from the array. */
#define VERB_FIXED_MAX 6

typedef struct {
    const char *name;
    const char *cmd;      /* resolved under the root; NULL -> native verb */
    const char *fixed[VERB_FIXED_MAX];
                          /* fixed argv between cmd and the argument: at most
                           * VERB_FIXED_MAX-1 args + the NULL TERMINATOR, which
                           * every row MUST carry (the shorter rows zero-fill
                           * it).  call_exec_verb walks it BOUNDED and refuses
                           * a row that fills all VERB_FIXED_MAX slots, so a
                           * future over-long row fails loudly instead of
                           * reading past the array into `desc` — the first-cut
                           * bug this table shipped. */
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
     * guest's own: FX_STORE_PATH is the persistent store (g_store — a ramfs
     * /fx/store activate would be lost on the restart) and
     * /usr/fx/package-set.dhall is the frozen package set mkinitramfs ships.
     * STORE-SCOPED: this row carries FX_STORE_PATH, so call_exec_verb refuses
     * to run it when that path is absent (a diskless guest) instead of letting
     * the child fail downstream.  Argument: config (the path of the config to
     * activate). */
    { "fx_activate", "fx-activate", { "--store", FX_STORE_PATH,
                                      "--package-set", "/usr/fx/package-set.dhall",
                                      "--config", NULL },
      "ACTIVATE service configuration <config> on the running system. DURABLE-ONLY: "
      "the new generation becomes CURRENT on the persistent store and takes effect at "
      "the NEXT boot — the running system is not re-materialized (no hot-apply, no "
      "PID1 boot-decision re-arm), so an fx_status read right after this still shows "
      "the OLD generation. Runs the root's /bin/fx-activate with the image's frozen "
      "package set. Argument: config (a path, e.g. /fx/disk/agent-config.dhall)." },
    { "fx_rollback", "fxctl", { "rollback", NULL },
      "Run `fxctl rollback <version>`: roll the system back to generation <version>. "
      "Argument: version." },
    { "fx_what", "fxstore", { "what", NULL },
      "Run `fxstore what <target>`: the install fact (provenance proof tree) "
      "managing installed path <target>. Argument: target." },
    { "fx_why", "fxstore", { "why", NULL },
      "Run `fxstore why <package>`: why <package> is in the store — its closure, the "
      "targets it provides, and the roots pulling it in. Argument: package." },
    /* The store root is the guest's LIVE store (FX_STORE_PATH = fx-init's
     * g_store on the disk), not the initramfs's /fx/store snapshot: the
     * install facts a verdict must be judged against are the ones that
     * generation published.  Without it the verb would reconcile the running
     * rootfs against a STALE snapshot and report phantom drift.  STORE-SCOPED:
     * the row carries FX_STORE_PATH, so call_exec_verb refuses it when the path
     * is absent rather than guessing a store. */
    { "fx_store_verify", "fxstore", { "verify", "--store", FX_STORE_PATH },
      "Run `fxstore verify`: reconcile the rootfs against the recorded install "
      "facts of the LIVE (" FX_STORE_PATH ") generation and report every drift. The "
      "first line of the reply text is `exit=1` exactly when drift was found — "
      "that exit line is the drift gate. Optional argument: rootfs (default /)." },
    /* THE OUTCOME INSTRUMENT — how an agent sees the result of its OWN last
     * activation (the roll-forward signal).  Both are NATIVE (no exec) and
     * STORE-SCOPED with NO store argument: they read <store>/.bootlog and
     * <store>/.db/snapshots/CURRENT (fx-init's own two plain files), and a store
     * a caller names is never consulted. */
    { "fx_outcome", NULL, { NULL, NULL },
      "Report the OUTCOME OF PREVIOUS BOOTS, read from the store's own plain files "
      "(no channel needed): current <N> (the generation the running system came up "
      "in, from <store>/.db/snapshots/CURRENT), last <v> ok|failed (the previous "
      "boot's verdict), recoveries <n> + recovery_last/recovery_recur (from "
      "<store>/.recovery: how many AUTOMATIC roll-forwards fx-init has performed — "
      "the machine answering 'has this happened before?'; a recurring genhash is "
      "the SAME fault returning), boots <n>, then one 'boot <version> <status> "
      "<epoch>' line per recorded boot from <store>/.bootlog (status ok|failed|"
      "in-progress|shutdown). Read it after a restart to see whether the generation "
      "you activated booted ok, or FAILED and was rolled forward to older content "
      "under a HIGHER version number — and whether that has happened BEFORE. "
      "Takes no arguments; store-scoped." },
    { "fx_generation", NULL, { NULL, NULL },
      "Print the CURRENT generation of the store — the generation the running "
      "system came up in, from <store>/.db/snapshots/CURRENT: one line, "
      "'current <N>'. Exit 1 and names the file when it cannot be read (a version "
      "is never guessed). Takes no arguments; store-scoped." },
    { "fx_read", NULL, { NULL, NULL },
      "Read a file and return its content. Paths resolve under FX_VERB_ROOT. "
      "Capped at 1 MiB. Argument: path." },
    { "fx_write", NULL, { NULL, NULL },
      "Write a file (create-or-truncate). The write surface is a CLOSED, HOST-DECLARED "
      "SET: only the exact paths listed in FX_AGENT_WRITABLE (colon-separated; each "
      "path may be spelled absolute or root-relative — both name the same file) may "
      "be written — a write to anything else is REFUSED (exit=1) naming the path and "
      "the set, and the model cannot widen the set. Does not follow a symlink at the "
      "final path. Arguments: path, content." },
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
    /* the fixed[] walk is BOUNDED BY THE ARRAY, not by a terminator it hopes to
     * find: a row that fills all VERB_FIXED_MAX slots with no NULL would walk
     * past fixed[] into `desc` (and on through the next rows) and hand the
     * child a garbage argv — the exact overrun the first cut of this table
     * shipped.  VERB_FIXED_MAX slots can hold at most VERB_FIXED_MAX-1 args
     * plus the terminator, so reaching the bound means the row is malformed:
     * FAIL LOUDLY rather than truncate the argv silently. */
    size_t nfix = 0;
    while (nfix < VERB_FIXED_MAX && v->fixed[nfix]) nfix++;
    if (nfix == VERB_FIXED_MAX) {
        cap_free(&out);
        return send_error(idv, -32603,
                          "internal: verb table row has no NULL terminator in fixed[]");
    }
    /* store-scoped rows (those carrying FX_STORE_PATH) refuse to run when the
     * store is not there, naming the path: see FX_STORE_PATH. */
    for (size_t i = 0; i < nfix; i++) {
        if (strcmp(v->fixed[i], FX_STORE_PATH) != 0) continue;
        char *sp = store_if_present();
        if (sp) { free(sp); break; }
        store_scope_refuse(&out, v->name);
        int sret = send_capture_reply(idv, &out, 1);
        cap_free(&out);
        return sret;
    }
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

    /* fx_outcome / fx_generation: the native OUTCOME verbs.  Handled HERE,
     * before the "every remaining exec verb takes exactly one string argument"
     * fallback below — whose no-argument branch would otherwise hand a NULL cmd
     * (these rows carry no command) to call_exec_verb. */
    if (strcmp(name, "fx_outcome") == 0 || strcmp(name, "fx_generation") == 0) {
        Capture out;
        if (!cap_init(&out)) return send_error(idv, -32603, "out of memory");
        int exitcode = 1;
        if (strcmp(name, "fx_outcome") == 0)
            native_outcome(&out, &exitcode);
        else
            native_generation(&out, &exitcode);
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
