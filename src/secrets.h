/* src/secrets.h — scoped secret injection (scrub-and-inject) — SECURITY CRITICAL.
 *
 * Port of vibe_runtime/secrets.py (Slice 4 fold-in, per the Slice-4 plan's
 * GAP-3 decision).  The daemon must NEVER let a detached `vibe` child inherit
 * the orchestrator/daemon process environment.  Instead it builds the child
 * env from a small explicit whitelist base plus ONLY the keys the run's
 * ``secrets_scope`` (minimal | default | full) is allowed to see.
 *
 * This is scrub-and-inject, not inherit-and-strip: the child env is
 * constructed allowlist-positive, so a secret added to the daemon's own env
 * later is structurally unable to leak into a detached child.  build_child_env
 * never reads ``environ`` for secret content — the base whitelist only
 * carries PATH/HOME (re-derived, never wholesale-copied) and a handful of
 * locale/terminal vars that are safe to forward.
 *
 * Store layout (~/.vibe/secrets.toml, override VIBE_SECRETS_FILE):
 *
 *     [secrets]
 *     SOME_API_KEY = "value"       # env var name == secret name
 *
 *     [scopes]
 *     minimal = []                 # no secrets
 *     default = ["SOME_API_KEY"]
 *     full    = ["SOME_API_KEY", "OTHER_TOKEN"]
 *
 * An ABSENT or malformed file yields an empty store (no crash); the daemon
 * then still injects the whitelist base for `minimal` (no secrets), so a
 * missing file degrades to the most-constrained scope, never to full
 * inheritance.
 *
 * Parsing is via the vendored tomlc99 (src/vendor/tomlc99/) — never hand-rolled.
 */
#ifndef SECRETS_H
#define SECRETS_H

#include <stddef.h>

#define SECRETS_SCOPE_MINIMAL "minimal"
#define SECRETS_SCOPE_DEFAULT "default"
#define SECRETS_SCOPE_FULL    "full"

/* 0/1: is `scope` one of minimal|default|full? */
int secrets_is_known_scope(const char *scope);

/* Validate scope; return 0 on success, -1 + err on unknown scope.  Never
 * touches the secrets file. */
int secrets_validate_scope(const char *scope, char *err, size_t errcap);

/* Build the child env (scrub-and-inject).  Returns a freshly malloc'd,
 * NUL-terminated array of freshly malloc'd "KEY=VALUE" strings (caller frees
 * via secrets_envp_free).  On an unknown scope, returns NULL and fills err.
 *
 * The store is loaded fresh from VIBE_SECRETS_FILE (default ~/.vibe/secrets.toml).
 * An absent or malformed file yields an empty store (most-constrained).  The
 * whitelist base (PATH/HOME re-derived + LANG/LC_ALL/TZ/TERM/XDG_RUNTIME_DIR
 * forwarded only when present) is always injected; only the scope's secret
 * keys are layered on top.  Nothing else from ``environ`` is ever copied. */
char **secrets_build_child_env(const char *scope, char *err, size_t errcap);

/* Free an envp returned by secrets_build_child_env (NULL safe). */
void secrets_envp_free(char **envp);

/* ── Test/embedding hooks ───────────────────────────────────────────────────
 * The default secrets file is VIBE_SECRETS_FILE or ~/.vibe/secrets.toml, read
 * fresh on every build_child_env call.  Tests that want hermetic, in-memory
 * stores set VIBE_SECRETS_FILE to a tmp file they wrote. */

/* Pure loader exposed for direct testing (port of secrets.load_secrets_store):
 * writes the parsed secrets/scopes into out_ arrays (caller frees).  Returns
 * 0 always (absent/malformed => empty store, never crash).
 *
 * On return:
 *   *out_secrets_keys / *out_secrets_vals are parallel malloc'd arrays of
 *   n_secrets entries (NULL/0 when empty); each value is a malloc'd string.
 *   *out_scope_keys / *out_scope_vals are parallel arrays of n_scopes entries;
 *   each scope value is itself a malloc'd, NULL-terminated array of malloc'd
 *   secret-name strings. */
int secrets_load_store(const char *path,
                       char ***out_secrets_keys, char ***out_secrets_vals, size_t *out_n_secrets,
                       char ***out_scope_keys, char ****out_scope_vals, size_t *out_n_scopes);

void secrets_store_free(char **secrets_keys, char **secrets_vals, size_t n_secrets,
                        char **scope_keys, char ***scope_vals, size_t n_scopes);

#endif /* SECRETS_H */
