/* src/agent/config.h — runtime config loader.
 *
 * Loads the runtime's OWN config.dhall via the vendored dhall-c (in-process
 * eval, same machinery src/runner.c's validate_agent_profile uses) and exposes
 * the agent config's INTENT:
 *   - the agent list (name + agent_type),
 *   - per-agent model + default_max_turns + prompt_file,
 *   - per-agent MCP-server specs, mapped directly onto mcp_client.h's
 *     McpToolServer so S10/S11 can hand them straight to mcp_tools_list /
 *     mcp_tools_call.
 *
 * ACCESS CONTROL IS NOT IN THIS SCHEMA AND CANNOT BE (ACL split, slice S3).
 * The fields that used to let this file constrain the agent — enabled_tools,
 * disabled_tools, the providers[] block and models[].provider — are GONE from
 * the schema, because the agent must not be able to EXPRESS its own bounds:
 *   - the verb VOCABULARY belongs to the operator's pinned access table,
 *     policy/access/access-verbs.tsv, and is enforced at the HOST seat
 *     (tools/fx-hostgate.c, the access author in call_judge);
 *   - the provider ENDPOINT and the CREDENTIAL belong to the host proxy
 *     (FX_HOSTGATE_KEY); the guest has no network at all (CONFIG_NET unset),
 *     so a guest-side provider block was a dead field whose api_key_env_var
 *     was merely a NAME to grep the host for.
 * A config that still CARRIES one of them is REFUSED, by name, by
 * config_check_moved() below — never silently ignored (see that declaration).
 *
 * FAIL-OPEN: a missing, unreadable, malformed/unparseable config.dhall, or one
 * with an empty/absent agents list, yields an EMPTY RuntimeConfig and returns 0
 * — NEVER a crash, matching runner.c's fail-open semantic.  config_load returns
 * -1 only on a genuine hard error (OOM), with a message in `err`.
 *
 * The MOVED-FIELD check is NOT part of that fail-open contract and must never
 * be folded into it: it is FAIL-CLOSED and lives BESIDE config_load, called
 * first by agent_main.  A refusal buried inside a fail-open path is a refusal
 * that can be skipped by exactly the inputs it exists for.
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
 * ALL agents in the same list must have the SAME field set (dhall record
 * homogeneity), or the list fail-opens to empty.
 */
typedef struct ConfigAgent {
    char *name;                      /* required */
    char *agent_type;                /* NULL if absent */
    char *model;                     /* NULL if unset; an ENGINE name, not a
                                      * provider join (models[].provider is a
                                      * MOVED field) */
    unsigned long default_max_turns; /* 0 if unset */
    char *prompt_file;               /* NULL if unset; path to system prompt file */
    McpToolServer *mcp_servers;      /* n_mcp_servers of them; NULL if none */
    size_t n_mcp_servers;
    size_t cap_mcp_servers;
} ConfigAgent;

typedef struct RuntimeConfig {
    ConfigAgent *agents;
    size_t n_agents;
    size_t cap_agents;
} RuntimeConfig;

/* Load config.dhall from FX_AGENT_CONFIG_DIR (default ~/.config/fx-agent).
 * Returns 0 on success — `out` is zeroed and is EMPTY (no agents) when the
 * config is missing / unparseable / has an empty or absent agents list.  Returns
 * -1 only on a hard error (OOM) and fills `err` (may be NULL/0).  On -1, `out`
 * is left emptied (config_free(out) is still safe). */
int config_load(RuntimeConfig *out, char *err, size_t errcap);

/* THE MOVED-FIELD MIGRATION PASS — FAIL-CLOSED, and deliberately a SEPARATE
 * call from config_load (agent_main calls it FIRST, before anything else that
 * can return early).  Refuses a config that still carries an access-control
 * field the schema no longer has: enabled_tools, disabled_tools, providers[],
 * models[], api_key_env_var, models[].provider.
 *
 * Returns 0 when the config carries no such field; non-zero when it does, with
 * `err` naming the field AND the host file that now owns it.
 *
 * WHY IT EXISTS: silence is the failure direction.  Because the schema can no
 * longer HOLD such a field, a config that still declares one would be silently
 * ignored — it would still READ as constrained while the agent BEHAVED as
 * unconstrained, and nothing at rest would record the difference.  A refusal is
 * the only direction that cannot be silent.
 *
 * WHAT IT INSPECTS: the config's VALUE (the evaluated JSON), so a field carried
 * by an import or a used `let` is caught as surely as a literal record.  Two
 * residuals, stated rather than papered over: a moved name appearing only in a
 * COMMENT or in a `let` the config never uses is not in the value (and cannot
 * constrain anything); and a config that does not evaluate at all is not
 * refused HERE — it already fails loudly downstream, as an empty agents list is
 * "agent not found" (exit 1), so that direction has no silent path.
 *
 * THE BLIND: built with -DFX_ACCEPT_MOVED_ACCESS the refusal is COMPILED OUT
 * and the field is accepted-and-ignored (with a stderr line saying so).  It is
 * the gate's mutation arm, not a deployment switch. */
int config_check_moved(char *err, size_t errcap);

/* Free every string/array owned by cfg and zero it.  NULL-safe. */
void config_free(RuntimeConfig *cfg);

/* Find an agent by exact name; returns NULL if absent.  Borrowed pointer
 * (valid until config_free). */
const ConfigAgent *config_find_agent(const RuntimeConfig *cfg, const char *name);

#ifdef __cplusplus
}
#endif

#endif /* AGENT_CONFIG_H */
