/* tools/fx-verbs-server.c — the fx-linux system verbs as an MCP stdio tool
 * server.
 *
 * A newline-delimited JSON-RPC 2.0 MCP server (initialize ->
 * notifications/initialized -> tools/list -> tools/call, plus ping), driven
 * by fx-harness's
 * src/agent/mcp_client.c: fork+execvpe'd over stdio, id-matched replies,
 * bounded newline frames.  The whole verb surface is ONE table of rows
 * {name, argv template, description}:
 *
 *   fx_query         fxctl --fifo q <relation>
 *                                         live datalog relations (generation,
 *                                         svc, svc_argv, install, provides,
 *                                         user, log) over PID1's fifo pair
 *   fx_status        fxctl --fifo status
 *   fx_activate      <native: the PID1 control channel>  the agent's
 *                                         activation goes THROUGH PID1's own
 *                                         activate handler (see THE CONTROL
 *                                         CHANNEL below) so the change is
 *                                         COMMITTED, not merely published
 *   fx_rollback      fxctl --fifo rollback <version>
 *   fx_what          fxstore what <target>    provenance proof tree for an
 *                                             installed path
 *   fx_why           fxstore why <package>    closure + provided targets +
 *                                             pulling roots
 *   fx_store_verify  fxstore verify --store /fx/disk/store
 *                                             reconcile the running rootfs
 *                                             against the LIVE generation's
 *                                             install facts; EXIT 1 ON DRIFT
 *   fx_build         fxstore build --store /fx/disk/store <pkg>
 *                                             BUILD one package of the
 *                                             image's FROZEN package set
 *                                             into the LIVE store, IN THE
 *                                             GUEST (todo.md §5: the agent
 *                                             iterates without sending
 *                                             code off the machine).  The
 *                                             row pins the WHOLE execution
 *                                             context: the fxstore binary
 *                                             is resolved under the root,
 *                                             the store is FX_STORE_PATH
 *                                             (store-scoped refusal like
 *                                             its neighbours), the working
 *                                             directory is /usr/fx — where
 *                                             mkinitramfs ships the frozen
 *                                             package-set.dhall fxstore
 *                                             loads from its cwd — and the
 *                                             child env carries
 *                                             FXSTORE_SH/FXSTORE_STAGE3
 *                                             pointing at the deployment's
 *                                             staged seats (see
 *                                             build_verb_envp).  The
 *                                             package argument is BOUNDED
 *                                             by the host-declared closed
 *                                             set FX_AGENT_BUILDABLE: the
 *                                             agent may NAME a package the
 *                                             deployment ships, never
 *                                             invent one, and never a
 *                                             flag, a path or a store.
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
 * (src/agent/outcome.h) — a model can be given judgement later, the machinery
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
 * THE CONTROL CHANNEL (fx_activate's route, 2026-10).  The agent's activation
 * must go THROUGH PID 1, not around it: PID1's `activate` handler (fx-init
 * init.zig handle_request) does the WHOLE standard activation — it forks the
 * fx-activate child (which evaluates the config, computes the closure, emits
 * the per-generation Dhakefile, publishes the snapshot and moves store
 * CURRENT), then RE-READS the store's facts (the service table becomes the
 * NEW generation's), rt_set_generation_current, RE-ARMS the boot decision (a
 * fresh grace window — the verdict latched for the old generation must not
 * stand for the new one), RE-RUNS the boot path's dhake materialization on
 * the LIVE post-pivot root (THE COMMIT: the new generation's /etc + /bin are
 * put on the running system, no reboot), and records rt_effect("activate").
 * A direct exec of /bin/fx-activate gets ONLY the child half: the generation
 * is PUBLISHED (store CURRENT moves) but never COMMITTED — the difference
 * between "the generation exists" and "the machine is running it".  So this
 * server speaks PID1's fifo line protocol natively (see fifo_activate): it
 * writes `activate <config>` to <run>/control.in and reads the reply (data
 * lines, then `OK`, or a single `ERR <why>` refusal) off control.out.
 *
 * WHY NOT `fxctl --fifo activate` (the existing client): MEASURED, not
 * guessed — an activation takes ~63s (host, warm cache, the slot package
 * set), and fxctl's fifo read path is poll()-gated with a HARD 5s budget per
 * read and no override (fxctl.zig PollSource).  fxctl would report
 * "no response (timeout/disconnect)" exit 1 while PID1 is still mid-handler,
 * and the activation would COMMIT a minute later anyway — a FALSE refusal on
 * exactly the call whose diagnosis matters most.  The fast fxctl verbs
 * (fx_query/fx_status/fx_rollback, replies in milliseconds) DO ride fxctl's
 * fifo mode; only the one slow command needs this server's own budget.
 *
 * The fifo pair's documented bound, stated here because this server is one
 * of its clients: it is SINGLE-CLIENT BY CONVENTION, NOT ENFORCEMENT — a
 * second concurrent client's replies interleave on the shared control.out
 * (garbled reads, never supervisor corruption; see fxctl.zig's header).
 *
 * EXIT-CODE REPORTING — every tools/call reply text begins with "exit=<n>"
 * followed by the verb's stdout+stderr.  isError is NEVER set:
 * mcp_client.c:437-441 drops isError results entirely (returns -1, text
 * lost), so the model would never see fx_store_verify's drift report — the
 * exit line IS the drift gate.
 *
 * BOUNDS — request lines and captured verb output are capped at FXV_MAX_LINE,
 * the same 1 MiB cap the client enforces (MCP_MAX_LINE,
 * src/agent/mcp_client.h).  Every JSON frame is parsed AND built with the
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
#include <poll.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "yyjson.h"
#include "agent/outcome.h"   /* the store's outcome files — ONE reader, shared
                             * with the harness's own boot-time consume */
#include "vendor/datalog-dafsa/src/dl.h"  /* the sibling datalog engine — the
                             * ops-policy seat's evaluator; the SAME engine the
                             * harness's runstore links, resolved by the SAME
                             * DATALOG_DIR discipline (tools/build.sh / Makefile)
                             */
