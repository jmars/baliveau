/* src/llm2/fx_backend.c — the ONE-backend factory (replaces backend_select.c).
 *
 * Upstream's backend_build() routes across four adapters (openai_responses,
 * generic, mistral, anthropic); each drags in its own tcp_connect copy plus
 * http_client/tls.  fx-harness ships ONE backend so that the transport seam is
 * a single file and the surface to audit stays small.
 *
 * Faithful to upstream for the one type it accepts:
 *   - base_url is BORROWED (the caller's config owns it for the process life)
 *   - api_key is a borrowed getenv() pointer, resolved ONLY when the provider
 *     names a non-empty env var; absent => NULL => the adapter omits the auth
 *     header (the call then fails auth: FAIL-CLOSED)
 *   - an unknown type returns -1 with `out` untouched, so agent_main's
 *     fail-open resolves to openai_responses_backend()
 *
 * Because the guest holds no credentials, upstream's secrets-scope logic has
 * nothing to inject here: api_key is NULL unless a future config explicitly
 * carries a key in the guest's environment, and the host proxy is the only
 * place a real key lives.
 */
#include "llm_backend.h"

#include <stdlib.h>
#include <string.h>

int backend_build(Backend *out, const char *type, const char *base_url,
                  const char *api_key_env_var) {
    if (!out || !type || !base_url) return -1;
    memset(out, 0, sizeof *out);

    out->base_url = base_url; /* borrowed */

    if (api_key_env_var && *api_key_env_var)
        out->api_key = getenv(api_key_env_var);

    if (strcmp(type, "openai_responses") != 0)
        return -1; /* unknown type: caller fail-opens to the default backend */

    out->format      = RESPONSES;
    out->chat_stream = openai_responses_chat_stream;
    out->parse_event = openai_responses_parse_event;
    out->impl        = NULL;
    return 0;
}
