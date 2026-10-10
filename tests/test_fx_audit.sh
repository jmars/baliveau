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
#               harness's own kill shape), and a SILENT boot the writer
#               records nothing for (no bootable generation).
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
# THE FAIL-BEFORE is PINNED at 030fbdc (the revision this change lands on
# top of): the gate extracts tools/fx-audit.c AT THAT REVISION (git show,
# guarded by git cat-file -e), PROVES it differs from the working tree
# (cmp — a control that equals its subject proves nothing), builds it, and
# shows the SAME appended forged verdict auditing COHERENT on it.  Nothing
# depends on the position of HEAD; the pin is a fixed object name.
#
# FIXTURE HONESTY: .bootlog/.recovery are fx-init's files and fx-init does
# not run host-side; the gate WRITES them in the writers' exact formats
# (bootlog_append's "%u %s %u\n" — a "<v> in-progress <epoch>" line AND the
# verdict line for every boot, because that is what the writer appends per
# boot (init.zig:4387 then the verdict sites); recovery_line's "<epoch>
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
# Env: FXSTORE_BIN (default ../fxstore/zig-out/bin/fxstore), FX_INIT_REPO,
#      FX_AUDIT_KEEP=1.
set -u

fail() { echo "test_fx_audit: FAIL: $*" >&2; exit 1; }
skip() { echo "test_fx_audit: SKIP ($*)"; exit 77; }

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
SIBS="$(cd "$REPO/.." && pwd)"

command -v cc >/dev/null 2>&1 || skip "cc not found"
command -v sed >/dev/null 2>&1 || skip "sed not found"

FXSTORE="${FXSTORE_BIN:-$SIBS/fxstore/zig-out/bin/fxstore}"
[ -x "$FXSTORE" ] || skip "fxstore binary missing at $FXSTORE (build the sibling)"
"$FXSTORE" --help 2>&1 | grep -q 'fxstore facts' || skip "fxstore at $FXSTORE predates 'facts' (rebuild the sibling)"

INIT="${FX_INIT_REPO:-$SIBS/fx-init}"
[ -d "$INIT" ] || skip "fx-init checkout not found at $INIT (set FX_INIT_REPO)"
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL"

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
# mode 0 rows (the /bin links) have a PACKAGE DIR as their origin (already
# provisioned); regular rows (the /etc copies) name a file inside the
# generation dir, which dhake materializes in-guest and the gate fakes here.
materialize_rootfs() {
    _st="$1"; _rt="$2"; _v="$3"; _ps="$4"
    FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts install --as-of "$_v" --store "$_st" \
        | while IFS="$(printf '\t')" read -r tgt org mode gh; do
            [ -n "$tgt" ] || continue
            mkdir -p "$_rt/$(dirname "$tgt")" || exit 1
            rm -f "$_rt$tgt"
            if [ "$mode" = "0" ]; then
                [ -d "$_st/$org" ] || exit 1
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
# written as its REAL line pair: "<v> in-progress <epoch>" (init.zig:4387,
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
# line: <epoch-s> <published-version> <from-failed-version> <content-genhash|->
EOF
}

genhash_of() { # genhash_of STORE VERSION -> the generation hash
    FXSTORE_BIN="$FXSTORE" "$FXSTORE" facts generation --as-of "$2" --store "$1" \
        | head -1 | cut -f1
}

cur_of() { cat "$1/.db/snapshots/CURRENT" 2>/dev/null || fail "no CURRENT in $1"; }

