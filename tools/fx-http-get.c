/* tools/fx-http-get.c — the http_get DECLARED PROGRAM (egress S3).
 *
 * The host-tool program the proxy's registry names for http_get.  THE
 * CONTRACT is the one fx-host-time.c states: stdin = the call's arguments as
 * JSON verbatim (the `url` is extracted BY KEY from that JSON — never
 * interpolated into a command line), stdout = the RESULT, exit 0 for a
 * well-formed call, exit != 0 for a hard parse error (the SPAWN renders a
 * named refusal for that case, never a silent empty success).
 *
 * THE PROXY CARRIES NO HTTP FOR THIS (the S3 shape correction): the proxy's
 * P10 HTTP client exists for the MODEL UPSTREAM only (a fixed endpoint plus
 * credential handling), and a second purpose there would make HTTP the only
 * possible egress.  THIS binary is the fetch, and it CARRIES THE REFUSALS AS
 * THE CALL'S RESULT so the model reads why:
 *   - https            REFUSED LOUDLY (no TLS stack — a hand-rolled TLS here
 *                      would be a silent-wrong surface; the honest upgrade is
 *                      a TLS library link, stated, not built);
 *   - 3xx              never followed (the classic allowlist bypass);
 *   - non-http scheme  refused by name;
 *   - IP literal       refused by name (an IP-literal authority is unclassable,
 *                      and this program refuses it directly too);
 *   - userinfo         refused (a credential embedded in the URL is never sent);
 *   - timeout          a whole-exchange deadline, and a per-read stall bound;
 *   - over-cap         the response body is capped — refuse, never drop.
 * Every refusal is a NAMED string on stdout (exit 0): it IS the call's
 * result.  The SPAWN's own deadline and stdout cap are the outer bounds; this
 * file's are the inner ones (a nicer refusal name, not a silent hang).
 *
 * SECURITY POSTURE, stated plainly: fetched bytes enter the model's context
 * with tool-result authority — prompt injection is NOT fixed here (the
 * record makes the consequence visible, not contained).  No credential is
 * ever read from the environment or sent: this program speaks ANONYMOUS GET.
 */
#define _POSIX_C_SOURCE 200809L
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "yyjson.h"

#define FH_HTTP_MAX 400u /* the response BODY cap.  The fetched body IS the
                          * result, and the result must fit the record's
                          * 512-byte outcome cap (the S2-fix record/wire
                          * agreement) — so the body is capped below it:
                          * refuse, never drop. */
#define FH_HTTP_DEADLINE 30   /* whole-exchange deadline, seconds */
#define FH_HTTP_CONNECT_TIMEOUT 5
#define FH_HTTP_READ_TIMEOUT 15 /* per-read stall bound (SO_RCVTIMEO) */

static void die_errno(const char *what) {
    fprintf(stderr, "fx-http-get: FATAL: %s: errno=%d\n", what, errno);
    exit(1);
}

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) die_errno("malloc");
    return p;
}

