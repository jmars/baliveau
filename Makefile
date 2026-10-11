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

test-report: $(BIN_REPORT)
	bash tests/test_fx_report.sh

$(BIN_REPORT): tools/fx-report.c src/vendor/dhall-c/sha256.c src/vendor/dhall-c/dhall.h
	@mkdir -p build
	$(CC) $(CFLAGS) -Isrc/vendor/dhall-c $(LDFLAGS) -o $@ tools/fx-report.c src/vendor/dhall-c/sha256.c

.PHONY: test-report

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
