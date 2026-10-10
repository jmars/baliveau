#!/bin/sh
# tools/build-luajit.sh -- cross-build the GUEST LuaJIT from the vendored, pinned
# source in src/vendor/luajit/ (see that directory's PIN file).
#
# Targets (both static, STRIPPED, FFI COMPILED OUT):
#   x86      -> build/luajit.musl               (+ .unstripped size reference)
#               ELF 32-bit i386.  The v86 LANE's artifact: that guest's CPU is
#               32-bit, so this is the ONLY artifact it can exec.
#   x86_64   -> build/luajit-x86_64.musl        (+ .unstripped size reference)
#               ELF 64-bit x86-64.  The QEMU LANE's artifact: its pinned kernel
#               has `# CONFIG_IA32_EMULATION is not set`, so the i386 artifact
#               CANNOT exec there at all (binfmt_elf's elf_check_arch rejects
#               it: execve -> ENOEXEC) -- MEASURED, see tests/qemu-agent.sh and
#               tools/stage-guest.sh's "GUEST ABI" note.  tests/qemu-luajit.sh
#               proves THIS artifact executes in that guest, with the i386 one
#               as the in-boot negative control.
#
# usage: tools/build-luajit.sh [x86|x86_64|all]    (default: all)
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
#    "cannot find -lgcc".  `zig cc -target <arch>-linux-musl` emits STATIC
#    binaries of the asked pointer size that run on this x86-64 HOST, which
#    satisfies the same-pointer-size rule without multilib.  Both HOST_CC and
#    CC are therefore the same zig invocation, and the same-pool rule is
#    ASSERTED ON THE BUILT TOOL, not assumed from the flag: buildvm's ELF class
#    is checked per target below (i386 build => i386 buildvm, x86_64 build =>
#    x86-64 buildvm).  The same-POOL rule runs BOTH ways: an x86_64 target
#    inherited i386 host tools would generate a 32-bit VM into a 64-bit binary.
#
#    SCOPE CAUTION, learned the hard way (tools/stage-guest.sh's "GUEST ABI"
#    note): "the zig i386 binary still RUNS on this x86-64 kernel" is a fact
#    about THIS HOST only -- this host's kernel has IA32 emulation.  It was
#    once written here as if it settled where the artifact runs; it settles
#    nothing about the qemu guest, whose pinned kernel refuses EM_386 exec.
#    Host-runnability is asserted below ONLY as a build gate, never as
#    evidence about any guest.
#
# 2. TARGET_SYS=Linux.  This is a cross build; without it the Makefile inherits
#    HOST_SYS.  TARGET_LJARCH needs NO pinning: the Makefile does not read uname,
#    it preprocesses lj_arch.h with TARGET_CC and takes x86/x64 from zig's
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
#    for the guest; it is PROVEN off by running the binary (gate 2 below), not
#    by reading the flag back.  The JIT is left ON -- it builds and compiles
#    traces on both targets.  The stdlib capability bounds (debug dropped,
#    package reduced) live in the VENDORED lib_init.c (see PIN's CORRECTION
#    section) and therefore apply to BOTH targets identically; they are proven
#    per artifact by tests/luajit-audit.sh, not here.
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

die() { echo "build-luajit: FATAL: $*" >&2; exit 1; }
say() { echo "build-luajit: $*"; }

command -v zig >/dev/null 2>&1 || die "zig not found (needed as HOST_CC and CC)"
[ -f "$VENDOR/PIN" ] || die "$VENDOR/PIN missing -- vendored source is not pinned"
[ -f "$VENDOR/src/Makefile" ] || die "$VENDOR/src/Makefile missing -- vendored tree incomplete"
command -v readelf >/dev/null 2>&1 || die "readelf not found (needed to assert no NEEDED entries)"
command -v file >/dev/null 2>&1 || die "file not found (needed to assert the artifact's ELF class)"

