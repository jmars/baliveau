/* src/agent/agent_main.h — the agent entrypoint (see agent_main.c).
 *
 * Runs the agent loop in-process instead of building a subprocess argv.
 * Exposes agent_main_entry (NO main()) so the hermetic test links
 * agent_main.c with its own main(); src/agent/agent_main_main.c provides the
 * binary's main().
 */
#ifndef AGENT_MAIN_H
#define AGENT_MAIN_H

#include "config.h"        /* RuntimeConfig / ConfigAgent for resolve_backend */
#include "llm_backend.h"   /* Backend */

#ifdef __cplusplus
extern "C" {
#endif

/* Parse the LOCKED runner.c flag set and run the native agent loop
 * in-process.  Returns the process exit code: 0 on success, non-zero on any
 * validation / config / backend / OOM error (never crashes). */
int agent_main_entry(int argc, char **argv);

/* Resolve the backend for an agent from the runtime config (provider routing).
 *   model_entry = ag->model ? config_find_model(cfg, ag->model) : NULL
 *   provider    = (model_entry && model_entry->provider)
 *                    ? config_find_provider(cfg, model_entry->provider) : NULL
 *   backend     = backend_build(provider->backend, provider->api_base,
 *                               provider->api_key_env_var)
 * FAIL-OPEN: an unknown/missing provider (or an unknown backend type) falls
 * back to the default openai_responses_backend() (the local router) — never an
 * error.  An existing agent.model with no models entry routes exactly as before
 * (default router).  The caller owns `out` (stack); the returned pointer is
 * `out` on a successful build, else the process-lifetime default accessor. */
const Backend *agent_main_resolve_backend(const RuntimeConfig *cfg,
                                          const ConfigAgent *ag, Backend *out);

#ifdef __cplusplus
}
#endif

#endif /* AGENT_MAIN_H */
