/* src/llm2/outcome.c — THE OBSERVATION LOOP (see outcome.h for the why).
 *
 * Plain C + POSIX only: no yyjson, no config engine, no agent loop types.  The
 * record is a line-oriented text file, so the SAME reader (this file) can be
 * linked into the tool server that exposes the outcome to a model — one reader,
 * one meaning.
 *
 * Every parse is FAIL-OPEN (a malformed line is skipped) EXCEPT the store's
 * CURRENT version, which is FAIL-CLOSED: a verdict built on a guessed store or
 * a guessed version is worse than no verdict.
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "outcome.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/* ── small helpers ──────────────────────────────────────────────────────── */

/* Join dir + "/" + name into out.  Returns the length, or -1 (too long). */
static int path_join(char *out, size_t cap, const char *dir, const char *name) {
    if (!dir || !*dir) return -1;
    int n = snprintf(out, cap, "%s/%s", dir, name);
    if (n < 0 || (size_t)n >= cap) return -1;
    return n;
}

/* Copy src into dst[cap], NUL-terminated, truncated at cap-1.  NULL -> "". */
static void copy_str(char *dst, size_t cap, const char *src) {
    if (!cap) return;
    if (!src) src = "";
    size_t n = strlen(src);
    if (n > cap - 1) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

/* Copy src into dst[cap] with every CR/LF replaced by '?'.  The record is
 * LINE-oriented, so a newline inside a field — the config path is
 * model-supplied, and a session/run name is only as trustworthy as the thing
 * that made it — would FORGE a whole extra record line (e.g. a `done` line for
 * a task the caller wants silenced, or a `result` line naming a version read
 * via fx_outcome).  Every field written is passed through here. */
static void one_line(char *dst, size_t cap, const char *src, const char *dflt) {
    if (!cap) return;
    if (!src || !*src) src = dflt;
    size_t i = 0;
    for (; src[i] && i < cap - 1; i++) {
        char c = src[i];
        dst[i] = (c == '\n' || c == '\r') ? '?' : c;
    }
    dst[i] = '\0';
}

/* fsync a directory so a file CREATED inside it survives a reboot: the file's
 * own fsync makes its contents durable, its new directory entry needs this. */
static void fsync_dir(const char *dir) {
    if (!dir || !*dir) return;
    int fd = open(dir, O_RDONLY | O_DIRECTORY);
    if (fd < 0) return;
    (void)fsync(fd);
    close(fd);
}

/* ── the task identity ──────────────────────────────────────────────────── */

void fx_outcome_task_id(const char *agent, const char *prompt, char *out, size_t cap) {
    unsigned long long h = 1469598103934665603ULL; /* FNV-1a-64 offset basis */
    const char *parts[3];
    parts[0] = agent ? agent : "";
    parts[1] = "\x1f"; /* a byte neither a validated identifier nor a prompt uses */
    parts[2] = prompt ? prompt : "";
    for (int i = 0; i < 3; i++) {
        for (const unsigned char *p = (const unsigned char *)parts[i]; *p; p++) {
            h ^= (unsigned long long)*p;
            h *= 1099511628211ULL; /* FNV prime */
        }
    }
    if (cap) snprintf(out, cap, "%016llx", h);
}

/* ── the durable record ─────────────────────────────────────────────────── */

/* The record file for a data dir.  Returns 0 and fills `out`. */
static int record_path(char *out, size_t cap, const char *data_dir) {
    if (path_join(out, cap, data_dir, "attempts.jsonl") < 0) return -1;
    return 0;
}

/* The LAST field of a record line (the config path, or the agent name for an
 * `agent` binding line): everything after the 6th whitespace-delimited token,
 * without its CR/LF.  A "-" means "absent" and is returned as "". */
static void tail_field(const char *line, char *out, size_t cap) {
    if (cap) out[0] = '\0';
    if (!line || !cap) return;
    const char *p = line;
    int fields = 0;
    while (fields < 6 && *p) {
        while (*p == ' ' || *p == '\t') p++;
        while (*p && *p != ' ' && *p != '\t' && *p != '\n') p++;
        fields++;
    }
    while (*p == ' ' || *p == '\t') p++;
    size_t cl = strcspn(p, "\r\n");
    if (cl > cap - 1) cl = cap - 1;
    memcpy(out, p, cl);
    out[cl] = '\0';
    if (strcmp(out, "-") == 0) out[0] = '\0';
}

/* Parse the six fixed fields of a record line.  Returns 1 and fills the
 * out-params when the line is a complete, newline-TERMINATED record for a
 * 6-field record; 0 otherwise (caller skips: FAIL-OPEN). */
static int record_fields(const char *line, unsigned long *epoch, char *task,
                         size_t taskcap, char *step, size_t stepcap,
                         char *session, size_t sesscap, char *run, size_t runcap,
                         unsigned long *version) {
    if (!line || !strchr(line, '\n')) return 0;
    char rt[FX_OUTCOME_TASK_CAP] = {0}, st[16] = {0}, se[264] = {0}, ru[64] = {0};
    unsigned long ep = 0, v = 0;
    if (sscanf(line, "%lu %16s %15s %255s %63s %lu", &ep, rt, st, se, ru, &v) != 6)
        return 0;
    if (epoch) *epoch = ep;
    if (version) *version = v;
    copy_str(task, taskcap, rt);
    copy_str(step, stepcap, st);
    copy_str(session, sesscap, se);
    copy_str(run, runcap, ru);
    return 1;
}

int fx_outcome_record(const char *data_dir, const char *task, const char *step,
                      const char *session, const char *run, unsigned long version,
                      const char *config) {
    if (!data_dir || !*data_dir || !task || !*task || !step || !*step) return -1;
    char path[PATH_MAX];
    if (record_path(path, sizeof path, data_dir) < 0) return -1;

    /* The config path is the LAST field (it is caller-supplied and may contain
     * spaces); every other field is a single whitespace-free token.  A missing
     * config is written as "-" so the field count never varies.  EVERY field
     * goes through one_line() (SF6): the record is line-oriented, so a CR/LF in
     * a caller-shaped field would forge an extra record line. */
    char stask[FX_OUTCOME_TASK_CAP], sstep[16];
    /* The session is a path component: NAME_MAX (255) + NUL.  It is the SAME
     * width the reader parses it back with (`%255s`), so a record cannot
     * round-trip as a DIFFERENT session than the one written. */
    char ssess[256], srun[64], scfg[FX_OUTCOME_PATH_CAP];
    one_line(stask, sizeof stask, task, "-");
    one_line(sstep, sizeof sstep, step, "-");
    one_line(ssess, sizeof ssess, session, "-");
    one_line(srun, sizeof srun, run, "-");
    one_line(scfg, sizeof scfg, config, "-");
    char line[FX_OUTCOME_LINE_CAP];
    int n = snprintf(line, sizeof line, "%lu %s %s %s %s %lu %s\n",
                     (unsigned long)time(NULL), stask, sstep, ssess, srun,
                     version, scfg);
    if (n < 0 || (size_t)n >= sizeof line) return -1;

    /* ONE write() of the whole line: a crash mid-flush can only leave a PREFIX
     * of a line, which the reader skips (it accepts a line only when it ends
     * with a newline — see fx_outcome_record_load).  BUT a prefix left behind
     * is only HALF contained: this file is opened O_APPEND, so the NEXT record
     * would be appended straight onto the torn tail and MERGE with it into one
     * unparsable line — destroying a VALID record too (both lost -> the next
     * boot reads "nothing on record" and RUNS).  So the writer repairs the
     * tail FIRST: when the file is non-empty and its last byte is not a
     * newline, a single '\n' is written before the record, closing the torn
     * prefix as its own (skipped) line.  A crash between the two writes only
     * ever leaves a BLANK line, which the reader skips harmlessly. */
    int fd = open(path, O_RDWR | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return -1;
    int rc = 0;
    off_t sz = lseek(fd, 0, SEEK_END);
    if (sz < 0) rc = -1;
    if (rc == 0 && sz > 0) {
        char last = 0;
        ssize_t got = pread(fd, &last, 1, sz - 1);
        if (got != 1) {
            rc = -1;
        } else if (last != '\n') {
            ssize_t w = write(fd, "\n", 1);
            if (w != 1) rc = -1;
        }
    }
    size_t off = 0;
    while (rc == 0 && off < (size_t)n) {
        ssize_t w = write(fd, line + off, (size_t)n - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            rc = -1;
            break;
        }
        off += (size_t)w;
    }
    if (rc == 0 && fsync(fd) != 0) rc = -1;
    if (close(fd) != 0) rc = -1;
    /* the file is created on the first record of a boot whose data dir is on
     * the virtio disk: the DIRECTORY ENTRY must be durable too, or the whole
     * file can vanish. */
    if (rc == 0) fsync_dir(data_dir);
    return rc;
}

int fx_outcome_record_load(const char *data_dir, const char *task, FxOutcome *out) {
    if (!out) return -1;
    memset(out, 0, sizeof *out);
    if (!data_dir || !*data_dir || !task) return 0;
    copy_str(out->task, sizeof out->task, task);

    char path[PATH_MAX];
    if (record_path(path, sizeof path, data_dir) < 0) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) return 0; /* no record yet: the ordinary first-boot case */

    char line[FX_OUTCOME_LINE_CAP + 2];
    while (fgets(line, (int)sizeof line, f) != NULL) {
        /* A record line is only real if it is TERMINATED: a crash (or ENOSPC)
         * mid-write leaves a prefix, and a prefix that cuts inside a field can
         * still yield a full field set — a truncated version token parses as a
         * version, and a truncated version that matches a real bootlog line
         * would decide ACTIVATION_FAILED or ALREADY_DONE from a CORRUPT record.
         * THE BOUND OF THIS SKIP, and how it is closed: skipping is
         * conservative for a torn RESULT line (the task then has no result,
         * i.e. the UNRESOLVED branch — never a silent "done"), but it is NOT
         * conservative for a torn ATTEMPT line whose result line DID land:
         * the attempt vanished, the result was dropped for want of an attempt
         * to account, and the verdict was RUN — the re-issuing direction (the
         * hole MEASURED by the ordering review).  The DAMAGE RULE closes it:
         * a torn line whose TASK token survived the tear marks the record
         * damaged for that task, a dropped orphan result marks it too, and
         * fx_outcome_verdict refuses RUN off a damaged record.  A torn line
         * whose task token itself was cut is not attributable to any task and
         * stays a plain skip (cross-task poisoning would wedge unrelated
         * tasks forever). */
        if (!strchr(line, '\n')) {
            unsigned long tep = 0;
            char ttask[FX_OUTCOME_TASK_CAP] = {0};
            if (sscanf(line, "%lu %16s", &tep, ttask) == 2 &&
                strcmp(ttask, task) == 0)
                out->has_torn_line = 1;
            continue;
        }
        unsigned long epoch = 0, version = 0;
        char rtask[FX_OUTCOME_TASK_CAP] = {0};
        char step[16] = {0};
        char session[264] = {0};
        char run[64] = {0};
        /* 6 fields parsed; a 7th (the config, possibly with spaces) is taken
         * from the rest of the line with tail_field — tolerated absent. */
        if (!record_fields(line, &epoch, rtask, sizeof rtask, step, sizeof step,
                           session, sizeof session, run, sizeof run, &version))
            continue; /* malformed/oversized/unterminated line: FAIL-OPEN skip */
        if (strcmp(rtask, task) != 0) continue;

        /* the config field, if any: everything after the 6th token. */
        char config[FX_OUTCOME_PATH_CAP] = {0};
        tail_field(line, config, sizeof config);

        if (strcmp(step, "attempt") == 0) {
            out->has_attempt = 1;
            out->has_result = 0;
            /* A COMPLETE attempt line ends any damage recorded so far: the
             * damage rule protects exactly the claim "no attempt for this
             * task", and there now IS one the record can read.  Whatever a
             * torn or orphaned EARLIER line hid is superseded by this one
             * (damage AFTER it still marks — a torn line proves mid-write). */
            out->has_torn_line = 0;
            out->has_orphan_result = 0;
            /* A done line may only settle attempts that PRECEDE it: this
             * attempt was recorded AFTER any done seen so far, so that done
             * cannot speak for it.  Without this the loader's done was sticky
             * and POSITION-BLIND — a `done` that PREDATES a later unaccounted
             * attempt (a --resume/--reconsider run that died before its tool
             * result) still pre-empted it, and the report claimed "a LATER
             * run of this task COMPLETED", which is inverted for that record.
             * Line order is write order (the file is append-only with one
             * writer), so position is the exact ordering.
             *
             * The done is SUSPENDED, not deleted: its provenance is kept so
             * it can return to force (see the result handler below). */
            if (out->done) out->done_suspended = 1;
            out->done = 0;
            out->version = version;
            out->epoch = epoch;
            copy_str(out->session, sizeof out->session, session);
            copy_str(out->run, sizeof out->run, run);
            copy_str(out->config, sizeof out->config, config);
        } else if (strcmp(step, "result") == 0) {
            if (out->has_attempt) {
                out->has_result = 1;
                out->version = version;
                if (config[0]) copy_str(out->config, sizeof out->config, config);
                /* A done that PREDATES this attempt is back in force: the
                 * attempt this result just accounted did not come out of
                 * nowhere, and there is now no unaccounted activation left
                 * for that done to fail to settle.  A later attempt clears a
                 * done ONLY while that attempt is UNACCOUNTED — without the
                 * reinstatement, done -> attempt -> result(vN) read done=0
                 * and the C==A branch returned RUN: a FALSE RUN, re-issuing
                 * an activation for a task the record says COMPLETED (the
                 * exact failure class this unit exists to stop). */
                if (out->done_suspended) {
                    out->done = 1;
                    out->done_suspended = 0;
                }
            } else {
                /* An ORPHAN result: well-formed, terminated, naming this
                 * task — but no attempt it could account was ever read (its
                 * attempt line was torn, or never written).  Dropped for
                 * verdict purposes, but NOT silently: the record cannot be
                 * trusted to say "no attempt for this task" while it holds a
                 * result line for it, so it marks the damage rule. */
                out->has_orphan_result = 1;
            }
        } else if (strcmp(step, "done") == 0) {
            out->done = 1;
            out->done_suspended = 0; /* the newest done governs; an ordinary
                                      * done AFTER the attempt is not a
                                      * suspended one */
            /* the done line's own provenance: WHO completed the task.  The
             * recorded ATTEMPT's session/run/epoch are the ones a report
             * about that attempt must name, so they only fall back to this
             * line when there is no attempt on record. */
            out->done_epoch = epoch;
            if (session[0] && strcmp(session, "-") != 0)
                copy_str(out->done_session, sizeof out->done_session, session);
            if (run[0] && strcmp(run, "-") != 0)
                copy_str(out->done_run, sizeof out->done_run, run);
            if (!out->has_attempt) {
                out->epoch = epoch;
                if (session[0] && strcmp(session, "-") != 0)
                    copy_str(out->session, sizeof out->session, session);
                if (run[0] && strcmp(run, "-") != 0)
                    copy_str(out->run, sizeof out->run, run);
            }
        }
        /* any other step: ignored (a future record kind must not be misread) */
    }
    fclose(f);
    return 0;
}

int fx_outcome_bindings(const char *data_dir, const char *task, const char *agent,
                        FxOutcomeBind *out) {
    if (!out) return -1;
    memset(out, 0, sizeof *out);
    if (!data_dir || !*data_dir || !task || !agent) return -1;

    char path[PATH_MAX];
    if (record_path(path, sizeof path, data_dir) < 0) return -1;
    FILE *f = fopen(path, "rb");
    if (!f) return 0; /* no record yet: nothing is bound */

    char line[FX_OUTCOME_LINE_CAP + 2];
    while (fgets(line, (int)sizeof line, f) != NULL) {
        unsigned long epoch = 0, version = 0;
        char rtask[FX_OUTCOME_TASK_CAP] = {0};
        char step[16] = {0};
        char session[264] = {0}, run[64] = {0};
        if (!record_fields(line, &epoch, rtask, sizeof rtask, step, sizeof step,
                           session, sizeof session, run, sizeof run, &version))
            continue;
        if (strcmp(step, "agent") != 0) continue;
        char bound_agent[128] = {0};
        tail_field(line, bound_agent, sizeof bound_agent);
        if (strcmp(bound_agent, agent) != 0) continue; /* another agent's task */
        if (strcmp(rtask, task) == 0) {
            out->bound = 1;
            continue; /* keep walking: an earlier drift is still a drift */
        }
        if (!out->other_task[0]) copy_str(out->other_task, sizeof out->other_task, rtask);
        out->drifted = 1;
    }
    fclose(f);
    return 0;
}

/* ── the store's own outcome files ──────────────────────────────────────── */

int fx_outcome_current(const char *store, unsigned long *out, char *err, size_t errcap) {
    if (out) *out = 0;
    if (!store || !*store) {
        if (err && errcap)
            snprintf(err, errcap, "no store path given (the store is never guessed)");
        return -1;
    }
    char path[PATH_MAX];
    if (path_join(path, sizeof path, store, FX_OUTCOME_CURRENT_FILE) < 0) {
        if (err && errcap) snprintf(err, errcap, "store path too long");
        return -1;
    }
    FILE *f = fopen(path, "r");
    if (!f) {
        if (err && errcap)
            snprintf(err, errcap, "%s: cannot be opened: %s", path, strerror(errno));
        return -1;
    }
    char line[128];
    unsigned long v = 0;
    int ok = (fgets(line, (int)sizeof line, f) != NULL &&
              sscanf(line, "%lu", &v) == 1);
    fclose(f);
    if (!ok) {
        if (err && errcap)
            snprintf(err, errcap, "%s: exists but carries no version", path);
        return -1;
    }
    if (out) *out = v;
    return 0;
}

int fx_outcome_bootlog_each(const char *store,
                            int (*cb)(void *u, unsigned long version,
                                      const char *status, unsigned long epoch),
                            void *u) {
    if (!store || !*store) return -1;
    char path[PATH_MAX];
    if (path_join(path, sizeof path, store, FX_OUTCOME_BOOTLOG_FILE) < 0) return -1;
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[512];
    int seen = 0;
    while (fgets(line, (int)sizeof line, f) != NULL) {
        unsigned long v = 0, epoch = 0;
        char status[FX_OUTCOME_STATUS_CAP] = {0};
        if (sscanf(line, "%lu %31s %lu", &v, status, &epoch) != 3) continue;
        seen++;
        if (cb && cb(u, v, status, epoch) != 0) break;
    }
    fclose(f);
    return seen;
}

typedef struct {
    unsigned long version;
    char         *status;
    size_t        scap;
    int           found;
} VerdictScan;

static int verdict_cb(void *u, unsigned long version, const char *status,
                      unsigned long epoch) {
    (void)epoch;
    VerdictScan *s = (VerdictScan *)u;
    if (s->version != version) return 0;
    /* only a VERDICT counts: the boot's own "in-progress" line is not one, and
     * neither is a "shutdown" marker. */
    if (strcmp(status, "ok") != 0 && strcmp(status, "failed") != 0) return 0;
    copy_str(s->status, s->scap, status);
    s->found = 1;
    return 1; /* stop */
}

int fx_outcome_bootlog_verdict(const char *store, unsigned long version,
                               char *status_out, size_t scap) {
    VerdictScan s;
    memset(&s, 0, sizeof s);
    s.version = version;
    s.status = status_out;
    s.scap = scap;
    if (status_out && scap) status_out[0] = '\0';
    if (fx_outcome_bootlog_each(store, verdict_cb, &s) < 0) return 0;
    return s.found;
}

typedef struct {
    unsigned long version;
    char         *status;
    size_t        scap;
    int           found;
} LastScan;

static int last_cb(void *u, unsigned long version, const char *status,
                   unsigned long epoch) {
    (void)epoch;
    LastScan *s = (LastScan *)u;
    if (strcmp(status, "ok") != 0 && strcmp(status, "failed") != 0) return 0;
    s->version = version;
    copy_str(s->status, s->scap, status);
    s->found = 1;
    return 0; /* keep walking: the LAST one wins */
}

int fx_outcome_bootlog_last(const char *store, unsigned long *version_out,
                            char *status_out, size_t scap) {
    LastScan s;
    memset(&s, 0, sizeof s);
    s.status = status_out;
    s.scap = scap;
    if (status_out && scap) status_out[0] = '\0';
    if (fx_outcome_bootlog_each(store, last_cb, &s) < 0) return 0;
    if (!s.found) return 0;
    if (version_out) *version_out = s.version;
    return 1;
}

/* ── the recovery journal ───────────────────────────────────────────────── */

/* Distinct genhashes seen so far, with per-hash counts — the recurrence scan.
 * A journal holds one line per roll-forward (real boots), so the distinct-fault
 * count is small; growth is per DISTINCT CONTENT, not per line. */
typedef struct {
    char          hash[FX_OUTCOME_GENHASH_CAP];
    unsigned long n;
} RecurEntry;

int fx_outcome_recovery(const char *store, FxRecovery *out, char *err,
                        size_t errcap) {
    if (!out) return -1;
    memset(out, 0, sizeof *out);
    if (!store || !*store) {
        if (err && errcap)
            snprintf(err, errcap, "no store path given (the store is never guessed)");
        return -1;
    }
    char path[PATH_MAX];
    if (path_join(path, sizeof path, store, FX_OUTCOME_RECOVERY_FILE) < 0) {
        if (err && errcap) snprintf(err, errcap, "store path too long");
        return -1;
    }
    FILE *f = fopen(path, "rb");
    if (!f) {
        if (errno == ENOENT) {
            /* ABSENT IS NOT AN ERROR: a store that predates the journal (or an
             * fx-init older than 4d6a8c2) simply has no journal, and that is a
             * DIFFERENT claim than "never recovered" — the caller reports it
             * as its own state (journal_absent), never as a zero count. */
            out->journal_absent = 1;
            return 0;
        }
        if (err && errcap)
            snprintf(err, errcap, "%s: cannot be opened: %s", path, strerror(errno));
        return -1;
    }

    RecurEntry *seen = NULL;
    size_t nseen = 0, capseen = 0;
    int track = 1; /* recurrence tracking stops on OOM (it is a bonus signal,
                    * not a verdict input); counting continues */
    /* 512 covers the writer's own 128-byte line buffer with margin; a line
     * that fills the buffer WITHOUT a newline is over-long (not the writer's)
     * and is drained and skipped whole — counting a split fragment of a
     * forged line would be counting noise as a recovery. */
    char line[512];
    while (fgets(line, (int)sizeof line, f) != NULL) {
        if (!strchr(line, '\n')) {
            int ch;
            while ((ch = fgetc(f)) != EOF && ch != '\n') {} /* drain */
            /* an unterminated line that ran past the buffer: not the writer's
             * shape; treated as damaged, same as a torn line below */
            if (line[0] >= '0' && line[0] <= '9') out->damaged_lines++;
            continue;
        }
        if (line[0] < '0' || line[0] > '9')
            continue; /* the '#' header (the definition lives in the file), or
                       * a blank line: not a data line by the file's own rule */
        out->count++;
        unsigned long epoch = 0, pub = 0, from = 0;
        char gh[FX_OUTCOME_GENHASH_CAP] = {0};
        if (sscanf(line, "%lu %lu %lu %71s", &epoch, &pub, &from, gh) != 4) {
            /* Counted (the file's own definition is digit-initial lines) but
             * unreadable: it can contribute nothing to `last` or recurrence.
             * This cannot happen from the writer; a torn MERGE (the journal
             * has no tail repair, so an append after a torn line joins it)
             * or a forged line lands here. */
            out->damaged_lines++;
            continue;
        }
        out->have_last = 1;
        out->last_epoch = epoch;
        out->last_published = pub;
        out->last_from_failed = from;
        if (strcmp(gh, "-") == 0) gh[0] = '\0'; /* honest absence, not a hash */
        copy_str(out->last_genhash, sizeof out->last_genhash, gh);
        if (!gh[0] || !track) continue; /* '-' never matches for recurrence:
                               * two unresolvable hashes are two ABSENCES, and
                               * "the same content re-failing" is a claim the
                               * evidence does not hold */
        size_t i = 0;
        for (; i < nseen; i++)
            if (strcmp(seen[i].hash, gh) == 0) break;
        if (i < nseen) {
            if (++seen[i].n > out->recur_count) {
                out->recur_count = seen[i].n;
                copy_str(out->recur_genhash, sizeof out->recur_genhash, gh);
                out->have_recur = 1;
            }
        } else {
            if (nseen == capseen) {
                size_t nc = capseen ? capseen * 2 : 16;
                RecurEntry *ns = realloc(seen, nc * sizeof *seen);
                if (!ns) {
                    free(seen);
                    seen = NULL;
                    track = 0;
                    continue;
                }
                seen = ns;
                capseen = nc;
            }
            copy_str(seen[nseen].hash, sizeof seen[nseen].hash, gh);
            seen[nseen].n = 1;
            nseen++;
        }
    }
    int rerr = errno; /* captured at the loop's exit, before free() can move it */
    free(seen);
    /* A FILE THAT OPENED BUT COULD NOT BE READ IS ITS OWN STATE, and MEASURED
     * it is reachable: glibc's fopen(<store>/.recovery, "rb") SUCCEEDS on a
     * DIRECTORY, the first fgets then fails with EISDIR, and before this check
     * the reader returned count=0 — which the callers report as "0 automatic
     * roll-forwards on record ... this is the FIRST time this machine has had
     * to recover".  That is a MEASUREMENT THAT WAS NEVER MADE, and it collapsed
     * the unreadable state into the zero state (a chmod-000 journal, where
     * fopen itself fails, was already loud; the directory case was not).  A
     * read error also means any count read so far is PARTIAL — reported as a
     * total it would be wrong, so the whole read is refused. */
    if (ferror(f)) {
        if (err && errcap)
            snprintf(err, errcap, "%s: cannot be read: %s", path,
                     strerror(rerr ? rerr : EIO));
        fclose(f);
        return -1;
    }
    fclose(f);
    return 0;
}

/* ── the rule ───────────────────────────────────────────────────────────── */

/* ── THE TRUNCATION MARKER ────────────────────────────────────────────────
 * A report that does not fit its buffer is CUT, and a cut is silent unless it
 * says so.  That silence has already cost something real: at the former
 * 2048-byte cap the ACTIVATION_FAILED report was over budget in the corner
 * case (a 511-char config + a 255-char session + the recovery-journal line),
 * and what the cut removed was the ESCAPE CLAUSE — the tail naming the task's
 * ONLY way out (--reconsider, or removing this task's lines).  A refusal whose
 * escape is silently missing is a permanent wedge, and nothing in the tree
 * noticed.  The cap was then raised to FX_OUTCOME_MSG_CAP — but A RAISED CAP
 * IS NOT A GUARD: the next input that grows past it is cut just as silently.
 * So every report built by report() now ENDS IN THIS MARKER when it did not
 * fit, and the marker is the thing a reader cannot miss.
 *
 * WHERE THIS CAN HAPPEN — every call site that builds a report string.  All of
 * them go through report(): the eight verdict reports in fx_outcome_verdict
 * (ALREADY_DONE x4, UNRESOLVED x2, ACTIVATION_FAILED, SUPERSEDED) plus the
 * damaged-record report, which lives in report_damaged() with three wordings
 * and is reached from two places in fx_outcome_verdict — nine report() call
 * sites in this file, and no report is built anywhere else.  The buffer belongs
 * to the CALLER, and the only production caller whose buffer can truncate is
 * src/llm2/agent_main.c:642 — `char rep[FX_OUTCOME_MSG_CAP]`, printed with
 * fputs to the refusing run's stdout and to the console.  The oracle
 * (tests/test_outcome.sh) passes 2x the cap so its greps see the whole text,
 * and phase 10 drives a DELIBERATELY small cap to prove the marker is reached.
 *
 * HOW THE MARKER IS REACHED, and why it cannot itself be cut: it is written
 * into the TAIL of the buffer only AFTER vsnprintf reported a shortfall, so it
 * OVERWRITES the prose the cut landed in instead of competing with the body
 * for room — a body that used all the space cannot drop it.  Its length is
 * bounded by FX_OUTCOME_TRUNC_MARK_CAP and re-checked at RUN time (the
 * snprintf return): if the format ever grew past the buffer, the SHORT marker
 * is emitted instead, so the marker only ever gets SHORTER, never absent.  The
 * one case no marker can cover — a caller buffer too small for even the short
 * marker — is asserted below to be unreachable from FX_OUTCOME_MSG_CAP and is
 * documented at the fallback rather than left as a hole. */
#define FX_OUTCOME_TRUNC_MARK_CAP 128
/* MEASURED: the marker's longest form — "\n... TRUNCATED at <20-digit count>
 * bytes — the escape clause may be missing; raise FX_OUTCOME_MSG_CAP\n" — is
 * 110 bytes, so 128 holds it with room and the runtime check is a guard, not
 * the sizing. */
static const char FX_OUTCOME_TRUNC_SHORT[] = "\n... TRUNCATED\n";

_Static_assert(sizeof FX_OUTCOME_TRUNC_SHORT < FX_OUTCOME_MSG_CAP,
               "FX_OUTCOME_MSG_CAP must hold the short truncation marker");
_Static_assert(FX_OUTCOME_TRUNC_MARK_CAP < FX_OUTCOME_MSG_CAP,
               "FX_OUTCOME_MSG_CAP must hold the full truncation marker");

/* fmt a report and return the verdict — one exit path for each verdict, so the
 * text a reader greps is built in exactly one place.  The printf ATTRIBUTE is
 * load-bearing: every report is a long format string with a dozen numbered
 * conversions, and a mismatched one (a %s fed a version, a dropped argument)
 * prints a plausible but WRONG report — exactly the defect the first cut of the
 * ACTIVATION_FAILED report shipped.  With the attribute the compiler checks
 * every call. */
static FxVerdict report(FxVerdict v, char *text, size_t textcap, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));

