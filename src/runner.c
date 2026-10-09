/* src/runner.c — SECURITY KEYSTONE: locked `vibe -p` argv builder.
 *
 * Port of vibe_runtime/runner.py into C. Every string that can reach a child
 * subprocess argv is validated here; the prompt is always a plain argv element
 * and never a shell string; only caller-approved flags are ever emitted.
 * See src/runner.h for the config decision (runtime's OWN Dhall config).
 */
#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <limits.h>
#include <sys/stat.h>
#include <pthread.h>

#include "runner.h"
#include "dhall.h"
#include "yyjson.h"
#include "llm2/dhall_eval_lock.h"

/* Serializes dhall_eval_to_json (its process-global arena is NOT thread-safe;
 * the daemon is thread-per-conn and calls validate_agent_profile from multiple
 * conn_threads concurrently). This is the process-wide lock SHARED with
 * config.c (src/llm2) — a per-TU mutex would let two threads touch the same
 * arena concurrently. Statically initialized, ready before main. */

/* ------------------------------------------------------------------ */
/* MAX_TURNS bound (env VIBE_MAX_TURNS, default 1000)                 */
/* ------------------------------------------------------------------ */

int runner_max_turns(void) {
    const char *s = getenv("VIBE_MAX_TURNS");
    if (!s || !*s) return RUNNER_MAX_TURNS_DEFAULT;
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end == s || *end != '\0' || v <= 0 || v > INT_MAX) {
        return RUNNER_MAX_TURNS_DEFAULT;
    }
    return (int)v;
}

/* ------------------------------------------------------------------ */
/* validate_identifier                                                */
/* ------------------------------------------------------------------ */

