/* src/agent/mcp_client.c — MCP stdio CLIENT for arbitrary tool servers (S5).
 *
 * Generalizes session.c's session_jing_memory_tool_call into a general MCP
 * stdio client.  The idioms (fork+execvpe spawn with scrubbed env, bounded
 * newline read with poll()+timeout, id-matched response skip, waitpid+SIGKILL
 * teardown, join content text blocks) are copied from src/session.c
 * (session_jing_memory_tool_call ~826-935 + helpers).  See mcp_client.h for the
 * public API and the memory-safety/security rules.
 */
#define _GNU_SOURCE  /* execvpe */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <poll.h>

#include "mcp_client.h"
#include "runner.h"
#include "secrets.h"
#include "yyjson.h"

/* Protocol version must match what mcp_stdio.h / session.c use. */
#include "mcp_stdio.h"

/* Default PATH for the PATH-only child env (mirrors session.c's default). */
#define MCP_PATH_DEFAULT "/home/arch/.local/bin:/usr/local/bin:/usr/bin"

/* ── helpers (copied from session.c) ───────────────────────────────────── */

static double now_mono(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* Growable byte buffer accumulating partial reads. */
typedef struct {
    char *data;
    size_t len;
    size_t cap;
} ReadBuf;

static void rb_init(ReadBuf *b) { b->data = NULL; b->len = 0; b->cap = 0; }

static int rb_append(ReadBuf *b, const char *bytes, size_t n) {
    if (b->len + n + 1 > b->cap) {
        size_t ncap = b->cap ? b->cap * 2 : 4096;
        while (ncap < b->len + n + 1) ncap *= 2;
        char *nd = realloc(b->data, ncap);
        if (!nd) return -1;
        b->data = nd;
        b->cap = ncap;
    }
    memcpy(b->data + b->len, bytes, n);
    b->len += n;
    b->data[b->len] = '\0';
    return 0;
}

static void rb_free(ReadBuf *b) {
    free(b->data);
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

static int send_all(int fd, const char *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, data + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        off += (size_t)n;
    }
    return 0;
}

/* A spawned MCP subprocess (mirror of session.c's MemProc). */
typedef struct {
    pid_t pid;
    int in_fd;   /* child stdin (we write requests) */
    int out_fd;  /* child stdout (we read responses) */
} MCPProc;

static double mcp_timeout_s(void) {
    const char *e = getenv("FX_MCP_TIMEOUT_S");
    if (e && *e) {
        char *end = NULL;
        double v = strtod(e, &end);
        if (end && *end == '\0' && v > 0) return v;
    }
    return MCP_CLIENT_RPC_TIMEOUT_S;
}

/* Return the effective timeout: the per-server value if > 0, else the global
 * default (env FX_MCP_TIMEOUT_S / MCP_CLIENT_RPC_TIMEOUT_S). */
static double mcp_eff_timeout(double specific) {
    return specific > 0 ? specific : mcp_timeout_s();
}

/* Read one newline-delimited line off the raw fd, accumulating partial bytes
 * in *b across calls (session.c's read_one_line, with a line-size cap).  Returns
 * 0 + malloc'd *line_out (no trailing newline), or -1 on timeout / EOF / error /
 * oversize line. */
static int read_one_line(MCPProc *p, ReadBuf *b, double deadline, char **line_out) {
    for (;;) {
        char *nl = (b->data && b->len) ? memchr(b->data, '\n', b->len) : NULL;
        if (nl) {
            size_t ll = (size_t)(nl - b->data);
            char *line = malloc(ll + 1);
            if (!line) return -1;
            memcpy(line, b->data, ll);
            line[ll] = '\0';
            size_t rest = b->len - (ll + 1);
            memmove(b->data, nl + 1, rest);
            b->len = rest;
            if (b->data) b->data[b->len] = '\0';
            *line_out = line;
            return 0;
        }
        if (b->len > MCP_MAX_LINE) return -1; /* line exceeds cap */
        double now = now_mono();
        if (now >= deadline) return -1;
        struct pollfd pfd = { p->out_fd, POLLIN, 0 };
        int ms = (int)((deadline - now) * 1000.0);
        if (ms < 1) ms = 1;
        int pr = poll(&pfd, 1, ms);
        if (pr < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (pr == 0) return -1; /* timeout */
        char tmp[4096];
        ssize_t n = read(p->out_fd, tmp, sizeof(tmp));
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1; /* child closed stdout */
        if (rb_append(b, tmp, (size_t)n) != 0) return -1;
    }
}

/* Read messages until the one with id == expected_id; skip notifications
 * (session.c's read_response). */
static int read_response(MCPProc *p, ReadBuf *b, int expected_id, double deadline,
                         yyjson_doc **out) {
    for (;;) {
        char *line = NULL;
        if (read_one_line(p, b, deadline, &line) != 0) return -1;
        yyjson_doc *doc = yyjson_read(line, strlen(line), 0);
        free(line);
        if (!doc) return -1; /* malformed JSON-RPC line -> fail */
        yyjson_val *root = yyjson_doc_get_root(doc);
        int id = -1;
        yyjson_val *idv = yyjson_obj_get(root, "id");
        if (idv && yyjson_is_int(idv)) id = (int)yyjson_get_int(idv);
        if (id == expected_id) {
            *out = doc;
            return 0;
        }
        yyjson_doc_free(doc); /* notification / unrelated id: skip */
    }
}

static void proc_teardown(MCPProc *p) {
    if (p->in_fd >= 0) { close(p->in_fd); p->in_fd = -1; }
    if (p->out_fd >= 0) { close(p->out_fd); p->out_fd = -1; }
    if (p->pid > 0) {
        int status;
        double dl = now_mono() + 2.0;
        for (;;) {
            pid_t r = waitpid(p->pid, &status, WNOHANG);
            if (r == p->pid) break;
            if (r < 0) break;
            if (now_mono() >= dl) {
                kill(p->pid, SIGKILL);
                waitpid(p->pid, &status, 0);
                break;
            }
            struct timespec ts = { 0, 20000000 };
            nanosleep(&ts, NULL);
        }
        p->pid = -1;
    }
}

/* Join the text content blocks of a tools/call result (str or list) — a copy
 * of session.c's join_text.  Returns a malloc'd string ("" when empty/NULL). */
static char *join_text(yyjson_val *result) {
    yyjson_val *content = yyjson_obj_get(result, "content");
    ReadBuf b;
    rb_init(&b);
    if (yyjson_is_arr(content)) {
        yyjson_val *it;
        size_t i, max;
        yyjson_arr_foreach(content, i, max, it) {
            const char *text = NULL;
            if (yyjson_is_obj(it)) {
                yyjson_val *ty = yyjson_obj_get(it, "type");
                if (ty && yyjson_is_str(ty) && strcmp(yyjson_get_str(ty), "text") == 0) {
                    yyjson_val *tx = yyjson_obj_get(it, "text");
                    if (tx && yyjson_is_str(tx)) text = yyjson_get_str(tx);
                }
            } else if (yyjson_is_str(it)) {
                text = yyjson_get_str(it);
            }
            if (!text) continue;
            if (b.len > 0) rb_append(&b, "\n", 1);
            rb_append(&b, text, strlen(text));
        }
    } else if (yyjson_is_str(content)) {
        rb_append(&b, yyjson_get_str(content), strlen(yyjson_get_str(content)));
    }
    if (!b.data) {
        char *s = malloc(1);
        if (s) s[0] = '\0';
        rb_free(&b);
        return s;
    }
    b.data[b.len] = '\0';
    return b.data;
}

/* Build the child envp: secrets_build_child_env(scope) when scope is a known
 * scope, else a minimal PATH-only envp.  Then overlay srv->env entries (they
 * win over any same-key base entry).  Returns a malloc'd NULL-terminated
 * array of malloc'd "K=V" strings (free with secrets_envp_free).  NULL on any
 * allocation failure / unknown scope. */
static char **build_child_env(const char *scope, const McpToolServer *srv) {
    char **base_envp = NULL;
    if (scope && *scope) {
        char err[256];
        base_envp = secrets_build_child_env(scope, err, sizeof(err));
        if (!base_envp) return NULL;
    } else {
        const char *path = getenv("PATH");
        if (!path || !*path) path = MCP_PATH_DEFAULT;
        size_t plen = strlen("PATH=") + strlen(path) + 1;
        char *pathbuf = malloc(plen);
        if (!pathbuf) return NULL;
        snprintf(pathbuf, plen, "PATH=%s", path);
        base_envp = malloc(sizeof(char *) * 2);
        if (!base_envp) { free(pathbuf); return NULL; }
        base_envp[0] = pathbuf;
        base_envp[1] = NULL;
    }

    /* Count base entries */
    size_t base_count = 0;
    if (base_envp) {
        for (size_t i = 0; base_envp[i]; i++) base_count++;
    }

    /* If no server env to overlay, return base as-is */
    if (!srv || !srv->env || srv->n_env == 0) {
        return base_envp;
    }

    /* Allocate new array: base_count + srv->n_env + 1 (NULL terminator) */
    size_t total = base_count + srv->n_env + 1;
    char **envp = malloc(total * sizeof(char *));
    if (!envp) { secrets_envp_free(base_envp); return NULL; }

    /* Copy server env entries FIRST so they precede any same-key base entry:
     * the child resolves duplicate keys via getenv() which returns the FIRST
     * match, so placing the overlay before the base makes the server's value
     * win (a naive "last-match-wins" assumption is wrong for getenv). */
    for (size_t i = 0; i < srv->n_env; i++) {
        /* Duplicate the server's env string (it's owned by the server struct) */
        envp[i] = strdup(srv->env[i]);
        if (!envp[i]) {
            /* On OOM, free everything we've built so far */
            for (size_t j = 0; j < i; j++) free(envp[j]);
            free(envp);
            secrets_envp_free(base_envp);
            return NULL;
        }
    }

    /* Copy base entries after (duplicate each string) */
    for (size_t i = 0; i < base_count; i++) {
        envp[srv->n_env + i] = strdup(base_envp[i]);
        if (!envp[srv->n_env + i]) {
            /* On OOM, free everything we've built so far */
            for (size_t j = 0; j < srv->n_env + i; j++) free(envp[j]);
            free(envp);
            secrets_envp_free(base_envp);
            return NULL;
        }
    }
    secrets_envp_free(base_envp);

    envp[srv->n_env + base_count] = NULL;

    return envp;
}

/* Spawn the server: argv = command + args + NULL; envp from build_child_env.
 * Mirror of session.c's mem_proc_spawn generalized to a variable argv. */
static int proc_spawn(const char *command, char **args, size_t n_args,
                      char *envp[], MCPProc *p) {
    int inpipe[2], outpipe[2];
    if (pipe(inpipe) != 0) return -1;
    if (pipe(outpipe) != 0) {
        close(inpipe[0]);
        close(inpipe[1]);
        return -1;
    }
    int devnull = open("/dev/null", O_WRONLY);
    pid_t pid = fork();
    if (pid < 0) {
        close(inpipe[0]); close(inpipe[1]);
        close(outpipe[0]); close(outpipe[1]);
        if (devnull >= 0) close(devnull);
        return -1;
    }
    if (pid == 0) {
        dup2(inpipe[0], 0);
        dup2(outpipe[1], 1);
        if (devnull >= 0) dup2(devnull, 2);
        close(inpipe[0]); close(inpipe[1]);
        close(outpipe[0]); close(outpipe[1]);
        if (devnull >= 0) close(devnull);
        char **argv = malloc(sizeof(char *) * (n_args + 2));
        if (!argv) _exit(127);
        argv[0] = (char *)command;
        for (size_t i = 0; i < n_args; i++) argv[i + 1] = args[i];
        argv[n_args + 1] = NULL;
        execvpe(command, argv, envp);
        _exit(127);
    }
    close(inpipe[0]);
    close(outpipe[1]);
    if (devnull >= 0) close(devnull);
    p->pid = pid;
    p->in_fd = inpipe[1];
    p->out_fd = outpipe[0];
    return 0;
}

/* Speak the MCP handshake: initialize (id 1) -> notifications/initialized.
 * Returns 0 on success. */
static int do_handshake(MCPProc *p, ReadBuf *b, double timeout_s) {
    const char *init =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{"
        "\"protocolVersion\":\"" MCP_PROTOCOL_VERSION "\",\"capabilities\":{},"
        "\"clientInfo\":{\"name\":\"fx-agent\",\"version\":\"0.1.0\"}}}\n";
    if (send_all(p->in_fd, init, strlen(init)) != 0) return -1;
    yyjson_doc *init_doc = NULL;
    if (read_response(p, b, 1, now_mono() + timeout_s, &init_doc) != 0) return -1;
    yyjson_val *init_root = yyjson_doc_get_root(init_doc);
    yyjson_val *r = yyjson_obj_get(init_root, "result");
    yyjson_val *e = yyjson_obj_get(init_root, "error");
    bool init_ok = (r != NULL && (!e || yyjson_is_null(e)));
    yyjson_doc_free(init_doc);
    if (!init_ok) return -1;

    const char *ni = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}\n";
    if (send_all(p->in_fd, ni, strlen(ni)) != 0) return -1;
    return 0;
}

/* ── public API ────────────────────────────────────────────────────────── */

int mcp_tools_call(const McpToolServer *srv, const char *tool_name,
                   const char *args_json, char **out_result_text) {
    if (!srv || !srv->command) return -1;
    if (out_result_text) *out_result_text = NULL;

    /* tool_name MUST pass validate_identifier BEFORE it enters a JSON-RPC
     * frame (and before any subprocess is spawned). */
    RunnerError verr;
    if (validate_identifier(tool_name, "tool_name", &verr) != 0) return -1;

    /* args_json is already JSON from the model (attacker-shaped but opaque).
     * Length-cap it; pass it verbatim.  Reject embedded CR/LF so it cannot
     * split the newline-delimited JSON-RPC frame into a malformed line. */
    size_t args_len = args_json ? strlen(args_json) : 0;
    if (args_len > MCP_ARGS_CAP) return -1;
    if (args_json && (memchr(args_json, '\n', args_len) != NULL ||
                      memchr(args_json, '\r', args_len) != NULL))
        return -1;

    char **envp = build_child_env(srv->scope, srv);
    if (!envp) return -1;

    double handshake_timeout = mcp_eff_timeout(srv->startup_timeout_s);
    double call_timeout = mcp_eff_timeout(srv->tool_timeout_s);

    MCPProc p = { -1, -1, -1 };
    if (proc_spawn(srv->command, srv->args, srv->n_args, envp, &p) != 0) {
        secrets_envp_free(envp);
        return -1;
    }
    secrets_envp_free(envp);

    ReadBuf b;
    rb_init(&b);
    char *result = NULL;

    if (do_handshake(&p, &b, handshake_timeout) != 0) goto done;

    /* Frame: name is validated charset (no JSON escaping needed); args_json is
     * verbatim JSON.  Buffer sized for the capped args + headroom. */
    size_t reqcap = MCP_ARGS_CAP + 4096;
    char *req = malloc(reqcap);
    if (!req) goto done;
    int rn = snprintf(req, reqcap,
                      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\","
                      "\"params\":{\"name\":\"%s\",\"arguments\":%s}}\n",
                      tool_name, args_json ? args_json : "{}");
    if (rn < 0 || (size_t)rn >= reqcap) { free(req); goto done; }
    if (send_all(p.in_fd, req, (size_t)rn) != 0) { free(req); goto done; }
    free(req);

    yyjson_doc *reply_doc = NULL;
    if (read_response(&p, &b, 2, now_mono() + call_timeout, &reply_doc) != 0) goto done;
    yyjson_val *reply_root = yyjson_doc_get_root(reply_doc);
    yyjson_val *err = yyjson_obj_get(reply_root, "error");
    if (err && !yyjson_is_null(err)) { yyjson_doc_free(reply_doc); goto done; }
    yyjson_val *res = yyjson_obj_get(reply_root, "result");
    if (!res || !yyjson_is_obj(res)) { yyjson_doc_free(reply_doc); goto done; }
    yyjson_val *isErr = yyjson_obj_get(res, "isError");
    if (isErr && yyjson_is_bool(isErr) && yyjson_get_bool(isErr)) {
        yyjson_doc_free(reply_doc);
        goto done;
    }
    result = join_text(res);
    yyjson_doc_free(reply_doc);

done:
    rb_free(&b);
    proc_teardown(&p);
    if (!result) return -1;
    if (out_result_text) *out_result_text = result;
    else free(result);
    return 0;
}

int mcp_tools_list(const McpToolServer *srv, McpTool **out_tools, size_t *out_n) {
    if (!srv || !srv->command) return -1;
    if (out_tools) *out_tools = NULL;
    if (out_n) *out_n = 0;

    char **envp = build_child_env(srv->scope, srv);
    if (!envp) return -1;

    double handshake_timeout = mcp_eff_timeout(srv->startup_timeout_s);
    double list_timeout = mcp_eff_timeout(srv->tool_timeout_s);

    MCPProc p = { -1, -1, -1 };
    if (proc_spawn(srv->command, srv->args, srv->n_args, envp, &p) != 0) {
        secrets_envp_free(envp);
        return -1;
    }
    secrets_envp_free(envp);

    ReadBuf b;
    rb_init(&b);
    McpTool *tools = NULL;
    size_t n = 0;
    int failed = 0;

    if (do_handshake(&p, &b, handshake_timeout) != 0) { failed = 1; goto done; }

    const char *tl = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}\n";
    if (send_all(p.in_fd, tl, strlen(tl)) != 0) { failed = 1; goto done; }

    yyjson_doc *reply_doc = NULL;
    if (read_response(&p, &b, 2, now_mono() + list_timeout, &reply_doc) != 0) { failed = 1; goto done; }
    yyjson_val *root = yyjson_doc_get_root(reply_doc);
    yyjson_val *err = yyjson_obj_get(root, "error");
    if (err && !yyjson_is_null(err)) { yyjson_doc_free(reply_doc); failed = 1; goto done; }
    yyjson_val *res = yyjson_obj_get(root, "result");
    yyjson_val *arr = res ? yyjson_obj_get(res, "tools") : NULL;
    if (!arr || !yyjson_is_arr(arr)) { yyjson_doc_free(reply_doc); failed = 1; goto done; }
    size_t cnt = yyjson_arr_size(arr);
    if (cnt > 0) {
        tools = malloc(sizeof(McpTool) * cnt);
        if (!tools) { yyjson_doc_free(reply_doc); failed = 1; goto done; }
        memset(tools, 0, sizeof(McpTool) * cnt);
        yyjson_val *it;
        size_t i, max;
        yyjson_arr_foreach(arr, i, max, it) {
            const char *nm = NULL, *desc = NULL;
            if (yyjson_is_obj(it)) {
                yyjson_val *nv = yyjson_obj_get(it, "name");
                yyjson_val *dv = yyjson_obj_get(it, "description");
                if (nv && yyjson_is_str(nv)) nm = yyjson_get_str(nv);
                if (dv && yyjson_is_str(dv)) desc = yyjson_get_str(dv);
            }
            if (!nm) nm = "";
            if (!desc) desc = "";
            tools[i].name = malloc(strlen(nm) + 1);
            tools[i].description = malloc(strlen(desc) + 1);
            if (!tools[i].name || !tools[i].description) {
                if (tools[i].name) { free((void *)tools[i].name); tools[i].name = NULL; }
                if (tools[i].description) { free((void *)tools[i].description); tools[i].description = NULL; }
                /* roll back this entry and bail */
                yyjson_doc_free(reply_doc);
                mcp_tools_free(tools, i);
                tools = NULL;
                failed = 1;
                goto done;
            }
            memcpy((void *)tools[i].name, nm, strlen(nm) + 1);
            memcpy((void *)tools[i].description, desc, strlen(desc) + 1);
            n++;
        }
    }
    yyjson_doc_free(reply_doc);

done:
    rb_free(&b);
    proc_teardown(&p);
    if (failed) { mcp_tools_free(tools, n); return -1; }
    if (out_tools) *out_tools = tools;
    if (out_n) *out_n = n;
    return 0;
}

void mcp_tools_free(McpTool *tools, size_t n) {
    if (!tools) return;
    for (size_t i = 0; i < n; i++) {
        free((void *)tools[i].name);
        free((void *)tools[i].description);
    }
    free(tools);
}