static FxVerdict report(FxVerdict v, char *text, size_t textcap, const char *fmt, ...) {
    if (!text || !textcap) return v;
    va_list ap;
    va_start(ap, fmt);
    /* vsnprintf returns the length it WOULD have written: `n >= textcap` is the
     * truncation, and before this marker existed that was the whole story. */
    int n = vsnprintf(text, textcap, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n < textcap) return v;

    char mark[FX_OUTCOME_TRUNC_MARK_CAP];
    int m = snprintf(mark, sizeof mark,
                     "\n... TRUNCATED at %zu bytes — the escape clause may be "
                     "missing; raise FX_OUTCOME_MSG_CAP\n", (size_t)n);
    size_t ml;
    if (m > 0 && (size_t)m < sizeof mark) {
        ml = (size_t)m;
    } else {
        memcpy(mark, FX_OUTCOME_TRUNC_SHORT, sizeof FX_OUTCOME_TRUNC_SHORT);
        ml = sizeof FX_OUTCOME_TRUNC_SHORT - 1;
    }
    if (textcap > ml) {
        /* the tail of the buffer, ending exactly on its NUL */
        memcpy(text + textcap - 1 - ml, mark, ml + 1);
    } else if (textcap >= sizeof FX_OUTCOME_TRUNC_SHORT) {
        /* The caller's buffer cannot hold the full marker: keep the report LOUD
         * at the cost of its body rather than silent with its body.  NOT
         * reachable from FX_OUTCOME_MSG_CAP (asserted above) — it is here so a
         * new caller with a smaller buffer degrades loudly instead of quietly. */
        memcpy(text, FX_OUTCOME_TRUNC_SHORT, sizeof FX_OUTCOME_TRUNC_SHORT);
    } else {
        /* Nothing fits: a marker is impossible in this buffer.  Stated in the
         * code because it is the one case the guard cannot reach. */
        text[0] = '\0';
    }
    return v;
}

