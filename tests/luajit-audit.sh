#!/bin/sh
# tests/luajit-audit.sh -- capability-bound audit for the guest LuaJIT artifact
# (src/vendor/luajit/src/lib_init.c, lj_lib_load[]; built by tools/build-luajit.sh).
#
# Usage: tests/luajit-audit.sh [path-to-artifact] [--arm2 [--arm2-out PATH]]
#   default artifact: build/luajit.musl          (i386  -- the v86 lane's)
#   the qemu lane's:  build/luajit-x86_64.musl   (x86-64)
#
# THE TWO ARMS ARE EXCLUSIVE.  Every invocation without --arm2 runs ARM 1 and
# nothing else; --arm2 runs ARM 2 and nothing else.  They cannot share one
# invocation: arm 2 runs IN the guest, which has neither file(1) nor readelf,
# and arm 1's static checks are not skippable (a skipped check reads as a pass).
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
#   ARM 1 -- the SHIPPED SURFACE (the default arm).  Asserts what the artifact
#   itself provably is and does, anywhere it runs: which libraries exist and
#   work, which are absent, that require() still resolves the preloads (the
#   package reduction must not have broken it), and that FFI stays absent.
#   This arm is the host gate: a mutation of the surface must make it fail.
#
#   ARM 2 -- the GUEST-ONLY HATCH PROBES.  os.execute and io.popen stay in the
#   surface DELIBERATELY (io/os are the admitted filesystem reach); they are
#   neutralized only by the guest environment -- system(3)/popen(3) resolve
#   /bin/sh, WHICH THE PIVOTED GUEST ROOT DOES NOT HAVE.  On THIS HOST there
#   IS a /bin/sh, so os.execute("true") SUCCEEDS here and an assertion that it
#   fails would be a claim about the host, wrong for the guest.  Arm 2
#   therefore refuses to run on any host that has /bin/sh.
#
#   WHO CALLS ARM 2 -- this arm is a SEAT, not a comment (MEASURED, 2026-10-13):
#   tests/qemu-luajit.sh boots the guest and its `luajit-arm2` service runs,
#   INSIDE that guest,
#       /usr/bin/busybox sh /usr/fx-agent/luajit-audit.sh \
#           /usr/fx-agent/bin/luajit --arm2 --arm2-out /fx/disk/<MARK>.arm2
#   (/usr/bin/busybox is the one shell the pivoted root has: the pivot binds
#   /lib64 and /usr only, and the image's /bin/sh symlink lives in the
#   initramfs layer the tmpfs root REPLACES -- that absence IS this arm's
#   premise.)  `make test-luajit-guest` asserts arm 2's console lines AND
#   reads the --arm2-out evidence back OFF THE RAW IMAGE -- the guest's stdout
#   dies with its tmpfs, so the disk file is the durable half.  A mutation
#   that lets the hatches leak fails that gate by name.  This script's arm 2
#   used to have NO caller at all: while it said "NOT YET RUN", the gate
#   re-implemented the same two probes inline in its Lua probe and folded the
#   answers into its own disk marker -- two implementations, one probe set,
#   and the one that exists to be run in the guest exercised by nothing.  The
#   inline duplicate is gone; this arm is the single implementation.
#
#   WHICH ARTIFACT ARM 2 MEASURES: the x86_64 artifact (build/luajit-x86_64.musl,
#   staged at /usr/fx-agent/bin/luajit).  The i386 artifact CANNOT EXEC in the
#   qemu guest at all -- the pinned kernel has no IA32 emulation, so execve
#   gives ENOEXEC -- and probing process reach through it would measure that
#   exec failure rather than the hatch; qemu-luajit.sh keeps the i386 artifact
#   as its negative CONTROL for exactly that reason.  Arm 2 makes the refusal
#   LOUD instead of silent: its ARM-EXECUTES control check fails by name on an
#   artifact that does not run, so a hatch result can never be read off a
#   binary that never started.  What arm 2 asserts is architecture-independent
#   (the Lua-visible os/io surface is the same code in both artifacts); it is
#   the artifact's ability to EXEC that is not.
#
#   (The third classic hatch, package.loadlib, is not in arm 2 because the
#   reduction removed it from the surface outright; arm 1 asserts its absence
#   everywhere, guest or not.)
#
# Exit code: 0 iff the arm that ran passed (arm 1 by default, arm 2 with
#   --arm2); 2 iff arm 2 refused because this is not the guest; 1 iff arm 1
#   or arm 2 failed.

