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
           -Isrc -Isrc/llm2 -Isrc/vendor/dhall-c -Isrc/vendor/yyjson \
           -Isrc/vendor/datalog-dafsa/src -Isrc/vendor/datalog-dafsa/vendor \
           -Isrc/vendor/tomlc99 \
           -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE
LDFLAGS :=

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

# ─── vendored: datalog-dafsa (the runstore + checkpoint backend) ───────────
DL_SRC := src/vendor/datalog-dafsa/src/analyze.c \
          src/vendor/datalog-dafsa/src/compiler.c \
          src/vendor/datalog-dafsa/src/dl.c \
          src/vendor/datalog-dafsa/src/intern.c \
          src/vendor/datalog-dafsa/src/iter.c \
          src/vendor/datalog-dafsa/src/magic.c \
          src/vendor/datalog-dafsa/src/parser.c \
          src/vendor/datalog-dafsa/src/permindex.c \
          src/vendor/datalog-dafsa/src/regexwalk.c \
          src/vendor/datalog-dafsa/src/relation.c \
          src/vendor/datalog-dafsa/src/snapshot.c \
          src/vendor/datalog-dafsa/src/termstore.c \
          src/vendor/datalog-dafsa/src/topdown.c \
          src/vendor/datalog-dafsa/src/tupleset.c \
          src/vendor/datalog-dafsa/src/util.c \
          src/vendor/datalog-dafsa/src/vm.c \
          src/vendor/datalog-dafsa/src/vrelation.c

DL_VENDOR_SRC := src/vendor/datalog-dafsa/vendor/dafsa.c \
                 src/vendor/datalog-dafsa/vendor/dafsa_build.c \
                 src/vendor/datalog-dafsa/vendor/dafsa_core.c \
                 src/vendor/datalog-dafsa/vendor/dafsa_crc32.c \
                 src/vendor/datalog-dafsa/vendor/dafsa_persist.c \
                 src/vendor/datalog-dafsa/vendor/dafsa_rank.c \
                 src/vendor/datalog-dafsa/vendor/dafsa_state.c \
                 src/vendor/datalog-dafsa/vendor/dafsa_view.c \
                 src/vendor/datalog-dafsa/vendor/dafsa_view_rank.c \
                 src/vendor/datalog-dafsa/vendor/dafsa_wal.c

# ─── LAYER 2: the agent loop ───────────────────────────────────────────────
L2_SRC := src/llm2/agent_main.c \
          src/llm2/agent_loop.c \
          src/llm2/checkpoint.c \
          src/llm2/config.c \
          src/llm2/dhall_eval_lock.c \
          src/llm2/mcp_client.c \
          src/llm2/tool_policy.c \
          src/llm2/tui.c \
          src/llm2/sse.c \
          src/llm2/openai_responses.c \
          src/llm2/fx_transport.c \
          src/llm2/fx_backend.c

# ─── LAYER 1 sources the loop reuses ──────────────────────────────────────
L1_SRC := src/runner.c src/runstore.c src/secrets.c

ALL_SRC := $(L2_SRC) $(L1_SRC) $(DHALL_SRC) $(YYJSON_SRC) $(TOMLC99_SRC) \
           $(DL_SRC) $(DL_VENDOR_SRC)

BIN      := build/fx-agent
BIN_MUSL := build/fx-agent.musl

all: $(BIN)

$(BIN): src/llm2/agent_main_main.c $(ALL_SRC)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ src/llm2/agent_main_main.c $(ALL_SRC)

# The guest binary.  Not part of `all`: it is the deployment target, verified
# separately once the native build is green.
musl: $(BIN_MUSL)

$(BIN_MUSL): src/llm2/agent_main_main.c $(ALL_SRC)
	@mkdir -p build
	$(MUSL_CC) $(MUSL_CFLAGS) $(LDFLAGS) -o $@ src/llm2/agent_main_main.c $(ALL_SRC)

clean:
	rm -rf build

# The resume oracle (tests/test_resume.sh): kills the harness mid-dispatch with
# a tool that SIGKILLs its parent, then asserts the transcript survived and that
# --resume seeds the loop from it.  It FAILS on a tree without the per-message
# flush + the resume seed (measured against this tree before the fix), so it is
# a real gate, not a smoke test.  Needs upstream's recorded SSE fixtures:
# override their directory with VIBE_FIXTURE_DIR=<dir>.
test: all
	bash tests/test_resume.sh

.PHONY: all musl clean test
