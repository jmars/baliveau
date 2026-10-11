/* src/llm2/tui.c — LAYER-2 S12 terminal UI (self-contained, NO ncurses).
 *
 * A minimal live-streaming terminal UI built directly on raw termios + ANSI
 * escape sequences (cosmocc ships <termios.h> with tcgetattr/tcsetattr/
 * cfmakeraw/tcgetwinsize; TIOCGWINSZ is exposed via tcgetwinsize).  See
 * tui.h for the API and the memory-safety rules.
 *
 * Two modes:
 *   - PASS-THROUGH (active == 0, the default when stdout/stdin are not a tty):
 *     append_line/stream print plain text to outf, statusf prints to stderr, no
 *     ANSI, no raw mode, no redraw.  The bounded scrollback is still maintained
 *     so the retention logic is exercised uniformly (and testable without a
 *     tty).  tui_poll_key still decodes keys (testable from a regular FILE*).
 *   - ACTIVE (active != 0, stdout AND stdin are a tty, or the test seam
 *     VIBE_TUI_FORCE_ACTIVE is set): raw termios on stdin, enter the alt-screen,
 *     hide the cursor, redraw a visible window (clear + reprint the tail of the
 *     bounded scrollback + the current streaming line + an inverse-video status
 *     bar) on every change.  Scroll with Up/Down/PgUp/PgDn/Home/End, Ctrl-L
 *     redraws, q/Q/Esc/Ctrl-C quits.
 *
 * Memory-safety: bounded scrollback (drop oldest), every malloc checked (errors
 * surface as -1, never a crash), no strcpy/strcat/sprintf on network bytes
 * (streaming fragments are memcpy'd; only snprintf with caps is used), and the
 * terminal (termios + alt-screen + cursor) is restored on tui_free.
 */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include "tui.h"

#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <signal.h>
#include <termios.h>
#include <poll.h>
#include <sys/ioctl.h> /* fx-harness: ioctl(TIOCGWINSZ) for the window size */

/* Internal sentinel: an escape sequence is incomplete (need more input bytes). */
#define TUI_KEY_NEEDMORE (-1)

struct Tui {
    FILE *in, *outf;
    int fd_in, fd_out;
    int active;

    /* Raw-mode restoration state (only set when raw mode was actually entered). */
    int raw_set;
    struct termios saved;

    /* Terminal size (fallback 80x24). */
    int rows, cols;

    /* Bounded scrollback (drop oldest beyond TUI_SCROLLBACK_CAP). */
    char **sb;
    size_t sb_n, sb_cap;

    /* The current streaming line (active mode). */
    char *stream;
    size_t stream_len, stream_cap;
    int stream_open; /* pass-through: did any fragment stream since last end? */

    /* Inverse-video status bar text. */
    char status[256];

    /* Lines scrolled up from the live bottom. */
    int back;

    /* Pending un-decoded input bytes (escape sequences spanning reads). */
    unsigned char pend[64];
    size_t pend_n;
};

/* ── abnormal-exit terminal restore ──────────────────────────────────────
 * cfmakeraw clears ISIG so Ctrl-C is already intercepted as a quit key, but a
 * SIGTERM / SIGHUP / SIGINT / crash (if it reaches exit()) while in raw mode
 * would otherwise leave the user's terminal in raw mode with a hidden cursor
 * and the alt-screen engaged.  To make the ctx's "atexit-safe" note true for
 * abnormal termination too, keep a process-global pointer to the ACTIVE Tui and
 * restore the terminal from an atexit() handler and from a SIGTERM/SIGHUP/
 * SIGINT handler.  Only async-signal-safe calls are used in the signal path
 * (tcsetattr + write() — no fputs/fflush/printf). */
static Tui *g_active_tui;       /* the ACTIVE (raw-mode) Tui, or NULL */
static int  g_restore_registered;

/* Restore the terminal to a sane state.  Idempotent.  Async-signal-safe
 * primitives only (used from both atexit() and the signal handler). */
