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
# observation comparison's mutant is the COHERENT arm's control.  No pinned
# pre-fix revision is used anywhere: the tool is NEW, no earlier revision
# carries it, so there is no HEAD dependence to guard (stated so nobody
# reads its absence as an oversight).
#
# FIXTURE HONESTY: .bootlog/.recovery are fx-init's files and fx-init does
# not run host-side; the gate WRITES them in the writers' exact formats
# (bootlog_append's "%u %s %u\n", recovery_line's "<epoch> <published>
# <from-failed> <genhash>\n" under the verbatim RECOVERY_HEADER from
# init.zig).  Everything else is written by the real writers: fx-activate
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
# in the WRITERS' exact formats (see FIXTURE HONESTY above)
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

audit() { # audit STORE ROOTFS [extra args...] — runs the seat
    _st="$1"; _rt="$2"; shift 2
    FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$_st" --rootfs "$_rt" "$@"
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

# the machine's history in fx-init's records: v1 ok, v2 failed, the
# roll-forward republished v1's content as v$CUR, which then booted ok
write_records "$STORE" \
    "$V1 ok 100" \
    "$V2 failed 101" \
    "$CUR ok 103"
echo "$CUR $V2 $GH_CUR" | awk '{ print "103 " $1 " " $2 " " $3 }' >> "$STORE/.recovery"


OBS="$WORK/obs"
audit "$STORE" "$ROOT" --obs-dir "$OBS" > "$WORK/out.clean1" 2>&1
expect_coh "$WORK/out.clean1" $? "CLEAN first audit"
grep -q 'ENROLLING' "$WORK/out.clean1" || fail "CLEAN: first run did not enroll"
# idempotence + the append-only path: a LEGITIMATE new boot line between
# audits must leave the store coherent (fx-init appends; it never rewrites)
echo "$CUR ok 104" >> "$STORE/.bootlog"
audit "$STORE" "$ROOT" --obs-dir "$OBS" > "$WORK/out.clean2" 2>&1
expect_coh "$WORK/out.clean2" $? "CLEAN re-audit (idempotence + legal append)"
grep -q 'append-only respected' "$WORK/out.clean2" \
    || fail "CLEAN re-audit: the legal append was not seen by the prefix comparison"
grep -q 'disagreement' "$WORK/out.clean2" \
    && fail "CLEAN re-audit: a legal append produced a disagreement"
echo "test_fx_audit: CLEAN: coherent on first audit; a legal bootlog append re-audits coherent"

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

run_fixture() { # run_fixture NAME [extra seat args...]
    _fxname="$1"; shift
    FXSTORE_BIN="$FXSTORE" "$AUDIT" --store "$WORK/store-$_fxname" \
        --rootfs "$WORK/rootfs-$_fxname" --obs-file "$WORK/obsf-$_fxname.obs" "$@"
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
# the ok v1); the control row points at the recorded v2 failure
fresh rwf
echo "200 $CUR $V1 $GH_CUR" >> "$WORK/store-rwf/.recovery"
run_fixture rwf > "$WORK/out.rwf" 2>&1
expect_incoh "$WORK/out.rwf" $? "RWF" recovery-without-failure
grep -q "last bootlog verdict is 'ok'" "$WORK/out.rwf" \
    || fail "RWF: the finding does not name the ok verdict: $(grep '^INCOHERENT recovery-without-failure' "$WORK/out.rwf")"
fresh rwfctl
echo "201 $CUR $V2 $GH_CUR" >> "$WORK/store-rwfctl/.recovery"
run_fixture rwfctl > "$WORK/out.rwfctl" 2>&1
expect_coh "$WORK/out.rwfctl" $? "RWF control (failure IS recorded)"
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
# two readers, one lie)
fresh chain2
echo "202 $CUR $V2 0000000000000000000000000000000000000000000000000000000000000000" >> "$WORK/store-chain2/.recovery"
run_fixture chain2 > "$WORK/out.chain2" 2>&1
expect_incoh "$WORK/out.chain2" $? "CHAIN recovery-genhash" version-chain
grep -q '^check recovery-without-failure: pass$' "$WORK/out.chain2" \
    || fail "CHAIN(b): recovery-without-failure fired too (isolation failed)"
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
# control: B against its OWN observation is coherent
audit "$STORE_B" "$WORK/rootfs-b" --obs-dir "$WORK/obs-b" > "$WORK/out.fb1" 2>&1
expect_coh "$WORK/out.fb1" $? "FACTS control (own observation)"
# the arm: B audited against A's observation file
audit "$STORE_B" "$WORK/rootfs-b" --obs-file "$AOBSFILE" > "$WORK/out.fb2" 2>&1
expect_incoh "$WORK/out.fb2" $? "FACTS rebuilt history" disagreement-facts-changed
grep -q "version $V1B" "$WORK/out.fb2" \
    || fail "FACTS: the finding does not name version $V1B"
echo "test_fx_audit: FACTS: same version numbers, different content, against the old observation -> disagreement-facts-changed"

# ══ THE TRIGGER ═════════════════════════════════════════════════════════
# refuses a clean store
audit "$STORE" "$ROOT" --obs-dir "$WORK/obs-trig-clean" --rollback > "$WORK/out.trigref" 2>&1
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
    > "$WORK/out.inside" 2>&1
_rc=$?
[ "$_rc" = "2" ] || fail "LOUD: an --obs-dir inside the store must be refused (exit 2), got $_rc"
grep -q 'INSIDE the store' "$WORK/out.inside" || fail "LOUD: the refusal does not say why"
echo "test_fx_audit: LOUD: unreadable record -> exit 2; obs-inside-store refused"

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
        --rootfs "$WORK/rootfs-$2" --obs-file "$WORK/obsf-$2.obs"
}

# the mutant fixtures reuse the arms' tampered copies (already built above):
# chain/drift/gone/damaged carry their tamper; coh is the coherent tamper
mutate version-chain             "$WORK/mut-version-chain"
mut_run "$WORK/mut-version-chain" chain > "$WORK/out.m-chain" 2>&1
expect_coh "$WORK/out.m-chain" $? "MUTANT version-chain (CURRENT=99 went coherent — the check is load-bearing)"
mutate recovery-without-failure  "$WORK/mut-recovery-without-failure"
fresh m-rwf
echo "200 $CUR $V1 $GH_CUR" >> "$WORK/store-m-rwf/.recovery"
mut_run "$WORK/mut-recovery-without-failure" m-rwf > "$WORK/out.m-rwf" 2>&1
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
echo "test_fx_audit: MUTANTS: each check's fixture goes coherent when that one check is sed-ed out — including the previous-observation comparison on the coherent tamper (the bound, made visible)"

# src-of-artifact's own finding (disagreement-artifact-gone) is emitted by
# the previous-observation walk, whose mutant arm above covers the
# mechanism; the src-of-artifact check row itself is state-reporting only
# (absence is a legitimate fallback), so it has no failing fixture BY
# DESIGN — the finding it feeds is the one the ARTIFACT arm pins.

echo "test_fx_audit: PASS — the audit seat discriminates (clean passes with a real roll-forward history, each named incoherence fires from its own fixture, the coherent tamper passes every cross-check and is caught only by the previous observation, the trigger refuses clean and rolls back tampered via fxstore --hard, the verdict is independent of attempts.jsonl, and a one-check mutant goes blind on exactly its own fixture)"
exit 0
