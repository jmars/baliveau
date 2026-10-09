/* src/llm2/agent_main.c — LAYER-2 S11 native agent entrypoint.
 *
 * Consumes the SAME LOCKED flag set runner.c's build_vibe_cmd emits, but runs
 * the native agent loop IN-PROCESS (no subprocess, no `vibe -p`):
 *
 *   -p <prompt> --agent <agent> --max-turns N [--resume <short8>]
 *   [--workdir <cwd>] --output text [--auto-approve]
 *
 * Flow: parse argv (getopt_long) -> validate agent/session_id/workdir/max_turns
 * via runner.h -> config_load -> config_find_agent (reject subagent) ->
 * resolve the configured provider backend (agent_main_resolve_backend;
 * FAIL-OPEN to the default openai_responses_backend()) + the agent's
 * mcp_servers[0] as the tool server + a ToolPolicy from the agent's
 * enabled_tools/disabled_tools ->
 * build the seed message list (ALWAYS a leading role=user message holding the
 * prompt) -> agent_loop_run_ex with a transcript callback that ckpt_appends
 * into a CkptMessages -> write messages.jsonl via ckpt_save + update runstore
 * status via ckpt_run_*.  The final assistant text goes to stdout (--output
 * text).
 *
 * This file exposes agent_main_entry (NO main()) so the hermetic test links it
 * with its own main(); src/llm2/agent_main_main.c provides the binary's main().
 *
 * Memory-safety (L2 rules, carried over): all config/CLI bytes are
 * length-checked or validated (runner.h) before use; no strcpy/strcat/sprintf
 * on network bytes; the transcript callback deep-copies each message via
 * ckpt_append (which length-caps at CKPT_FIELD_CAP / AGENT_ARGS_CAP); every
 * malloc is checked (the loop/backend/checkpoint layers handle their own);
 * signal(SIGPIPE, SIG_IGN) at entry (mcp_client writes to a child pipe).
 * FAIL-OPEN: a missing/unparseable config or a not-found agent yields a clear
 * error and a non-zero exit — never a crash.
 */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <errno.h>
#include <signal.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <getopt.h>
#include <time.h>
#include <dirent.h>
#include <sys/stat.h>

#include "agent_main.h"
#include "config.h"
#include "checkpoint.h"
#include "agent_loop.h"
#include "llm_backend.h"
#include "runner.h"
#include "runstore.h"
#include "tui.h"

/* Hard cap on prompt file size (bounded read to prevent OOM). */
#define PROMPT_FILE_MAX (512 * 1024)

/* ── small helpers ───────────────────────────────────────────────────────── */

/* mkdir -p (best-effort; the run dirs under the data dir). */
static void mkdirs(const char *path) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof(tmp), "%s", path);
    size_t len = strlen(tmp);
    if (len > 1 && tmp[len - 1] == '/') tmp[len - 1] = '\0';
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = '\0'; mkdir(tmp, 0755); *p = '/'; }
    }
    mkdir(tmp, 0755);
}

/* Expand a leading ~ in path to $HOME.  Returns a malloc'd expanded path, or NULL.
 * Caller frees.  Only expands if path starts with ~ or ~/; otherwise returns a copy. */
static char *expand_tilde(const char *path) {
    if (!path || !*path) return NULL;
    if (path[0] != '~') return strdup(path);
    /* Only expand `~` and `~/...`; leave `~user`/`~otheruser/...` unchanged
     * (the doc contract — otherwise `~foo` would wrongly become $HOME"foo"). */
    if (path[1] != '/' && path[1] != '\0') return strdup(path);
    const char *home = getenv("HOME");
    if (!home || !*home) return strdup(path);
    size_t home_len = strlen(home);
    /* Skip just the `~`: keep a following `/` so the expansion stays
     * "<home>/<rest>".  (Taking path+2 on "~/.vibe" would drop the slash and
     * yield "<home>.vibe/..." — wrong.) */
    const char *rest = path + 1;
    size_t rest_len = strlen(rest);
    char *expanded = malloc(home_len + rest_len + 1);
    if (!expanded) return NULL;
    memcpy(expanded, home, home_len);
    memcpy(expanded + home_len, rest, rest_len);
    expanded[home_len + rest_len] = '\0';
    return expanded;
}

