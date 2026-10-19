/* src/agent/config.c — runtime config loader.
 *
 * Evaluates the runtime's OWN config.dhall in-process via the vendored dhall-c
 * and walks the resulting JSON (yyjson) into a RuntimeConfig.  The dhall-c eval
 * machinery (runtime_config_dir / read_file / dhall_eval_to_json under a mutex)
 * mirrors src/runner.c's proven pattern — these are small and re-implemented
 * here because runner.c's copies are static; runner.c semantics are untouched.
 *
 * Schema (dhall -> json via dhall-c):
 *   { agents = [ { name, agent_type, model, default_max_turns, prompt_file,
 *                  mcp_servers } ] }
 * Optional fields may be absent (no json key), None/Some (Optional -> null /
 * inner value), or plain values (Text -> string, Natural -> number).  The walk
 * treats NULL/missing as "unset" throughout.
 *
 * FAIL-OPEN: missing/unreadable/malformed config, or an empty/absent agents
 * list, yields an empty RuntimeConfig and returns 0 — never a crash.
 *
 * THAT FAIL-OPEN CONTRACT IS FOR INTENT ONLY.  The moved access-control fields
 * are checked by config_check_moved BELOW — a SEPARATE, FAIL-CLOSED pass that
 * never returns 0-by-parse-failure and is called by agent_main BEFORE
 * config_load.  Do not fold it into the fail-open path: a refusal that path can
 * skip is not a refusal (plan handoff-aclsplit-plan, risk R4).
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <limits.h>

#include "config.h"
#include "dhall.h"
#include "yyjson.h"
#include "dhall_eval_lock.h"

/* The dhall-c arena is a process-global and NOT thread-safe (same caveat as
 * runner.c).  Guard every eval with the process-wide shared lock declared in
 * dhall_eval_lock.h — the SAME mutex runner.c uses, so runner.c and config.c
 * can never corrupt the shared arena concurrently.  Statically initialized in
 * dhall_eval_lock.c, so it is ready before main and needs no pthread_once. */

/* Sanity caps on config-driven array sizes (config-origin, length-checked). */
#define CONFIG_MAX_AGENTS       512u
#define CONFIG_MAX_MCP_SERVERS  128u
#define CONFIG_MAX_MCP_ARGS     128u
#define CONFIG_MAX_MCP_ENV      128u

/* ------------------------------------------------------------------ */
/* Path + file helpers (mirrors runner.c)                             */
/* ------------------------------------------------------------------ */

static void runtime_config_dir(char *out, size_t cap) {
    const char *env = getenv("FX_AGENT_CONFIG_DIR");
    if (env && *env) {
        snprintf(out, cap, "%s", env);
        return;
    }
    const char *home = getenv("HOME");
    if (home && *home) {
        snprintf(out, cap, "%s/.config/fx-agent", home);
    } else {
        snprintf(out, cap, ".config/fx-agent");
    }
}

/* Read a whole file into a NUL-terminated malloc'd buffer.  0 on success
 * (caller frees *out), -1 on any I/O failure. */
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
 * string, or NULL on any failure.  Callers hold g_dhall_eval_lock. */
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

/* ------------------------------------------------------------------ */
/* JSON walk into RuntimeConfig (fail-open per-field)                 */
/* ------------------------------------------------------------------ */

/* Length-capped strdup of config-origin bytes.  Never sprintf/strcpy. */
static char *dup_capped(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s);
    if (n > CONFIG_FIELD_CAP) n = CONFIG_FIELD_CAP;
    char *out = malloc(n + 1);
    if (!out) return NULL;
    memcpy(out, s, n);
    out[n] = '\0';
    return out;
}

static void free_config_agent(ConfigAgent *a) {
    if (!a) return;
    free(a->name);
    free(a->agent_type);
    free(a->model);
    free(a->prompt_file);
    for (size_t i = 0; i < a->n_mcp_servers; i++) {
        McpToolServer *s = &a->mcp_servers[i];
        free((char *)s->command);
        free((char *)s->scope);
        free((char *)s->name);
        for (size_t j = 0; j < s->n_args; j++) free(s->args[j]);
        free(s->args);
        for (size_t j = 0; j < s->n_env; j++) free(s->env[j]);
        free(s->env);
    }
    free(a->mcp_servers);
}

/* Parse one mcp_servers record into *srv (malloc'd owned copies).  Returns 0 on
 * success, -1 on OOM (in which case *srv is left free-able via free_config_agent
 * only if committed; here the caller commits only on success, so a failing
 * append cleans up its own temp). */
