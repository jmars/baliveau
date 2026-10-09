#!/bin/sh
# tools/build-luajit.sh -- cross-build the GUEST LuaJIT from the vendored, pinned
# source in src/vendor/luajit/ (see that directory's PIN file).
#
# Target: x86-linux-musl, static, i386, STRIPPED, FFI COMPILED OUT.
# Output: build/luajit.musl                    (the guest artifact, stripped)
#         build/luajit.musl.unstripped         (size reference for that artifact)
#
# Deliberately NOT a Makefile target: the Makefile has its own owner, and this is
# a vendored third-party build with its own toolchain rules.
#
# ---------------------------------------------------------------------------
# WHY THIS INVOCATION AND NOT LuaJIT'S DOCUMENTED ONE
#
# 1. HOST_CC.  LuaJIT requires its host build tools (minilua, buildvm) and the
#    target to have the SAME POINTER SIZE.  The documented answer is
#    `HOST_CC="gcc -m32"`, which is UNAVAILABLE here: this host is an immutable
#    openSUSE MicroOS with no multilib dev packages, so `gcc -m32` dies with
#    "cannot find -lgcc".  `zig cc -target x86-linux-musl` emits static 32-bit
#    i386 binaries that still RUN on this x86-64 kernel, which satisfies the
#    same-pointer-size rule without multilib.  Both HOST_CC and CC are therefore
#    the same zig invocation, and host/target pointer sizes are BOTH 4.
#
# 2. TARGET_SYS=Linux.  This is a cross build; without it the Makefile inherits
#    HOST_SYS.  TARGET_LJARCH needs NO pinning: the Makefile does not read uname,
#    it preprocesses lj_arch.h with TARGET_CC and takes x86 from zig's
#    predefined macros.  Asserted below (ELF class + machine, not the flag).
#
# 3. TARGET_XLIBS="-lm -lunwind".  musl has no libgcc_eh.  lj_err.c's DWARF
#    unwinder needs _Unwind_* / __register_frame / __deregister_frame, and
#    without them the link fails with eight undefined symbols.  zig ships
#    compiler-rt's libunwind, which supplies them.
#
# 4. TARGET_LDFLAGS="-static" -- explicit rather than relying on the default.
#
# 5. GIT_RELVER.  The vendored tree carries no .git, so LuaJIT's rolling-release
#    version would otherwise be the unexpanded `$Format:%ct$` placeholder from
#    .relver, not a version.  This pins the version string to the pinned
#    commit's ctime (1788856981, see PIN).
#
# 6. BUILDMODE=static and XCFLAGS=-DLUAJIT_DISABLE_FFI.  FFI-off is mandatory
#    for this guest; it is PROVEN off by running the binary (step 5 below), not
#    by reading the flag back.  The JIT is left ON -- the i386 JIT builds and
#    compiles traces on this target.
#
# 7. TARGET_STRIP=":"  -- ":" is the shell no-op.  The link output is left
#    unstripped so this script can report the unstripped size and then do the
#    one strip itself, explicitly, instead of having `make` do it invisibly.
#
# `make clean` brackets the build, so this reproduces the artifact from clean
# AND leaves the vendored tree byte-identical to the pinned commit afterwards
# (build/ is gitignored; the vendored sources must not accumulate build litter).
# ---------------------------------------------------------------------------

set -eu

cd "$(dirname "$0")/.."

VENDOR=src/vendor/luajit
OUT=build/luajit.musl
OUT_UNSTRIPPED=$OUT.unstripped
ZCC="zig cc -target x86-linux-musl"

die() { echo "build-luajit: FATAL: $*" >&2; exit 1; }
say() { echo "build-luajit: $*"; }

command -v zig >/dev/null 2>&1 || die "zig not found (needed as HOST_CC and CC)"
[ -f "$VENDOR/PIN" ] || die "$VENDOR/PIN missing -- vendored source is not pinned"
[ -f "$VENDOR/src/Makefile" ] || die "$VENDOR/src/Makefile missing -- vendored tree incomplete"
command -v readelf >/dev/null 2>&1 || die "readelf not found (needed to assert no NEEDED entries)"

mkdir -p build

# --- build (twice: once to reset, once for real) -----------------------------
# `clean` first so the result is a from-clean build even if a previous run left
# objects behind; then the actual build.
say "cleaning $VENDOR ..."
make -C "$VENDOR/src" clean \
    HOST_CC="$ZCC -static" \
    CC="$ZCC" \
    TARGET_SYS=Linux \
    BUILDMODE=static \
    >/dev/null

say "building (zig cc -> $ZCC, HOST_CC the same invocation) ..."
make -C "$VENDOR/src" -j"$(nproc 2>/dev/null || echo 4)" \
    HOST_CC="$ZCC -static" \
    CC="$ZCC" \
    TARGET_SYS=Linux \
    BUILDMODE=static \
    XCFLAGS="-DLUAJIT_DISABLE_FFI" \
    TARGET_LDFLAGS="-static" \
    TARGET_XLIBS="-lm -lunwind" \
    TARGET_STRIP=":" \
    "GIT_RELVER=echo 1788856981 > luajit_relver.txt" \
    || die "make failed"

RAW=$VENDOR/src/luajit
[ -f "$RAW" ] || die "make reported success but $RAW does not exist"

# --- the host tools must ALSO be i386 (same-pool rule), assert it ------------
if ! file -b "$VENDOR/src/host/buildvm" | grep -q 'ELF 32-bit.*Intel i386.*statically linked'; then
    die "host build tool is not 32-bit i386 static: $(file -b "$VENDOR/src/host/buildvm")"
