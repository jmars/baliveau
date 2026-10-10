#!/bin/sh
# tests/luajit-audit.sh -- capability-bound audit for the guest LuaJIT artifact
# (src/vendor/luajit/src/lib_init.c, lj_lib_load[]; built by tools/build-luajit.sh).
#
# Usage: tests/luajit-audit.sh [path-to-artifact] [--arm2]
#   default artifact: build/luajit.musl          (i386  -- the v86 lane's)
#   the qemu lane's:  build/luajit-x86_64.musl   (x86-64)
#
# PER-TARGET vs ARCHITECTURE-INDEPENDENT checks: the ONLY arch-dependent
# checks in this audit are the two static ELF checks at the top of arm 1
# (the exact `file -b` description and the corroborating readelf machine),
# which accept EXACTLY the two blessed descriptions -- i386 and x86-64 --
# and fail on anything else; nothing is skipped for either target.  Every
# probe below them asserts the Lua-visible surface (the lj_lib_load[] bounds
# and the FFI compile-out baked into BOTH targets from the same vendored
# tree), which is architecture-independent by construction -- that is the
# claim, and it is re-proven per artifact by simply running this audit on
# both, which the gates do.
#
# The audit is split into two arms, and the split is the point:
#
#   ARM 1 -- the SHIPPED SURFACE.  Asserts what the artifact itself provably
#   is and does, anywhere it runs: which libraries exist and work, which are
#   absent, that require() still resolves the preloads (the package reduction
#   must not have broken it), and that FFI stays absent.  This arm is the
#   gate: a mutation of the surface must make it fail.
#
#   ARM 2 -- the GUEST-ONLY HATCH PROBES.  os.execute and io.popen stay in the
#   surface DELIBERATELY (io/os are the admitted filesystem reach); they are
#   neutralized only by the guest environment -- system(3)/popen(3) need
#   /bin/sh, WHICH THE GUEST IMAGE DOES NOT SHIP.  On THIS HOST there IS a
#   /bin/sh, so os.execute("true") SUCCEEDS here and an assertion that it
#   fails would be a claim about the host, wrong for the guest.  Arm 2
#   therefore (a) does not run unless --arm2 is passed, (b) refuses to run on
#   any host that has /bin/sh, and (c) has NEVER RUN ANYWHERE YET: no guest
#   image exists as of 2026-10-09, so its expectations are UNVERIFIED -- do
#   not cite them as evidence.  (The third classic hatch, package.loadlib, is
#   not in arm 2 because the reduction removed it from the surface outright;
#   arm 1 asserts its absence everywhere, guest or not.)
#
# Exit code: 0 iff arm 1 passes (and arm 2, if it ran, passes).

set -eu
cd "$(dirname "$0")/.."

ART=build/luajit.musl
RUN_ARM2=0
for arg in "$@"; do
    case "$arg" in
	--arm2) RUN_ARM2=1 ;;
	*) ART=$arg ;;
    esac
done

die() { echo "luajit-audit: FATAL: $*" >&2; exit 1; }
say() { echo "luajit-audit: $*"; }

[ -x "$ART" ] || die "artifact $ART missing or not executable (build it with tools/build-luajit.sh)"
command -v readelf >/dev/null 2>&1 || die "readelf not found"

# ── ARM 1: the shipped surface -----------------------------------------------
# Every check must be able to fail: each probe asserts exact output, and a
# probe that itself errors (nonzero rc) fails its check.  Failures accumulate;
# nothing is fail-fast, so a mutation report lists everything it broke.

TOTAL=0
FAILED=0

note_fail() { FAILED=$((FAILED + 1)); say "FAIL: $*"; }

# probe <lua-chunk>: run the artifact, capture output and rc (stderr included,
# so a Lua error surfaces as a mismatch, never as a silent pass).
PROBE_OUT=""
PROBE_RC=0
probe() {
    set +e
    PROBE_OUT=$("$ART" -e "$1" 2>&1)
    PROBE_RC=$?
    set -e
}

# check <name> <expected-exact-output>
check() {
    TOTAL=$((TOTAL + 1))
    if [ "$PROBE_RC" -ne 0 ]; then
	note_fail "$1 -- probe exited rc=$PROBE_RC: $PROBE_OUT"
    elif [ "$PROBE_OUT" != "$2" ]; then
	note_fail "$1 -- expected [$2], got [$PROBE_OUT]"
    else
	say "  ok: $1"
    fi
}

