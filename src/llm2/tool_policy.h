/* src/llm2/tool_policy.h — LAYER-2 tool allowlist policy (Slice S6).
 *
 * Custom glob matcher supporting '*' only (everything else literal) and
 * ToolPolicy-based allowlist semantics: allowed = (n_enabled==0 || matches_any(enabled))
 * && !matches_any(disabled).  NULL policy -> allow-all.
 *
 * No backend/config coupling — hermetic and independently testable.
 * No glob(3)/fnmatch(3) — cosmocc ships no fnmatch.h.
 */
#ifndef TOOL_POLICY_H
#define TOOL_POLICY_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A tool allowlist/denylist policy.  enabled/disabled are arrays of glob
 * patterns (only '*' wildcard supported; all other chars literal).
 * NULL/0 for both -> allow-all.  disabled always wins over enabled. */
typedef struct {
    const char *const *enabled;   /* allowlist patterns (NULL/0 = no allowlist) */
    size_t n_enabled;
    const char *const *disabled;  /* denylist patterns (NULL/0 = none) */
    size_t n_disabled;
} ToolPolicy;

/* glob_match: returns 1 if `text` matches `pattern`, 0 otherwise.
 * Pattern syntax: '*' matches any sequence (including empty); all other
 * characters are literal.  Empty pattern matches only empty text.
 * Iterative two-pointer, constant stack, O(n*m) worst case. */
int glob_match(const char *pattern, const char *text);

/* tool_policy_allowed: returns 1 if `tool_name` is allowed by policy `p`, 0
 * otherwise.  Semantics:
 *   allowed = (n_enabled==0 || matches_any(enabled)) && !matches_any(disabled)
 * NULL policy or all-empty lists -> allow-all (1). */
int tool_policy_allowed(const ToolPolicy *p, const char *tool_name);

#ifdef __cplusplus
}
#endif

#endif /* TOOL_POLICY_H */