static void restore_terminal_now(void) {
    Tui *t = g_active_tui;
    if (!t || !t->active) return;
    if (t->raw_set) tcsetattr(t->fd_in, TCSANOW, &t->saved); /* restore termios */
    if (t->fd_out >= 0) {
        static const char show[]  = "\x1b[?25h";  /* show cursor */
        static const char leave[] = "\x1b[?1049l"; /* leave alt screen */
        (void)write(t->fd_out, show, sizeof show - 1);
        (void)write(t->fd_out, leave, sizeof leave - 1);
    }
}

static void tui_on_atexit(void) {
    restore_terminal_now();
    g_active_tui = NULL;
}

static void tui_on_signal(int sig) {
    restore_terminal_now();
    /* Re-raise with the default disposition so the exit status reflects the
     * signal that killed us. */
    signal(sig, SIG_DFL);
    raise(sig);
    _exit(128 + sig); /* in case the re-raise returns */
}

static void tui_register_restore(void) {
    if (g_restore_registered) return;
    g_restore_registered = 1;
    (void)atexit(tui_on_atexit);
    signal(SIGTERM, tui_on_signal);
    signal(SIGHUP,  tui_on_signal);
    signal(SIGINT,  tui_on_signal);
}

/* ── helpers ────────────────────────────────────────────────────────────── */

static void write_str(Tui *t, const char *s) {
    if (t->outf && s) fputs(s, t->outf);
}

/* Clamp the scroll offset to the valid range [0, last line index]. */
static void clamp_back(Tui *t) {
    size_t vcount = t->sb_n + (t->stream_len ? 1 : 0);
    long maxback = vcount ? (long)vcount - 1 : 0;
    if (t->back > maxback) t->back = (int)maxback;
    if (t->back < 0) t->back = 0;
}

/* Redraw the visible window: home + clear, reprint the tail of the scrollback
 * + the streaming line, then an inverse-video status bar.  No-op in
 * pass-through mode. */
static void render(Tui *t) {
    if (!t->active || !t->outf) return;
    int rows = t->rows, cols = t->cols;
    int content_rows = rows - 1; /* status bar takes the last row */
    if (content_rows < 1) content_rows = 1;
    if (cols < 1) cols = 1;

    write_str(t, "\x1b[H\x1b[2J"); /* home + clear */

    size_t vcount = t->sb_n + (t->stream_len ? 1 : 0);
    long bottom = vcount ? (long)vcount - 1 - t->back : -1;
    long top = bottom - (content_rows - 1);
    if (top < 0) top = 0;

    for (long vi = top; vi <= bottom; vi++) {
        const char *line = "";
        size_t len = 0;
        if ((size_t)vi < t->sb_n) { line = t->sb[vi]; len = strlen(line); }
        else if ((size_t)vi == t->sb_n && t->stream_len) { line = t->stream; len = t->stream_len; }
        size_t clip = len < (size_t)cols ? len : (size_t)cols;
        if (clip) fwrite(line, 1, clip, t->outf);
        fputc('\n', t->outf);
    }

    /* Inverse-video status bar, clipped + padded to `cols`. */
    write_str(t, "\x1b[7m");
    size_t slen = strlen(t->status);
    if (slen > (size_t)cols) slen = cols;
    if (slen) fwrite(t->status, 1, slen, t->outf);
    for (size_t i = slen; i < (size_t)cols; i++) fputc(' ', t->outf);
    write_str(t, "\x1b[0m");
    fflush(t->outf);
}

/* Consume the first `n` pending input bytes. */
static void consume(Tui *t, size_t n) {
    if (n > t->pend_n) n = t->pend_n;
    if (n == 0) return;
    memmove(t->pend, t->pend + n, t->pend_n - n);
    t->pend_n -= n;
}

/* Non-blocking (or short-timeout) refill of the pending input buffer from
 * fd_in.  timeout_ms 0 = poll 0 (no wait).  Returns bytes appended, 0 if none
 * available / EOF, or a negative poll/read error. */
