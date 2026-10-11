/* src/agent/fx_transport.h — the fx-harness model transport.
 *
 * NO HTTP, NO sockets, NO TLS.  The chardev is the whole interface:
 *
 *   guest -> host   a length-prefixed request line:  "<byte-count>\n<json>"
 *   host  -> guest  the provider's raw SSE body, verbatim
 *
 * The host proxy owns the endpoint, the headers and the API KEY.  Nothing in
 * the guest knows the base_url, and no credential ever crosses the channel —
 * the api_key field on the Backend is unused by this adapter.  Every request
 * and every response is a byte stream on the one device the host owns, so the
 * transcript is recorded by the host rather than self-reported by the harness.
 *
 * There is no HTTP client and no TLS in this tree: with no socket layer in
 * the guest (CONFIG_NET unset, socket(2) -> ENOSYS) and no HTTP in the
 * channel, the adapter reads SSE bytes directly off the chardev and feeds
 * sse.c.
 */
#ifndef FX_TRANSPORT_H
#define FX_TRANSPORT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The chardev path: $FX_CHARDEV, else FX_CHARDEV_DEFAULT. */
#define FX_CHARDEV_DEFAULT "/dev/vport0p1"

/* Open the transport and return its fd, or -1.
 *
 * `host`/`port` are accepted only for signature parity with upstream's
 * tcp_connect and are IGNORED — which provider to call is the host proxy's
 * decision, not the guest's.  Pass (NULL, 0). */
int fx_transport_open(const char *host, int port);

/* Write one framed request: "<len>\n" followed by exactly len bytes of JSON.
 * Returns 0 on success, -1 on a short/failed write. */
int fx_send_request(int fd, const char *json, size_t len);

/* Read up to cap bytes, retrying EINTR.  Returns n>0, 0 on EOF, -1 on error.
 * One buffered syscall per call; the caller feeds sse.c byte-at-a-time. */
int fx_recv_some(int fd, void *buf, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* FX_TRANSPORT_H */