#include "dhall.h"           /* sha256_hex — the vendored dhall-c hash the
                             * PINS verification calls (fx-report.c's pattern) */


extern char **environ; /* the server's own environment (pass-through source) */

/* Must match MCP_PROTOCOL_VERSION (src/mcp_stdio.h) — the client rejects a
 * failed/absent initialize result outright. */
#define FXV_PROTOCOL_VERSION "2025-06-18"
#define FXV_SERVER_NAME      "fx-verbs"
#define FXV_SERVER_VERSION   "0.1.0"

/* Line/output cap — SAME value the client enforces (MCP_MAX_LINE,
 * src/agent/mcp_client.h). */
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
 * harness's observation loop rests on <FX_AGENT_DATA>/attempts.jsonl being
 * beyond the model's WRITE reach — a model that could rewrite the record
 * could erase its own failed activation and re-issue it blindly (the
 * oscillator the loop exists to stop).  fx_read stays OPEN: the record is
 * not a secret, a read settles and erases nothing, and the loop's input is
 * the harness's own boot-time consume, not the model's.  OPEN, but not
 * unbounded: fx_read / fx_ls resolve their path through the SAME
 * canon_root_rel gate fx_write does, so nothing that CLIMBS ABOVE
 * FX_VERB_ROOT is readable or listable (see native_read).  The closed set is
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
 * record (<FX_AGENT_DATA>/attempts.jsonl), the store, the bootlog and
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

/* ── the buildable set (fx_build's closed package surface) ──────────────── */

/* THE BOUND OF fx_build, stated exactly: the package argument is a member of
 * a CLOSED, NAMED SET the HOST fixes — the exact FX_AGENT_WRITABLE pattern,
 * one shape over.  WHY A SET AND NOT "any package in the frozen package
 * set": reading the set would mean evaluating Dhall in this server (no), and
 * a bare name-shape check would let the model build ANY well-formed name —
 * including packages the deployment provisions host-side (fx-init, dhake),
 * whose store facts a guest build would rewrite.  The set names exactly the
 * packages the deployment has decided are AGENT-BUILDABLE; everything else
 * is refused loudly, naming the set, and the model cannot widen it.
 *
 * The DEFAULT set when FX_AGENT_BUILDABLE is UNSET: exactly the ONE package
 * the first self-modification contract names — the slot (oslot), the package
 * whose src.path the deployment pre-declares and the agent fills
 * (fx-init/m3/package-set-slot.dhall).  Like FX_DEFAULT_WRITABLE it is never
 * "unrestricted": a deployment that never sets the variable cannot have its
 * provisioned packages rebuilt in-guest.  A SET-BUT-EMPTY
 * FX_AGENT_BUILDABLE means the host declares nothing buildable (fx_build
 * refuses every name) — distinct from unset by construction.  Entries are
 * colon-separated BARE package names; a malformed entry (leading '-', '/',
 * embedded whitespace) is UNREACHABLE, not silently honored: the shape gate
 * below refuses any REQUEST that is not a bare name before membership is
 * consulted, so no request that could match a malformed entry ever reaches
 * the exec argv. */
#define FX_DEFAULT_BUILDABLE "oslot"

/* The set in force, read at call time.  Never NULL; may be "" (refuse all). */
static const char *buildable_set(void) {
    const char *b = getenv("FX_AGENT_BUILDABLE");
    return b ? b : FX_DEFAULT_BUILDABLE;
}

/* Is `pkg` an EXACT member of the colon-separated name set?  Exact string
 * comparison per entry — no prefix, no glob, the in_writable_set discipline
 * over names instead of canonicalized paths. */
static int in_name_set(const char *pkg, const char *set) {
    const char *e = set;
    while (e && *e) {
        while (*e == ':') e++; /* empty entries are ignored */
        if (!*e) break;
        const char *end = e;
        while (*end && *end != ':') end++;
        size_t el = (size_t)(end - e);
        if (el == strlen(pkg) && memcmp(e, pkg, el) == 0) return 1;
        e = end;
    }
    return 0;
}

/* The shape half of the bound: a buildable name is BARE — non-empty, no
 * leading '-' (it is a package name, not a flag), no '/' (not a path or a
 * store), no ':' (not a set), no whitespace.  Membership alone would refuse
 * all of these for a sane set; the shape gate holds the rule even under a
 * MISCONFIGURED set, the same belt-and-braces as O_NOFOLLOW on top of the
 * writable set. */
static int is_bare_package_name(const char *pkg) {
    if (!pkg || !*pkg) return 0;
    if (pkg[0] == '-') return 0;
    if (strchr(pkg, '/') || strchr(pkg, ':')) return 0;
    for (const char *p = pkg; *p; p++)
        if (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') return 0;
    return 1;
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
 * <ROOT>/fx/store/bin (the store bin dir), then <ROOT>/usr/fx-agent/bin (the
 * DEPLOYMENT's agent-payload staging dir — where tools/stage-guest.sh puts
 * fx-agent, fx-verbs-server, luajit and, for the in-guest build, fxstore +
 * stage3 + the recipe's busybox applets; /usr is a pivot bind, so it is
 * present where services run).  Without the leading "bin" a verb like
 * fx_activate resolves to the initramfs COPY — for a lane that stages
 * fx-activate via `mkinitramfs -b` a different binary from the one fx-init's
 * own activate handler execs.
 * Returns a malloc'd absolute path, or NULL when nothing executable matches. */
static char *resolve_command(const char *cmd) {
    static const char *const DIRS[] = {
        "bin",
        "usr/fx-core/bin",
        "fx/store/bin",
        "usr/fx-agent/bin",
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
     * by name must not pick up the initramfs copy either), the deployment's
     * agent-payload dir last of the root's. */
    char *bin0 = root_join("bin");
    char *bin1 = root_join("usr/fx-core/bin");
    char *bin2 = root_join("fx/store/bin");
    char *bin3 = root_join("usr/fx-agent/bin");
    if (!bin0 || !bin1 || !bin2 || !bin3) {
        free(bin0); free(bin1); free(bin2); free(bin3);
        return NULL;
    }

    char path[8 * PATH_MAX];
    snprintf(path, sizeof(path), "%s:%s:%s:%s:/bin:/usr/bin", bin0, bin1, bin2, bin3);
    free(bin0);
    free(bin1);
    free(bin2);
    free(bin3);

    char *entries[16];
    size_t n = 0;
    char buf[8 * PATH_MAX];
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

    /* THE IN-GUEST BUILD'S SEATS (fx_build): fxstore resolves its recipe
     * interpreter and its stage3 sandbox binary ONCE at startup from
     * FXSTORE_SH / FXSTORE_STAGE3 — absolute paths, never a PATH lookup.  In
     * the guest the pivoted root has no /bin/sh (fx-init's pivot binds /usr
     * and /lib64 only), so the deployment stages both under
     * <root>/usr/fx-agent/bin and this server points fxstore at them.  Only
     * injected when the seat is actually executable under the root: on a
     * host stub root (or a deployment without the payload) neither key is
     * set and fxstore keeps its own defaults — the host behaviour is
     * unchanged. */
    {
        static const char *const SEATS[] = { "FXSTORE_SH", "FXSTORE_STAGE3" };
        static const char *const PATHS[] = { "usr/fx-agent/bin/sh",
                                             "usr/fx-agent/bin/stage3" };
        for (size_t i = 0; ok && i < sizeof(SEATS) / sizeof(SEATS[0]); i++) {
            char *seat = root_join(PATHS[i]);
            if (!seat) { ok = false; break; }
            if (access(seat, X_OK) == 0) {
                ok = ok && snprintf(buf, sizeof(buf), "%s=%s", SEATS[i], seat) > 0
                     && (entries[n++] = strdup(buf)) != NULL;
            }
            free(seat);
        }
    }

    /* forwarded when present (same list secrets.c forwards, plus FX_RUN so a
     * relocated run dir reaches fxctl children the same way it reaches this
     * server's own native channel client — ctrl_run_dir) */
    static const char *const FWD[] = { "HOME", "LANG", "LC_ALL", "TZ", "TERM",
                                       "XDG_RUNTIME_DIR", "FX_RUN" };
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
 * `cwd` (may be NULL) is a row-pinned working directory the CHILD chdirs to
 * before exec — fx_build's fxstore loads package-set.dhall from its cwd, and
 * the frozen set lives at /usr/fx in the image.  A chdir failure is LOUD
 * (127, naming the dir), never a silent fallback cwd.  Returns 0 with
 * *exitcode set (127 on exec failure, 128+sig on a signal). */
static int run_verb(char **argv, const char *cwd, Capture *out, int *exitcode) {
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
        if (cwd && chdir(cwd) != 0) {
            char msg[PATH_MAX + 128];
            int n = snprintf(msg, sizeof(msg),
                             "fx-verbs: cannot chdir to %s: %s\n",
                             cwd, strerror(errno));
            if (n > 0) {
                ssize_t wr = write(2, msg, (size_t)n);
                (void)wr;
            }
            _exit(127);
        }
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

/* ── THE OPERATOR POLICY SEAT (the ops-policy unit, slice S2) ──────────────
 *
 * An OPERATOR-authored datalog ALLOW/DENY layer consulted at the fx_write
 * commit site — AFTER the writable-set floor passes and BEFORE open(), so a
 * denial is a commit-site fact, not a walk-around-able pre-dispatch table
 * (§7.1c).  THE AUTHOR IS THE OPERATOR, never the agent: the artifacts live
 * at <root>/usr/fx-agent/policy/ — in NO writable set — and are PINNED
 * (policy/ops/PINS); the release path is `make ops-policy-artifact` with
 * artifact + PINS in the same commit.
 *
 * DENY-MORE-ONLY (decided 2026-10-14): the policy may TIGHTEN, never loosen.
 * decision = floor_allows && !denied — the compiled-in writable set above
 * stays the FLOOR, and no rule here can grant anything (the artifact's only
 * head is `denied`, enforced by the pin-time lint).
 *
 * THE VOCABULARY SEAM (the design's load-bearing constraint, MEASURED in S1):
 * le proper nouns are letters-only and fold to lowercased symbols, so a
 * policy that spelled a runtime symbol or path would match NOTHING — a
 * silent allow-all.  The pinned policy is therefore written over the CLOSED
 * ABSTRACT vocabulary (policy/ops/ops-lexicon.ini), and THIS SEAT injects
 * the binding facts from its own tables:
 *
 *   at startup (the resolve):     class(<served path>, <pathclass>)
 *                                 protected(<pathclass>)   [protected=yes rows]
 *   static:                       kind(fx_write, write)
 *   per call (in ops_write_allowed):
 *                                 touches(fx_write, <canon path>)
 *                                 writable(<canon path>)
 *                                 boot_verdict(ok)         [iff the bootlog's
 *                                  newest ok|failed verdict reads ok]
 *
 * THE SERVED SET is the canonicalized FX_AGENT_WRITABLE entries — the paths
 * this seat can actually commit — so an alias resolves against what the seat
 * SERVES, never against a wish (the S1 review's resolve-set obligation).
 * Two loud startup refusals pin the table's honesty, both directions:
 *   - a PROTECTED alias matching NO served path (the silent allow-all it
 *     would buy), and
 *   - a SERVED path covered by NO row (an unclassified writable path —
 *     untightened, not loosened, but refused loudly, never silently
 *     unguarded).
 * The protected-direction check is scoped to a NON-EMPTY served set: with
 * nothing writable the floor refuses everything and there is no allow-all
 * to guard.
 *
 * THE PIN: every file PINS names must exist here with the pinned sha256
 * (sha256_hex, the vendored dhall-c hash) BEFORE any of it is believed.  A
 * PRESENT-but-stale or swapped artifact is a LOUD STARTUP REFUSAL naming
 * both shas — never a silent allow-all; the failed service exit propagates
 * into fx-init's boot verdict.  An ABSENT policy dir is the NAMED
 * floor-only state (one startup line), never an error and never silent.
 *
 * STARTUP SNAPSHOT (P7's risk, the evaluated-at-the-wrong-moment class):
 * the artifact is read and its rules compiled ONCE here; per-call facts —
 * the ONLY thing that moves — are computed fresh per call.  A mid-run swap
 * of the files cannot change a decision; a restart with a swapped file dies
 * on the pin check.
 *
 * MEASURED (C engine, this host): startup open+declare ~27 ms and
 * dl_load_rules ~10 ms after first-touch (the process' FIRST engine touch
 * costs ~0.5 s of page-in — once per server spawn); the per-call
 * dl_query(denied) 0.37 ms; the denial path's per-rule attribution
 * (dl_query_rules_ro) ~1.1 ms per rule.
 */
#define FXV_OPS_DIR_REL "usr/fx-agent/policy"
#define FXV_OPS_DL      "ops-policy.dl"
#define FXV_OPS_TSV     "ops-aliases.tsv"
#define FXV_OPS_PINS    "PINS"
#define FXV_OPS_MAX_FILE (1024u * 1024u) /* the artifact cap, FXV_MAX_LINE's */

typedef struct {
    char *alias;        /* the raw tsv surface, for the refusals */
    char *alias_folded; /* its FOLDED symbol (le's proper-noun fold); the
                         * duplicate check runs on the FOLDED form, matching
                         * eval_ops.py --check-aliases */
    char *pathclass;    /* the raw surface, for the refusals */
    char *class_sym;    /* FOLDED — the symbol the class and protected facts
                         * carry (the folding contract) */
    int   prot;     /* the yes/no column: D1's protected facts ride on it */
    char *pattern;  /* EXACT '<path>' or SUBTREE ('<path>' + the two-star
                     * slash tail) — never a prefix */
} OpsAliasRow;

static struct {
    int           present;  /* 0 = floor-only mode */
    dl_db        *db;
    char          scratch[PATH_MAX]; /* the scratch db dir (removed at exit) */
    char          sha[65];     /* the pinned .dl sha (the serverInfo state) */
    char         *dl_text;       /* the artifact's bytes */
    char        **rule;          /* its rule lines, for per-rule attribution */
    size_t        n_rule;
    OpsAliasRow  *row;
    size_t        n_row;
    size_t        n_served;      /* canonicalized writable-set entries */
    size_t        n_class;       /* class facts the resolve injected */
} OPS;

/* A LOUD startup refusal: exit nonzero, naming the fault on stderr.  The
 * mcp client /dev/null's this server's stderr (mcp_client.c) — there the
 * refusal IS the failed spawn (initialize never answers, the boot verdict
 * turns FAILED); stand-alone, the line is on the console. */
static void ops_die(const char *fmt, ...) {
    fputs("fx-verbs: ops-policy REFUSED: ", stderr);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

/* Best-effort scratch-db removal (flat engine files; no shell, no system(3)). */
static void ops_rm_rf(const char *dir, int depth) {
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) continue;
        char *child = malloc(strlen(dir) + 1 + strlen(de->d_name) + 1);
        if (!child) break;
        sprintf(child, "%s/%s", dir, de->d_name);
        if (unlink(child) != 0 && errno == EISDIR && depth < 4)
            ops_rm_rf(child, depth + 1);
        free(child);
    }
    closedir(d);
    rmdir(dir);
}

static void ops_policy_shutdown(void) {
    if (OPS.db) { dl_close(OPS.db); OPS.db = NULL; }
    if (OPS.scratch[0]) { ops_rm_rf(OPS.scratch, 0); OPS.scratch[0] = '\0'; }
}

/* defined below (the PID1 control-channel section): the scratch db's parent */
static char *ctrl_run_dir(void);

static char *ops_read_file(const char *path, size_t *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    size_t cap = 8192, len = 0;
    char *buf = malloc(cap + 1);
    if (!buf) { fclose(f); return NULL; }
    for (;;) {
        if (len == cap) {
            if (cap >= FXV_OPS_MAX_FILE) {
                /* the CAP path is not a read failure: name it as one, or the
                 * caller's strerror prints the stale errno (F5: a pinned
                 * file over the cap read as "MISSING ... Success") */
                errno = EFBIG;
                free(buf); fclose(f); return NULL;
            }
            cap *= 2;
            char *nb = realloc(buf, cap + 1);
            if (!nb) { free(buf); fclose(f); return NULL; }
            buf = nb;
        }
        size_t n = fread(buf + len, 1, cap - len, f);
        len += n;
        if (n == 0) break;
    }
    if (ferror(f)) { free(buf); fclose(f); return NULL; }
    fclose(f);
    buf[len] = '\0';
    if (len_out) *len_out = len;
    return buf;
}

/* THE PIN CHECK: every file PINS names must exist with the pinned sha256.
 * Names BOTH shas on a mismatch — the operator's diagnosis is "which bytes
 * did I expect vs which bytes am I holding".  Also demands that the two
 * files the seat LOADS (the .dl and the alias table) are pinned at all: a
 * PINS that omitted them would silently skip their verification.
 * F4 (the S2 review): the verified bytes are KEPT and handed to the loaders
 * through dl_out/tsv_out — re-reading the files after the hash check would
 * open a window where a swap loads unverified bytes.  dl_sha_out (65 bytes)
 * receives the pinned .dl sha for the startup line and serverInfo. */
static void ops_verify_pins(const char *dir, const char *pins_path,
                            char **dl_out, char **tsv_out, char *dl_sha_out) {
    size_t plen = 0;
    char *pins = ops_read_file(pins_path, &plen);
    if (!pins)
        ops_die("%s cannot be read: %s — a present policy dir must carry a "
                "verifiable pin set", pins_path, strerror(errno));
    int saw_dl = 0, saw_tsv = 0;
    char *save = NULL;
    for (char *line = strtok_r(pins, "\n", &save); line;
         line = strtok_r(NULL, "\n", &save)) {
        while (*line == ' ' || *line == '\t') line++;
        if (!*line || *line == '#') continue;
        char *tab = strchr(line, '\t');
        if (!tab) ops_die("%s: a pin row is name<TAB>sha256, got '%.80s'",
                          pins_path, line);
        *tab = '\0';
        char *name = line, *want = tab + 1;
        char *nl = strchr(want, '\r');
        if (nl) *nl = '\0';
        int is_dl = strcmp(name, FXV_OPS_DL) == 0;
        int is_tsv = strcmp(name, FXV_OPS_TSV) == 0;
        if (is_dl) saw_dl = 1;
        if (is_tsv) saw_tsv = 1;
        size_t flen = 0;
        char path[PATH_MAX];
        int n = snprintf(path, sizeof path, "%s/%s", dir, name);
        if (n <= 0 || n >= (int)sizeof path) ops_die("pin path too long: %s", name);
        char *bytes = ops_read_file(path, &flen);
        if (!bytes)
            ops_die("pinned file %s is MISSING or unreadable (: %s) "
                    "(pinned sha256 %s) — no such file, or it is over the "
                    "%u-byte artifact cap; restore it or re-pin",
                    path, strerror(errno), want, FXV_OPS_MAX_FILE);
        char got[65];
        sha256_hex(bytes, flen, got);
        if (strcmp(got, want) != 0) {
            free(bytes);
            ops_die("pinned file %s sha256 mismatch: pinned %s != actual %s "
                    "— the deployed artifact is stale or swapped; a policy "
                    "edit is a re-pin (artifact + PINS in the same release)",
                    path, want, got);
        }
        /* verified: the LOADED files are the bytes just hashed */
        if (is_dl) {
            free(*dl_out);
            *dl_out = bytes;
            snprintf(dl_sha_out, 65, "%s", want);
        } else if (is_tsv) {
            free(*tsv_out);
            *tsv_out = bytes;
        } else {
            free(bytes);
        }
    }
    free(pins);
    if (!saw_dl || !saw_tsv)
        ops_die("%s does not pin both %s and %s — the loaded artifacts would "
                "go unverified", pins_path, FXV_OPS_DL, FXV_OPS_TSV);
}

/* THE PATTERN GRAMMAR — the TWO FORMS policy/ops/ops-aliases.tsv states and
 * eval_ops.py --check-aliases enforces at pin time, implemented for the
 * resolve (the seat does not trust the staging to have been checked):
 *   EXACT   '<path>'   glob-less; matches that one path, NEVER a prefix
 *   SUBTREE            '<path>' plus a slash and two asterisks: the path
 *                      itself and every descendant
 * Anything else (a lone '*', '?', '[', '**' off the tail, a trailing '/',
 * a subtree base ending in '/' — it can never match a canonical path) is a
 * LOUD startup refusal: coverage nobody stated is the silent allow-all. */
static int ops_glob_char(const char *s) {
    return strpbrk(s, "*?[") != NULL;
}

static int ops_pattern_valid(const char *p) {
    size_t l = strlen(p);
    if (l < 2 || p[0] != '/') return 0;
    if (l >= 3 && strcmp(p + l - 3, "/**") == 0) {
        size_t bl = l - 3;
        if (bl < 2 || p[0] != '/' || p[bl - 1] == '/') return 0;
        char base[PATH_MAX];
        if (bl >= sizeof base) return 0;
        memcpy(base, p, bl); base[bl] = '\0';
        return !ops_glob_char(base);
    }
    if (p[l - 1] == '/') return 0;
    return !ops_glob_char(p);
}

static int ops_pattern_hits(const char *pattern, const char *canon) {
    size_t pl = strlen(pattern);
    if (pl >= 3 && strcmp(pattern + pl - 3, "/**") == 0) {
        size_t bl = pl - 3;
        size_t cl = strlen(canon);
        if (cl < bl || strncmp(canon, pattern, bl) != 0) return 0;
        return cl == bl || canon[bl] == '/';
    }
    return strcmp(canon, pattern) == 0;
}

/* The FOLD (the folding contract, seat half — F1): le compiles a proper noun
 * (CAPITALISED letters-only, le/lexicon.py:157) to its LOWERCASED dl symbol
 * (le/binding.py:144 — `Configpath` -> `configpath`), so that folded symbol
 * is what a LEGAL operator rule spells after compilation.  The seat folds the
 * alias table's surfaces the same way before interning: injecting the RAW
 * surface would never match a legal rule's folded constant — a policy that
 * stops matching stops protecting, silently.  A surface that is not ASCII
 * letters-only is REFUSED here rather than folded: le could never compile it
 * into a constant, so it could only ever non-match (the same silent
 * allow-all in another spelling; eval_ops.py --check-aliases owns lexicon
 * MEMBERSHIP at pin time, this owns shape).  Returns 0 on a non-proper
 * surface. */
static int ops_fold_proper(char *dst, size_t dstsz, const char *src) {
    size_t l = strlen(src);
    if (l == 0 || l >= dstsz) return 0;
    for (size_t i = 0; i < l; i++) {
        unsigned char c = (unsigned char)src[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return 0;
        dst[i] = (char)(c | 0x20);
    }
    dst[l] = '\0';
    return 1;
}

/* The alias table: alias<TAB>pathclass<TAB>protected<TAB>pattern, '#'
 * comments — parsed and VALIDATED here (grammar above, duplicate aliases,
 * the yes/no flag), because a malformed row must refuse loudly, never
 * half-match.  `tsv_owned` is the verified bytes ops_verify_pins kept (F4);
 * `path` names the file in the refusals.  A trailing CR is stripped per line
 * (F5: a CRLF table used to validate as an exact pattern with a trailing
 * \r — a shape that can never match, refused under a confusing name). */
static void ops_load_aliases(const char *path, char *tsv_owned) {
    char *tsv = tsv_owned;
    size_t cap = 8;
    OPS.row = malloc(cap * sizeof *OPS.row);
    if (!OPS.row) ops_die("out of memory");
    char *save = NULL;
    for (char *line = strtok_r(tsv, "\n", &save); line;
         line = strtok_r(NULL, "\n", &save)) {
        while (*line == ' ' || *line == '\t') line++;
        size_t ll = strlen(line);
        if (ll > 0 && line[ll - 1] == '\r') line[ll - 1] = '\0';
        if (!*line || *line == '#') continue;
        char *f[4];
        int nf = 0;
        char *lsave = NULL;
        for (char *tok = strtok_r(line, "\t", &lsave); tok && nf < 4;
             tok = strtok_r(NULL, "\t", &lsave))
            f[nf++] = tok;
        if (nf != 4)
            ops_die("%s: an alias row is alias<TAB>pathclass<TAB>protected"
                    "<TAB>pattern, got %d field(s)", path, nf);
        if (strcmp(f[2], "yes") != 0 && strcmp(f[2], "no") != 0)
            ops_die("%s: the protected flag is '%s', not yes|no", path, f[2]);
        if (!ops_pattern_valid(f[3]))
            ops_die("%s: the pattern '%s' is neither of the two stated forms "
                    "— an EXACT glob-less path or a SUBTREE '<path>/**'",
                    path, f[3]);
        if (OPS.n_row == cap) {
            cap *= 2;
            OpsAliasRow *nr = realloc(OPS.row, cap * sizeof *OPS.row);
            if (!nr) ops_die("out of memory");
            OPS.row = nr;
        }
        OpsAliasRow *r = &OPS.row[OPS.n_row];
        r->alias = strdup(f[0]);
        r->pathclass = strdup(f[1]);
        r->pattern = strdup(f[3]);
        r->alias_folded = malloc(strlen(f[0]) + 1);
        r->class_sym = malloc(strlen(f[1]) + 1);
        if (!r->alias || !r->pathclass || !r->pattern ||
            !r->alias_folded || !r->class_sym) ops_die("out of memory");
        if (!ops_fold_proper(r->alias_folded, strlen(f[0]) + 1, f[0]))
            ops_die("%s: the alias '%s' is not a proper noun (ASCII letters "
                    "only) — le compiles proper nouns to their lowercased "
                    "symbol, so any other shape could only ever match nothing",
                    path, f[0]);
        if (!ops_fold_proper(r->class_sym, strlen(f[1]) + 1, f[1]))
            ops_die("%s: the pathclass '%s' is not a proper noun (ASCII "
                    "letters only) — le compiles proper nouns to their "
                    "lowercased symbol, so any other shape could only ever "
                    "match nothing", path, f[1]);
        for (size_t i = 0; i < OPS.n_row; i++)
            if (strcmp(OPS.row[i].alias_folded, r->alias_folded) == 0)
                ops_die("%s: the alias '%s' is mapped twice", path, f[0]);
        OPS.n_row++;
        r->prot = (strcmp(f[2], "yes") == 0);
    }
    free(tsv);
    if (OPS.n_row == 0)
        ops_die("%s carries no alias rows — the vocabulary seam's binding "
                "table is empty and every served path would be unclassified",
                path);
}

/* A grown-on-demand string vector (the served set). */
typedef struct { char **v; size_t n, cap; } OpsVec;

static void ops_vec_push(OpsVec *s, char *owned) {
    if (s->n == s->cap) {
        s->cap = s->cap ? s->cap * 2 : 8;
        char **nv = realloc(s->v, s->cap * sizeof *nv);
        if (!nv) ops_die("out of memory");
        s->v = nv;
    }
    s->v[s->n++] = owned;
}

static int ops_vec_has(const OpsVec *s, const char *x) {
    for (size_t i = 0; i < s->n; i++)
        if (strcmp(s->v[i], x) == 0) return 1;
    return 0;
}

/* THE POLICY'S PATH SPELLING: the alias patterns and the facts carry the
 * GUEST-ABSOLUTE path ("/fx/disk/agent-config.dhall") — the spelling the
 * pinned table declares and the driver's fact fixtures use; canon_root_rel
 * yields the ROOT-RELATIVE form the writable-set floor compares in.  In the
 * guest root == "/", so "/"+canon IS the runtime path; under a stub root it
 * is the same declared spelling the floor's entries use. */
static char *ops_abs_of(const char *canon) {
    size_t cl = strlen(canon);
    char *abs = malloc(cl + 2);
    if (!abs) ops_die("out of memory");
    abs[0] = '/';
    memcpy(abs + 1, canon, cl + 1);
    return abs;
}

/* THE RESOLVE: the served set is the canonicalized writable-set entries
 * (EXACTLY in_writable_set's normalization, collected instead of compared —
 * the floor code is not touched), spelled the policy's way (guest-absolute).
 * Every served path must be covered by a row (loud refusal otherwise);
 * covered paths get their class fact, and a protected=yes row's class gets
 * the protected fact.  All fact adds are checked: the folding contract
 * (inject FOLDED symbols) is machine-checked here — a failed add refuses
 * startup, never silently proceeds. */
static void ops_resolve_and_declare(void) {
    OpsVec served = {0};
    const char *set = writable_set();
    const char *e = set;
    while (e && *e) {
        while (*e == ':') e++;
        if (!*e) break;
        const char *end = e;
        while (*end && *end != ':') end++;
        size_t el = (size_t)(end - e);
        char ent[PATH_MAX];
        if (el > 0 && el < sizeof ent) {
            memcpy(ent, e, el); ent[el] = '\0';
            char *cent;
            if (ent[0] == '/') {
                cent = canon_root_rel(ent);
            } else {
                char abs[PATH_MAX];
                int n = snprintf(abs, sizeof abs, "/%s", ent);
                cent = (n > 0 && n < (int)sizeof abs) ? canon_root_rel(abs) : NULL;
            }
            if (cent) {
                char *abs = ops_abs_of(cent);
                free(cent);
                if (!ops_vec_has(&served, abs)) ops_vec_push(&served, abs);
                else free(abs);
            }
        }
        e = end;
    }
    OPS.n_served = served.n;

    for (size_t i = 0; i < served.n; i++) {
        int covered = 0;
        for (size_t r = 0; r < OPS.n_row; r++) {
            if (!ops_pattern_hits(OPS.row[r].pattern, served.v[i])) continue;
            covered = 1;
            /* F1: the class symbol is the FOLDED pathclass surface — the
             * dl symbol le compiles a legal "the path is of the pathclass
             * Configpath" sentence to.  The raw surface ('Configpath') would
             * never match it: the rule would silently stop protecting. */
            uint32_t c[2] = { dl_intern_str(OPS.db, served.v[i]),
                              dl_intern_str(OPS.db, OPS.row[r].class_sym) };
            if (!c[0] || !c[1] || dl_add_fact(OPS.db, "class", c, 2) < 0)
                ops_die("cannot inject the class fact for %s (the folding "
                        "contract is machine-checked: a failed add refuses, "
                        "never silently proceeds)", served.v[i]);
            OPS.n_class++;
            if (OPS.row[r].prot) {
                uint32_t p[1] = { dl_intern_str(OPS.db, OPS.row[r].class_sym) };
                if (!p[0] || dl_add_fact(OPS.db, "protected", p, 1) < 0)
                    ops_die("cannot inject the protected fact for %s",
                            OPS.row[r].pathclass);
            }
        }
        if (!covered)
            ops_die("the served writable path %s is covered by NO alias row "
                    "in %s — an unclassified writable path is refused loudly, "
                    "never silently unguarded; add a row (and re-pin)",
                    served.v[i], FXV_OPS_TSV);
    }
    /* the protected direction, scoped to a non-empty served set (with
     * nothing writable the floor refuses everything — no allow-all to guard) */
    if (served.n > 0) {
        for (size_t r = 0; r < OPS.n_row; r++) {
            if (!OPS.row[r].prot) continue;
            int hit = 0;
            for (size_t i = 0; i < served.n; i++)
                if (ops_pattern_hits(OPS.row[r].pattern, served.v[i])) hit = 1;
            if (!hit)
                ops_die("the PROTECTED alias '%s' (pattern %s) matches NO "
                        "served writable path — it would protect nothing "
                        "while the policy and the pin say it does (the "
                        "silent allow-all); fix the pattern and re-pin",
                        OPS.row[r].alias, OPS.row[r].pattern);
        }
    }
    for (size_t i = 0; i < served.n; i++) free(served.v[i]);
    free(served.v);
}

/* STARTUP: the whole policy load, or the named floor-only state.  Called
 * once from main() before the frame loop. */
static void ops_policy_startup(void) {
    memset(&OPS, 0, sizeof OPS);
    char *dir = root_join(FXV_OPS_DIR_REL);
    if (!dir) ops_die("cannot resolve " FXV_OPS_DIR_REL " under FX_VERB_ROOT");
    struct stat st;
    int empty = 0;
    if (stat(dir, &st) == 0 && S_ISDIR(st.st_mode)) {
        /* an EMPTY dir is also "no operator policy" (a fresh image's staging
         * point), but a NON-EMPTY dir without a verifiable pin set is a
         * broken release and refuses below */
        DIR *d = opendir(dir);
        if (d) {
            struct dirent *de;
            empty = 1;
            while ((de = readdir(d)) != NULL) {
                if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
                    continue;
                empty = 0;
                break;
            }
            closedir(d);
        }
    }
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode) || empty) {
        /* THE NAMED FLOOR-ONLY STATE: no operator policy is a state of the
         * deployment, stated once — never an error, never a silent
         * allow-all (deny-more-only: the floor governs alone). */
        fprintf(stderr, "fx-verbs: ops-policy: no operator policy at %s "
                        "(FX_VERB_ROOT=%s) — floor-only mode: the "
                        "compiled-in writable set governs alone\n",
                dir, fx_root());
        free(dir);
        return;
    }

    char pins_path[PATH_MAX], dl_path[PATH_MAX], tsv_path[PATH_MAX];
    snprintf(pins_path, sizeof pins_path, "%s/%s", dir, FXV_OPS_PINS);
    snprintf(dl_path, sizeof dl_path, "%s/%s", dir, FXV_OPS_DL);
    snprintf(tsv_path, sizeof tsv_path, "%s/%s", dir, FXV_OPS_TSV);
    /* F4: verify AND KEEP — the .dl/tsv bytes are the ones just hashed, so
     * no window exists where a swap loads unverified bytes. */
    char *tsv_bytes = NULL;
    ops_verify_pins(dir, pins_path, &OPS.dl_text, &tsv_bytes, OPS.sha);
    ops_load_aliases(tsv_path, tsv_bytes);

    /* the scratch db: the engine holds the compiled rules and this boot's
     * policy facts — process-lifetime state, nothing on the store, removed
     * at exit (registered NOW so a later refusal still cleans up).
     * F3: it lives under the run dir — /run in the guest, <root>/run under a
     * stub — NOT /tmp: the landlock-fallback lane unveils the REAL /tmp rwc
     * (fxstore's build.zig), so same-uid recipe code could replace the
     * backing store with a VALID-BUT-EMPTY db (rows=0 => allow, the
     * dangerous direction); /run is unveiled in neither lane. */
    {
        char *rd = ctrl_run_dir();
        if (!rd || !*rd)
            ops_die("cannot resolve the run dir for the policy scratch db");
        char parent[PATH_MAX];
        int n = snprintf(parent, sizeof parent, "%s/ops", rd);
        free(rd);
        if (n <= 0 || n >= (int)sizeof parent)
            ops_die("run dir too long for the policy scratch db");
        for (char *s = parent + 1; *s; s++) {
            if (*s != '/') continue;
            *s = '\0';
            if (mkdir(parent, 0700) != 0 && errno != EEXIST)
                ops_die("cannot create %s for the policy scratch db: %s — "
                        "a present policy must be loadable, never silently "
                        "skipped", parent, strerror(errno));
            *s = '/';
        }
        if (mkdir(parent, 0700) != 0 && errno != EEXIST)
            ops_die("cannot create %s for the policy scratch db: %s — "
                    "a present policy must be loadable, never silently "
                    "skipped", parent, strerror(errno));
        n = snprintf(OPS.scratch, sizeof OPS.scratch, "%s/ops-XXXXXX", parent);
        if (n <= 0 || n >= (int)sizeof OPS.scratch)
            ops_die("run dir too long for the policy scratch db");
    }
    if (!mkdtemp(OPS.scratch))
        ops_die("cannot create the policy scratch db under the run dir "
                "(%s): %s — a present policy must be loadable, never "
                "silently skipped", OPS.scratch, strerror(errno));
    atexit(ops_policy_shutdown);
    int derr = 0;
    OPS.db = dl_open2(OPS.scratch, &derr);
    if (!OPS.db)
        ops_die("cannot open the policy scratch db %s (err %d)", OPS.scratch, derr);
    /* THE CLOSED RELATION SET — exactly the ops lexicon's templates plus the
     * one head (ops-lexicon.ini [predicates]).  A pinned artifact whose atoms
     * fall outside it fails dl_load_rules by name (the engine refuses an
     * undeclared predicate — MEASURED), so relation-level drift is loud.
     * S2: `hosttool` is DECLARED so the SAME artifact (now carrying D3) loads
     * here, but this seat NEVER injects a hosttool fact (host tools are a
     * host-side vocabulary) — so D3 is INERT IN-GUEST, exactly as D2 is inert
     * at the host seat.  The in-guest seat keeps D2; it adds no host-tool
     * denial of its own. */
    if (dl_declare_relation(OPS.db, "denied", 2) != 0 ||
        dl_declare_relation(OPS.db, "touches", 2) != 0 ||
        dl_declare_relation(OPS.db, "kind", 2) != 0 ||
        dl_declare_relation(OPS.db, "class", 2) != 0 ||
        dl_declare_relation(OPS.db, "protected", 1) != 0 ||
        dl_declare_relation(OPS.db, "writable", 1) != 0 ||
        dl_declare_relation(OPS.db, "hosttool", 1) != 0 ||
        dl_declare_relation(OPS.db, "boot_verdict", 1) != 0)
        ops_die("cannot declare the closed relation set in %s", OPS.scratch);
    if (dl_load_rules(OPS.db, OPS.dl_text) != 0)
        ops_die("%s: the engine refused the pinned rules (see the engine's "
                "diagnostic above) — a pinned artifact the engine cannot "
                "load is a broken release, never a floor-only fallback", dl_path);

    /* the rule lines, split for per-rule attribution (the head rename) */
    for (char *p = OPS.dl_text; *p; ) {
        while (*p == '\n' || *p == '\r' || *p == ' ' || *p == '\t') p++;
        if (!*p) break;
        char *end = p;
        while (*end && *end != '\n' && *end != '\r') end++;
        int ended = *end != '\0';
        *end = '\0';
        if (!ended) end = NULL;
        char **nr = realloc(OPS.rule, (OPS.n_rule + 1) * sizeof *OPS.rule);
        if (!nr) ops_die("out of memory");
        OPS.rule = nr;
        OPS.rule[OPS.n_rule++] = p;
        if (!end) break;
        p = end + 1;
    }
    if (OPS.n_rule == 0)
        ops_die("%s carries no rules (policy-vacuous) — an artifact the "
                "release path's lint refuses cannot be served as a policy",
                dl_path);

    ops_resolve_and_declare();

    /* THE FOLDING CONTRACT, static half, machine-checked: the seat injects
     * FOLDED symbols (Write -> write).  Per call, the canon path is always a
     * served path (the floor passed => an exact writable-set member => it
     * was in the resolve set), so its class fact exists by the resolve's
     * checked adds — the per-call half of the contract holds by construction
     * and is pinned by the gate's deny-direction arms. */
    {
        uint32_t k[2] = { dl_intern_str(OPS.db, "fx_write"),
                          dl_intern_str(OPS.db, "write") };
        if (!k[0] || !k[1] || dl_add_fact(OPS.db, "kind", k, 2) < 0)
            ops_die("cannot inject the kind fact for fx_write (the folding "
                    "contract is machine-checked)");
    }

    char sha[65] = "(none)";
    snprintf(sha, sizeof sha, "%.16s…", OPS.sha); /* captured at verify (F4) */
    fprintf(stderr, "fx-verbs: ops-policy: loaded %s (sha256 %s, %zu rule(s), "
                    "%zu alias row(s), %zu served writable path(s), %zu class "
                    "fact(s))\n",
            dir, sha, OPS.n_rule, OPS.n_row, OPS.n_served, OPS.n_class);
    OPS.present = 1; /* LAST: nothing above may observe a half-loaded policy */
    free(dir);
}

/* THE BOOT VERDICT, computed FRESH PER CALL — the per-call facts are the
 * only thing that moves (the R3 wrong-moment risk), so the verdict is never
 * cached across calls.  The source is outcome.c's bootlog reader — the SAME
 * read fx_outcome reports from — one reader, no drift.  ok => inject
 * boot_verdict(ok); absent/unreadable/failed/in-progress/shutdown => inject
 * NOTHING, and D2's negation (!boot_verdict(ok)) denies: fail-closed, the
 * exact shape the pinned rule encodes ("it is not the case that Ok is the
 * boot verdict" — a shutdown or in-flight last line is not ok either). */
static int ops_boot_ok(void) {
    char *store = store_if_present();
    if (!store) return 0;
    FxBootlog bl;
    int rc = fx_outcome_bootlog_read(store, NULL, NULL, &bl);
    free(store);
    if (rc != 0 || bl.absent || !bl.have_last) return 0;
    return strcmp(bl.last_status, "ok") == 0;
}

static int ops_collect_count_cb(const uint32_t *cols, uint8_t arity, void *u) {
    (void)cols; (void)arity;
    (*(size_t *)u)++;
    return 0;
}

/* An engine fault on the decision path is fail-CLOSED: an unconsultable
 * policy refuses, it never allows (deny-more-only's own direction). */
static int ops_engine_fail(Capture *out, const char *why) {
    cap_append_str(out, "fx-verbs: fx_write REFUSED: ops-policy engine error: ");
    cap_append_str(out, why);
    cap_append_str(out, " (fail-closed: an unconsultable policy refuses, "
                        "it never allows)\n");
    fprintf(stderr, "fx-verbs: ops-policy engine error: %s\n", why);
    return 0;
}

/* THE PER-CALL DECISION.  Returns 1 when the policy is SILENT (the floor's
 * verdict stands — it never permits), 0 when it DENIES (the refusal is
 * appended to `out` and mirrored to stderr).  Injects the per-call facts,
 * queries the pinned rules, retracts the facts (collect-then-mutate,
 * runstore.h's discipline — MEASURED: the retraction also retracts the
 * derived denied rows, so nothing LATCHES across calls). */
static int ops_write_allowed(const char *canon, Capture *out) {
    if (!OPS.present) return 1;

    char *apath = ops_abs_of(canon); /* the policy's guest-absolute spelling */
    uint32_t w = dl_intern_str(OPS.db, "fx_write");
    uint32_t p = dl_intern_str(OPS.db, apath);
    uint32_t tp[2] = { w, p };
    uint32_t pp[1] = { p };
    if (!w || !p ||
        dl_add_fact(OPS.db, "touches", tp, 2) < 0 ||
        dl_add_fact(OPS.db, "writable", pp, 1) < 0) {
        free(apath);
        return ops_engine_fail(out, "cannot inject the per-call facts");
    }

    int boot_ok = ops_boot_ok();
    uint32_t ok = dl_intern_str(OPS.db, "ok");
    uint32_t bv[1] = { ok };
    int have_bv = 0;
    if (boot_ok) {
        if (!ok || dl_add_fact(OPS.db, "boot_verdict", bv, 1) < 0) {
            free(apath);
            return ops_engine_fail(out, "cannot inject the boot verdict");
        }
        have_bv = 1;
    }

    size_t rows = 0;
    if (dl_query(OPS.db, "denied", ops_collect_count_cb, &rows) < 0) {
        free(apath);
        return ops_engine_fail(out, "dl_query(denied) failed");
    }

    /* PER-RULE ATTRIBUTION (denial path only): the derived relation holds
     * DEDUPLICATED TUPLES with no rule provenance (MEASURED: D1+D2 on one
     * path is ONE row), so "which rule fired" is re-asked per rule line:
     * each artifact rule is evaluated on a SHALLOW CLONE (dl_query_rules_ro
     * — read-only, the live db untouched) with its HEAD RENAMED, because the
     * clone carries this call's materialized denied rows and a same-head
     * query would return them whatever the body (MEASURED).  Only the HEAD
     * atom is renamed; a body reference to `denied` (a recursive policy —
     * the pinned one has none) would read the clone's materialized rows, so
     * a future recursive rule must come with its own attribution design. */
    int fired[32];
    size_t n_fired = 0;
    if (rows > 0) {
        for (size_t i = 0; i < OPS.n_rule && n_fired < 32; i++) {
            const char *rl = OPS.rule[i];
            if (strlen(rl) > 1024) continue;
            if (memcmp(rl, "denied(", 7) != 0) continue; /* the lint's head */
            char prog[1200], goal[32];
            snprintf(goal, sizeof goal, "ops_r%zu", i + 1);
            int n = snprintf(prog, sizeof prog, "%s%s", goal, rl + 6);
            if (n <= 0 || n >= (int)sizeof prog) continue;
            size_t rn = 0;
            if (dl_query_rules_ro(OPS.db, prog, goal, ops_collect_count_cb, &rn) >= 0
                && rn > 0)
                fired[n_fired++] = (int)i;
        }
    }

    /* retract the per-call facts; a failed retraction would LATCH this
     * call's facts onto the next, so it refuses loudly (fail-closed). */
    int delbad = 0;
    if (dl_delete_fact(OPS.db, "touches", tp, 2) < 0 ||
        dl_delete_fact(OPS.db, "writable", pp, 1) < 0 ||
        (have_bv && dl_delete_fact(OPS.db, "boot_verdict", bv, 1) < 0))
        delbad = 1;

    if (rows == 0) {
        free(apath);
        if (delbad)
            return ops_engine_fail(out, "cannot retract the per-call facts");
        return 1;
    }

    /* THE DENIAL, in the floor-refusal's shape, one line per FIRED rule.
     * The rule number is POSITIONAL over the artifact's own rule order —
     * ops-policy.le names its rules D1..Dn in that order and the compile is
     * deterministic (the gate re-compiles and demands byte-equality) — while
     * the quoted text, the artifact's own rule, is the authority.  The same
     * lines go to stderr: harness-driven, the client /dev/null's stderr and
     * this tool result is the durable record (the transcript); stand-alone,
     * stderr is the console. */
    cap_append_str(out, "fx-verbs: fx_write REFUSED: the operator policy "
                        "denies this write\n");
    if (n_fired == 0) {
        cap_append_str(out, "policy ops-policy: denied (no rule attributed — "
                            "the artifact and the engine disagree; refusing, "
                            "never allowing)\n");
    }
    for (size_t i = 0; i < n_fired; i++) {
        char line[1400];
        int n = snprintf(line, sizeof line,
                         "policy ops-policy rule D%d: %s (verb fx_write, "
                         "path %s, boot verdict %s)\n",
                         fired[i] + 1, OPS.rule[fired[i]], apath,
                         boot_ok ? "ok" : "not ok");
        if (n > 0) {
            cap_append_str(out, line);
            fputs(line, stderr);
        }
    }
    if (delbad) {
        cap_append_str(out, "policy ops-policy: the per-call facts could not "
                            "be retracted (fail-closed; the NEXT decision "
                            "refuses until the engine is clean)\n");
    }
    free(apath);
    return 0;
}

/* ── the PID1 control channel (fx_activate's route) ─────────────────────── */

/* defined below the native verbs (the JSON reply senders) */
static int send_error(yyjson_val *idv, int code, const char *msg);
static int send_capture_reply(yyjson_val *idv, Capture *out, int exitcode);

/* The run dir holding the fifo pair: FX_RUN when the deployment sets it
 * (fxctl's own rule, absolute), else <root>/run/fx — so a host stub root
 * (FX_VERB_ROOT=/tmp/stub) finds the pair at /tmp/stub/run/fx exactly as the
 * guest (root /) finds /run/fx, PID1's g_run.  Returns a malloc'd dir or
 * NULL.  The SERVER's own env is read (not the child whitelist): the native
 * client does not fork. */
static char *ctrl_run_dir(void) {
    const char *r = getenv("FX_RUN");
    if (r && *r) {
        char *out = strdup(r);
        while (out && *out && out[strlen(out) - 1] == '/')
            out[strlen(out) - 1] = '\0';
        return out;
    }
    return root_join("run/fx");
}

/* fxctl's LINE_MAX_REQ: the request line (body + '\n') is capped at 4096 =
 * PIPE_BUF exactly, so one write(2) of the whole line is atomic. */
#define FXV_CTRL_LINE_MAX 4096

/* The total reply budget.  NOT fxctl's 5s: PID1 answers only AFTER its whole
 * activate handler ran (the fx-activate child + facts re-read + the live-root
 * re-materialization), and MEASURED that takes ~63s on this class of store —
 * see the header.  600s is beyond every caller's patience, so the budget's
 * real job is to fail LOUDLY when PID1 never answers (its one EAGAIN-drop
 * path), never to bound a healthy activation. */
#define FXV_CTRL_BUDGET_MS 600000L

/* One line's classification, EXACTLY fxctl's classifyLine: "OK" terminates
 * success, "ERR" followed by end-of-line/space/tab terminates refusal
 * (so "ERRSUFFIX" is a data line), everything else — the empty line
 * included — is data.  PID1 is the grammar's authority; duplicating its
 * client's classifier keeps the pair byte-compatible. */
typedef enum { CTRL_LINE_OK, CTRL_LINE_ERR, CTRL_LINE_DATA } CtrlLineKind;

static CtrlLineKind ctrl_classify(const char *line, size_t len) {
    if (len == 2 && memcmp(line, "OK", 2) == 0) return CTRL_LINE_OK;
    if (len >= 3 && memcmp(line, "ERR", 3) == 0 &&
        (len == 3 || line[3] == ' ' || line[3] == '\t')) return CTRL_LINE_ERR;
    return CTRL_LINE_DATA;
}

/* Run `activate <config>` through PID1's fifo pair.  Returns 0 having filled
 * `out` (PID1's data lines and/or the refusal text) and `exitcode` (0 on OK,
 * 1 on ERR / transport failure).  Returns -1 ONLY when the channel is absent
 * (open failed; errno names why) — the caller decides what a channel-less
 * deployment gets.  The caller has ALREADY refused a config path carrying
 * whitespace: PID1's request grammar is strtok_r on space/tab and has no
 * quoting, so such a path cannot be carried honestly. */
static int fifo_activate(const char *config, Capture *out, int *exitcode) {
    char *dir = ctrl_run_dir();
    if (!dir) return -1;
    char in_path[PATH_MAX], out_path[PATH_MAX];
    if (snprintf(in_path, sizeof(in_path), "%s/control.in", dir) >=
            (int)sizeof(in_path) ||
        snprintf(out_path, sizeof(out_path), "%s/control.out", dir) >=
            (int)sizeof(out_path)) {
        free(dir);
        cap_append_str(out, "fx-verbs: control channel path too long\n");
        *exitcode = 1;
        return 0;
    }
    free(dir);

    /* fxctl's open flags: control.in O_WRONLY|O_NONBLOCK (a fifo write-open
     * with no reader fails ENXIO IMMEDIATELY — PID1 parks its own reader
     * forever, so ENXIO means PID1 is gone), control.out O_RDONLY|
     * O_NONBLOCK.  Never a blocking open: a dead PID1 must be a fast
     * failure, not a hang. */
    int wfd = open(in_path, O_WRONLY | O_NONBLOCK);
    if (wfd < 0) return -1;
    int rfd = open(out_path, O_RDONLY | O_NONBLOCK);
    if (rfd < 0) {
        close(wfd);
        return -1;
    }

    /* ONE write of "activate <config>\n" — capped by the caller-rejected
     * whitespace bound and the length check below, so it always fits
     * PIPE_BUF and is atomic (fxctl's two-syscall body/newline split can
     * tear between two CONCURRENT clients; this cannot). */
    char req[FXV_CTRL_LINE_MAX];
    int n = snprintf(req, sizeof(req), "activate %s\n", config);
    if (n < 0 || (size_t)n >= sizeof(req)) {
        close(wfd);
        close(rfd);
        cap_append_str(out, "fx-verbs: fx_activate REFUSED: the config path is "
                            "too long for the control channel's request line "
                            "(4095 char bound)\n");
        *exitcode = 1;
        return 0;
    }
    size_t off = 0;
    bool sent = true;
    while (off < (size_t)n) {
        ssize_t w = write(wfd, req + off, (size_t)n - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            sent = false;
            break;
        }
        off += (size_t)w;
    }
    close(wfd); /* the request side is done; PID1 keeps its own reader */
    if (!sent) {
        close(rfd);
        char msg[PATH_MAX + 128];
        snprintf(msg, sizeof(msg), "fx-verbs: fx_activate: control channel "
                                   "write failed: %s\n", strerror(errno));
        cap_append_str(out, msg);
        *exitcode = 1;
        return 0;
    }

    /* Read until OK / ERR / EOF, poll()-gated under the TOTAL budget.  Data
     * lines (PID1's "activated version N") are the diagnosis the model gets;
     * an ERR line is appended verbatim so a refusal is LOUD. */
    struct timeval t0;
    gettimeofday(&t0, NULL);
    char line[8192];       /* fxctl's fgets width: a longer line is split */
    size_t llen = 0;
    bool done = false;
    int rc = 0;
    while (!done) {
        struct timeval now;
        gettimeofday(&now, NULL);
        long elapsed = (now.tv_sec - t0.tv_sec) * 1000L +
                       (now.tv_usec - t0.tv_usec) / 1000L;
        long remain = FXV_CTRL_BUDGET_MS - elapsed;
        if (remain <= 0) break;
        struct pollfd pf = { .fd = rfd, .events = POLLIN, .revents = 0 };
        int pr = poll(&pf, 1, remain > INT_MAX ? INT_MAX : (int)remain);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pr == 0) break; /* budget spent: fall out to the loud failure */
        char buf[4096];
        ssize_t r = read(rfd, buf, sizeof(buf));
        if (r < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) continue;
            break;
        }
        if (r == 0) break; /* PID1's writer is gone */
        for (ssize_t i = 0; i < r; i++) {
            char ch = buf[i];
            if (ch != '\n') {
                if (llen + 1 < sizeof(line)) line[llen++] = ch;
                continue;
            }
            switch (ctrl_classify(line, llen)) {
            case CTRL_LINE_OK:
                done = true;
                rc = 0;
                break;
            case CTRL_LINE_ERR:
                cap_append(out, line, llen);
                cap_append_str(out, "\n");
                done = true;
                rc = 1;
                break;
            case CTRL_LINE_DATA:
                cap_append(out, line, llen);
                cap_append_str(out, "\n");
                line[0] = '\0';
                llen = 0;
                break;
            }
            if (done) break;
            line[0] = '\0';
            llen = 0;
        }
    }
    close(rfd);
    if (!done) {
        cap_append_str(out,
            "fx-verbs: fx_activate: NO RESPONSE on the control channel within "
            "the 600s budget — PID1 did not answer 'activate'.  The activation "
            "may still have been PUBLISHED by PID1's child (check fx_outcome / "
            "fx_generation) but THIS call cannot say it committed; do not "
            "blindly re-issue it\n");
        rc = 1;
    }
    *exitcode = rc;
    return 0;
}

/* THE CHANNEL-LESS FALLBACK: exec the RUNNING ROOT's /bin/fx-activate
 * directly — the OLD (pre-2026-10) route, with the SAME pinned argv PID1's
 * own handler execs.  This is the REDUCED semantics and the banner says so:
 * the generation is PUBLISHED to the store (CURRENT moves, the next boot
 * runs it) but NOT COMMITTED (no live-root re-materialization, no boot-
 * decision re-arm, no service restart, no line in PID1's live runtime log —
 * the tmpfs log dies with the boot anyway).  The DURABLE record of the
 * publish is not this route's claim to make: fx-activate SELF-RECORDS it in
 * <store>/.operator since the runtime-record closure, one row under THIS
 * boot's fx.bootnonce= (and records nothing where the boot carries no
 * nonce).  It exists for a deployment whose PID1 has no fifo pair (setup
 * failed / a future transport change), never as a silent downgrade: the
 * banner is the reply's FIRST line. */
static void fallback_direct_activate(const char *config, Capture *out,
                                     int *exitcode) {
    cap_append_str(out,
        "fx-verbs: fx_activate: NO PID1 CONTROL CHANNEL — DIRECT-EXEC FALLBACK "
        "with REDUCED semantics: the generation will be PUBLISHED to the store "
        "(CURRENT moves; the next boot runs it) but NOT COMMITTED to the "
        "running system (no hot-apply of /etc+/bin, no boot-decision re-arm, "
        "no service restart, no line in PID1's live runtime log).  The "
        "publish still SELF-RECORDS in the store's durable <store>/.operator "
        "journal where this boot carries an fx.bootnonce= (fx-activate writes "
        "that row itself); with no boot nonce nothing durable is recorded.  "
        "Route fx-activate through PID1's control channel for the full "
        "activation.\n");
    char *cmd = resolve_command("fx-activate");
    if (!cmd) {
        cap_append_str(out, "fx-verbs: fx-activate not found under FX_VERB_ROOT (");
        cap_append_str(out, fx_root());
        cap_append_str(out, ")\n");
        *exitcode = 127;
        return;
    }
    char *argv[8];
    size_t k = 0;
    argv[k++] = cmd;
    argv[k++] = (char *)"--store";
    argv[k++] = (char *)FX_STORE_PATH;
    argv[k++] = (char *)"--package-set";
    argv[k++] = (char *)"/usr/fx/package-set.dhall";
    argv[k++] = (char *)"--config";
    argv[k++] = (char *)config;
    argv[k] = NULL;
    int ec = 127;
    int rc = run_verb(argv, NULL, out, &ec);
    free(cmd);
    if (rc != 0) {
        cap_append_str(out, "fx-verbs: failed to run the fallback exec\n");
        ec = 127;
    }
    *exitcode = ec;
}

/* fx_activate's dispatch: STORE-SCOPED first (the shared refusal — the row's
 * needs_store flag documents the same scope the exec rows carry in argv),
 * then the whitespace bound (PID1's request grammar cannot carry such a
 * path), then the channel, then the loud fallback.  Returns 0 (reply sent)
 * or a send_* return. */
static int native_activate(const char *config, yyjson_val *idv) {
    Capture out;
    if (!cap_init(&out)) return send_error(idv, -32603, "out of memory");
    int exitcode = 1;

    char *store = store_if_present();
    if (!store) {
        store_scope_refuse(&out, "fx_activate");
        int sret = send_capture_reply(idv, &out, 1);
        cap_free(&out);
        return sret;
    }
    free(store);

    if (!config || !*config ||
        strchr(config, ' ') || strchr(config, '\t') ||
        strchr(config, '\n') || strchr(config, '\r')) {
        cap_append_str(&out, "fx-verbs: fx_activate REFUSED: the config path '");
        cap_append_str(&out, config ? config : "(empty)");
        cap_append_str(&out, "' is empty or contains whitespace — PID1's "
                            "control-channel grammar is space/tab-delimited "
                            "with no quoting, so such a path cannot be carried "
                            "(the writable set's declared paths never carry "
                            "whitespace)\n");
        int sret = send_capture_reply(idv, &out, 1);
        cap_free(&out);
        return sret;
    }

    if (fifo_activate(config, &out, &exitcode) < 0)
        fallback_direct_activate(config, &out, &exitcode);

    int sret = send_capture_reply(idv, &out, exitcode);
    cap_free(&out);
    return sret;
}

/* THE READ/LIST HALF OF THE ROOT BOUND.  fx_read and fx_ls were the two
 * native verbs that root_join'd the request WITHOUT canonicalizing it, so a
 * '..' climbed ABOVE FX_VERB_ROOT and reached the HOST (/../../etc/hostname
 * under FX_VERB_ROOT=/tmp/stub).  Both now take the SAME canon_root_rel gate
 * fx_write has, and this is its refusal.  It NAMES the path and the root and
 * says the verb is a READ/LIST, never a silent no-op.  Reads stay OPEN inside
 * the root: a '..' that canonicalizes to a point still INSIDE it must still
 * work — the bound is "cannot climb above FX_VERB_ROOT", NOT "no '..'".
 * NOT A PRODUCTION CHANGE: FX_VERB_ROOT defaults to "/" and nothing can climb
 * above "/", so this bites only where a non-/ root is set (the stub-root
 * tests, a jailed deployment). */
static void root_bound_refuse(Capture *out, const char *verb, const char *path) {
    cap_append_str(out, "fx-verbs: ");
    cap_append_str(out, verb);
    cap_append_str(out, " REFUSED: ");
    cap_append_str(out, path ? path : "(null)");
    cap_append_str(out, " does not name a path inside FX_VERB_ROOT (root=");
    cap_append_str(out, fx_root());
    cap_append_str(out, "); a '..' that climbs above the root is not a readable "
                        "or listable path (the path is addressed absolutely "
                        "under the root)\n");
}

static int native_read(const char *path, Capture *out, int *exitcode) {
    /* THE ROOT BOUND (see root_bound_refuse): canonicalize FIRST — exactly
     * what native_write does — so no '..' ever reaches open().  A path that
     * cannot be canonicalized INSIDE FX_VERB_ROOT (a relative spelling, or a
     * '..' that climbs above the root) is refused loudly. */
    char *canon = canon_root_rel(path);
    if (!canon) {
        root_bound_refuse(out, "fx_read", path);
        *exitcode = 1;
        return 0;
    }
    char *full = root_join(canon);
    free(canon);
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
    /* THE OPERATOR POLICY (ops-policy, S2): consulted AFTER the floor passes
     * and BEFORE open() — a denial is a commit-site fact and never creates
     * the file.  DENY-MORE-ONLY: decision = floor_allows && !denied; the
     * compiled-in set above stays the FLOOR and is never weakened by (or
     * for) the policy.  The policy is SILENT here in floor-only mode (no
     * policy dir at startup) — the floor's verdict is returned unchanged. */
    if (!ops_write_allowed(canon, out)) {
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
    /* THE ROOT BOUND, exactly as native_read.  The empty path is fx_ls's
     * DOCUMENTED default — the root itself — and canonicalizes to "" like an
     * explicit "/". */
    const char *req = (path && *path) ? path : "/";
    char *canon = canon_root_rel(req);
    if (!canon) {
        root_bound_refuse(out, "fx_ls", path);
        *exitcode = 1;
        return 0;
    }
    char *full = root_join(canon);
    free(canon);
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
    const char *cwd;      /* row-pinned working directory (root-relative,
                           * joined with FX_VERB_ROOT at call time), chdir'd
                           * by the child before exec; NULL = inherit the
                           * server's cwd.  Only fx_build pins one: fxstore
                           * loads package-set.dhall from its cwd, and the
                           * image's frozen set lives at /usr/fx. */
    bool needs_store;    /* STORE-SCOPED by declaration, not by an argv
                           * token: fx_activate's channel argv carries no
                           * store path (PID1 owns the store argument), so
                           * the auto-detect below cannot see its scope —
                           * the flag IS the scope, enforced by the native
                           * handler AND honored by call_exec_verb should
                           * the row ever gain an exec form. */
} Verb;

/* fx_write (path+content), fx_store_verify (optional rootfs) and fx_ls
 * (optional path) take their arguments by name in handle_tools_call; fx_build
 * (package) does too, behind its closed-set gate; every other exec verb takes
 * exactly the one string argument named in its description. */
static const Verb VERBS[] = {
    /* The fxctl rows ride fxctl's FIFO MODE (`--fifo`): in the guest the
     * kernel has NO socket layer (CONFIG_NET unset — PID1's own console line
     * says so), so fxctl's socket default is ENOSYS and these verbs would be
     * dead; the fifo pair (<run>/control.in + control.out) is the transport
     * fxctl's fifo mode was added AS ("the in-guest transport", fxctl.zig).
     * `--fifo` is a bare flag fxctl strips before building the request line,
     * so the wire grammar is unchanged.  These are the FAST commands (ms
     * replies) — inside fxctl's 5s poll budget, unlike activate (see the
     * header's WHY NOT fxctl note). */
    { "fx_query", "fxctl", { "--fifo", "q", NULL },
      "Run `fxctl q <relation>` over PID1's control channel: read one live "
      "datalog relation. Known relations: generation, svc, svc_argv, install, "
      "provides, user, log. Argument: relation.", NULL, false },
    { "fx_status", "fxctl", { "--fifo", "status", NULL },
      "Run `fxctl status` over PID1's control channel: the live system status "
      "(current generation, services, store state). Takes no arguments.",
      NULL, false },
    /* fx_activate goes THROUGH PID1's activate handler over the fifo pair —
     * the WHOLE standard activation, not just its child half: the handler
     * forks fx-activate (config evaluation, closure, the per-generation
     * Dhakefile, the snapshot publish, CURRENT moves), RE-READS the store's
     * facts (the service table becomes the NEW generation's), records the
     * runtime generation, RE-ARMS the boot decision (a fresh grace window —
     * the verdict latched for the old generation must not stand for the new
     * one), RE-MATERIALIZES the new generation's /etc + /bin on the LIVE
     * running root (THE COMMIT: no reboot needed), and records
     * rt_effect("activate").  The reply is PID1's own: "activated version N"
     * on success, or its refusal as `ERR <why>` with exit=1 — including the
     * service-table overflow refusal (the config is too wide for the
     * supervisor's window).  A deployment with NO channel (the pair absent)
     * falls back to direct fx-activate exec with a LOUD reduced-semantics
     * banner: published, not committed (see fallback_direct_activate).
     * STORE-SCOPED (needs_store): refuses by name when the persistent store
     * is absent, exactly like its exec neighbours — the channel argv carries
     * no store path, so the flag IS the scope.  The fifo pair is single-
     * client by convention, not enforcement.  Argument: config (the path of
     * the config to activate; no whitespace — the channel's request grammar
     * is space/tab-delimited). */
    { "fx_activate", NULL, { NULL, NULL },
      "ACTIVATE service configuration <config> on the running system, THROUGH "
      "PID1: the new generation is published AND COMMITTED — its /etc + /bin "
      "are materialized on the RUNNING root (no reboot) and the boot decision "
      "is re-armed for it, so an fx_status read right after shows the NEW "
      "generation. The reply is PID1's own ('activated version N', or its "
      "refusal with exit=1). Falls back to direct fx-activate exec (publish-"
      "only, next boot) ONLY when no PID1 control channel exists, and says so "
      "loudly. Argument: config (a path, e.g. /fx/disk/agent-config.dhall).",
      NULL, true },
    { "fx_rollback", "fxctl", { "--fifo", "rollback", NULL },
      "Run `fxctl rollback <version>` over PID1's control channel: roll the "
      "system back to generation <version> (durable: CURRENT moves; the "
      "running services carry over until the next boot). Argument: version.",
      NULL, false },
    { "fx_what", "fxstore", { "what", NULL },
      "Run `fxstore what <target>`: the install fact (provenance proof tree) "
      "managing installed path <target>. Argument: target.", NULL, false },
    { "fx_why", "fxstore", { "why", NULL },
      "Run `fxstore why <package>`: why <package> is in the store — its closure, the "
      "targets it provides, and the roots pulling it in. Argument: package.", NULL, false },
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
      "that exit line is the drift gate. Optional argument: rootfs (default /).", NULL, false },
    /* fx_build — THE IN-GUEST BUILD VERB (todo.md §5's residual, closed):
     * the agent iterates WITHOUT sending code off the machine.  The argv is
     * PINNED: fxstore build --store <the guest's own persistent store> <pkg>
     * — the model names a PACKAGE, never a flag, a recipe or a store (the
     * package argument is bounded in handle_tools_call by the closed set
     * FX_AGENT_BUILDABLE, default exactly the slot package oslot; see
     * FX_DEFAULT_BUILDABLE for why a set and not a name-shape check).
     * STORE-SCOPED: the row carries FX_STORE_PATH, so call_exec_verb refuses
     * to run it when that path is absent (a diskless guest) instead of
     * building into a ramfs snapshot the next boot would lose.  The cwd is
     * PINNED to usr/fx: fxstore loads package-set.dhall from its cwd, and
     * that is where mkinitramfs ships the image's frozen set — the build
     * reads THE DEPLOYMENT'S recipe, never a set the model could reach.
     * The child env additionally carries FXSTORE_SH/FXSTORE_STAGE3 pointed
     * at the deployment's staged seats when they exist (build_verb_envp), so
     * the recipe's /bin/sh and the sandbox binary resolve in the pivoted
     * root, where /bin/sh does not exist. */
    { "fx_build", "fxstore", { "build", "--store", FX_STORE_PATH, NULL },
      "BUILD a package of the image's frozen package set into the LIVE store, "
      "IN THE GUEST: runs `fxstore build --store " FX_STORE_PATH " <package>`, "
      "reading package-set.dhall from /usr/fx (the frozen deployment set) and "
      "writing content-addressed store dirs the NEXT activation can use — "
      "build FIRST, then fx_activate. The package is BOUNDED by the "
      "host-declared closed set FX_AGENT_BUILDABLE (default: the slot package "
      "'oslot' only): a name outside it — or anything that is not a bare "
      "package name — is REFUSED (exit=1) naming the set, and the model "
      "cannot widen it. Takes no flags, no store, no recipe. "
      "Argument: package.",
      "usr/fx", false },
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
      "Takes no arguments; store-scoped.", NULL, false },
    { "fx_generation", NULL, { NULL, NULL },
      "Print the CURRENT generation of the store — the generation the running "
      "system came up in, from <store>/.db/snapshots/CURRENT: one line, "
      "'current <N>'. Exit 1 and names the file when it cannot be read (a version "
      "is never guessed). Takes no arguments; store-scoped.", NULL, false },
    { "fx_read", NULL, { NULL, NULL },
      "Read a file and return its content. The path is absolute and resolves under "
      "FX_VERB_ROOT; a '..' that climbs ABOVE the root is REFUSED (exit=1, naming "
      "the path and the root). Capped at 1 MiB. Argument: path.", NULL, false },
    { "fx_write", NULL, { NULL, NULL },
      "Write a file (create-or-truncate). The write surface is a CLOSED, HOST-DECLARED "
      "SET: only the exact paths listed in FX_AGENT_WRITABLE (colon-separated; each "
      "path may be spelled absolute or root-relative — both name the same file) may "
      "be written — a write to anything else is REFUSED (exit=1) naming the path and "
      "the set, and the model cannot widen the set. Does not follow a symlink at the "
      "final path. Arguments: path, content.", NULL, false },
    { "fx_ls", NULL, { NULL, NULL },
      "List a directory: one entry per line, directories suffixed '/'. The path is "
      "absolute and resolves under FX_VERB_ROOT; a '..' that climbs ABOVE the root "
      "is REFUSED (exit=1, naming the path and the root). Argument: path (default: "
      "the root itself).", NULL, false },
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
    /* store-scoped rows refuse to run when the store is not there, naming
     * the path: see FX_STORE_PATH.  TWO declarations of the same scope: a row
     * whose fixed[] CARRIES the path (fx_store_verify, fx_build) is scoped by
     * construction, and fx_activate — whose channel argv cannot carry it —
     * declares it with needs_store. */
    if (v->needs_store) {
        char *sp = store_if_present();
        if (!sp) {
            store_scope_refuse(&out, v->name);
            int sret = send_capture_reply(idv, &out, 1);
            cap_free(&out);
            return sret;
        }
        free(sp);
    }
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
    /* the row-pinned working directory (NULL for every row but fx_build) */
    char *cwd = NULL;
    if (v->cwd) {
        cwd = root_join(v->cwd);
        if (!cwd) {
            free(cmd);
            cap_free(&out);
            return send_error(idv, -32603, "out of memory");
        }
    }
    /* argv = [resolved, fixed..., tail..., NULL] */
    size_t ntail = 0;
    while (argv_tail[ntail]) ntail++;
    char **argv = malloc((1 + nfix + ntail + 1) * sizeof(char *));
    if (!argv) { free(cmd); free(cwd); cap_free(&out); return send_error(idv, -32603, "out of memory"); }
    size_t k = 0;
    argv[k++] = cmd;
    for (size_t i = 0; i < nfix; i++) argv[k++] = (char *)v->fixed[i];
    for (size_t i = 0; i < ntail; i++) argv[k++] = argv_tail[i];
    argv[k] = NULL;

    int exitcode = 127;
    int rc = run_verb(argv, cwd, &out, &exitcode);
    free(argv);
    free(cmd);
    free(cwd);
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

    /* fx_build: the package argument is bounded by the CLOSED SET before any
     * exec happens — the refusal is native, loud, names the set, and never
     * reaches fxstore.  Two gates, in order: the BARE-NAME shape (a package
     * is NAMED, never a flag/path/set spelling) and exact membership in the
     * host-declared FX_AGENT_BUILDABLE set.  Both mirror fx_write's
     * writable-set refusal. */
    if (strcmp(name, "fx_build") == 0) {
        const char *pkg = NULL;
        if (arg_string(arguments, "package", &pkg) != 0)
            return send_error(idv, -32602,
                              "fx_build requires string argument 'package'");
        Capture out;
        if (!cap_init(&out)) return send_error(idv, -32603, "out of memory");
        int exitcode = 1;
        if (!is_bare_package_name(pkg)) {
            cap_append_str(&out, "fx-verbs: fx_build REFUSED: '");
            cap_append_str(&out, pkg);
            cap_append_str(&out, "' is not a bare package name — fx_build names a "
                                "PACKAGE the deployment ships, never a flag, a "
                                "path or a set\n");
        } else if (!in_name_set(pkg, buildable_set())) {
            cap_append_str(&out, "fx-verbs: fx_build REFUSED: '");
            cap_append_str(&out, pkg);
            cap_append_str(&out, "' is not in the host-declared buildable set "
                                "FX_AGENT_BUILDABLE='");
            cap_append_str(&out, buildable_set());
            cap_append_str(&out, "'. Only the exact package names the HOST lists "
                                "there may be built (the frozen package set's "
                                "other packages are provisioned, not "
                                "agent-buildable); to grant more, the operator "
                                "must change FX_AGENT_BUILDABLE — the model "
                                "cannot widen it\n");
        } else {
            cap_free(&out);
            char *tail[2] = { (char *)pkg, NULL };
            return call_exec_verb(idv, v, tail);
        }
        int sret = send_capture_reply(idv, &out, exitcode);
        cap_free(&out);
        return sret;
    }

    /* fx_activate: NATIVE — through PID1's control channel (see
     * native_activate), never call_exec_verb (the row carries no command).
     * Handled here, before the fx_outcome/fx_generation native pair and
     * before the one-argument exec fallback below (whose REQ table no longer
     * names it). */
    if (strcmp(name, "fx_activate") == 0) {
        const char *config = NULL;
        if (arg_string(arguments, "config", &config) != 0)
            return send_error(idv, -32602,
                              "fx_activate requires string argument 'config' (a path)");
        return native_activate(config, idv);
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
        /* F2: the ops-policy state rides the initialize reply — the channel
         * the deployment actually reads (the harness /dev/null's this
         * server's stderr, so the floor-only startup notice would otherwise
         * leave NO durable marker: an EXPECTED-but-absent policy would
         * downgrade to the floor silently).  The stderr line stays. */
        yyjson_mut_obj_add_str(md, sinfo, "opsPolicy",
                               OPS.present ? "loaded" : "floor-only");
        if (OPS.present)
            yyjson_mut_obj_add_str(md, sinfo, "opsPolicySha", OPS.sha);
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
    ops_policy_startup(); /* the operator policy, or the named floor-only state */
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
