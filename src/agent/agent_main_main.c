/* src/agent/agent_main_main.c — thin entry point for the native agent binary.
 *
 * the real work lives in src/agent/agent_main.c (agent_main_entry).
 * This is a thin shim so the binary's `main()` is just `agent_main_entry()`,
 * mirroring the src/mcp_main.c / src/mcp_stdio.c split: kept separate from
 * agent_main.c so the hermetic test links agent_main.c with its OWN main(). */
#include "agent_main.h"

int main(int argc, char **argv) {
    return agent_main_entry(argc, argv);
}
