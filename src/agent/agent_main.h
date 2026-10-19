/* src/agent/agent_main.h — the agent entrypoint (see agent_main.c).
 *
 * Runs the agent loop in-process instead of building a subprocess argv.
 * Exposes agent_main_entry (NO main()) so the hermetic test links
 * agent_main.c with its own main(); src/agent/agent_main_main.c provides the
 * binary's main().
 */
#ifndef AGENT_MAIN_H
#define AGENT_MAIN_H

#ifdef __cplusplus
extern "C" {
#endif

/* Parse the LOCKED runner.c flag set and run the native agent loop
 * in-process.  Returns the process exit code: 0 on success, non-zero on any
 * validation / config / backend / OOM error (never crashes). */
int agent_main_entry(int argc, char **argv);

#ifdef __cplusplus
}
#endif

#endif /* AGENT_MAIN_H */