audit() { # audit STORE ROOTFS BOOTS [extra args...] — runs the seat
    _st="$1"; _rt="$2"; _nb="$3"; shift 3
    FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$_st" --rootfs "$_rt" --boots "$_nb" "$@"
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
# started: v1 boots ok; v2 boots and FAILS; the next boot rolls forward
# (fxstore soft rollback republishing v1's content as v$CUR) and boots ok.
# Each boot is the writer's real line pair (in-progress at boot start,
# init.zig:4387; the verdict from the g_boot_decided latch).
write_records "$STORE" \
    "$V1 in-progress 99" \
    "$V1 ok 100" \
    "$V2 in-progress 100" \
    "$V2 failed 101" \
    "$CUR in-progress 102" \
    "$CUR ok 103"
echo "$CUR $V2 $GH_CUR" | awk '{ print "103 " $1 " " $2 " " $3 }' >> "$STORE/.recovery"


OBS="$WORK/obs"
audit "$STORE" "$ROOT" 3 --obs-dir "$OBS" > "$WORK/out.clean1" 2>&1
expect_coh "$WORK/out.clean1" $? "CLEAN first audit"
grep -q 'ENROLLING' "$WORK/out.clean1" || fail "CLEAN: first run did not enroll"
grep -q 'host boot count 3 is recorded as the baseline' "$WORK/out.clean1" \
    || fail "CLEAN: the enrollment did not record the host boot count"
# idempotence + the append-only path: a LEGITIMATE new boot between audits
# (the writer's real pair: in-progress at start, then the verdict) must
# leave the store coherent — fx-init appends; it never rewrites
echo "$CUR in-progress 104" >> "$STORE/.bootlog"
echo "$CUR ok 105" >> "$STORE/.bootlog"
audit "$STORE" "$ROOT" 4 --obs-dir "$OBS" > "$WORK/out.clean2" 2>&1
expect_coh "$WORK/out.clean2" $? "CLEAN re-audit (idempotence + legal append: an ordinary boot)"
grep -q 'append-only respected' "$WORK/out.clean2" \
    || fail "CLEAN re-audit: the legal append was not seen by the prefix comparison"
grep -q 'boot accounting: host boots 3 -> 4 (delta 1); this window added in-progress 1, verdicts 1, shutdown 0' "$WORK/out.clean2" \
    || fail "CLEAN re-audit: the ordinary boot was not accounted by the host delta: $(grep 'boot accounting' "$WORK/out.clean2")"
grep -q 'disagreement' "$WORK/out.clean2" \
    && fail "CLEAN re-audit: a legal append produced a disagreement"
echo "test_fx_audit: CLEAN: coherent on first audit; an ordinary boot (in-progress + ok, --boots 3 -> 4) re-audits coherent"

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
    # it added (the host's count is an INPUT, never inferred).
    _fxname="$1"; shift
    FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$WORK/store-$_fxname" \
        --rootfs "$WORK/rootfs-$_fxname" --obs-file "$WORK/obsf-$_fxname.obs" \
        --boots "${FBOOTS:-4}" "$@"
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
echo "200 $CUR $V1 $GH_CUR" >> "$WORK/store-rwf/.recovery"
FBOOTS=5 run_fixture rwf > "$WORK/out.rwf" 2>&1
expect_incoh "$WORK/out.rwf" $? "RWF" recovery-without-failure
grep -q "last bootlog verdict is 'ok'" "$WORK/out.rwf" \
    || fail "RWF: the finding does not name the ok verdict: $(grep '^INCOHERENT recovery-without-failure' "$WORK/out.rwf")"
grep -q '^check boot-accounting: pass$' "$WORK/out.rwf" \
    || fail "RWF: boot-accounting fired too (isolation failed — the row has a declared boot behind it)"
fresh rwfctl
echo "201 $CUR $V2 $GH_CUR" >> "$WORK/store-rwfctl/.recovery"
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
echo "202 $CUR $V2 0000000000000000000000000000000000000000000000000000000000000000" >> "$WORK/store-chain2/.recovery"
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
audit "$STORE_B" "$WORK/rootfs-b" 4 --obs-dir "$WORK/obs-b" > "$WORK/out.fb1" 2>&1
expect_coh "$WORK/out.fb1" $? "FACTS control (own observation)"
# the arm: B audited against A's observation file
audit "$STORE_B" "$WORK/rootfs-b" 4 --obs-file "$AOBSFILE" > "$WORK/out.fb2" 2>&1
expect_incoh "$WORK/out.fb2" $? "FACTS rebuilt history" disagreement-facts-changed
grep -q "version $V1B" "$WORK/out.fb2" \
    || fail "FACTS: the finding does not name version $V1B"
echo "test_fx_audit: FACTS: same version numbers, different content, against the old observation -> disagreement-facts-changed"

# ══ THE TRIGGER ═════════════════════════════════════════════════════════
# refuses a clean store
audit "$STORE" "$ROOT" 4 --obs-dir "$WORK/obs-trig-clean" --rollback > "$WORK/out.trigref" 2>&1
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
    --boots 4 \
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
# "<v$V2> ok" in the writer's exact shape.  bootlog_last (init.zig:737)
# reads the LAST non-shutdown status, so the next boot would treat v$V2 as
# ok and fx-init would NOT roll forward — the broken generation stays
# current.  On the standard baseline (which carries a .recovery row from
# v$V2) the bare forge also trips recovery-without-failure — a row pointing
# at a version whose failure vanished; with NO row nothing cross-checks it
# and only the host's boot count can see it.
mk_norec() { # mk_norec NAME — a store whose failure was never rolled forward
    # v1 boots ok; v2 boots and FAILS; the OPERATOR hard-rolls back to v1
    # (fxstore rollback --hard — operator rollbacks write no .recovery row,
    # by the journal's own header), and v1 boots ok again.  THREE boots,
    # header-only .recovery.  Enrollment runs with its own observation
    # file (the fresh-copied one describes the standard baseline).
    _n="$1"
    fresh "$_n"
    write_records "$WORK/store-$_n" \
        "$V1 in-progress 99" \
        "$V1 ok 100" \
        "$V2 in-progress 100" \
        "$V2 failed 101" \
        "$V1 in-progress 104" \
        "$V1 ok 105"
    FXSTORE_BIN="$FXSTORE" "$FXSTORE" rollback --hard "$V1" --store "$WORK/store-$_n" >/dev/null 2>&1 \
        || fail "NOREC $_n: fxstore rollback --hard $V1 failed"
    [ "$(cur_of "$WORK/store-$_n")" = "$V1" ] \
        || fail "NOREC $_n: the hard rollback did not repoint CURRENT at v$V1"
    rm -f "$WORK/obsf-$_n.obs"
    FBOOTS=3 run_fixture "$_n" > "$WORK/out.norec-$_n" 2>&1
    expect_coh "$WORK/out.norec-$_n" $? "NOREC enroll ($_n)"
}

mk_norec forg
echo "$V2 ok 999" >> "$WORK/store-forg/.bootlog"
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
echo "$CUR in-progress 104" >> "$WORK/store-fab/.bootlog"
echo "$CUR ok 105" >> "$WORK/store-fab/.bootlog"
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
printf '%s' "$V2 ok 999" >> "$WORK/store-torn/.bootlog"
FBOOTS=3 run_fixture torn > "$WORK/out.torn" 2>&1
expect_incoh "$WORK/out.torn" $? "TORNFORGE" bootlog-forged-verdict
grep -q 'TORN' "$WORK/out.torn" \
    || fail "TORNFORGE: the finding does not say the line is torn: $(grep '^INCOHERENT bootlog-forged-verdict' "$WORK/out.torn")"
grep -q '^check recovery-without-failure: pass$' "$WORK/out.torn" \
    || fail "TORNFORGE: recovery-without-failure fired too (isolation failed)"
echo "test_fx_audit: TORNFORGE: a forge without its newline still fires (fgets returns it in-guest)"

# ══ LEGIT: every legitimate growth shape stays coherent ════════════════
# a boot that FAILS (in-progress + failed) — FBOOTS declares one new boot
fresh legfail
echo "$CUR in-progress 110" >> "$WORK/store-legfail/.bootlog"
echo "$CUR failed 111" >> "$WORK/store-legfail/.bootlog"
FBOOTS=5 run_fixture legfail > "$WORK/out.legfail" 2>&1
expect_coh "$WORK/out.legfail" $? "LEGIT failed boot"
echo "test_fx_audit: LEGIT: a boot that fails (in-progress + failed, --boots 5) stays coherent"

# a failure that ROLLS FORWARD: the failed boot, then the REAL fxstore soft
# rollback (fx-init's own roll-forward driver) republishing v$V1's content
# as a NEW version, then that generation's boot (in-progress + ok) and its
# .recovery row — two boots, all growth accounted
fresh legrwf
echo "$CUR in-progress 110" >> "$WORK/store-legrwf/.bootlog"
echo "$CUR failed 111" >> "$WORK/store-legrwf/.bootlog"
FXSTORE_BIN="$FXSTORE" "$FXSTORE" rollback "$V1" --store "$WORK/store-legrwf" >/dev/null 2>&1 \
    || fail "LEGIT rwf: fxstore rollback $V1 failed"
ROLLV=$(cur_of "$WORK/store-legrwf")
[ "$ROLLV" -gt "$CUR" ] || fail "LEGIT rwf: the republish did not ratchet ($ROLLV <= $CUR)"
GH_ROLL=$(genhash_of "$WORK/store-legrwf" "$ROLLV")
[ "$GH_ROLL" = "$GH1" ] || fail "LEGIT rwf: the republished content is not v$V1's (genhash $GH_ROLL != $GH1)"
echo "$ROLLV in-progress 112" >> "$WORK/store-legrwf/.bootlog"
echo "$ROLLV ok 113" >> "$WORK/store-legrwf/.bootlog"
echo "111 $ROLLV $CUR $GH_ROLL" >> "$WORK/store-legrwf/.recovery"
FBOOTS=6 run_fixture legrwf > "$WORK/out.legrwf" 2>&1
expect_coh "$WORK/out.legrwf" $? "LEGIT roll-forward boot"
grep -q '^check recovery-without-failure: pass$' "$WORK/out.legrwf" \
    || fail "LEGIT rwf: recovery-without-failure fired on a real recorded failure (isolation failed)"
echo "test_fx_audit: LEGIT: a failure that rolls forward (failed -> real fxstore republish v$ROLLV -> in-progress + ok + .recovery row, --boots 6) stays coherent"

# a clean SHUTDOWN: the writer appends ip + ok + shutdown, ONE boot
fresh legsd
echo "$CUR in-progress 110" >> "$WORK/store-legsd/.bootlog"
echo "$CUR ok 111" >> "$WORK/store-legsd/.bootlog"
echo "$CUR shutdown 112" >> "$WORK/store-legsd/.bootlog"
FBOOTS=5 run_fixture legsd > "$WORK/out.legsd" 2>&1
expect_coh "$WORK/out.legsd" $? "LEGIT clean shutdown"
echo "test_fx_audit: LEGIT: a clean shutdown (in-progress + ok + shutdown) stays coherent"

# a boot KILLED AT THE VERDICT (init.zig's own comment: the harness kills
# the VM at the verdict) — in-progress alone, no verdict: legal, the boot
# never decided
fresh legkill
echo "$CUR in-progress 110" >> "$WORK/store-legkill/.bootlog"
FBOOTS=5 run_fixture legkill > "$WORK/out.legkill" 2>&1
expect_coh "$WORK/out.legkill" $? "LEGIT killed at verdict"
echo "test_fx_audit: LEGIT: a boot killed at the verdict (in-progress alone) stays coherent"

# a SILENT boot: the host started one more boot and the writer appended
# NOTHING (no bootable generation: decide_boot_version returned 0, which
# appends no line and pre-decides the verdict away, init.zig:4368-4379).
# Coherent — and this is exactly the SLACK the stated bound admits: a boot
# the host started but fx-init never recorded leaves the count richer than
# the record, and a forger appending a line-pair into that slack would pass
# (closing it needs a per-boot host nonce; see the tool's bound).
fresh legq
FBOOTS=5 run_fixture legq > "$WORK/out.legq" 2>&1
expect_coh "$WORK/out.legq" $? "LEGIT silent boot"
grep -q 'no .bootlog lines added this window' "$WORK/out.legq" \
    || fail "LEGIT silent boot: the empty window was not reported as such: $(grep 'boot accounting' "$WORK/out.legq")"
echo "test_fx_audit: LEGIT: a silent boot (started, nothing appended — no bootable generation) stays coherent"

# ══ BEFORE: the fail-before, on the PINNED pre-change revision ══════════
# The asymmetry a regression probe needs: on 030fbdc (the tree this change
# lands on top of) the SAME forge went COHERENT.  The pin is guarded and
# PROVEN DIFFERENT from the working tree — a control that equals its
# subject proves nothing.
git -C "$REPO" cat-file -e 030fbdc^{commit} 2>/dev/null \
    || fail "BEFORE: the pinned revision 030fbdc does not exist (the fail-before control needs it)"
git -C "$REPO" show 030fbdc:tools/fx-audit.c > "$WORK/pinned-fx-audit.c" \
    || fail "BEFORE: cannot extract tools/fx-audit.c at 030fbdc"
cmp -s "$WORK/pinned-fx-audit.c" "$REPO/tools/fx-audit.c" \
    && fail "BEFORE: the pinned 030fbdc source is IDENTICAL to the working tree — the control equals its subject and proves nothing"
cc -std=c11 -O2 -Wall -Wextra -I"$REPO/src/vendor/dhall-c" \
   -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE \
   -o "$WORK/fx-audit-pinned" "$WORK/pinned-fx-audit.c" "$REPO/src/vendor/dhall-c/sha256.c" \
    || fail "BEFORE: cannot build the pinned 030fbdc fx-audit"
# the no-recovery fixture (the store where the forge is truly invisible),
# enrolled with the PINNED tool — its observation is format 1, no boot
# count, and the pinned tool does not know --boots
mk_norec before
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-pinned" --store "$WORK/store-before" \
    --rootfs "$WORK/rootfs-before" --obs-file "$WORK/obsf-before-pinned.obs" \
    > "$WORK/out.bp1" 2>&1
expect_coh "$WORK/out.bp1" $? "BEFORE enroll (pinned tool)"
# the IDENTICAL forge the FORGERY arm makes
echo "$V2 ok 999" >> "$WORK/store-before/.bootlog"
FXSTORE_BIN="$FXSTORE" "$WORK/fx-audit-pinned" --store "$WORK/store-before" \
    --rootfs "$WORK/rootfs-before" --obs-file "$WORK/obsf-before-pinned.obs" \
    > "$WORK/out.bp2" 2>&1
expect_coh "$WORK/out.bp2" $? "BEFORE the forge goes COHERENT on 030fbdc (the measured hole)"
grep -q 'append-only respected' "$WORK/out.bp2" \
    || fail "BEFORE: the pinned tool did not even see the append (the fixture is wrong)"
# the fail-after on the SAME tampered store: the new tool against its OWN
# (format-2) enrollment of the same pre-forge state
FBOOTS=3 run_fixture before > "$WORK/out.bp2new" 2>&1
expect_incoh "$WORK/out.bp2new" $? "BEFORE/AFTER on the same store" bootlog-forged-verdict
# and the new tool REFUSES the pinned tool's format-1 observation: a
# baseline with no boot count cannot anchor growth, and assuming one is
# the silent default this seat refuses
FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$WORK/store-before" \
    --rootfs "$WORK/rootfs-before" --obs-file "$WORK/obsf-before-pinned.obs" --boots 3 \
    > "$WORK/out.bp3" 2>&1
_rc=$?
[ "$_rc" = "2" ] || fail "BEFORE: the new tool must refuse a format-1 observation (exit 2), got $_rc"
grep -q 'FORMAT 1' "$WORK/out.bp3" \
    || fail "BEFORE: the refusal does not name the format-1 baseline"
grep -q 're-enroll' "$WORK/out.bp3" \
    || fail "BEFORE: the refusal does not name the way out"
echo "test_fx_audit: BEFORE: on the pinned 030fbdc the SAME appended '$V2 ok 999' audits COHERENT (exit 0); the new tool fires on the same store and REFUSES the pinned tool's format-1 observation (no boot count recorded — never assume one)"

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
    FXSTORE_BIN="$FXSTORE" "$1" --store "$WORK/store-$2" \
        --rootfs "$WORK/rootfs-$2" --obs-file "$WORK/obsf-$2.obs" \
        --boots "${MUT_BOOTS:-4}"
}

