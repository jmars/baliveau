/* src/secrets.c — scoped secret injection (scrub-and-inject) — SECURITY CRITICAL.
 *
 * See src/secrets.h for the design rationale.  Faithful port of
 * vibe_runtime/secrets.py.  TOML parsing is via the vendored tomlc99
 * (src/vendor/tomlc99/) — never hand-rolled.
 */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

#include "secrets.h"
#include "vendor/tomlc99/toml.h"

/* ── Small helpers ──────────────────────────────────────────────────────── */

static char *xstrdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

/* Grow a malloc'd array of pointers (NULL-terminated) by appending `item`. */
static int ptrarr_append(void *arrp, size_t *n, void *item) {
    void ***parr = (void ***)arrp;
    void **na = realloc(*parr, sizeof(void *) * (*n + 2));
    if (!na) return -1;
    *parr = na;
    (*parr)[*n] = item;
    (*n)++;
    (*parr)[*n] = NULL;
    return 0;
}

static void ptrarr_free(void **arr, size_t n, void (*free_item)(void *)) {
    if (!arr) return;
    for (size_t i = 0; i < n; i++) {
        if (free_item) free_item(arr[i]);
        else free(arr[i]);
    }
    free(arr);
}

/* ── Scope validation ───────────────────────────────────────────────────── */

int secrets_is_known_scope(const char *scope) {
    if (!scope) return 0;
    return strcmp(scope, SECRETS_SCOPE_MINIMAL) == 0 ||
           strcmp(scope, SECRETS_SCOPE_DEFAULT) == 0 ||
           strcmp(scope, SECRETS_SCOPE_FULL) == 0;
}

int secrets_validate_scope(const char *scope, char *err, size_t errcap) {
    if (secrets_is_known_scope(scope)) return 0;
    if (err && errcap > 0) {
        snprintf(err, errcap,
                 "invalid secrets_scope '%.200s': expected one of [minimal, default, full]",
                 scope ? scope : "");
    }
    return -1;
}

/* ── Default secrets file resolution ─────────────────────────────────────── */

static void secrets_file_path(char *out, size_t cap) {
    const char *env = getenv("VIBE_SECRETS_FILE");
    if (env && *env) { snprintf(out, cap, "%s", env); return; }
    const char *home = getenv("HOME");
    if (home && *home) snprintf(out, cap, "%s/.vibe/secrets.toml", home);
    else snprintf(out, cap, ".vibe/secrets.toml");
}

/* ── Store loader (port of load_secrets_store) ──────────────────────────── */

