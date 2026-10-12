#!/bin/sh
# tests/test_fx_audit.sh — THE DISCRIMINATION PROOF for the AUDIT SEAT
# (tools/fx-audit.c; todo.md §4, design record §6b "auditing, not proofing").
#
# A DETECTOR THAT CANNOT FAIL IS NOT A DETECTOR, so every assertion here is
# built as an incoherence that MUST fire (and, where noted, a control arm
# that must NOT):
#
#   CLEAN       a store whose records all agree passes — and "clean" is
#               DEFINED, so a future reader can re-derive it: a store
#               written only by the real writers (fx-activate via its
#               host-side binary, `fxstore rollback` for the roll-forward),
#               every fact-named store path materialized, a .bootlog whose
#               verdicts agree with .recovery, a rootfs that `fxstore
#               verify` reconciles, CURRENT a published version, and a
#               coherent observation history (the store is audited, then
#               audited AGAIN — idempotence is part of clean).
#   RWF         a .recovery row whose from-failed version's last bootlog
#               verdict is NOT failed/in-progress fires
#               recovery-without-failure (control: the same row pointing at
#               the recorded failure does not).
#   DRIFT       an unmanaged rootfs file fires verify-drift through
#               `fxstore verify` exit 1 (control: the clean rootfs passes).
#   GONE        deleting a store dir the provides facts name fires
#               facts-path-gone.
#   CHAIN       CURRENT=99 (not a published version) fires version-chain;
#               a .recovery row carrying a WRONG content genhash fires
#               version-chain's recovery cross-check while
#               recovery-without-failure still passes (the failure IS
#               recorded) — two readers, one lie.
#   DAMAGED     a terminated .bootlog line in a shape fx-init never writes
#               fires bootlog-damaged.
#   VANISHED    .recovery present at the previous observation and now gone
#               fires record-vanished.
#   ARTIFACT    a src_of source artifact materialized, enrolled, then
#               removed fires disagreement-artifact-gone.
#   FACTS       a SECOND store, same version numbers, different content,
#               audited against the FIRST store's observation file fires
#               disagreement-facts-changed (control: audited against its
#               own observation it is coherent) — history was rebuilt
#               between audits.
#   COHERENT    THE LOAD-BEARING ARM: a generation that rewrites ALL of its
#               own records CONSISTENTLY (.bootlog "2 failed" -> "2 ok", the
#               .recovery row stripped — every in-guest record now agrees)
#               passes EVERY cross-check and is caught ONLY by the
#               previous-observation comparison (disagreement-*-rewritten).
#               The mutation control below proves the "only": a detector
#               built without the comparison goes COHERENT on exactly this
#               fixture.
#   BOOTS       --boots is the off-disk anchor (the host's cumulative boot
#               count on the store).  It is REQUIRED: without it the tool
#               REFUSES (exit 2) — an optional anchor that silently defaults
#               is a decorative bound.
#   FORGERY     THE MEASURED HOLE, closed: an APPENDED "<failed v> ok" in
#               the writer's exact shape (the forge that feeds bootlog_last
#               a verdict no boot produced, so fx-init does NOT roll
#               forward) fires bootlog-forged-verdict, named in those terms.
#               FABBOOT: a COMPLETE forged boot (in-progress + verdict) with
#               no host boot behind it fires bootlog-fabricated-boots.
#               TORNFORGE: the same forge WITHOUT its trailing newline
#               (fgets still returns it in-guest) fires too.
#   TORNLEGIT   a boot whose append was CUT SHORT — its in-progress line
#               landed, its verdict line is torn (no trailing newline) — is
#               a CRASH the reader itself classes as "mid-write, not
#               tamper", and the host count accounts for the boot: it stays
#               COHERENT and LOUD (the torn tail and the in-progress behind
#               it are both named), never a finding.  TORNLEGIT-BEFORE pins
#               the FALSE POSITIVE the review MEASURED on fcebaa3: the
#               pre-fix tool rejects the same store (exit 1) with a message
#               naming an in-progress the SAME run's accounting line prints
#               as present.
#   KNOWN-HOLE→CLOSED  the forged PAIR (in-progress + verdict) into a silent
#               boot's slack was the admitted bound; the per-boot NONCE
#               closes it and the arms assert the closing from both sides:
#               PAIRSIL  the pair wearing a nonce the host never issued for
#                        a window boot (invented / the 'none' placeholder /
#                        a past window's / no field at all) fires
#                        bootlog-unbound-nonce, and the silent boot's OWN
#                        nonce is REPORTED as UNCLAIMED (info, coherent
#                        direction: never a rollback of a healthy machine);
#               PAIRONTOP the pair wearing a REAL window nonce that the
#                        boot's own lines already spent — a forger that READ
#                        a nonce off the disk cannot reuse it: per-nonce
#                        accounting fires bootlog-fabricated-boots;
#               PAIRNOLEDGER  --nonces absent with boots in the window is
#                        exit 2 (an anchor that silently defaults is
#                        decorative — the --boots rule, applied to the
#                        nonce ledger);
#               FORMAT2  a format-2 observation (pre-nonce) is REFUSED with
#                        a re-enroll instruction, the way format-1 was;
#               NONELEDGER  a ledger entry whose nonce is the literal
#                        'none' is exit 2 — the WRITER reserves that token
#                        (parse_kernel_nonce refuses fx.bootnonce=none), so
#                        the host can never have issued it; accepting it
#                        would make every placeholder line claimable as
#                        that boot's.
#   REARM       the WRITER's second verdict per boot, derived not patched:
#               the in-guest `activate` publishes a NEW version (the
#               store's CURRENT moves), appends the ACTIVATED version's own
#               "<v> in-progress" for it (init.zig:3543, the re-arm marker
#               this unit's writer change added) and RE-ARMS the boot
#               decision (init.zig:3616-3619), so ONE boot under ONE nonce
#               legitimately carries a verdict for a second version —
#               fx-init's own suite measures the second DISK verdict
#               (tests/qemu_boot_rollback.sh:18-27).
#               The per-NONCE VERDICT budget (verdicts<=1 per nonce) rested
#               on "the g_boot_decided latch allows one verdict per boot"
#               and the writer refutes it — a HEALTHY boot audited as a
#               forgery, the direction that rolls back a live machine.
#               The derived accounting: verdicts are budgeted PER VERSION
#               (<= in-progress lines for the version, + 1 ONLY for a
#               first-published version with NO re-arm ip of its own) and a
#               verdict's provenance is EITHER a same-nonce in-progress
#               (the boot's own, or the re-arm's own) OR the store's own
#               record that the version was first published in the window;
#               the IN-PROGRESS budget is per nonce with the FIRST line =
#               that boot's OWN and every later one an activate re-arm
#               (first-published in the window, newer than the booted
#               version).  Arms:
#               REARM    the OLD-writer healthy shape (boot pair + the
#                        re-arm verdict for the activated version with NO
#                        ip of its own, one nonce) stays COHERENT and the
#                        re-arm attribution is NAMED — mixed-history
#                        coverage: old histories must stay readable;
#               DGRACE   the during-grace old-writer activate (the boot's
#                        in-progress for the booted version, the verdict for
#                        the ACTIVATED one) stays coherent;
#               REARMFLIP a SECOND verdict for the activated version (the
#                        flip that overwrites the re-arm verdict by
#                        appending after it, wearing the same live nonce)
#                        fires the per-VERSION budget — the one budget a
#                        per-nonce rule cannot express;
#               REARMIP  the NEW-writer healthy shape (the boot's own pair,
#                        then the activated version's ip AND its verdict,
#                        one nonce): COHERENT, the re-arm ip NAMED and the
#                        verdict NAMED as consuming it;
#               REARMIPFLIP the +1 must NOT stack on a present re-arm ip: a
#                        real ip + ONE forged second verdict fires the
#                        per-VERSION budget (allow = ip + 0);
#               REARMIPFORGE a forged ip+verdict pair on a real boot's nonce
#                        for a version the store did NOT first publish in
#                        the window (and the older-than-the-boot's-own
#                        variant) fires the re-arm rule;
#               REARMIPOLDER the same rule, the ordering half: a
#                        first-published ip NOT newer than the nonce's own
#                        first ip fires it;
#               REARMIPX THE CROSS-NONCE FLIP: with TWO real window nonces, a
#                        forged ip+verdict pair for the version the LIVE boot
#                        activated, riding an EARLIER boot's nonce, fires the
#                        ONE-per-first-published-VERSION-per-window cap (a
#                        per-(nonce, version) rule reads it as a legitimate
#                        re-arm and passes a SECOND verdict for an
#                        already-verdicted version — BEFORE-E pins both the
#                        pre-re-arm reader (which closed it) and the
#                        round-1 reader (which re-opened it));
#               REARMIPREPUB the ROLL-FORWARD REPUBLISH shape: a version the
#                        store first published WITHOUT an activation (a
#                        roll-forward republish) and then BOOTED has no
#                        legitimate later ip, so a forged pair for it riding
#                        an EARLIER boot's nonce fires the NOT-ALREADY-BOOTED
#                        re-arm clause (round 2's reader read it as a
#                        legitimate re-arm and passed a SECOND verdict);
#               REARMIP2 the FALSE-POSITIVE direction for that clause: TWO
#                        activations in ONE boot (two re-arm ips under ONE
#                        nonce, NEITHER activated version booted) must stay
#                        COHERENT — a too-broad clause rolls back a HEALTHY
#                        machine, the costly direction;
#               MIXED    a window with one nonced boot + one healthy
#                        operator hand-boot ('none' placeholder lines,
#                        ledger shorter than the window) is information
#                        only: COHERENT, both regime lines printed, no
#                        INCOHERENT — the regime a deployment hits by
#                        accident, ungated until now;
#               SUBST    the named hole: a verdict SUBSTITUTED inside a
#                        live boot (the forger wears the boot's own nonce,
#                        which /proc/cmdline makes readable in-guest, and
#                        suppresses fx-init's verdict) audits coherent —
#                        one verdict for one (nonce, version), every
#                        anchor satisfied — and the tool must SAY so: the
#                        arm asserts the printed bound names the
#                        substitution, so the tool never claims a closure
#                        it does not have.
#   NONCE-W   the WRITER pin (fx-init 500fc68, git cat-file -e + cmp proving
#               pin != working tree): the pinned writer's bootlog_append is
#               the 3-field "%u %s %u" and knows no fx.bootnonce — the
#               fail-before of the WRITER half, asserted at source level
#               (the behaviour half lives in fx-init's zig tests and the
#               real-guest demo in qemu-agent-observe.sh).
#   CAP         a .bootlog (or .recovery) longer than the reader's line
#               table is exit 2 NAMING the cap and the file — silently
#               auditing a truncated view is exactly the silent pass the
#               tool's header forbids.
#   BEFORE      THE FAIL-BEFORE, on the PINNED pre-change revision 030fbdc
#               (git cat-file -e guard + cmp proving pin != working tree —
#               a control that equals its subject proves nothing): the
#               pinned tool, given the same enrollment -> forge sequence,
#               calls the tampered store COHERENT.  The new tool also
#               REFUSES the pinned tool's format-1 observation (it recorded
#               no boot count; assuming one is the silent default this seat
#               refuses).
#   LEGIT       the other half of the accounting — LEGITIMATE growth stays
#               coherent, each shape from the writer's own call sites: an
#               ordinary boot (in-progress + ok), a boot that FAILS
#               (in-progress + failed), a failure that ROLLS FORWARD
#               (failed -> the real fxstore republish -> the new version's
#               in-progress + ok + a .recovery row), a clean SHUTDOWN, a
#               boot KILLED AT THE VERDICT (in-progress alone — this
#               harness's own kill shape), a SILENT boot the writer records
#               nothing for (no bootable generation), the SAME version
#               booted TWICE in one window, a MULTI-CYCLE roll-forward (two
#               roll-forwards between two audits), and an in-progress
#               followed by a SHUTDOWN (a clean stop during the judgement —
#               do_shutdown appends its line whether or not the boot ever
#               decided a verdict, init.zig:4215/:4779).
#   TRIGGER     --rollback REFUSES a clean store (CURRENT untouched) and on
#               the coherent-tamper store calls `fxstore rollback --hard`
#               (CURRENT repointed, LOUD, naming the finding), after which
#               a re-audit is coherent (the post-rollback baseline).
#   SELFREPORT  the verdict does not depend on attempts.jsonl: the same
#               incoherent store with that file ABSENT, DELETED and
#               DOCTORED reaches the identical verdict (byte-identical
#               output) — a self-report is never evidence.
#   LOUD        an unreadable .bootlog is exit 2 (a tool error), never a
#               silent pass; an --obs-dir INSIDE the store is refused.
#
# POSITIVE CONTROL (the mutation): for EVERY named check the gate builds a
# mutated detector with exactly that one check's registration deleted from a
# COPY of the source (sed, one line: `run_check("<name>", ...)`), and
# asserts the corresponding fixture's audit goes COHERENT on the mutant —
# the assertion FAILS unless the check is load-bearing.  The previous-
# observation comparison's mutant is the COHERENT arm's control; the
# boot-accounting mutant's is the FORGERY arm's.
#
# THE FAIL-BEFORES are PINNED (nothing depends on the position of HEAD;
# each pin is a fixed object name, guarded by git cat-file -e and cmp-proven
# DIFFERENT from the working tree): the READER side at 030fbdc (pre---boots:
# the bare forged verdict audited coherent; its format-1 observation is
# refused), at 88a73b8 (pre-NONCE: the forged PAIR into a silent boot's
# slack audited coherent — the reviewer's measurement, reproduced on the
# old-writer store it can read; its format-2 observation is refused), at
# fcebaa3 (the torn-verdict false positive), and at be2fbd1 (pre-PER-VERSION
# accounting: the healthy in-guest-activate re-arm boot audited INCOHERENT —
# the false-positive BLOCKER this change fixes, both the per-nonce verdict
# budget and the version-exact attribution pinned); the WRITER side at
# fx-init 500fc68 (the pre-nonce 3-field bootlog_append — no fx.bootnonce
# token anywhere), asserted at source level with the same guards.
#
# FIXTURE HONESTY: .bootlog/.recovery are fx-init's files and fx-init does
# not run host-side; the gate WRITES them in the writers' exact formats
# (bootlog_append's "%u %s %u\n" — a "<v> in-progress <epoch>" line AND the
# verdict line for every boot, because that is what the writer appends per
# boot (init.zig:4705 then the verdict sites); recovery_line's "<epoch>
# <published> <from-failed> <genhash>\n" under the verbatim RECOVERY_HEADER
# from init.zig).  The HOST BOOT COUNT narrative is likewise declared, not
# measured: the baseline store's history is THREE boots the "host" (this
# gate) says it started — v1's boot (ok), v2's boot (failed), the
# roll-forward boot (republished CUR, ok) — so enrollment runs with
# --boots 3 and every arm that grows the bootlog declares the boots it
# added.  Everything else is written by the real writers: fx-activate
# (host-built, the qemu-agent-observe.sh provisioning shape) and fxstore
# itself (the soft `rollback` that fx-init's roll-forward drives in-guest).
#
# Env: FX_SIBLINGS (default $HOME/fixpoint-linux unless $REPO/.. holds the
#      stack), FXSTORE_BIN (default $FX_SIBLINGS/fxstore/zig-out/bin/fxstore),
#      FX_INIT_REPO, FX_AUDIT_KEEP=1.
set -u

fail() { echo "test_fx_audit: FAIL: $*" >&2; exit 1; }
skip() { echo "test_fx_audit: SKIP ($*)"; exit 77; }

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
# Sibling root: an explicit FX_SIBLINGS wins; else the historical neighbour
# $REPO/.. only if it actually holds the stack (fx-init present); else the
# relocated default $HOME/fixpoint-linux.
SIBS="${FX_SIBLINGS:-$(cd "$REPO/.." && pwd)}"
[ -d "$SIBS/fx-init" ] || [ -n "${FX_SIBLINGS:-}" ] || SIBS="$HOME/fixpoint-linux"

command -v cc >/dev/null 2>&1 || skip "cc not found"
command -v sed >/dev/null 2>&1 || skip "sed not found"

FXSTORE="${FXSTORE_BIN:-$SIBS/fxstore/zig-out/bin/fxstore}"
[ -x "$FXSTORE" ] || skip "fxstore binary missing at $FXSTORE (set FX_SIBLINGS or FXSTORE_BIN, or build the sibling)"
"$FXSTORE" --help 2>&1 | grep -q 'fxstore facts' || skip "fxstore at $FXSTORE predates 'facts' (rebuild the sibling)"

INIT="${FX_INIT_REPO:-$SIBS/fx-init}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_SIBLINGS or FX_INIT_REPO)"

# ── THE CITATION PIN (fx-init d0de8c9, re-measured at the RUNTIME-RECORD
#    CLOSURE on the working tree above it): the tree every cited LINE means ──
# This gate and tools/fx-audit.c cite init.zig BY LINE NUMBER, and nothing
# pinned the file, so the citations rotted SILENTLY: the accounting header
# cited :4465 for the in-progress site when it was :4718, and :1674 for
# recovery_append when it was :914 — found by hand, only because a unit
# happened to print every cited line.  A citation into a file that MOVED is
# a FINDING, not a renumbering job, so the pin makes the drift LOUD.
# The pin is a FIXED object — the file's BLOB name, not HEAD and not the
# working file — so it stays exact once a later commit lands (identical
# bytes, identical blob) and never moves under the gate's feet.  Guarded
# (git cat-file -e) the house way: a shallow clone fails as a MISSING PIN,
# never as a pass.
pin_init_blob() { # pin_init_blob BLOB FILE CITING...
    git -C "$INIT" cat-file -e "$1" 2>/dev/null \
        || fail "CITATION PIN: blob $1 is not present in $INIT's object db — the pin is a fixed object name; hash-object -w the measured file or update the pin consciously"
    git -C "$INIT" cat-file blob "$1" | cmp -s - "$INIT/$2" \
        || fail "CITATION PIN: $INIT/$2 differs from the pinned blob $1 this gate's citations were measured against — the init.zig citations in $3 are STALE; re-measure every cited line against this tree and fix the ones that MOVED"
}
# ROUND-2 NIT PASS: init.zig moved (ONE REQ_MAX definition; the marker's
# setenv now CHECKED) with a ZERO line delta, so the cites above are
# unchanged — only this gate's blob pin was re-measured.
pin_init_blob 7c054559821da222fddf793c62989b4b65e97361 zig/src/init.zig "tools/fx-audit.c and tests/test_fx_audit.sh"
echo "test_fx_audit: CITATION PIN: init.zig measured for tools/fx-audit.c and this gate is fx-init d0de8c9 + the runtime-record closure (uncommitted working tree, blob 7c054559)"

DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL (set FX_SIBLINGS)"

ZB="$REPO/build/guest-payload/init-x86_64-musl/bin"
if [ ! -x "$ZB/activate_paths" ] || [ ! -x "$ZB/fx-activate" ]; then
    command -v zig >/dev/null 2>&1 || skip "$ZB binaries absent and zig not found to build them"
    echo "test_fx_audit: building fx-init's binaries (x86_64-linux-musl)"
    ( cd "$INIT/zig" && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe \
        -p "$REPO/build/guest-payload/init-x86_64-musl" \
        --cache-dir "$REPO/build/guest-payload/zig-init-cache" ) || fail "fx-init zig build failed"
fi
[ -x "$ZB/activate_paths" ] || fail "no $ZB/activate_paths"
[ -x "$ZB/fx-activate" ] || fail "no $ZB/fx-activate"
grep -aq src_of "$ZB/fx-activate" || {
    skip "staged fx-activate at $ZB predates src_of — the staging froze on an OLD fx-init; rm -rf build/guest-payload/init-x86_64-musl and re-run to rebuild it"
}

