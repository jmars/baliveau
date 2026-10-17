# fx-harness — a minimal, native agent harness for the fx-linux guest.
#
# TWO structural decisions shape the tree:
#
#   1. NO TLS.  The guest has no socket layer at all (CONFIG_NET unset =>
#      socket(2) is ENOSYS), so the model transport is a character device
#      bridged by a host-side proxy that holds the API key — src/agent/
#      fx_transport.c is the whole transport, and no TLS stack is built.
#
#   2. ONE backend.  fx_backend.c accepts "openai_responses" and returns -1
#      otherwise (agent_main fail-opens to the same adapter).
#
# Explicit file lists, never shell globs: the tree must build in sandboxes
# whose shells mangle '*' and multi-command pipelines.

CC      ?= cc
CFLAGS  := -std=c11 -O2 -g -Wall -Wextra \
           -ffile-prefix-map=$(CURDIR)=. -fdebug-prefix-map=$(CURDIR)=. \
           -Isrc -Isrc/agent -Isrc/vendor/dhall-c -Isrc/vendor/yyjson \
           -Ibuild/include \
           -Isrc/vendor/tomlc99 \
           -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE
LDFLAGS :=

# ─── the datalog engine: the fx stack's Zig build, sibling checkout ─────────
# The engine is NO LONGER VENDORED here (the legacy C copy is gone — its
# 64-byte dafsa_internal.h cache-line assert cannot hold on 32-bit x86-musl
# and the stack's real engine is the Zig port anyway).  Like fx-init and
# fxstore, we link the Zig-built libdatalog from the SIBLING checkout:
#
#   native (gnu):   the prebuilt zig-out/lib/libdatalog.so (x86-64), with a
#                   baked rpath so the binary runs without LD_LIBRARY_PATH;
#   musl (i386):    a STATIC libdatalog.a built from the sibling's Zig
#                   sources for x86-linux-musl (a glibc-built .so is
#                   incompatible with elf_i386, and a dynamic link would
#                   defeat the static goal — same pattern as fxstore).
#
# The tree therefore cannot build standalone; see README (Build deps).
#
# SIBLING RESOLUTION — the repo's ONE policy, shared with every gate
# (tests/test_sibling_paths.sh): an explicit DATALOG_DIR wins; else the
# historical neighbour ../datalog-dafsa IF it really holds the engine; else
# the relocated default $HOME/fixpoint-linux/datalog-dafsa.  MEASURED
# 2026-10-13: this tree MOVED out of the fx stack's workspace (it was
# /var/data/workspace/fixpoint-linux/fx-harness), so the bare `../datalog-dafsa`
# default made $(error) below fire on EVERY invocation in the new layout —
# `make test-osier-share` exited 2 at this line before any test ran.
DATALOG_DIR ?= $(if $(wildcard ../datalog-dafsa/zig-out/lib/libdatalog.so),../datalog-dafsa,$(HOME)/fixpoint-linux/datalog-dafsa)
DATALOG_SHIM     := build/include/vendor/datalog-dafsa/src
DATALOG_MUSL_LIB := build/datalog-musl/lib
DATALOG_MUSL_A   := $(DATALOG_MUSL_LIB)/libdatalog.a

ifeq ($(wildcard $(DATALOG_DIR)/zig-out/lib/libdatalog.so),)
$(error DATALOG_DIR=$(DATALOG_DIR) has no zig-out/lib/libdatalog.so — \
        clone/checkout the sibling and build it: \
        cd $(DATALOG_DIR) && zig build -p zig-out --build-file zig/build.zig)
endif

# The guest target: static i386-musl, the toolchain that already builds every
# other fx guest binary (fx-init, fx-core's stages, dhall-c, datalog-dafsa).
MUSL_CC     ?= zig cc -target x86-linux-musl
MUSL_CFLAGS := $(CFLAGS) -static

# ─── vendored: dhall-c (config engine, linked in-process) ──────────────────
DHALL_SRC := src/vendor/dhall-c/arena.c \
             src/vendor/dhall-c/ast.c \
             src/vendor/dhall-c/bignum.c \
             src/vendor/dhall-c/builtins.c \
             src/vendor/dhall-c/http.c \
             src/vendor/dhall-c/import.c \
             src/vendor/dhall-c/lexer.c \
             src/vendor/dhall-c/normalize.c \
             src/vendor/dhall-c/parser.c \
             src/vendor/dhall-c/serialize.c \
             src/vendor/dhall-c/sha256.c \
             src/vendor/dhall-c/ssrf.c \
             src/vendor/dhall-c/typecheck.c

# ─── vendored: yyjson / tomlc99 ────────────────────────────────────────────
YYJSON_SRC  := src/vendor/yyjson/yyjson.c
TOMLC99_SRC := src/vendor/tomlc99/toml.c

# ─── the agent loop ───────────────────────────────────────────────
AGENT_SRC := src/agent/agent_main.c \
          src/agent/agent_loop.c \
          src/agent/checkpoint.c \
          src/agent/config.c \
          src/agent/dhall_eval_lock.c \
          src/agent/mcp_client.c \
          src/agent/outcome.c \
          src/agent/tool_policy.c \
          src/agent/tui.c \
          src/agent/sse.c \
          src/agent/openai_responses.c \
          src/agent/fx_transport.c \
          src/agent/fx_backend.c

# ─── harness sources the loop reuses ──────────────────────────────────────
HARNESS_SRC := src/runner.c src/runstore.c src/secrets.c

ALL_SRC := $(AGENT_SRC) $(HARNESS_SRC) $(DHALL_SRC) $(YYJSON_SRC) $(TOMLC99_SRC)

BIN      := build/fx-agent
BIN_MUSL := build/fx-agent.musl

all: $(BIN)

# runstore.h includes "vendor/datalog-dafsa/src/dl.h" (the pre-swap path);
# build/include/vendor/datalog-dafsa/src is a symlink to the sibling's src/
# so that include resolves against the ENGINE'S OWN headers — no src/ edit.
# Recreated every build so a changed DATALOG_DIR re-points it.
$(DATALOG_SHIM): FORCE
	@mkdir -p $(dir $(DATALOG_SHIM))
	@ln -sfn "$(abspath $(DATALOG_DIR))/src" $(DATALOG_SHIM)

FORCE:
.PHONY: FORCE

# The sibling's Zig engine, compiled for x86-linux-musl into build/ by its
# OWN build.zig (the authority on how the engine builds).  dlp's i386
# @compileError is a pre-existing, unrelated CLI failure — the lib steps
# still install — so its exit code is tolerated and the ARTIFACT is the gate.
$(DATALOG_MUSL_A):
	cd $(DATALOG_DIR) && zig build -Dtarget=x86-linux-musl -Drelease \
	    -p "$(CURDIR)/build/datalog-musl" --build-file zig/build.zig || true
	@test -f $@ || { echo "ERROR: $(DATALOG_MUSL_A) missing — the sibling's zig build for x86-linux-musl did not produce libdatalog.a" >&2; exit 1; }