int secrets_load_store(const char *path,
                       char ***out_secrets_keys, char ***out_secrets_vals, size_t *out_n_secrets,
                       char ***out_scope_keys, char ****out_scope_vals, size_t *out_n_scopes) {
    if (out_secrets_keys) *out_secrets_keys = NULL;
    if (out_secrets_vals) *out_secrets_vals = NULL;
    if (out_n_secrets) *out_n_secrets = 0;
    if (out_scope_keys) *out_scope_keys = NULL;
    if (out_scope_vals) *out_scope_vals = NULL;
    if (out_n_scopes) *out_n_scopes = 0;

    char pathbuf[PATH_MAX];
    if (!path || !*path) {
        secrets_file_path(pathbuf, sizeof(pathbuf));
        path = pathbuf;
    }

    FILE *fp = fopen(path, "rb");
    if (!fp) return 0;  /* absent => empty store */

    char errbuf[256] = {0};
    toml_table_t *root = toml_parse_file(fp, errbuf, sizeof(errbuf));
    fclose(fp);
    if (!root) return 0;  /* malformed => empty store */

    /* [secrets] table: key/value strings.  Non-string values are str()-coerced
     * to match Python's `str(v)` — but tomlc99 gives us typed accessors; we
     * accept only strings (the documented store layout) and silently skip
     * non-string entries (most-constrained). */
    toml_table_t *secrets_t = toml_table_in(root, "secrets");
    toml_table_t *scopes_t  = toml_table_in(root, "scopes");
    if (!secrets_t && !scopes_t) { toml_free(root); return 0; }

    char **sec_keys = NULL, **sec_vals = NULL; size_t nsec = 0;
    char **sc_keys = NULL; char ***sc_vals = NULL; size_t nsc = 0;

    if (secrets_t) {
        int nk = toml_table_nkval(secrets_t);
        /* Pre-allocate parallel arrays sized to the kval count (we may write
         * fewer — non-string/non-int/non-bool entries are skipped). */
        sec_keys = calloc((size_t)nk + 1, sizeof(char *));
        sec_vals = calloc((size_t)nk + 1, sizeof(char *));
        if (!sec_keys || !sec_vals) { free(sec_keys); free(sec_vals); sec_keys = sec_vals = NULL; goto oom; }
        for (int i = 0; i < nk; i++) {
            const char *k = toml_key_in(secrets_t, i);
            if (!k) continue;
            /* String secrets (the documented layout). */
            toml_datum_t dv = toml_string_in(secrets_t, k);
            char *val_str = NULL;
            if (dv.ok) {
                val_str = dv.u.s;  /* takes ownership (caller frees) */
            } else {
                /* Non-string: coerce int/bool to a decimal string (mirrors
                 * Python's `str(v)` for unusual but not-malformed entries). */
                toml_datum_t iv = toml_int_in(secrets_t, k);
                if (iv.ok) {
                    char buf[32]; snprintf(buf, sizeof(buf), "%lld", (long long)iv.u.i);
                    val_str = xstrdup(buf);
                } else {
                    toml_datum_t bv = toml_bool_in(secrets_t, k);
                    if (bv.ok) val_str = xstrdup(bv.u.b ? "True" : "False");
                }
            }
            if (!val_str) continue;  /* non-scalar or OOM: skip (most-constrained) */
            sec_keys[nsec] = xstrdup(k);
            if (!sec_keys[nsec]) { free(val_str); continue; }
            sec_vals[nsec] = val_str;
            nsec++;
        }
        sec_keys[nsec] = NULL;
        sec_vals[nsec] = NULL;
    }

    if (scopes_t) {
        /* tomlc99 keeps a single key index spanning kvals + arrays + subtables;
         * toml_key_in(tab, idx) returns the key at that combined index.  We
         * probe each key with toml_array_in and keep only array-valued scopes
         * (the documented layout).  Non-array scope values are silently
         * dropped (mirrors Python's `v if isinstance(v, list) else []`). */
        int total = toml_table_nkval(scopes_t) + toml_table_narr(scopes_t) + toml_table_ntab(scopes_t);
        /* Pre-count array-valued scopes to size the parallel arrays. */
        int n_arr = 0;
        for (int i = 0; i < total; i++) {
            const char *k = toml_key_in(scopes_t, i);
            if (!k) continue;
            if (toml_array_in(scopes_t, k)) n_arr++;
        }
        sc_keys = calloc((size_t)n_arr + 1, sizeof(char *));
        sc_vals = calloc((size_t)n_arr + 1, sizeof(char **));
        if (!sc_keys || !sc_vals) { free(sc_keys); free(sc_vals); sc_keys = NULL; sc_vals = NULL; goto oom; }
        for (int i = 0; i < total; i++) {
            const char *k = toml_key_in(scopes_t, i);
            if (!k) continue;
            toml_array_t *a = toml_array_in(scopes_t, k);
            if (!a) continue;
            /* Collect string elements (skip non-strings — most-constrained). */
            int nelem = toml_array_nelem(a);
            char **names = calloc((size_t)nelem + 1, sizeof(char *));
            if (!names) continue;
            size_t nn = 0;
            for (int j = 0; j < nelem; j++) {
                toml_datum_t sv = toml_string_at(a, j);
                if (sv.ok) { names[nn++] = sv.u.s; continue; }
                toml_datum_t iv = toml_int_at(a, j);
                if (iv.ok) {
                    char buf[32]; snprintf(buf, sizeof(buf), "%lld", (long long)iv.u.i);
                    char *s = xstrdup(buf);
                    if (s) names[nn++] = s;
                }
                /* non-string non-int: skip */
            }
            names[nn] = NULL;
            sc_keys[nsc] = xstrdup(k);
            if (!sc_keys[nsc]) { for (size_t x = 0; x < nn; x++) free(names[x]); free(names); continue; }
            sc_vals[nsc] = names;
            nsc++;
        }
        sc_keys[nsc] = NULL;
        sc_vals[nsc] = NULL;
    }

    toml_free(root);
    if (out_secrets_keys) *out_secrets_keys = sec_keys; else ptrarr_free((void**)sec_keys, nsec, NULL);
    if (out_secrets_vals) *out_secrets_vals = sec_vals; else ptrarr_free((void**)sec_vals, nsec, NULL);
    if (out_n_secrets) *out_n_secrets = nsec;
    if (out_scope_keys) *out_scope_keys = sc_keys; else { for (size_t i=0;i<nsc;i++) free(sc_keys[i]); free(sc_keys); }
    if (out_scope_vals) *out_scope_vals = sc_vals; else { for (size_t i=0;i<nsc;i++) ptrarr_free((void**)sc_vals[i], 0, NULL); free(sc_vals); }
    if (out_n_scopes) *out_n_scopes = nsc;
    return 0;

oom:
    toml_free(root);
    ptrarr_free((void**)sec_keys, nsec, NULL);
    ptrarr_free((void**)sec_vals, nsec, NULL);
    for (size_t i = 0; i < nsc; i++) { free(sc_keys[i]); ptrarr_free((void**)sc_vals[i], 0, NULL); }
    free(sc_keys); free(sc_vals);
    return 0;
}

void secrets_store_free(char **secrets_keys, char **secrets_vals, size_t n_secrets,
                        char **scope_keys, char ***scope_vals, size_t n_scopes) {
    ptrarr_free((void**)secrets_keys, n_secrets, NULL);
    ptrarr_free((void**)secrets_vals, n_secrets, NULL);
    for (size_t i = 0; i < n_scopes; i++) {
        if (scope_keys) free(scope_keys[i]);
        if (scope_vals) ptrarr_free((void**)scope_vals[i], 0, NULL);
    }
    free(scope_keys);
    free(scope_vals);
}