/* Read a file with a bounded size cap.  Returns a malloc'd NUL-terminated buffer
 * on success (caller frees), NULL on any failure (missing, unreadable, oversize, OOM).
 * Reads at most PROMPT_FILE_MAX bytes. */
static char *read_prompt_file(const char *path) {
    if (!path || !*path) return NULL;
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return NULL; }
    if ((size_t)sz > PROMPT_FILE_MAX) { fclose(f); return NULL; }
    rewind(f);
    char *buf = malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[got] = '\0';
    return buf;
}

/* Data dir for the runstore + transcript: env VIBE_RUNTIME_DIR, else the same
 * default the daemon uses (~/.local/share/vibe-runtime). */
static void runtime_data_dir(char *out, size_t cap) {
    const char *env = getenv("VIBE_RUNTIME_DIR");
    if (env && *env) { snprintf(out, cap, "%s", env); return; }
    const char *home = getenv("HOME");
    if (home && *home) snprintf(out, cap, "%s/.local/share/vibe-runtime", home);
    else snprintf(out, cap, ".local/share/vibe-runtime");
}

/* 12-hex run_id (validates as a runner identifier).  Mirrors daemon.c's
 * gen_run_id: /dev/urandom with a time-based fallback. */
static void gen_run_id(char *out, size_t cap) {
    if (cap < 13) { if (cap) out[0] = '\0'; return; }
    int fd = open("/dev/urandom", O_RDONLY);
    unsigned char b[6] = {0};
    if (fd >= 0) {
        ssize_t got = read(fd, b, sizeof b);
        (void)got;
        close(fd);
    } else {
        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
        for (int i = 0; i < 6; i++) b[i] = (unsigned char)(ts.tv_nsec >> (i * 8));
    }
    static const char *hex = "0123456789abcdef";
    for (int i = 0; i < 6; i++) {
        out[i * 2]     = hex[(b[i] >> 4) & 0xF];
        out[i * 2 + 1] = hex[b[i] & 0xF];
    }
    out[12] = '\0';
}

/* ── session resolution (the resume seed) ───────────────────────────────── */

/* A session id becomes a PATH COMPONENT (sessions/<sid>/), and
 * validate_identifier's charset allows '.' and '_' — so a bare "." or ".."
 * passes validation and would then name the sessions dir itself or its parent.
 * Reject those (and any '/' — belt and braces) locally. */
static int sid_is_dotted(const char *sid) {
    if (!sid || !*sid) return 1;
    if (strcmp(sid, ".") == 0 || strcmp(sid, "..") == 0) return 1;
    return strchr(sid, '/') != NULL;
}

/* Resolve a --resume argument to an EXISTING session dir name: an exact match
 * wins, otherwise a UNIQUE prefix match (the CLI's short8 habit).  Nothing
 * matched, or the prefix is ambiguous, is fail-closed (-1) — guessing would
 * resume the wrong conversation.  Dotted entries (".", "..", ".hidden") are
 * skipped.  Returns 0 and writes the resolved id into out on success. */
static int resolve_session(const char *sessions_dir, const char *want,
                           char *out, size_t cap) {
    DIR *d = opendir(sessions_dir);
    if (!d) return -1;
    size_t want_len = strlen(want);
    size_t hits = 0;
    char exact[NAME_MAX + 1] = {0}, prefix[NAME_MAX + 1] = {0};
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        if (strcmp(e->d_name, want) == 0) {
            snprintf(exact, sizeof exact, "%s", e->d_name);
        } else if (strncmp(e->d_name, want, want_len) == 0) {
            hits++;
            if (hits == 1) snprintf(prefix, sizeof prefix, "%s", e->d_name);
        }
    }
    closedir(d);
    if (exact[0]) { snprintf(out, cap, "%s", exact); return 0; }
    if (hits == 1) { snprintf(out, cap, "%s", prefix); return 0; }
    return -1;
}

/* ── transcript hook ─────────────────────────────────────────────────────── */