$(BIN): src/agent/agent_main_main.c $(ALL_SRC) \
        $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ src/agent/agent_main_main.c $(ALL_SRC) \
	    -L$(DATALOG_DIR)/zig-out/lib \
	    -Wl,-rpath,$(abspath $(DATALOG_DIR)/zig-out/lib) -ldatalog

# The guest binary.  Not part of `all`: it is the deployment target, verified
# separately once the native build is green.  -s strips it (guest artifacts
# ship stripped).
musl: $(BIN_MUSL)

$(BIN_MUSL): src/agent/agent_main_main.c $(ALL_SRC) $(DATALOG_MUSL_A) | $(DATALOG_SHIM)
	@mkdir -p build
	$(MUSL_CC) $(MUSL_CFLAGS) $(LDFLAGS) -o $@ src/agent/agent_main_main.c $(ALL_SRC) \
	    -L$(DATALOG_MUSL_LIB) -ldatalog -s

# THE PRE-FIX ARTIFACT of the observation loop (src/agent/outcome.h): the SAME
# sources, with the boot-time consume of the harness's own durable activation
# record compiled out (-DFX_HARNESS_NO_OBSERVE).  It is not a feature and not a
# runtime switch — it exists so the observation loop's central assertion ("a
# failed activation is reported and the task is NOT re-run") can be shown to be
# able to FAIL: tests/test_outcome.sh and tests/qemu-agent-observe.sh run the
# same fixture and the same state against both binaries and require the blind
# one to re-run/ratchet where the real one refuses.  Nothing in a deployment can
# reach this behaviour.
BIN_BLIND := build/fx-agent-blind
blind: $(BIN_BLIND)

$(BIN_BLIND): src/agent/agent_main_main.c $(ALL_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) -DFX_HARNESS_NO_OBSERVE $(LDFLAGS) -o $@ src/agent/agent_main_main.c $(ALL_SRC) \
	    -L$(DATALOG_DIR)/zig-out/lib \
	    -Wl,-rpath,$(abspath $(DATALOG_DIR)/zig-out/lib) -ldatalog

# The first oracle: Osier CODE SHARE of the ACTIVE GENERATION (host tool —
# native only, no musl variant; it shells fxstore's read-only `facts` and
# needs the sibling fxstore checkout built with it).
#   tools/fx-osier-share.c measures the fraction of the source bytes of the
#   components the active generation RUNS that are .elm (Osier), from the
#   store's own version-bound facts — never from a source tree.  The gate,
#   tests/test_osier_share.sh, is the DISCRIMINATION PROOF: a synthetic
#   Osier-sourced component must MOVE the number 0 -> non-zero; a built-
#   but-not-run component must NOT; a run component with non-Osier source
#   must not raise it.  It provisions its fixture store toolchain-free via
#   fx-init's activate_paths + fx-activate (host-side, nothing boots).
BIN_OSIER := build/fx-osier-share

test-osier-share: $(BIN_OSIER)
	bash tests/test_osier_share.sh

$(BIN_OSIER): tools/fx-osier-share.c $(DHALL_SRC) $(YYJSON_SRC)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ tools/fx-osier-share.c $(DHALL_SRC) $(YYJSON_SRC)

.PHONY: test-osier-share

# The AUDIT SEAT — the oracle's SIBLING (todo.md §4, design record §6b):
# host-side, agent-unwritable, a function of observable system state.  Where
# the oracle measures a generation, this seat asks whether the RECORDS
# AGREE — .bootlog/.recovery (fx-init) x the version-bound facts (fx-activate)
# x CURRENT (fxstore) x the rootfs (fxstore verify, exit 1 on drift) — and,
# load-bearing, compares what it sees now against ITS OWN PREVIOUS
# OBSERVATION (kept on host disk, never inside the store), which is the only
# thing that catches a COHERENT in-guest rewrite of history.  The response is
# the EXISTING rollback machinery, driven by the thin --rollback trigger.
#   tools/fx-audit.c is the seat; tests/test_fx_audit.sh is the
#   discrimination proof: a clean store passes, each named incoherence fires
#   from its own fixture, the coherent tamper is caught ONLY by the
#   previous-observation comparison (and a sed-mutated detector that skips
#   that comparison goes blind on exactly that fixture), the trigger refuses
#   a clean store and rolls back a tampered one through `fxstore rollback
#   --hard`, and the verdict is pinned independent of attempts.jsonl (a
#   self-report is never evidence).
BIN_AUDIT := build/fx-audit

test-audit: $(BIN_AUDIT)
	bash tests/test_fx_audit.sh

$(BIN_AUDIT): tools/fx-audit.c src/vendor/dhall-c/sha256.c src/vendor/dhall-c/dhall.h
	@mkdir -p build
	$(CC) $(CFLAGS) -Isrc/vendor/dhall-c $(LDFLAGS) -o $@ tools/fx-audit.c src/vendor/dhall-c/sha256.c

.PHONY: test-audit

# THE SELECTION STEP — the fourth host-side seat (design record §7.1): the
# oracle asks IS IT BETTER, the audit asks IS IT HONEST, the reporter asks
# IS IT DOCUMENTED, and this one ANSWERS THE QUESTION THEY LEAVE OPEN:
# WHICH GENERATION SHOULD THE SYSTEM BE RUNNING?  It computes the
# LEXICOGRAPHIC order over the store's published versions — viable
# (.bootlog) -> coherent (fxstore verify, CURRENT only) -> greatest run-set
# share (the oracle's own run_set_share_fraction, shell'd, never
# re-derived) — and ENFORCES it: a candidate that is not viable, or is
# CURRENT with drift, can NEVER win, whatever its share (before this seat
# existed the order lived in prose: build/fx-osier-share's number was
# consumed by tests alone).  Its output is the house shape (frozen
# tab-separated records with a `#` human summary BESIDE them, the ORDER
# table printed on every run, byte-deterministic), and `--apply` is the
# thin trigger: on `revert-to <v>` only it drives the EXISTING `fxstore
# rollback <v>` SOFT (content returns and the VERSION NUMBER GOES UP — the
# substrate's own roll-forward semantics; `--hard` is recovery-only).
#   tools/fx-select.c is the seat; tests/test_fx_select.sh is the
#   discrimination proof: the highest-share generation FAILS its boot and
#   must not be named (with a sed-mutant that drops the viability filter
#   and goes blind on exactly that fixture), a drifting CURRENT loses to a
#   lower-share viable generation, the max share beats the newest, a tie
#   never causes a revert (and the tie rule is shown LIVE with CURRENT at
#   the lower twin), no eligible candidate refuses loudly, an
#   oracle-refusing candidate is excluded BY NAME rather than counted as
#   0%, the default never mutates, two runs are cmp-identical, the --apply
#   trigger both refuses a no-op and lands a real rollback, and a missing
#   oracle is a tool error.  The fixture is TOOLCHAIN-FREE (fx-init's
#   activate_paths + the real host-side fx-activate; nothing boots).
BIN_SELECT := build/fx-select