[ "$#" -gt 0 ] || set -- all
for arg in "$@"; do
    case "$arg" in
        x86|x86_64|all) ;;
        *) die "unknown target '$arg' (usage: tools/build-luajit.sh [x86|x86_64|all])" ;;
    esac
done
ARCHS=""
for arg in "$@"; do
    case "$arg" in
        all) ARCHS="x86 x86_64" ;;
        *)   ARCHS="$ARCHS $arg" ;;
    esac
done

mkdir -p build

# --- per-target properties (the ONLY things that differ between the two) -----
# FILE_RE    the exact `file -b` description of the stripped artifact
#            (tolerant of the optional ", version 1 (SYSV)" some `file` builds
#            insert).  Exact, not a substring: a drifted target must fail.
# MACHINE    the readelf -h Machine: string.
# BUILDVM_RE the same-pool assertion on the HOST TOOL buildvm.
target_props() { # target_props ARCH -> sets TRIPLE OUT FILE_RE MACHINE BUILDVM_RE
    case "$1" in
        x86)
            TRIPLE=x86-linux-musl
            OUT=build/luajit.musl
            FILE_RE='^ELF 32-bit LSB executable, Intel i386, (version [0-9]+ \(SYSV\), )?statically linked, stripped$'
            MACHINE='Intel 80386'
            BUILDVM_RE='ELF 32-bit.*Intel i386.*statically linked'
            ;;
        x86_64)
            TRIPLE=x86_64-linux-musl
            OUT=build/luajit-x86_64.musl
            FILE_RE='^ELF 64-bit LSB executable, x86-64, (version [0-9]+ \(SYSV\), )?statically linked, stripped$'
            MACHINE='Advanced Micro Devices X86-64'
            BUILDVM_RE='ELF 64-bit.*x86-64.*statically linked'
            ;;
        *) die "internal: unknown target $1" ;;
    esac
}

build_one() { # build_one ARCH
    ARCH=$1
    target_props "$ARCH"
    OUT_UNSTRIPPED=$OUT.unstripped
    ZCC="zig cc -target $TRIPLE"

    say "=== [$ARCH] target $TRIPLE -> $OUT ==="

    # --- build (clean first, then for real) ---------------------------------
    # `clean` first so the result is a from-clean build even if a previous run
    # (of EITHER target -- the two builds share the vendored tree) left
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
        || die "[$ARCH] make failed"

    RAW=$VENDOR/src/luajit
    [ -f "$RAW" ] || die "[$ARCH] make reported success but $RAW does not exist"

    # --- the host tools must be the SAME POINTER SIZE (same-pool rule) -------
    # Asserted on the BUILT TOOL's ELF class, per target: an i386 buildvm in an
    # x86_64 build (or vice versa) means the flag and the pool disagreed.
    if ! file -b "$VENDOR/src/host/buildvm" | grep -q "$BUILDVM_RE"; then
        die "[$ARCH] host build tool is not ${ARCH}-static: $(file -b "$VENDOR/src/host/buildvm")"
    fi
    say "host tools OK: $(file -b "$VENDOR/src/host/buildvm")"

    # --- strip, explicitly, out of tree -------------------------------------
    cp "$RAW" "$OUT_UNSTRIPPED"
    cp "$RAW" "$OUT.tmp"
    strip --strip-all "$OUT.tmp" || die "[$ARCH] strip failed"
    mv -f "$OUT.tmp" "$OUT"
    chmod 755 "$OUT"

    # --- ASSERT THE TARGET, LOUDLY ------------------------------------------
    # A wrong-arch (the other lane's target) or dynamically linked binary must
    # never be reported as a success.  These checks are on the artifact itself,
    # not on the flags passed.
    DESC=$(file -b "$OUT")
    say "file: $DESC"
    printf '%s\n' "$DESC" | grep -Eq "$FILE_RE" \
        || die "[$ARCH] unexpected artifact description: $DESC"
    readelf -h "$OUT" | grep -q "Machine:.*$MACHINE" \
        || die "[$ARCH] readelf says this is not $MACHINE: $(readelf -h "$OUT" | grep Machine)"
    if readelf -d "$OUT" 2>/dev/null | grep -q '(NEEDED)'; then
        die "[$ARCH] dynamic NEEDED entries present -- not a static binary:
$(readelf -d "$OUT")"
    fi

    # --- GATE 1: it runs on this HOST (a build gate only; says nothing
    #     about any guest -- see the SCOPE CAUTION above) ---------------------
    HELLO=$("$OUT" -e 'print("hello")') || die "[$ARCH] the artifact did not run"
    [ "$HELLO" = "hello" ] || die "[$ARCH] smoke test printed '$HELLO', not 'hello'"
    say "runs on this host: $($OUT -v)"

    # --- GATE 2: FFI must be ABSENT (this gate CAN fail) ---------------------
    # Proven by executing the binary, not by reading -DLUAJIT_DISABLE_FFI back.
    # Arch-independent: the FFI is compiled out at build time on both targets.
    set +e
    FFI_ERR=$("$OUT" -e 'require("ffi")' 2>&1)
    FFI_RC=$?
    set -e
    if [ "$FFI_RC" -eq 0 ]; then
        die "[$ARCH] FFI IS NOT DISABLED: require('ffi') SUCCEEDED (rc=0). The build is wrong."
    fi
    case "$FFI_ERR" in
        *"module 'ffi' not found"*) ;;
        *) die "[$ARCH] require('ffi') failed (rc=$FFI_RC) but not with 'module not found':