# the mutant fixtures reuse the arms' tampered copies (already built above):
# chain/drift/gone/damaged carry their tamper; coh is the coherent tamper
mutate version-chain             "$WORK/mut-version-chain"
mut_run "$WORK/mut-version-chain" chain > "$WORK/out.m-chain" 2>&1
expect_coh "$WORK/out.m-chain" $? "MUTANT version-chain (CURRENT=99 went coherent — the check is load-bearing)"
mutate recovery-without-failure  "$WORK/mut-recovery-without-failure"
fresh m-rwf
echo "200 $CUR $V1 $GH_CUR" >> "$WORK/store-m-rwf/.recovery"
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
echo "test_fx_audit: MUTANTS: each check's fixture goes coherent when that one check is sed-ed out — including the previous-observation comparison on the coherent tamper (the bound, made visible) and boot-accounting on the appended forged verdict"

# src-of-artifact's own finding (disagreement-artifact-gone) is emitted by
# the previous-observation walk, whose mutant arm above covers the
# mechanism; the src-of-artifact check row itself is state-reporting only
# (absence is a legitimate fallback), so it has no failing fixture BY
# DESIGN — the finding it feeds is the one the ARTIFACT arm pins.

echo "test_fx_audit: PASS — the audit seat discriminates (clean passes with a real roll-forward history, each named incoherence fires from its own fixture, the coherent tamper passes every cross-check and is caught only by the previous observation, the APPENDED forged verdict is refused by the host-boot accounting on the new tree and passes on the pinned pre-change tree, every legitimate growth shape stays coherent, the trigger refuses clean and rolls back tampered via fxstore --hard, the verdict is independent of attempts.jsonl, and a one-check mutant goes blind on exactly its own fixture)"
exit 0
