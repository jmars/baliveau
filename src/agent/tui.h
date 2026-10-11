/* src/agent/tui.h — terminal UI (self-contained, NO ncurses).
 *
 * A minimal live-streaming terminal UI built directly on raw termios + ANSI
 * escape sequences.  The agent loop is single-threaded/synchronous (chat_stream
 * blocks on SSE recv, forwarding deltas to a sink), so the TUI renders live from
 * the agent loop's per-delta sink — NOT from a second thread.
 *
 * When stdout (or stdin) is NOT a tty, tui_init degrades to PASS-THROUGH mode
 * (tui_active() == 0): append_line/stream print plain text to the output stream
 * (no ANSI, no raw mode, no redraw), statusf prints to stderr.  This makes the
 * TUI fully usable piped and fully testable in a sandbox without a tty.
 *
 * Memory-safety (L2 rules): bounded scrollback (drop oldest), every malloc
 * checked (returns -1 on OOM, never crashes), no strcpy/strcat/sprintf on
 * network bytes (only snprintf with caps; streaming fragments are memcpy'd),
 * and the terminal (termios + alt-screen) is restored on tui_free.
 *
 * The API is intentionally tiny: the agent_main sink calls stream/append_line/
 * end_stream per delta; statusf paints the inverse-video status bar; poll_key
 * reads stdin NON-BLOCKING (poll 0 timeout) and decodes ANSI escapes.
 */
#ifndef AGENT_TUI_H
#define AGENT_TUI_H

#include <stddef.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bound on the number of scrollback lines retained (drop-oldest beyond this).
 * Exposed so embedders / tests know the retention bound. */
#define TUI_SCROLLBACK_CAP 512

/* Opaque TUI handle. */
typedef struct Tui Tui;

/* Initialize a TUI over `in` (key input) and `outf` (rendering output).  Sets
 * *out (calloc'd; free with tui_free).  Returns 0 on success, -1 on invalid
 * args / OOM.  If either stream is not a tty, the TUI runs in pass-through
 * mode (see header note). */
int tui_init(Tui **out, FILE *in, FILE *outf);

/* Free the TUI: restore the saved termios (if raw mode was entered), leave the
 * alt-screen, show the cursor, and free the scrollback/stream buffers.  NULL
 * safe.  Safe to call at most once per tui_init. */
void tui_free(Tui *t);

/* Non-zero when the TUI is running in real (raw-mode / ANSI) mode; zero in
 * pass-through mode. */
int tui_active(const Tui *t);

/* Append a complete line to the output (buffered in the scrollback when
 * active).  In pass-through mode prints `line` + a newline to outf.  `n` is the
 * byte length of `line`.  Returns 0 / -1 (OOM — only possible in active mode). */
int tui_append_line(Tui *t, const char *line, size_t n);

/* Stream a live text fragment (the current streaming line).  In pass-through
 * mode prints the fragment as-is (no newline) to outf.  Returns 0 / -1 (OOM). */
int tui_stream(Tui *t, const char *frag, size_t n);

/* End the current streaming line (a DELTA_FINISH): promote the buffered stream
 * into the scrollback and redraw.  In pass-through mode prints a newline.
 * Returns 0 / -1. */
int tui_end_stream(Tui *t);

/* Set/refresh the status bar text.  In pass-through mode prints to stderr.
 * Returns 0 / -1. */
int tui_statusf(Tui *t, const char *fmt, ...);

/* Key codes returned by tui_poll_key. */
enum {
    TUI_KEY_NONE = 0, /* no key available (non-blocking) */
    TUI_KEY_UP,       /* arrow up           */
    TUI_KEY_DOWN,     /* arrow down         */
    TUI_KEY_PGUP,     /* Page Up            */
    TUI_KEY_PGDN,     /* Page Down          */
    TUI_KEY_HOME,     /* Home               */
    TUI_KEY_END,      /* End                */
    TUI_KEY_QUIT,     /* q / Q / Esc / Ctrl-C */
    TUI_KEY_REDRAW,   /* Ctrl-L             */
    TUI_KEY_OTHER     /* some other key     */
};

/* Read one key from stdin NON-BLOCKING (poll 0 timeout) and decode ANSI escape
 * sequences (arrows / PgUp / PgDn / Home / End).  Returns TUI_KEY_NONE when no
 * key is available.  When active, a scroll key also adjusts the viewport and
 * redraws.  Works regardless of pass-through/active mode (so key decode is
 * testable without a tty). */
int tui_poll_key(Tui *t);

/* Force a full redraw (clear + reprint the visible window + status bar).
 * No-op in pass-through mode. */
void tui_redraw(Tui *t);

#ifdef __cplusplus
}
#endif

#endif /* AGENT_TUI_H */