static int fill_input(Tui *t, int timeout_ms) {
    if (t->fd_in < 0) return 0;
    struct pollfd pfd;
    pfd.fd = t->fd_in;
    pfd.events = POLLIN;
    int pr = poll(&pfd, 1, timeout_ms);
    if (pr <= 0) return pr; /* 0 = none/timeout, <0 = poll error */

    unsigned char tmp[64];
    ssize_t r = read(t->fd_in, tmp, sizeof tmp);
    if (r <= 0) return 0;
    size_t room = sizeof(t->pend) - t->pend_n;
    size_t take = ((size_t)r < room) ? (size_t)r : room;
    memcpy(t->pend + t->pend_n, tmp, take);
    t->pend_n += take;
    return (int)take;
}

/* Decode ONE complete key from the pending buffer.  Returns TUI_KEY_NEEDMORE
 * if the leading escape sequence is incomplete (consume nothing), else consumes
 * the sequence and returns a TUI_KEY_*. */
static int decode_key(Tui *t) {
    if (t->pend_n == 0) return TUI_KEY_NONE;
    unsigned char c0 = t->pend[0];

    if (c0 == 0x1b) { /* ESC — either a lone ESC (quit) or a CSI/SS3 sequence */
        if (t->pend_n == 1) return TUI_KEY_NEEDMORE;
        unsigned char c1 = t->pend[1];
        if (c1 == '[') {
            if (t->pend_n < 3) return TUI_KEY_NEEDMORE;
            unsigned char c2 = t->pend[2];
            switch (c2) {
            case 'A': consume(t, 3); return TUI_KEY_UP;
            case 'B': consume(t, 3); return TUI_KEY_DOWN;
            case 'H': consume(t, 3); return TUI_KEY_HOME;
            case 'F': consume(t, 3); return TUI_KEY_END;
            case 'C': case 'D': consume(t, 3); return TUI_KEY_OTHER; /* right/left */
            case '5': case '6': { /* PgUp/PgDn: ESC [ 5~ / 6~ */
                if (t->pend_n < 4) return TUI_KEY_NEEDMORE;
                if (t->pend[3] == '~') { consume(t, 4); return c2 == '5' ? TUI_KEY_PGUP : TUI_KEY_PGDN; }
                consume(t, 3); return TUI_KEY_OTHER;
            }
            default: consume(t, 3); return TUI_KEY_OTHER;
            }
        }
        if (c1 == 'O') { /* SS3: ESC O A / B / H / F */
            if (t->pend_n < 3) return TUI_KEY_NEEDMORE;
            unsigned char c2 = t->pend[2];
            consume(t, 3);
            switch (c2) {
            case 'A': return TUI_KEY_UP;
            case 'B': return TUI_KEY_DOWN;
            case 'H': return TUI_KEY_HOME;
            case 'F': return TUI_KEY_END;
            default:  return TUI_KEY_OTHER;
            }
        }
        consume(t, 1); /* lone ESC followed by a non-sequence byte -> quit */
        return TUI_KEY_QUIT;
    }

    consume(t, 1);
    switch (c0) {
    case 0x03: case 'q': case 'Q': return TUI_KEY_QUIT; /* Ctrl-C / q / Q */
    case 0x0c: return TUI_KEY_REDRAW;                    /* Ctrl-L */
    default:   return TUI_KEY_OTHER;
    }
}

/* Apply a scroll/redraw key to the viewport. */
static void handle_scroll_key(Tui *t, int key) {
    int content_rows = t->rows - 1;
    if (content_rows < 1) content_rows = 1;
    switch (key) {
    case TUI_KEY_UP:    t->back += 1;               break;
    case TUI_KEY_DOWN:  t->back -= 1;               break;
    case TUI_KEY_PGUP:  t->back += content_rows;    break;
    case TUI_KEY_PGDN:  t->back -= content_rows;    break;
    case TUI_KEY_HOME:  t->back = 1000000; break;   /* clamp to top */
    case TUI_KEY_END:   t->back = 0;       break;   /* live bottom */
    default: break;                                 /* REDRAW etc. */
    }
    if (t->back < 0) t->back = 0;
    clamp_back(t);
    render(t);
}

/* ── public API ─────────────────────────────────────────────────────────── */