static int parse_mcp_server(yyjson_val *rec, McpToolServer *srv) {
    memset(srv, 0, sizeof *srv);

    yyjson_val *cmd = yyjson_obj_get(rec, "command");
    if (cmd && yyjson_is_str(cmd)) {
        srv->command = dup_capped(yyjson_get_str(cmd));
        if (!srv->command) return -1;
    }

    yyjson_val *scope = yyjson_obj_get(rec, "scope");
    if (scope && yyjson_is_str(scope)) {
        srv->scope = dup_capped(yyjson_get_str(scope));
        if (!srv->scope) return -1;
    }

    yyjson_val *name = yyjson_obj_get(rec, "name");
    if (name && yyjson_is_str(name)) {
        srv->name = dup_capped(yyjson_get_str(name));
        if (!srv->name) return -1;
    }

    yyjson_val *args = yyjson_obj_get(rec, "args");
    if (args && yyjson_is_arr(args)) {
        yyjson_val *it;
        size_t i, max;
        size_t cap = 0;
        yyjson_arr_foreach(args, i, max, it) {
            if (!yyjson_is_str(it)) continue;
            if (srv->n_args >= CONFIG_MAX_MCP_ARGS) break;
            if (srv->n_args == cap) {
                size_t ncap = cap ? cap * 2 : 4;
                if (ncap > CONFIG_MAX_MCP_ARGS) ncap = CONFIG_MAX_MCP_ARGS;
                char **na = realloc(srv->args, ncap * sizeof(char *));
                if (!na) return -1;
                srv->args = na;
                cap = ncap;
            }
            char *dup = dup_capped(yyjson_get_str(it));
            if (!dup) return -1;
            srv->args[srv->n_args++] = dup;
        }
    }

    /* `env` accepts TWO dhall-c serialized shapes (both become "K=V" entries):
     *   1. a JSON object  { "KEY": "value", ... }  — dhall `Some { KEY = "v" }`
     *      (record literal; only usable when every server has the SAME keys).
     *   2. a JSON array    [ {"mapKey":"KEY","mapValue":"v"}, ... ] — dhall
     *      `Some ([ { mapKey = "KEY", mapValue = "v" } ] : List { mapKey : Text,
     *      mapValue : Text })` (the toMap form; required for dhall-c record
     *      homogeneity when servers differ in which env keys they set).
     * Both are accepted; the array form is the portable one. */
    yyjson_val *env_obj = yyjson_obj_get(rec, "env");
    if (env_obj && yyjson_is_obj(env_obj)) {
        yyjson_val *key, *val;
        size_t i, max;
        size_t cap = 0;
        yyjson_obj_foreach(env_obj, i, max, key, val) {
            if (!yyjson_is_str(key) || !yyjson_is_str(val)) continue;
            if (srv->n_env >= CONFIG_MAX_MCP_ENV) break;
            if (srv->n_env == cap) {
                size_t ncap = cap ? cap * 2 : 4;
                if (ncap > CONFIG_MAX_MCP_ENV) ncap = CONFIG_MAX_MCP_ENV;
                char **na = realloc(srv->env, ncap * sizeof(char *));
                if (!na) return -1;
                srv->env = na;
                cap = ncap;
            }
            const char *k = yyjson_get_str(key);
            const char *v = yyjson_get_str(val);
            size_t klen = strlen(k);
            size_t vlen = strlen(v);
            char *entry = malloc(klen + vlen + 2);
            if (!entry) return -1;
            memcpy(entry, k, klen);
            entry[klen] = '=';
            memcpy(entry + klen + 1, v, vlen);
            entry[klen + vlen + 1] = '\0';
            srv->env[srv->n_env++] = entry;
        }
    } else if (env_obj && yyjson_is_arr(env_obj)) {
        /* toMap form: array of { mapKey, mapValue }. */
        yyjson_val *it;
        size_t i, max;
        size_t cap = 0;
        yyjson_arr_foreach(env_obj, i, max, it) {
            if (!yyjson_is_obj(it)) continue;
            yyjson_val *kv = yyjson_obj_get(it, "mapKey");
            yyjson_val *vv = yyjson_obj_get(it, "mapValue");
            if (!kv || !yyjson_is_str(kv) || !vv || !yyjson_is_str(vv)) continue;
            if (srv->n_env >= CONFIG_MAX_MCP_ENV) break;
            if (srv->n_env == cap) {
                size_t ncap = cap ? cap * 2 : 4;
                if (ncap > CONFIG_MAX_MCP_ENV) ncap = CONFIG_MAX_MCP_ENV;
                char **na = realloc(srv->env, ncap * sizeof(char *));
                if (!na) return -1;
                srv->env = na;
                cap = ncap;
            }
            const char *k = yyjson_get_str(kv);
            const char *v = yyjson_get_str(vv);
            size_t klen = strlen(k);
            size_t vlen = strlen(v);
            char *entry = malloc(klen + vlen + 2);
            if (!entry) return -1;
            memcpy(entry, k, klen);
            entry[klen] = '=';
            memcpy(entry + klen + 1, v, vlen);
            entry[klen + vlen + 1] = '\0';
            srv->env[srv->n_env++] = entry;
        }
    }

    yyjson_val *startup_timeout = yyjson_obj_get(rec, "startup_timeout_sec");
    if (startup_timeout && yyjson_is_num(startup_timeout)) {
        double v = yyjson_get_num(startup_timeout);
        if (v > 0 && isfinite(v)) srv->startup_timeout_s = v;
    }

    yyjson_val *tool_timeout = yyjson_obj_get(rec, "tool_timeout_sec");
    if (tool_timeout && yyjson_is_num(tool_timeout)) {
        double v = yyjson_get_num(tool_timeout);
        if (v > 0 && isfinite(v)) srv->tool_timeout_s = v;
    }

    return 0;
}