test-select: $(BIN_SELECT) $(BIN_OSIER)
	bash tests/test_fx_select.sh

$(BIN_SELECT): tools/fx-select.c
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ tools/fx-select.c

.PHONY: test-select

# THE HOST PROXY (design record §7.6; plan handoff-hostgate-plan2, slice P1)
# — the wire seat: the guest has no socket layer, so whoever holds the
# chardev's other end holds the endpoint and the credential, and that end
# must be a HOST seat like the others (agent-unwritable, a function of
# observable state — here, the wire itself).  P1 is the stream-transparent
# skeleton, NO POLICY: it speaks the measured chardev contract
# (src/agent/fx_transport.c:57-85 — "<len>\n<json>" in, raw SSE out,
# response.completed last) and nothing else.  Its transport is a PTY PAIR,
# NOT a FIFO (measured: a FIFO opened O_RDWR self-reads — the guest would
# consume its own request frame; a pty has no self-read, and cfmakeraw kills
# the echo/ONLCR phantom).  The gate, tests/test_hostgate.sh, is the
# transparency proof: the DIRECT FILE arm (no proxy) and the PROXY arm must
# print the SAME marker, and a mangling proxy must flip that pass to a fail
# on exactly this fixture — a transparency mistake is LOUD, never silent.
# P2 adds THE ONE LOG + the join (see tools/fx-hostgate.c): the gate's P2
# phases assert BOTH directions — a real two-turn run RESOLVES the call_id,
# and an unfireable join is REPORTED by call_id — plus the mutation blind:
# build/fx-hostgate-mutant is THIS source with the resolution pass compiled
# out (FH_MUTANT_NO_JOIN); it exits cleanly with a WRONG RECORD and the gate
# must catch that by content, not by exit status.  The P2 fix adds the
# bounding blind: build/fx-hostgate-unbound (FH_MUTANT_NO_BOUND) renders
# every free-text field verbatim — unbounded model-controlled text in an
# append-only host log — and the gate's bound phase must flip on it by
# content too.
BIN_HOSTGATE := build/fx-hostgate
BIN_HOSTGATE_MUTANT := build/fx-hostgate-mutant
BIN_HOSTGATE_UNBOUND := build/fx-hostgate-unbound
BIN_HOSTGATE_NOREWRITE := build/fx-hostgate-norewrite
BIN_HOSTGATE_BLINDADD := build/fx-hostgate-blindadd
BIN_HOSTGATE_SINGLEITEM := build/fx-hostgate-singleitem
BIN_HOSTGATE_NOSUBST := build/fx-hostgate-nosubst
# P4 + P5 (the reserved-name contract and the justification): the mutants and
# the build-time override arms, EVERY ONE from the same tools/fx-hostgate.c.
BIN_HOSTGATE_NONAMECHECK := build/fx-hostgate-nonamecheck
BIN_HOSTGATE_COLLIDE := build/fx-hostgate-collide
BIN_HOSTGATE_NONAMEBAD := build/fx-hostgate-nonamebad
BIN_HOSTGATE_BADNAME := build/fx-hostgate-badname
BIN_HOSTGATE_BADPIN := build/fx-hostgate-badpin
BIN_HOSTGATE_NOJUSTIFY := build/fx-hostgate-nojustify
BIN_HOSTGATE_NOTOOLS := build/fx-hostgate-notools
BIN_HOSTGATE_NODRATE := build/fx-hostgate-nodrate
BIN_HOSTGATE_DONEARGS := build/fx-hostgate-doneargs
# P6 (the operator author at the host seat): the PRE-FIX control (the seat
# compiled out — fail-open), the D2-bound control (the seat binding a fact it
# cannot see) and the canonicalization blind (no path normalization before
# matching the pinned patterns).
BIN_HOSTGATE_NOOPS := build/fx-hostgate-noops
BIN_HOSTGATE_OPSFLOOR := build/fx-hostgate-opsfloor
BIN_HOSTGATE_OPSNOCANON := build/fx-hostgate-opsnocanon
# P7 (the claim author at the host seat): the PRE-FIX CONTROL (the claim seat
# compiled out — fail-open: a call the pinned policy refuses crosses verbatim
# and EXECUTES), mirroring the P6 noops control.
BIN_HOSTGATE_NOCLAIM := build/fx-hostgate-noclaim
# P7-fix: two PRE-FIX controls for the seat's own defence, each the SAME source
# with one hardening compiled out.  noevalpin: the evaluator that COMPUTES the
# verdict is exempt from the pin (a swapped always-derives evaluator arms and a
# forbidden call crosses).  nobound: NO deadline on the per-call subprocess (a
# hung evaluator stalls the whole seat and writes NO row — the dead-agent
# instrument is blind to the call).
BIN_HOSTGATE_NOEVALPIN := build/fx-hostgate-noevalpin
BIN_HOSTGATE_NOBOUND := build/fx-hostgate-nobound
# P8 (resume + the one log as join state): the PRE-FIX CONTROL for the log's
# second role.  nologload: the startup load compiled OUT — the in-memory state
# starts EMPTY and the first flush REPLACES any existing record, so the prior
# run's rows are GONE and its denials are neither restored nor substituted on
# the outbound leg (the brief's measured wipe, and the silent empty map the
# corruption arms exist to catch).
BIN_HOSTGATE_NOLOGLOAD := build/fx-hostgate-nologload
# P8-fix: three PRE-FIX CONTROLS for the P8 review's should-fixes, each the
# SAME source with one behaviour compiled out (see the rules below).
BIN_HOSTGATE_LOADUNBOUND := build/fx-hostgate-loadunbound
BIN_HOSTGATE_NODEDUP := build/fx-hostgate-nodedup
BIN_HOSTGATE_NOSCOPECARRY := build/fx-hostgate-noscopecarry
# S1 (THE HOST-TOOL REGISTRY + host_time): the collision arm's two builds and
# the dispatch blind.  The two colliding builds override the ONE table name AND
# its pin together (a build that overrides only the name refuses on the stale
# pin instead of on the collision, which would make the arm prove the wrong
# thing); the difference between them is exactly the collision check.
BIN_HOSTGATE_HOSTCOLLIDE := build/fx-hostgate-hostcollide
BIN_HOSTGATE_NOHOSTCOLL := build/fx-hostgate-nohostcoll
BIN_HOSTGATE_NOEXEC := build/fx-hostgate-noexec
# S2 (THE JUDGED ARGUMENTS + THE TOTALITY CHECK): the class-resolution blind
# (FH_MUTANT_OPS_NO_CLASS) — the plan's risk #1 made concrete (a host path
# that matched no class row, or a protected path whose class was never
# injected, EXECUTES where the real build refuses).
BIN_HOSTGATE_OPSNOCLASS := build/fx-hostgate-opsnoclass