$FFI_ERR" ;;
    esac
    say "FFI gate OK: require('ffi') -> rc=$FFI_RC, $(printf '%s' "$FFI_ERR" | head -1)"

    # --- GATE 3: the JIT is on and compiles traces (TWO-SIDED) ---------------
    # Same probe shape for both targets: LuaJIT has native JIT backends for
    # x86 (32-bit) and x64 (64-bit) alike, so the arch-dependence here is only
    # in the emitted trace code, not in the mechanism.  Two-sided, so it CAN
    # fail: the same probe is run once with the JIT on (a trace must start)
    # and once with jit.off() (none may).  A counter that is simply broken, or
    # a JIT stubbed out, cannot pass both arms.
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
    JITOUT=$("$OUT" -e "$JITPROBE") || die "[$ARCH] JIT probe failed to run"
    JIT_ON=$(printf '%s' "$JITOUT" | cut -d' ' -f1)
    JIT_OFF=$(printf '%s' "$JITOUT" | cut -d' ' -f2)
    if [ "$JIT_ON" -lt 1 ]; then
        die "[$ARCH] no JIT trace was compiled with the JIT on (on=$JIT_ON off=$JIT_OFF) -- the JIT is off or broken"
    fi
    if [ "$JIT_OFF" -ne 0 ]; then
        die "[$ARCH] the JIT probe counted traces with jit.off() (on=$JIT_ON off=$JIT_OFF) -- the probe is unsound"
    fi
    say "JIT gate OK: traces started with JIT on=$JIT_ON, with jit.off()=$JIT_OFF"

    # --- sizes ----------------------------------------------------------------
    SZ_STRIPPED=$(wc -c < "$OUT")
    SZ_UNSTRIPPED=$(wc -c < "$OUT_UNSTRIPPED")
    say "size stripped   : $SZ_STRIPPED bytes  ($OUT)"
    say "size unstripped : $SZ_UNSTRIPPED bytes  ($OUT_UNSTRIPPED)"
    say "sha256 stripped : $(sha256sum "$OUT" | cut -d' ' -f1)"

    # --- leave the vendored tree pristine --------------------------------------
    say "cleaning $VENDOR again (vendored sources must not accumulate build litter) ..."
    make -C "$VENDOR/src" clean \
        HOST_CC="$ZCC -static" \
        CC="$ZCC" \
        TARGET_SYS=Linux \
        BUILDMODE=static \
        >/dev/null
}

for a in $ARCHS; do
    build_one "$a"
done
say "done"
