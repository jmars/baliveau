/* src/agent/dhall_eval_lock.c — the ONLY definition of g_dhall_eval_lock.
 *
 * Serializes ALL in-process dhall-c evaluation (the arena + normalize-error
 * globals are process-global and NOT thread-safe).  runner.c and config.c
 * share this single lock via dhall_eval_lock.h.
 *
 * File-scope (static-storage) variables are zero-initialized at load time,
 * which for a pthread_mutex_t is exactly what PTHREAD_MUTEX_INITIALIZER
 * yields — so the lock is ready before main() and needs no pthread_once.  We
 * deliberately omit the literal macro here: cosmocc's -Wall -Wextra trips
 * -Wmissing-field-initializers on PTHREAD_MUTEX_INITIALIZER (it initializes
 * only the leading fields, leaving the trailing _futex field unset), and a
 * plain zero-initialized global carries the same semantics warning-free.
 */
#include "dhall_eval_lock.h"

pthread_mutex_t g_dhall_eval_lock;