/* State for the transcript hook.  `c` is the in-memory transcript (what the
 * end-of-run ckpt_save rewrites the file from); `path` is that file, which
 * every message is ALSO appended to — and fsync'd — as it arrives, so a
 * mid-run death (a reboot) leaves the transcript on disk.
 *
 * `skip` counts messages that are ALREADY on disk because they were loaded as
 * a resume seed: the loop re-notifies every seed (agent_loop.c:739), so the
 * first `skip` notifications must be kept in memory but NOT re-appended to
 * disk (a wrong count duplicates a line — the double-append tripwire in
 * tests/test_resume.sh).  Synthesized messages are not on disk and are
 * therefore not counted. */
typedef struct {
    CkptMessages *c;      /* in-memory transcript (borrowed) */
    const char   *path;   /* messages.jsonl for this session */
    const char   *dir;    /* the session dir (for the one-time dir fsync) */
    size_t        skip;   /* leading messages already on disk */
    int           warned; /* warn-once latch for a failing flush */
    int           dir_synced; /* one-time: the file's DIRECTORY ENTRY is durable */
} CbCtx;

/* fsync a directory so a file CREATED inside it survives a reboot.  The file's
 * own fsync makes its CONTENTS durable; its new directory entry needs the
 * directory fsync, otherwise the file can vanish whole. */
static void fsync_dir(const char *dir) {
    if (!dir || !*dir) return;
    int fd = open(dir, O_RDONLY | O_DIRECTORY);
    if (fd < 0) return;
    (void)fsync(fd);
    close(fd);
}

/* Fired by agent_loop_run_ex for EVERY appended message (seeds + each
 * assistant/tool message).  Deep-copies into the transcript via ckpt_append
 * (which length-caps attacker-shaped fields) AND flushes the message to the
 * durable messages.jsonl before returning.  Best-effort: a ckpt_append OOM or
 * a failed flush is absorbed (warned once), never propagated — the loop keeps
 * going, and ckpt_save rewrites the whole file at end of run. */
static void transcript_cb(const LlmMsg *m, void *user) {
    CbCtx *ctx = (CbCtx *)user;
    if (!m || !ctx || !ctx->c) return;
    (void)ckpt_append(ctx->c, m);
    if (ctx->skip) { ctx->skip--; return; } /* already durable (resume seed) */
    if (ckpt_append_line(ctx->path, m) != 0) {
        if (!ctx->warned) {
            fprintf(stderr,
                    "agent_main: warning: transcript flush to '%s' failed; "
                    "the transcript is still written at end of run\n",
                    ctx->path ? ctx->path : "(unset)");
            ctx->warned = 1;
        }
        return;
    }
    if (!ctx->dir_synced) { fsync_dir(ctx->dir); ctx->dir_synced = 1; }
}

/* ── TUI delta sink (S12) ──────────────────────────────────────────────── */

/* The delta-callback user struct: FIRST member is a DeltaAbort (the contract in
 * agent_loop.h); `ab.abort` is set to 1 when the user presses quit mid-stream
 * (checked inside the delta callback, between deltas). */
typedef struct {
    DeltaAbort ab;
    Tui *tui;
} TuiSink;

/* Fired by agent_loop_run_delta for every non-DELTA_NONE delta.  Renders live:
 * text/reasoning stream, tool calls/errors append a line, finish ends the
 * streaming line.  Also checks tui_poll_key between deltas and aborts on QUIT. */