fi
say "host tools OK: $(file -b "$VENDOR/src/host/buildvm")"

# --- strip, explicitly, out of tree -----------------------------------------
cp "$RAW" "$OUT_UNSTRIPPED"
cp "$RAW" "$OUT.tmp"
strip --strip-all "$OUT.tmp" || die "strip failed"
mv -f "$OUT.tmp" "$OUT"
chmod 755 "$OUT"

# --- ASSERT THE TARGET, LOUDLY ----------------------------------------------
# A host-arch (x86-64) or dynamically linked binary must never be reported as a
# success.  These checks are on the artifact itself, not on the flags passed.
DESC=$(file -b "$OUT")
say "file: $DESC"
# Strict, but tolerant of the optional ", version 1 (SYSV)" that some `file`
# builds insert: 32-bit + Intel i386 + statically linked + stripped, and NOT x86-64.
printf '%s\n' "$DESC" | grep -Eq '^ELF 32-bit LSB executable, Intel i386, (version [0-9]+ \(SYSV\), )?statically linked, stripped$' \
    || die "unexpected artifact description: $DESC"
if printf '%s\n' "$DESC" | grep -q 'x86-64'; then
    die "artifact is x86-64, not i386: $DESC"
fi
readelf -h "$OUT" | grep -q 'Machine:.*Intel 80386' \
    || die "readelf says this is not an Intel 80386 binary: $(readelf -h "$OUT" | grep Machine)"
if readelf -d "$OUT" 2>/dev/null | grep -q '(NEEDED)'; then
    die "dynamic NEEDED entries present -- not a static binary:
$(readelf -d "$OUT")"
fi

# --- GATE 1: it runs on this host -------------------------------------------
HELLO=$("$OUT" -e 'print("hello")') || die "the artifact did not run"
[ "$HELLO" = "hello" ] || die "smoke test printed '$HELLO', not 'hello'"
say "runs: $($OUT -v)"

# --- GATE 2: FFI must be ABSENT (this gate CAN fail) ------------------------
# Proven by executing the binary, not by reading -DLUAJIT_DISABLE_FFI back.
set +e
FFI_ERR=$("$OUT" -e 'require("ffi")' 2>&1)
FFI_RC=$?
set -e
if [ "$FFI_RC" -eq 0 ]; then
    die "FFI IS NOT DISABLED: require('ffi') SUCCEEDED (rc=0). The build is wrong."
fi
case "$FFI_ERR" in
    *"module 'ffi' not found"*) ;;
    *) die "require('ffi') failed (rc=$FFI_RC) but not with 'module not found':
$FFI_ERR" ;;
esac
say "FFI gate OK: require('ffi') -> rc=$FFI_RC, $(printf '%s' "$FFI_ERR" | head -1)"

# --- GATE 3: the JIT is on and compiles traces ------------------------------
# Two-sided, so it CAN fail: the same probe is run once with the JIT on (a trace
# must start) and once with jit.off() (none may).  A counter that is simply
# broken, or a JIT stubbed out, cannot pass both arms.
# NOTE the callback's FIRST argument is the event NAME ("start"/"stop"/"abort")
# and the trace number is the *second* -- the reverse of what the jit.attach
# doc-comment suggests.  Read off the emit sites, e.g. lj_trace.c: "setstrV(V,
# V->top++, lj_str_newlit(V, "start"))".
JITPROBE='
local on_starts, off_starts = 0, 0
jit.attach(function(what) if what == "start" then on_starts = on_starts + 1 end end, "trace")
local s = 0
for i = 1, 300 do s = s + i * 2 end
jit.off()
jit.attach(function(what) if what == "start" then off_starts = off_starts + 1 end end, "trace")
local t = 0
for i = 1, 300 do t = t + i * 2 end
print(on_starts .. " " .. off_starts)'
JITOUT=$("$OUT" -e "$JITPROBE") || die "JIT probe failed to run"
JIT_ON=$(printf '%s' "$JITOUT" | cut -d' ' -f1)
JIT_OFF=$(printf '%s' "$JITOUT" | cut -d' ' -f2)
if [ "$JIT_ON" -lt 1 ]; then
    die "no JIT trace was compiled with the JIT on (on=$JIT_ON off=$JIT_OFF) -- the JIT is off or broken"
fi
if [ "$JIT_OFF" -ne 0 ]; then
    die "the JIT probe counted traces with jit.off() (on=$JIT_ON off=$JIT_OFF) -- the probe is unsound"
fi
say "JIT gate OK: traces started with JIT on=$JIT_ON, with jit.off()=$JIT_OFF"

# --- sizes ------------------------------------------------------------------
SZ_STRIPPED=$(wc -c < "$OUT")
SZ_UNSTRIPPED=$(wc -c < "$OUT_UNSTRIPPED")
say "size stripped   : $SZ_STRIPPED bytes  ($OUT)"
say "size unstripped : $SZ_UNSTRIPPED bytes  ($OUT_UNSTRIPPED)"
say "sha256 stripped : $(sha256sum "$OUT" | cut -d' ' -f1)"

# --- leave the vendored tree pristine ---------------------------------------
say "cleaning $VENDOR again (vendored sources must not accumulate build litter) ..."
make -C "$VENDOR/src" clean \
    HOST_CC="$ZCC -static" \
    CC="$ZCC" \
    TARGET_SYS=Linux \
    BUILDMODE=static \
    >/dev/null
say "done"