set -eu
# Repo root, from this script's own path — WITHOUT dirname(1): arm 2 runs in
# the guest, whose PATH carries the busybox applets the image symlinks
# (mkinitramfs: sh/mount/mkfs.ext2/cp/rm/mv/sync) and NOT dirname; a missing
# dirname would leave `cd "$(dirname ...)/.."` becoming `cd /` and quietly
# change which artifact a RELATIVE path names.  Parameter expansion instead.
case "$0" in
    */*) SELF_DIR=${0%/*} ;;
    *)   SELF_DIR=. ;;
esac
cd "$SELF_DIR/.."

ART=build/luajit.musl
RUN_ARM2=0
ARM2_OUT=""

die() { echo "luajit-audit: FATAL: $*" >&2; exit 1; }
say() { echo "luajit-audit: $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
	--arm2) RUN_ARM2=1 ;;
	--arm2-out) [ $# -ge 2 ] || die "--arm2-out needs a path"; ARM2_OUT=$2; shift ;;
	*) ART=$1 ;;
    esac
    shift
done

[ -x "$ART" ] || die "artifact $ART missing or not executable (build it with tools/build-luajit.sh)"

# ── shared prologue: the checker both arms use ---------------------------------
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

# ── ARM 2: the guest-only hatch probes (--arm2; this arm is EXCLUSIVE) --------
# RUNS IN THE GUEST -- see the header for how it is invoked and why that
# invocation is possible at all.  Entered ONLY with --arm2: on a host the arm
# cannot mean anything (/bin/sh present means the hatches are EXPECTED to open,
# so a result from here would be a false claim about the guest), and arm 1
# needs file(1)+readelf(1), which the guest does not have -- so the two arms
# cannot share one invocation and this one exits or falls through to arm 1.
if [ "$RUN_ARM2" -eq 1 ]; then

    if [ -x /bin/sh ]; then
	say "ARM 2 REFUSED: /bin/sh is present, so this is not the guest -- $ART's"
	say "  hatch probes are expected to SUCCEED here by design; their results"
	say "  are not evidence about the guest and will not be collected."
	say "  (A refused run writes NO --arm2-out evidence: an absent file, never a"
	say "  stale or empty one, is what a caller sees if arm 2 never ran.)"
	exit 2
    fi

    say "ARM 2 (guest-only hatch probes): running IN the guest -- $ART"

    # CONTROL FIRST: the artifact must EXECUTE here, or the two probes below
    # measure the exec failure and not the hatch.  This is the check that makes
    # "arm 2 is meaningful for the x86_64 artifact only" a FAILING assertion
    # rather than a comment: run arm 2 on the i386 artifact in this guest and it
    # dies here, by name.  (qemu-luajit.sh runs the i386 artifact as its own
    # negative control, asserting ENOEXEC/BINFMT there; it does not run arm 2 on it.)
    probe 'print("arm2-alive")'
    check "ARM-EXECUTES control: the artifact runs in this environment" "arm2-alive"

    # os.execute("true") must NOT succeed: system(3) needs /bin/sh, absent in
    # the guest.  Shape-independent predicate: in Lua 5.1/LuaJIT success comes
    # back as 0 or true; anything else (nil, false, nonzero, 127/other) is the
    # hatch holding.
    probe 'local r = os.execute("true") print(tostring(r == 0 or r == true))'
    check "GUEST: os.execute('true') does not succeed (no /bin/sh)" "false"

    # io.popen must fail: popen(3) also forks /bin/sh.
    probe 'local f, e = io.popen("echo hi") print(tostring(f))'
    check "GUEST: io.popen fails (no /bin/sh)" "nil"

    if [ "$FAILED" -eq 0 ]; then
	VERDICT=held
	say "ARM 2: hatch probes held ($TOTAL checks passed: the ARM-EXECUTES control + the two hatch probes)"
    else
	VERDICT=FAILED
	say "ARM 2: $FAILED of $TOTAL checks FAILED (see the FAIL lines above) -- a leak is"
	say "  os.execute/io.popen succeeding; a failed ARM-EXECUTES control means the hatch"
	say "  question was NOT measured for this artifact, which is itself a failure"
    fi

    # The DURABLE HALF (--arm2-out): the guest's stdout dies with its tmpfs, so
    # the caller's evidence is this file, read back off the raw image by the
    # gate.  It is written for BOTH verdicts -- a leaked hatch must leave
    # durable evidence too, not just a console line -- and it binds the verdict
    # to the artifact by name, so evidence cannot be read as belonging to the
    # other ABI.  echo, not printf(1): the guest's PATH carries only the applets
    # the image symlinks, and this line needs no formatting the shell cannot do.
    if [ -n "$ARM2_OUT" ]; then
	echo "ARM2 art=${ART##*/} verdict=$VERDICT checks=$TOTAL failed=$FAILED" > "$ARM2_OUT" \
	    || die "cannot write the arm-2 evidence to $ARM2_OUT"
	# AND FLUSH IT.  MEASURED (this arm's first in-guest run, 2026-10-13): with
	# no flush the evidence file lands on the disk with the right NAME and ZERO
	# BYTES -- PID1 can stop the guest the moment it decides the boot verdict
	# (this lane's i386 control fails the boot BY CONSTRUCTION), so a
	# page-cache-only write is lost while its inode survives.  Linux's sync(2)
	# waits for the I/O; echo, not printf, because the guest's PATH carries
	# only the applets the image symlinks.
	if command -v sync >/dev/null 2>&1; then
	    sync
	elif [ -x /usr/bin/busybox ]; then
	    /usr/bin/busybox sync
	else
	    die "no sync available: $ARM2_OUT cannot be flushed, so the durable half would be a lie"
	fi
	say "ARM 2: evidence written and flushed -- $ARM2_OUT"
    fi

    [ "$FAILED" -eq 0 ] || exit 1
    exit 0