static void tui_delta_cb(const Delta *d, void *user) {
    TuiSink *s = (TuiSink *)user;
    if (!s || !s->tui || !d) return;

    /* Poll for a quit key between deltas (non-blocking). */
    if (tui_poll_key(s->tui) == TUI_KEY_QUIT) s->ab.abort = 1;

    switch (d->type) {
    case DELTA_TEXT:
        if (d->text && d->text_len) (void)tui_stream(s->tui, d->text, d->text_len);
        break;
    case DELTA_REASONING:
        if (d->text && d->text_len) (void)tui_stream(s->tui, d->text, d->text_len);
        break;
    case DELTA_TOOL_CALL:
        (void)tui_end_stream(s->tui);
        if (d->tool_name && d->tool_name_len) {
            char line[512];
            size_t name_len = d->tool_name_len < 400 ? d->tool_name_len : 400;
            int ln = snprintf(line, sizeof line, "  -> %.*s",
                              (int)name_len, d->tool_name);
            if (ln > 0 && (size_t)ln < sizeof line)
                (void)tui_append_line(s->tui, line, (size_t)ln);
        }
        break;
    case DELTA_ERROR:
        (void)tui_end_stream(s->tui);
        (void)tui_append_line(s->tui, "[error]", 7);
        break;
    case DELTA_FINISH:
        (void)tui_end_stream(s->tui);
        break;
    default:
        break;
    }
}

/* ── provider routing ──────────────────────────────────────────────────── */

/* Resolve the backend for an agent from the runtime config (see agent_main.h).
 * FAIL-OPEN: any unknown/missing provider (or backend type) falls back to the
 * default openai_responses_backend() — never an error. */
const Backend *agent_main_resolve_backend(const RuntimeConfig *cfg,
                                          const ConfigAgent *ag, Backend *out) {
    if (!cfg || !ag || !out) return openai_responses_backend();

    const ConfigModel *model_entry =
        ag->model ? config_find_model(cfg, ag->model) : NULL;
    const ConfigProvider *provider =
        (model_entry && model_entry->provider)
            ? config_find_provider(cfg, model_entry->provider)
            : NULL;

    const char *type     = (provider && provider->backend)     ? provider->backend : "openai_responses";
    const char *base_url = (provider && provider->api_base)    ? provider->api_base : "http://127.0.0.1:8321";
    const char *key_env  = (provider && provider->api_key_env_var) ? provider->api_key_env_var : NULL;

    if (backend_build(out, type, base_url, key_env) == 0) return out;
    return openai_responses_backend(); /* unknown backend type: fail-open */
}

/* ── entry ───────────────────────────────────────────────────────────────── */