test-hostgate: $(BIN_HOSTGATE) $(BIN_HOSTGATE_MUTANT) $(BIN_HOSTGATE_UNBOUND) \
               $(BIN_HOSTGATE_NOREWRITE) $(BIN_HOSTGATE_BLINDADD) \
               $(BIN_HOSTGATE_SINGLEITEM) $(BIN_HOSTGATE_NOSUBST) \
               $(BIN_HOSTGATE_NONAMECHECK) $(BIN_HOSTGATE_NONAMEBAD) $(BIN_HOSTGATE_COLLIDE) \
               $(BIN_HOSTGATE_BADNAME) $(BIN_HOSTGATE_BADPIN) \
               $(BIN_HOSTGATE_NOJUSTIFY) $(BIN_HOSTGATE_NOTOOLS) \
               $(BIN_HOSTGATE_NODRATE) $(BIN_HOSTGATE_DONEARGS) \
               $(BIN_HOSTGATE_NOOPS) $(BIN_HOSTGATE_OPSFLOOR) \
               $(BIN_HOSTGATE_OPSNOCANON) $(BIN_HOSTGATE_NOCLAIM) \
               $(BIN_HOSTGATE_NOEVALPIN) $(BIN_HOSTGATE_NOBOUND) \
               $(BIN_HOSTGATE_NOLOGLOAD) $(BIN_HOSTGATE_LOADUNBOUND) \
               $(BIN_HOSTGATE_NODEDUP) $(BIN_HOSTGATE_NOSCOPECARRY) \
               $(BIN_HOSTGATE_HOSTCOLLIDE) $(BIN_HOSTGATE_NOHOSTCOLL) \
               $(BIN_HOSTGATE_NOEXEC) $(BIN_HOSTGATE_OPSNOCLASS) $(BIN)
	bash tests/test_hostgate.sh

# P6 THE OPS AUTHOR: the engine whose reasoning the seat evaluates is the
# SIBLING's, linked IN-PROCESS exactly as $(BIN)'s rule does — the same
# -L/-rpath pair, the header resolving through the DATALOG_SHIM symlink.  The
# proxy never reimplements the datalog evaluation.
HOSTGATE_LIBS := -L$(DATALOG_DIR)/zig-out/lib \
                 -Wl,-rpath,$(abspath $(DATALOG_DIR)/zig-out/lib) -ldatalog

# The proxy links the vendored dhall-c sha256 (P4's catalog pin and P6's
# policy PINS check) and the sibling datalog engine; nothing else of dhall-c,
# the same single-object link fx-audit/fx-report/fx-claim use.
$(BIN_HOSTGATE): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# P2's mutation blind: the SAME proxy source with the join pass compiled out
# — a never-firing join is a WRONG RECORD, not a crash, and the gate must
# catch it by content on exactly the two-turn fixture.
$(BIN_HOSTGATE_MUTANT): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_JOIN -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# The P2-fix mutation blind: the bound compiled OUT (FH_MUTANT_NO_BOUND) —
# an over-long model-controlled field must arrive in the log MARKED, and a
# proxy that ships it verbatim is a wrong record the gate catches by
# content on exactly the bound fixture.
$(BIN_HOSTGATE_UNBOUND): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_BOUND -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# P3's PRE-FIX CONTROL (FH_MUTANT_NO_REWRITE): the P2-era behavior pinned —
# the enforcement rewrites are compiled out while the policy RECORD still
# runs, so on the denied fixture the stream carries the TRUE name of a call
# the log says was denied.  The gate's control arm proves the stub then
# DISPATCHES (marker present): the asymmetry the real proxy flips.
$(BIN_HOSTGATE_NOREWRITE): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_REWRITE -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# P3's COMPLETENESS MUTATION BLIND (FH_MUTANT_NO_ADDED_REWRITE): ONLY the
# output_item.added rewrite is compiled out (done/completed keep theirs).
# The guest's tool accumulator is fed by the added event alone
# (openai_responses.c:146-161), so the mutant lets the true name reach the
# accumulator and DISPATCH while the record claims a denial — a partial
# rewriter is an allow, and the gate must catch it by the dispatch marker.
$(BIN_HOSTGATE_BLINDADD): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_ADDED_REWRITE -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# P3-FIX PRE-FIX CONTROL (FH_MUTANT_SINGLE_ITEM): the P2/P3-era SINGLE
# open-item accumulator pinned — the interleave shape that produced the
# reproduced silent allow.  The gate's interleave control arms run this
# build and require the silent allow (marker present, mis-joined allowed row
# under call_A carrying call_B's args) — the asymmetry the per-item buffers
# flip.
$(BIN_HOSTGATE_SINGLEITEM): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_SINGLE_ITEM -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# P3-FIX OUTBOUND-SUBSTITUTION MUTATION BLIND (FH_MUTANT_NO_SUBSTITUTE): the
# decode rewrite STAYS (name rewritten, nothing executes) while the outbound
# substitution (restore + denial text) is compiled out — a missed outbound
# leg.  The pending-substitution instrument must catch it by content: an
# `unresolved-substitution` anomaly row in the log, while the dump still
# carries the reserved name unrestored.
$(BIN_HOSTGATE_NOSUBST): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_SUBSTITUTE -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# ── P4 + P5 (the reserved-name contract and the justification) ──────────────
#
# The contract's FAILURE DIRECTION is a silent allow (a colliding reserved
# name is CALLABLE), so the gate needs a build in which the collision is REAL:
# FH_MUTANT_NO_NAME_CONTRACT removes the check, and the reserved name is
# overridden to a CATALOG VERB — the proxy then starts and rewrites denied
# calls to a name the verbs server answers.  The bad-charset and bad-pin arms
# are overrides of the same source (a STATIC refusal has no mutation to make:
# what is under test is that the proxy refuses, and the control is the mutant
# that starts).
$(BIN_HOSTGATE_NONAMECHECK): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_NAME_CONTRACT -DFH_RESERVED_NAME='"fx_write"' -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# the same mutant with an UNPARSEABLE reserved name: the control for the
# CHARSET arm — the check compiled out let the bad name go live, so the startup
# refusal is what stands between it and the wire.
$(BIN_HOSTGATE_NONAMEBAD): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_NAME_CONTRACT -DFH_RESERVED_NAME='"fx host denied"' -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

