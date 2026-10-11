/* src/runner.h — SECURITY KEYSTONE: locked headless-agent argv builder.
 *
 * Builds the exact, immutable argv array for a headless agent invocation.
 * The `agent` and `session_id` parameters are validated against a safe
 * charset so they can NEVER inject flags or shell metacharacters into a
 * subprocess argv; the prompt is always a plain argv element; only
 * caller-approved flags are ever emitted. argv[0] is the resolved
 * agent-main path (env FX_AGENT_MAIN, default build/agent_main).
 *
 * Config decision: validate_agent_profile reads the RUNTIME'S OWN Dhall
 * config (env FX_AGENT_CONFIG_DIR, default ~/.config/fx-agent/, file
 * config.dhall), evaluated IN-PROCESS via the vendored dhall-c, and looks
 * up the {name, agent_type} agents list entry.
 */
#ifndef RUNNER_H
#define RUNNER_H

#include <stdbool.h>
#include <stddef.h>

#define RUNNER_MAX_TURNS_DEFAULT 1000

/* Error channel: functions return 0 on success, non-zero on failure and fill
 * *err (may be NULL to discard). */
typedef struct {
    char msg[1024];
} RunnerError;

#define RUNNER_ERROR(e, ...)                      \
    do {                                          \
        if (e) snprintf((e)->msg, sizeof((e)->msg), __VA_ARGS__); \
    } while (0)

/* A built command line: NULL-terminated argv array + argc (excluding the NULL
 * terminator). Call runner_cmd_free() when done. */
typedef struct {
    char **argv;
    int argc;
} RunnerCmd;

/* MAX_TURNS bound — read from env FX_MAX_TURNS at call time (default 1000). */
int runner_max_turns(void);

/* Validate an identifier against ^[A-Za-z0-9._-]+$ (non-empty, no leading '-'). */
int validate_identifier(const char *value, const char *field, RunnerError *err);

/* cwd must be an absolute, existing directory. */
int validate_cwd(const char *cwd, RunnerError *err);

/* cwd must resolve under FX_PROJECTS_ROOT (default ~/projects). */
int validate_cwd_confinement(const char *cwd, RunnerError *err);

/* Validate the agent against the runtime's OWN Dhall config. Rejects a
 * subagent-type profile or a missing profile. FAIL-OPEN (accept) when the
 * config is missing/malformed/unparseable — never false-reject. */
int validate_agent_profile(const char *agent, RunnerError *err);

/* Build the locked argv:
 *   <agent_main> -p <prompt> --agent <agent> --max-turns N
 *        [--resume <session_id>] [--workdir <cwd>] --output <output>
 *        [--auto-approve]
 * session_id/cwd are only emitted when non-NULL and non-empty. output defaults
 * to "text". argv[0] is the resolved agent-main path (env FX_AGENT_MAIN,
 * default build/agent_main). Returns 0 on success and fills *out
 * (caller frees via runner_cmd_free); non-zero on validation failure. */
int build_agent_cmd(const char *agent, const char *prompt,
                   const char *session_id, int max_turns,
                   const char *cwd, const char *output, bool auto_approve,
                   RunnerError *err, RunnerCmd *out);

/* Resolve the agent-main binary path: env FX_AGENT_MAIN, default
 * build/agent_main; a missing native binary fails loudly at exec. */
void runner_agent_main_path(char *out, size_t cap);

void runner_cmd_free(RunnerCmd *cmd);

#endif /* RUNNER_H */