/* Parse one agent object into a fresh ConfigAgent; on success the caller
 * commits it (owns everything).  Returns 0 on success, -1 on OOM. */
static int parse_agent(RuntimeConfig *out, yyjson_val *ag, const char *name) {
    ConfigAgent a;
    memset(&a, 0, sizeof a);
    a.name = dup_capped(name);
    if (!a.name) return -1;

    yyjson_val *at = yyjson_obj_get(ag, "agent_type");
    if (at && yyjson_is_str(at)) {
        a.agent_type = dup_capped(yyjson_get_str(at));
        if (!a.agent_type) { free_config_agent(&a); return -1; }
    }

    yyjson_val *model = yyjson_obj_get(ag, "model");
    if (model && yyjson_is_str(model)) {
        a.model = dup_capped(yyjson_get_str(model));
        if (!a.model) { free_config_agent(&a); return -1; }
    }

    yyjson_val *mt = yyjson_obj_get(ag, "default_max_turns");
    if (mt && yyjson_is_num(mt)) {
        a.default_max_turns = (unsigned long)yyjson_get_uint(mt);
    }

    yyjson_val *prompt_file = yyjson_obj_get(ag, "prompt_file");
    if (prompt_file && yyjson_is_str(prompt_file)) {
        a.prompt_file = dup_capped(yyjson_get_str(prompt_file));
        if (!a.prompt_file) { free_config_agent(&a); return -1; }
    }

    yyjson_val *servers = yyjson_obj_get(ag, "mcp_servers");
    if (servers && yyjson_is_arr(servers)) {
        yyjson_val *sit;
        size_t i, max;
        yyjson_arr_foreach(servers, i, max, sit) {
            if (!yyjson_is_obj(sit)) continue;
            if (a.n_mcp_servers >= CONFIG_MAX_MCP_SERVERS) break;
            if (a.n_mcp_servers == a.cap_mcp_servers) {
                size_t ncap = a.cap_mcp_servers ? a.cap_mcp_servers * 2 : 2;
                if (ncap > CONFIG_MAX_MCP_SERVERS) ncap = CONFIG_MAX_MCP_SERVERS;
                McpToolServer *ns = realloc(a.mcp_servers, ncap * sizeof(McpToolServer));
                if (!ns) { free_config_agent(&a); return -1; }
                a.mcp_servers = ns;
                a.cap_mcp_servers = ncap;
            }
            McpToolServer srv;
            if (parse_mcp_server(sit, &srv) != 0) {
                /* Free the partially-built spec (OOM path) before bailing. */
                free((char *)srv.command);
                free((char *)srv.scope);
                free((char *)srv.name);
                for (size_t k = 0; k < srv.n_args; k++) free(srv.args[k]);
                free(srv.args);
                for (size_t k = 0; k < srv.n_env; k++) free(srv.env[k]);
                free(srv.env);
                free_config_agent(&a);
                return -1;
            }
            a.mcp_servers[a.n_mcp_servers++] = srv;
        }
    }

    if (out->n_agents == out->cap_agents) {
        size_t ncap = out->cap_agents ? out->cap_agents * 2 : 4;
        if (ncap > CONFIG_MAX_AGENTS) ncap = CONFIG_MAX_AGENTS;
        ConfigAgent *na = realloc(out->agents, ncap * sizeof(ConfigAgent));
        if (!na) { free_config_agent(&a); return -1; }
        out->agents = na;
        out->cap_agents = ncap;
    }
    out->agents[out->n_agents++] = a;
    return 0;
}