$(BIN_HOSTGATE_COLLIDE): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_RESERVED_NAME='"fx_write"' -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

$(BIN_HOSTGATE_BADNAME): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_RESERVED_NAME='"fx host denied"' -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

$(BIN_HOSTGATE_BADPIN): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_CATALOG_SHA256='"0000000000000000000000000000000000000000000000000000000000000000"' -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# P5's two half-mutations, each isolating one side of --require-justification:
# NO_JUSTIFY_CHECK = the model is TOLD and the host IGNORES it (an unjustified
# call crosses and EXECUTES); NO_TOOLS_INJECT = the host CHECKS a rule the
# model was never told (the lane dies unjustified behind a protective record),
# and the denial-rate instrument must make that shape visible.
$(BIN_HOSTGATE_NOJUSTIFY): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_JUSTIFY_CHECK -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

$(BIN_HOSTGATE_NOTOOLS): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_TOOLS_INJECT -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

$(BIN_HOSTGATE_NODRATE): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_DENIAL_RATE -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)


# P5's PRE-FIX CONTROL for the ARGUMENT MIRROR (FH_MUTANT_JUDGE_DONE_ARGS):
# the judge reads the done event's own field instead of the argument
# accumulator the guest dispatches — on a stream whose justification arrives
# ONLY in the deltas (what a real provider sends) it denies an honest, fully
# justified call: the dead-agent shape, loud only through the marker and the
# denial-rate instrument.
$(BIN_HOSTGATE_DONEARGS): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_JUDGE_DONE_ARGS -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# ── P6 (THE OPERATOR AUTHOR AT THE HOST SEAT) ───────────────────────────────
#
# Three builds of the SAME source, each isolating one property of the seat:
#
# (1) THE PRE-FIX CONTROL — FH_MUTANT_NO_OPS_SEAT compiles the whole ops seat
#     out while --ops-policy-dir is still accepted and IGNORED: exactly the
#     P3-era proxy.  Its failure DIRECTION is FAIL-OPEN — a call the pinned
#     policy DENIES crosses verbatim and EXECUTES.  The gate requires the
#     armed build to deny it and this build to run it, so the denial cannot be
#     an artifact of the scenario.
$(BIN_HOSTGATE_NOOPS): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_OPS_SEAT -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# (2) THE D2-BOUND CONTROL — FH_MUTANT_OPS_BIND_UNSEEN makes the seat ALSO
#     inject writable(<path>) per call: the floor fact it CANNOT see.  D2 then
#     fires and the seat denies a write that only D2 (i.e. only the in-guest
#     seat, with a non-ok boot verdict) would deny.  The gate requires the
#     real build to ALLOW that call and this one to DENY it, so the D2 bound
#     is the seat's binding and not the fixture's.
$(BIN_HOSTGATE_OPSFLOOR): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_OPS_BIND_UNSEEN -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# (3) THE CANONICALIZATION BLIND — FH_MUTANT_OPS_NO_CANON matches the call's
#     RAW path string against the pinned patterns instead of normalizing it
#     first.  The failure DIRECTION is a host-seat SILENT ALLOW: an equivalent
#     spelling of a protected path ("/fx/disk/agent-data/../agent-config.dhall")
#     is not denied, while the in-guest seat — which DOES canonicalize — would
#     still refuse the write.  The gate requires the two builds to disagree on
#     exactly that spelling.
$(BIN_HOSTGATE_OPSNOCANON): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_OPS_NO_CANON -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# (4) S2 THE TOTALITY-CHECK BLIND — FH_MUTANT_OPS_NO_CLASS compiles out the
#     per-call class resolution AND the unclassed-arg refusal.  A host tool's
#     path is then never classed and never refused: a PROTECTED path (which D3
#     would deny if classed) and an UNCLASSED path (which the totality check
#     would refuse by name) BOTH EXECUTE.  The failure DIRECTION is the plan's
#     risk #1 made concrete: a host call silently permitted because its
#     argument matched nothing (or dodged the class table).
$(BIN_HOSTGATE_OPSNOCLASS): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_OPS_NO_CLASS -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# ── P7 (THE CLAIM AUTHOR AT THE HOST SEAT) ──────────────────────────────────
#
# THE PRE-FIX CONTROL — FH_MUTANT_NO_CLAIM_SEAT compiles the whole claim seat
# out while --calls-policy-dir is still accepted and IGNORED: exactly the
# P6-era proxy.  Its failure DIRECTION is FAIL-OPEN — a call the pinned policy
# refuses (a forbidden purpose) crosses verbatim and EXECUTES.  The gate
# requires the armed build to deny it and this build to run it, so the denial
# cannot be an artifact of the scenario.
$(BIN_HOSTGATE_NOCLAIM): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_CLAIM_SEAT -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# P7-fix PRE-FIX CONTROL 1: the evaluator pin compiled OUT — the file that
# computes the verdict is only stat()ed, exactly the P7 pre-fix shape.  With a
# swapped always-`derives` evaluator the seat arms happily and a forbidden call
# crosses and EXECUTES; the real build refuses at startup.
$(BIN_HOSTGATE_NOEVALPIN): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_EVAL_PIN -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# P7-fix PRE-FIX CONTROL 2: the per-call deadline compiled OUT — the seat
# blocks on the evaluator forever, the turn ends with the call never judged,
# and NO row is written (the reviewer's whole-seat stall with a silent record).
$(BIN_HOSTGATE_NOBOUND): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_EVAL_BOUND -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# P8 PRE-FIX CONTROL: THE LOG LOAD COMPILED OUT.  This is the source as it
# stood before P8 — the in-memory row array starts EMPTY on every process
# start and the file is never read back, so a second run against the same
# --log REPLACES the first run's record (MEASURED by the brief: run 1's
# `denied` row gone, only run 2's left) and the deny map is empty, so the
# resumed run's OLD denied items cross un-restored and un-substituted (the
# model sees fx_host_denied plus a generic sentinel).  A corrupt log is not
# noticed at all: it is overwritten.  The gate's restart and corruption arms
# must CATCH this build — that is the asymmetry.
$(BIN_HOSTGATE_NOLOGLOAD): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_LOG_LOAD -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# P8-fix (R1/R2/R5) PRE-FIX CONTROLS: three controls for the three P8-review
# findings whose fix is a BEHAVIOUR rather than a refusal, each the SAME source
# with exactly that behaviour compiled out — so the gate's new arms are proved
# to be able to FAIL, on their own fixture, by content.
#   loadunbound  (R1): the LOAD-time bound compiled out — a crafted-but-valid
#                DENIED row's 1 MB true_name/denial_text reach the deny map and
#                so the outbound leg at FULL LENGTH (FH_BOUND applied only at
#                WRITE time: the reviewer's measured 1,048,576 bytes).
#   nodedup      (R2): a fresh row per OBSERVATION of a call_id — one re-served
#                call inflates into several rows and the last one can never be
#                answered inside its own run (the phantom UNRESOLVED at every
#                exit), and the log it writes is one this seat now refuses.
#   noscopecarry (R5): an ALLOWED row's stored `allow_scope` is ignored and
#                recomputed from the CURRENT run's seats — the silent REWORD of
#                a row this process never judged.
$(BIN_HOSTGATE_LOADUNBOUND): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_LOAD_BOUND -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