static double now_mono(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void refuse(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("(http_get: REFUSED — ", stdout);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputs(")\n", stdout);
    fflush(stdout);
}

/* Read all of stdin (the args JSON), bounded. */
static char *read_stdin(void) {
    size_t cap = 4096, len = 0;
    char *buf = xmalloc(cap);
    for (;;) {
        if (len + 4096 > cap) {
            cap *= 2;
            char *nb = realloc(buf, cap);
            if (!nb) { free(buf); return NULL; }
            buf = nb;
        }
        ssize_t n = read(0, buf + len, cap - len - 1);
        if (n < 0) {
            if (errno == EINTR) continue;
            free(buf);
            return NULL;
        }
        if (n == 0) break;
        len += (size_t)n;
    }
    buf[len] = '\0';
    return buf;
}

/* A parsed URL: scheme (lowercased), host, port, path. */
struct url {
    char scheme[16];
    char *host;
    int port;
    char *path;
};

/* Is `host` an IP literal (dotted-quad or IPv6)?  An IP-literal authority is
 * unclassable (no operator table names it) and is refused by name. */
static int host_is_ip_literal(const char *host) {
    int dots = 0, digits = 0, other = 0;
    for (const char *p = host; *p; p++) {
        if (*p == '.') dots++;
        else if (*p >= '0' && *p <= '9') digits++;
        else if (*p == ':') return 1; /* IPv6 */
        else other++;
    }
    return other == 0 && digits > 0 && dots == 3;
}

/* Parse `raw` into *u.  Returns 0 on success, -1 after a named refusal on
 * stdout (the refusal IS the result; the caller exits 0). */
static int parse_url(const char *raw, struct url *u) {
    memset(u, 0, sizeof *u);
    u->port = 80;
    if (!raw || !*raw) { refuse("no url was given"); return -1; }
    const char *scheme_end = strstr(raw, "://");
    if (!scheme_end) { refuse("the url \"%s\" is not a URL (expected http://host[:port]/path)", raw); return -1; }
    size_t slen = (size_t)(scheme_end - raw);
    if (slen == 0 || slen >= sizeof u->scheme) { refuse("the url has no usable scheme"); return -1; }
    for (size_t i = 0; i < slen; i++) u->scheme[i] = (char)tolower((unsigned char)raw[i]);
    u->scheme[slen] = '\0';
    if (strcmp(u->scheme, "https") == 0) {
        refuse("the url uses https; this tool speaks plain HTTP only (no TLS "
               "stack), and a TLS endpoint is refused loudly, never "
               "half-supported");
        return -1;
    }
    if (strcmp(u->scheme, "http") != 0) {
        refuse("unsupported URL scheme \"%s\"; only the http scheme is spoken",
               u->scheme);
        return -1;
    }
    const char *p = scheme_end + 3;
    const char *slash = strchr(p, '/');
    const char *at = strchr(p, '@');
    if (at && (!slash || at < slash)) {
        refuse("the url carries userinfo (a credential embedded in the URL); "
               "this tool sends no credential, and the embedded form is "
               "refused loudly, never sent");
        return -1;
    }
    const char *hostpart_end = slash ? slash : p + strlen(p);
    const char *colon = NULL;
    for (const char *q = p; q < hostpart_end; q++) if (*q == ':') { colon = q; break; }
    size_t host_len = colon ? (size_t)(colon - p) : (size_t)(hostpart_end - p);
    if (host_len == 0) { refuse("the url has no host"); return -1; }
    u->host = xmalloc(host_len + 1);
    memcpy(u->host, p, host_len);
    u->host[host_len] = '\0';
    for (size_t i = 0; i < host_len; i++) u->host[i] = (char)tolower((unsigned char)u->host[i]);
    if (strpbrk(u->host, "\r\n")) { refuse("the url contains a CR or LF (header-injection shaped)"); free(u->host); u->host = NULL; return -1; }
    if (host_is_ip_literal(u->host)) {
        refuse("the authority \"%s\" is an IP literal; IP-literal authorities "
               "are unclassable and refused by name", u->host);
        free(u->host); u->host = NULL;
        return -1;
    }
    if (colon) {
        const char *ps = colon + 1;
        size_t plen = (size_t)(hostpart_end - ps);
        if (plen == 0 || plen >= 16) { refuse("bad port in the url"); free(u->host); u->host = NULL; return -1; }
        char pbuf[16];
        memcpy(pbuf, ps, plen); pbuf[plen] = '\0';
        char *end = NULL;
        long v = strtol(pbuf, &end, 10);
        if (!end || *end != '\0' || v < 1 || v > 65535) {
            refuse("bad port in the url");
            free(u->host); u->host = NULL;
            return -1;
        }
        u->port = (int)v;
    }
    const char *path = slash ? slash : "/";
    if (strpbrk(path, "\r\n")) { refuse("the url path contains a CR or LF (header-injection shaped)"); free(u->host); u->host = NULL; return -1; }
    u->path = xmalloc(strlen(path) + 1);
    strcpy(u->path, path);
    return 0;
}

/* A bounded TCP connect (non-blocking + poll), trying every resolved
 * address.  Returns a connected fd or -1. */
static int tcp_connect(const char *host, int port) {
    struct addrinfo hints, *res = NULL, *ai;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portstr[16];
    snprintf(portstr, sizeof portstr, "%d", port);
    if (getaddrinfo(host, portstr, &hints, &res) != 0) return -1;
    int fd = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int fl = fcntl(fd, F_GETFL, 0);
        if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) { close(fd); fd = -1; continue; }
        int c = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (c < 0 && errno == EINPROGRESS) {
            struct pollfd pfd;
            pfd.fd = fd; pfd.events = POLLOUT; pfd.revents = 0;
            int pr = poll(&pfd, 1, FH_HTTP_CONNECT_TIMEOUT * 1000);
            if (pr <= 0) { close(fd); fd = -1; continue; }
            int soerr = 0; socklen_t sl = sizeof soerr;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) != 0 || soerr != 0) {
                close(fd); fd = -1; continue;
            }
        } else if (c < 0) { close(fd); fd = -1; continue; }
        if (fcntl(fd, F_SETFL, fl) < 0) { close(fd); fd = -1; continue; }
        break;
    }
    freeaddrinfo(res);
    return fd;
}

