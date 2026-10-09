#!/bin/sh
# tests/fixtures/kill_parent.sh — the lowest MCP tool server: it SIGKILLs the
# harness the moment it is spawned, which is exactly what an in-guest reboot
# does to a run that is mid-tool-dispatch.
#
# $PPID is the agent: mcp_client.c's proc_spawn fork+execvpe's this script
# directly (no intermediate shell), so the exec'd process's parent IS the
# harness.  It is spawned per tools/call, i.e. AFTER agent_loop.c:776 has
# notified the transcript callback of the assistant message carrying the call
# (flush) and BEFORE the dispatch at :783 returns — so the kill can only happen
# once the flush has run.
kill -9 "$PPID"
exit 1