/* Walk the config JSON into out.  Returns 0 (out possibly empty), -1 on OOM. */
static int parse_config_json(const char *json, RuntimeConfig *out) {
    yyjson_doc *doc = yyjson_read(json, strlen(json), 0);
    if (!doc) return 0; /* fail-open: treat unparseable JSON as empty */

    yyjson_val *root = yyjson_doc_get_root(doc);
    if (root && yyjson_is_obj(root)) {
        /* Parse agents */
        yyjson_val *agents = yyjson_obj_get(root, "agents");
        if (agents && yyjson_is_arr(agents)) {
            yyjson_val *it;
            size_t i, max;
            yyjson_arr_foreach(agents, i, max, it) {
                if (!yyjson_is_obj(it)) continue;
                yyjson_val *name = yyjson_obj_get(it, "name");
                if (!name || !yyjson_is_str(name)) continue;
                if (out->n_agents >= CONFIG_MAX_AGENTS) break;
                if (parse_agent(out, it, yyjson_get_str(name)) != 0) {
                    yyjson_doc_free(doc);
                    return -1;
                }
            }
        }
    }
    yyjson_doc_free(doc);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Public API                                                         */
/* ------------------------------------------------------------------ */

int config_load(RuntimeConfig *out, char *err, size_t errcap) {
    memset(out, 0, sizeof *out);
    if (errcap) err[0] = '\0';

    char dir[PATH_MAX];
    runtime_config_dir(dir, sizeof(dir));
    char path[PATH_MAX + 32];
    snprintf(path, sizeof(path), "%s/config.dhall", dir);

    char *src = NULL;
    if (read_file(path, &src) != 0) {
        /* Config missing/unreadable -> fail-open (empty config). */
        return 0;
    }

    pthread_mutex_lock(&g_dhall_eval_lock);
    char *json = dhall_eval_to_json(src);
    pthread_mutex_unlock(&g_dhall_eval_lock);
    free(src);
    if (!json) {
        /* Malformed/unparseable config -> fail-open (empty config). */
        return 0;
    }

    int rc = parse_config_json(json, out);
    free(json);
    if (rc != 0 && err && errcap) {
        snprintf(err, errcap, "config_load: out of memory parsing config.dhall");
    }
    if (rc != 0) {
        /* Hard error: leave out emptied (config_free safe). */
        config_free(out);
    }
    return rc;
}

void config_free(RuntimeConfig *cfg) {
    if (!cfg) return;
    for (size_t i = 0; i < cfg->n_agents; i++) {
        free_config_agent(&cfg->agents[i]);
    }
    free(cfg->agents);
    memset(cfg, 0, sizeof *cfg);
}

const ConfigAgent *config_find_agent(const RuntimeConfig *cfg, const char *name) {
    if (!cfg || !name) return NULL;
    for (size_t i = 0; i < cfg->n_agents; i++) {
        if (cfg->agents[i].name && strcmp(cfg->agents[i].name, name) == 0) {
            return &cfg->agents[i];
        }
    }
    return NULL;
}

/* ------------------------------------------------------------------ */
/* THE MOVED-FIELD MIGRATION PASS (FAIL-CLOSED, beside config_load)    */
/* ------------------------------------------------------------------ */

/* The access-control fields this schema no longer has, and the HOST file that
 * owns each one now.  The owner string is what the operator is told to edit, so
 * it names the file, not a role — a refusal that says only "not allowed here"
 * sends the reader nowhere and invites them to put the field back.
 *
 * BOTH spellings of the provider join are listed: a top-level `providers` block
 * and the `provider` field a model entry used to carry.  `models` is listed
 * whole because, with the join gone, a name-only models table is data NOTHING
 * reads — a config field with no consumer is this tree's most productive bug
 * shape, and the agent names its engine in `agent.model` instead. */
static const struct {
    const char *field;
    const char *owner;
} CONFIG_MOVED[] = {
    { "enabled_tools",
      "policy/access/access-verbs.tsv (the operator's pinned ACCESS TABLE — "
      "the verb vocabulary, enforced at the host seat tools/fx-hostgate.c)" },
    { "disabled_tools",
      "policy/access/access-verbs.tsv (the operator's pinned ACCESS TABLE — "
      "the verb vocabulary, enforced at the host seat tools/fx-hostgate.c)" },
    { "providers",
      "the HOST PROXY (tools/fx-hostgate.c) — it owns the provider endpoint AND "
      "the credential (FX_HOSTGATE_KEY); the guest has no network at all" },
    { "api_key_env_var",
      "the HOST PROXY (tools/fx-hostgate.c) — the credential is the host's; a "
      "guest-readable NAME for it is only a targeting hint" },
    { "models",
      "the HOST PROXY (tools/fx-hostgate.c) — a model entry existed to name a "
      "provider; the agent names its ENGINE in agent.model instead" },
    { "provider",
      "the HOST PROXY (tools/fx-hostgate.c) — the model->provider join is the "
      "host's (the guest keeps no join and needs none)" },
};

static const char *moved_owner(const char *key) {
    if (!key) return NULL;
    for (size_t i = 0; i < sizeof CONFIG_MOVED / sizeof CONFIG_MOVED[0]; i++) {
        if (strcmp(key, CONFIG_MOVED[i].field) == 0) return CONFIG_MOVED[i].owner;
    }
    return NULL;
}

/* Recursive search of a JSON VALUE for a MOVED FIELD NAME used as an OBJECT
 * KEY.  A string VALUE that happens to spell a field name is not a field and is
 * not refused (it cannot constrain anything). */
static int json_find_moved(yyjson_val *v, const char **field, const char **owner) {
    if (!v) return 0;
    if (yyjson_is_obj(v)) {
        yyjson_val *k, *val;
        size_t i, max;
        yyjson_obj_foreach(v, i, max, k, val) {
            if (yyjson_is_str(k)) {
                const char *own = moved_owner(yyjson_get_str(k));
                if (own) {
                    *field = yyjson_get_str(k);
                    *owner = own;
                    return 1;
                }
            }
            if (json_find_moved(val, field, owner)) return 1;
        }
    } else if (yyjson_is_arr(v)) {
        yyjson_val *it;
        size_t i, max;
        yyjson_arr_foreach(v, i, max, it) {
            if (json_find_moved(it, field, owner)) return 1;
        }
    }
    return 0;
}

int config_check_moved(char *err, size_t errcap) {
    if (errcap) err[0] = '\0';

    char dir[PATH_MAX];
    runtime_config_dir(dir, sizeof(dir));
    char path[PATH_MAX + 32];
    snprintf(path, sizeof(path), "%s/config.dhall", dir);

    /* A missing/unreadable config carries no field to move — and the run then
     * fails loudly downstream anyway (an empty agents list is "agent not
     * found", exit 1), so this is not a silent path in either direction. */
    char *src = NULL;
    if (read_file(path, &src) != 0) return 0;

    pthread_mutex_lock(&g_dhall_eval_lock);
    char *json = dhall_eval_to_json(src);
    pthread_mutex_unlock(&g_dhall_eval_lock);
    free(src);
    if (!json) {
        /* Does not EVALUATE.  That is not a moved field and is not this pass's
         * business: config_load fail-opens to an empty config and the run stops
         * at "agent not found" — loud, with nothing to ignore. */
        return 0;
    }

    const char *field = NULL, *owner = NULL;
    int hit = 0;
    yyjson_doc *doc = yyjson_read(json, strlen(json), 0);
    if (doc) {
        hit = json_find_moved(yyjson_doc_get_root(doc), &field, &owner);
        yyjson_doc_free(doc);
    }
    free(json);
    if (!hit) return 0;

#ifdef FX_ACCEPT_MOVED_ACCESS
    /* THE BLIND (the gate's mutation arm, never a deployment switch): the
     * refusal is compiled out, which is exactly the SILENT-IGNORE failure
     * direction — the config still reads as constrained while the schema simply
     * drops the field.  It says so out loud so the arm cannot mistake itself
     * for the real build. */
    fprintf(stderr,
            "config: MOVED-FIELD REFUSAL COMPILED OUT (FX_ACCEPT_MOVED_ACCESS) — "
            "config %s carries '%s' and the field is SILENTLY IGNORED; its owner "
            "is %s\n", path, field, owner);
    return 0;
#else
    if (err && errcap) {
        snprintf(err, errcap,
                 "config %s carries the MOVED access-control field '%s' — the "
                 "agent config can no longer EXPRESS access control (ACL split "
                 "S3), so accepting it would leave this config reading as "
                 "constrained while the agent behaved as unconstrained. That "
                 "field's owner is now %s: edit that host file, not this config.",
                 path, field, owner);
    }
    return 1;
#endif
}
