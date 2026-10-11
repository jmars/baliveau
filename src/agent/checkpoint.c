/* src/agent/checkpoint.c — messages.jsonl checkpoint (see .h).
 *
 * Self-contained: uses ONLY the LlmMsg/LlmToolCall types from agent_loop.h
 * (never agent_loop.c internals), the runstore accessors, and yyjson.  JSON is
 * built/parsed with yyjson_mut/yyjson_read only.
 */
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#include "checkpoint.h"
#include "yyjson.h"

static void msg_free(LlmMsg *m); /* fwd decl (used by msg_copy below) */

/* Copy `s` into a fresh malloc'd NUL-terminated buffer, truncating to `cap`
 * bytes (the cap excludes the trailing NUL).  NULL input -> empty string. */
static char *dup_capped(const char *s, size_t cap) {
    if (!s) s = "";
    size_t len = strlen(s);
    if (len > cap) len = cap;
    char *out = (char *)malloc(len + 1);
    if (!out) return NULL;
    memcpy(out, s, len);
    out[len] = '\0';
    return out;
}

/* Deep-copy one LlmToolCall into *dst (dst must be zeroed).  Returns 0/-1. */
static int tool_call_copy(LlmToolCall *dst, const LlmToolCall *src) {
    memset(dst, 0, sizeof *dst);
    dst->id = dup_capped(src->id, CKPT_FIELD_CAP);
    dst->name = dup_capped(src->name, CKPT_FIELD_CAP);
    /* Arguments JSON is attacker-shaped (prompt-injection) — tight cap. */
    dst->arguments = dup_capped(src->arguments, AGENT_ARGS_CAP);
    dst->arguments_len = dst->arguments ? strlen(dst->arguments) : 0;
    if ((src->id && !dst->id) || (src->name && !dst->name) ||
        (src->arguments && !dst->arguments)) {
        free((char *)dst->id);
        free((char *)dst->name);
        free((char *)dst->arguments);
        memset(dst, 0, sizeof *dst);
        return -1;
    }
    return 0;
}

/* Deep-copy one LlmMsg into *dst (dst must be zeroed).  Returns 0/-1; on error
 * frees whatever was allocated. */
static int msg_copy(LlmMsg *dst, const LlmMsg *src) {
    memset(dst, 0, sizeof *dst);
    dst->role = dup_capped(src->role, CKPT_FIELD_CAP);
    dst->content = dup_capped(src->content, CKPT_FIELD_CAP);
    dst->content_len = dst->content ? strlen(dst->content) : 0;
    dst->tool_call_id = dup_capped(src->tool_call_id, CKPT_FIELD_CAP);
    if ((src->role && !dst->role) || (src->content && !dst->content) ||
        (src->tool_call_id && !dst->tool_call_id)) {
        msg_free(dst);
        return -1;
    }
    if (src->n_tool_calls) {
        dst->tool_calls = (LlmToolCall *)calloc(src->n_tool_calls,
                                                sizeof(LlmToolCall));
        if (!dst->tool_calls) { msg_free(dst); return -1; }
        for (size_t i = 0; i < src->n_tool_calls; i++) {
            if (tool_call_copy(&dst->tool_calls[i], &src->tool_calls[i]) != 0) {
                dst->n_tool_calls = i; /* so msg_free frees the copies made so far */
                msg_free(dst);
                return -1;
            }
        }
        dst->n_tool_calls = src->n_tool_calls;
    }
    return 0;
}

/* Free every string + tool_call owned by a single LlmMsg, then zero it. */
static void msg_free(LlmMsg *m) {
    if (!m) return;
    free((char *)m->role);
    free((char *)m->content);
    free((char *)m->tool_call_id);
    for (size_t i = 0; i < m->n_tool_calls; i++) {
        free((char *)m->tool_calls[i].id);
        free((char *)m->tool_calls[i].name);
        free((char *)m->tool_calls[i].arguments);
    }
    free(m->tool_calls);
    memset(m, 0, sizeof *m);
}