fi


# ── ARM 1: the shipped surface (the default arm) -------------------------------
# static checks on the artifact itself: the target must not have drifted.
# ARCHITECTURE-DEPENDENT (the only such checks in this file): the description
# must match EXACTLY ONE of the two blessed artifacts -- i386 (v86 lane) or
# x86-64 (qemu lane) -- and readelf's machine must corroborate the class
# file(1) announced.  Anything else (wrong class, dynamic, unstripped) fails.
# The two host tools arm 1 needs -- and the reason --arm2 cannot share an
# invocation with it: the guest has neither.  Absent here, this arm has not
# run, and it must say so rather than skip its checks silently.
command -v readelf >/dev/null 2>&1 || die "readelf not found"
command -v file >/dev/null 2>&1 || die "file(1) not found"
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

# Arm 2 did not run here (it was not selected) -- say so, and say WHO runs it,
# so this line cannot read as "not run anywhere" (it did say exactly that
# until 2026-10-13, while a guest image existed and the gate ran a second,
# inline copy of the same probes instead of calling this arm).
say "ARM 2 (guest-only hatch probes): NOT RUN -- this arm runs IN the guest, not on this host"
say "  caller: tests/qemu-luajit.sh (make test-luajit-guest), whose luajit-arm2"
say "  service runs this script with --arm2 inside the booted guest and reads the"
say "  result back off the raw disk image (tests/evidence/qemu-luajit/)."
exit 0
