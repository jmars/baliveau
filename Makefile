# fx-harness — a minimal, native agent harness for the fx-linux guest.
#
# Derived from vibe-runtime's LAYER-2 (src/llm2/) with TWO structural changes:
#
#   1. NO TLS / NO mbedTLS.  The guest has no socket layer at all (CONFIG_NET
#      unset => socket(2) is ENOSYS), so the model transport is a character
#      device bridged by a host-side proxy that holds the API key.  The
#      vendored mbedTLS tree (16 MB upstream) is not present; src/llm2/tls.h +
#      fx_transport.c supply the three symbols the stack references.
#
#   2. ONE backend.  backend_select.c's four-adapter factory is replaced by
#      fx_backend.c, which accepts "openai_responses" and returns -1 otherwise
#      (agent_main fail-opens to the same adapter).
#
# Explicit file lists, never shell globs (the upstream convention): the tree
# must build in sandboxes whose shells mangle '*' and multi-command pipelines.

CC      ?= cc
CFLAGS  := -std=c11 -O2 -g -Wall -Wextra \
           -ffile-prefix-map=$(CURDIR)=. -fdebug-prefix-map=$(CURDIR)=. \
           -Isrc -Isrc/llm2 -Isrc/vendor/dhall-c -Isrc/vendor/yyjson \
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
DATALOG_DIR ?= ../datalog-dafsa
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

# ─── LAYER 2: the agent loop ───────────────────────────────────────────────
L2_SRC := src/llm2/agent_main.c \
          src/llm2/agent_loop.c \
          src/llm2/checkpoint.c \
          src/llm2/config.c \
          src/llm2/dhall_eval_lock.c \
          src/llm2/mcp_client.c \
          src/llm2/outcome.c \
          src/llm2/tool_policy.c \
          src/llm2/tui.c \
          src/llm2/sse.c \
          src/llm2/openai_responses.c \
          src/llm2/fx_transport.c \
          src/llm2/fx_backend.c

# ─── LAYER 1 sources the loop reuses ──────────────────────────────────────
L1_SRC := src/runner.c src/runstore.c src/secrets.c

ALL_SRC := $(L2_SRC) $(L1_SRC) $(DHALL_SRC) $(YYJSON_SRC) $(TOMLC99_SRC)

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

$(BIN): src/llm2/agent_main_main.c $(ALL_SRC) \
        $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ src/llm2/agent_main_main.c $(ALL_SRC) \
	    -L$(DATALOG_DIR)/zig-out/lib \
	    -Wl,-rpath,$(abspath $(DATALOG_DIR)/zig-out/lib) -ldatalog

# The guest binary.  Not part of `all`: it is the deployment target, verified
# separately once the native build is green.  -s strips it (guest artifacts
# ship stripped).
musl: $(BIN_MUSL)

$(BIN_MUSL): src/llm2/agent_main_main.c $(ALL_SRC) $(DATALOG_MUSL_A) | $(DATALOG_SHIM)
	@mkdir -p build
	$(MUSL_CC) $(MUSL_CFLAGS) $(LDFLAGS) -o $@ src/llm2/agent_main_main.c $(ALL_SRC) \
	    -L$(DATALOG_MUSL_LIB) -ldatalog -s

# THE PRE-FIX ARTIFACT of the observation loop (src/llm2/outcome.h): the SAME
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

$(BIN_BLIND): src/llm2/agent_main_main.c $(ALL_SRC) $(DATALOG_DIR)/zig-out/lib/libdatalog.so | $(DATALOG_SHIM)
	@mkdir -p build
	$(CC) $(CFLAGS) -DFX_HARNESS_NO_OBSERVE $(LDFLAGS) -o $@ src/llm2/agent_main_main.c $(ALL_SRC) \
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
#                     upstream's recorded SSE fixtures: override their directory
#                     with VIBE_FIXTURE_DIR.
test: all blind
	bash tests/test_resume.sh
	bash tests/test_outcome.sh

.PHONY: all musl blind clean test