$(BIN_HOSTGATE_NODEDUP): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_CALL_DEDUP -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

$(BIN_HOSTGATE_NOSCOPECARRY): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_SCOPE_CARRY -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# ── S1 (THE HOST-TOOL REGISTRY) ──────────────────────────────────────────────
#
# (1) THE COLLISION ARM, REAL BUILD — the ONE registry table with a name that
#     IS a guest verb (fx_read), pinned correctly so the pin check passes and
#     the COLLISION check is what refuses.  Startup refusal, exit 1, before the
#     slave path is published: a host tool that shadows a guest verb is executed
#     by the host AND dispatched by the guest under one name.
HOSTTOOL_COLLIDING_NAME := -DFH_HOSTTOOL_NAME='"fx_read"'
HOSTTOOL_COLLIDING_PIN := -DFH_HOSTTOOL_SHA256='"88638ce0cf6d71e4b4bd0890724e935597dd8f656c295501dc53a859df32c34a"'

$(BIN_HOSTGATE_HOSTCOLLIDE): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) $(HOSTTOOL_COLLIDING_NAME) $(HOSTTOOL_COLLIDING_PIN) -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# (2) THE SAME BUILD WITH THE COLLISION CHECK COMPILED OUT — it STARTS, and the
#     colliding call is EXECUTED BY THE HOST: the silent allow measured end to
#     end (the gate's dispatch marker is the witness).
$(BIN_HOSTGATE_NOHOSTCOLL): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_HOST_COLLISION $(HOSTTOOL_COLLIDING_NAME) $(HOSTTOOL_COLLIDING_PIN) -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

# (3) THE DISPATCH BLIND — FH_MUTANT_NO_EXEC compiles the registry lookup out of
#     the allowed path.  The call forwards to the guest, the guest answers
#     -32602, and the model is handed "(tool call failed)" where the HOST's
#     result belonged: SILENT DEGRADATION (the outside effect never happened and
#     nothing in the record says the executor was missing).  The gate's arm
#     asserts the sentinel CROSSES on the wire capture.
$(BIN_HOSTGATE_NOEXEC): tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -DFH_MUTANT_NO_EXEC -o $@ tools/fx-hostgate.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC) $(HOSTGATE_LIBS)

.PHONY: test-hostgate

# THE SIBLING-PATH GATE (unit `path-sweep`).  Every gate that reads a sibling
# checkout (fx-init, fxstore, datalog-dafsa) resolves it with ONE policy —
# $FX_SIBLINGS wins, else the historical neighbour $REPO/.. IF it really holds
# fx-init, else $HOME/fixpoint-linux, else a LOUD skip.  MEASURED 2026-10-13:
# the tree moved out of the fx stack's workspace and the old `$REPO/..` default
# made ten gates SKIP (or die at the DATALOG_DIR $(error)) quietly enough to
# read as a pass.  This gate executes every site BOTH ways — a bogus
# $FX_SIBLINGS must skip loudly naming it (proving the resolution line is LIVE
# on that script), and with no override each script must get PAST resolution —
# and pins the pre-fix revision (cmp-proven to differ) to show it SKIPPED.
# Slow (~9 min): it runs the gate scripts under a stated bound.
test-sibling-paths:
	bash tests/test_sibling_paths.sh

.PHONY: test-sibling-paths

# The REPORTER SEAT — the third host-side seat (todo.md §1b, design record
# §1a): the oracle asks IS IT BETTER, the audit asks IS IT HONEST, this one
# asks IS IT DOCUMENTED.  Same family properties (host-side,
# agent-unwritable, a function of observable system state); it READS the
# substrate's durable records (snapshots + version-bound facts via
# `fxstore facts`, .bootlog, .recovery, the retained config the
# generation_config fact names — fx-init 1399dbd) and never becomes a source
# of truth.  Its output is STABLE and MACHINE-READABLE by construction —
# frozen tab-separated records, a `#`-prefixed human summary BESIDE them,
# the event taxonomy and retention tables printed on every run, and every
# record marked MEASURED / DERIVED / ABSENT with the absence's KIND stated
# ("there were none" vs "this is not durably recorded").  THE BOUND prints
# in the output, the audit seat's discipline: the runtime datalog is tmpfs
# and dies at reboot, operator interventions exist only as the ABSENCE of
# the automatic .recovery row (a DERIVED disjunction, never a verdict), and
# `fxstore gc` deletes the retained configs (MEASURED).
#   tools/fx-report.c is the seat; tests/test_fx_report.sh is the
# acceptance: a fixture store with a real lifecycle must let a reader
# answer, FROM THE REPORT ALONE, "what changed between N and N+1, and from
# which input" — both configs readable, the diff, the generation each
# produced — plus the none-vs-not-recorded absence arms, the
# operator-intervention derivation (control: the .recovery-attributed
# republish is NOT an operator event), the gc/config findings, byte-exact
# determinism, and MUTATIONS of the taxonomy (each sed-mutated class must
# make its own assertion go blind).
BIN_REPORT := build/fx-report

# P9: the call class reads the host proxy's one log and the guest transcript,
# so the gate drives a REAL proxy run — the seat depends on the proxy and the
# host-built agent (the same artifacts `make test-hostgate` builds).
test-report: $(BIN_REPORT) $(BIN_HOSTGATE) $(BIN)
	bash tests/test_fx_report.sh

$(BIN_REPORT): tools/fx-report.c src/vendor/dhall-c/sha256.c src/vendor/dhall-c/dhall.h $(YYJSON_SRC)
	@mkdir -p build
	$(CC) $(CFLAGS) -Isrc/vendor/dhall-c $(LDFLAGS) -o $@ tools/fx-report.c src/vendor/dhall-c/sha256.c $(YYJSON_SRC)

.PHONY: test-report

