/* src/agent/dhall_eval_lock.h — process-wide lock serializing ALL dhall-c eval.
 *
 * dhall-c operates on a single process-global arena (dhall_arena) plus
 * normalize-error globals that are NOT thread-safe (the daemon is
 * thread-per-conn).  runner.c and config.c BOTH evaluate dhall in-process and
 * MUST share this ONE lock — a separate mutex per TU would let two threads
 * touch the same arena concurrently and corrupt the heap.  This header
 * declares the shared lock; the sole definition lives in dhall_eval_lock.c.
 */
#ifndef AGENT_DHALL_EVAL_LOCK_H
#define AGENT_DHALL_EVAL_LOCK_H

#include <pthread.h>

extern pthread_mutex_t g_dhall_eval_lock;

#endif /* AGENT_DHALL_EVAL_LOCK_H */