/* The DAMAGE RULE's report (the table in outcome.h): the record provably lost
 * a line for this task, so wherever the rule would say RUN — "nothing on
 * record", "the ordinary re-run" — it says this instead.  A STOP, because a
 * record that was mid-write cannot be trusted to say there is no unaccounted
 * activation for the task; a false STOP is the safer error.  `where` names
 * the RUN row that was about to fire. */
static FxVerdict report_damaged(FxOutcome *o, const char *data_dir,
                                const char *agent, const char *where,
                                char *text, size_t textcap, const char *escape) {
    char damage[320];
    if (o->has_torn_line && o->has_orphan_result)
        snprintf(damage, sizeof damage,
                 "an unterminated (torn) line naming this task was skipped, and a\n"
                 "             result line was dropped with no attempt line to account it");
    else if (o->has_torn_line)
        snprintf(damage, sizeof damage,
                 "an unterminated (torn) line naming this task was skipped — the file\n"
                 "             was mid-write, and what that line was is unreadable");
    else
        snprintf(damage, sizeof damage,
                 "a result line for this task was dropped: no attempt line it could\n"
                 "             account was ever read (torn, or never written)");
    return report(FX_VERDICT_UNRESOLVED, text, textcap,
        "fx-harness: THE ATTEMPT RECORD FOR THIS TASK IS DAMAGED. NOT RE-RUNNING IT.\n"
        "  task     : %s (agent %s)\n"
        "  where    : %s\n"
        "  damage   : %s\n"
        "  rule     : a torn line proves the file was mid-write, so the record cannot\n"
        "             be trusted to say there is no unaccounted activation for this\n"
        "             task — the verdict RUN is refused off a damaged record\n"
        "  record   : %s/attempts.jsonl\n"
        "  action   : this run stops here (exit 0); no activation is issued.  Repair\n"
        "             the record, or remove this task's lines from it, before re-running\n"
        "%s",
        o->task, agent ? agent : "", where, damage,
        data_dir ? data_dir : "(unset)", escape);
}

