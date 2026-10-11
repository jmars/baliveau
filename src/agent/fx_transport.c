/* src/agent/fx_transport.c — the chardev transport (no HTTP, no sockets, no TLS).
 *
 * WHAT THIS REPLACES, and why each had to go:
 *
 *   tcp_connect()             socket(2)+connect(2)/getaddrinfo — the guest has
 *                             NO socket layer (CONFIG_NET unset => ENOSYS)
 *   http_socket_bio()         a BIO built on recv(2)/send(2).  MEASURED: those
 *                             return ENOTSOCK on a chardev, so http_request()
 *                             failed having written ZERO bytes and the loop
 *                             reported "backend/loop error" with the device
 *                             never having seen a request
 *   http_client.c             HTTP/1.1 request framing + head/chunked/
 *                             content-length body parsing — an envelope with
 *                             nothing to carry: the host proxy speaks HTTP to
 *                             the provider, the guest speaks SSE to the host
 *   tls_bio_create_default()  mbedTLS over the socket (16 MB vendored) — gone,
 *                             and with it the api_key from the guest path
 *
 * WHAT REMAINS is the shape the system actually has: one declared device, a
 * framed request out, a raw SSE stream back.
 *
 * FRAMING.  "<len>\n<json>" — a decimal byte count, a newline, then the request
 * body.  JSON is not newline-safe to delimit (the loop's serializer is not
 * required to escape them), so the count is authoritative.  It is also
 * trivially readable by a shell-side proxy, which matters for the offline arm.
 *
 * OFFLINE ARM (no proxy, no network): point FX_CHARDEV at a regular file
 * holding a RECORDED SSE STREAM (no HTTP envelope).  O_APPEND puts the request
 * past the canned bytes while reads still start at offset 0, and a regular file
 * gives a real EOF — so a recorded provider stream drives the whole loop
 * deterministically.
 */
#include "fx_transport.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int fx_transport_open(const char *host, int port) {
    /* host/port deliberately unused: the guest does not choose the provider,
     * the host proxy does (it holds the API key). */
    (void)host;
    (void)port;

    const char *p = getenv("FX_CHARDEV");
    if (!p || !*p) p = FX_CHARDEV_DEFAULT;

    /* O_RDWR: a chardev is bidirectional, and a FIFO opened read-only blocks
     * until a writer appears.  O_APPEND makes the offline arm deterministic (it
     * ignores the read offset, so the request lands past the canned stream
     * while reads start at 0); a character device ignores it. */
    return open(p, O_RDWR | O_APPEND);
}

int fx_send_request(int fd, const char *json, size_t len) {
    char hdr[32];
    int hl = snprintf(hdr, sizeof hdr, "%zu\n", len);
    if (hl <= 0 || (size_t)hl >= sizeof hdr) return -1;

    const char *parts[2] = { hdr, json };
    size_t sizes[2] = { (size_t)hl, len };

    for (int k = 0; k < 2; k++) {
        size_t off = 0;
        while (off < sizes[k]) {
            ssize_t n = write(fd, parts[k] + off, sizes[k] - off);
            if (n < 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            off += (size_t)n;
        }
    }
    /* Position the fd at the start of the response before any read.
     * MEASURED: write(2) advances the file offset EVEN UNDER O_APPEND, so
     * without this the first read returns 0 (EOF) and the loop sees an empty
     * stream — the O_APPEND trick alone is not enough.  A character device
     * cannot seek (ESPIPE) and the proxy streams back regardless, so the
     * result is deliberately ignored. */
    (void)lseek(fd, 0, SEEK_SET);

    return 0;
}

int fx_recv_some(int fd, void *buf, size_t cap) {
    for (;;) {
        ssize_t n = read(fd, buf, cap);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        return (int)n; /* 0 = EOF */
    }
}