static int write_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        off += (size_t)n;
    }
    return 0;
}

/* One anonymous GET.  Returns 0 with the body in *body_out and *len_out on
 * success; -1 after a named refusal on stdout. */
static int do_get(const char *host, int port, const char *path,
                  char **body_out, size_t *len_out) {
    *body_out = NULL;
    *len_out = 0;
    int fd = tcp_connect(host, port);
    if (fd < 0) { refuse("cannot connect to %s:%d", host, port); return -1; }

    struct timeval rtv;
    rtv.tv_sec = FH_HTTP_READ_TIMEOUT; rtv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof rtv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &rtv, sizeof rtv);

    double start = now_mono();

    char head[4096];
    int hn = snprintf(head, sizeof head,
                      "GET %s HTTP/1.1\r\nHost: %s\r\nAccept: */*\r\n"
                      "Connection: close\r\n\r\n",
                      path, host);
    if (hn <= 0 || (size_t)hn >= sizeof head) { close(fd); refuse("request head too long"); return -1; }
    if (write_all(fd, head, (size_t)hn) != 0) {
        close(fd);
        refuse("request write to %s:%d failed", host, port);
        return -1;
    }

    unsigned char *buf = xmalloc(8192);
    size_t cap = 8192, len = 0;
    long content_len = -1;
    int chunked = 0;
    size_t head_end = 0;
    int have_head = 0;
    int status = 0;

    for (;;) {
        if (now_mono() - start > FH_HTTP_DEADLINE) {
            refuse("the fetch exceeded the %d-second deadline", FH_HTTP_DEADLINE);
            free(buf); close(fd); return -1;
        }
        if (len == cap) {
            /* the buffer (header + body) is full: the body is over the cap
             * (or the header is absurd) — refuse, never read more.  With the
             * body capped at FH_HTTP_MAX and the header bounded at 4096, a
             * well-formed response never fills the 8192-byte buffer. */
            refuse("the response body exceeds the %u-byte bound; refuse, "
                   "never drop", (unsigned)FH_HTTP_MAX);
            free(buf); close(fd); return -1;
        }
        ssize_t n = read(fd, buf + len, cap - len);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                refuse("the endpoint stalled %d seconds between bytes",
                       FH_HTTP_READ_TIMEOUT);
                free(buf); close(fd); return -1;
            }
            refuse("read from %s:%d failed", host, port);
            free(buf); close(fd); return -1;
        }
        if (n == 0) break;
        len += (size_t)n;

        if (!have_head) {
            for (size_t i = 0; i + 3 < len; i++) {
                if (buf[i] == '\r' && buf[i+1] == '\n' && buf[i+2] == '\r' && buf[i+3] == '\n') {
                    have_head = 1;
                    head_end = i + 4;
                    break;
                }
            }
            if (have_head) {
                char hb[4096];
                size_t hl = head_end;
                if (hl > sizeof hb - 1) { refuse("response header absurdly long"); free(buf); close(fd); return -1; }
                memcpy(hb, buf, hl); hb[hl] = '\0';
                if (sscanf(hb, "HTTP/%*s %d", &status) == 1 && status >= 300 && status < 400) {
                    refuse("the server answered HTTP %d (a redirect); redirects "
                           "are never followed (the classic allowlist bypass)",
                           status);
                    free(buf); close(fd); return -1;
                }
                if (sscanf(hb, "HTTP/%*s %d", &status) == 1 && status != 200) {
                    refuse("the server answered HTTP %d (not 200 OK)", status);
                    free(buf); close(fd); return -1;
                }
                for (char *line = hb; (line = strstr(line, "\r\n")) != NULL;) {
                    line += 2;
                    if (strncasecmp(line, "Content-Length:", 15) == 0)
                        content_len = strtol(line + 15, NULL, 10);
                    else if (strncasecmp(line, "Transfer-Encoding:", 18) == 0 &&
                             strcasestr(line + 18, "chunked") != NULL)
                        chunked = 1;
                }
            }
        }
        if (have_head) {
            size_t body_so_far = len - head_end;
            if (!chunked && content_len >= 0 && body_so_far >= (size_t)content_len) break;
            if (chunked) {
                const unsigned char *tail = buf + head_end;
                size_t tl = len - head_end;
                if (tl >= 5 && memcmp(tail + tl - 5, "0\r\n\r\n", 5) == 0) break;
            }
        }
    }
    close(fd);

    if (!have_head) { refuse("the endpoint sent no HTTP response header block"); free(buf); return -1; }
    if (len < 5 || strncmp((const char *)buf, "HTTP/", 5) != 0) {
        refuse("the endpoint did not answer HTTP (unrecognized status line)");
        free(buf); return -1;
    }
    if (!chunked && content_len >= 0 && len - head_end < (size_t)content_len) {
        refuse("the endpoint closed mid-stream (%zu of %ld Content-Length bytes)",
               len - head_end, content_len);
        free(buf); return -1;
    }

    unsigned char *bodyp = buf + head_end;
    size_t body_n = len - head_end;
    if (chunked) {
        char *plain = xmalloc(body_n + 1);
        size_t pn = 0, i = 0;
        int clean_end = 0;
        while (i < body_n) {
            size_t ls = i;
            while (ls < body_n && !(bodyp[ls] == '\r' && ls + 1 < body_n && bodyp[ls+1] == '\n')) ls++;
            if (ls >= body_n) break;
            long cs = strtol((const char *)bodyp + i, NULL, 16);
            size_t dl = (size_t)(ls + 2);
            if (cs == 0) { clean_end = 1; break; }
            if (cs < 0 || (size_t)cs > body_n - dl) break;
            memcpy(plain + pn, bodyp + dl, (size_t)cs);
            pn += (size_t)cs;
            i = dl + (size_t)cs + 2;
        }
        if (!clean_end) {
            refuse("the endpoint sent a malformed or truncated chunked body");
            free(plain); free(buf); return -1;
        }
        plain[pn] = '\0';
        free(buf);
        *body_out = plain;
        *len_out = pn;
        return 0;
    }
    if (content_len >= 0 && body_n > (size_t)content_len) body_n = (size_t)content_len;
    buf = realloc(buf, len + 1);
    if (!buf) die_errno("realloc response");
    if (body_n > 0 && head_end > 0) memmove(buf, buf + head_end, body_n);
    buf[body_n] = '\0';
    *body_out = (char *)buf;
    *len_out = body_n;
    return 0;
}