# THE CLAIM UNIT's S0 GATE (pre-registered claims; plan handoff-claim-rev-plan).
# Three host-authored inputs under policy/ — the AGENT-FACING CLOSED LEXICON
# (policy/claims-lexicon.ini: no `justified`, no [actions] — that absence IS
# the soundness boundary), the FROZEN POLICY (policy/claims-policy.le +
# policy/policy-lexicon.ini, compiled into the sha-pinned rule-text artifact
# policy/claims-policy.dl) and the FREE-LE EVALUATOR (policy/eval_claim.py:
# compile the claim against the agent lexicon, head check, premise
# verification against the store facts as-of from_version, query justified).
# `le` is CONSUMED AS A DEPENDENCY from its own checkout — never forked — and
# the engine is the sibling's dlb binding; the gate FAILS (never skips) when
# either is absent, because free LE over a closed lexicon IS this slice.
# tests/test_claim_policy.sh carries the boundary arms, the mutants each
# blind on exactly its fixture, the pin/determinism arms and the four vacuity
# arms.  It also TYPES the evaluator's one trusted-facts channel: a facts dump
# may name a store template and nothing else (A10), so neither a row binding
# nor the judgment predicate can enter from outside, and the verdict is
# checked to name only the claim its rows carry — with the PRE-FIX evaluator
# executed to show that arm can fail.  No C is built here: S1 is
# tools/fx-claim.c, a later unit.
test-claim-policy:
	bash tests/test_claim_policy.sh

# The policy release path: regenerating the pinned artifact is a HOST release
# (it rewrites policy/claims-policy.dl, and policy/PINS' sha must be updated
# in the same commit — the gate fails until both agree).
#
# The `le` checkout, resolved the repo's way (sibling first, then the
# relocated default).  NO parse-time $(error): le is needed by this target and
# by test-claim-policy only, and a hard parse error here would break every
# OTHER target on a machine without the sibling.  Note it is passed as LE_DIR
# (the env var policy/eval_claim.py reads), not as a make variable name it
# would not see.
LE_ROOT ?= $(if $(wildcard ../logical-english/le/__init__.py),../logical-english,$(HOME)/logical-english)

policy-artifact:
	LE_DIR=$(abspath $(LE_ROOT)) python3 policy/eval_claim.py --compile-policy \
	    --policy-le policy/claims-policy.le \
	    --policy-lexicon policy/policy-lexicon.ini > policy/claims-policy.dl.tmp
	mv policy/claims-policy.dl.tmp policy/claims-policy.dl
	@printf 'policy/claims-policy.dl sha256: '; sha256sum policy/claims-policy.dl | cut -d' ' -f1
	@printf 'policy/PINS must carry exactly that value for claims-policy.dl\n'

.PHONY: test-claim-policy policy-artifact

# THE CLAIM UNIT's S1 GATE (the judge seat; plan handoff-claim-rev-plan,
# slice S1).  tools/fx-claim.c is the JUDGE: host-side, agent-unwritable, a
# function of observable state (design record §7.1).  Per published
# GENERATION it assembles the triple — the claim (the two extraEtc rows that
# rode into the generation at /etc/fx-claim.tsv + /etc/fx-claim.le), the
# VERDICT (ONE policy/eval_claim.py subprocess: the evaluation is free LE,
# the seat owns the RECORD, not the reasoning) and the OUTCOME (the .operator
# activate row + the generation facts) — and persists it in the host-side obs
# file <store>.fx-claim-obs under fx-audit's observation discipline VERBATIM
# (enroll-first, keyed obs outside the store, rewrite-after-coherent,
# tmp+rename).  It never reimplements the store: versions and facts come from
# `fxstore timeline` / `fxstore facts <rel> --as-of N` (the fx-report.c
# pattern), and the seat keeps the comparisons the plan ranked most likely
# silently wrong, each binding's direction stated in the source: --landed-
# config is the STORE's generation_config fact for the riding generation
# (never the row's S_from), the facts dumps are --as-of the ROW's
# from_version (never the riding version), and the row's from_version must
# match the .operator row's from-version (outcome-ok rows only).  le is
# consumed as a dependency by the evaluator, never forked.  A DEPLOYMENT
# STOPGAP, labelled: the committed target is in-guest (qemu lane, x64 via
# QBE); the location must never become a reason to shrink the language.
# tests/test_claim.sh is the acceptance: fixtures built by the REAL writers
# (fx-activate activating configs that carry the two claim rows in extraEtc),
# every named disagreement class armed, the four mutants each blind on
# exactly its own fixture, obs stability (byte-identical re-run; a tampered
# obs fires verdict-rewritten), and the pinned pre-fix control: the
# prose-reader accepting the vacuous claim recorded as the before, the
# judge's refusal as the after.
BIN_CLAIM := build/fx-claim

test-claim: $(BIN_CLAIM)
	bash tests/test_claim.sh

$(BIN_CLAIM): tools/fx-claim.c src/vendor/dhall-c/sha256.c src/vendor/dhall-c/dhall.h
	@mkdir -p build
	$(CC) $(CFLAGS) -Isrc/vendor/dhall-c $(LDFLAGS) -o $@ tools/fx-claim.c src/vendor/dhall-c/sha256.c

.PHONY: test-claim

# THE OPS-POLICY UNIT's S1 GATE (the operator deny policy; plan
# handoff-oppolicy-plan, slice S1 — policy artifacts + release path +
# boundary gate, NO server change).  Three host-authored inputs under
# policy/ops/ — the OPERATOR-POLICY LEXICON (ops-lexicon.ini: closed,
# deny-more-only, `denied` the only head; NO `justified` — that absence is
# the two-author boundary against the claim unit), the OPERATOR POLICY
# (ops-policy.le: D1 the conditioned protected-path denial, D2 the
# boot-verdict-conditional denial a list cannot express) and the PINNED
# ALIAS TABLE (ops-aliases.tsv: operator path aliases -> runtime patterns,
# the bridge across the letters-only-proper-noun seam; an unresolvable alias
# is a LOUD refusal, never a silent non-match), compiled + linted +
# validated by policy/ops/eval_ops.py (a thin sibling of eval_claim.py; `le`
# consumed as a dependency, never forked).  DENY-MORE-ONLY: the policy
# tightens the compiled-in floors and never loosens them; the enforcement
# seat at the verbs server's commit sites is slice S2 and is NOT built here.
# tests/test_ops_policy.sh carries the pin/determinism arms, the lint
# refusals, the two-author boundary arms (each side refuses the other's
# predicate, and the boundary is shown to BE the closure by mutant), the
# alias-refusal arms and the deny-direction arms driven through the engine
# against a fixture fact set — each naming its failure direction (silent
# deny-all and silent allow-all are different defects, and both are armed).
test-ops-policy:
	bash tests/test_ops_policy.sh

