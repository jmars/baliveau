/* src/agent/config.h — runtime config loader.
 *
 * Loads the runtime's OWN config.dhall via the vendored dhall-c (in-process
 * eval, same machinery src/runner.c's validate_agent_profile uses) and exposes:
 *   - the agent list (name + agent_type),
 *   - per-agent model + default_max_turns,
 *   - per-agent MCP-server specs, mapped directly onto mcp_client.h's
 *     McpToolServer so S10/S11 can hand them straight to mcp_tools_list /
 *     mcp_tools_call.
 *
 * FAIL-OPEN: a missing, unreadable, malformed/unparseable config.dhall, or one
 * with an empty/absent agents list, yields an EMPTY RuntimeConfig and returns 0
 * — NEVER a crash, matching runner.c's fail-open semantic.  config_load returns
 * -1 only on a genuine hard error (OOM), with a message in `err`.
 *
 * Memory: every string exposed is a fresh malloc'd copy OWNED by the
 * RuntimeConfig and freed by config_free.  Borrowed pointers remain valid until
 * the matching config_free.
 */
#ifndef AGENT_CONFIG_H
#define AGENT_CONFIG_H

#include <stddef.h>

#include "mcp_client.h"   /* McpToolServer (the MCP spec type we map onto) */

#ifdef __cplusplus
extern "C" {
#endif

/* Hard cap on any single string field copied out of the config (name,
 * agent_type, model, command, scope, one mcp arg).  config-origin bytes are
 * never sprintf'd/strcpy'd — they are copied via length-checked helpers. */
#define CONFIG_FIELD_CAP 4096u

/* Max counts for new config sections. */
#define CONFIG_MAX_PROVIDERS   512u
#define CONFIG_MAX_MODELS      512u
#define CONFIG_MAX_TOOL_GLOBS  128u

/* One provider entry: name, API base URL, optional env var for API key, backend type. */
typedef struct ConfigProvider {
    char *name;              /* required */
    char *api_base;          /* required */
    char *api_key_env_var;   /* NULL if absent/None */
    char *backend;           /* required */
} ConfigProvider;

/* One model entry: name and optional provider name (maps to a ConfigProvider). */
typedef struct ConfigModel {
    char *name;              /* required */
    char *provider;         /* NULL if absent/None */
} ConfigModel;

/* One agent entry.  MCP specs are McpToolServer (owned deep copies of a
 * dhall { command, args, scope } record); scope is NULL when absent/None
 * (PATH-only child env), per mcp_client.h.
 *
 * DHALL NOTE (schema footgun): an UNANNOTATED empty list `args = []` fails
 * dhall-c's type inference, so the whole config fail-opens to empty.  Write an
 * arg-less MCP server as `args = [] : List Text` (type annotation), or simply
 * OMIT the `args` field — both parse to n_args == 0.  Only the nested `args`
 * field is affected; an agent-level `mcp_servers = []` parses fine.
 *
 * NEW FIELDS (providers/models/tool filtering): enabled_tools and disabled_tools
 * are Optional (List Text).  An UNANNOTATED empty list (enabled_tools = [] or
 * disabled_tools = []) fails dhall-c type inference -> whole config fail-opens.
 * Use `enabled_tools = [] : List Text` or OMIT the field entirely (parsed as
 * n_enabled_tools == 0).  ALL agents in the same list must have the SAME field
 * set (dhall record homogeneity) — adding enabled_tools to one agent requires
 * adding `enabled_tools = None (List Text)` to every other agent, or the list
 * fail-opens to empty. */
typedef struct ConfigAgent {
    char *name;                      /* required */
    char *agent_type;                /* NULL if absent */
    char *model;                     /* NULL if unset */
    unsigned long default_max_turns; /* 0 if unset */
    char *prompt_file;               /* NULL if unset; path to system prompt file */
    McpToolServer *mcp_servers;      /* n_mcp_servers of them; NULL if none */
    size_t n_mcp_servers;
    size_t cap_mcp_servers;
    char **enabled_tools;            /* n_enabled_tools strings; NULL if none */
    size_t n_enabled_tools;
    size_t cap_enabled_tools;
    char **disabled_tools;           /* n_disabled_tools strings; NULL if none */
    size_t n_disabled_tools;
    size_t cap_disabled_tools;
} ConfigAgent;

typedef struct RuntimeConfig {
    ConfigAgent *agents;
    size_t n_agents;
    size_t cap_agents;
    ConfigProvider *providers;      /* n_providers entries */
    size_t n_providers;
    size_t cap_providers;
    ConfigModel *models;            /* n_models entries */
    size_t n_models;
    size_t cap_models;
} RuntimeConfig;

/* Load config.dhall from FX_AGENT_CONFIG_DIR (default ~/.config/fx-agent).
 * Returns 0 on success — `out` is zeroed and is EMPTY (no agents) when the
 * config is missing / unparseable / has an empty or absent agents list.  Returns
 * -1 only on a hard error (OOM) and fills `err` (may be NULL/0).  On -1, `out`
 * is left emptied (config_free(out) is still safe). */
int config_load(RuntimeConfig *out, char *err, size_t errcap);

/* Free every string/array owned by cfg and zero it.  NULL-safe. */
void config_free(RuntimeConfig *cfg);

/* Find an agent by exact name; returns NULL if absent.  Borrowed pointer
 * (valid until config_free). */
const ConfigAgent *config_find_agent(const RuntimeConfig *cfg, const char *name);

/* Find a provider by exact name; returns NULL if absent.  Borrowed pointer
 * (valid until config_free). */
const ConfigProvider *config_find_provider(const RuntimeConfig *cfg, const char *name);

/* Find a model by exact name; returns NULL if absent.  Borrowed pointer
 * (valid until config_free). */
const ConfigModel *config_find_model(const RuntimeConfig *cfg, const char *name);

#ifdef __cplusplus
}
#endif

#endif /* AGENT_CONFIG_H */