# static checks on the artifact itself: the target must not have drifted.
# ARCHITECTURE-DEPENDENT (the only such checks in this file): the description
# must match EXACTLY ONE of the two blessed artifacts -- i386 (v86 lane) or
# x86-64 (qemu lane) -- and readelf's machine must corroborate the class
# file(1) announced.  Anything else (wrong class, dynamic, unstripped) fails.
DESC=$(file -b "$ART")
TOTAL=$((TOTAL + 1))
ARCH_DESC=""
if printf '%s\n' "$DESC" | grep -Eq '^ELF 32-bit LSB executable, Intel i386, (version [0-9]+ \(SYSV\), )?statically linked, stripped$'; then
    ARCH_DESC=i386
    say "  ok: artifact is i386, statically linked, stripped"
elif printf '%s\n' "$DESC" | grep -Eq '^ELF 64-bit LSB executable, x86-64, (version [0-9]+ \(SYSV\), )?statically linked, stripped$'; then
    ARCH_DESC=x86-64
    say "  ok: artifact is x86-64, statically linked, stripped"
else
    note_fail "artifact description changed: $DESC"
fi
TOTAL=$((TOTAL + 1))
case "$ARCH_DESC" in
    i386)
	readelf -h "$ART" | grep -q 'Machine:.*Intel 80386' \
	    && say "  ok: readelf machine is Intel 80386" \
	    || note_fail "file said i386 but readelf machine differs: $(readelf -h "$ART" | grep Machine)" ;;
    x86-64)
	readelf -h "$ART" | grep -q 'Machine:.*Advanced Micro Devices X86-64' \
	    && say "  ok: readelf machine is AMD x86-64" \
	    || note_fail "file said x86-64 but readelf machine differs: $(readelf -h "$ART" | grep Machine)" ;;
    *)
	note_fail "ELF class unrecognized -- the readelf machine check could not run" ;;
esac
TOTAL=$((TOTAL + 1))
if readelf -d "$ART" 2>/dev/null | grep -q '(NEEDED)'; then
    note_fail "artifact has dynamic NEEDED entries -- not a static binary"
else
    say "  ok: artifact has zero NEEDED entries"
fi

# -- ABSENT: debug (dropped outright from lj_lib_load[]) and ffi (compiled out).
probe 'print(string.format("%s %s", tostring(debug), tostring(ffi)))'
check "debug and ffi globals are nil" "nil nil"

# -- ABSENT: require("ffi") must fail, with the module-not-found error
#    (the same error tools/build-luajit.sh gate 2 demands).
probe 'local ok, err = pcall(require, "ffi") print(string.format("%s|%s", tostring(ok), (tostring(err):gsub("\n.*", ""))))'
check "require('ffi') fails with module-not-found" "false|module 'ffi' not found:"

# -- CONTROL: the package reduction kept require() working for the preloads.
#    jit.util is pre-registered by luaopen_jit (src/lib_jit.c); if this fails
#    the package library was broken, not reduced.
probe 'local u = require("jit.util") print(string.format("%s %s %s", type(u), type(u.funcinfo), require("jit.util") == u))'
check "CONTROL require('jit.util') resolves, is cached" "table function true"
probe 'print(type(require("jit.profile")))'
check "CONTROL require('jit.profile') resolves" "table"

# -- REDUCED: the package surface.  require + preload/loaded + the single
#    preload loader survive; loadlib/searchpath, path/cpath, the module-system
#    helpers and the search itself are gone.
probe 'local p = package print(string.format("%s %s %s %s %s %s %s %s %s %s %s %s", type(p), tostring(p.loadlib), tostring(p.searchpath), tostring(p.seeall), tostring(p.path), tostring(p.cpath), tostring(p.config), tostring(p.searchers), tostring(module), type(require), tostring(p.loaders ~= nil and p.loaders[1] ~= nil and p.loaders[2] == nil), tostring(p.preload ~= nil and p.loaded ~= nil)))'
check "package surface: require+tables only, fs search gone" \
    "table nil nil nil nil nil nil nil nil function true true"
#    A require of something absent must fail through the PRELOAD path (no
#    fallback to file/dl loaders), with the standard not-found error.
probe 'local ok, err = pcall(require, "no.such.mod") print(string.format("%s|%s", tostring(ok), (tostring(err):gsub("\n.*", ""))))'
check "require of unknown module: preload-only not-found" \
    "false|module 'no.such.mod' not found:"