int agent_main_entry(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN); /* mcp_client writes to a child pipe */

    optind = 1; /* restart getopt_long so the test can drive this repeatedly */
    opterr = 0;

    const char *prompt = NULL, *agent = NULL, *resume = NULL;
    const char *workdir = NULL, *output = "text";
    int max_turns = -1; /* -1 => not given; defaulted to runner_max_turns() */
    int auto_approve = 0;

    enum {
        OPT_AGENT = 1, OPT_MAX_TURNS, OPT_RESUME, OPT_WORKDIR, OPT_OUTPUT, OPT_AUTO
    };
    static const struct option longopts[] = {
        { "agent",        required_argument, 0, OPT_AGENT    },
        { "max-turns",    required_argument, 0, OPT_MAX_TURNS },
        { "resume",       required_argument, 0, OPT_RESUME   },
        { "workdir",      required_argument, 0, OPT_WORKDIR  },
        { "output",       required_argument, 0, OPT_OUTPUT   },
        { "auto-approve", no_argument,       0, OPT_AUTO     },
        { 0, 0, 0, 0 }
    };

    int c;
    while ((c = getopt_long(argc, argv, "p:", longopts, NULL)) != -1) {
        switch (c) {
        case 'p':         prompt = optarg; break;
        case OPT_AGENT:   agent = optarg; break;
        case OPT_MAX_TURNS: {
            char *end = NULL;
            errno = 0;
            long v = strtol(optarg, &end, 10);
            if (end == optarg || *end != '\0' || errno == ERANGE ||
                v <= 0 || v > INT_MAX) {
                fprintf(stderr,
                        "agent_main: --max-turns expects an integer between 1 and %d, got '%s'\n",
                        runner_max_turns(), optarg);
                return 2;
            }
            max_turns = (int)v;
            break;
        }
        case OPT_RESUME:  resume = optarg; break;
        case OPT_WORKDIR: workdir = optarg; break;
        case OPT_OUTPUT:  output = optarg ? optarg : "text"; break;
        case OPT_AUTO:    auto_approve = 1; break;
        default:
            fprintf(stderr, "agent_main: unknown or invalid option\n");
            return 2;
        }
    }
    if (optind < argc) {
        fprintf(stderr, "agent_main: unexpected trailing argument '%s'\n", argv[optind]);
        return 2;
    }
    /* Validate --output: only "text" (S11) and "tui" (S12) are supported. */
    if (output && strcmp(output, "text") != 0 && strcmp(output, "tui") != 0) {
        fprintf(stderr, "agent_main: --output must be 'text' or 'tui', got '%s'\n",
                output);
        return 2;
    }
    (void)auto_approve; /* parsed; the in-process loop has no approval gate */

    if (!agent || !*agent) {
        fprintf(stderr, "agent_main: --agent <agent> is required\n");
        return 2;
    }
    if (!prompt) {
        fprintf(stderr, "agent_main: -p <prompt> is required\n");
        return 2;
    }

    RunnerError rerr;
    memset(&rerr, 0, sizeof rerr);
    if (validate_identifier(agent, "agent", &rerr) != 0) {
        fprintf(stderr, "agent_main: %s\n", rerr.msg);
        return 2;
    }
    if (resume && *resume) {
        if (validate_identifier(resume, "session_id", &rerr) != 0) {
            fprintf(stderr, "agent_main: %s\n", rerr.msg);
            return 2;
        }
    }
    if (workdir && *workdir) {
        if (validate_cwd(workdir, &rerr) != 0 ||
            validate_cwd_confinement(workdir, &rerr) != 0) {
            fprintf(stderr, "agent_main: %s\n", rerr.msg);
            return 2;
        }
    }
    int mt = runner_max_turns();
    if (max_turns < 0) max_turns = mt;
    if (max_turns <= 0 || max_turns > mt) {
        fprintf(stderr, "agent_main: --max-turns must be between 1 and %d, got %d\n",
                mt, max_turns);
        return 2;
    }

    /* Load the runtime config; reject a subagent / unknown agent. */
    RuntimeConfig cfg;
    char err[256] = {0};
    if (config_load(&cfg, err, sizeof err) != 0) {
        fprintf(stderr, "agent_main: config_load failed: %s\n", err);
        return 1;
    }
    const ConfigAgent *ag = config_find_agent(&cfg, agent);
    if (!ag) {
        fprintf(stderr, "agent_main: agent '%s' not found in runtime config\n", agent);
        config_free(&cfg);
        return 1;
    }
    if (ag->agent_type && strcmp(ag->agent_type, "subagent") == 0) {
        fprintf(stderr,
                "agent_main: agent '%s' is a subagent and cannot be the primary "
                "agent of a detached run\n", agent);
        config_free(&cfg);
        return 1;
    }
    const char *model = ag->model ? ag->model : "deepseek-v4-flash";
    const McpToolServer *tool_srv =
        (ag->n_mcp_servers > 0) ? &ag->mcp_servers[0] : NULL;

    /* Provider routing: resolve the backend from the agent's model (FAIL-OPEN
     * to the default local-router backend when the provider/model is unknown)
     * and build the tool allowlist from the agent's enabled_tools/disabled_tools
     * globs (all-empty -> allow-all). */
    Backend b;
    const Backend *backend = agent_main_resolve_backend(&cfg, ag, &b);
    ToolPolicy policy = {
        .enabled    = (const char *const *)ag->enabled_tools,
        .n_enabled  = ag->n_enabled_tools,
        .disabled   = (const char *const *)ag->disabled_tools,
        .n_disabled = ag->n_disabled_tools,
    };

    /* fx-harness: there is no TLS default-verify step — the transport is a
     * character device with no TLS layer at all (see fx_transport.h). */

    /* Runstore + per-run dir under the data dir. */
    char data[PATH_MAX];
    runtime_data_dir(data, sizeof data);
    char run_id[16] = {0};
    gen_run_id(run_id, sizeof run_id);
    char run_dir[PATH_MAX];
    snprintf(run_dir, sizeof run_dir, "%.700s/runs/%s", data, run_id);
    mkdirs(data);
    mkdirs(run_dir);

    /* SESSION HOME.  The transcript lives in <data>/sessions/<sid>/, NOT in the
     * per-run dir: a resumed run has a FRESH run_id (it is a new run) but must
     * land back in the SAME session directory, and a reboot must not move it.
     * sid = the resolved --resume argument, else this run's id.  Resolved
     * BEFORE the runstore is opened, so a resume with nothing to resume leaves
     * no orphan run record behind at status=running. */
    char sessions_dir[PATH_MAX];
    char sid[NAME_MAX + 1];
    snprintf(sessions_dir, sizeof sessions_dir, "%.700s/sessions", data);
    int resumed = (resume && *resume);
    if (resumed) {
        if (sid_is_dotted(resume)) {
            fprintf(stderr, "agent_main: invalid session_id '%.300s'\n", resume);
            config_free(&cfg);
            return 2;
        }
        if (resolve_session(sessions_dir, resume, sid, sizeof sid) != 0) {
            fprintf(stderr,
                    "agent_main: no session to resume: '%.300s' matches no "
                    "directory under %s (or matches more than one)\n",
                    resume, sessions_dir);
            config_free(&cfg);
            return 1;
        }
    } else {
        snprintf(sid, sizeof sid, "%s", run_id);
    }
    char sess_dir[PATH_MAX];
    char msgs_path[PATH_MAX];
    snprintf(sess_dir, sizeof sess_dir, "%.700s/%s", sessions_dir, sid);
    snprintf(msgs_path, sizeof msgs_path, "%.900s/messages.jsonl", sess_dir);
    mkdirs(sess_dir);

    /* --resume: LOAD the pre-death transcript.  (Both halves already existed —
     * ckpt_load and the durable file — and were never connected.)  `prior` is
     * BORROWED as the loop's seed array below and may therefore only be freed
     * AFTER the final ckpt_save. */
    CkptMessages prior;
    ckpt_messages_init(&prior);
    size_t n_seed_disk = 0; /* messages already on disk = the flush skip count */
    if (resumed) {
        if (ckpt_load(msgs_path, &prior) != 0 || prior.n == 0) {
            fprintf(stderr,
                    "agent_main: no session to resume: '%.900s' has no readable "
                    "transcript\n", msgs_path);
            ckpt_messages_free(&prior);
            config_free(&cfg);
            return 1;
        }
        n_seed_disk = prior.n;
        /* DANGLING TOOL CALLS: the run died after the assistant message
         * carrying its tool call was flushed and before the result existed, so
         * the loaded transcript ends on an UNANSWERED call.  The loop's
         * invariant is that every assistant tool_call gets a matching role=tool
         * message (agent_loop.c:779); a turn that violates it is malformed for
         * the provider.  Synthesize the missing results IN MEMORY — they are
         * NOT on disk, so they are not counted in n_seed_disk and therefore
         * flush as new lines. */
        const LlmMsg *last = &prior.msgs[prior.n - 1];
        if (last->n_tool_calls && last->role && strcmp(last->role, "assistant") == 0) {
            CkptMessages syn;
            ckpt_messages_init(&syn);
            for (size_t i = 0; i < last->n_tool_calls; i++) {
                LlmMsg sm;
                memset(&sm, 0, sizeof sm);
                sm.role = "tool";
                sm.tool_call_id = last->tool_calls[i].id;
                sm.content = "(rebooted before the tool returned)";
                sm.content_len = strlen(sm.content);
                (void)ckpt_append(&syn, &sm);
            }
            /* Copy out of `syn`: appending to `prior` can realloc its array and
             * invalidate `last` partway through the loop. */
            for (size_t i = 0; i < syn.n; i++) (void)ckpt_append(&prior, &syn.msgs[i]);
            ckpt_messages_free(&syn);
        }
    }

    RunStore rs;
    memset(&rs, 0, sizeof rs);
    if (ckpt_run_open(&rs, data, err, sizeof err) != 0) {
        fprintf(stderr, "agent_main: runstore_open(%s) failed: %s\n", data, err);
        ckpt_messages_free(&prior);
        config_free(&cfg);
        return 1;
    }
    if (ckpt_run_add(&rs, run_id, agent, err, sizeof err) != 0) {
        fprintf(stderr, "agent_main: runstore_add(%s) failed: %s\n", run_id, err);
        ckpt_run_close(&rs);
        ckpt_messages_free(&prior);
        config_free(&cfg);
        return 1;
    }
    /* Every run links to its session (on a fresh run the session IS this run;
     * on a resume the new run links back to the pre-death session). */
    (void)ckpt_run_set_session_id(&rs, run_id, sid);
    (void)ckpt_run_set_status(&rs, run_id, RS_STATUS_RUNNING);

    /* Seed the conversation.  On a FRESH run: optionally prepend a role=system
     * message from the agent's prompt_file, then ALWAYS append a role=user
     * message holding the prompt (the "session_first_user_message requires
     * leading role=user" rule: the first message sent/written must be
     * role=user).  On a RESUME the loaded transcript IS the conversation — it
     * already carries the original prompt, and -p is not re-seeded (the CLI
     * still requires it; it is ignored here).  Zero the fresh array so the
     * unset LlmMsg fields (tool_call_id/n_tool_calls/tool_calls) are NULL/0 —
     * msglist_append_copy reads them and would otherwise see stack garbage. */
    LlmMsg fresh[2];
    memset(fresh, 0, sizeof fresh);
    size_t n_fresh = 0;
    char *sysbuf = NULL; /* malloc'd buffer for system prompt; freed after loop */

    if (!resumed) {
        if (ag->prompt_file && *ag->prompt_file) {
            char *expanded = expand_tilde(ag->prompt_file);
            if (expanded) {
                sysbuf = read_prompt_file(expanded);
                free(expanded);
            }
            if (!sysbuf) {
                fprintf(stderr,
                        "agent_main: warning: prompt_file '%s' unreadable; "
                        "continuing without system prompt\n", ag->prompt_file);
            } else {
                fresh[n_fresh].role = "system";
                fresh[n_fresh].content = sysbuf;
                fresh[n_fresh].content_len = strlen(sysbuf);
                n_fresh++;
            }
        }

        /* Always append the role=user prompt seed */
        fresh[n_fresh].role = "user";
        fresh[n_fresh].content = prompt;
        fresh[n_fresh].content_len = prompt ? strlen(prompt) : 0;
        n_fresh++;
    }

    /* The loop's seed array.  On a resume it BORROWS prior.msgs, so
     * ckpt_messages_free(&prior) must come after the final ckpt_save. */
    const LlmMsg *seed_msgs = resumed ? prior.msgs : fresh;
    size_t n_seeds = resumed ? prior.n : n_fresh;

    CkptMessages transcript;
    ckpt_messages_init(&transcript);

    /* The flush state: every message the loop appends is written to
     * msgs_path (fsync'd) as it arrives, so the transcript is durable BEFORE
     * the tool call that reboots the guest.  skip = the messages already on
     * disk (the resume seed), which the loop re-notifies from :739. */
    CbCtx cb;
    memset(&cb, 0, sizeof cb);
    cb.c = &transcript;
    cb.path = msgs_path;
    cb.dir = sess_dir;
    cb.skip = n_seed_disk;

    TurnResult final;
    memset(&final, 0, sizeof final);

    /* --output tui: run the loop through the per-delta sink so the terminal
     * streams live.  If stdout/stdin are not a tty (or tui_init fails), the TUI
     * degrades to pass-through; for output parity we fall back to the text path
     * so a non-tty --output tui produces the SAME stdout text as --output text. */
    int use_tui_active = 0;
    Tui *tui = NULL;
    if (output && strcmp(output, "tui") == 0) {
        if (tui_init(&tui, stdin, stdout) == 0 && tui && tui_active(tui))
            use_tui_active = 1;
        else if (tui) { tui_free(tui); tui = NULL; }
    }

    int rc;
    int tui_aborted = 0;
    if (use_tui_active) {
        TuiSink sink = { {0}, tui };
        rc = agent_loop_run_delta(backend, model, tool_srv, &policy,
                                  seed_msgs, n_seeds, max_turns, &final,
                                  transcript_cb, &cb,
                                  tui_delta_cb, &sink);
        tui_aborted = (rc != 0 && sink.ab.abort);
        (void)tui_end_stream(tui);
        if (rc == 0 && final.text && final.text_len)
            (void)tui_append_line(tui, final.text, final.text_len);
        (void)tui_statusf(tui, "done (scroll: arrows/PgUp/PgDn, Ctrl-L redraw, q quit)");
        /* A brief blocking interactive loop so the user can read/scroll before
         * the terminal is restored.  poll_key is non-blocking, so sleep between
         * polls to bound the wait (~3s) and give the user time to scroll. */
        for (int i = 0; i < 30; i++) {
            int k = tui_poll_key(tui);
            if (k == TUI_KEY_QUIT) break;
            if (k == TUI_KEY_NONE) usleep(100000);
        }
        tui_free(tui);
        tui = NULL;
    } else {
        rc = agent_loop_run_ex(backend, model, tool_srv, &policy,
                               seed_msgs, n_seeds, max_turns, &final,
                               transcript_cb, &cb);
    }

    /* The loop's transcript holds the seeds + every appended assistant/tool
     * message, but the FINAL text turn is returned in `final` without being
     * appended (agent_loop breaks on n_tool_calls==0).  Append a synthetic
     * role=assistant message so the model's answer is durable in messages.jsonl
     * (not only stdout), preserving the resume story.  Flush it too — it is a
     * NEW line (unlike the borrowed seeds it is not already on disk). */
    if (rc == 0 && final.text && final.text_len) {
        LlmMsg answer;
        memset(&answer, 0, sizeof answer);
        answer.role = "assistant";
        answer.content = final.text;
        answer.content_len = final.text_len;
        (void)ckpt_append(&transcript, &answer);
        /* Flush it as its own line too: if ckpt_save below fails, the answer is
         * still durable.  (ckpt_save REWRITES the file from the in-memory list,
         * so this line is replaced, not duplicated.) */
        if (ckpt_append_line(msgs_path, &answer) != 0 && !cb.warned) {
            fprintf(stderr,
                    "agent_main: warning: transcript flush to '%s' failed; "
                    "the transcript is still written at end of run\n",
                    msgs_path);
            cb.warned = 1;
        }
    }

    /* Write the full transcript, rewriting the file from the in-memory list:
     * this is both the end-of-run record and the SELF-HEAL for a torn tail
     * line left by a flush that was cut off mid-write (ckpt_load skips such a
     * line fail-open, and this rewrite drops it for good).  msgs_path is the
     * session's messages.jsonl, so a resumed run rewrites the SAME file it
     * loaded — the pre-death lines and the new ones end up in one transcript. */
    (void)ckpt_save(msgs_path, &transcript);

    (void)ckpt_run_set_status(&rs, run_id,
                              rc == 0 ? RS_STATUS_DONE : RS_STATUS_FAILED);
    ckpt_run_close(&rs);

    int exit_code;
    if (rc != 0 && !tui_aborted) {
        fprintf(stderr, "agent_main: agent loop failed (backend/loop error)\n");
        exit_code = 1;
    } else if (tui_aborted) {
        /* The user pressed quit mid-stream: a clean stop, not an error. */
        exit_code = 0;
    } else {
        /* --output text (or a non-tty --output tui, which degrades to the same):
         * the final assistant text to stdout.  use_tui_active is 1 only when the
         * live TUI is active (which renders final.text itself via
         * tui_append_line); it is 0 for BOTH --output text and a degraded
         * --output tui, so gating on !use_tui_active emits the answer on stdout
         * for every non-TUI path. */
        if (!use_tui_active && final.text && final.text_len)
            printf("%s\n", final.text);
        exit_code = 0;
    }

    free(sysbuf);
    agent_loop_free_turn(&final);
    ckpt_messages_free(&transcript);
    /* ONLY after the ckpt_save above: on a resume, seed_msgs points into
     * prior.msgs and the loop read them; freeing earlier is a use-after-free. */
    ckpt_messages_free(&prior);
    config_free(&cfg);
    return exit_code;
}