/* ── list lifecycle ─────────────────────────────────────────────────────── */

void ckpt_messages_init(CkptMessages *c) {
    if (!c) return;
    memset(c, 0, sizeof *c);
}

void ckpt_messages_free(CkptMessages *c) {
    if (!c) return;
    for (size_t i = 0; i < c->n; i++) msg_free(&c->msgs[i]);
    free(c->msgs);
    c->msgs = NULL;
    c->n = c->cap = 0;
}

int ckpt_append(CkptMessages *c, const LlmMsg *msg) {
    if (!c || !msg) return -1;
    if (c->n == c->cap) {
        size_t ncap = c->cap ? c->cap * 2 : 8;
        LlmMsg *nm = (LlmMsg *)realloc(c->msgs, ncap * sizeof(LlmMsg));
        if (!nm) return -1;
        c->msgs = nm;
        c->cap = ncap;
    }
    if (msg_copy(&c->msgs[c->n], msg) != 0) return -1;
    c->n++;
    return 0;
}

/* ── serialization ──────────────────────────────────────────────────────── */

/* Append one message as a compact JSON object to the mut-doc `root`. */
static void msg_to_json(yyjson_mut_doc *doc, yyjson_mut_val *root,
                        const LlmMsg *m) {
    yyjson_mut_obj_add_strcpy(doc, root, "role", m->role ? m->role : "");
    yyjson_mut_obj_add_strcpy(doc, root, "content",
                              m->content ? m->content : "");
    if (m->tool_call_id && m->tool_call_id[0])
        yyjson_mut_obj_add_strcpy(doc, root, "tool_call_id", m->tool_call_id);
    if (m->n_tool_calls && m->tool_calls) {
        yyjson_mut_val *tc = yyjson_mut_arr(doc);
        for (size_t i = 0; i < m->n_tool_calls; i++) {
            yyjson_mut_val *o = yyjson_mut_obj(doc);
            yyjson_mut_obj_add_strcpy(doc, o, "id",
                m->tool_calls[i].id ? m->tool_calls[i].id : "");
            yyjson_mut_obj_add_strcpy(doc, o, "name",
                m->tool_calls[i].name ? m->tool_calls[i].name : "");
            yyjson_mut_obj_add_strcpy(doc, o, "arguments",
                m->tool_calls[i].arguments ? m->tool_calls[i].arguments : "");
            yyjson_mut_arr_append(tc, o);
        }
        yyjson_mut_obj_add_val(doc, root, "tool_calls", tc);
    }
}

int ckpt_save(const char *path, const CkptMessages *c) {
    if (!path || !c) return -1;
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof(tmp), "%.900s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) return -1;
    int rc = -1;
    for (size_t i = 0; i < c->n; i++) {
        yyjson_mut_doc *doc = yyjson_mut_doc_new(NULL);
        if (!doc) goto out;
        yyjson_mut_val *root = yyjson_mut_obj(doc);
        yyjson_mut_doc_set_root(doc, root);
        msg_to_json(doc, root, &c->msgs[i]);
        const char *line = yyjson_mut_write(doc, 0, NULL);
        if (!line) { yyjson_mut_doc_free(doc); goto out; }
        size_t len = strlen(line);
        int ok = (fwrite(line, 1, len, f) == len) &&
                 (fputc('\n', f) == '\n');
        free((void *)line);
        yyjson_mut_doc_free(doc);
        if (!ok) goto out;
    }
    if (fflush(f) != 0) goto out;
    int close_rc = fclose(f);
    f = NULL; /* closed either way — NULL f first so the out path can't double-close */
    if (close_rc != 0) goto out;
    if (rename(tmp, path) != 0) goto out;
    rc = 0;
out:
    if (rc != 0) {
        if (f) fclose(f); /* guarded: f is NULL on every path that already closed it */
        unlink(tmp);
    }
    return rc;
}

