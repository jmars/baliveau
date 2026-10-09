#!/bin/sh
# tools/build.sh — build the fx-verbs MCP stdio tool server.
#
# Two artifacts, same source (tools/fx-verbs-server.c + the vendored yyjson):
#   build/fx-verbs-server       native (cc) — the host-test arm; the smoke test
#                               (tests/verbs-smoke.sh) runs against this one
#                               with FX_VERB_ROOT pointing at a stub root.
#   build/fx-verbs-server.musl  static i386-musl via `zig cc -target
#                               x86-linux-musl` — the guest deployment target,
#                               the toolchain that builds every other fx guest
#                               binary (fx-init, fxstore, fx-core).
#
# Deliberately NOT a Makefile target: the Makefile has its own owner and this
# server is self-contained (one .c + the vendored yyjson).

set -e
cd "$(dirname "$0")/.."

CC=${CC:-cc}
CFLAGS="-std=c11 -O2 -g -Wall -Wextra -Isrc/vendor/yyjson \
        -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE"
SRC="tools/fx-verbs-server.c src/vendor/yyjson/yyjson.c"

mkdir -p build

echo "== native =="
# shellcheck disable=SC2086
$CC $CFLAGS -o build/fx-verbs-server $SRC
echo "built build/fx-verbs-server"

if command -v zig >/dev/null 2>&1; then
    echo "== guest (zig cc -target x86-linux-musl, static) =="
    # execvpe is a GNU extension: the source #defines _GNU_SOURCE, and musl
    # provides it under that guard ("test, do not assume" — README gap 3).
    zig cc -target x86-linux-musl -static $CFLAGS \
        -o build/fx-verbs-server.musl $SRC
    echo "built build/fx-verbs-server.musl"
else
    echo "zig not found: skipped the guest (musl) build" >&2
fi
