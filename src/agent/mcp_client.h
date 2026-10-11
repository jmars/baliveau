/* src/agent/mcp_client.h — MCP stdio CLIENT for arbitrary tool servers (S5).
 *
 * Generalizes session.c's session_jing_memory_tool_call (which is hardwired to
 * the jing-memory graph server) into a general MCP stdio client: spawn an
 * arbitrary MCP tool server binary, speak the standard MCP stdio handshake
 * (initialize -> notifications/initialized -> tools/list -> tools/call) over
 * newline-delimited JSON-RPC 2.0, and round-trip a tool invocation.
 *
 * Wire protocol (the reference is mcp_stdio.h / mcp_stdio.c and session.c):
 *   client->server: initialize -> notifications/initialized -> tools/list /
 *                   tools/call  (numeric ids)
 *   server->client: responses (id-matched) possibly interleaved with
 *                   notifications (skipped, like session.c's read_response).
 *
 * SECURITY: the child gets ONLY its secrets-scope env (secrets_build_child_env)
 * or, when scope is NULL, a minimal PATH-only envp — never the daemon's full
 * environment (defense-in-depth against secret leakage, exactly like session.c).
 * tool_name MUST pass validate_identifier (runner.h) before it enters a
 * JSON-RPC frame. args_json is attacker-shaped (prompt-injection) but it is
 * already JSON, so it is passed verbatim as an opaque JSON value with a
 * length cap (MCP_ARGS_CAP) — never interpreted, never interpolated.
 *
 * ENTRYPOINT REQUIREMENT: mcp_client writes to a child process pipe.  If the
 * child exits before/during a write, a plain write() raises SIGPIPE, which
 * kills the process by default.  The embedding program (the test, or the S11
 * agent_main) MUST call signal(SIGPIPE, SIG_IGN) at startup, or a crashed/early-
 * exiting tool server will terminate the agent.
 */
#ifndef MCP_CLIENT_H
#define MCP_CLIENT_H

#include <stddef.h>

/* Cap on the tools/call arguments JSON length (64 KiB). args_json longer than
 * this is rejected up front. */
#define MCP_ARGS_CAP (64u * 1024u)

/* Cap on a single read line (1 MiB); an oversize line aborts the exchange. */
#define MCP_MAX_LINE (1024u * 1024u)

/* Per-read timeout in seconds (default; overridable via FX_MCP_TIMEOUT_S). */
#define MCP_CLIENT_RPC_TIMEOUT_S 10.0

/* One advertised tool (from a tools/list reply). name/description are owned by
 * the returned McpTool array and freed via mcp_tools_free. */
typedef struct {
    const char *name;
    const char *description; /* may be "" when the server omitted it */
} McpTool;

/* An MCP tool server spec: spawn `command` with `args` (n_args of them) as a
 * stdio subprocess. `scope` is the secrets scope for the child env, or NULL to
 * use a minimal PATH-only envp. `name` is an optional server name. `env` is an
 * optional array of "K=V" strings injected into the child env (overriding any
 * same-key entries from the base env). `startup_timeout_s` is the timeout for
 * the handshake (0 -> fall back to mcp_timeout_s()). `tool_timeout_s` is the
 * timeout for RPC reads (0 -> fall back to mcp_timeout_s()). All strings are
 * borrowed from the caller and must outlive the call. */
typedef struct {
    const char *command;
    char **args;
    size_t n_args;
    const char *scope; /* may be NULL -> PATH-only child env */
    const char *name;  /* optional server name, may be NULL */
    char **env;        /* owned array of "K=V" strings; NULL if none */
    size_t n_env;      /* number of env entries */
    double startup_timeout_s;  /* 0 -> fall back to mcp_timeout_s() */
    double tool_timeout_s;     /* 0 -> fall back to mcp_timeout_s() */
} McpToolServer;

/* Run one MCP tools/call against a FRESH stdio subprocess of srv:
 * spawn -> initialize -> notifications/initialized -> tools/call. On success
 * returns 0 and sets *out_result_text to a freshly malloc'd string containing
 * the joined text content blocks of the tool result (caller frees). On any
 * failure (invalid tool_name, spawn error, handshake error, timeout, tool
 * error) returns -1 and leaves *out_result_text untouched (NULL-safe: never
 * dereferences a NULL out pointer). tool_name is validated with
 * validate_identifier BEFORE the subprocess is spawned. */
int mcp_tools_call(const McpToolServer *srv, const char *tool_name,
                   const char *args_json, char **out_result_text);

/* Enumerate the tools advertised by srv: spawn -> initialize ->
 * notifications/initialized -> tools/list. On success returns 0 and sets
 * *out_tools to a freshly malloc'd array of n McpTool entries (name/description
 * each malloc'd; caller frees via mcp_tools_free) and *out_n. On failure
 * returns -1 and leaves *out_tools and *out_n untouched. */
int mcp_tools_list(const McpToolServer *srv, McpTool **out_tools, size_t *out_n);

/* Free an array returned by mcp_tools_list (NULL safe; n ignored when
 * tools is NULL). */
void mcp_tools_free(McpTool *tools, size_t n);

#endif /* MCP_CLIENT_H */