/* Serialize one message to a messages.jsonl LINE (compact JSON + '\n') using
 * the SAME msg_to_json the whole-file writer uses, so appending and rewriting
 * produce byte-identical lines (no format drift between the two writers).
 * Returns a malloc'd NUL-terminated line (caller frees), or NULL on OOM. */
static char *msg_to_line(const LlmMsg *m) {
    yyjson_mut_doc *doc = yyjson_mut_doc_new(NULL);
    if (!doc) return NULL;
    yyjson_mut_val *root = yyjson_mut_obj(doc);
    yyjson_mut_doc_set_root(doc, root);
    msg_to_json(doc, root, m);
    const char *line = yyjson_mut_write(doc, YYJSON_WRITE_NEWLINE_AT_END, NULL);
    char *out = line ? strdup(line) : NULL; /* doc owns `line`; outlive it */
    free((void *)line);
    yyjson_mut_doc_free(doc);
    return out;
}

int ckpt_append_line(const char *path, const LlmMsg *m) {
    if (!path || !path[0] || !m) return -1;
    char *line = msg_to_line(m);
    if (!line) return -1;
    size_t len = strlen(line);

    /* O_APPEND + ONE write() of the whole line: concurrent writers stay
     * line-atomic and a crash mid-flush can only leave a PREFIX of the line,
     * which ckpt_load skips fail-open. */
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) { free(line); return -1; }
    int rc = 0;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, line + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            rc = -1;
            break;
        }
        off += (size_t)n;
    }
    /* fsync BEFORE returning: the caller may die (the rebuild) on the very next
     * statement, and the resume story requires this line to be on disk by then. */
    if (rc == 0 && fsync(fd) != 0) rc = -1;
    if (close(fd) != 0) rc = -1;
    free(line);
    return rc;
}

/* Parse one already-parsed JSON object into a message (deep copies, capped).
 * Returns 0/-1. */
static int msg_from_json(yyjson_val *obj, LlmMsg *out) {
    memset(out, 0, sizeof *out);
    yyjson_val *role = yyjson_obj_get(obj, "role");
    if (!role || !yyjson_is_str(role))
        role = yyjson_obj_get(obj, "type");
    if (!role || !yyjson_is_str(role)) return -1;

    yyjson_val *content = yyjson_obj_get(obj, "content");
    char *content_s = dup_capped(yyjson_is_str(content)
                                     ? yyjson_get_str(content)
                                     : "",
                                 CKPT_FIELD_CAP);
    char *role_s = dup_capped(yyjson_get_str(role), CKPT_FIELD_CAP);
    char *tcid_s = NULL;
    yyjson_val *tcid = yyjson_obj_get(obj, "tool_call_id");
    if (tcid && yyjson_is_str(tcid))
        tcid_s = dup_capped(yyjson_get_str(tcid), CKPT_FIELD_CAP);
    if (!role_s || !content_s || (tcid && !tcid_s)) {
        free(role_s); free(content_s); free(tcid_s);
        return -1;
    }
    out->role = role_s;
    out->content = content_s;
    out->content_len = strlen(content_s);
    out->tool_call_id = tcid_s;

    yyjson_val *tc = yyjson_obj_get(obj, "tool_calls");
    if (tc && yyjson_is_arr(tc)) {
        size_t n = yyjson_arr_size(tc);
        out->tool_calls = (LlmToolCall *)calloc(n, sizeof(LlmToolCall));
        if (!out->tool_calls) { msg_free(out); return -1; }
        size_t i = 0, max;
        yyjson_val *it;
        yyjson_arr_foreach(tc, i, max, it) {
            if (!yyjson_is_obj(it)) continue; /* skip a malformed entry */
            yyjson_val *id = yyjson_obj_get(it, "id");
            yyjson_val *name = yyjson_obj_get(it, "name");
            yyjson_val *args = yyjson_obj_get(it, "arguments");
            char *id_s = dup_capped(yyjson_is_str(id) ? yyjson_get_str(id) : "",
                                    CKPT_FIELD_CAP);
            char *name_s = dup_capped(yyjson_is_str(name)
                                          ? yyjson_get_str(name)
                                          : "",
                                      CKPT_FIELD_CAP);
            char *args_s = dup_capped(yyjson_is_str(args)
                                          ? yyjson_get_str(args)
                                          : "",
                                      AGENT_ARGS_CAP);
            if (!id_s || !name_s || !args_s) {
                free(id_s); free(name_s); free(args_s);
                msg_free(out);
                return -1;
            }
            out->tool_calls[out->n_tool_calls].id = id_s;
            out->tool_calls[out->n_tool_calls].name = name_s;
            out->tool_calls[out->n_tool_calls].arguments = args_s;
            out->tool_calls[out->n_tool_calls].arguments_len = strlen(args_s);
            out->n_tool_calls++;
        }
    }
    return 0;
}

