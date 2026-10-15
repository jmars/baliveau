#!/bin/sh
# tools/build.sh — build the fx-verbs MCP stdio tool server.
#
# Two artifacts, same source (tools/fx-verbs-server.c + the vendored yyjson +
# the vendored sha256 + the sibling datalog engine):
#   build/fx-verbs-server       native (cc) — the host-test arm; the smoke test
#                               (tests/verbs-smoke.sh) runs against this one
#                               with FX_VERB_ROOT pointing at a stub root.
#   build/fx-verbs-server.musl  static i386-musl via `zig cc -target
#                               x86-linux-musl` — the guest deployment target,
#                               the toolchain that builds every other fx guest
#                               binary (fx-init, fxstore, fx-core).
#
# Deliberately NOT a Makefile target: the Makefile has its own owner.  The
# SIBLING RESOLUTION and the musl static lib below REPLICATE the Makefile's
# ONE policy (DATALOG_DIR / DATALOG_MUSL_A) rather than inventing a second
# one — the engine and its build live in the sibling checkout, and both
# builders must resolve it identically (tests/test_sibling_paths.sh pins the
# resolution for the Makefile; this script follows the same three steps).

set -e
cd "$(dirname "$0")/.."
REPODIR=$(pwd)   # the sibling cd below must not lose it (the musl -p path)

CC=${CC:-cc}
CFLAGS="-std=c11 -O2 -g -Wall -Wextra -Isrc -Isrc/vendor/yyjson \
        -Isrc/vendor/dhall-c -Ibuild/include \
        -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE"
# src/agent/outcome.c is the ONE reader of the store's outcome files
# (<store>/.bootlog, <store>/.db/snapshots/CURRENT): the harness's boot-time
# consume and the fx_outcome/fx_generation verbs read them the same way, so the
# two cannot drift apart.  It is plain C with no yyjson/dhall dependency.
# src/vendor/dhall-c/sha256.c is the vendor hash (sha256_hex) the ops-policy
# seat verifies the pinned artifacts with — the ONE file the Makefile's
# BIN_REPORT link line already ships for the same reason.
SRC="tools/fx-verbs-server.c src/agent/outcome.c src/vendor/yyjson/yyjson.c \
     src/vendor/dhall-c/sha256.c"

# ── the sibling datalog engine (the Makefile's DATALOG_DIR policy, verbatim)
DATALOG_DIR=${DATALOG_DIR:-}
if [ -z "$DATALOG_DIR" ]; then
    if [ -f "../datalog-dafsa/zig-out/lib/libdatalog.so" ]; then
        DATALOG_DIR=../datalog-dafsa
    else
        DATALOG_DIR="$HOME/fixpoint-linux/datalog-dafsa"
    fi
fi
if [ ! -f "$DATALOG_DIR/zig-out/lib/libdatalog.so" ]; then
    echo "ERROR: DATALOG_DIR=$DATALOG_DIR has no zig-out/lib/libdatalog.so —" \
         "clone/checkout the sibling and build it (see Makefile)" >&2
    exit 1
fi
DATALOG_DIR=$(cd "$DATALOG_DIR" && pwd)

# runstore.h's include discipline, shared: "vendor/datalog-dafsa/src/dl.h"
# resolves through build/include's symlink to the ENGINE'S OWN headers — no
# src/ edit, and the verbs server's include line matches runstore.h's.
mkdir -p build/include/vendor/datalog-dafsa
ln -sfn "$DATALOG_DIR/src" build/include/vendor/datalog-dafsa/src

# The musl static engine, the Makefile's DATALOG_MUSL_A recipe: built by the
# sibling's OWN build.zig into build/datalog-musl (its authority on how the
# engine builds).  Built here only when absent — the Makefile target remains
# the owner of the artifact when `make` drives the tree.
DATALOG_MUSL_A=build/datalog-musl/lib/libdatalog.a
if [ ! -f "$DATALOG_MUSL_A" ]; then
    echo "== sibling engine (zig build -Dtarget=x86-linux-musl, static) =="
    (cd "$DATALOG_DIR" && zig build -Dtarget=x86-linux-musl -Drelease \
        -p "$REPODIR/build/datalog-musl" --build-file zig/build.zig) \
        || true
    if [ ! -f "$DATALOG_MUSL_A" ]; then
        echo "ERROR: $DATALOG_MUSL_A missing — the sibling's zig build for" \
             "x86-linux-musl did not produce libdatalog.a" >&2
        exit 1
    fi
fi

mkdir -p build

echo "== native =="
# shellcheck disable=SC2086
$CC $CFLAGS -o build/fx-verbs-server $SRC \
    -L"$DATALOG_DIR/zig-out/lib" -Wl,-rpath,"$DATALOG_DIR/zig-out/lib" \
    -ldatalog
echo "built build/fx-verbs-server"

if command -v zig >/dev/null 2>&1; then
    echo "== guest (zig cc -target x86-linux-musl, static) =="
    # execvpe is a GNU extension: the source #defines _GNU_SOURCE, and musl
    # provides it under that guard ("test, do not assume" — README gap 3).
    # Static musl links the STATIC engine (a glibc-built .so is incompatible
    # with elf_i386 — the Makefile's BIN_MUSL note, same pattern as fxstore).
    zig cc -target x86-linux-musl -static $CFLAGS \
        -o build/fx-verbs-server.musl $SRC \
        -Lbuild/datalog-musl/lib -ldatalog
    echo "built build/fx-verbs-server.musl"
else
    echo "zig not found: skipped the guest (musl) build" >&2
fi