int main(void) {
    char *in = read_stdin();
    if (!in) return 1;
    yyjson_doc *doc = yyjson_read(in, strlen(in), 0);
    free(in);
    yyjson_val *root = doc ? yyjson_doc_get_root(doc) : NULL;
    const char *raw = NULL;
    if (yyjson_is_obj(root)) {
        yyjson_val *pv = yyjson_obj_get(root, "url");
        if (pv) raw = yyjson_get_str(pv);
    }
    if (!raw) {
        if (doc) yyjson_doc_free(doc);
        return 1; /* no url: a hard parse error -> the SPAWN refuses by name */
    }
    struct url u;
    if (parse_url(raw, &u) != 0) {
        if (doc) yyjson_doc_free(doc);
        return 0; /* a named refusal is the result, already on stdout */
    }
    if (doc) yyjson_doc_free(doc);

    char *body = NULL;
    size_t blen = 0;
    if (do_get(u.host, u.port, u.path, &body, &blen) != 0) {
        free(u.host);
        free(u.path);
        return 0; /* a named refusal is the result */
    }
    /* the body, verbatim (bounded); the SPAWN's stdout cap is the outer bound */
    fwrite(body, 1, blen, stdout);
    fflush(stdout);
    free(body);
    free(u.host);
    free(u.path);
    return 0;
}