int tui_init(Tui **out, FILE *in, FILE *outf) {
    if (!out) return -1;
    *out = NULL;
    if (!in || !outf) return -1;

    Tui *t = (Tui *)calloc(1, sizeof *t);
    if (!t) return -1;
    t->in = in;
    t->outf = outf;
    t->fd_in = fileno(in);
    t->fd_out = fileno(outf);
    t->rows = 24;
    t->cols = 80;
    t->status[0] = '\0';

    /* Active when both streams are a tty (or the test seam is set). */
    int is_tty = (t->fd_in >= 0 && t->fd_out >= 0 &&
                  isatty(t->fd_in) && isatty(t->fd_out));
    const char *force = getenv("VIBE_TUI_FORCE_ACTIVE");
    t->active = is_tty || (force && *force);

    if (t->active) {
        /* Register the abnormal-exit terminal restore once (atexit + signals).
         * Only meaningful when raw mode can be entered. */
        tui_register_restore();
        g_active_tui = t;
        /* Raw mode on stdin (best-effort; harmless if stdin is not a real tty). */
        if (tcgetattr(t->fd_in, &t->saved) == 0) {
            struct termios raw = t->saved;
            cfmakeraw(&raw);
            raw.c_cc[VMIN] = 0;
            raw.c_cc[VTIME] = 0;
            if (tcsetattr(t->fd_in, TCSANOW, &raw) == 0) t->raw_set = 1;
        }
        struct winsize ws;
        /* fx-harness: ioctl(TIOCGWINSZ), not tcgetwinsize(3) — the latter is
         * glibc>=2.36 / POSIX-2024 and is ABSENT FROM MUSL, the libc every fx
         * guest binary builds against, so the upstream call cannot link there. */
        if (ioctl(t->fd_out, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0 && ws.ws_col > 0) {
            t->rows = ws.ws_row;
            t->cols = ws.ws_col;
        }
        if (t->rows < 2) t->rows = 2;
        if (t->cols < 1) t->cols = 1;
        write_str(t, "\x1b[?1049h"); /* enter alt screen */
        write_str(t, "\x1b[?25l");   /* hide cursor */
        fflush(t->outf);
        render(t);
    }

    *out = t;
    return 0;
}

void tui_free(Tui *t) {
    if (!t) return;
    if (t->active) {
        if (g_active_tui == t) g_active_tui = NULL; /* normal path owns the restore */
        if (t->raw_set) tcsetattr(t->fd_in, TCSANOW, &t->saved); /* restore termios */
        write_str(t, "\x1b[?25h");   /* show cursor */
        write_str(t, "\x1b[?1049l"); /* leave alt screen */
        fflush(t->outf);
    }
    for (size_t i = 0; i < t->sb_n; i++) free(t->sb[i]);
    free(t->sb);
    free(t->stream);
    free(t);
}

int tui_active(const Tui *t) {
    return t ? t->active : 0;
}

int tui_append_line(Tui *t, const char *line, size_t n) {
    if (!t || !line) return -1;

    /* Buffer into the bounded scrollback (drop oldest at cap) in BOTH modes so
     * retention is uniform and testable without a tty. */
    char *copy = (char *)malloc(n + 1);
    if (!copy) return -1;
    memcpy(copy, line, n);
    copy[n] = '\0';

    if (t->sb_n == TUI_SCROLLBACK_CAP) { /* drop oldest */
        free(t->sb[0]);
        memmove(&t->sb[0], &t->sb[1], (t->sb_n - 1) * sizeof(char *));
        t->sb_n--;
    }
    if (t->sb_n >= t->sb_cap) {
        size_t nc = t->sb_cap ? t->sb_cap * 2 : 64;
        char **nd = (char **)realloc(t->sb, nc * sizeof(char *));
        if (!nd) { free(copy); return -1; }
        t->sb = nd;
        t->sb_cap = nc;
    }
    t->sb[t->sb_n++] = copy;

    t->stream_len = 0; /* a completed line supersedes the streaming line */
    t->stream_open = 0;

    if (!t->active) {
        if (t->outf) { fwrite(line, 1, n, t->outf); fputc('\n', t->outf); fflush(t->outf); }
        return 0;
    }
    clamp_back(t);
    render(t);
    return 0;
}

int tui_stream(Tui *t, const char *frag, size_t n) {
    if (!t || !frag) return -1;

    if (!t->active) {
        if (t->outf && n) { fwrite(frag, 1, n, t->outf); fflush(t->outf); }
        if (n) t->stream_open = 1;
        return 0;
    }

    if (t->stream_len + n + 1 > t->stream_cap) {
        size_t nc = t->stream_cap ? t->stream_cap : 64;
        while (nc < t->stream_len + n + 1) nc *= 2;
        char *nd = (char *)realloc(t->stream, nc);
        if (!nd) return -1;
        t->stream = nd;
        t->stream_cap = nc;
    }
    memcpy(t->stream + t->stream_len, frag, n);
    t->stream_len += n;
    t->stream[t->stream_len] = '\0';
    t->stream_open = 1;
    clamp_back(t);
    render(t);
    return 0;
}

int tui_end_stream(Tui *t) {
    if (!t) return -1;

    if (!t->active) {
        if (t->outf && t->stream_open) { fputc('\n', t->outf); fflush(t->outf); }
        t->stream_open = 0;
        return 0;
    }

    if (t->stream_len > 0) {
        /* Promote the streaming line into the scrollback. */
        char *s = t->stream;
        size_t n = t->stream_len;
        t->stream = NULL;
        t->stream_len = 0;
        t->stream_cap = 0;
        t->stream_open = 0;
        /* Reuse append_line's buffering by appending the owned buffer directly. */
        if (t->sb_n == TUI_SCROLLBACK_CAP) {
            free(t->sb[0]);
            memmove(&t->sb[0], &t->sb[1], (t->sb_n - 1) * sizeof(char *));
            t->sb_n--;
        }
        if (t->sb_n >= t->sb_cap) {
            size_t nc = t->sb_cap ? t->sb_cap * 2 : 64;
            char **nd = (char **)realloc(t->sb, nc * sizeof(char *));
            if (!nd) { free(s); return -1; }
            t->sb = nd;
            t->sb_cap = nc;
        }
        t->sb[t->sb_n++] = s;
        s[n] = '\0';
    }
    t->stream_open = 0;
    clamp_back(t);
    render(t);
    return 0;
}

int tui_statusf(Tui *t, const char *fmt, ...) {
    if (!t || !fmt) return -1;

    if (!t->active) {
        va_list ap;
        va_start(ap, fmt);
        vfprintf(stderr, fmt, ap);
        va_end(ap);
        fputc('\n', stderr);
        fflush(stderr);
        return 0;
    }

    va_list ap;
    va_start(ap, fmt);
    vsnprintf(t->status, sizeof t->status, fmt, ap);
    va_end(ap);
    render(t);
    return 0;
}

int tui_poll_key(Tui *t) {
    if (!t || t->fd_in < 0) return TUI_KEY_NONE;

    fill_input(t, 0); /* refill once, non-blocking */
    for (int guard = 0; guard < 8; guard++) {
        int k = decode_key(t);
        if (k != TUI_KEY_NEEDMORE) {
            if (t->active && (k == TUI_KEY_UP || k == TUI_KEY_DOWN ||
                              k == TUI_KEY_PGUP || k == TUI_KEY_PGDN ||
                              k == TUI_KEY_HOME || k == TUI_KEY_END ||
                              k == TUI_KEY_REDRAW))
                handle_scroll_key(t, k);
            return k;
        }
        /* Incomplete escape sequence: wait briefly for the rest. */
        int got = fill_input(t, 25);
        if (got <= 0) {
            if (t->pend_n == 1 && t->pend[0] == 0x1b) { t->pend_n = 0; return TUI_KEY_QUIT; }
            if (t->pend_n) { consume(t, 1); return TUI_KEY_OTHER; }
            return TUI_KEY_NONE;
        }
    }
    return TUI_KEY_OTHER;
}

void tui_redraw(Tui *t) {
    if (!t) return;
    if (t->active) render(t);
}