/* ── Whitelist base (port of _base_env) ──────────────────────────────────── */

/* Append "KEY=VALUE" to envp (a NULL-terminated, malloc-grow array). */
static int envp_append(char ***envp, size_t *n, const char *key, const char *val) {
    size_t klen = strlen(key), vlen = val ? strlen(val) : 0;
    char *entry = malloc(klen + 1 + vlen + 1);
    if (!entry) return -1;
    memcpy(entry, key, klen);
    entry[klen] = '=';
    if (val && vlen) memcpy(entry + klen + 1, val, vlen);
    entry[klen + 1 + vlen] = '\0';
    if (ptrarr_append(envp, n, entry) != 0) { free(entry); return -1; }
    return 0;
}

static int envp_forward_env(char ***envp, size_t *n, const char *key) {
    const char *v = getenv(key);
    if (!v || !*v) return 0;
    return envp_append(envp, n, key, v);
}

/* Re-derive HOME: prefer $HOME, else fall back to a best-effort "/" — the
 * child gets SOMETHING (the daemon never inherits via this path). */
static void derive_home(char *out, size_t cap) {
    const char *h = getenv("HOME");
    if (h && *h) { snprintf(out, cap, "%s", h); return; }
    snprintf(out, cap, "/");
}

static void derive_path(char *out, size_t cap) {
    const char *p = getenv("PATH");
    if (p && *p) { snprintf(out, cap, "%s", p); return; }
    snprintf(out, cap, "/usr/local/bin:/usr/bin:/bin");
}

/* ── build_child_env (scrub-and-inject) ──────────────────────────────────── */

char **secrets_build_child_env(const char *scope, char *err, size_t errcap) {
    if (!secrets_is_known_scope(scope)) {
        if (err && errcap > 0) {
            snprintf(err, errcap,
                     "unknown secrets_scope '%.200s'; expected one of [minimal, default, full]",
                     scope ? scope : "");
        }
        return NULL;
    }

    char **envp = NULL; size_t nenv = 0;

    /* Whitelist base: PATH/HOME re-derived + locale/terminal vars forwarded. */
    char path[PATH_MAX], home[PATH_MAX];
    derive_path(path, sizeof(path));
    derive_home(home, sizeof(home));
    if (envp_append(&envp, &nenv, "PATH", path) != 0) goto oom;
    if (envp_append(&envp, &nenv, "HOME", home) != 0) goto oom;
    if (envp_forward_env(&envp, &nenv, "LANG") != 0) goto oom;
    if (envp_forward_env(&envp, &nenv, "LC_ALL") != 0) goto oom;
    if (envp_forward_env(&envp, &nenv, "TZ") != 0) goto oom;
    if (envp_forward_env(&envp, &nenv, "TERM") != 0) goto oom;
    if (envp_forward_env(&envp, &nenv, "XDG_RUNTIME_DIR") != 0) goto oom;

    /* Inject ONLY the scope's secret keys (silently skip names not in
     * [secrets]). */
    char **sec_keys = NULL, **sec_vals = NULL; size_t nsec = 0;
    char **sc_keys = NULL; char ***sc_vals = NULL; size_t nsc = 0;
    secrets_load_store(NULL, &sec_keys, &sec_vals, &nsec, &sc_keys, &sc_vals, &nsc);

    /* Find the scope's secret-name list. */
    char **scope_names = NULL;
    for (size_t i = 0; i < nsc; i++) {
        if (sc_keys[i] && strcmp(sc_keys[i], scope) == 0) {
            scope_names = sc_vals[i];
            break;
        }
    }
    if (scope_names) {
        for (size_t i = 0; scope_names[i] != NULL; i++) {
            const char *name = scope_names[i];
            for (size_t j = 0; j < nsec; j++) {
                if (sec_keys[j] && strcmp(sec_keys[j], name) == 0) {
                    if (envp_append(&envp, &nenv, name, sec_vals[j]) != 0) goto oom;
                    break;
                }
            }
        }
    }

    secrets_store_free(sec_keys, sec_vals, nsec, sc_keys, sc_vals, nsc);

    /* NULL-terminate (ptrarr_append already appends a trailing NULL on every
     * append, but make sure when nenv==0). */
    if (nenv == 0) {
        envp = malloc(sizeof(char *) * 1);
        if (!envp) return NULL;
        envp[0] = NULL;
    }
    /* The last append already wrote a NULL at index nenv. */
    return envp;

oom:
    secrets_store_free(sec_keys, sec_vals, nsec, sc_keys, sc_vals, nsc);
    secrets_envp_free(envp);
    if (err && errcap > 0) snprintf(err, errcap, "out of memory building child env");
    return NULL;
}

void secrets_envp_free(char **envp) {
    if (!envp) return;
    for (size_t i = 0; envp[i] != NULL; i++) free(envp[i]);
    free(envp);
}
