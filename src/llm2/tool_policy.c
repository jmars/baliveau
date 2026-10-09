/* src/llm2/tool_policy.c — LAYER-2 tool allowlist policy (Slice S6).
 *
 * Custom glob matcher supporting '*' only (everything else literal) and
 * ToolPolicy-based allowlist semantics.
 *
 * No backend/config coupling — hermetic and independently testable.
 * No glob(3)/fnmatch(3) — cosmocc ships no fnmatch.h.
 */

#include "tool_policy.h"

#include <string.h>

/* ------------------------------------------------------------------ */
/* glob_match: iterative two-pointer matcher for '*'-only patterns. */
/* ------------------------------------------------------------------ */

/* Returns 1 if `text` matches `pattern`, 0 otherwise.
 * Pattern syntax: '*' matches any sequence (including empty); all other
 * characters are literal.  Empty pattern matches only empty text.
 *
 * Algorithm: two-pointer with backtracking for '*' wildcards.
 * - When we see a '*' in pattern, remember its position and the current text
 *   position, then try matching 0 characters (advance pattern past '*').
 * - If the rest of pattern doesn't match, backtrack: advance text by 1 and
 *   retry from the position after '*'.
 * - This is O(n*m) worst case but constant stack (safe on 64 KiB tool names).
 */
int glob_match(const char *pattern, const char *text) {
    if (pattern == NULL || text == NULL) return 0;

    const char *p = pattern;
    const char *t = text;
    const char *star_p = NULL;  /* position of last '*' in pattern */
    const char *star_t = NULL;  /* position in text when we started after '*' */

    while (*t != '\0') {
        if (*p == '*') {
            /* Record the '*' position and current text position. */
            star_p = p;
            star_t = t;
            p++;  /* consume the '*' */
        } else if (*p != '\0' && *p == *t) {
            /* Literal match. */
            p++;
            t++;
        } else if (star_p != NULL) {
            /* Mismatch: backtrack to the last '*' and try consuming
             * one more character with it. */
            p = star_p + 1;
            star_t++;
            t = star_t;
        } else {
            /* No wildcard to backtrack to. */
            return 0;
        }
    }

    /* Text is exhausted.  Skip any remaining '*' in pattern. */
    while (*p == '*') {
        p++;
    }

    /* Pattern must also be exhausted for a match. */
    return *p == '\0';
}

/* ------------------------------------------------------------------ */
/* tool_policy_allowed */
/* ------------------------------------------------------------------ */

/* Helper: check if any pattern in `patterns` (count = `n`) matches `text`. */
static int matches_any(const char *const *patterns, size_t n, const char *text) {
    if (patterns == NULL || n == 0) return 0;
    for (size_t i = 0; i < n; i++) {
        if (glob_match(patterns[i], text)) return 1;
    }
    return 0;
}

/* Returns 1 if `tool_name` is allowed by policy `p`, 0 otherwise.
 * Semantics:
 *   allowed = (n_enabled==0 || matches_any(enabled)) && !matches_any(disabled)
 * NULL policy or all-empty lists -> allow-all (1). */
int tool_policy_allowed(const ToolPolicy *p, const char *tool_name) {
    if (p == NULL) return 1;  /* NULL policy = allow-all */
    if (tool_name == NULL) return 0;  /* NULL tool name = deny (safe default) */

    /* Check disabled list first: if any disabled pattern matches, deny. */
    if (matches_any(p->disabled, p->n_disabled, tool_name)) return 0;

    /* If no enabled list (n_enabled == 0), allow. */
    if (p->n_enabled == 0) return 1;

    /* Otherwise, must match at least one enabled pattern. */
    return matches_any(p->enabled, p->n_enabled, tool_name);
}