int ckpt_load(const char *path, CkptMessages *out) {
    if (out) ckpt_messages_init(out);
    if (!path || !out) return -1;
    FILE *f = fopen(path, "rb");
    if (!f) return -1;

    /* Heap-allocate the read buffer: CKPT_LINE_CAP (4 MiB) on the stack is a
     * latent stack-overflow footgun if this is ever called from a thread with
     * a small stack (e.g. an in-process resume path). Allocate once around the
     * loop so memory stays bounded on a huge line without smashing the stack. */
    char *buf = (char *)malloc(CKPT_LINE_CAP + 1);
    if (!buf) { fclose(f); return -1; }
    int rc = 0;
    while (fgets(buf, CKPT_LINE_CAP + 1, f) != NULL) {
        size_t len = strlen(buf);
        /* Check if line may exceed cap: fgets filled the buffer without finding '\n'. */
        if (len == CKPT_LINE_CAP && buf[CKPT_LINE_CAP - 1] != '\n') {
            int ch = fgetc(f);
            if (ch == '\n') {
                /* Line is exactly CKPT_LINE_CAP+1 bytes (CKPT_LINE_CAP content + '\n').
                 * This exceeds our cap of CKPT_LINE_CAP bytes for a line. Skip it. */
                continue;
            } else if (ch != EOF) {
                /* Line is longer than CKPT_LINE_CAP+1 bytes. Drain and skip. */
                while (ch != EOF && ch != '\n') {
                    ch = fgetc(f);
                }
                continue; /* skip oversized line (FAIL-OPEN) */
            }
            /* ch == EOF: line is exactly CKPT_LINE_CAP bytes at end of file (no '\n').
             * This is at our cap, so we accept it. */
        }
        /* Trim trailing newline if present. */
        if (len > 0 && buf[len - 1] == '\n') {
            buf[len - 1] = '\0';
            len--;
        }
        /* Skip blank lines. */
        char *s = buf;
        while (*s && (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n')) s++;
        if (!*s) continue;
        yyjson_doc *doc = yyjson_read(s, len - (size_t)(s - buf), 0);
        if (!doc) continue; /* FAIL-OPEN: skip unparseable line */
        yyjson_val *root = yyjson_doc_get_root(doc);
        if (yyjson_is_obj(root)) {
            LlmMsg m;
            if (msg_from_json(root, &m) == 0) {
                if (ckpt_append(out, &m) != 0) {
                    msg_free(&m);
                    yyjson_doc_free(doc);
                    rc = -1;
                    break;
                }
            }
            msg_free(&m);
        }
        yyjson_doc_free(doc);
    }
    free(buf);
    fclose(f);
    return rc;
}

/* ── compaction ─────────────────────────────────────────────────────────── */

/* Predicate: is this a system message? */
static int is_system(const LlmMsg *m) {
    return m && m->role && strcmp(m->role, "system") == 0;
}

size_t ckpt_compact(CkptMessages *c, size_t max_msgs) {
    if (!c) return 0;
    if (c->n <= max_msgs) return c->n;

    size_t n_sys = 0;
    for (size_t i = 0; i < c->n; i++)
        if (is_system(&c->msgs[i])) n_sys++;
    size_t total_non_sys = c->n - n_sys;

    /* Keep the newest (max_msgs - 1 - n_sys) non-system messages, reserving
     * one slot for the prepended summary marker and all slots for the system
     * messages (never dropped). */
    size_t kept_non_sys;
    if (max_msgs > n_sys + 1) {
        size_t want = max_msgs - n_sys - 1;
        kept_non_sys = want < total_non_sys ? want : total_non_sys;
    } else {
        kept_non_sys = 0; /* all room taken by systems + marker */
    }

    size_t dropped_non_sys = total_non_sys - kept_non_sys;

    /* Build the compacted list: [summary, systems..., newest non-systems...]. */
    size_t new_n = 1 + n_sys + kept_non_sys;
    LlmMsg *nm = (LlmMsg *)calloc(new_n ? new_n : 1, sizeof(LlmMsg));
    if (!nm) return c->n; /* OOM: leave unchanged rather than corrupt */

    /* Summary marker at index 0. */
    nm[0].role = strdup("system");
    nm[0].content = (char *)malloc(96);
    if (!nm[0].role || !nm[0].content) {
        for (size_t i = 0; i < new_n; i++) msg_free(&nm[i]);
        free(nm);
        return c->n;
    }
    snprintf((char *)nm[0].content, 96, "[compacted: dropped %zu earlier messages]",
             dropped_non_sys);
    nm[0].content_len = strlen(nm[0].content);

    size_t sys_i = 1, nonsys_i = 1 + n_sys;
    size_t non_sys_seen = 0;
    for (size_t i = 0; i < c->n; i++) {
        const LlmMsg *m = &c->msgs[i];
        if (is_system(m)) {
            if (msg_copy(&nm[sys_i], m) != 0) goto compact_fail;
            sys_i++;
        } else {
            non_sys_seen++;
            if (non_sys_seen > total_non_sys - kept_non_sys) {
                if (msg_copy(&nm[nonsys_i], m) != 0) goto compact_fail;
                nonsys_i++;
            }
        }
    }

    ckpt_messages_free(c);
    c->msgs = nm;
    c->n = new_n;
    c->cap = new_n;
    return c->n;

compact_fail:
    for (size_t i = 0; i < new_n; i++) msg_free(&nm[i]);
    free(nm);
    return c->n; /* unchanged on OOM */
}

/* ── run-state helpers (thin wrappers over the runstore DAFSA) ──────────── */

int ckpt_run_open(RunStore *rs, const char *dir, char *err, size_t errcap) {
    if (!rs || !dir) return -1;
    return runstore_open(rs, dir, err, errcap);
}

void ckpt_run_close(RunStore *rs) {
    if (rs) runstore_close(rs);
}

int ckpt_run_add(RunStore *rs, const char *run_id, const char *agent,
                 char *err, size_t errcap) {
    if (!rs || !run_id) return -1;
    AgentRun r;
    memset(&r, 0, sizeof r);
    r.run_id = (char *)run_id;
    r.agent = (char *)(agent ? agent : "");
    r.slug = "ckpt";
    r.instructions = "";
    r.cwd = "/";
    return runstore_add(rs, &r, err, errcap);
}

int ckpt_run_set_status(RunStore *rs, const char *run_id, const char *status) {
    if (!rs || !run_id) return -1;
    return runstore_set_status(rs, run_id, status);
}

int ckpt_run_set_session_id(RunStore *rs, const char *run_id, const char *sid) {
    if (!rs || !run_id) return -1;
    return runstore_set_session_id(rs, run_id, sid);
}

int ckpt_run_set_last_turn_at(RunStore *rs, const char *run_id, const char *iso) {
    if (!rs || !run_id) return -1;
    return runstore_set_last_turn_at(rs, run_id, iso);
}