# ── the seat itself, and the STALE-BINARY guard: the artifact the gate
#    drives must be the artifact just built from THIS source (a cached
#    binary answering for a property of the system has bitten this repo
#    four times this week).  make is idempotent; the -nt assertion catches
#    any cache that survived it.
make -s build/fx-audit >/dev/null || fail "cannot build build/fx-audit"
AUDIT="$REPO/build/fx-audit"
[ -x "$AUDIT" ] || fail "no $AUDIT"
[ "$AUDIT" -nt "$REPO/tools/fx-audit.c" ] || fail "$AUDIT is older than tools/fx-audit.c — a stale cached binary answered for the seat; rm -rf build and re-run"
# ...and the artifact must BE the one THIS source builds, not merely newer: a
# cached, shadowed or half-built binary answering for the seat is a class this
# repo has paid for five times.  The marker exists only in this source, so its
# absence means the binary was not built from tools/fx-audit.c.
grep -aq 'silently dropped from the counting AND the forged-verdict attribution' "$AUDIT" \
    || fail "STALE BINARY: $AUDIT does not contain this source's .bootlog cap-refusal message — the artifact answering for the seat was not built from tools/fx-audit.c"
grep -aq 'no nonce the host issued for a boot in this window' "$AUDIT" \
    || fail "STALE BINARY: $AUDIT does not contain this source's nonce-binding message — the artifact answering for the seat was not built from tools/fx-audit.c (the per-boot-nonce change)"
grep -aq 'the in-guest activate RE-ARM shape' "$AUDIT" \
    || fail "STALE BINARY: $AUDIT does not contain this source's re-arm attribution message — the artifact answering for the seat was not built from tools/fx-audit.c (the per-version verdict accounting change)"

# ── the per-boot nonce fixtures ───────────────────────────────────────────
# nth ORDINAL — the deterministic nonce the gate (as the host) issued for
# boot ORDINAL.  The real host mints random hex per launch; the gate's
# nonces are deterministic because the FIXTURE lines must be fabricated in
# the writer's exact shape with the very nonce the ledger names — the
# binding under test is host-ledger <-> line-field, not randomness (which
# is the live host's property, demonstrated in qemu-agent-observe.sh).
nth() { printf 'badfee%08x' "$1"; }
# mkled OUT LAST — the host's ledger: "<boot> <nonce>" per boot 1..LAST
mkled() { : > "$1"; _i=1; while [ "$_i" -le "$2" ]; do echo "$_i $(nth $_i)" >> "$1"; _i=$((_i + 1)); done; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fxaudit.XXXXXX")" || fail mktemp
if [ "${FX_AUDIT_KEEP:-0}" = "1" ]; then
    trap 'echo "test_fx_audit: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi

# ── the fixture store (toolchain-free provisioning, osier-gate shape) ────
SRC="$WORK/src"
mkdir -p "$SRC/osier-svc" "$SRC/tool"
{
    echo "-- the audit fixture's osier module"
    i=0; while [ $i -lt 5 ]; do echo "line_$i = $i -- osier source"; i=$((i+1)); done
} > "$SRC/osier-svc/Main.elm"
echo "/* shared tool tree */" > "$SRC/tool/tool.c"

PSN=0
ps_pkg() {
    if [ "$PSN" -eq 0 ]; then echo "  { name = \"$1\", version = \"0\""
    else echo "  , { name = \"$1\", version = \"0\""; fi
    PSN=$((PSN + 1))
    cat <<EOF
    , src = < Path = "$2" >
    , deps = [] : List Text
    , excludes = [] : List Text
    , build = { target = "$1", recipe = [] : List Action } }
EOF
}

cfg_write() { # cfg_write OUT PKGLIST SVCLIST
    cat > "$1" <<EOF
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "auditbox"
    , packages = [ $2 ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ] : List User
    , services = [ $3 ] : List Service
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 30000
    , agentService = None Text
    }
EOF
}
TOOLS='"dhake", "fx-init", "fxctl", "fx-activate"'
svc_osier() {
    echo '{ name = "osierd", argv = [ "osier-svc" ], pkg = Some "osier-svc", on = "all", restart = Some "always", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text }'
}
svc_sh() {
    echo '{ name = "shsvc", argv = [ "/bin/sh", "-c", "true" ], pkg = None Text, on = "all", restart = Some "always", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text }'
}