int validate_identifier(const char *value, const char *field, RunnerError *err) {
    if (!value || !*value) {
        RUNNER_ERROR(err, "invalid %s: must match ^[A-Za-z0-9._-]+$ and not start with '-'",
                     field ? field : "value");
        return -1;
    }
    if (value[0] == '-') {
        RUNNER_ERROR(err, "invalid %s '%.300s': must match ^[A-Za-z0-9._-]+$ and not start with '-'",
                     field ? field : "value", value);
        return -1;
    }
    for (const char *p = value; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')) {
            RUNNER_ERROR(err, "invalid %s '%.300s': must match ^[A-Za-z0-9._-]+$ and not start with '-'",
                         field ? field : "value", value);
            return -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* validate_cwd + confinement                                        */
/* ------------------------------------------------------------------ */

int validate_cwd(const char *cwd, RunnerError *err) {
    if (!cwd || cwd[0] != '/') {
        RUNNER_ERROR(err, "cwd must be an absolute path, got '%.300s'", cwd ? cwd : "");
        return -1;
    }
    struct stat st;
    if (stat(cwd, &st) != 0 || !S_ISDIR(st.st_mode)) {
        RUNNER_ERROR(err, "cwd is not an existing directory: '%.300s'", cwd);
        return -1;
    }
    return 0;
}

static void projects_root(char *out, size_t cap) {
    const char *env = getenv("VIBE_PROJECTS_ROOT");
    if (env && *env) {
        snprintf(out, cap, "%s", env);
        return;
    }
    const char *home = getenv("HOME");
    if (home && *home) {
        snprintf(out, cap, "%s/projects", home);
    } else {
        snprintf(out, cap, "/projects");
    }
}

/* Best-effort canonical path: realpath when it resolves, else the input. */
static void resolve_path(const char *in, char *out, size_t cap) {
    char r[PATH_MAX];
    if (realpath(in, r)) {
        snprintf(out, cap, "%s", r);
    } else {
        snprintf(out, cap, "%s", in);
    }
}

int validate_cwd_confinement(const char *cwd, RunnerError *err) {
    char root[PATH_MAX];
    projects_root(root, sizeof(root));
    char rcwd[PATH_MAX], rroot[PATH_MAX];
    resolve_path(cwd, rcwd, sizeof(rcwd));
    resolve_path(root, rroot, sizeof(rroot));

    size_t n = strlen(rroot);
    if (strncmp(rcwd, rroot, n) != 0 || (rcwd[n] != '/' && rcwd[n] != '\0')) {
        RUNNER_ERROR(err, "cwd '%.300s' is outside the projects root '%.300s'", cwd, root);
        return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Runtime config dir resolution                                      */
/* ------------------------------------------------------------------ */

static void runtime_config_dir(char *out, size_t cap) {
    const char *env = getenv("VIBE_RUNTIME_CONFIG_DIR");
    if (env && *env) {
        snprintf(out, cap, "%s", env);
        return;
    }
    const char *home = getenv("HOME");
    if (home && *home) {
        snprintf(out, cap, "%s/.config/vibe-runtime", home);
    } else {
        snprintf(out, cap, ".config/vibe-runtime");
    }
}

/* Read a whole file into a NUL-terminated malloc'd buffer. Returns 0 on
 * success (caller frees *out), -1 on any I/O failure. */
static int read_file(const char *path, char **out) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return -1; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return -1; }
    char *buf = malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return -1; }
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[got] = '\0';
    *out = buf;
    return 0;
}

/* Evaluate a Dhall source string in-process and return the JSON as a malloc'd
 * string, or NULL on any failure. Serialized by g_dhall_eval_lock (shared with
 * config.c); callers hold that lock around this. */
static char *dhall_eval_to_json(const char *src) {
    if (!dhall_arena) dhall_arena = arena_new();
    arena_reset(dhall_arena);

    ImportLoader *loader = import_loader_new();
    import_loader_push_root(loader, NULL);

    Parser p;
    memset(&p, 0, sizeof(p));
    p.loader = loader;

    DhallError err;
    dhall_error_clear(&err);

    Term *t = parse_source(&p, src, "<runtime-config>", &err);
    if (!t) { import_loader_free(loader); return NULL; }
    Term *ty = infer_type(&p, t, &err);
    if (!ty) { import_loader_free(loader); return NULL; }
    normalize_clear_error();
    Term *val = normalize(t);
    if (normalize_has_error()) { import_loader_free(loader); return NULL; }

    FILE *outf = tmpfile();
    if (!outf) { import_loader_free(loader); return NULL; }
    bool ok = term_to_json(outf, val, &err);
    if (ok) fflush(outf);
    rewind(outf);

    size_t len = 0;
    char *buf = NULL;
    if (ok) {
        size_t bufsz = 1024;
        buf = malloc(bufsz + 1);
        if (!buf) { fclose(outf); import_loader_free(loader); return NULL; }
        size_t n;
        while ((n = fread(buf + len, 1, bufsz - len, outf)) > 0) {
            len += n;
            if (len == bufsz) {
                bufsz *= 2;
                char *nb = realloc(buf, bufsz + 1);
                if (!nb) { free(buf); fclose(outf); import_loader_free(loader); return NULL; }
                buf = nb;
            }
        }
        buf[len] = '\0';
    }
    fclose(outf);
    import_loader_free(loader);
    if (!ok) { free(buf); return NULL; }
    return buf;
}

/* Look up the agent in the runtime's own config.dhall.
 * Returns:  1 = found and valid (accept)
 *           0 = fail-open (config missing/unparseable — accept, never false-reject)
 *          -1 = hard reject (agent is a subagent, or missing from config)
 * On reject, *err is filled. */
static int config_check_agent(const char *agent, RunnerError *err) {
    char dir[PATH_MAX];
    runtime_config_dir(dir, sizeof(dir));

    char path[PATH_MAX + 32];
    snprintf(path, sizeof(path), "%s/config.dhall", dir);

    char *src = NULL;
    if (read_file(path, &src) != 0) {
        /* Config missing/unreadable -> fail-open. */
        return 0;
    }

    pthread_mutex_lock(&g_dhall_eval_lock);
    char *json = dhall_eval_to_json(src);
    pthread_mutex_unlock(&g_dhall_eval_lock);
    free(src);
    if (!json) {
        /* Malformed/unparseable config -> fail-open. */
        return 0;
    }

    int rc = 0; /* default fail-open */
    yyjson_doc *doc = yyjson_read(json, strlen(json), 0);
    if (doc) {
        yyjson_val *root = yyjson_doc_get_root(doc);
        yyjson_val *agents = yyjson_obj_get(root, "agents");
        if (agents && yyjson_is_arr(agents)) {
            const char *found_type = NULL;
            bool found = false;
            yyjson_val *it;
            size_t i, max;
            yyjson_arr_foreach(agents, i, max, it) {
                if (!yyjson_is_obj(it)) continue;
                yyjson_val *name = yyjson_obj_get(it, "name");
                if (!name || !yyjson_is_str(name)) continue;
                if (strcmp(yyjson_get_str(name), agent) != 0) continue;
                found = true;
                yyjson_val *at = yyjson_obj_get(it, "agent_type");
                if (at && yyjson_is_str(at)) found_type = yyjson_get_str(at);
                break;
            }
            if (!found) {
                RUNNER_ERROR(err, "agent profile '%.300s' not found in runtime config (looked in %.300s)",
                             agent, dir);
                rc = -1;
            } else if (found_type && strcmp(found_type, "subagent") == 0) {
                RUNNER_ERROR(err,
                             "agent '%.300s' is a subagent (agent_type=\"subagent\") and "
                             "cannot be used as the primary agent for a detached run; "
                             "choose an agent_type=\"agent\" profile", agent);
                rc = -1;
            } else {
                rc = 1; /* found + not a subagent -> accept */
            }
        }
        /* agents list absent -> no mapping -> accept (fail-open). */
    }
    yyjson_doc_free(doc);
    free(json);
    return rc;
}

int validate_agent_profile(const char *agent, RunnerError *err) {
    if (validate_identifier(agent, "agent", err) != 0) return -1;
    int rc = config_check_agent(agent, err);
    if (rc < 0) return -1;   /* hard reject */
    return 0;                 /* found+valid, or fail-open accept */
}

/* ------------------------------------------------------------------ */
/* build_vibe_cmd — locked argv builder                               */
/* ------------------------------------------------------------------ */

static int cmd_append(RunnerCmd *cmd, const char *s) {
    char **na = realloc(cmd->argv, sizeof(char *) * (size_t)(cmd->argc + 2));
    if (!na) return -1;
    cmd->argv = na;
    cmd->argv[cmd->argc] = strdup(s ? s : "");
    if (!cmd->argv[cmd->argc]) return -1;
    cmd->argc++;
    cmd->argv[cmd->argc] = NULL;
    return 0;
}

void runner_cmd_free(RunnerCmd *cmd) {
    if (!cmd) return;
    for (int i = 0; i < cmd->argc; i++) free(cmd->argv[i]);
    free(cmd->argv);
    cmd->argv = NULL;
    cmd->argc = 0;
}

void runner_agent_main_path(char *out, size_t cap) {
    const char *env = getenv("VIBE_AGENT_MAIN");
    if (env && *env) { snprintf(out, cap, "%s", env); return; }
    /* No legacy `vibe` fallback: the Python reference was removed, so a
     * missing native binary must fail loudly (exec fails -> child 127 ->
     * reaped as FAILED) rather than silently re-invoking an interpreter. */
    snprintf(out, cap, "build/agent_main");
}

int build_vibe_cmd(const char *agent, const char *prompt,
                   const char *session_id, int max_turns,
                   const char *cwd, const char *output, bool auto_approve,
                   RunnerError *err, RunnerCmd *out) {
    if (!out) return -1;

    if (validate_identifier(agent, "agent", err) != 0) return -1;
    if (session_id && *session_id) {
        if (validate_identifier(session_id, "session_id", err) != 0) return -1;
    }
    int mt = runner_max_turns();
    if (max_turns <= 0 || max_turns > mt) {
        RUNNER_ERROR(err, "max_turns must be between 1 and %d, got %d", mt, max_turns);
        return -1;
    }
    if (cwd && *cwd) {
        if (validate_cwd(cwd, err) != 0) return -1;
        if (validate_cwd_confinement(cwd, err) != 0) return -1;
    }

    RunnerCmd cmd = { NULL, 0 };
    char turns[32];
    snprintf(turns, sizeof(turns), "%d", max_turns);

    char argv0[PATH_MAX];
    runner_agent_main_path(argv0, sizeof(argv0));
    if (cmd_append(&cmd, argv0) != 0 ||
        cmd_append(&cmd, "-p") != 0 ||
        cmd_append(&cmd, prompt ? prompt : "") != 0 ||
        cmd_append(&cmd, "--agent") != 0 ||
        cmd_append(&cmd, agent) != 0 ||
        cmd_append(&cmd, "--max-turns") != 0 ||
        cmd_append(&cmd, turns) != 0) {
        runner_cmd_free(&cmd);
        return -1;
    }
    if (session_id && *session_id) {
        if (cmd_append(&cmd, "--resume") != 0 || cmd_append(&cmd, session_id) != 0) {
            runner_cmd_free(&cmd);
            return -1;
        }
    }
    if (cwd && *cwd) {
        if (cmd_append(&cmd, "--workdir") != 0 || cmd_append(&cmd, cwd) != 0) {
            runner_cmd_free(&cmd);
            return -1;
        }
    }
    if (cmd_append(&cmd, "--output") != 0 ||
        cmd_append(&cmd, output && *output ? output : "text") != 0) {
        runner_cmd_free(&cmd);
        return -1;
    }
    if (auto_approve) {
        if (cmd_append(&cmd, "--auto-approve") != 0) {
            runner_cmd_free(&cmd);
            return -1;
        }
    }

    *out = cmd;
    return 0;
}