FxVerdict fx_outcome_verdict(const char *data_dir, const char *task,
                             const char *store, const char *agent,
                             FxOutcome *out, char *text, size_t textcap,
                             char *err, size_t errcap) {
    FxOutcome local;
    if (!out) out = &local;
    if (text && textcap) text[0] = '\0';
    if (err && errcap) err[0] = '\0';
    if (!task || !*task) return FX_VERDICT_RUN;
    if (fx_outcome_record_load(data_dir, task, out) != 0) return FX_VERDICT_RUN;

    /* The ONE legitimate way out of a refusal, NAMED IN EVERY STOP REPORT.  The
     * record is unwedged only by a LATER COMPLETED run of the same task (which
     * writes `done`), so the operator either forces one (--reconsider) or
     * removes this task's lines.  Nothing in the harness settles it silently;
     * on the model side the bound is the TOOL TABLE's, not a secrecy claim
     * (see outcome.h): fx_write's surface is the host-declared closed set, and
     * this record is in no set — an agent that could erase the evidence of
     * its own failed activation could re-issue it blindly. */
    /* THE ESCAPE CLAUSE'S OWN BUFFER, sized so it can never be cut.  The marker
     * above catches a report that overruns FX_OUTCOME_MSG_CAP, but a snprintf
     * into a too-small `escape` would cut the escape clause SILENTLY while the
     * whole report stayed UNDER the cap — the marker would never fire, and the
     * cut would land exactly where it hurts (the tail of this clause names
     * attempts.jsonl, i.e. the way out).  The only variable input here is
     * data_dir, and any data_dir that can produce a report at all is one the
     * record could be OPENED with: fx_outcome_record_load() path_joins it into
     * `char path[PATH_MAX]` and returns 0 (-> the ordinary RUN, no report) when
     * it does not fit.  So PATH_MAX + 320 holds the clause for every input that
     * can reach it: MEASURED, the fixed prose is 226 bytes including
     * "/attempts.jsonl", and 226 + (PATH_MAX - 1) < PATH_MAX + 320. */
    char escape[PATH_MAX + 320];
    snprintf(escape, sizeof escape,
        "  escape   : to force a re-run: re-run with --reconsider (an operator flag; a run\n"
        "             that COMPLETES records `done` and settles this task), or remove this\n"
        "             task's lines from %s/attempts.jsonl\n",
        data_dir ? data_dir : "(unset)");

    /* ── no activation is on record ── */
    if (!out->has_attempt) {
        if (!out->done) {
            /* the DAMAGE RULE first: a record that provably lost a line for
             * this task must not be read as "nothing on record" — the RUN
             * this branch would return re-issues an activation whose attempt
             * line is exactly what the record can no longer show. */
            if (out->has_torn_line || out->has_orphan_result)
                return report_damaged(out, data_dir, agent,
                    "the record reads as \"no activation on record\" for this task",
                    text, textcap, escape);
            return FX_VERDICT_RUN;
        }
        return report(FX_VERDICT_ALREADY_DONE, text, textcap,
            "fx-harness: TASK ALREADY COMPLETE — NOT RE-RUNNING IT.\n"
            "  task     : %s (agent %s)\n"
            "  what I did: nothing on this boot's behalf was activated; the task ran to\n"
            "              completion on an earlier boot and its record is durable at\n"
            "              %s/attempts.jsonl (session %s, run %s, epoch %lu)\n"
            "  rule     : a completed task is not re-run\n"
            "  action   : this run stops here (exit 0); the record is NOT deleted\n"
            "%s",
            out->task, agent ? agent : "", data_dir ? data_dir : "(unset)",
            out->session[0] ? out->session : "-", out->run[0] ? out->run : "-",
            out->epoch, escape);
    }

    /* ── an activation is on record, but its outcome was never recorded: the
     *    run died between dispatching the activation and reading its result,
     *    or the verb never named a generation.  The store cannot account for
     *    it, so repeating it is exactly the blind re-apply this unit exists to
     *    stop — UNLESS the task has since been recorded COMPLETE (a later run
     *    of it finished — the only way the record can ever be settled). ── */
    if (!out->has_result || out->version == 0) {
        if (out->done) {
            return report(FX_VERDICT_ALREADY_DONE, text, textcap,
                "fx-harness: TASK ALREADY COMPLETE — NOT RE-RUNNING IT.\n"
                "  task     : %s (agent %s)\n"
                "  activated: %s (recorded before the call was dispatched; the verb named no\n"
                "             generation, so the record cannot account for that activation)\n"
                "  done     : a `done` marker is in force for this task (session %s,\n"
                "             run %s, epoch %lu) — a run of the task completed, which is\n"
                "             the strongest evidence the record can hold; a done that\n"
                "             predates an UNACCOUNTED activation would NOT settle it\n"
                "  rule     : a completed task is not re-run\n"
                "  record   : %s/attempts.jsonl (session %s, run %s, epoch %lu)\n"
                "  action   : this run stops here (exit 0); the record is NOT deleted\n"
                "%s",
                out->task, agent ? agent : "",
                out->config[0] ? out->config : "-",
                out->done_session[0] ? out->done_session : "-",
                out->done_run[0] ? out->done_run : "-",
                out->done_epoch,
                data_dir ? data_dir : "(unset)",
                out->session[0] ? out->session : "-", out->run[0] ? out->run : "-",
                out->epoch, escape);
        }
        return report(FX_VERDICT_UNRESOLVED, text, textcap,
            "fx-harness: OBSERVED OUTCOME — THE STORE CANNOT ACCOUNT FOR MY ACTIVATION.\n"
            "            NOT REPEATING IT.\n"
            "  task     : %s (agent %s)\n"
            "  activated: %s (recorded before the call was dispatched; %s)\n"
            "  rule     : \"if the generation I am running in is not the one I activated,\n"
            "              my activation failed\" — and no generation was recorded, so it\n"
            "              cannot be repeated knowingly\n"
            "  record   : %s/attempts.jsonl (session %s, run %s, epoch %lu)\n"
            "  action   : this run stops here (exit 0); no further activation is issued\n"
            "%s",
            out->task, agent ? agent : "",
            out->config[0] ? out->config : "-",
            out->has_result ? "the verb named no generation"
                            : "no tool result was ever flushed",
            data_dir ? data_dir : "(unset)",
            out->session[0] ? out->session : "-", out->run[0] ? out->run : "-",
            out->epoch, escape);
    }

    /* ── the store decides.  Read the BOOTLOG verdict for the generation I
     *    activated FIRST: it distinguishes "my boot failed and the store rolled
     *    forward" (the oscillator) from "it booted ok and a later activation
     *    superseded it" — which "current != mine" alone cannot tell apart. ── */
    char status[FX_OUTCOME_STATUS_CAP] = {0};
    int have_verdict = fx_outcome_bootlog_verdict(store, out->version, status,
                                                  sizeof status);
    unsigned long current = 0;
    int have_current = 0;
    char cerr[512] = {0};

    if (have_verdict && strcmp(status, "failed") == 0) {
        /* the report NAMES the roll-forward; reading CURRENT is corroboration,
         * not the decision — it may legitimately be unreadable here. */
        have_current = (fx_outcome_current(store, &current, cerr,
                                           sizeof cerr) == 0);
        out->current = current;
        out->have_current = have_current;
        char running[512];
        if (have_current)
            snprintf(running, sizeof running, "generation v%lu (%s/%s)", current,
                     store, FX_OUTCOME_CURRENT_FILE);
        else
            snprintf(running, sizeof running,
                     "(the store's CURRENT could not be read: %s)", cerr);
        /* THE RECOVERY JOURNAL: has this happened BEFORE?  A single failed
         * boot is one mistake; the same machine rolling forward again and
         * again is the oscillator, and only <store>/.recovery can say so —
         * no single boot, and no bootlog line, carries "this has happened
         * before".  The wording is bounded by the journal's own honesty
         * limit (its header): a recurring genhash is the SAME FAULT
         * RETURNING, not proof of a live oscillation.  An absent or
         * unreadable journal degrades to its own honest sentence; it never
         * fabricates a count, and it cannot change the verdict — the verdict
         * was already ACTIVATION_FAILED before this line existed. */
        char recovery[560];
        {
            FxRecovery rj;
            char rerr[256] = {0};
            if (fx_outcome_recovery(store, &rj, rerr, sizeof rerr) != 0) {
                /* A journal that EXISTS but cannot be read is its OWN state.
                 * "absent" (there is no journal) and "zero" (the journal is
                 * there and has counted nothing) are both claims about the
                 * file's CONTENT, and both were MEASURED; this one is a claim
                 * about the READ, and reporting it as either of the others
                 * would be reporting a measurement that was never made — the
                 * unreadable journal would silently read as "absent" and the
                 * three states would collapse into two.  The VERB spells the
                 * same state with the same lead word (tools/fx-verbs-server.c:
                 * "recovery UNREADABLE: ..."). */
                snprintf(recovery, sizeof recovery,
                         "UNREADABLE — %s\n"
                         "             the journal is there but could not be read, so\n"
                         "             whether this has happened before is UNKNOWN, not zero",
                         rerr);
            } else if (rj.journal_absent) {
                snprintf(recovery, sizeof recovery,
                         "no %s on this store (fx-init predates the journal, or\n"
                         "             the store does) — whether this has happened before is\n"
                         "             UNKNOWN, not zero",
                         FX_OUTCOME_RECOVERY_FILE);
            } else if (rj.count == 0) {
                snprintf(recovery, sizeof recovery,
                         "0 automatic roll-forwards on record (%s)\n"
                         "             — this is the FIRST time this machine has had to recover",
                         FX_OUTCOME_RECOVERY_FILE);
            } else {
                char head[96];
                snprintf(head, sizeof head,
                         "%lu automatic roll-forward(s) on record (%s",
                         rj.count, FX_OUTCOME_RECOVERY_FILE);
                /* the RECURRENCE leads — it is the journal's reason to exist,
                 * so a truncating tail must eat it LAST */
                char recur[256] = "";
                if (rj.have_recur)
                    snprintf(recur, sizeof recur,
                             "; the content genhash %s has failed %lu time(s) —\n"
                             "             THE SAME FAULT RETURNING, not a live-oscillation\n"
                             "             claim (read the journal's epochs and .bootlog)",
                             rj.recur_genhash, rj.recur_count);
                char last[192] = "";
                if (rj.have_last)
                    snprintf(last, sizeof last,
                             "; newest: v%lu republished from v%lu at epoch %lu,\n"
                             "             content %s",
                             rj.last_published, rj.last_from_failed, rj.last_epoch,
                             rj.last_genhash[0] ? rj.last_genhash : "- (unresolvable)");
                char floor[96] = "";
                if (rj.damaged_lines > 0)
                    snprintf(floor, sizeof floor,
                             " (+%d torn/unparsable line(s) — the count is a FLOOR)",
                             rj.damaged_lines);
                snprintf(recovery, sizeof recovery, "%s%s%s%s)",
                         head, recur, last, floor);
            }
        }
        return report(FX_VERDICT_ACTIVATION_FAILED, text, textcap,
            "fx-harness: OBSERVED OUTCOME — THE ACTIVATION THIS HARNESS RECORDED FAILED.\n"
            "            NOT REPEATING IT.\n"
            "  task     : %s (agent %s)\n"
            "  activated: %s -> generation v%lu (recorded before the call was dispatched,\n"
            "             outcome read back from the verb's own reply)\n"
            "  bootlog  : \"v%lu failed\" in %s/%s — the boot of my generation failed and\n"
            "             fx-init rolled the store forward to older good content under a\n"
            "             NEW, HIGHER version number\n"
            "  recovery : %s\n"
            "  running  : %s\n"
            "  rule     : \"if the generation I am running in is not the one I activated,\n"
            "              my activation failed — do not repeat it\"\n"
            "  record   : %s/attempts.jsonl (session %s, run %s, epoch %lu)\n"
            "  action   : this run stops here (exit 0): the task is NOT re-run and no\n"
            "             further activation is issued.  Inspect the config above and the\n"
            "             store's .bootlog before changing anything.\n"
            "%s",
            out->task, agent ? agent : "",
            out->config[0] ? out->config : "-", out->version,
            out->version, store, FX_OUTCOME_BOOTLOG_FILE,
            recovery,
            running,
            data_dir ? data_dir : "(unset)",
            out->session[0] ? out->session : "-", out->run[0] ? out->run : "-",
            out->epoch, escape);
    }

    if (!have_current) {
        if (fx_outcome_current(store, &current, cerr, sizeof cerr) != 0) {
            if (err && errcap)
                snprintf(err, errcap,
                         "cannot read the store's outcome files: %s "
                         "(store '%s'; the store is never guessed)",
                         cerr, store && *store ? store : "(none)");
            return FX_VERDICT_ERROR;
        }
        have_current = 1;
    }
    out->current = current;
    out->have_current = 1;
    copy_str(out->bootlog_status, sizeof out->bootlog_status, status);

    if (have_verdict && strcmp(status, "ok") == 0) {
        /* my generation DID boot ok; a later activation (mine or another
         * task's) moved the store past it.  Whether the TASK is complete is a
         * SEPARATE question, and the record answers it with `done` — the same
         * marker branch 2 trusts.  Without it, "it booted" is all we know: stop
         * (repeating an activation that took is the blind re-apply this unit
         * stops) but do NOT claim a completion the record does not hold. */
        if (!out->done) {
            return report(FX_VERDICT_SUPERSEDED, text, textcap,
                "fx-harness: OBSERVED OUTCOME — MY ACTIVATION TOOK AND WAS SUPERSEDED.\n"
                "            THE TASK IS NOT RECORDED COMPLETE. NOT REPEATING IT BLINDLY.\n"
                "  task     : %s (agent %s)\n"
                "  activated: %s -> generation v%lu, which is recorded OK in the store's\n"
                "             %s (it booted); this boot runs v%lu, so the store moved on\n"
                "  done     : NO `done` marker is on record for this task — the activation\n"
                "             TOOK, but nothing on record says the task FINISHED\n"
                "  rule     : an activation that took is not re-issued blindly: repeating it\n"
                "             would re-apply a change already in the store with no evidence\n"
                "             that the task is complete\n"
                "  record   : %s/attempts.jsonl (session %s, epoch %lu)\n"
                "  action   : this run stops here (exit 0).  The task is NOT recorded complete\n"
                "             and no further activation is issued.\n"
                "%s",
                out->task, agent ? agent : "",
                out->config[0] ? out->config : "-", out->version,
                FX_OUTCOME_BOOTLOG_FILE, current,
                data_dir ? data_dir : "(unset)",
                out->session[0] ? out->session : "-", out->epoch, escape);
        }
        /* my generation booted ok and the task IS recorded complete: do not
         * re-run it. */
        return report(FX_VERDICT_ALREADY_DONE, text, textcap,
            "fx-harness: TASK ALREADY COMPLETE — NOT RE-RUNNING IT.\n"
            "  task     : %s (agent %s)\n"
            "  activated: %s -> generation v%lu, which is recorded OK in the store's\n"
            "             %s (it booted); this boot runs v%lu, so the store has moved on\n"
            "  rule     : an activation that took is not repeated\n"
            "  record   : %s/attempts.jsonl (session %s, epoch %lu)\n"
            "  action   : this run stops here (exit 0)\n"
            "%s",
            out->task, agent ? agent : "",
            out->config[0] ? out->config : "-", out->version,
            FX_OUTCOME_BOOTLOG_FILE, current,
            data_dir ? data_dir : "(unset)",
            out->session[0] ? out->session : "-", out->epoch, escape);
    }

    if (current == out->version) {
        if (!out->done) {
            /* the DAMAGE RULE holds here too: "the ordinary re-run" is a
             * claim about the record's LAST attempt, and a torn line after
             * it (or an orphan result) means the record cannot be trusted to
             * make that claim — stop instead. */
            if (out->has_torn_line || out->has_orphan_result)
                return report_damaged(out, data_dir, agent,
                    "the activation on record is the CURRENT generation and would be\n"
                    "             re-run as \"the ordinary re-run\"",
                    text, textcap, escape);
            return FX_VERDICT_RUN;
        }
        return report(FX_VERDICT_ALREADY_DONE, text, textcap,
            "fx-harness: TASK ALREADY COMPLETE — NOT RE-RUNNING IT.\n"
            "  task     : %s (agent %s)\n"
            "  activated: %s -> generation v%lu, and this boot IS running v%lu (the store's\n"
            "             CURRENT): the activation took\n"
            "  rule     : a completed task is not re-run\n"
            "  record   : %s/attempts.jsonl (session %s, epoch %lu)\n"
            "  action   : this run stops here (exit 0)\n"
            "%s",
            out->task, agent ? agent : "",
            out->config[0] ? out->config : "-", out->version, out->version,
            data_dir ? data_dir : "(unset)",
            out->session[0] ? out->session : "-", out->epoch, escape);
    }

    /* The generation I activated is neither the one this boot runs nor judged by
     * the bootlog: something moved the store without a verdict for my version. */
    return report(FX_VERDICT_UNRESOLVED, text, textcap,
        "fx-harness: OBSERVED OUTCOME — THE STORE CANNOT ACCOUNT FOR MY ACTIVATION.\n"
        "            NOT REPEATING IT.\n"
        "  task     : %s (agent %s)\n"
        "  activated: %s -> generation v%lu\n"
        "  running  : generation v%lu (%s/%s)\n"
        "  bootlog  : no \"v%lu ok\" and no \"v%lu failed\" line — my activation was\n"
        "             superseded before it ever booted\n"
        "  rule     : \"if the generation I am running in is not the one I activated,\n"
        "              my activation failed — do not repeat it\"\n"
        "  record   : %s/attempts.jsonl (session %s, epoch %lu)\n"
        "  action   : this run stops here (exit 0); no further activation is issued\n"
        "%s",
        out->task, agent ? agent : "",
        out->config[0] ? out->config : "-", out->version,
        current, store, FX_OUTCOME_CURRENT_FILE,
        out->version, out->version,
        data_dir ? data_dir : "(unset)",
        out->session[0] ? out->session : "-", out->epoch, escape);
}
