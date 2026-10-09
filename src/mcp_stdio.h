/* src/mcp_stdio.h — MCP stdio server + daemon RPC client (Slice 5).
 *
 * Port of vibe_runtime/mcp_server.py: a newline-delimited JSON-RPC 2.0 MCP
 * server ("vibe-agent") that Vibe spawns over stdio to drive the long-lived
 * runtime daemon through its agent_* tools.  This server NEVER touches the
 * runstore directly — every state mutation forwards to the daemon over its
 * Unix socket via mcp_client().
 *
 * Wire protocol (mirrors daemon.c): the client sends one JSON-lines request
 *   {"cmd":"start","args":{...}}\n
 * and reads one reply line back:
 *   {"ok":true,"result":{...}}\n   or   {"ok":false,"error":"..."}\n
 *
 * The MCP server side speaks the standard MCP stdio handshake:
 *   initialize (protocolVersion 2025-06-18) -> notifications/initialized ->
 *   tools/list -> tools/call, plus ping.  Each tools/call is a thin forward to
 *   mcp_client().  Scope validation is done locally via secrets_is_known_scope
 *   / secrets_validate_scope BEFORE forwarding (the daemon stays authoritative).
 *
 * Env knobs (read at call time so tests can set them):
 *   VIBE_RUNTIME_SOCKET    Unix socket path override (default ~/.local/share/
 *                          vibe-runtime/agent.sock, "~" expanded via HOME)
 *   VIBE_MAX_REQUEST_BYTES reply/request read cap in bytes (default 256 KB)
 */
#ifndef MCP_STDIO_H
#define MCP_STDIO_H

#include <stddef.h>

#define MCP_PROTOCOL_VERSION "2025-06-18"
#define MCP_SERVER_NAME      "vibe-agent"
#define MCP_SERVER_VERSION   "0.1.0"

#define MCP_RPC_TIMEOUT_S    30.0

/* ── RPC client ──────────────────────────────────────────────────────────── */

/* Send one RPC command to the daemon over its Unix socket and return the
 * reply as a malloc'd JSON string (the daemon's reply line verbatim).  On any
 * failure (socket/connect error, timeout, oversized/malformed reply) returns a
 * malloc'd {"ok":false,"error":"..."} string instead.  Returns NULL only on
 * out-of-memory (callers fall back to a static error text).  Caller frees the
 * returned string with free().
 *
 * args_json is a pre-built JSON object string (e.g. {"agent":"coder"}), or
 * NULL for "{}". */
char *mcp_client(const char *cmd, const char *args_json);

/* Test/embedding hook: replace the socket transport inside mcp_client.  Pass
 * NULL to restore the real socket client.  Mirrors the session.c tool_call
 * hook idiom.  The hook returns a malloc'd reply JSON string (or NULL, which
 * mcp_client turns into a generic error). */
typedef char *(*mcp_client_fn)(const char *cmd, const char *args_json);
void mcp_set_client_hook(mcp_client_fn fn);

/* Test/embedding hook: override the Unix socket path (used verbatim after "~"
 * expansion).  Pass NULL to reset to VIBE_RUNTIME_SOCKET / the default. */
void mcp_set_socket_path(const char *path);

/* ── MCP stdio server ────────────────────────────────────────────────────── */

/* Serve one MCP stdio session: read newline-delimited JSON-RPC 2.0 requests
 * from in_fd, write responses to out_fd, until EOF on in_fd.  Handles
 * initialize -> notifications/initialized -> tools/list -> tools/call (and
 * ping).  Returns 0 on clean EOF, -1 on a fatal write error. */
int mcp_stdio_serve(int in_fd, int out_fd);

/* Entry point for the vibe-agent binary: serve(stdin, stdout).  Returns the
 * process exit code. */
int mcp_stdio_main(void);

#endif /* MCP_STDIO_H */