# The ops policy release path (the policy-artifact pattern): regenerating the
# pinned artifact is a HOST release — it rewrites policy/ops/ops-policy.dl,
# and policy/ops/PINS' sha must be updated in the same commit (the gate
# fails until both agree).
ops-policy-artifact:
	LE_DIR=$(abspath $(LE_ROOT)) python3 policy/ops/eval_ops.py --compile-policy \
	    --policy-le policy/ops/ops-policy.le \
	    --policy-lexicon policy/ops/ops-lexicon.ini > policy/ops/ops-policy.dl.tmp
	mv policy/ops/ops-policy.dl.tmp policy/ops/ops-policy.dl
	@printf 'policy/ops/ops-policy.dl sha256: '; sha256sum policy/ops/ops-policy.dl | cut -d' ' -f1
	@printf 'policy/ops/PINS must carry exactly that value for ops-policy.dl\n'

.PHONY: test-ops-policy ops-policy-artifact

# THE CALLS-POLICY UNIT (P7 — the claim author at the host seat).  Three
# host-authored inputs under policy/calls/ — the AGENT-FACING CLOSED LEXICON
# (calls-lexicon.ini: NO `justified`, NO `denied` — that double absence IS the
# two-author boundary and the soundness boundary), the FROZEN POLICY
# (calls-policy.le + calls-policy-lexicon.ini, compiled into the sha-pinned
# rule-text artifact calls-policy.dl) and the PINNED VERB TABLE
# (calls-verbs.tsv: runtime verb -> abstract verb/purpose symbol, the bridge
# across the letters-only-proper-noun seam; the `forbidden` column is what the
# policy's `!forbidden_purpose` guard consumes) — compiled + linted + validated
# by policy/calls/eval_calls.py (a thin sibling of eval_claim.py; `le`
# consumed as a dependency, never forked).  The proxy (tools/fx-hostgate.c)
# SHELLS eval_calls.py per call exactly as fx-claim.c shells eval_claim.py —
# the reasoning is never reimplemented.  The artifact-level gate arms (the
# boundary mutant, vacuity, the letters-only seam, the two-author boundary)
# and the end-to-end justified=allow / not-justified=deny arms live in
# tests/test_hostgate.sh (P7 phases).
#
# The calls policy release path (the policy-artifact pattern): regenerating the
# pinned artifact is a HOST release — it rewrites policy/calls/calls-policy.dl,
# and policy/calls/PINS' sha must be updated in the same commit (the gate
# fails until both agree).
calls-policy-artifact:
	LE_DIR=$(abspath $(LE_ROOT)) python3 policy/calls/eval_calls.py --compile-policy \
	    --policy-le policy/calls/calls-policy.le \
	    --policy-lexicon policy/calls/calls-policy-lexicon.ini > policy/calls/calls-policy.dl.tmp
	mv policy/calls/calls-policy.dl.tmp policy/calls/calls-policy.dl
	@printf 'policy/calls/calls-policy.dl sha256: '; sha256sum policy/calls/calls-policy.dl | cut -d' ' -f1
	@printf 'policy/calls/PINS must carry exactly that value for calls-policy.dl\n'

.PHONY: calls-policy-artifact

# The slot ground for the first self-modification task (todo.md §5): the
# deployment pre-declares ONE package whose src.path is a directory the
# agent may write; the host-frozen recipe (a STUB — no Osier->Lua compiler
# exists yet, and the artifact SAYS so) turns the agent's source into a
# runnable artifact; the service RUNS in a guest; fx-osier-share moves
# 0% -> non-zero over the RUN SET on the GUEST'S OWN disk store, attributed
# by src_of.  Needs qemu+kvm, e2fsprogs (e2fsck/debugfs/mke2fs), zig, the
# built sibling fxstore, and fx-init's m3/package-set-slot.dhall.
test-agent-slot:
	bash tests/qemu-agent-slot.sh

.PHONY: test-agent-slot

# THE IN-GUEST BUILD GATE (todo.md §5's residual, closed): the agent writes,
# BUILDS (the payload's static x86_64-musl fxstore, via the pinned fx_build
# verb), activates and RUNS the slot — every step inside the guest, ONE
# image and ONE disk (sha-compared), no host build step, no read-back, no
# e2fsck/debugfs injection between boots.  Also proves the staged fxstore
# (a console --help probe) and stage3 (a dedicated usage boot) EXEC under
# the pinned kernel.  test-agent-slot stays green beside it: it still proves
# the CROSS-MACHINE claim (a HOST-built hash adopted by a GUEST activation)
# and the injection path a deployment without an in-guest builder needs.
# Same deps as test-agent-slot.
test-agent-slot-inguest:
	bash tests/qemu-agent-slot-inguest.sh

.PHONY: test-agent-slot-inguest

# The GUEST-ABI gate for the LuaJIT runtime (the Osier->Lua backend's
# premise): the x86_64 artifact build/luajit-x86_64.musl EXECUTES in the
# pinned-kernel qemu guest — console line + a durable marker on the virtio
# disk, with the JIT compiling traces in-guest — while the repo's i386
# artifact (the v86 lane's) cannot exec there at all (no IA32 emulation) and
# is the in-boot negative control.  Same deps as test-agent-slot, plus the
# vendored LuaJIT tree (tools/build-luajit.sh builds both artifacts).
test-luajit-guest:
	bash tests/qemu-luajit.sh

.PHONY: test-luajit-guest

clean:
	rm -rf build

# The two oracles of the agent loop.
#   test_resume.sh  — kills the harness mid-dispatch with a tool that SIGKILLs
#                     its parent, then asserts the transcript survived and that
#                     --resume seeds the loop from it.  It FAILS on a tree
#                     without the per-message flush + the resume seed (measured
#                     against this tree before the fix), so it is a real gate.
#   test_outcome.sh — the observation-loop oracle: a recorded activation whose
#                     boot FAILED is reported and NOT repeated (with the way out
#                     NAMED); one that took, a completed task, an unjudged
#                     activation, a torn record line, a prompt-drift, a forged
#                     record line, a resume seed and an unreadable store each get
#                     their own verdict; and the pre-fix artifact (make blind)
#                     re-runs the very task the real build refuses.  Both need
#                     the recorded SSE fixtures (tests/fixtures/): override
#                     their directory with FX_FIXTURE_DIR.
#   test_sameboot.sh — THE SAME-BOOT GUARD (the control-channel activation's
#                     self-interaction): PID1's hot-apply starts a SECOND agent
#                     instance for a config that redeclares the agent service,
#                     and that successor must not re-issue the still-unjudged
#                     activation (boot entry < CURRENT + the record's own
#                     version == CURRENT -> reported, exit 0), while a FRESH
#                     boot of the same generation (entry == CURRENT) still runs.
test: all blind
	bash tests/test_resume.sh
	bash tests/test_outcome.sh
	bash tests/test_sameboot.sh

.PHONY: all musl blind clean test