# -- PRESENT AND FUNCTIONAL: every library the reduction intends to keep.
probe 'assert(type(assert) == "function" and type(pairs) == "function" and type(ipairs) == "function" and type(loadstring) == "function") assert(loadstring("return 42")() == 42) print("ok")'
check "base functional (incl. the compiler: loadstring)" "ok"
probe 'local t = {3, 1, 2} table.sort(t) assert(t[1] == 1 and t[3] == 3) assert(table.concat({1, 2}, "-") == "1-2") assert(type(table.insert) == "function" and type(table.remove) == "function") print("ok")'
check "table functional" "ok"
probe 'assert(("ab"):rep(2) == "abab" and string.format("%d", 42) == "42" and ("a,b"):find(",") == 2 and ("ABC"):lower() == "abc") print("ok")'
check "string functional" "ok"
probe 'assert(math.floor(math.pi) == 3 and math.max(1, 9) == 9 and math.huge > 1e308 and math.abs(-2) == 2) print("ok")'
check "math functional" "ok"
probe 'assert(bit.band(6, 3) == 2 and bit.bxor(5, 3) == 6 and bit.lshift(1, 4) == 16 and bit.tobit(-1) < 0) print("ok")'
check "bit functional" "ok"
probe 'local co = coroutine.wrap(function(a) local b = coroutine.yield(a + 1) return b * 2 end) assert(co(1) == 2) assert(co(10) == 20) print("ok")'
check "coroutine functional (yield/resume round-trip)" "ok"
probe 'assert(jit and jit.status() == true and type(jit.version) == "string") print("ok")'
check "jit present, JIT compiler on" "ok"
probe 'io.write("iowrite-ok")'
check "io functional (io.write to real stdout)" "iowrite-ok"
probe 'print(string.format("%s %s %s", type(io.open), type(io.popen), type(io.lines)))'
check "io surface: open/popen/lines present (DELIBERATE admission)" \
    "function function function"
probe 'print(string.format("%s %s", type(os.time()), type(os.date())))'
check "os functional (time/date)" "number string"
probe 'print(string.format("%s %s %s %s", type(os.execute), type(os.getenv), type(os.exit), type(os.remove)))'
check "os surface: execute/getenv/exit/remove present (DELIBERATE admission)" \
    "function function function function"

if [ "$FAILED" -eq 0 ]; then
    say "ARM 1 (shipped surface): ALL $TOTAL CHECKS PASSED -- $ART"
else
    say "ARM 1 (shipped surface): $FAILED of $TOTAL CHECKS FAILED -- $ART"
    exit 1
fi

# ── ARM 2: guest-only hatch probes (NOT evidence unless run IN the guest) ----
# Status as of 2026-10-09: NOT YET RUN ANYWHERE.  No guest image exists, so
# the expectations below are UNVERIFIED claims about the guest environment.

if [ "$RUN_ARM2" -ne 1 ]; then
    say "ARM 2 (guest-only hatch probes): NOT YET RUN -- pass --arm2 once a guest image exists"
    exit 0
fi

# Refuse to run where the arm cannot mean anything: a host with /bin/sh makes
# os.execute/io.popen SUCCEED, and "they fail" would be a false claim about
# that host rather than a true one about the guest.
if [ -x /bin/sh ]; then
    say "ARM 2 REFUSED: /bin/sh present, so this is not the guest. The hatch"
    say "  probes below are expected to SUCCEED here by design -- their results"
    say "  are not evidence about the guest and will not be collected."
    exit 2
fi

say "ARM 2 (guest-only hatch probes): running IN the guest"

# os.execute("true") must NOT succeed: system(3) needs /bin/sh, absent in the
# guest.  Shape-independent predicate: in Lua 5.1/LuaJIT success comes back as
# 0 or true; anything else (nil, false, nonzero, 127/other) is the hatch holding.
probe 'local r = os.execute("true") print(tostring(r == 0 or r == true))'
check "GUEST: os.execute('true') does not succeed (no /bin/sh)" "false"

# io.popen must fail: popen(3) also forks /bin/sh.
probe 'local f, e = io.popen("echo hi") print(tostring(f))'
check "GUEST: io.popen fails (no /bin/sh)" "nil"

if [ "$FAILED" -eq 0 ]; then
    say "ARM 2: hatch probes held ($TOTAL checks passed)"
else
    say "ARM 2: $FAILED hatch probe(s) DID NOT HOLD -- the guest leaks process reach"
    exit 1
fi