# mkstore STORE_DIR OSIER_SRC — provision + activate v1 (the E/A config)
mkstore() {
    _st="$1"; _osrc="$2"
    mkdir -p "$_st" || fail "cannot create $_st"
    {
        cat <<'EOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text
             | Rm : Text | Touch : Text | Move : { from : Text, to : Text }
             | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text }
             | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Src = < Path : Text | Fetch : { url : Text, hash : Text } >
let Package = { name : Text, version : Text, src : Src, deps : List Text,
                excludes : List Text, build : { target : Text, recipe : List Action } }
in  { packages = [
EOF
        ps_pkg dhake        "$SRC/tool"
        ps_pkg fx-init      "$SRC/tool"
        ps_pkg fxctl        "$SRC/tool"
        ps_pkg fx-activate  "$SRC/tool"
        ps_pkg osier-svc    "$_osrc"
        echo "  ] }"
    } > "$WORK/pkgset-$(basename "$_st").dhall"
    _ps="$WORK/pkgset-$(basename "$_st").dhall"
    _p=$(LD_LIBRARY_PATH="$DL" "$ZB/activate_paths" --store "$_st" --package-set "$_ps" \
        dhake fx-init fxctl fx-activate osier-svc) || fail "activate_paths failed: $_p"
    for _pd in $_p; do mkdir -p "$_st/$_pd" || fail "cannot create $_pd"; done
    cfg_write "$WORK/cfg-$(basename "$_st").dhall" "$TOOLS, \"osier-svc\"" "$(svc_sh), $(svc_osier)"
    _o=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$_st" --package-set "$_ps" \
        --config "$WORK/cfg-$(basename "$_st").dhall" 2>&1) \
        || fail "fx-activate failed: $_o"
    _v=$(echo "$_o" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$_v" ] || fail "no version from fx-activate: $_o"
    echo "$_v"
}

# materialize_rootfs STORE ROOTFS VERSION — create every path the install
# facts name (the rootfs links, the store files they point at, the
# generation's buildfile/dhake), so the CLEAN store genuinely reconciles.
# The origin is the EXACT installed content, so BOTH modes name a file in
# the store: mode 0 rows (the /bin links) name `<hash>-<pkg>/<binary>` — the
# binary the link points at (a link to the package DIR is un-exec-able) —
# and regular rows (the /etc copies) name a file inside the generation dir,
# which dhake materializes in-guest and the gate fakes here.
materialize_rootfs() {
    _st="$1"; _rt="$2"; _v="$3"; _ps="$4"
    FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts install --as-of "$_v" --store "$_st" \
        | while IFS="$(printf '\t')" read -r tgt org mode gh; do
            [ -n "$tgt" ] || continue
            mkdir -p "$_rt/$(dirname "$tgt")" || exit 1
            rm -f "$_rt$tgt"
            if [ "$mode" = "0" ]; then
                mkdir -p "$_st/$(dirname "$org")" || exit 1
                : > "$_st/$org" || exit 1
                ln -s "$_st/$org" "$_rt$tgt" || exit 1
            else
                mkdir -p "$_st/$(dirname "$org")" || exit 1
                : > "$_st/$org" || exit 1
                : > "$_rt$tgt" || exit 1
            fi
        done || fail "cannot materialize rootfs from install facts"
    # svc_bin's store-relative binaries
    FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts svc_bin --as-of "$_v" --store "$_st" \
        | while IFS="$(printf '\t')" read -r name bin; do
            case "$bin" in /*) continue ;; esac
            [ -n "$bin" ] || continue
            mkdir -p "$_st/$(dirname "$bin")" || exit 1
            : > "$_st/$bin" || exit 1
        done || fail "cannot materialize svc_bin paths"
    # the generation's own buildfile + dhake file
    FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts generation --as-of "$_v" --store "$_st" \
        | while IFS="$(printf '\t')" read -r gh bf dh ep; do
            mkdir -p "$_st/$(dirname "$bf")" "$_st/$(dirname "$dh")" || exit 1
            : > "$_st/$bf" || exit 1
            : > "$_st/$dh" || exit 1
        done || fail "cannot materialize the generation's files"
    FXSTORE_BIN="$FXSTORE" "$FXSTORE" verify "$_rt" --as-of "$_v" --store "$_st" >/dev/null \
        || fail "precondition: fxstore verify is not clean on the fixture (rootfs materialization is wrong)"
}

# write_records STORE BOOTLOG_ROWS... — .bootlog + the header-only .recovery
# in the WRITERS' exact formats (see FIXTURE HONESTY above).  Every boot is
# written as its REAL line pair: "<v> in-progress <epoch>" (init.zig:4705,
# when the boot starts) followed by that boot's verdict — never a bare
# verdict, because the writer never emits one without its in-progress.
write_records() {
    _st="$1"; shift
    : > "$_st/.bootlog"
    for _r in "$@"; do echo "$_r" >> "$_st/.bootlog"; done
    cat > "$_st/.recovery" <<'EOF'
# fx-init recovery journal. One DATA line per AUTOMATIC roll-forward:
# fx-init republished an older ok generation because the current
# version's last .bootlog verdict was failed/in-progress. The count
# of recoveries is the number of lines starting with a digit.
# NOT counted: operator rollbacks (fxctl/fxstore `rollback`),
# activations, ordinary boots, and boots where recovery was REFUSED
# by the guardrail (the hold appends nothing).
# Same fault coming back: multiple lines whose trailing genhash is
# IDENTICAL are the same CONTENT re-failing — the recurrence a bare
# count cannot show. This file still cannot say the machine is
# oscillating RIGHT NOW: read the epochs below and .bootlog for the
# interleaving.
# Written only by fx-init at the roll-forward decision. Root in-guest
# can forge or truncate it exactly as it can .bootlog; the counts are
# reconstructible from .bootlog x the store's version/genhash history.
# line: <epoch-s> <published-version> <from-failed-version> <content-genhash|-> <boot-nonce|none>
# The final field is THIS boot's fx.bootnonce= token from the kernel
# command line (the HOST's per-launch record of the boot that wrote the
# row; "none" = the host issued no nonce — an operator hand-boot).
# It binds the row to that boot the way .bootlog's 4th field binds a
# line: same boot, same nonce, fx-init never writes without one.
EOF
}

genhash_of() { # genhash_of STORE VERSION -> the generation hash
    FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts generation --as-of "$2" --store "$1" \
        | head -1 | cut -f1
}

cur_of() { cat "$1/.db/snapshots/CURRENT" 2>/dev/null || fail "no CURRENT in $1"; }

audit() { # audit STORE ROOTFS BOOTS LEDGER [extra args...] — runs the seat
    _st="$1"; _rt="$2"; _nb="$3"; _led="$4"; shift 4
    FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$_st" --rootfs "$_rt" --boots "$_nb" --nonces "$_led" "$@"
}

expect_coh() { # expect_coh OUT EXIT LABEL — must be coherent
    [ "$2" = "0" ] || fail "$3: expected coherent exit 0, got $2: $(sed -n 1,8p "$1")"
    grep -q '^VERDICT: coherent$' "$1" || fail "$3: no coherent verdict: $(tail -3 "$1")"
}

expect_incoh() { # expect_incoh OUT EXIT LABEL FINDING...
    _o="$1"; _e="$2"; _l="$3"; shift 3
    [ "$_e" = "1" ] || fail "$_l: expected incoherent exit 1, got $_e: $(sed -n 1,8p "$_o")"
    grep -q '^VERDICT: incoherent' "$_o" || fail "$_l: no incoherent verdict"
    for _f in "$@"; do
        grep -q "^INCOHERENT $_f " "$_o" || fail "$_l: finding '$_f' not reported: $(grep '^INCOHERENT' "$_o")"
    done
}

# ══ THE CLEAN BASELINE (store A, with a real roll-forward history) ═══════
STORE="$WORK/store-a"
V1=$(mkstore "$STORE" "$SRC/osier-svc")
[ -n "$V1" ] || fail "no version from the first activation"
PS_A="$WORK/pkgset-store-a.dhall"

# a second activation (different config: c-svc is NOT in this store's set —
# change the service list instead) -> version 2, which "fails to boot"
cfg_write "$WORK/cfg-a2.dhall" "$TOOLS, \"osier-svc\"" "$(svc_sh)"
V2=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$STORE" --package-set "$PS_A" \
        --config "$WORK/cfg-a2.dhall" 2>&1 | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V2" ] || fail "no version from activation 2"
[ "$V2" -gt "$V1" ] || fail "expected v2 > v1, got $V2"

# the roll-forward: fx-init's recovery drives fxstore's SOFT rollback
# in-guest; host-side the gate drives the same fxstore call
FXSTORE_BIN="$FXSTORE" "$FXSTORE" rollback "$V1" --store "$STORE" >/dev/null 2>&1 \
    || fail "fxstore rollback $V1 failed"
CUR=$(cur_of "$STORE")
GH_CUR=$(genhash_of "$STORE" "$CUR")
[ -n "$GH_CUR" ] || fail "no genhash as-of CURRENT=$CUR"
GH1=$(genhash_of "$STORE" "$V1")
[ "$GH_CUR" = "$GH1" ] || fail "rollback did not restore v$V1's content (genhash $GH_CUR != $GH1)"

ROOT="$WORK/rootfs-a"
mkdir -p "$ROOT"
materialize_rootfs "$STORE" "$ROOT" "$CUR" "$PS_A"

# the machine's history in fx-init's records, as THREE boots the host
# started — v1 boots ok; v2 boots and FAILS; the next boot rolls forward
# (fxstore soft rollback republishing v1's content as v$CUR) and boots ok.
# Each boot is the writer's real line pair (in-progress at boot start,
# init.zig:4705; the verdict from the g_boot_decided latch), each wearing
# the nonce the host issued for it (the gate's own ledger).
write_records "$STORE" \
    "$V1 in-progress 99 $(nth 1)" \
    "$V1 ok 100 $(nth 1)" \
    "$V2 in-progress 100 $(nth 2)" \
    "$V2 failed 101 $(nth 2)" \
    "$CUR in-progress 102 $(nth 3)" \
    "$CUR ok 103 $(nth 3)"
echo "$CUR $V2 $GH_CUR $(nth 3)" | awk '{ print "103 " $1 " " $2 " " $3 " " $4 }' >> "$STORE/.recovery"


OBS="$WORK/obs"
mkled "$WORK/nonces-main.led" 3
audit "$STORE" "$ROOT" 3 "$WORK/nonces-main.led" --obs-dir "$OBS" > "$WORK/out.clean1" 2>&1
expect_coh "$WORK/out.clean1" $? "CLEAN first audit"
grep -q 'ENROLLING' "$WORK/out.clean1" || fail "CLEAN: first run did not enroll"
grep -q 'host boot count 3 is recorded as the baseline' "$WORK/out.clean1" \
    || fail "CLEAN: the enrollment did not record the host boot count"
# idempotence + the append-only path: a LEGITIMATE new boot between audits
# (the writer's real pair: in-progress at start, then the verdict, both
# wearing the nonce the host issued for boot 4) must leave the store
# coherent — fx-init appends; it never rewrites
mkled "$WORK/nonces-main.led" 4
echo "$CUR in-progress 104 $(nth 4)" >> "$STORE/.bootlog"
echo "$CUR ok 105 $(nth 4)" >> "$STORE/.bootlog"
audit "$STORE" "$ROOT" 4 "$WORK/nonces-main.led" --obs-dir "$OBS" > "$WORK/out.clean2" 2>&1
expect_coh "$WORK/out.clean2" $? "CLEAN re-audit (idempotence + legal append: an ordinary boot)"
grep -q 'append-only respected' "$WORK/out.clean2" \
    || fail "CLEAN re-audit: the legal append was not seen by the prefix comparison"
grep -q 'boot accounting: host boots 3 -> 4 (delta 1); this window added in-progress 1, verdicts 1, shutdown 0' "$WORK/out.clean2" \
    || fail "CLEAN re-audit: the ordinary boot was not accounted by the host delta: $(grep 'boot accounting' "$WORK/out.clean2")"
grep -q 'disagreement' "$WORK/out.clean2" \
    && fail "CLEAN re-audit: a legal append produced a disagreement"
# boot 4's nonce is CLAIMED by its own pair: no unclaimed-nonce report
grep -q 'UNCLAIMED' "$WORK/out.clean2" \
    && fail "CLEAN re-audit: a boot whose lines landed was reported UNCLAIMED: $(grep 'UNCLAIMED' "$WORK/out.clean2")"
echo "test_fx_audit: CLEAN: coherent on first audit; an ordinary boot (in-progress + ok under boot 4's nonce, --boots 3 -> 4) re-audits coherent"

# ── the fixture scheme ───────────────────────────────────────────────────
# every incoherence arm runs on a COPY of the clean baseline with its OWN
# rootfs (the /bin links embed the STORE's absolute path — a shared rootfs
# is itself a drift fixture) and its own copy of the baseline OBSERVATION
# FILE (--obs-file: the default keying is by store path, and a copied store
# has a different path — the override is exactly "audit this store against
# the host's memory of that store").
AOBSFILE=$(ls "$OBS"/*.obs 2>/dev/null | head -1)
[ -n "$AOBSFILE" ] || fail "the clean audit wrote no observation file"

fresh() { # fresh NAME — copy store + observation file + build its rootfs
    cp -a "$STORE" "$WORK/store-$1"
    cp "$AOBSFILE" "$WORK/obsf-$1.obs"
    mkdir -p "$WORK/rootfs-$1"
    materialize_rootfs "$WORK/store-$1" "$WORK/rootfs-$1" "$(cur_of "$WORK/store-$1")" "$PS_A"
}

run_fixture() { # run_fixture NAME [extra seat args...] — runs the seat.
    # FBOOTS (default 4) is the host truth for this fixture: the baseline
    # observation was taken after the clean arm's FOURTH declared boot, so
    # every arm that grows the bootlog must set FBOOTS to declare the boots
    # it added (the host's count is an INPUT, never inferred).  The ledger
    # (one nonce per boot 1..FBOOTS) is minted per fixture the same way —
    # the host's record of what it issued, never read from the store.
    _fxname="$1"; shift
    mkled "$WORK/nonces-$_fxname.led" "${FBOOTS:-4}"
    FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$WORK/store-$_fxname" \
        --rootfs "$WORK/rootfs-$_fxname" --obs-file "$WORK/obsf-$_fxname.obs" \
        --boots "${FBOOTS:-4}" --nonces "$WORK/nonces-$_fxname.led" "$@"
}

# the coherent tamper, as a function (used by three arms)
tamper_coherent() { # tamper_coherent STOREDIR
    sed -i "s/^$V2 failed/$V2 ok/" "$1/.bootlog"
    head -16 "$1/.recovery" > "$1/.recovery.tmp" && mv "$1/.recovery.tmp" "$1/.recovery"
}

# ══ COHERENT: the tamper that rewrites ALL in-guest records ══════════════
# .bootlog's "v2 failed" becomes "v2 ok" and the .recovery row is stripped:
# every record the machine keeps about itself now AGREES (no failure, no
# recovery).  Only the host's recorded observation can see it.
fresh coh
tamper_coherent "$WORK/store-coh"
run_fixture coh > "$WORK/out.coh" 2>&1
expect_incoh "$WORK/out.coh" $? "COHERENT tamper" \
    disagreement-bootlog-rewritten disagreement-recovery-rewritten
# the CROSS-CHECKS pass on the tampered store — the tamper is coherent
for _c in version-chain recovery-without-failure verify-drift facts-path-gone \
          src-of-artifact records-damaged; do
    grep -q "^check $_c: pass\$" "$WORK/out.coh" \
        || fail "COHERENT: cross-check $_c did not pass on the tampered store (the tamper is not coherent — the arm is vacuous): $(grep '^check' "$WORK/out.coh")"
done
echo "test_fx_audit: COHERENT tamper: every cross-check passes; caught ONLY by the previous observation"

# ══ the named incoherences, each on its own fresh copy ══════════════════

# RWF: a roll-forward nobody recorded a failure for (from_failed points at
# the ok v1); the control row points at the recorded v2 failure.  Both rows
# are declared with ONE host boot behind them (FBOOTS=5): the writer's real
# order is recovery_append BEFORE the boot's in-progress line (init.zig:
# decide_boot_version runs first), so a boot killed in between leaves
# exactly this shape — row, no bootlog lines.  The accounting then passes
# both and only the from-failed reader separates them.
fresh rwf
echo "200 $CUR $V1 $GH_CUR $(nth 5)" >> "$WORK/store-rwf/.recovery"
FBOOTS=5 run_fixture rwf > "$WORK/out.rwf" 2>&1
expect_incoh "$WORK/out.rwf" $? "RWF" recovery-without-failure
grep -q "last bootlog verdict is 'ok'" "$WORK/out.rwf" \
    || fail "RWF: the finding does not name the ok verdict: $(grep '^INCOHERENT recovery-without-failure' "$WORK/out.rwf")"
grep -q '^check boot-accounting: pass$' "$WORK/out.rwf" \
    || fail "RWF: boot-accounting fired too (isolation failed — the row has a declared boot behind it)"
fresh rwfctl
echo "201 $CUR $V2 $GH_CUR $(nth 5)" >> "$WORK/store-rwfctl/.recovery"
FBOOTS=5 run_fixture rwfctl > "$WORK/out.rwfctl" 2>&1
expect_coh "$WORK/out.rwfctl" $? "RWF control (failure IS recorded, boot declared)"
echo "test_fx_audit: RWF: fires on an unrecorded failure; control row passes"

# DRIFT: an unmanaged rootfs file (fxstore verify exit 1, reused)
fresh drift
echo "payload" > "$WORK/rootfs-drift/bin/rogue"
run_fixture drift > "$WORK/out.drift" 2>&1
expect_incoh "$WORK/out.drift" $? "DRIFT" verify-drift
grep -q 'bin/rogue' "$WORK/out.drift" \
    || fail "DRIFT: the finding does not name the rogue file: $(grep '^INCOHERENT verify-drift' "$WORK/out.drift")"
echo "test_fx_audit: DRIFT: an unmanaged rootfs file fires through fxstore verify"

# GONE: a store dir the provides facts name is deleted
fresh gone
OSDIR=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts provides --as-of "$(cur_of "$WORK/store-gone")" --store "$WORK/store-gone" \
    | awk -F'\t' '$1 == "osier-svc" { print $2; exit }')
[ -n "$OSDIR" ] || fail "GONE: no provides row for osier-svc"
rm -rf "$WORK/store-gone/$OSDIR"
run_fixture gone > "$WORK/out.gone" 2>&1
expect_incoh "$WORK/out.gone" $? "GONE" facts-path-gone
grep -q "$OSDIR" "$WORK/out.gone" \
    || fail "GONE: the finding does not name the missing dir $OSDIR"
echo "test_fx_audit: GONE: provides names $OSDIR and it is not there"

# CHAIN (a): CURRENT points nowhere
fresh chain
echo 99 > "$WORK/store-chain/.db/snapshots/CURRENT"
run_fixture chain > "$WORK/out.chain" 2>&1
expect_incoh "$WORK/out.chain" $? "CHAIN current" version-chain
grep -q 'not a published version' "$WORK/out.chain" \
    || fail "CHAIN: the finding does not say CURRENT is not published"
# CHAIN (b): a .recovery row with the WRONG content genhash — while the
# failure itself IS recorded (recovery-without-failure must still pass:
# two readers, one lie).  FBOOTS=5 declares the boot behind the row (the
# RWF arm's shape), so the accounting stays out of the isolation.
fresh chain2
echo "202 $CUR $V2 0000000000000000000000000000000000000000000000000000000000000000 $(nth 5)" >> "$WORK/store-chain2/.recovery"
FBOOTS=5 run_fixture chain2 > "$WORK/out.chain2" 2>&1
expect_incoh "$WORK/out.chain2" $? "CHAIN recovery-genhash" version-chain
grep -q '^check recovery-without-failure: pass$' "$WORK/out.chain2" \
    || fail "CHAIN(b): recovery-without-failure fired too (isolation failed)"
grep -q '^check boot-accounting: pass$' "$WORK/out.chain2" \
    || fail "CHAIN(b): boot-accounting fired too (isolation failed — the row has a declared boot behind it)"
grep -q 'generation fact' "$WORK/out.chain2" \
    || fail "CHAIN(b): the finding does not name the genhash disagreement"
echo "test_fx_audit: CHAIN: CURRENT=99 and a wrong recovery genhash each fire version-chain"

# DAMAGED: a terminated .bootlog line fx-init never writes
fresh damaged
echo "not a boot verdict at all" >> "$WORK/store-damaged/.bootlog"
run_fixture damaged > "$WORK/out.damaged" 2>&1
expect_incoh "$WORK/out.damaged" $? "DAMAGED" bootlog-damaged
grep -q 'not a boot verdict' "$WORK/out.damaged" \
    || fail "DAMAGED: the finding does not quote the damaged line"
echo "test_fx_audit: DAMAGED: a foreign .bootlog line fires bootlog-damaged"

# VANISHED: .recovery was there at enrollment and is now gone
fresh vanished
rm "$WORK/store-vanished/.recovery"
run_fixture vanished > "$WORK/out.vanished" 2>&1
expect_incoh "$WORK/out.vanished" $? "VANISHED" record-vanished
echo "test_fx_audit: VANISHED: .recovery present then absent fires record-vanished"

# ARTIFACT: a src_of source artifact enrolled then removed
fresh artifact
SRCH=$(FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts src_of --as-of "$(cur_of "$WORK/store-artifact")" --store "$WORK/store-artifact" \
    | awk -F'\t' '$3 == "osier-svc" { print $2; exit }')
[ -n "$SRCH" ] || fail "ARTIFACT: no src_of row for osier-svc (is the staged fx-activate the src_of writer?)"
mkdir -p "$WORK/store-artifact/$SRCH-osier-svc-src"
run_fixture artifact > "$WORK/out.art1" 2>&1
expect_coh "$WORK/out.art1" $? "ARTIFACT enroll (artifact present)"
rm -rf "$WORK/store-artifact/$SRCH-osier-svc-src"
run_fixture artifact > "$WORK/out.art2" 2>&1
expect_incoh "$WORK/out.art2" $? "ARTIFACT gone" disagreement-artifact-gone
grep -q "$SRCH-osier-svc-src" "$WORK/out.art2" \
    || fail "ARTIFACT: the finding does not name the artifact"
echo "test_fx_audit: ARTIFACT: $SRCH-osier-svc-src enrolled then removed fires disagreement-artifact-gone"

# FACTS: a SECOND store, same version numbers, different content, audited
# against the FIRST store's observation — history was rebuilt
STORE_B="$WORK/store-b"
mkdir -p "$WORK/osier-b"
echo "-- a DIFFERENT osier source (same package, new content)" > "$WORK/osier-b/Main.elm"
# the FACTS arm needs B's version numbers to COLLIDE with A's recorded
# ones (the provisioning is deterministic: the same activate_paths +
# fx-activate sequence publishes the same count of snapshots)
V1B=$(mkstore "$STORE_B" "$WORK/osier-b")
[ "$V1B" = "$V1" ] || fail "store B's activation is v$V1B, expected v$V1 (the FACTS arm needs colliding version numbers)"
# B's .bootlog/.recovery must be byte-identical to what A's observation
# recorded, so the FACTS disagreement is isolated: copy A's records verbatim
# (the same fabrication as everywhere in this gate, stated in the header)
cp "$STORE/.bootlog" "$STORE_B/.bootlog"
cp "$STORE/.recovery" "$STORE_B/.recovery"
mkdir -p "$WORK/rootfs-b"
materialize_rootfs "$STORE_B" "$WORK/rootfs-b" "$V1B" "$WORK/pkgset-store-b.dhall"
# control: B against its OWN observation is coherent (B's copied .bootlog
# narrates the same 4 boots A's does, so its enrollment declares 4 too)
mkled "$WORK/nonces-b.led" 4
audit "$STORE_B" "$WORK/rootfs-b" 4 "$WORK/nonces-b.led" --obs-dir "$WORK/obs-b" > "$WORK/out.fb1" 2>&1
expect_coh "$WORK/out.fb1" $? "FACTS control (own observation)"
# the arm: B audited against A's observation file
audit "$STORE_B" "$WORK/rootfs-b" 4 "$WORK/nonces-b.led" --obs-file "$AOBSFILE" > "$WORK/out.fb2" 2>&1
expect_incoh "$WORK/out.fb2" $? "FACTS rebuilt history" disagreement-facts-changed
grep -q "version $V1B" "$WORK/out.fb2" \
    || fail "FACTS: the finding does not name version $V1B"
echo "test_fx_audit: FACTS: same version numbers, different content, against the old observation -> disagreement-facts-changed"

# ══ THE TRIGGER ═════════════════════════════════════════════════════════
# refuses a clean store
audit "$STORE" "$ROOT" 4 "$WORK/nonces-main.led" --obs-dir "$WORK/obs-trig-clean" --rollback > "$WORK/out.trigref" 2>&1
_rc=$?
[ "$_rc" = "1" ] || fail "TRIGGER clean: expected refusal exit 1, got $_rc"
grep -q 'refusing to roll back a coherent store' "$WORK/out.trigref" \
    || fail "TRIGGER clean: no refusal message"
[ "$(cur_of "$STORE")" = "$CUR" ] || fail "TRIGGER clean: CURRENT moved on a clean store"
# fires on the coherent-tamper store through the EXISTING machinery
fresh trig
tamper_coherent "$WORK/store-trig"
run_fixture trig --rollback "$V1" > "$WORK/out.trig" 2>&1
_rc=$?
[ "$_rc" = "0" ] || fail "TRIGGER: expected exit 0, got $_rc: $(tail -5 "$WORK/out.trig")"
grep -q "ROLLBACK $CUR -> $V1" "$WORK/out.trig" \
    || fail "TRIGGER: no loud ROLLBACK line naming source and target"
grep -q 'INCOHERENT disagreement-bootlog-rewritten' "$WORK/out.trig" \
    || fail "TRIGGER: the rollback does not NAME the incoherence that caused it"
[ "$(cur_of "$WORK/store-trig")" = "$V1" ] || fail "TRIGGER: CURRENT not repointed at v$V1 (got $(cur_of "$WORK/store-trig"))"
# post-rollback: the store is coherent against the re-enrolled baseline
run_fixture trig > "$WORK/out.trig2" 2>&1
expect_coh "$WORK/out.trig2" $? "TRIGGER post-rollback re-audit"
# the auto-target must refuse a no-op: on the tampered store the newest
# ok-per-.bootlog IS the current version, so --rollback without a V must
# refuse rather than "roll back" 7 -> 7
fresh trig2
tamper_coherent "$WORK/store-trig2"
run_fixture trig2 --rollback > "$WORK/out.trig3" 2>&1
_rc=$?
[ "$_rc" = "1" ] || fail "TRIGGER auto-target: expected refusal exit 1, got $_rc"
grep -q 'would be a no-op' "$WORK/out.trig3" \
    || fail "TRIGGER auto-target: no no-op refusal: $(tail -4 "$WORK/out.trig3")"
[ "$(cur_of "$WORK/store-trig2")" = "$CUR" ] || fail "TRIGGER auto-target: CURRENT moved on a refusal"
echo "test_fx_audit: TRIGGER: refuses clean; rolls the tampered store back to v$V1 naming the finding; re-audit coherent; auto-target refuses the no-op"

# ══ SELFREPORT: attempts.jsonl is never evidence ════════════════════════
# an INCOHERENT store (the coherent tamper), because the strong claim is
# that no self-report can talk the seat out of an incoherence
fresh sr
tamper_coherent "$WORK/store-sr"
run_fixture sr > "$WORK/out.sr0" 2>&1; _rc0=$?
[ "$_rc0" = "1" ] || fail "SELFREPORT: the base store is not incoherent (rc=$_rc0)"
# the file DELETED (never present anywhere) vs PLANTED in the store vs
# DOCTORED in the rootfs — identical verdicts, byte-identical outputs
echo '{"task":"self-modify","verdict":"TASK_COMPLETE","ok":true,"rollbacks":0}' > "$WORK/rootfs-sr/attempts.jsonl"
echo '{"task":"self-modify","verdict":"TASK_COMPLETE","ok":true,"rollbacks":0}' > "$WORK/store-sr/attempts.jsonl"
run_fixture sr > "$WORK/out.sr1" 2>&1; _rc1=$?
[ "$_rc1" = "$_rc0" ] || fail "SELFREPORT: exit changed with attempts.jsonl planted ($_rc0 -> $_rc1)"
cmp -s "$WORK/out.sr0" "$WORK/out.sr1" \
    || fail "SELFREPORT: the output changed when attempts.jsonl was planted — the seat read a self-report"
echo '{"task":"self-modify","verdict":"TASK_COMPLETE","ok":true,"rollbacks":0,"note":"everything is fine"}' > "$WORK/store-sr/attempts.jsonl"
echo 'this is not even json' > "$WORK/rootfs-sr/attempts.jsonl"
run_fixture sr > "$WORK/out.sr2" 2>&1; _rc2=$?
[ "$_rc2" = "$_rc0" ] || fail "SELFREPORT: exit changed with a doctored attempts.jsonl"
cmp -s "$WORK/out.sr0" "$WORK/out.sr2" \
    || fail "SELFREPORT: the output changed when attempts.jsonl was doctored"
echo "test_fx_audit: SELFREPORT: absent / planted / doctored attempts.jsonl -> byte-identical incoherent verdict"

# ══ LOUD: a record that cannot be read ══════════════════════════════════
fresh unreadable
chmod 000 "$WORK/store-unreadable/.bootlog"
run_fixture unreadable > "$WORK/out.unreadable" 2>&1
_rc=$?
[ "$_rc" = "2" ] || fail "LOUD: an unreadable .bootlog must be exit 2 (tool error), got $_rc"
grep -q 'FAIL' "$WORK/out.unreadable" || fail "LOUD: no FAIL message"
chmod 644 "$WORK/store-unreadable/.bootlog"
# an observation dir INSIDE the store is refused (host memory must not live
# on agent-reachable disk)
FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$WORK/store-unreadable" \
    --rootfs "$WORK/rootfs-unreadable" --obs-dir "$WORK/store-unreadable/obs-inside" \
    --boots 4 --nonces "$WORK/nonces-unreadable.led" \
    > "$WORK/out.inside" 2>&1
_rc=$?
[ "$_rc" = "2" ] || fail "LOUD: an --obs-dir inside the store must be refused (exit 2), got $_rc"
grep -q 'INSIDE the store' "$WORK/out.inside" || fail "LOUD: the refusal does not say why"
echo "test_fx_audit: LOUD: unreadable record -> exit 2; obs-inside-store refused"

# ══ BOOTS: the anchor is REQUIRED — no silent default ═══════════════════
FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$STORE" --rootfs "$ROOT" \
    > "$WORK/out.noboots" 2>&1
_rc=$?
[ "$_rc" = "2" ] || fail "BOOTS: a missing --boots must be exit 2 (tool error), got $_rc"
grep -q 'boots is REQUIRED' "$WORK/out.noboots" \
    || fail "BOOTS: the refusal does not say what is missing"
grep -q 'assuming a count' "$WORK/out.noboots" \
    || fail "BOOTS: the refusal does not say WHY it refuses to assume"
echo "test_fx_audit: BOOTS: no --boots -> exit 2, loud refusal (an optional anchor that silently defaults is a decorative bound)"

# ══ FORGERY: the measured hole, closed ══════════════════════════════════
# THE MOTIVATING EXPLOIT, on the store where it is actually invisible: a
# failure that has NOT been rolled forward (no .recovery row — the moment
# the exploit is used).  v$V2's last verdict is failed; the agent APPENDS
# "<v$V2> ok" in the writer's exact shape.  bootlog_last (init.zig:764)
# reads the LAST non-shutdown status, so the next boot would treat v$V2 as
# ok and fx-init would NOT roll forward — the broken generation stays
# current.  On the standard baseline (which carries a .recovery row from
# v$V2) the bare forge also trips recovery-without-failure — a row pointing
# at a version whose failure vanished; with NO row nothing cross-checks it
# and only the host's boot count can see it.
mk_norec() { # mk_norec NAME — a store whose failure was never rolled forward
    # v1 boots ok; v2 boots and FAILS; the OPERATOR hard-rolls back to v1
    # (fxstore rollback --hard — operator rollbacks write no .recovery row,
    # by the journal's own header), and v1 boots ok again.  THREE boots
    # (nonces 1..3), header-only .recovery.  Enrollment runs with its own
    # observation file (the fresh-copied one describes the standard
    # baseline) — re-enrolling from the file-copied bytes would carry the
    # STANDARD baseline's boot count (4), so the arm RE-ENROLLS at --boots 3.
    _n="$1"
    fresh "$_n"
    write_records "$WORK/store-$_n" \
        "$V1 in-progress 99 $(nth 1)" \
        "$V1 ok 100 $(nth 1)" \
        "$V2 in-progress 100 $(nth 2)" \
        "$V2 failed 101 $(nth 2)" \
        "$V1 in-progress 104 $(nth 3)" \
        "$V1 ok 105 $(nth 3)"
    FXSTORE_BIN="$FXSTORE" "$FXSTORE" rollback --hard "$V1" --store "$WORK/store-$_n" >/dev/null 2>&1 \
        || fail "NOREC $_n: fxstore rollback --hard $V1 failed"
    [ "$(cur_of "$WORK/store-$_n")" = "$V1" ] \
        || fail "NOREC $_n: the hard rollback did not repoint CURRENT at v$V1"
    rm -f "$WORK/obsf-$_n.obs"
    if [ "${NOREC_OLD:-0}" = "1" ]; then
        # the PRE-NONCE writer's exact output (3-field lines, 4-field rows):
        # what fx-init at the writer pin (500fc68) appends — the world the
        # pinned pre-nonce readers audited.  The enroll still passes the
        # ledger (the new tool parses it; nothing is judged at enrollment).
        sed -i 's/ \(badfee[0-9a-f]*\)$//' "$WORK/store-$_n/.bootlog"
        sed -i 's/ \(badfee[0-9a-f]*\)$//' "$WORK/store-$_n/.recovery"
    fi
    FBOOTS=3 run_fixture "$_n" > "$WORK/out.norec-$_n" 2>&1
    expect_coh "$WORK/out.norec-$_n" $? "NOREC enroll ($_n)"
}

mk_norec forg
echo "$V2 ok 999 deadbad00000009" >> "$WORK/store-forg/.bootlog"
FBOOTS=3 run_fixture forg > "$WORK/out.forg" 2>&1
expect_incoh "$WORK/out.forg" $? "FORGERY" bootlog-forged-verdict
grep -q "an ADDED '$V2 ok 999' line has no '$V2 in-progress' line earlier in this window" "$WORK/out.forg" \
    || fail "FORGERY: the finding does not quote the forged line: $(grep '^INCOHERENT bootlog-forged-verdict' "$WORK/out.forg")"
grep -q 'no boot the host started is behind this line' "$WORK/out.forg" \
    || fail "FORGERY: the finding does not say no host boot is behind the line"
grep -q 'forged .ok. makes the next boot skip the roll-forward' "$WORK/out.forg" \
    || fail "FORGERY: the finding does not name the consequence (skipped roll-forward, broken generation stays current)"
# the forge passes EVERY cross-check — the hole is closed by the count alone
for _c in version-chain recovery-without-failure verify-drift facts-path-gone \
          src-of-artifact records-damaged previous-observation; do
    grep -q "^check $_c: pass\$" "$WORK/out.forg" \
        || fail "FORGERY: cross-check $_c did not pass (the forge is not invisible to it — the arm is vacuous): $(grep '^check' "$WORK/out.forg")"
done
echo "test_fx_audit: FORGERY: the APPENDED '$V2 ok 999' passes every cross-check and fires bootlog-forged-verdict, named in the exploit's own terms"

# FABBOOT: a COMPLETE forged boot (in-progress + verdict, both in the
# writer's shape) with no host boot behind it — attribution alone would
# pass this (the verdict rides its in-progress); only the COUNT catches it
fresh fab
echo "$CUR in-progress 104 deadbad00000007" >> "$WORK/store-fab/.bootlog"
echo "$CUR ok 105 deadbad00000007" >> "$WORK/store-fab/.bootlog"
run_fixture fab > "$WORK/out.fab" 2>&1
expect_incoh "$WORK/out.fab" $? "FABBOOT" bootlog-fabricated-boots
grep -q 'in-progress line(s) added but the host started only 0 boot(s)' "$WORK/out.fab" \
    || fail "FABBOOT: the finding does not name the count disagreement: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.fab")"
echo "test_fx_audit: FABBOOT: a whole forged boot-pair with no host boot fires bootlog-fabricated-boots"

# TORNFORGE: the same forge WITHOUT the trailing newline — fx-init reads
# .bootlog with fgets, and fgets returns a final unterminated line, so the
# forge steers bootlog_last just the same; the accounting must not have a
# no-newline bypass
mk_norec torn
printf '%s' "$V2 ok 999 deadbad0000000" >> "$WORK/store-torn/.bootlog"
FBOOTS=3 run_fixture torn > "$WORK/out.torn" 2>&1
expect_incoh "$WORK/out.torn" $? "TORNFORGE" bootlog-forged-verdict
grep -q 'TORN' "$WORK/out.torn" \
    || fail "TORNFORGE: the finding does not say the line is torn: $(grep '^INCOHERENT bootlog-forged-verdict' "$WORK/out.torn")"
grep -q '^check recovery-without-failure: pass$' "$WORK/out.torn" \
    || fail "TORNFORGE: recovery-without-failure fired too (isolation failed)"
echo "test_fx_audit: TORNFORGE: a forge without its newline still fires (fgets returns it in-guest)"

# TORNLEGIT: the FALSE POSITIVE the review MEASURED, as a LEGITIMATE shape.
# A boot whose append was cut short by a crash: its in-progress line landed,
# its verdict line is torn.  The host started that boot (the delta accounts
# for it) and the reader itself classes a torn tail as "a crash mid-write,
# not tamper" — so this is NOT a finding, and the torn line must still be
# NAMED (a pass that hides it would be the silent pass the header forbids).
mk_norec tleg
echo "$V1 in-progress 106 $(nth 4)" >> "$WORK/store-tleg/.bootlog"
# the torn verdict is cut MID-NONCE (the last character is missing): a torn
# line's own nonce can never be trusted, so the attribution — not the torn
# token — must answer for it
NC4=$(nth 4)
printf '%s' "$V1 ok 107 ${NC4%?}" >> "$WORK/store-tleg/.bootlog"
FBOOTS=4 run_fixture tleg > "$WORK/out.tleg" 2>&1
expect_coh "$WORK/out.tleg" $? "TORNLEGIT (a torn verdict riding its own boot's in-progress)"
grep -q "an added TORN '$V1 ok 107' line" "$WORK/out.tleg" \
    || fail "TORNLEGIT: the tolerated torn line is not NAMED (a silent pass): $(grep 'TORN' "$WORK/out.tleg")"
grep -q "accounted for by an added '$V1 in-progress' line" "$WORK/out.tleg" \
    || fail "TORNLEGIT: the naming does not say WHICH in-progress accounts for it: $(grep 'TORN' "$WORK/out.tleg")"
grep -q "boot accounting: host boots 3 -> 4 (delta 1); this window added in-progress 1, verdicts 1, shutdown 0" "$WORK/out.tleg" \
    || fail "TORNLEGIT: the torn verdict was not counted in the accounting line: $(grep 'boot accounting: host boots' "$WORK/out.tleg")"
grep -q 'torn tail' "$WORK/out.tleg" \
    || fail "TORNLEGIT: the torn tail was not reported at all (a silent pass)"
echo "test_fx_audit: TORNLEGIT: a torn verdict that rides its own boot's in-progress stays COHERENT and is NAMED (the pre-fix false positive — see TORNLEGIT-BEFORE)"

# ══ THE PAIR FORGERY, CLOSED (was KNOWN-HOLE) ════════════════════════════
# THE MEASURED HOLE: a forged line-PAIR appended into the SLACK of a boot
# the host started but fx-init never recorded (a SILENT boot) fully
# impersonated that boot — the count accounted it, the attribution found
# its own forged in-progress.  The per-boot nonce closes it; the arms pin
# every nonce choice a forger has, and both DIRECTIONS of the closure.

# PAIRSIL — the forger's realistic position: it cannot know a silent
# boot's nonce (future nonces do not exist; a silent boot ran no service
# to spend its own; a PAST boot's nonce is visible in-guest only on lines
# that already spent it).  Boot 4 was started SILENT (its nonce issued,
# nothing written), and the pair wears an INVENTED nonce.  It must FIRE
# as unbound — and the silent boot's own nonce must be REPORTED UNCLAIMED
# (a boot the host started that nothing speaks for is a visible, COHERENT
# state — never a silent pass, never a rollback).
mk_norec pairsil
echo "$V2 in-progress 999 deadbad00000001" >> "$WORK/store-pairsil/.bootlog"
echo "$V2 ok 999 deadbad00000001" >> "$WORK/store-pairsil/.bootlog"
FBOOTS=4 run_fixture pairsil > "$WORK/out.pairsil" 2>&1
expect_incoh "$WORK/out.pairsil" $? "PAIRSIL (a forged pair in a silent boot's slack, invented nonce)" bootlog-unbound-nonce
grep -q "2 ADDED .bootlog line(s) carry no nonce the host issued for a boot in this window; first: '$V2 in-progress 999 deadbad00000001'" "$WORK/out.pairsil" \
    || fail "PAIRSIL: the finding does not quote the forged pair's first line: $(grep '^INCOHERENT bootlog-unbound-nonce' "$WORK/out.pairsil")"
grep -q 'no boot the host started is behind a nonce-less or foreign-nonce line' "$WORK/out.pairsil" \
    || fail "PAIRSIL: the finding does not say no host boot is behind the pair"
grep -q "the nonce the host issued for boot 4 ($(nth 4)) is UNCLAIMED" "$WORK/out.pairsil" \
    || fail "PAIRSIL: the silent boot's nonce was not REPORTED unclaimed: $(grep 'UNCLAIMED' "$WORK/out.pairsil")"
grep -q '^check boot-accounting: failed$' "$WORK/out.pairsil" \
    || fail "PAIRSIL: boot-accounting did not fire"
echo "test_fx_audit: PAIRSIL: the forged PAIR in a silent boot's slack FIRES bootlog-unbound-nonce (invented nonce), and the silent boot's own nonce is REPORTED UNCLAIMED"

# PAIRCLS — the other nonce classes a nonce-less forger can wear, one line
# each on the same shape: the PLACEHOLDER ("none" — what a hand-booted
# writer emits, distinguishable from an issued nonce), NO FIELD AT ALL
# (the pre-nonce writer's old shape), and a PAST window's REAL nonce (one
# whose boot already spent it).  All must fire unbound — never silently
# accepted as accounted, never silently skipped.
mk_norec paircls
echo "$V2 in-progress 998 none"            >> "$WORK/store-paircls/.bootlog"
echo "$V2 ok 998 none"                     >> "$WORK/store-paircls/.bootlog"
echo "$V2 in-progress 997"                 >> "$WORK/store-paircls/.bootlog"
echo "$V2 ok 997"                          >> "$WORK/store-paircls/.bootlog"
echo "$V2 in-progress 996 $(nth 2)"        >> "$WORK/store-paircls/.bootlog"
echo "$V2 ok 996 $(nth 2)"                 >> "$WORK/store-paircls/.bootlog"
FBOOTS=4 run_fixture paircls > "$WORK/out.paircls" 2>&1
expect_incoh "$WORK/out.paircls" $? "PAIRCLS (placeholder / no-field / past-window nonce pairs)" bootlog-unbound-nonce
grep -q '6 ADDED .bootlog line(s) carry no nonce' "$WORK/out.paircls" \
    || fail "PAIRCLS: all six nonce-less lines must be named by one count: $(grep '^INCOHERENT bootlog-unbound-nonce' "$WORK/out.paircls")"
grep -q 'a hex nonce from an earlier window or outside the ledger is one this boot was never issued' "$WORK/out.paircls" \
    || fail "PAIRCLS: the finding does not name the earlier-window class (boot 2's real nonce, re-worn in window 4): $(grep '^INCOHERENT bootlog-unbound' "$WORK/out.paircls")"
grep -q "the nonce the host issued for boot 4 ($(nth 4)) is UNCLAIMED" "$WORK/out.paircls" \
    || fail "PAIRCLS: boot 4 was silent and its nonce must be REPORTED unclaimed"
echo "test_fx_audit: PAIRCLS: placeholder, no-field and past-window-nonce pairs all fire unbound (the earlier-window class is named; boot 4's silent nonce is reported)"

# PAIRONTOP — the strongest forger: it READ a REAL window nonce off the
# disk (boot 4's lines are on the platter) and appends its pair wearing
# THAT.  Boot 4 is no longer silent here — its own pair already spent the
# nonce's budget, so the reuse fires the per-nonce accounting: a second
# boot on paper wearing one real boot's nonce.
mk_norec pairontop
echo "$V1 in-progress 106 $(nth 4)" >> "$WORK/store-pairontop/.bootlog"
echo "$V1 ok 107 $(nth 4)"          >> "$WORK/store-pairontop/.bootlog"
echo "$V2 in-progress 999 $(nth 4)" >> "$WORK/store-pairontop/.bootlog"
echo "$V2 ok 999 $(nth 4)"          >> "$WORK/store-pairontop/.bootlog"
FBOOTS=4 run_fixture pairontop > "$WORK/out.pairontop" 2>&1
expect_incoh "$WORK/out.pairontop" $? "PAIRONTOP (a pair wearing a real nonce its boot already spent)" bootlog-fabricated-boots
grep -q "the nonce the host issued for boot 4 ($(nth 4)) carries 2 in-progress line(s) in this window" "$WORK/out.pairontop" \
    || fail "PAIRONTOP: the finding does not name the REUSED nonce and its budget: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.pairontop")"
grep -q '^INCOHERENT bootlog-unbound-nonce ' "$WORK/out.pairontop" \
    && fail "PAIRONTOP: a REAL window nonce must NOT be called unbound: $(grep '^INCOHERENT bootlog-unbound' "$WORK/out.pairontop")"
echo "test_fx_audit: PAIRONTOP: a pair wearing a real window nonce its boot already spent fires the per-nonce budget (a disk-read nonce is not a reusable one)"

# PAIRNOLEDGER — the anchor itself is required: a window with boots and no
# ledger is exit 2, not a silently-narrower check (the --boots rule).
mk_norec pairnol
FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$WORK/store-pairnol" \
    --rootfs "$WORK/rootfs-pairnol" --obs-file "$WORK/obsf-pairnol.obs" --boots 4 \
    > "$WORK/out.pairnol" 2>&1
_rc=$?
[ "$_rc" = "2" ] || fail "PAIRNOLEDGER: a window with boots and no --nonces must be exit 2, got $_rc: $(sed -n 1,3p "$WORK/out.pairnol")"
grep -q 'nonces is REQUIRED when the window holds boots' "$WORK/out.pairnol" \
    || fail "PAIRNOLEDGER: the refusal does not name the missing anchor"
grep -q 'decorative' "$WORK/out.pairnol" \
    || fail "PAIRNOLEDGER: the refusal does not say why it refuses to default"
echo "test_fx_audit: PAIRNOLEDGER: --boots 3 -> 4 with no --nonces is exit 2, loud (the nonce ledger is an anchor, not an option)"

# NONELEDGER — the ledger must agree with the WRITER's reservation: 'none'
# is the writer's no-nonce-issued placeholder and parse_kernel_nonce REFUSES
# fx.bootnonce=none as a host value, so the host can never have issued it.
# A ledger that claimed it would let every placeholder line in a window
# claim THAT boot's nonce — the reader must die (exit 2), not guess.  FAILS
# if load_nonces ever accepts the token.
fresh nres
mkled "$WORK/nonces-nres.led" 4
echo "5 none" >> "$WORK/nonces-nres.led"
FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$WORK/store-nres" \
    --rootfs "$WORK/rootfs-nres" --obs-file "$WORK/obsf-nres.obs" \
    --boots 5 --nonces "$WORK/nonces-nres.led" > "$WORK/out.nres" 2>&1
_rc=$?
[ "$_rc" = "2" ] || fail "NONELEDGER: a ledger nonce 'none' must be exit 2 (the writer reserves the token), got $_rc: $(sed -n 1,3p "$WORK/out.nres")"
grep -q "reserves 'none' as its no-nonce-issued placeholder" "$WORK/out.nres" \
    || fail "NONELEDGER: the refusal does not name the writer's reservation: $(sed -n 1,3p "$WORK/out.nres")"
grep -q 'Fix the ledger' "$WORK/out.nres" \
    || fail "NONELEDGER: the refusal does not say whose record is wrong"
echo "test_fx_audit: NONELEDGER: a ledger entry 'none' is exit 2 — the reader now agrees with the writer's reservation (the host never issued that token)"

# CAP: the reader's .bootlog line table is a FIXED 4096.  Past it, lines
# were SILENTLY DROPPED from both the counting and the forged-verdict
# attribution — i.e. an audit that reports on a file it truncated, the exact
# silent pass the tool's header forbids ("a record that cannot be READ is
# its own LOUD state (exit 2), never a silent pass").  The forge sits AT
# line 4097: the line that must not be able to escape.
fresh cap
i=0; while [ $i -lt 4096 ]; do echo "$CUR in-progress $((200 + i))" >> "$WORK/store-cap/.bootlog"; i=$((i+1)); done
echo "$V2 ok 999" >> "$WORK/store-cap/.bootlog"
FBOOTS=4 run_fixture cap > "$WORK/out.cap" 2>&1
_rc=$?
[ "$_rc" = "2" ] || fail "CAP: a .bootlog past the 4096-line table must be exit 2 (loud), got $_rc: $(sed -n 1,4p "$WORK/out.cap")"
grep -q '4096' "$WORK/out.cap" || fail "CAP: the refusal does not name the CAP: $(sed -n 1,3p "$WORK/out.cap")"
grep -q '\.bootlog' "$WORK/out.cap" || fail "CAP: the refusal does not name the FILE"
grep -q 'silently dropped' "$WORK/out.cap" \
    || fail "CAP: the refusal does not say what would have happened to the lines past the cap"
echo "test_fx_audit: CAP: a .bootlog longer than the 4096-line table is exit 2, naming the cap and the file"

# CAP-REC: the same for .recovery's 1024-row table
fresh caprec
i=0; while [ $i -lt 1024 ]; do echo "$((100 + i)) $CUR $V2 $GH_CUR" >> "$WORK/store-caprec/.recovery"; i=$((i+1)); done
echo "9999 $CUR $V2 $GH_CUR" >> "$WORK/store-caprec/.recovery"
FBOOTS=4 run_fixture caprec > "$WORK/out.caprec" 2>&1
_rc=$?
[ "$_rc" = "2" ] || fail "CAP-REC: a .recovery past the 1024-row table must be exit 2 (loud), got $_rc: $(sed -n 1,4p "$WORK/out.caprec")"
grep -q '1024' "$WORK/out.caprec" || fail "CAP-REC: the refusal does not name the CAP"
grep -q '\.recovery' "$WORK/out.caprec" || fail "CAP-REC: the refusal does not name the FILE"
grep -q 'silently dropped' "$WORK/out.caprec" || fail "CAP-REC: the refusal does not say what would have happened"
echo "test_fx_audit: CAP-REC: a .recovery longer than the 1024-row table is exit 2, naming the cap and the file"

# ══ LEGIT: every legitimate growth shape stays coherent ════════════════
# a boot that FAILS (in-progress + failed) — FBOOTS declares one new boot
fresh legfail
echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-legfail/.bootlog"
echo "$CUR failed 111 $(nth 5)" >> "$WORK/store-legfail/.bootlog"
FBOOTS=5 run_fixture legfail > "$WORK/out.legfail" 2>&1
expect_coh "$WORK/out.legfail" $? "LEGIT failed boot"
echo "test_fx_audit: LEGIT: a boot that fails (in-progress + failed, --boots 5) stays coherent"

# a failure that ROLLS FORWARD: the failed boot, then the REAL fxstore soft
# rollback (fx-init's own roll-forward driver) republishing v$V1's content
# as a NEW version, then that generation's boot (in-progress + ok) and its
# .recovery row — two boots, all growth accounted
fresh legrwf
echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-legrwf/.bootlog"
echo "$CUR failed 111 $(nth 5)" >> "$WORK/store-legrwf/.bootlog"
FXSTORE_BIN="$FXSTORE" "$FXSTORE" rollback "$V1" --store "$WORK/store-legrwf" >/dev/null 2>&1 \
    || fail "LEGIT rwf: fxstore rollback $V1 failed"
ROLLV=$(cur_of "$WORK/store-legrwf")
[ "$ROLLV" -gt "$CUR" ] || fail "LEGIT rwf: the republish did not ratchet ($ROLLV <= $CUR)"
GH_ROLL=$(genhash_of "$WORK/store-legrwf" "$ROLLV")
[ "$GH_ROLL" = "$GH1" ] || fail "LEGIT rwf: the republished content is not v$V1's (genhash $GH_ROLL != $GH1)"
echo "$ROLLV in-progress 112 $(nth 6)" >> "$WORK/store-legrwf/.bootlog"
echo "$ROLLV ok 113 $(nth 6)" >> "$WORK/store-legrwf/.bootlog"
echo "111 $ROLLV $CUR $GH_ROLL $(nth 6)" >> "$WORK/store-legrwf/.recovery"
FBOOTS=6 run_fixture legrwf > "$WORK/out.legrwf" 2>&1
expect_coh "$WORK/out.legrwf" $? "LEGIT roll-forward boot"
grep -q '^check recovery-without-failure: pass$' "$WORK/out.legrwf" \
    || fail "LEGIT rwf: recovery-without-failure fired on a real recorded failure (isolation failed)"
echo "test_fx_audit: LEGIT: a failure that rolls forward (failed -> real fxstore republish v$ROLLV -> in-progress + ok + .recovery row, --boots 6) stays coherent"

# a clean SHUTDOWN: the writer appends ip + ok + shutdown, ONE boot
fresh legsd
echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-legsd/.bootlog"
echo "$CUR ok 111 $(nth 5)" >> "$WORK/store-legsd/.bootlog"
echo "$CUR shutdown 112 $(nth 5)" >> "$WORK/store-legsd/.bootlog"
FBOOTS=5 run_fixture legsd > "$WORK/out.legsd" 2>&1
expect_coh "$WORK/out.legsd" $? "LEGIT clean shutdown"
echo "test_fx_audit: LEGIT: a clean shutdown (in-progress + ok + shutdown) stays coherent"

# a boot KILLED AT THE VERDICT (init.zig's own comment: the harness kills
# the VM at the verdict) — in-progress alone, no verdict: legal, the boot
# never decided
fresh legkill
echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-legkill/.bootlog"
FBOOTS=5 run_fixture legkill > "$WORK/out.legkill" 2>&1
expect_coh "$WORK/out.legkill" $? "LEGIT killed at verdict"
echo "test_fx_audit: LEGIT: a boot killed at the verdict (in-progress alone) stays coherent"

# a SILENT boot: the host started one more boot (issuing its nonce) and the
# writer appended NOTHING (no bootable generation: decide_boot_version
# returned 0, which appends no line and pre-decides the verdict away,
# init.zig:4695-4701).  Coherent — and the nonce makes the silence ITSELF a
# reportable fact: the boot's nonce is UNCLAIMED.  This is the
# false-positive direction the review priced: a machine that booted nothing
# is not an incoherence, and an unclaimed nonce must NEVER roll a healthy
# machine back.  (Before the nonce this slack was the forger's opening; now
# the slack is NAMED every run — a pair claiming it cannot wear its nonce.)
fresh legq
FBOOTS=5 run_fixture legq > "$WORK/out.legq" 2>&1
expect_coh "$WORK/out.legq" $? "LEGIT silent boot"
grep -q 'no .bootlog lines added this window' "$WORK/out.legq" \
    || fail "LEGIT silent boot: the empty window was not reported as such: $(grep 'boot accounting' "$WORK/out.legq")"
grep -q "the nonce the host issued for boot 5 ($(nth 5)) is UNCLAIMED" "$WORK/out.legq" \
    || fail "LEGIT silent boot: the silent boot's issued nonce was not REPORTED unclaimed: $(grep 'UNCLAIMED' "$WORK/out.legq")"
grep -q 'never roll a healthy machine back' "$WORK/out.legq" \
    || fail "LEGIT silent boot: the unclaimed-nonce report does not state its own direction (reported, not a finding)"
echo "test_fx_audit: LEGIT: a silent boot (started, nothing appended — no bootable generation) stays coherent AND its nonce is REPORTED UNCLAIMED"

# the SAME version booted TWICE in one window: two boots of v$CUR, each the
# writer's real line pair, in file order.  The second verdict must consume
# the SECOND in-progress — not the first one twice, and not nothing.
# FAILS if the in-order consumption is removed or made per-version-global:
# the second verdict then finds no UNCONSUMED in-progress for its version and
# the arm exits 1 bootlog-forged-verdict (it is the "consumed" half of the
# attribution rule that this arm holds).
fresh twice
echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-twice/.bootlog"
echo "$CUR ok 111 $(nth 5)" >> "$WORK/store-twice/.bootlog"
echo "$CUR in-progress 112 $(nth 6)" >> "$WORK/store-twice/.bootlog"
echo "$CUR ok 113 $(nth 6)" >> "$WORK/store-twice/.bootlog"
FBOOTS=6 run_fixture twice > "$WORK/out.twice" 2>&1
expect_coh "$WORK/out.twice" $? "LEGIT same version booted twice in one window"
grep -q 'boot accounting: host boots 4 -> 6 (delta 2); this window added in-progress 2, verdicts 2, shutdown 0' "$WORK/out.twice" \
    || fail "LEGIT twice: both boots were not accounted: $(grep 'boot accounting: host boots' "$WORK/out.twice")"
echo "test_fx_audit: LEGIT: the same version booted twice in one window (2 real pairs, --boots 4 -> 6) stays coherent"

# a MULTI-CYCLE roll-forward inside ONE window: the current version fails, a
# boot rolls forward to the republished generation (a .recovery row), THAT
# generation fails too, and a second boot rolls forward again — two complete
# cycles between two audits (4 boots, 2 rows).  Writer-faithful: the row is
# written in the boot that rolls forward (init.zig:1787, recovery_append's
# call), before that boot's in-progress line (init.zig:4705), and each row
# names the version that failed.
# FAILS if recovery-without-failure reads anything but the LAST non-shutdown
# verdict for a row's from-failed version (boot 6 wrote "$R1 ok 113", boot 7
# wrote "$R1 failed 115": a first-match reader calls row 2 unanswered), or
# if the row bound were tightened to one-per-window, or if the attribution
# mis-paired the two cycles.
fresh multi
echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-multi/.bootlog"
echo "$CUR failed 111 $(nth 5)" >> "$WORK/store-multi/.bootlog"
FXSTORE_BIN="$FXSTORE" "$FXSTORE" rollback "$V1" --store "$WORK/store-multi" >/dev/null 2>&1 \
    || fail "LEGIT multi: the first fxstore rollback failed"
R1=$(cur_of "$WORK/store-multi")
[ "$R1" -gt "$CUR" ] || fail "LEGIT multi: cycle 1 did not ratchet ($R1 <= $CUR)"
GH_R1=$(genhash_of "$WORK/store-multi" "$R1")
[ "$GH_R1" = "$GH1" ] || fail "LEGIT multi: cycle 1's republish is not v$V1's content"
echo "$R1 in-progress 112 $(nth 6)" >> "$WORK/store-multi/.bootlog"
echo "$R1 ok 113 $(nth 6)" >> "$WORK/store-multi/.bootlog"
echo "111 $R1 $CUR $GH_R1 $(nth 6)" >> "$WORK/store-multi/.recovery"
echo "$R1 in-progress 114 $(nth 7)" >> "$WORK/store-multi/.bootlog"
echo "$R1 failed 115 $(nth 7)" >> "$WORK/store-multi/.bootlog"
FXSTORE_BIN="$FXSTORE" "$FXSTORE" rollback "$V1" --store "$WORK/store-multi" >/dev/null 2>&1 \
    || fail "LEGIT multi: the second fxstore rollback failed"
R2=$(cur_of "$WORK/store-multi")
[ "$R2" -gt "$R1" ] || fail "LEGIT multi: cycle 2 did not ratchet ($R2 <= $R1)"
GH_R2=$(genhash_of "$WORK/store-multi" "$R2")
[ "$GH_R2" = "$GH1" ] || fail "LEGIT multi: cycle 2's republish is not v$V1's content"
echo "$R2 in-progress 116 $(nth 8)" >> "$WORK/store-multi/.bootlog"
echo "$R2 ok 117 $(nth 8)" >> "$WORK/store-multi/.bootlog"
echo "115 $R2 $R1 $GH_R2 $(nth 8)" >> "$WORK/store-multi/.recovery"
FBOOTS=8 run_fixture multi > "$WORK/out.multi" 2>&1
expect_coh "$WORK/out.multi" $? "LEGIT multi-cycle roll-forward in one window"
grep -q 'boot accounting: host boots 4 -> 8 (delta 4); this window added in-progress 4, verdicts 4, shutdown 0' "$WORK/out.multi" \
    || fail "LEGIT multi: the four boots were not accounted: $(grep 'boot accounting: host boots' "$WORK/out.multi")"
grep -q '^check recovery-without-failure: pass$' "$WORK/out.multi" \
    || fail "LEGIT multi: a real SECOND roll-forward tripped recovery-without-failure: $(grep '^INCOHERENT' "$WORK/out.multi")"
echo "test_fx_audit: LEGIT: a MULTI-CYCLE roll-forward in one window (two real fxstore republishes -> 2 rows, 4 boots, --boots 4 -> 8) stays coherent"

# an in-progress followed by a SHUTDOWN and NO verdict: the boot started, was
# told to stop during the grace (SIGTERM -> sigterm_handler sets g_shutdown ->
# the main loop exits -> do_shutdown appends the shutdown line, init.zig:4215,
# called from :4779), and never decided.  Writer-faithful: do_shutdown appends
# its line whether or not the boot ever decided a verdict.
# FAILS if the counter ever demanded a verdict before a shutdown line, or if
# an open in-progress for the current version were turned into its own
# finding (the "every boot must decide" reading the writer contradicts).
fresh ipsd
echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-ipsd/.bootlog"
echo "$CUR shutdown 111 $(nth 5)" >> "$WORK/store-ipsd/.bootlog"
FBOOTS=5 run_fixture ipsd > "$WORK/out.ipsd" 2>&1
expect_coh "$WORK/out.ipsd" $? "LEGIT in-progress then shutdown (clean stop during the judgement)"
grep -q 'boot accounting: host boots 4 -> 5 (delta 1); this window added in-progress 1, verdicts 0, shutdown 1' "$WORK/out.ipsd" \
    || fail "LEGIT ipsd: the shutdown-without-verdict boot was not accounted: $(grep 'boot accounting: host boots' "$WORK/out.ipsd")"
echo "test_fx_audit: LEGIT: an in-progress followed by a shutdown (clean stop during the judgement, no verdict) stays coherent"

# ══ THE RE-ARM: the writer's SECOND verdict per boot, derived not patched ═
# The per-nonce VERDICT budget (<=1 verdict per nonce) rested on "the
# g_boot_decided latch allows at most one verdict per boot" — and the writer
# refutes it: the in-guest `activate` (the control channel; the agent-slot
# loop's every task cycle) publishes a NEW version through fx-activate and
# RE-ARMS the latch (init.zig:3616-3619), so one boot under one nonce
# legitimately carries a verdict for the ACTIVATED version as well.
# fx-init's own suite measures the second DISK verdict
# (tests/qemu_boot_rollback.sh:18-27).  A reader that budgets verdicts per
# nonce calls this healthy boot a forgery and rolls a healthy machine back.
# The derived rule: verdicts are budgeted PER VERSION (<= the window's
# in-progress lines for the version, + 1 ONLY for a first-published version
# with NO re-arm ip of its own), and a verdict's provenance is EITHER a
# same-nonce in-progress OR the store's own record
# that the version was first published in this window.
# mk_rearm NAME — the common fixture: boot 5 boots v$CUR ok (the writer's
# real pair under its issued nonce), then the harness drives the SAME
# fx-activate the in-guest handler runs (publishing v$ACTV > v$CUR, CURRENT
# moves — the store's own publish record), then the re-armed grace window
# verdicts the ACTIVATED generation: "$ACTV failed" with NO in-progress for
# it, wearing the SAME boot-5 nonce.  The activate uses CUR's OWN config
# content so the materialized rootfs still reconciles (the audit verifies
# against CURRENT's facts, which the publish moved).
mk_rearm() { # mk_rearm NAME — sets REARM_V to the activated version
    _n="$1"
    fresh "$_n"
    echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-$_n/.bootlog"
    echo "$CUR ok 111 $(nth 5)"          >> "$WORK/store-$_n/.bootlog"
    _a=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$WORK/store-$_n" \
            --package-set "$PS_A" --config "$WORK/cfg-store-a.dhall" 2>&1 \
            | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$_a" ] || fail "mk_rearm $_n: no version from the activate"
    [ "$_a" -gt "$CUR" ] || fail "mk_rearm $_n: the activate did not ratchet ($_a <= $CUR)"
    materialize_rootfs "$WORK/store-$_n" "$WORK/rootfs-$_n" "$_a" "$PS_A"
    echo "$_a failed 112 $(nth 5)" >> "$WORK/store-$_n/.bootlog"
    REARM_V="$_a"
}

# REARM — the healthy shape: ONE boot, ONE nonce, TWO verdicts, the second
# for the activated version.  FAILS (exit 1) if any per-nonce verdict budget
# survives, and FAILS the naming grep if the anchor accepts the line
# silently (a pass that hides what accounted for it).
mk_rearm rearm
FBOOTS=5 run_fixture rearm > "$WORK/out.rearm" 2>&1
expect_coh "$WORK/out.rearm" $? "REARM (one boot, one nonce: the boot's own verdict + the activate re-arm's verdict for the newly published version)"
grep -q "an ADDED '$REARM_V failed 112' verdict rides no in-progress of its own, but v$REARM_V was FIRST PUBLISHED this window" "$WORK/out.rearm" \
    || fail "REARM: the re-arm attribution is not NAMED (a silent pass): $(grep -i 're-arm\|first published' "$WORK/out.rearm")"
grep -q 'INCOHERENT' "$WORK/out.rearm" \
    && fail "REARM: a healthy re-arm boot was called incoherent: $(grep '^INCOHERENT' "$WORK/out.rearm")"
echo "test_fx_audit: REARM: one boot, one nonce, TWO verdicts — the second for the in-guest-activated version, no in-progress of its own — stays COHERENT with the re-arm attribution NAMED (the per-nonce verdict budget the writer refuted is gone)"

# DGRACE — the during-grace activate the review MEASURED firing at the old
# version-exact attribution: the boot's in-progress names the version it
# BOOTED, the (single) verdict names the ACTIVATED version, and the boot
# never verdicts its own — the activate superseded the window before grace
# expiry.  FAILS (exit 1) if a verdict is only ever attributable to a
# same-version in-progress.
fresh dgrace
echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-dgrace/.bootlog"
DGV=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$WORK/store-dgrace" \
        --package-set "$PS_A" --config "$WORK/cfg-store-a.dhall" 2>&1 \
        | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$DGV" ] || fail "DGRACE: no version from the activate"
materialize_rootfs "$WORK/store-dgrace" "$WORK/rootfs-dgrace" "$DGV" "$PS_A"
echo "$DGV ok 111 $(nth 5)" >> "$WORK/store-dgrace/.bootlog"
FBOOTS=5 run_fixture dgrace > "$WORK/out.dgrace" 2>&1
expect_coh "$WORK/out.dgrace" $? "DGRACE (a during-grace activate: the boot's in-progress for the booted version, the verdict for the activated one)"
grep -q "an ADDED '$DGV ok 111' verdict rides no in-progress of its own, but v$DGV was FIRST PUBLISHED this window" "$WORK/out.dgrace" \
    || fail "DGRACE: the re-arm attribution is not NAMED: $(grep -i 're-arm\|first published' "$WORK/out.dgrace")"
echo "test_fx_audit: DGRACE: a verdict for the ACTIVATED version while the boot's only in-progress names the booted one stays COHERENT (the review's SHOULD-FIX 1 shape)"

# REARMFLIP — the one attack the derived budget exists to catch: a SECOND
# verdict for the version the window already verdicted (the re-arm's own),
# appended after it wearing the same live nonce, overwriting what
# bootlog_last will read.  Per-nonce accounting is structurally blind here
# (one nonce, and the writer may legitimately carry many verdicts on it);
# the PER-VERSION budget is the catcher.  FAILS (goes coherent) if the
# budget is removed or miscounts the re-arm allowance.
mk_rearm rearmflip
echo "$REARM_V ok 999 $(nth 5)" >> "$WORK/store-rearmflip/.bootlog"
FBOOTS=5 run_fixture rearmflip > "$WORK/out.rearmflip" 2>&1
expect_incoh "$WORK/out.rearmflip" $? "REARMFLIP (a second verdict for the version the window already verdicted)" bootlog-fabricated-boots
grep -q "version $REARM_V carries 2 ADDED verdict line(s) this window but at most 1 can be behind them (0 in-progress line(s) for v$REARM_V, first published this window)" "$WORK/out.rearmflip" \
    || fail "REARMFLIP: the finding does not name the version's verdict budget: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.rearmflip")"
grep -q '^INCOHERENT bootlog-forged-verdict ' "$WORK/out.rearmflip" \
    && fail "REARMFLIP: provenance fired too (isolation failed — BOTH verdicts legitimately ride the first-published anchor; only the budget may fire): $(grep '^INCOHERENT' "$WORK/out.rearmflip")"
echo "test_fx_audit: REARMFLIP: a SECOND verdict for the activated version (same live nonce) fires the PER-VERSION verdict budget — the flip a per-nonce rule cannot see"

# ── THE NEW-WRITER RE-ARM SHAPE (the re-arm in-progress, init.zig:3543) ──
# mk_rearmip NAME — boot 5 boots v$CUR ok (the writer's real pair under its
# issued nonce), then the SAME fx-activate the in-guest handler drives
# publishes v$ACTV > v$CUR, and the activated version's OWN
# "<v> in-progress" lands BEFORE the re-armed window's verdict for it — the
# exact on-disk order fx-init's activate arm now writes (the ip after the
# CURRENT rewrite and before the facts are read).  Sets REARMIP_V.
mk_rearmip() { # mk_rearmip NAME — sets REARMIP_V to the activated version
    _n="$1"
    fresh "$_n"
    echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-$_n/.bootlog"
    echo "$CUR ok 111 $(nth 5)"          >> "$WORK/store-$_n/.bootlog"
    _a=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$WORK/store-$_n" \
            --package-set "$PS_A" --config "$WORK/cfg-store-a.dhall" 2>&1 \
            | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$_a" ] || fail "mk_rearmip $_n: no version from the activate"
    [ "$_a" -gt "$CUR" ] || fail "mk_rearmip $_n: the activate did not ratchet ($_a <= $CUR)"
    materialize_rootfs "$WORK/store-$_n" "$WORK/rootfs-$_n" "$_a" "$PS_A"
    echo "$_a in-progress 112 $(nth 5)" >> "$WORK/store-$_n/.bootlog"
    echo "$_a ok 113 $(nth 5)"          >> "$WORK/store-$_n/.bootlog"
    REARMIP_V="$_a"
}

# REARMIP — the healthy NEW-writer shape: one boot, one nonce, the boot's
# own ip+verdict, then the re-arm ip AND its verdict for the activated
# version.  FAILS (exit 1) if the per-nonce rule rejects a legitimate
# re-arm line (a healthy machine rolled back), and FAILS its greps if
# either attribution is not NAMED (a silent pass).
mk_rearmip rearmip
FBOOTS=5 run_fixture rearmip > "$WORK/out.rearmip" 2>&1
expect_coh "$WORK/out.rearmip" $? "REARMIP (the NEW writer shape: the activated version's own in-progress, then its verdict, one boot, one nonce)"
grep -q "carries a RE-ARM in-progress for v$REARMIP_V" "$WORK/out.rearmip" \
    || fail "REARMIP: the re-arm in-progress is not NAMED: $(grep -i 'RE-ARM' "$WORK/out.rearmip")"
grep -q "for v$REARMIP_V CONSUMES the RE-ARM in-progress this boot wrote for it" "$WORK/out.rearmip" \
    || fail "REARMIP: the verdict is not NAMED as riding the re-arm ip: $(grep -i 'CONSUMES' "$WORK/out.rearmip")"
grep -q 'INCOHERENT' "$WORK/out.rearmip" \
    && fail "REARMIP: a healthy new-writer re-arm boot was called incoherent: $(grep '^INCOHERENT' "$WORK/out.rearmip")"
echo "test_fx_audit: REARMIP: the NEW writer's shape (boot pair, then the activated version's own ip AND its verdict, one nonce) stays COHERENT with both attributions NAMED"

# REARMIP2 — THE FALSE-POSITIVE DIRECTION for the NOT-ALREADY-BOOTED clause:
# TWO activations in ONE boot give TWO re-arm in-progresses under ONE nonce,
# and NEITHER activated version has been booted — so the clause (which fires
# only on a version that already appeared as a boot's OWN first in-progress)
# must NOT fire.  A false positive here rolls back a HEALTHY machine, the
# costly direction; the multi-later-ip case is the one a too-broad clause
# would break.
mk_rearmip2() { # mk_rearmip2 NAME — two re-arm ips under one boot's nonce
    _n="$1"
    fresh "$_n"
    echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-$_n/.bootlog"
    echo "$CUR ok 111 $(nth 5)"          >> "$WORK/store-$_n/.bootlog"
    _i=0
    while [ "$_i" -lt 2 ]; do
        _a=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$WORK/store-$_n" \
                --package-set "$PS_A" --config "$WORK/cfg-store-a.dhall" 2>&1 \
                | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
        [ -n "$_a" ] || fail "mk_rearmip2 $_n: no version from activate $_i"
        [ "$_a" -gt "$CUR" ] || fail "mk_rearmip2 $_n: activate $_i did not ratchet ($_a <= $CUR)"
        materialize_rootfs "$WORK/store-$_n" "$WORK/rootfs-$_n" "$_a" "$PS_A"
        echo "$_a in-progress $((112 + _i * 2)) $(nth 5)" >> "$WORK/store-$_n/.bootlog"
        echo "$_a ok $((113 + _i * 2)) $(nth 5)"          >> "$WORK/store-$_n/.bootlog"
        _i=$((_i + 1))
    done
}
mk_rearmip2 rearmip2
FBOOTS=5 run_fixture rearmip2 > "$WORK/out.rearmip2" 2>&1
expect_coh "$WORK/out.rearmip2" $? "REARMIP2 (TWO activations in one boot: two re-arm in-progresses under ONE nonce, neither activated version booted — the NOT-ALREADY-BOOTED clause must not fire)"
grep -q 'INCOHERENT' "$WORK/out.rearmip2" \
    && fail "REARMIP2: a healthy TWO-activation boot was called incoherent (the NOT-ALREADY-BOOTED clause FALSE-POSITIVES): $(grep '^INCOHERENT' "$WORK/out.rearmip2")"
echo "test_fx_audit: REARMIP2: two activations in one boot (two re-arm ip lines, ONE nonce, neither version booted) stay COHERENT — the NOT-ALREADY-BOOTED clause does not false-positive"

# REARMIPFLIP — THE CRUX: the +1 first-published credit must NOT stack on a
# present re-arm ip.  A REAL re-arm ip plus ONE forged second verdict for
# the same version must still fire the per-version budget (allow = ip + 0);
# if the +1 stacks, allow = 2 and this forgery passes SILENTLY.
mk_rearmip rearmipflip
echo "$REARMIP_V ok 999 $(nth 5)" >> "$WORK/store-rearmipflip/.bootlog"
FBOOTS=5 run_fixture rearmipflip > "$WORK/out.rearmipflip" 2>&1
expect_incoh "$WORK/out.rearmipflip" $? "REARMIPFLIP (a real re-arm ip + a SECOND forged verdict for the version)" bootlog-fabricated-boots
grep -q "version $REARMIP_V carries 2 ADDED verdict line(s) this window but at most 1 can be behind them (1 in-progress line(s) for v$REARMIP_V, first published this window but its RE-ARM in-progress is PRESENT — the extra slot is NOT granted on top of it)" "$WORK/out.rearmipflip" \
    || fail "REARMIPFLIP: the budget finding does not state that the +1 does NOT stack on the re-arm ip: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.rearmipflip")"
echo "test_fx_audit: REARMIPFLIP: a real re-arm ip + one forged verdict fires the PER-VERSION budget — the +1 does NOT stack on a present re-arm ip"

# REARMIPFORGE — THE OTHER CRUX SIDE: a forged (ip + verdict) PAIR wearing a
# REAL window boot's nonce, for a version the store did NOT first publish in
# this window.  The pair is self-consistent (the forged verdict rides its
# own forged ip, so provenance alone passes it), which is exactly why the
# re-arm rule must fire on the IP.  A wrong predicate here (e.g. the
# "newer than the boot's own" test dropped) lets the motivating forge pass.
# The forged version is max+1 (the store's publish ratchet means REARMIP_V is
# the highest version it holds, so REARMIP_V+1 is absent from the store
# ENTIRELY): the ORDERING predicate is satisfied (it is greater than the
# version the boot booted), so this fixture isolates the FIRST-PUBLISHED
# predicate the way REARMIPOLDER isolates ordering.
mk_rearmip rearmipforge
RIPF_V=$((REARMIP_V + 1))
echo "$RIPF_V in-progress 998 $(nth 5)" >> "$WORK/store-rearmipforge/.bootlog"
echo "$RIPF_V ok 998 $(nth 5)"          >> "$WORK/store-rearmipforge/.bootlog"
FBOOTS=5 run_fixture rearmipforge > "$WORK/out.rearmipforge" 2>&1
expect_incoh "$WORK/out.rearmipforge" $? "REARMIPFORGE (a forged ip+verdict pair for a version NOT first published this window)" bootlog-fabricated-boots
grep -q "carries 3 in-progress line(s) in this window" "$WORK/out.rearmipforge" \
    || fail "REARMIPFORGE: the re-arm rule did not fire on the forged ip: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.rearmipforge")"
grep -q "is NOT a version the store first published in this window" "$WORK/out.rearmipforge" \
    || fail "REARMIPFORGE: the finding does not state WHY the ip cannot be a re-arm: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.rearmipforge")"
grep -q "is NOT greater than" "$WORK/out.rearmipforge" \
    && fail "REARMIPFORGE: the ORDERING predicate fired too — v$RIPF_V is greater than the booted version, so this fixture no longer ISOLATES first-published: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.rearmipforge")"
grep -q "the verdict that rides this line-pair is part of the same forge" "$WORK/out.rearmipforge" \
    || fail "REARMIPFORGE: the finding does not name the PAIR the forged ip vouches for"
echo "test_fx_audit: REARMIPFORGE: a forged ip+verdict pair for a version the store did NOT publish in the window (max+1, absent from the store) fires the re-arm rule on the FIRST-PUBLISHED predicate ALONE, and the finding names the pair"

# REARMIPOLDER — the SAME rule, the OTHER predicate: an ip that IS a
# first-published version of this window but NOT GREATER than the version
# the nonce's first ip named.  This is the direction that must never fire on
# a HEALTHY machine (the publish ratchet is max+1, so a real re-arm version
# always exceeds the booted one) — and it is the one a "different version"
# test in place of "greater version" would miss.  Built as the writer
# cannot: CURRENT=$VB (the boot's own), then an ip for the EARLIER $VA.
fresh rearmipolder
VA=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$WORK/store-rearmipolder" \
        --package-set "$PS_A" --config "$WORK/cfg-store-a.dhall" 2>&1 \
        | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
VB=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$WORK/store-rearmipolder" \
        --package-set "$PS_A" --config "$WORK/cfg-store-a.dhall" 2>&1 \
        | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$VA" ] && [ -n "$VB" ] && [ "$VB" -gt "$VA" ] || fail "REARMIPOLDER: the two activations did not ratchet ($VA -> $VB)"
materialize_rootfs "$WORK/store-rearmipolder" "$WORK/rootfs-rearmipolder" "$VB" "$PS_A"
echo "$VB in-progress 110 $(nth 5)" >> "$WORK/store-rearmipolder/.bootlog"
echo "$VA in-progress 111 $(nth 5)" >> "$WORK/store-rearmipolder/.bootlog"
FBOOTS=5 run_fixture rearmipolder > "$WORK/out.rearmipolder" 2>&1
expect_incoh "$WORK/out.rearmipolder" $? "REARMIPOLDER (a re-arm ip older than the nonce's own first ip)" bootlog-fabricated-boots
grep -q "is NOT greater than v$VB, the version that nonce's first in-progress named" "$WORK/out.rearmipolder" \
    || fail "REARMIPOLDER: the finding does not state the ORDERING it violated: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.rearmipolder")"
echo "test_fx_audit: REARMIPOLDER: a first-published ip that is NOT newer than the nonce's own first ip fires the same rule (the ordering predicate is the load-bearing half)"

# ── REARMIPX — THE CROSS-NONCE FLIP (the review's BLOCKER): the re-arm
# budget is ONE per first-published VERSION per WINDOW, never one per
# (nonce, version).  With TWO real window nonces a forger takes the version
# the LIVE boot activated (X: first-published in this window and, by the
# publish ratchet, newer than every earlier boot's own version too) and
# appends an in-progress+verdict PAIR for it riding an EARLIER window
# boot's nonce.  Keyed per (nonce, version) that pair IS a legitimate
# re-arm: X is first-published and X is newer than that nonce's first ip —
# so ip(X) and vd(X) both rise to 2 and the per-version verdict budget
# allows 2.  The result is a SECOND verdict for a version the window
# already verdicted (the flip), which the PRE-RE-ARM reader closed (one
# in-progress per nonce) and a per-(nonce, version) rule silently reopens.
# FAILS (goes coherent) unless the duplicate is keyed on the VERSION alone.
# The pinned pre-change reader's half of this asymmetry is BEFORE-E below.
fresh rearmipx
echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-rearmipx/.bootlog"
echo "$CUR failed 111 $(nth 5)"      >> "$WORK/store-rearmipx/.bootlog"
FXSTORE_BIN="$FXSTORE" "$FXSTORE" rollback "$V1" --store "$WORK/store-rearmipx" >/dev/null 2>&1 \
    || fail "REARMIPX: fxstore rollback (the roll-forward republish) failed"
RIPX_REW=$(cur_of "$WORK/store-rearmipx")
[ -n "$RIPX_REW" ] && [ "$RIPX_REW" -gt "$CUR" ] || fail "REARMIPX: the roll-forward did not republish above $CUR (got $RIPX_REW)"
RIPX_GHW=$(genhash_of "$WORK/store-rearmipx" "$RIPX_REW")
echo "113 $RIPX_REW $CUR $RIPX_GHW $(nth 6)" >> "$WORK/store-rearmipx/.recovery"
materialize_rootfs "$WORK/store-rearmipx" "$WORK/rootfs-rearmipx" "$RIPX_REW" "$PS_A"
echo "$RIPX_REW in-progress 112 $(nth 6)" >> "$WORK/store-rearmipx/.bootlog"
echo "$RIPX_REW ok 113 $(nth 6)"          >> "$WORK/store-rearmipx/.bootlog"
RIPX_V=$(LD_LIBRARY_PATH="$DL" "$ZB/fx-activate" --store "$WORK/store-rearmipx" \
        --package-set "$PS_A" --config "$WORK/cfg-store-a.dhall" 2>&1 \
        | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$RIPX_V" ] && [ "$RIPX_V" -gt "$RIPX_REW" ] || fail "REARMIPX: no ratcheted activate above $RIPX_REW (got $RIPX_V)"
materialize_rootfs "$WORK/store-rearmipx" "$WORK/rootfs-rearmipx" "$RIPX_V" "$PS_A"
echo "$RIPX_V in-progress 114 $(nth 6)" >> "$WORK/store-rearmipx/.bootlog"
echo "$RIPX_V failed 115 $(nth 6)"      >> "$WORK/store-rearmipx/.bootlog"
echo "$RIPX_V in-progress 116 $(nth 5)" >> "$WORK/store-rearmipx/.bootlog"
echo "$RIPX_V ok 117 $(nth 5)"          >> "$WORK/store-rearmipx/.bootlog"
FBOOTS=6 run_fixture rearmipx > "$WORK/out.rearmipx" 2>&1
expect_incoh "$WORK/out.rearmipx" $? "REARMIPX (a forged pair for the activated version riding a SECOND real window nonce — the cross-nonce flip)" bootlog-fabricated-boots
grep -q "a SECOND in-progress for v$RIPX_V in this window" "$WORK/out.rearmipx" \
    || fail "REARMIPX: the finding does not state the per-version-per-window cap: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.rearmipx")"
echo "test_fx_audit: REARMIPX: a forged pair for the ACTIVATED version riding a SECOND real window nonce fires the per-version-per-window ip cap — the cross-nonce flip a per-(nonce, version) rule admits"

# ── REARMIPREPUB — THE ROLL-FORWARD REPUBLISH SHAPE (the round-2 BLOCKER):
# a version the STORE first published WITHOUT an activation — the roll-forward
# republish W (fxstore rollback, the same call decide_boot_version drives) —
# and then BOOTED in the window has NO legitimate later ip anywhere (its only
# in-progress is its own boot's first).  A forged "<W> in-progress Nth>" +
# "<W> ok Nth>" pair riding an EARLIER real window boot's nonce then passes
# the version-keyed dup (W is not in seen_ip: it never had a real re-arm),
# the first-published predicate (W IS first published) and the ordering
# predicate (W > that boot's own, the ratchet) — so round 2's reader read it
# as a legitimate re-arm and its verdict budget (ip=2, vd=2) passed a SECOND
# verdict for a version the window already verdicted.  The fix is the
# NOT-ALREADY-BOOTED clause: a re-arm names the version the activate JUST
# published (max+1), which has never been booted, so a later ip for W — whose
# OWN first in-progress (boot 6's) already appeared — is refused.  FAILS
# (goes coherent) unless that clause is checked.
fresh rearmiprepub
echo "$CUR in-progress 110 $(nth 5)" >> "$WORK/store-rearmiprepub/.bootlog"
echo "$CUR failed 111 $(nth 5)"      >> "$WORK/store-rearmiprepub/.bootlog"
FXSTORE_BIN="$FXSTORE" "$FXSTORE" rollback "$V1" --store "$WORK/store-rearmiprepub" >/dev/null 2>&1 \
    || fail "REARMIPREPUB: fxstore rollback (the roll-forward republish) failed"
RIPR_W=$(cur_of "$WORK/store-rearmiprepub")
[ -n "$RIPR_W" ] && [ "$RIPR_W" -gt "$CUR" ] || fail "REARMIPREPUB: the roll-forward did not republish above $CUR (got $RIPR_W)"
RIPR_GHW=$(genhash_of "$WORK/store-rearmiprepub" "$RIPR_W")
echo "113 $RIPR_W $CUR $RIPR_GHW $(nth 6)" >> "$WORK/store-rearmiprepub/.recovery"
materialize_rootfs "$WORK/store-rearmiprepub" "$WORK/rootfs-rearmiprepub" "$RIPR_W" "$PS_A"
echo "$RIPR_W in-progress 112 $(nth 6)" >> "$WORK/store-rearmiprepub/.bootlog"
echo "$RIPR_W ok 113 $(nth 6)"          >> "$WORK/store-rearmiprepub/.bootlog"
# THE FORGE: a pair for the REPUBLISHED (never activated) version, riding the
# EARLIER boot's nonce — no activation ever wrote a re-arm ip for W.
echo "$RIPR_W in-progress 114 $(nth 5)" >> "$WORK/store-rearmiprepub/.bootlog"
echo "$RIPR_W ok 115 $(nth 5)"          >> "$WORK/store-rearmiprepub/.bootlog"
FBOOTS=6 run_fixture rearmiprepub > "$WORK/out.rearmiprepub" 2>&1
expect_incoh "$WORK/out.rearmiprepub" $? "REARMIPREPUB (a forged pair for the REPUBLISHED version riding an earlier real nonce — the roll-forward republish shape)" bootlog-fabricated-boots
grep -q "was ALREADY BOOTED in this window" "$WORK/out.rearmiprepub" \
    || fail "REARMIPREPUB: the finding does not state the not-already-booted predicate: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.rearmiprepub")"
echo "test_fx_audit: REARMIPREPUB: a forged pair for a version the store first published WITHOUT an activation (the roll-forward republish) and then BOOTED fires the not-already-booted re-arm predicate — the republish shape"

# ══ MIXED: one nonced boot + one operator hand-boot is information only ══
# The regime a real deployment hits by accident: the host nonced boot 4 but
# boot 5 was an operator hand-boot (no fx.bootnonce= — the writer stamps
# its 'none' placeholder on every line that boot appends).  The ledger
# honestly declares it by covering 4 of the 5 boots.  This window must
# audit COHERENT with BOTH regime lines printed — a hand boot must never
# roll a healthy machine back, and the uncovered boot must never silently
# pass as nonce-accounted.  FAILS if the unbound info ever becomes a
# finding (every hand boot = a rollback) or either regime line is dropped.
mk_norec mixed
echo "$V1 in-progress 106 $(nth 4)" >> "$WORK/store-mixed/.bootlog"
echo "$V1 ok 107 $(nth 4)"          >> "$WORK/store-mixed/.bootlog"
echo "$V1 in-progress 108 none"     >> "$WORK/store-mixed/.bootlog"
echo "$V1 ok 109 none"              >> "$WORK/store-mixed/.bootlog"
mkled "$WORK/nonces-mixed.led" 4
FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$WORK/store-mixed" \
    --rootfs "$WORK/rootfs-mixed" --obs-file "$WORK/obsf-mixed.obs" \
    --boots 5 --nonces "$WORK/nonces-mixed.led" > "$WORK/out.mixed" 2>&1
expect_coh "$WORK/out.mixed" $? "MIXED (a nonced boot + a healthy operator hand-boot)"
grep -q 'INCOHERENT' "$WORK/out.mixed" \
    && fail "MIXED: a healthy hand-boot window was called incoherent: $(grep '^INCOHERENT' "$WORK/out.mixed")"
grep -q "2 ADDED .bootlog line(s) carry no nonce the host issued for a boot in this window (first: '$V1 in-progress 108 none') — the ledger covers 1 of the 2 window boot(s): a MIXED/MANUAL regime" "$WORK/out.mixed" \
    || fail "MIXED: the hand-boot lines are not NAMED with the regime: $(grep 'MIXED' "$WORK/out.mixed")"
grep -q 'the pair-forgery closure holds only for the covered boots' "$WORK/out.mixed" \
    || fail "MIXED: the window summary does not state the closure's extent: $(grep 'pair-forgery closure' "$WORK/out.mixed")"
grep -q 'boot accounting: host boots 3 -> 5 (delta 2); this window added in-progress 2, verdicts 2, shutdown 0' "$WORK/out.mixed" \
    || fail "MIXED: both boots were not counted by the arithmetic: $(grep 'boot accounting: host boots' "$WORK/out.mixed")"
echo "test_fx_audit: MIXED: one nonced boot + one healthy hand-boot ('none' lines, ledger 4 of 5) audits COHERENT, both regime lines printed, the uncovered boot named — never a rollback"

# ══ SUBST: the named hole — a substituted verdict audits coherent ═══════
# The one form the corrected accounting still cannot see: the agent (root
# in the guest) reads its own /proc/cmdline nonce, appends the verdict
# ITSELF in the writer's exact shape wearing that nonce, and suppresses
# fx-init's own verdict (a panic before grace expiry).  One verdict for one
# (nonce, version), every anchor satisfied — indistinguishable from the
# healthy bytes.  The seat's contract in that direction is HONESTY, not
# closure: the arm asserts the shape still audits coherent (over-tightening
# it would false-positive every real boot) AND that the printed bound NAMES
# the substitution, so no future reader mistakes the pair closure for
# authorship verification.
mk_norec subst
echo "$V1 in-progress 106 $(nth 4)" >> "$WORK/store-subst/.bootlog"
echo "$V1 ok 107 $(nth 4)"          >> "$WORK/store-subst/.bootlog"
FBOOTS=4 run_fixture subst > "$WORK/out.subst" 2>&1
expect_coh "$WORK/out.subst" $? "SUBST (a substituted verdict is byte-identical to the writer's own)"
grep -q 'boot accounting: host boots 3 -> 4 (delta 1); this window added in-progress 1, verdicts 1, shutdown 0' "$WORK/out.subst" \
    || fail "SUBST: the fixture is not the one-verdict shape the hole lives in: $(grep 'boot accounting: host boots' "$WORK/out.subst")"
grep -q 'a verdict SUBSTITUTED inside a LIVE boot' "$WORK/out.subst" \
    || fail "SUBST: the printed bound does not NAME the substitution hole — the tool claims more than it knows: $(sed -n '/^bound:/p' "$WORK/out.subst" | head -c 300)"
grep -q "authorship inside the boot that owns the nonce is NOT distinguishable" "$WORK/out.subst" \
    || fail "SUBST: the bound does not say WHY the hole cannot close from the host"
echo "test_fx_audit: SUBST: a verdict substituted inside a live boot audits coherent (measured, unavoidable — the nonce is readable in-guest) and the printed bound NAMES the hole"

# ══ BEFORE: the fail-before, on PINNED pre-change revisions ═════════════
# The asymmetry a regression probe needs: on the pinned trees the SAME
# forgeries went COHERENT.  Every pin is guarded (git cat-file -e) and
# PROVEN DIFFERENT from the working tree (cmp) — a control that equals its
# subject proves nothing, and this repo has shipped both a red gate (a
# moving ref) and a vacuous one (a pin compared to itself).  Nothing here
# reads HEAD: every pin is a fixed object name.
# pin_build REV OUTFILE — the audit source at REV, built, with the DOMAIN
# proof (exists; DIFFERS from the working tree).
pin_build() {
    _rev="$1"; _out="$2"
    git -C "$REPO" cat-file -e "$_rev^{commit}" 2>/dev/null \
        || fail "PIN $_rev: the pinned revision does not exist (the control needs it)"
    git -C "$REPO" show "$_rev:tools/fx-audit.c" > "$_out.c" \
        || fail "PIN $_rev: cannot extract tools/fx-audit.c at $_rev"
    cmp -s "$_out.c" "$REPO/tools/fx-audit.c" \
        && fail "PIN $_rev: the pinned source is IDENTICAL to the working tree — the control equals its subject and proves nothing"
    cc -std=c11 -O2 -Wall -Wextra -I"$REPO/src/vendor/dhall-c" \
       -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
       -o "$_out" "$_out.c" "$REPO/src/vendor/dhall-c/sha256.c" \
        || fail "PIN $_rev: cannot build the pinned fx-audit"
}
pin_build 030fbdc "$WORK/fx-audit-pinned"
pin_build 88a73b8 "$WORK/fx-audit-nonce-pin"
pin_build fcebaa3 "$WORK/fx-audit-prefix"
# ── BEFORE-D (bd3c5cf, the PRE-RE-ARM accounting): the fail-before of THIS
# unit's accounting change, on the SAME fixture the new arms call COHERENT.
# The pre-change reader budgets in-progress lines at ONE per nonce and
# budgets the verdicts per version with an unconditional +1 for a
# first-published version, so the NEW writer's healthy shape (the activated
# version's own ip AND its verdict in one boot) is exactly what it calls a
# forgery: "carries 2 in-progress line(s) in this window".  That is the
# measured false positive the change closes — pass-after is the same
# fixture's coherent REARMIP run above.
pin_build bd3c5cf "$WORK/fx-audit-prev"
# pin_blob_build BLOB OUTFILE — the same discipline for a source measured
# against an UNCOMMITTED tree (this round's pre-fix reader): the pin is the
# file's BLOB object name (git hash-object -w), stable across the later
# commit — the committed tree stores the same blob — guarded, and cmp-PROVEN
# different from the working tree.
pin_blob_build() {
    _blob="$1"; _out="$2"
    [ "$(git -C "$REPO" cat-file -t "$_blob" 2>/dev/null)" = "blob" ] \
        || fail "PINBLOB $_blob: not a blob in $REPO's object db (the control needs it — hash-object -w the measured file)"
    git -C "$REPO" cat-file blob "$_blob" > "$_out.c" \
        || fail "PINBLOB $_blob: cannot extract the pinned source"
    cmp -s "$_out.c" "$REPO/tools/fx-audit.c" \
        && fail "PINBLOB $_blob: the pinned source is IDENTICAL to the working tree — the control equals its subject and proves nothing"
    cc -std=c11 -O2 -Wall -Wextra -I"$REPO/src/vendor/dhall-c" \
       -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
       -o "$_out" "$_out.c" "$REPO/src/vendor/dhall-c/sha256.c" \
        || fail "PINBLOB $_blob: cannot build the pinned fx-audit"
}

# ── THE WRITER PIN (fx-init 500fc68): the fail-before of the WRITER half ──
# The pre-nonce writer cannot stamp a nonce: its bootlog_append is the
# 3-field "%u %s %u" and its command line knows no fx.bootnonce.  Pinned by
# object name, guarded, and cmp-PROVEN different from the working tree's
# init.zig.  SOURCE-LEVEL, stated as such: the writer's behavioural proof
# lives in fx-init's zig tests (bootlog_append/recovery_line format) and in
# the REAL-GUEST demonstration (qemu-agent-observe.sh: the guest's own
# .bootlog lines carry the host-issued nonces).
PIN_INIT=500fc68
git -C "$INIT" cat-file -e "$PIN_INIT^{commit}" 2>/dev/null \
    || fail "WRITER PIN $PIN_INIT: the pinned fx-init revision does not exist (shallow clone?)"
git -C "$INIT" show "$PIN_INIT:zig/src/init.zig" > "$WORK/init-pinned.zig" \
    || fail "WRITER PIN $PIN_INIT: cannot extract zig/src/init.zig"
cmp -s "$WORK/init-pinned.zig" "$INIT/zig/src/init.zig" \
    && fail "WRITER PIN $PIN_INIT: the pinned init.zig is IDENTICAL to the working tree — the control would not be a pre-nonce artifact (pin wrong or the writer change missing)"
grep -q 'fx.bootnonce' "$WORK/init-pinned.zig" \
    && fail "WRITER PIN $PIN_INIT: the pinned writer already knows fx.bootnonce — the pin is not pre-nonce"
grep -q 'fx.bootnonce' "$INIT/zig/src/init.zig" \
    || fail "WRITER PIN: the working tree's init.zig has no fx.bootnonce — the writer change is missing from the tree under test"
grep -q 'fprintf(f, "%u %s %u\\n", v, status, epoch)' "$WORK/init-pinned.zig" \
    || fail "WRITER PIN $PIN_INIT: the pinned bootlog_append is not the 3-field shape the reader's old grammar expects"
grep -q 'fprintf(f, "%u %s %u %s\\n", v, status, epoch, boot_nonce_str())' "$INIT/zig/src/init.zig" \
    || fail "WRITER PIN: the working tree's bootlog_append does not write the 4th nonce field"
echo "test_fx_audit: WRITER PIN: fx-init at $PIN_INIT writes the 3-field line (no fx.bootnonce anywhere); the working tree writes the 4-field nonce line (cmp-proven different)"

# ── BEFORE-A (030fbdc, the pre---boots era): the ORIGINAL bare-verdict forge
# passed; the new tool refuses its format-1 observation.
NOREC_OLD=1 mk_norec before
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-pinned" --store "$WORK/store-before" \
    --rootfs "$WORK/rootfs-before" --obs-file "$WORK/obsf-before-pinned.obs" \
    > "$WORK/out.bp1" 2>&1
expect_coh "$WORK/out.bp1" $? "BEFORE-A enroll (pinned 030fbdc, pre-nonce 3-field lines)"
echo "$V2 ok 999" >> "$WORK/store-before/.bootlog"
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-pinned" --store "$WORK/store-before" \
    --rootfs "$WORK/rootfs-before" --obs-file "$WORK/obsf-before-pinned.obs" \
    > "$WORK/out.bp2" 2>&1
expect_coh "$WORK/out.bp2" $? "BEFORE-A the bare forged verdict goes COHERENT on 030fbdc (the original measured hole)"
grep -q 'append-only respected' "$WORK/out.bp2" \
    || fail "BEFORE-A: the pinned tool did not even see the append (the fixture is wrong)"
# the fail-after on the SAME tampered store: the new tool against its OWN
# enrollment of the same pre-forge state
FBOOTS=3 run_fixture before > "$WORK/out.bp2new" 2>&1
expect_incoh "$WORK/out.bp2new" $? "BEFORE-A/AFTER on the same store" bootlog-forged-verdict
# and the new tool REFUSES the pinned tool's format-1 observation: a
# baseline with no boot count cannot anchor growth, and assuming one is
# the silent default this seat refuses
FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$WORK/store-before" \
    --rootfs "$WORK/rootfs-before" --obs-file "$WORK/obsf-before-pinned.obs" --boots 3 \
    > "$WORK/out.bp3" 2>&1
_rc=$?
[ "$_rc" = "2" ] || fail "BEFORE-A: the new tool must refuse a format-1 observation (exit 2), got $_rc"
grep -q 'FORMAT 1' "$WORK/out.bp3" \
    || fail "BEFORE-A: the refusal does not name the format-1 baseline"
grep -q 're-enroll' "$WORK/out.bp3" \
    || fail "BEFORE-A: the refusal does not name the way out"
echo "test_fx_audit: BEFORE-A: on the pinned 030fbdc the SAME appended '$V2 ok 999' audits COHERENT (exit 0); the new tool fires on the same store and REFUSES the pinned tool's format-1 observation"

# ── BEFORE-B (88a73b8, the pre-NONCE reader): THE PAIR FORGERY, the
# reviewer-constructed hole this change closes.  The pinned reader KNOWS
# --boots and its observation is format 2, but it has no nonce binding: on
# the OLD-WRITER store (the only shape it can read coherently — a 4-field
# line is damaged to it) the forged PAIR into a silent boot's slack passes
# its count AND its attribution.  The new tool, on the SAME store and the
# SAME pair bytes, fires.
NOREC_OLD=1 mk_norec pairpin
# the pinned tool enrolls the pre-pair state (its own observation file)
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-nonce-pin" --store "$WORK/store-pairpin" \
    --rootfs "$WORK/rootfs-pairpin" --obs-file "$WORK/obsf-pairpin-old.obs" --boots 3 \
    > "$WORK/out.pp1" 2>&1
expect_coh "$WORK/out.pp1" $? "BEFORE-B enroll (pinned 88a73b8, pre-nonce 3-field lines)"
# the new tool ALSO enrolls the same pre-pair state under its own format-3
# baseline (its observation is taken from the same bytes)
FBOOTS=3 run_fixture pairpin > "$WORK/out.pp1new" 2>&1
expect_coh "$WORK/out.pp1new" $? "BEFORE-B new-tool enroll (same store, same bytes)"
# THE FORGED PAIR (the reviewer's exact shape: in-progress + verdict, the
# writer's old 3-field grammar, appended into boot 4's silent slack)
echo "$V2 in-progress 999" >> "$WORK/store-pairpin/.bootlog"
echo "$V2 ok 999" >> "$WORK/store-pairpin/.bootlog"
# ...the pinned reader calls it COHERENT (the measured hole)
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-nonce-pin" --store "$WORK/store-pairpin" \
    --rootfs "$WORK/rootfs-pairpin" --obs-file "$WORK/obsf-pairpin-old.obs" --boots 4 \
    > "$WORK/out.pp2" 2>&1
expect_coh "$WORK/out.pp2" $? "BEFORE-B THE PAIR GOES COHERENT on the pinned pre-nonce reader (the hole this change closes)"
grep -q 'boot accounting: host boots 3 -> 4 (delta 1); this window added in-progress 1, verdicts 1, shutdown 0' "$WORK/out.pp2" \
    || fail "BEFORE-B: the pinned tool did not account the pair as an ordinary boot (fixture wrong): $(grep 'boot accounting' "$WORK/out.pp2")"
# ...the new tool, same store, same pair bytes, fires
FBOOTS=4 run_fixture pairpin > "$WORK/out.pp3" 2>&1
expect_incoh "$WORK/out.pp3" $? "BEFORE-B/AFTER on the same store and the same pair bytes" bootlog-unbound-nonce
grep -q '2 ADDED .bootlog line(s) carry no nonce the host issued' "$WORK/out.pp3" \
    || fail "BEFORE-B/AFTER: the new tool did not name both forged lines: $(grep '^INCOHERENT bootlog-unbound' "$WORK/out.pp3")"
echo "test_fx_audit: BEFORE-B: on the pinned 88a73b8 the forged PAIR into the silent boot's slack audits COHERENT (delta 1, attribution satisfied — the reviewer's measurement); the new tool fires bootlog-unbound-nonce on the SAME store and pair bytes"

# ── BEFORE-C (be2fbd1, the per-NONCE-verdict reader): THE BLOCKER, pinned.
# The revision this change fixes called the HEALTHY re-arm boot a forgery:
# its per-nonce verdict budget ("the nonce ... carries 2 verdict line(s)")
# and its version-exact in-progress attribution BOTH fire on one boot, one
# nonce, the activate re-arm's legitimate second verdict — exit 1, a healthy
# machine audited into a rollback (the review's measured BLOCKER, and
# fx-init's own suite documents the writer path, tests/qemu_boot_rollback.
# sh:18-27).  The pinned tool must REJECT this store; the working tree's
# tool must audit the SAME store and bytes COHERENT — the fail-before of a
# false-positive fix, the asymmetry that proves it.
pin_build be2fbd1 "$WORK/fx-audit-pernonce-pin"
mk_rearm beforec
mkled "$WORK/nonces-beforec.led" 5
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-pernonce-pin" --store "$WORK/store-beforec" \
    --rootfs "$WORK/rootfs-beforec" --obs-file "$WORK/obsf-beforec.obs" --boots 5 \
    --nonces "$WORK/nonces-beforec.led" > "$WORK/out.bc1" 2>&1
expect_incoh "$WORK/out.bc1" $? "BEFORE-C the healthy re-arm boot goes INCOHERENT on the pinned per-nonce-budget reader (the BLOCKER, fail-before)" \
    bootlog-fabricated-boots bootlog-forged-verdict
grep -q "carries 2 verdict line(s) — the g_boot_decided latch allows at most one verdict per boot" "$WORK/out.bc1" \
    || fail "BEFORE-C: the pinned run did not make the refuted per-nonce-budget claim: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.bc1")"
grep -q "'$REARM_V failed 112' line has no '$REARM_V in-progress' line earlier in this window" "$WORK/out.bc1" \
    || fail "BEFORE-C: the pinned run did not also fire the version-exact attribution on the re-arm verdict: $(grep '^INCOHERENT bootlog-forged' "$WORK/out.bc1")"
# the same store, the same bytes, the WORKING tree's tool: coherent
FBOOTS=5 run_fixture beforec > "$WORK/out.bc2" 2>&1
expect_coh "$WORK/out.bc2" $? "BEFORE-C/AFTER on the same store and the same bytes"
echo "test_fx_audit: BEFORE-C: on the pinned be2fbd1 the healthy re-arm boot (one nonce, the activate's second verdict) is REJECTED with the refuted per-nonce budget AND the version-exact attribution; the working tree audits the SAME store and bytes COHERENT (the BLOCKER's asymmetry)"

# ── BEFORE-D/AFTER (bd3c5cf, the PRE-re-arm accounting): THIS unit's
# fail-before/pass-after, on ONE fixture and ONE byte sequence.  The pinned
# pre-change reader has no re-arm line in its writer model, so the NEW
# writer's healthy shape (the activated version's own ip AND its verdict,
# same boot, same nonce) trips its per-nonce in-progress budget: "carries 2
# in-progress line(s) in this window".  The working tree's tool audits the
# SAME store and bytes COHERENT (the REARMIP arm above) — and the SAME new
# rule still fires on the forge (REARMIPFORGE / REARMIPOLDER), so this is
# not a loosening.
cp "$AOBSFILE" "$WORK/obs-rearmip-before.obs"
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-prev" --store "$WORK/store-rearmip" \
    --rootfs "$WORK/rootfs-rearmip" --obs-file "$WORK/obs-rearmip-before.obs" \
    --boots 5 --nonces "$WORK/nonces-rearmip.led" > "$WORK/out.rearmip-before" 2>&1
expect_incoh "$WORK/out.rearmip-before" $? "BEFORE-D the healthy NEW-writer re-arm boot goes INCOHERENT on the pinned pre-re-arm accounting (fail-before)" \
    bootlog-fabricated-boots
grep -q "carries 2 in-progress line(s) in this window" "$WORK/out.rearmip-before" \
    || fail "BEFORE-D: the pinned run did not make the ONE-per-nonce in-progress claim: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.rearmip-before")"
echo "test_fx_audit: BEFORE-D: on the pinned bd3c5cf the healthy NEW-writer re-arm boot is REJECTED by the one-in-progress-per-nonce budget; the working tree audits the SAME store and bytes COHERENT (REARMIP)"

# ── BEFORE-E/AFTER (the CROSS-NONCE FLIP, two pins): the fail-before of the
# per-version-per-window cap, on the REARMIPX fixture and ONE byte sequence.
#  (1) the pre-re-arm reader (bd3c5cf, the pin BEFORE-D builds) CLOSED this
#      forgery through its ONE-per-nonce in-progress budget;
#  (2) the reader THIS round fixes — a per-(nonce, version) re-arm
#      classification — re-opened it: its pinned BLOB object audits the same
#      store and the same bytes COHERENT, naming the forged pair as a
#      legitimate re-arm.  That blob is the uncommitted-tree pin
#      (git hash-object -w tools/fx-audit.c before the fix), stable across
#      the later commit.
# The working tree's reader FIRES on the same store (REARMIPX above): the
# asymmetry, and the capability the round-1 rule silently re-opened.
cp "$AOBSFILE" "$WORK/obs-rearmipx-pre.obs"
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-prev" --store "$WORK/store-rearmipx" \
    --rootfs "$WORK/rootfs-rearmipx" --obs-file "$WORK/obs-rearmipx-pre.obs" \
    --boots 6 --nonces "$WORK/nonces-rearmipx.led" > "$WORK/out.rearmipx-pre" 2>&1
expect_incoh "$WORK/out.rearmipx-pre" $? "BEFORE-E the PRE-re-arm reader on the cross-nonce forgery (the closure the round-1 rule re-opened)" \
    bootlog-fabricated-boots
grep -q "carries 2 in-progress line(s) in this window" "$WORK/out.rearmipx-pre" \
    || fail "BEFORE-E: the pre-re-arm pin did not fire its one-per-nonce budget: $(grep '^INCOHERENT bootlog-fabricated' "$WORK/out.rearmipx-pre")"
pin_blob_build 4e4976cc1d948f6882be6168ee6f2398d2c5806b "$WORK/fx-audit-r1pin"
cp "$AOBSFILE" "$WORK/obs-rearmipx-r1.obs"
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-r1pin" --store "$WORK/store-rearmipx" \
    --rootfs "$WORK/rootfs-rearmipx" --obs-file "$WORK/obs-rearmipx-r1.obs" \
    --boots 6 --nonces "$WORK/nonces-rearmipx.led" > "$WORK/out.rearmipx-r1" 2>&1
expect_coh "$WORK/out.rearmipx-r1" $? "BEFORE-E the ROUND-1 (per-(nonce,version)) pinned reader on the cross-nonce forgery — the hole"
grep -q "carries a RE-ARM in-progress for v$RIPX_V" "$WORK/out.rearmipx-r1" \
    || fail "BEFORE-E: the pinned round-1 reader did not NAME the FORGED pair as a legitimate re-arm (the fixture is not the shape it has): $(grep -i 'RE-ARM' "$WORK/out.rearmipx-r1")"
grep -q "^INCOHERENT" "$WORK/out.rearmipx-r1" \
    && fail "BEFORE-E: the pinned round-1 reader fired — the pin is not the reader that has the hole: $(grep '^INCOHERENT' "$WORK/out.rearmipx-r1")"
echo "test_fx_audit: BEFORE-E: the cross-nonce forgery is CLOSED by the pinned PRE-re-arm reader (bd3c5cf, one in-progress per nonce) and audits COHERENT on the pinned round-1 reader (its per-(nonce,version) re-arm classification reads the forged pair as legitimate); the working tree's reader FIRES the same store and bytes (REARMIPX) — the re-opened capability, pinned"

# ── BEFORE-F/AFTER (the ROLL-FORWARD REPUBLISH shape, round 3's blocker):
# the fail-before of the NOT-ALREADY-BOOTED re-arm clause, on the
# REARMIPREPUB fixture and ONE byte sequence.  The pinned reader THIS round
# fixes — the round-2 version-keyed cap (the uncommitted-tree BLOB pin,
# hash-object -w of tools/fx-audit.c at the end of round 2) — passes the
# republish forge: W is first-published, newer than boot 5's own, and NOT in
# seen_ip (no activation ever wrote a re-arm for it), so its per-nonce rule
# reads the forged pair as a legitimate re-arm and the verdict budget
# (ip=2, vd=2) passes a SECOND verdict for an already-verdicted version.
# The working tree's reader FIRES on the same store (REARMIPREPUB above):
# the asymmetry, and the shape the round-2 cap does not close.
pin_blob_build 5125d206 "$WORK/fx-audit-r2pin"
cp "$AOBSFILE" "$WORK/obs-rearmiprepub-r2.obs"
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-r2pin" --store "$WORK/store-rearmiprepub" \
    --rootfs "$WORK/rootfs-rearmiprepub" --obs-file "$WORK/obs-rearmiprepub-r2.obs" \
    --boots 6 --nonces "$WORK/nonces-rearmiprepub.led" > "$WORK/out.rearmiprepub-r2" 2>&1
expect_coh "$WORK/out.rearmiprepub-r2" $? "BEFORE-F the ROUND-2 pinned reader on the republish forge — the hole"
grep -q "carries a RE-ARM in-progress for v$RIPR_W" "$WORK/out.rearmiprepub-r2" \
    || fail "BEFORE-F: the pinned round-2 reader did not NAME the forged pair as a legitimate re-arm (the fixture is not the shape it has): $(grep -i 'RE-ARM' "$WORK/out.rearmiprepub-r2")"
grep -q "^INCOHERENT" "$WORK/out.rearmiprepub-r2" \
    && fail "BEFORE-F: the pinned round-2 reader fired — the pin is not the reader that has the hole: $(grep '^INCOHERENT' "$WORK/out.rearmiprepub-r2")"
echo "test_fx_audit: BEFORE-F: the republish forge audits COHERENT on the pinned round-2 reader (its version-keyed cap never sees the republished version — no activation wrote a re-arm for it) and the working tree's reader FIRES the same store and bytes (REARMIPREPUB) — the republish shape, pinned"

# ── FORMAT2: the new tool refuses the pinned tool's format-2 observation —
# a pre-nonce baseline cannot anchor a nonce-judged window, and assuming it
# could is the silent default this seat refuses (the format-1 rule, again).
FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$WORK/store-pairpin" \
    --rootfs "$WORK/rootfs-pairpin" --obs-file "$WORK/obsf-pairpin-old.obs" --boots 4 \
    --nonces "$WORK/nonces-pairpin.led" \
    > "$WORK/out.fmt2" 2>&1
_rc=$?
[ "$_rc" = "2" ] || fail "FORMAT2: the new tool must refuse a format-2 observation (exit 2), got $_rc: $(sed -n 1,3p "$WORK/out.fmt2")"
grep -q 'FORMAT 2' "$WORK/out.fmt2" \
    || fail "FORMAT2: the refusal does not name the format-2 baseline"
grep -q 're-enroll' "$WORK/out.fmt2" \
    || fail "FORMAT2: the refusal does not name the way out"
echo "test_fx_audit: FORMAT2: a pre-nonce (format-2) observation is REFUSED with a re-enroll instruction — never silently assumed"

# ── TORNLEGIT-BEFORE (fcebaa3): the FALSE POSITIVE that would roll back a
# healthy machine, pinned at the revision before the torn-attribution fix.
# The PRE-FIX tool REJECTS a healthy crashed boot on the torn shape — exit
# 1 bootlog-forged-verdict — while the SAME run's accounting line prints
# the in-progress its message claims is absent: it both false-positives
# and mis-reasons.  Runs on the OLD-shape fixture (the pinned tools cannot
# read nonce lines); the WORKING TREE's torn acceptance is TORNLEGIT above
# (nonce lines, cut mid-nonce).  The fix itself is pinned across two
# readers: fcebaa3 rejects, 88a73b8 accepts the SAME store and the SAME
# observation file, so the only variable is the tool.
NOREC_OLD=1 mk_norec tpin
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-prefix" --store "$WORK/store-tpin" \
    --rootfs "$WORK/rootfs-tpin" --obs-file "$WORK/obsf-tpin-prefix.obs" --boots 3 \
    > "$WORK/out.tpin1" 2>&1
expect_coh "$WORK/out.tpin1" $? "TORNLEGIT-BEFORE enroll (pre-fix fcebaa3)"
echo "$V1 in-progress 106" >> "$WORK/store-tpin/.bootlog"
printf '%s' "$V1 ok 107" >> "$WORK/store-tpin/.bootlog"
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-prefix" --store "$WORK/store-tpin" \
    --rootfs "$WORK/rootfs-tpin" --obs-file "$WORK/obsf-tpin-prefix.obs" --boots 4 \
    > "$WORK/out.tpin2" 2>&1
expect_incoh "$WORK/out.tpin2" $? "TORNLEGIT-BEFORE (the pre-fix tool on a healthy crashed boot)" bootlog-forged-verdict
grep -q 'no in-progress behind it in this window' "$WORK/out.tpin2" \
    || fail "TORNLEGIT-BEFORE: the pre-fix run did not make the claim this arm pins: $(grep '^INCOHERENT bootlog-forged' "$WORK/out.tpin2")"
grep -q 'this window added in-progress 1, verdicts 1, shutdown 0' "$WORK/out.tpin2" \
    || fail "TORNLEGIT-BEFORE: the pre-fix run did not print the accounting line that CONTRADICTS its own finding: $(grep 'boot accounting' "$WORK/out.tpin2")"
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-nonce-pin" --store "$WORK/store-tpin" \
    --rootfs "$WORK/rootfs-tpin" --obs-file "$WORK/obsf-tpin-prefix.obs" --boots 4 \
    > "$WORK/out.tpin3" 2>&1
expect_coh "$WORK/out.tpin3" $? "TORNLEGIT-BEFORE/AFTER (88a73b8, same store and same observation)"
grep -q 'TORN' "$WORK/out.tpin3" \
    || fail "TORNLEGIT-BEFORE/AFTER: the fixed tool does not even mention the torn line it tolerated"
echo "test_fx_audit: TORNLEGIT-BEFORE: on the pinned fcebaa3 the SAME healthy torn-verdict store is REJECTED (exit 1, message contradicting its own accounting); 88a73b8 accepts it on the same store and observation (the nonce-era working tree accepts the nonce-line twin in TORNLEGIT)"

# ══ THE MUTATION CONTROL (positive control, per check) ══════════════════
# a detector with exactly one check's registration deleted must go COHERENT
# on that check's fixture (and the blind seat goes coherent on the COHERENT
# tamper — the bound made visible)
mutate() { # mutate NAME OUT — sed out one run_check registration
    sed "/run_check(\"$1\", /d" "$REPO/tools/fx-audit.c" > "$WORK/mut-$1.c" \
        || fail "cannot mutate $1"
    cmp -s "$WORK/mut-$1.c" "$REPO/tools/fx-audit.c" \
        && fail "mutation of $1 changed nothing (the sed matched no line — check name drift?)"
    cc -std=c11 -O2 -Wall -Wextra -I"$REPO/src/vendor/dhall-c" \
       -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
       -o "$2" "$WORK/mut-$1.c" "$REPO/src/vendor/dhall-c/sha256.c" \
        || fail "cannot build the $1 mutant"
}
mut_run() { # mut_run BIN NAME — the mutant on fixture NAME
    mkled "$WORK/nonces-$2.led" "${MUT_BOOTS:-4}"
    FXSTORE_BIN="$FXSTORE" "$1" --store "$WORK/store-$2" \
        --rootfs "$WORK/rootfs-$2" --obs-file "$WORK/obsf-$2.obs" \
        --boots "${MUT_BOOTS:-4}" --nonces "$WORK/nonces-$2.led"
}

# the mutant fixtures reuse the arms' tampered copies (already built above):
# chain/drift/gone/damaged carry their tamper; coh is the coherent tamper
mutate version-chain             "$WORK/mut-version-chain"
mut_run "$WORK/mut-version-chain" chain > "$WORK/out.m-chain" 2>&1
expect_coh "$WORK/out.m-chain" $? "MUTANT version-chain (CURRENT=99 went coherent — the check is load-bearing)"
mutate recovery-without-failure  "$WORK/mut-recovery-without-failure"
fresh m-rwf
echo "200 $CUR $V1 $GH_CUR $(nth 5)" >> "$WORK/store-m-rwf/.recovery"
MUT_BOOTS=5 mut_run "$WORK/mut-recovery-without-failure" m-rwf > "$WORK/out.m-rwf" 2>&1
expect_coh "$WORK/out.m-rwf" $? "MUTANT recovery-without-failure (unrecorded failure went coherent)"
mutate verify-drift              "$WORK/mut-verify-drift"
mut_run "$WORK/mut-verify-drift" drift > "$WORK/out.m-drift" 2>&1
expect_coh "$WORK/out.m-drift" $? "MUTANT verify-drift (unmanaged file went coherent)"
mutate facts-path-gone           "$WORK/mut-facts-path-gone"
mut_run "$WORK/mut-facts-path-gone" gone > "$WORK/out.m-gone" 2>&1
expect_coh "$WORK/out.m-gone" $? "MUTANT facts-path-gone (missing store dir went coherent)"
mutate records-damaged           "$WORK/mut-records-damaged"
mut_run "$WORK/mut-records-damaged" damaged > "$WORK/out.m-damaged" 2>&1
expect_coh "$WORK/out.m-damaged" $? "MUTANT records-damaged (foreign line went coherent)"
mutate previous-observation      "$WORK/mut-previous-observation"
mut_run "$WORK/mut-previous-observation" coh > "$WORK/out.m-prevobs" 2>&1
expect_coh "$WORK/out.m-prevobs" $? "MUTANT previous-observation (THE BOUND: the coherent tamper goes coherent without host memory)"
mutate boot-accounting           "$WORK/mut-boot-accounting"
MUT_BOOTS=3 mut_run "$WORK/mut-boot-accounting" forg > "$WORK/out.m-acc" 2>&1
expect_coh "$WORK/out.m-acc" $? "MUTANT boot-accounting (the appended forged verdict goes coherent — the host-boot correlation is load-bearing)"
# THE NONCE DIRECTION: a detector that stops REQUIRING the nonce must go
# coherent on exactly the pair-forgery fixture — the check is the seat.
mkled "$WORK/nonces-pairsil.led" 4
MUT_BOOTS=4 mut_run "$WORK/mut-boot-accounting" pairsil > "$WORK/out.m-pair" 2>&1
expect_coh "$WORK/out.m-pair" $? "MUTANT boot-accounting on the PAIR forgery (a detector that stops requiring the nonce lets the silent-boot pair through)"
# THE RE-ARM ANCHOR direction (the BLOCKER's own control): with the store's
# publish record disabled as the second verdict anchor, the HEALTHY re-arm
# shape — one boot, one nonce, the second verdict for the activated
# version — goes INCOHERENT with bootlog-forged-verdict: exactly the false
# positive the review measured, the direction that rolls a healthy machine
# back.  The mutant is sed-built from a copy and cmp-proven different, the
# pin_build discipline.
sed 's|return 1; /\* REARM-ANCHOR|return 0; /* mutant-anchor|' "$REPO/tools/fx-audit.c" > "$WORK/mut-noanchor.c" \
    || fail "cannot write the no-anchor mutant"
cmp -s "$WORK/mut-noanchor.c" "$REPO/tools/fx-audit.c" \
    && fail "the no-anchor mutation changed nothing (the sed matched no line — marker drift?)"
cc -std=c11 -O2 -Wall -Wextra -I"$REPO/src/vendor/dhall-c" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$WORK/mut-noanchor" "$WORK/mut-noanchor.c" "$REPO/src/vendor/dhall-c/sha256.c" \
    || fail "cannot build the no-anchor mutant"
mk_rearm m-noanchor
MUT_BOOTS=5 mut_run "$WORK/mut-noanchor" m-noanchor > "$WORK/out.m-noanchor" 2>&1
expect_incoh "$WORK/out.m-noanchor" $? "MUTANT no-rearm-anchor (the healthy re-arm boot goes INCOHERENT — the anchor is load-bearing in the false-positive direction)" bootlog-forged-verdict
# THE PER-VERSION VERDICT BUDGET direction: with the budget loop disabled,
# the FLIP (a second verdict for the version the window already verdicted,
# wearing the same live nonce) goes coherent — the one catch a per-nonce
# rule cannot express, proven load-bearing.
sed 's|for (size_t k = 0; k < g_nvstat; k++) { /\* VERDICT-BUDGET|for (size_t k = 0; 0; k++) { /* mutant-budget|' "$REPO/tools/fx-audit.c" > "$WORK/mut-nobudget.c" \
    || fail "cannot write the no-budget mutant"
cmp -s "$WORK/mut-nobudget.c" "$REPO/tools/fx-audit.c" \
    && fail "the no-budget mutation changed nothing (the sed matched no line — marker drift?)"
cc -std=c11 -O2 -Wall -Wextra -I"$REPO/src/vendor/dhall-c" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$WORK/mut-nobudget" "$WORK/mut-nobudget.c" "$REPO/src/vendor/dhall-c/sha256.c" \
    || fail "cannot build the no-budget mutant"
mk_rearm m-nobudget
echo "$REARM_V ok 999 $(nth 5)" >> "$WORK/store-m-nobudget/.bootlog"
MUT_BOOTS=5 mut_run "$WORK/mut-nobudget" m-nobudget > "$WORK/out.m-nobudget" 2>&1
expect_coh "$WORK/out.m-nobudget" $? "MUTANT no-verdict-budget (the verdict FLIP goes coherent — the per-version budget is load-bearing)"
# THE PER-VERSION-PER-WINDOW IP CAP direction (the BLOCKER's own seam): with
# the duplicate check disabled (the version comparison can never match), the
# CROSS-NONCE flip goes coherent on the REARMIPX fixture — the forged pair
# rides a SECOND real window nonce, ip(v) and vd(v) rise in lockstep, and the
# per-version budget passes a SECOND verdict for v.  That is the exact
# re-opened capability the fix closes, and the seam proves the cap (not some
# other predicate) is what fires in REARMIPX.
sed 's|if (seen_ip\[q\] == g_bl\[i\].v) { /\* VERSION-KEY \*/|if (0) { /* mutant-versionkey */|' "$REPO/tools/fx-audit.c" > "$WORK/mut-versionkey.c" \
    || fail "cannot write the no-version-key mutant"
cmp -s "$WORK/mut-versionkey.c" "$REPO/tools/fx-audit.c" \
    && fail "the no-version-key mutation changed nothing (the sed matched no line — marker drift?)"
cc -std=c11 -O2 -Wall -Wextra -I"$REPO/src/vendor/dhall-c" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$WORK/mut-versionkey" "$WORK/mut-versionkey.c" "$REPO/src/vendor/dhall-c/sha256.c" \
    || fail "cannot build the no-version-key mutant"
MUT_BOOTS=6 mut_run "$WORK/mut-versionkey" rearmipx > "$WORK/out.m-vkey" 2>&1
expect_coh "$WORK/out.m-vkey" $? "MUTANT no-version-key (the CROSS-NONCE flip goes coherent — the per-version-per-window ip cap is load-bearing)"
grep -q "for v$RIPX_V — a version the store FIRST PUBLISHED in this window" "$WORK/out.m-vkey" \
    || fail "MUTANT no-version-key: the mutant did not even NAME the forged pair as a legitimate re-arm (the seam is vacuous): $(grep -i 'RE-ARM' "$WORK/out.m-vkey")"
# THE NOT-ALREADY-BOOTED RE-ARM CLAUSE direction (the republish blocker's
# own seam): with the own-check disabled (the already-booted comparison can
# never match), the ROLL-FORWARD REPUBLISH forge goes coherent on the
# REARMIPREPUB fixture — the forged pair rides an earlier real window nonce,
# reads as a legitimate re-arm (the republished version is first-published,
# newer than that boot's own, and never had a real re-arm), and the verdict
# budget passes a SECOND verdict for it.  That is the exact republish shape
# round 2's cap does not close, and the seam proves the not-already-booted
# clause (not some other predicate) is what fires in REARMIPREPUB.
sed 's|} else if (vstat_for(g_bl\[i\].v)->own) { /\* NOT-BOOTED-KEY \*/|} else if (0) { /* mutant-notbooted */|' "$REPO/tools/fx-audit.c" > "$WORK/mut-notbooted.c" \
    || fail "cannot write the no-notbooted mutant"
cmp -s "$WORK/mut-notbooted.c" "$REPO/tools/fx-audit.c" \
    && fail "the no-notbooted mutation changed nothing (the sed matched no line — marker drift?)"
cc -std=c11 -O2 -Wall -Wextra -I"$REPO/src/vendor/dhall-c" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$WORK/mut-notbooted" "$WORK/mut-notbooted.c" "$REPO/src/vendor/dhall-c/sha256.c" \
    || fail "cannot build the no-notbooted mutant"
MUT_BOOTS=6 mut_run "$WORK/mut-notbooted" rearmiprepub > "$WORK/out.m-notbooted" 2>&1
expect_coh "$WORK/out.m-notbooted" $? "MUTANT no-not-booted-key (the REPUBLISH forge goes coherent — the not-already-booted re-arm clause is load-bearing)"
grep -q "for v$RIPR_W — a version the store FIRST PUBLISHED in this window" "$WORK/out.m-notbooted" \
    || fail "MUTANT no-not-booted-key: the mutant did not even NAME the forged pair as a legitimate re-arm (the seam is vacuous): $(grep -i 'RE-ARM' "$WORK/out.m-notbooted")"
# THE SAME CLAUSE IN THE FALSE-POSITIVE DIRECTION: with the own-check forced
# ALWAYS-TRUE (any later in-progress rejected), the HEALTHY TWO-activation
# boot (REARMIP2: two re-arm ips, one nonce, NEITHER version booted) goes
# INCOHERENT — proving the clause must be scoped to a version that already
# appeared as a boot's OWN first in-progress, and that the REARMIP2 arm CAN
# FAIL (a fixture that cannot fail is not a test).
sed 's|} else if (vstat_for(g_bl\[i\].v)->own) { /\* NOT-BOOTED-KEY \*/|} else if (1) { /* mutant-broad */|' "$REPO/tools/fx-audit.c" > "$WORK/mut-broad.c" \
    || fail "cannot write the over-broad mutant"
cmp -s "$WORK/mut-broad.c" "$REPO/tools/fx-audit.c" \
    && fail "the over-broad mutation changed nothing (the sed matched no line — marker drift?)"
cc -std=c11 -O2 -Wall -Wextra -I"$REPO/src/vendor/dhall-c" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$WORK/mut-broad" "$WORK/mut-broad.c" "$REPO/src/vendor/dhall-c/sha256.c" \
    || fail "cannot build the over-broad mutant"
mk_rearmip2 m-broad
MUT_BOOTS=5 mut_run "$WORK/mut-broad" m-broad > "$WORK/out.m-broad" 2>&1
expect_incoh "$WORK/out.m-broad" $? "MUTANT over-broad not-booted clause (the HEALTHY two-activation boot goes INCOHERENT — the clause must not fire on a version that was never booted)" bootlog-fabricated-boots
echo "test_fx_audit: MUTANTS: each check's fixture goes coherent when that one check is sed-ed out — including the previous-observation comparison on the coherent tamper (the bound, made visible), boot-accounting on the appended forged verdict, and boot-accounting on the PAIR forgery (the nonce requirement is load-bearing); and the four intra-check seams: without the RE-ARM anchor the healthy re-arm boot goes INCOHERENT (the false-positive direction), without the PER-VERSION verdict budget the verdict FLIP goes coherent, without the VERSION-KEYED re-arm duplicate the CROSS-NONCE flip goes coherent (REARMIPX), and without the NOT-BOOTED-KEY the REPUBLISH forge goes coherent (REARMIPREPUB)"

# src-of-artifact's own finding (disagreement-artifact-gone) is emitted by
# the previous-observation walk, whose mutant arm above covers the
# mechanism; the src-of-artifact check row itself is state-reporting only
# (absence is a legitimate fallback), so it has no failing fixture BY
# DESIGN — the finding it feeds is the one the ARTIFACT arm pins.

echo "test_fx_audit: PASS — the audit seat discriminates (clean passes with a real roll-forward history, each named incoherence fires from its own fixture, the coherent tamper passes every cross-check and is caught only by the previous observation, the APPENDED forged verdict is refused by the host-boot accounting on the new tree and passes on the pinned pre-change tree, every legitimate growth shape stays coherent, the trigger refuses clean and rolls back tampered via fxstore --hard, the verdict is independent of attempts.jsonl, and a one-check mutant goes blind on exactly its own fixture)"
exit 0
