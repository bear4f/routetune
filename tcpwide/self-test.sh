#!/usr/bin/env bash
# shellcheck disable=SC2317 # mock functions are invoked indirectly by sourced helpers
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCPWIDE_LIB_ONLY=1
# shellcheck source=./tcpwide.sh
. "$ROOT/tcpwide.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf 'PASS: %s\n' "$label"
}
PASS_COUNT=0
pass() { PASS_COUNT=$(( PASS_COUNT + 1 )); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# `unset -f` on a mock does not reveal the real function underneath -- it just
# removes it, and the next caller gets "command not found". Blocks that need the
# genuine definitions back re-source the library instead. Callers re-set any
# configuration variables they depend on immediately afterwards.
restore_lib() {
  # shellcheck source=./tcpwide.sh
  . "$ROOT/tcpwide.sh"
}

# ── 尺寸推导 ───────────────────────────────────────────────────────────────
assert_eq "$((250 * 125 * 500))" "$(bdp_bytes 500 250)" 'BDP is rate x rtt with no lost precision'
total_ram_bytes() { printf '%s\n' $((8 * 1024 * 1024 * 1024)); }
# 500 Mbps x 250 ms = 15.6 MB. tcp_adv_win_scale=1 hands the application half
# the receive buffer, so the ceiling is twice the product — plus a fixed 2 MiB.
# tcpfit A/B'd that margin on a real 300Mbps/168ms link: 11.25MB averaged
# 257.3 Mbps, the same buffer plus 2MiB averaged 272.7, both at zero
# retransmission. A fixed margin recovers it without scaling faster machines up
# proportionally.
assert_eq "$((2 * 250 * 125 * 500 + 2 * 1024 * 1024))" "$(buffer_ceiling 500 250)" \
  'the ceiling is twice the bandwidth-delay product plus a fixed margin'
# 0.16.0 made this 4, from two machines whose in-flight bytes both came to about
# a quarter of rmem_max. Doubling rmem_max on one of them from 43.4 to 86.8 MB
# then moved nine backends by nothing -- median in flight 11.41 -> 11.40 MB --
# which a quarter-of-rmem relationship cannot survive. Correlation across two
# boxes was not causation, so it is back to what tcp_adv_win_scale=1 promises.
BDP_MULTIPLIER=4
assert_eq "$((4 * 250 * 125 * 500 + 2 * 1024 * 1024))" "$(buffer_ceiling 500 250)" \
  'the multiplier is still a knob for anyone who wants to re-test it'
BDP_MULTIPLIER=2
# The asymmetry that motivates a coverage RTT also motivates a floor: a ceiling
# below what a distant client needs is a cap nobody can diagnose.
assert_eq "$((8 * 1024 * 1024))" "$(buffer_ceiling 10 20)" 'a tiny envelope still gets the 8 MiB floor'
# One socket may take at most a quarter of the global TCP budget, so four large
# flows still fit before the kernel starts shrinking anyone. The budget starts at
# a quarter of RAM and grows toward a third when four sockets at the required
# ceiling would not otherwise fit, so a small box with a fast port is not held to
# a memory ladder that knows nothing about the path. Clamping against RAM
# directly let one connection monopolise the budget on a small box.
total_ram_bytes() { printf '%s\n' $((512 * 1024 * 1024)); }
assert_eq "$((512 * 1024 * 1024 / 3 / 4))" "$(buffer_ceiling 2000 1000)" \
  'one socket is held to a quarter of the global TCP budget'
# The budget only grows when the need calls for it: a modest ceiling leaves the
# budget at RAM/4 and is not clamped at all.
assert_eq "$((2 * 400 * 125 * 200 + 2 * 1024 * 1024))" "$(buffer_ceiling 400 200)" \
  'a ceiling that fits inside the starting budget is passed through unclamped'
total_ram_bytes() { printf '%s\n' $((8 * 1024 * 1024 * 1024)); }

# netshape's RAM ladder was adopted in 0.5.0 and is withdrawn here. It derives a
# ceiling from memory alone and knows nothing about the port: on a 520 MB box
# with a gigabit port it returns 16 MB, advertising an 8 MB window and capping a
# single flow at 450 Mbps on a 149ms path. Measured there: 349 Mbps peak.
#
# It also never had supporting evidence. It was adopted because netshape
# outperformed tcpwide, but on that machine `raise` refused to lower and the
# ladder never applied at all — the gain was fq maxrate. And what it guarded
# against, BBR holding a huge cwnd, is now bounded by per-flow pacing.
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
buf="$(buffer_ceiling 1000 250)"
assert_eq "$((520 * 1024 * 1024 / 3 / 4))" "$buf" \
  'a small box with a fast port is sized by budget, not by a RAM ladder'
(( buf > 16 * 1024 * 1024 )) || fail 'the budget cap must beat the ladder it replaced here'
pass 'the gigabit box gets more than the ladder would have allowed'
# The reason the budget follows the need rather than RAM alone: a 2-core 520 MB
# box does clear a gigabit, and a budget derived from memory alone decided it
# could not. What matters is the rate the resulting window supports on the paths
# that box actually serves — 140-176 ms, not the 250 ms worst case.
for rtt in 150 176; do
  win=$(( $(buffer_ceiling 1000 "$rtt") / BDP_MULTIPLIER ))
  mbps=$(( win / 125 / rtt ))
  (( mbps >= 1000 )) || fail "a 520 MB box must clear a gigabit at ${rtt}ms, got ${mbps} Mbps"
done
pass 'a 520 MB box with a gigabit port clears the port on its real paths'
total_ram_bytes() { printf '%s\n' $((8 * 1024 * 1024 * 1024)); }
assert_eq '475000' "$(shaped_kbit 500)" 'shaping leaves the configured headroom under the line rate'

# ── 拥塞控制选择 ───────────────────────────────────────────────────────────
assert_eq bbr   "$(pick_cc 'reno cubic bbr')"      'a stock kernel gets bbr'
assert_eq bbr3  "$(pick_cc 'reno cubic bbr bbr3')" 'bbr3 wins when the kernel carries it'
assert_eq bbr2  "$(pick_cc 'reno cubic bbr bbr2')" 'bbr2 wins over bbr'
# cubic halves the window on every random radio loss, so falling back to it is a
# real degradation and check must say so rather than pass silently.
assert_eq cubic "$(pick_cc 'reno cubic')"          'a kernel without BBR falls back to cubic'

# ── 目标配置 ───────────────────────────────────────────────────────────────
available_cc() { printf 'reno cubic bbr\n'; }
tgt="$(target_sysctl 500 250)"
key() { awk -F'\t' -v k="$1" '$1 == k {print $2}' <<< "$tgt"; }
assert_eq '0' "$(key net.ipv4.tcp_slow_start_after_idle)" 'cwnd is not reset between streaming chunks'
# The kernel caches ssthresh per destination. A 5G link that had a bad minute
# leaves a pessimistic value behind, and the next connection starts from it and
# leaves slow start early. On a variable link that is a direct cause of a slow
# ramp, so this must always be part of the set.
# tcp_no_metrics_save and tcp_frto are NOT written any more. The narrow knob for
# a cached pessimistic ssthresh is tcp_no_ssthresh_metrics_save, which has
# defaulted to 1 since Linux 5.6 -- so forcing tcp_no_metrics_save=1 threw away
# the whole destination cache (RTT, RTTVAR, cwnd, reordering) to fix something
# the kernel already fixed. F-RTO is a sender-side algorithm and needs no
# cooperation from a middlebox, so the justification for zeroing it was wrong.
[[ -z "$(key net.ipv4.tcp_no_metrics_save)" ]] \
  || fail 'tcp_no_metrics_save must be left at the kernel default'
[[ -z "$(key net.ipv4.tcp_frto)" ]] || fail 'tcp_frto must be left at the kernel default'
pass 'the two sysctls with no evidence behind them are left alone'
assert_eq bbr "$(key net.ipv4.tcp_congestion_control)" 'the chosen congestion control lands in the set'
assert_eq "$(buffer_ceiling 500 250)" "$(key net.core.rmem_max)" 'the ceiling follows the coverage envelope'
# Every ceiling above is computed as twice the BDP, which is only right when the
# application gets half of the receive buffer. At 2 it gets a quarter and all of
# them are wrong by a factor of two, so the assumption is stated, not assumed.
assert_eq '1' "$(key net.ipv4.tcp_adv_win_scale)" 'the window share is still set where the kernel honours it'
# Without autotuning the ceiling is decorative: connections never leave the
# default and never grow toward it.
assert_eq '1' "$(key net.ipv4.tcp_moderate_rcvbuf)" 'receive autotuning is required for a ceiling to mean anything'
# rmem_max is only a ceiling. tcp_mem is the budget the kernel actually
# enforces, and past its pressure threshold it shrinks every socket regardless.
[[ -n "$(key net.ipv4.tcp_mem)" ]] || fail 'the global TCP budget must be part of the set'
pass 'the global TCP page budget is set alongside the per-socket ceiling'
# netshape disables ECN on purpose and its reason is specific and field-earned:
# cross-border middleboxes blackhole ECN negotiation, and these are exactly
# cross-border paths. That beats the theory that passive mode is inherently safe.
assert_eq '0' "$(key net.ipv4.tcp_ecn)" 'ECN stays off on cross-border paths'
assert_eq '' "$(key net.ipv4.tcp_notsent_lowat)" \
  'the default does not impose application backpressure'
# It stays an explicit experiment. 128 KiB beat 16 KiB, but neither was tested
# against the kernel default, and 128 KiB is only 0.75 ms at 1.4 Gbps.
NOTSENT_LOWAT=262144; tgt="$(target_sysctl 500 250)"
assert_eq '262144' "$(key net.ipv4.tcp_notsent_lowat)" \
  'an explicitly chosen allowance is applied exactly'
NOTSENT_LOWAT=0; tgt="$(target_sysctl 500 250)"
while IFS=$'\t' read -r k v dir why; do
  [[ -n "$k" && -n "$v" && -n "$why" ]] || fail "key $k is missing a value or a rationale"
  # A direction is one word, or one word per field for a tuple like tcp_rmem
  # whose fields are not the same kind of thing.
  [[ "$dir" =~ ^(exact|raise|lower)(,(exact|raise|lower))*$ ]] \
    || fail "key $k has no safe direction: [$dir]"
done <<< "$tgt"
pass 'every key carries a value, a direction and a rationale'

# ── 队列 ───────────────────────────────────────────────────────────────────
q="$(target_qdisc 500 250)"
# Current iproute2 has no `ecn` keyword for cake — the live node rejected the
# entire spec with: What is "ecn"? Mainline sch_cake marks ECN-capable packets
# by default, so there was never anything to switch on.
[[ "$q" != *" ecn"* ]] || fail 'cake takes no ecn keyword in current iproute2'
pass 'the cake spec carries no keyword current iproute2 would reject'
[[ "$q" == *"dual-dsthost"* ]] || fail 'host fairness is the whole point of shaping'
pass 'the qdisc asks for per-host fairness, not per-flow'
[[ "$q" == *"bandwidth 475000kbit"* ]] || fail 'the shaper must sit under the line rate'
pass 'the shaper sits under the provider line rate'
# CAKE targets 100ms by default. At that setting a 250ms client is marked long
# before its queue is actually standing, and reads that as congestion.
[[ "$q" == *"rtt 250ms"* ]] || fail 'the AQM target must follow the coverage RTT'
pass 'the AQM target follows the coverage RTT rather than CAKE default'
SHAPE=0
# Even unshaped, every flow is paced at the line rate. Without that a single BBR
# flow with a large window probes far past the link and whatever is downstream
# drops the overshoot — and BBRv1 does not read those drops as congestion, so it
# keeps producing them. netshape puts this under its shaper; shaping the
# aggregate is not a substitute for pacing the individual flow.
spec="$(target_qdisc 500 250)"
[[ "$spec" == fq* && "$spec" != *maxrate* ]] \
  || fail 'unshaped still paces each flow at the line rate'
pass 'unshaped still paces each flow at the line rate'
# The queue limits come from netshape-manager, whose author reports it
# saturating a port on a single thread. flow_limit is the one that matters:
# it is a PER-FLOW packet quota, so N flows each get their own 100 and the
# kernel default cannot hold back an aggregate transfer while it can hold back
# a single one. That is the exact shape of 558 Mbps on one thread against 917
# on several, same backend, seconds apart.
assert_eq 'fq limit 40960 flow_limit 8192' "$spec" \
  'the fq queue limits follow netshape rather than the kernel default'
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
assert_eq 'fq limit 10240 flow_limit 2048' "$(target_qdisc 500 250)" \
  'a box under 1 GB gets the smaller rung of that ladder'
# Still overridable, so it can be A/B'd back to the kernel values.
FQ_LIMIT=10000; FQ_FLOW_LIMIT=100
assert_eq 'fq limit 10000 flow_limit 100' "$(target_qdisc 500 250)" \
  'the ladder can be overridden back to the kernel defaults'
FQ_LIMIT=0; FQ_FLOW_LIMIT=0
total_ram_bytes() { printf '%s\n' $((8 * 1024 * 1024 * 1024)); }
SHAPE=1

# ── 方向安全 ───────────────────────────────────────────────────────────────
assert_eq '16777216' "$(safe_value 16777216 8388608 raise)" 'a ceiling already above target is left alone'
assert_eq '20000000' "$(safe_value 6291456 20000000 raise)" 'a ceiling below target is raised'
assert_eq '16384'    "$(safe_value 16384 131072 lower)"     'a value already tighter is left alone'
assert_eq 'bbr'      "$(safe_value cubic bbr exact)"        'an exact key takes the target as given'
# min/default/max do not share a direction: the middle field wants raising for
# a faster start while the ceiling may already be higher than we would ask for.
assert_eq '4096 131072 16777216' "$(safe_value '4096 87380 16777216' '4096 131072 8388608' raise)" \
  'a multi-value key merges field by field instead of overwriting the tuple'
needs_write '4096 87380 16777216' '4096 131072 8388608' raise \
  || fail 'a raisable middle field must still count'
pass 'a raisable field is acted on even when its siblings are fine'
if needs_write 16777216 8388608 raise; then fail 'an adequate ceiling must not be flagged'; fi
pass 'an adequate ceiling is not flagged'

# ── 默认路由安全 ───────────────────────────────────────────────────────────
# A wrong edit to the default route costs the session, so anything we cannot
# put back exactly is refused.
ip() { printf 'default via 10.0.0.1 dev eth0 proto static\n'; }
route_is_simple "$(current_default_route)" || fail 'a single plain default route is editable'
pass 'a single plain default route is editable'
# initrwnd travels with initcwnd, following netshape. A relay is not only a
# sender: it pulls from an upstream backend and forwards, and the initial
# RECEIVE window governs how fast that upstream leg ramps. Setting only
# initcwnd left half of every connection starting from the kernel default.
assert_eq 'default via 10.0.0.1 dev eth0 proto static initcwnd 20 initrwnd 20' \
  "$(route_with_initcwnd "$(current_default_route)" 20)" 'initcwnd is appended to the existing route'
# Re-applying must not stack a second initcwnd or initrwnd onto the line.
assert_eq 'default via 10.0.0.1 dev eth0 proto static initcwnd 32 initrwnd 32' \
  "$(route_with_initcwnd 'default via 10.0.0.1 dev eth0 proto static initcwnd 20' 32)" \
  'reapplying replaces the metric instead of appending a second one'
ip() { printf 'default proto static nhid 42\n'; }
if route_is_simple "$(current_default_route)"; then fail 'a multipath default must be refused'; fi
pass 'an ECMP default route is refused rather than pinned to one nexthop'
ip() { printf 'default via 10.0.0.1 dev eth0\ndefault via 10.0.0.2 dev eth1\n'; }
if route_is_simple "$(current_default_route)"; then fail 'two default routes must be refused'; fi
pass 'more than one default route is refused'
unset -f ip

# ── 冲突检测 ───────────────────────────────────────────────────────────────
# Two tools driving one machine-wide setting is not a merge; it is whichever
# ran last.
if conflicting_tool >/dev/null 2>&1; then pass 'a conflicting tool is reported when present'
else pass 'no conflicting tool on this host'; fi

# ── 整形必须知道带宽 ───────────────────────────────────────────────────────
LINK_MBPS=""
if ( SHAPE=1; require_egress ) 2>/dev/null; then
  fail 'shaping without a bandwidth figure must be refused'
fi
pass 'shaping refuses to guess the line rate'
if ! ( SHAPE=0; LINK_MBPS=""; target_qdisc 200 250 >/dev/null ) 2>/dev/null; then
  fail 'no-shape mode must work without a bandwidth figure'
fi
pass 'no-shape mode needs no bandwidth figure'


# ── 0.2.0 配置持久化 ───────────────────────────────────────────────────────
tmp="$(mktemp -d)"; CONFIG_FILE="$tmp/tcpwide.conf"
LINK_MBPS=750; COVER_RTT_MS=300; INITCWND=32; SHAPE_PCT=90
SHAPE=1; PERSIST=1; PROFILE=stable; IFACE=ens3
save_config
LINK_MBPS=1; COVER_RTT_MS=10; INITCWND=1; SHAPE_PCT=50
SHAPE=0; PERSIST=0; PROFILE=balanced; IFACE=lo
load_config
assert_eq '750'    "$LINK_MBPS"  'the port speed survives a config round trip'
assert_eq '300'    "$COVER_RTT_MS" 'coverage RTT survives a config round trip'
assert_eq '32'     "$INITCWND"     'initcwnd survives a config round trip'
assert_eq '90'     "$SHAPE_PCT"    'shaping percentage survives a config round trip'
assert_eq '1'      "$PERSIST"      'the persistence flag survives a config round trip'
assert_eq 'stable' "$PROFILE"      'the profile survives a config round trip'
assert_eq 'ens3'   "$IFACE"        'the interface survives a config round trip'

# A junk value must be ignored without clobbering the in-memory default, and —
# the trap netshape documents — a rejected value on the FINAL line leaves the
# read loop non-zero, which under errexit would take the whole script down.
printf 'COVER_RTT_MS=99999\nINITCWND=abc\n' > "$CONFIG_FILE"
COVER_RTT_MS=250; INITCWND=20
load_config || fail 'load_config must return 0 even when the last line is rejected'
assert_eq '250' "$COVER_RTT_MS" 'an out-of-range value is ignored, not adopted'
assert_eq '20'  "$INITCWND"     'a non-numeric value is ignored, not adopted'
pass 'a rejected value on the final line does not abort under errexit'
rm -rf "$tmp"

# ── 0.2.0 档位 ─────────────────────────────────────────────────────────────
# Throughput profiles now own the warm-start value as well; assert every field
# so switching profiles cannot accidentally retain a previous memory policy.
apply_profile stable
assert_eq '90|16|0|1' "$SHAPE_PCT|$INITCWND|$BUF_DEFAULT|$SHAPE" \
  'the stable profile trades peak for headroom without warm-start memory'
apply_profile balanced
assert_eq '95|20|0|1' "$SHAPE_PCT|$INITCWND|$BUF_DEFAULT|$SHAPE" \
  'the balanced profile keeps the system buffer start'
apply_profile speed
assert_eq '98|64|1048576|1' "$SHAPE_PCT|$INITCWND|$BUF_DEFAULT|$SHAPE" \
  'the high-throughput shaped profile gets a warm start'
speed_tgt="$(target_sysctl 2000 150)"
assert_eq '1048576' "$(awk -F'\t' '$1 == "net.ipv4.tcp_rmem" {split($2,v," "); print v[2]}' <<< "$speed_tgt")" \
  'the warm receive start reaches the applied tuple'
assert_eq '1048576' "$(awk -F'\t' '$1 == "net.ipv4.tcp_wmem" {split($2,v," "); print v[2]}' <<< "$speed_tgt")" \
  'the warm send start reaches the applied tuple'
apply_profile noshape
assert_eq '0' "$SHAPE" 'the no-shape profile stops shaping'
assert_eq '64|1048576' "$INITCWND|$BUF_DEFAULT" \
  'the no-shape profile warms both startup controls'
[[ "$(target_qdisc 500 250)" == fq* && "$(target_qdisc 500 250)" != *maxrate* ]] \
  || fail 'the no-shape profile yields paced fq, not cake'
pass 'the no-shape profile yields paced fq, not cake'
if apply_profile nonsense 2>/dev/null; then fail 'an unknown profile must be rejected'; fi
pass 'an unknown profile is rejected'
apply_profile balanced

# ── 0.2.0 面板与应用同源 ───────────────────────────────────────────────────
# The panel, the preview and the apply path must all read the same target
# functions, or the panel will confidently report a configuration that is not
# the one being written.
available_cc() { printf 'reno cubic bbr\n'; }
total_ram_bytes() { printf '%s\n' $((958 * 1024 * 1024)); }
assert_eq "$(buffer_ceiling 500 250)" \
  "$(target_sysctl 500 250 | awk -F'\t' '$1 == "net.core.rmem_max" {print $2}')" \
  'the ceiling the panel shows is the one the apply path writes'

# ── 0.2.0 队列漂移 ─────────────────────────────────────────────────────────
# A box that rebooted, or that another tool touched, is the normal case. A panel
# that cannot see the difference reports a configuration that is not running.
IFACE=eth0; LINK_MBPS=500; COVER_RTT_MS=250; SHAPE=1
tc() { printf 'qdisc mq 0: root \n'; }
# The reported string is now the canonical live spec rather than the bare kind:
# "mq with no leaves" tells the operator what is wrong, "mq" only tells them
# something is.
assert_eq 'mq ← （没有叶子）' "$(qdisc_drift)" \
  'a live mq root against a cake config reports drift, and says what it found'
# The mocks below are full `tc qdisc show` lines, not abbreviations. They have
# to be: since 0.24.0 the drift check compares the whole spec, and a mock that
# omits the fields tc really prints would pass for the wrong reason -- which is
# exactly how three guards missed a live `maxrate 1960Mbit` for a whole release.
tc() { printf 'qdisc cake 8001: root refcnt 2 bandwidth 475Mbit besteffort dual-dsthost nonat nowash no-ack-filter split-gso rtt 250ms raw overhead 0\n'; }
if qdisc_drift >/dev/null 2>&1; then fail 'a matching qdisc must not report drift'; fi
pass 'a matching qdisc reports no drift'
# tc prints defaults nobody asked for (buckets, quantum, orphan_mask). Those
# must not read as drift, or the panel cries wolf on every correct apply.
SHAPE=0
tc() { printf 'qdisc fq 8001: root refcnt 2 limit 10240p flow_limit 2048p buckets 1024 orphan_mask 1023 quantum 3028b initial_quantum 15140b low_rate_threshold 550Kbit refill_delay 40ms\n'; }
if qdisc_drift >/dev/null 2>&1; then fail 'fq matches the no-shape target'; fi
pass "fq matches the no-shape target, and tc's own defaults are not drift"

# ── 0.24.0 队列漂移必须看见残留的 maxrate ──────────────────────────────────
# The bug this release exists for. `tc qdisc replace` over a same-kind qdisc
# only CHANGES the parameters it was given, so 0.23.0's `replace ... root fq
# limit 10240 flow_limit 2048` left the previous release's per-flow cap running.
# Both read-back guards compared only the qdisc kind -- fq against fq -- so the
# panel printed 队列与配置一致 while a 1960 Mbit cap sat on the interface.
tc() { printf 'qdisc fq 8006: root refcnt 2 limit 10240p flow_limit 2048p buckets 1024 orphan_mask 1023 quantum 3028b initial_quantum 15140b maxrate 1960Mbit low_rate_threshold 550Kbit\n'; }
drift="$(qdisc_drift)" || fail 'a stale per-flow cap must be reported as drift'
[[ "$drift" == *maxrate* ]] || fail "the drift report must name what it found: [$drift]"
pass 'a rate ceiling the target never asked for is drift'
# And the read-back at apply time has to say the same thing.
live_qdisc_layout() { printf 'fq 8006: root refcnt 2 limit 10240p flow_limit 2048p maxrate 1960Mbit\n'; }
out="$(report_live_qdisc 'fq limit 10240 flow_limit 2048' 2>&1)"
[[ "$out" == *"回读与目标不符"* ]] \
  || fail 'the read-back must not accept a queue carrying a cap it did not ask for'
pass 'the apply-time read-back compares the whole spec, not just the kind'
unset -f live_qdisc_layout
SHAPE=1
unset -f tc

# ── 0.2.0 默认路由空白归一 ─────────────────────────────────────────────────
# `ip route show` emits a trailing space on some route types (onlink is one),
# which produced "... onlink  initcwnd 20" with a doubled space on the live box.
assert_eq 'default via 193.41.250.250 dev eth0 onlink initcwnd 20 initrwnd 20' \
  "$(route_with_initcwnd 'default via 193.41.250.250 dev eth0 onlink ' 20)" \
  'a trailing space in the route does not produce a doubled separator'
# Re-applying must replace the metric, never stack a second one.
assert_eq 'default via 10.0.0.1 dev eth0 initcwnd 32 initrwnd 32' \
  "$(route_with_initcwnd 'default via 10.0.0.1 dev eth0 initcwnd 20' 32)" \
  'reapplying replaces the metric rather than appending another'

# ── 0.2.0 面板渲染不会中途崩 ───────────────────────────────────────────────
# A default route carrying no initcwnd makes a naive grep exit 1, and under
# pipefail that took the panel down mid-render instead of showing the default.
ip() { printf 'default via 10.0.0.1 dev eth0 onlink \n'; }
tc() { printf 'qdisc mq 0: root \n'; }
sysctl() {
  case "${1:-}" in
    -n) case "${2:-}" in
          *available*) printf 'reno cubic bbr\n' ;;
          net.ipv4.tcp_mem) printf '42039\t56054\t84078\n' ;;
          *) printf '\n' ;;
        esac ;;
  esac
}
has() { [[ "$1" == sysctl || "$1" == tc || "$1" == ip ]]; }
conflicting_tool() { return 1; }
PERSIST_SYSCTL="/nonexistent/tcpwide.conf"
render_panel >/dev/null 2>&1 || fail 'the panel must render on a route without initcwnd'
pass 'the panel renders on a default route that has no initcwnd yet'
[[ "$(render_panel 2>/dev/null)" == *"队列实际是"*mq* ]] \
  || fail 'the panel must warn when the live qdisc differs from the config'
pass 'the panel warns about a drifted qdisc'

# ── 0.22.0 面板宽度 ────────────────────────────────────────────────────────
# The panel reached 37 lines and 147 columns by accretion -- one explanatory
# sentence at a time, each of them reasonable on its own. Nothing but a hard
# assertion stops that happening again, so the width and the line count are
# tests, not a style preference. 72 columns is the narrowest phone SSH client
# worth designing for; anything wider wraps and the whole layout collapses.
panel_widths() {
  render_panel 2>/dev/null | python3 -c '
import re, sys, unicodedata
worst = 0
lines = sys.stdin.read().rstrip("\n").split("\n")
for line in lines:
    line = re.sub(r"\x1b\[[0-9;]*m", "", line)
    w = sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in line)
    worst = max(worst, w)
print(worst, len(lines))
'
}
if command -v python3 >/dev/null 2>&1; then
  IFS=' ' read -r panel_cols_max panel_lines <<< "$(panel_widths)"
  (( panel_cols_max <= 72 )) \
    || fail "every panel line must fit 72 columns, widest is $panel_cols_max"
  pass "the panel fits 72 columns (widest line $panel_cols_max)"
  (( panel_lines <= 24 )) \
    || fail "the panel must fit one screen, it is $panel_lines lines"
  pass "the panel fits one screen ($panel_lines lines)"
else
  pass 'panel width check skipped, no python3'
fi

# The fingerprint is a single joined string meant to be pasted next to a
# speedtest screenshot. On the panel it was 146 columns of restating the status
# block above it; it belongs in `status` and `record`, which is where it is
# actually copied out of.
[[ "$(render_panel 2>/dev/null)" != *"｜ cover "* ]] \
  || fail 'the configuration fingerprint must not be on the panel'
pass 'the fingerprint stays in status and record, off the panel'

# Every key the panel offers has to be explained somewhere, or the explanations
# were not moved off the menu, they were lost.
panel_menu_keys() {
  render_panel 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -E '^  [ >][0-9a-z] ' \
    | grep -oE '[ >][0-9a-z] ' \
    | sed 's/^[ >]//; s/ $//' | sort -u
}
help_text="$(panel_help 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
while read -r key; do
  [[ -n "$key" ]] || continue
  [[ "$help_text" == *$'\n'"    $key "* ]] \
    || fail "panel key [$key] has no entry in the help page"
done <<< "$(panel_menu_keys)"
pass 'every panel key is explained on the help page'
unset -f ip tc sysctl has conflicting_tool panel_widths panel_menu_keys
restore_lib


# ── 0.2.1 覆盖 RTT 的实测 ──────────────────────────────────────────────────
# The coverage RTT is the one number an operator cannot infer from their own
# latency: it is a property of the farthest client, not of the console they are
# typing into. So it gets measured rather than estimated.
has() { [[ "$1" == ss ]]; }
ss() {
  case "$1" in
    -tlnH) printf 'LISTEN 0 128 0.0.0.0:8096 0.0.0.0:*\n' ;;
    -tinH) cat <<'SS'
ESTAB 0 0 10.0.0.1:8096 119.237.129.39:51234
	 bbr rtt:146.5/2.2 data_segs_out:5000 minrtt:145.5
ESTAB 0 0 10.0.0.1:8096 223.153.241.126:44000
	 bbr rtt:277.4/30.1 data_segs_out:9000 minrtt:163.8
ESTAB 0 0 10.0.0.1:51999 104.21.67.144:443
	 bbr rtt:900.0/2.0 data_segs_out:900000 minrtt:1.0
ESTAB 0 0 10.0.0.1:8096 198.51.100.7:33333
	 bbr rtt:500.0/2.0 data_segs_out:0 minrtt:499.0
SS
    ;;
  esac
}
row="$(observed_client_rtt)"
# A relay opens its own connections outward to CDNs and origins. At 900ms that
# outbound socket would dominate the sizing, and it is not a client.
assert_eq '277' "$(printf '%s' "$row" | cut -f1)" \
  'an outbound connection does not set the coverage RTT'
# An idle socket carries a stale rtt field that is not a path sample.
assert_eq '2' "$(printf '%s' "$row" | cut -f2)" \
  'a socket that has sent nothing is not counted as a client'
assert_eq '350' "$(suggest_cover_rtt | cut -f1)" \
  'the suggestion rounds the measurement up with headroom for variable links'
# No inbound traffic at all means no measurement — not a confident default.
ss() { case "$1" in -tlnH) printf 'LISTEN 0 128 0.0.0.0:8096 0.0.0.0:*\n' ;; -tinH) : ;; esac; }
if suggest_cover_rtt >/dev/null 2>&1; then fail 'with no active clients there is nothing to measure'; fi
pass 'no active clients yields no suggestion rather than a made-up number'
unset -f ss has

# ── 0.2.1 输入防呆 ─────────────────────────────────────────────────────────
# A terminal sending CRLF, or a pasted line with trailing spaces, would fail the
# numeric test for a reason the operator cannot see on screen.
assert_eq '500' "$(printf '\r\n' | prompt_uint 'x' 500 1 100000 2>/dev/null)" \
  'a bare carriage return still takes the default'
assert_eq '750' "$(printf '  750  \n' | prompt_uint 'x' 500 1 100000 2>/dev/null)" \
  'surrounding whitespace is trimmed rather than rejected'
assert_eq '500' "$(printf '\n' | prompt_uint 'x' 500 1 100000 2>/dev/null)" \
  'an empty line takes the default'
if printf 'q\n' | prompt_uint 'x' 500 1 100000 >/dev/null 2>&1; then
  fail 'q must cancel'
fi
pass 'q cancels the prompt'


# ── 0.3.0 全局 TCP 预算 ────────────────────────────────────────────────────
total_ram_bytes() { printf '%s\n' $((958 * 1024 * 1024)); }
# The script runs under IFS=$'\n\t', so a default read would keep the three
# space-separated thresholds as one field.
IFS=' ' read -r tm_low tm_pres tm_max <<< "$(target_tcp_mem)"
# 1/16, 1/8, 1/4 of RAM in pages, following tcpfit.
test_page_size="$(getconf PAGESIZE 2>/dev/null || printf 4096)"
expected_tm_max=$((958 * 1024 * 1024 / test_page_size / 4))
(( expected_tm_max < 16384 )) && expected_tm_max=16384
assert_eq "$expected_tm_max" "$tm_max" \
  'the global budget cap is a quarter of RAM in pages'
[[ "$tm_low" -lt "$tm_pres" && "$tm_pres" -lt "$tm_max" ]] \
  || fail 'the three tcp_mem thresholds must be ordered'
pass 'the tcp_mem thresholds are ordered low < pressure < max'
# One socket takes at most a quarter of the budget, so four large flows still
# fit before the kernel starts shrinking everyone. 0.16.0 briefly halved that
# divisor to make room for a 4x multiplier; the multiplier is withdrawn and the
# extra headroom measured identically on the box it was meant to help, so
# handing one connection half the budget on a 520 MB box bought nothing.
buf="$(buffer_ceiling 500 250)"
(( buf * 4 <= tm_max * test_page_size )) \
  || fail 'the ceiling must leave room for four flows inside the global budget'
pass 'four flows at the ceiling fit inside the global budget'

# ── 0.3.0 整形的 CPU 代价 ──────────────────────────────────────────────────
# CAKE funnels the whole egress through one qdisc and does per-packet work. On a
# small VPS that can cost more than the policer it replaces, and the operator
# needs to know before choosing, not after a slow speedtest.
SHAPE=1
cpu_count() { printf '1\n'; }
[[ -n "$(shaping_cpu_warning 1000)" ]] || fail 'one core shaping a gigabit must warn'
pass 'shaping well past one core of headroom warns'
if shaping_cpu_warning 200 >/dev/null 2>&1; then fail '200 Mbps on one core needs no warning'; fi
pass 'a modest rate on one core does not warn'
# The threshold was raised 400 -> 600 because a 2-core 0.5 GB box can push
# 2 Gbps. True, and about the PORT -- not about CAKE's per-packet cost. That
# conflation removed the warning for exactly this combination, and the box then
# ran `cake bandwidth 980Mbit` at 332 Mbps peak where `fq` gave it 629.
cpu_count() { printf '2\n'; }
[[ -n "$(shaping_cpu_warning 1000)" ]] || fail 'two cores cannot shape a gigabit and must say so'
pass 'two cores shaping a gigabit warns, as the measurement demands'
cpu_count() { printf '4\n'; }
if shaping_cpu_warning 500 >/dev/null 2>&1; then fail 'four cores at 500 Mbps needs no warning'; fi
pass 'enough cores means no shaping warning'
SHAPE=0
cpu_count() { printf '1\n'; }
if shaping_cpu_warning 5000 >/dev/null 2>&1; then fail 'no-shape mode has no shaping cost'; fi
pass 'no-shape mode never warns about shaping CPU'
SHAPE=1
unset -f cpu_count


# ── 0.3.3 多词参数必须真的分词 ─────────────────────────────────────────────
# The script runs under IFS=$'\n\t'. Unquoted expansion therefore does NOT
# split on spaces, so `tc ... root $want_q` handed the entire eight-word CAKE
# spec to tc as ONE argument and the qdisc silently never applied — every run
# on the live node was sysctl-only while the panel reported drift.
SHAPE=1; SHAPE_PCT=95; IFACE=eth0
# Enough cores that CAKE fits, so this is the base spec without no-split-gso.
cpu_count() { printf '8\n'; }
split_words "$(target_qdisc 500 250)"
assert_eq '7' "${#SPLIT_WORDS[@]}" 'the CAKE spec splits into its individual arguments'
assert_eq 'cake' "${SPLIT_WORDS[0]}" 'the first argument is the qdisc name, not the whole spec'
assert_eq '250ms' "${SPLIT_WORDS[6]}" 'the last argument survives the split'
# split-gso is CAKE's dominant per-packet cost: one 64KB superpacket becomes ~44
# MTU packets so each can be paced. A box that cannot shape its port gets it
# turned off, which is the only way it keeps per-host fairness AND speed.
cpu_count() { printf '2\n'; }
split_words "$(target_qdisc 1000 250)"
assert_eq '8' "${#SPLIT_WORDS[@]}" 'a CPU-tight box gets one extra CAKE option'
assert_eq 'no-split-gso' "${SPLIT_WORDS[7]}" 'and that option is no-split-gso'
cpu_count() { printf '8\n'; }
split_words "$(target_qdisc 1000 250)"
assert_eq '7' "${#SPLIT_WORDS[@]}" 'a box with cores to spare keeps precise pacing'
split_words 'default via 10.0.0.1 dev eth0 onlink initcwnd 20'
assert_eq '8' "${#SPLIT_WORDS[@]}" 'a route spec splits into its individual arguments'

# End to end: the words must reach the command, not just the helper.
argc_file="$(mktemp)"
# Every call is recorded, not just the last: apply_link also reads the layout
# back after writing it, and a mock that keeps only the final call would report
# the read rather than the write.
tc() { printf '%s\n' "$#" >> "$argc_file"; return 0; }
ip() { printf 'default via 10.0.0.1 dev eth0\n'; }
has() { [[ "$1" == tc || "$1" == ip ]]; }
QDISC_SNAP="$(mktemp -d)/qdisc"; ROUTE_SNAP="$(mktemp -d)/route"
apply_link 500 250 >/dev/null 2>&1 || true
# qdisc replace dev eth0 root + 7 spec words = 12
grep -qx '12' "$argc_file" || fail 'tc receives the qdisc spec as separate arguments'
pass 'tc receives the qdisc spec as separate arguments'
rm -f "$argc_file"
unset -f tc ip has


# ── 0.3.4 内存夹子生效点要说出来 ───────────────────────────────────────────
# On a 958 MB box at 500 Mbps the RAM/32 clamp binds at 234ms, so the cost table
# printed identical ceilings for 250 and 400 and read as "it makes no
# difference" — when it actually means the clamp is already binding.
# The 520 MB box with a gigabit port: 1000 Mbps needs 61.6 MB at 250ms and
# 97 MB at 400ms, and the budget allows 32.5 MB, so both clamp to the same
# figure and a wider coverage RTT buys nothing.
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
assert_eq "$(buffer_ceiling 1000 250)" "$(buffer_ceiling 1000 400)" \
  'past the clamp a wider coverage RTT buys nothing'
has() { [[ "$1" == sysctl ]]; }
sysctl() { [[ "$2" == net.ipv4.tcp_mem ]] && printf '8330\t16661\t33323\n'; }
suggest_cover_rtt() { printf '250\t177\t9\n'; }
out="$(explain_cover_rtt 1000 2>&1)"
[[ "$out" == *"已被内存夹住"* ]] || fail 'a clamped row must be marked as clamped'
pass 'a clamped row in the cost table is marked'
[[ "$out" == *"不会再增加缓冲"* ]] \
  || fail 'the point where the clamp starts binding must be named'
[[ "$out" == *"全局 TCP 预算的 1/4"* ]] \
  || fail 'the binding rule must name itself'
pass 'the binding rule explains which rule it is'
pass 'the coverage RTT past which nothing changes is stated outright'
# A box with room to spare must not claim a clamp it is nowhere near.
total_ram_bytes() { printf '%s\n' $((32 * 1024 * 1024 * 1024)); }
out="$(explain_cover_rtt 100 2>&1)"
[[ "$out" != *"已被内存夹住"* ]] || fail 'an unclamped box must not be told it is clamped'
pass 'a box with memory to spare reports no clamp'
unset -f has sysctl suggest_cover_rtt total_ram_bytes


# ── 0.3.5 被拒的 CAKE 选项要指名道姓 ───────────────────────────────────────
# The live node refused the full spec while accepting plain fq, so the useful
# question is which option was refused: a kernel can carry sch_cake while the
# local tc does not know a keyword, and the reverse happens too.
has() { [[ "$1" == tc ]]; }
tc() { local IFS=' '; case "$*" in *dual-dsthost*) return 1 ;; *) return 0 ;; esac; }
assert_eq 'cake bandwidth 490000kbit dual-dsthost' \
  "$(probe_cake_options 'cake bandwidth 490000kbit dual-dsthost besteffort rtt 250ms')" \
  'the probe names the option that starts failing'
# A value-taking option is only testable once its value is in, or the probe
# would blame "bandwidth" for an incomplete pair.
tc() { local IFS=' '; case "$*" in *"rtt 250ms"*) return 1 ;; *) return 0 ;; esac; }
assert_eq 'cake bandwidth 490000kbit dual-dsthost besteffort rtt 250ms' \
  "$(probe_cake_options 'cake bandwidth 490000kbit dual-dsthost besteffort rtt 250ms')" \
  'an option that takes a value is tested with its value attached'
# Nothing to report when every option is accepted.
tc() { return 0; }
if probe_cake_options 'cake bandwidth 100kbit ecn' >/dev/null 2>&1; then
  fail 'a fully accepted spec must report no offending option'
fi
pass 'a fully accepted spec reports nothing'
unset -f tc has


# ── 0.3.7 不做 BBR 版本考据 ────────────────────────────────────────────────
# 0.22.0 dropped it. Reaching a newer BBR means replacing the kernel on a box
# that is serving traffic, which is not something a tuning script should be
# walking anyone through -- and the panel was carrying a whole page of kernel
# archaeology to support an option nobody was going to take. pick_cc still
# picks bbr3 or bbr2 when the kernel already offers them: that is a selection,
# not a switch, and it costs nothing.
for gone in explain_bbr3 bbr_variant bbr_variant_note; do
  grep -q "$gone" "$ROOT/tcpwide.sh" \
    && fail "$gone should have been removed in 0.22.0"
done
grep -qi xanmod "$ROOT/tcpwide.sh" && fail 'the kernel-swap instructions should be gone'
pass 'no kernel-version archaeology and no kernel-swap instructions'
assert_eq bbr "$(pick_cc 'reno cubic bbr')" 'a stock kernel still gets bbr'
assert_eq bbr3 "$(pick_cc 'reno cubic bbr bbr3')" 'and a kernel that offers bbr3 still gets it'

# The single-flow submenu's numbering has to stay contiguous. A menu that reads
# 1 2 3 5 is how an operator ends up pressing 4 and getting the wrong knob.
submenu_keys="$(sed -n '/^panel_single_flow()/,/^}/p' "$ROOT/tcpwide.sh" \
  | grep -oE "%b[0-9]\)%b" | grep -oE '[0-9]' | sort -u | tr -d '\n')"
assert_eq 012345 "$submenu_keys" 'the single-flow submenu is numbered 1-5 with no gap'


# ── 0.4.0 对端窗口决定的单流上限 ───────────────────────────────────────────
# A single flow can never exceed the peer's advertised window divided by the
# round trip, and nothing on this machine changes that number. On the live node
# the fastest flow peaked at 427.79 Mbps at 171ms — which is exactly what an
# 8.72 MB peer window permits, so the shortfall against the 500 Mbps line was
# never server-side.
has() { [[ "$1" == ss ]]; }
ss() {
  case "$1" in
    -tlnH) printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n' ;;
    -tinH) cat <<'SS'
ESTAB 0 0 10.0.0.1:443 203.0.113.9:51234
	 bbr rtt:171.0/8.0 snd_wnd:9143255 delivery_rate 427.8Mbps data_segs_out:99999
ESTAB 0 0 10.0.0.1:443 203.0.113.10:44000
	 bbr rtt:20.0/2.0 snd_wnd:262144 delivery_rate 90.0Mbps data_segs_out:5000
ESTAB 0 0 10.0.0.1:51999 104.21.67.144:443
	 bbr rtt:5.0/1.0 snd_wnd:99999999 delivery_rate 9000.0Mbps data_segs_out:99999
SS
    ;;
  esac
}
win="$(peer_window_ceiling)"
assert_eq '203.0.113.9' "$(printf '%s' "$win" | cut -f1)" \
  'the ceiling is reported for the fastest inbound flow'
assert_eq '427.8' "$(printf '%s' "$win" | cut -f4)" \
  'the ceiling is the peer window divided by the round trip'
assert_eq '427.8' "$(printf '%s' "$win" | cut -f5)" \
  'the observed rate is reported alongside so the two can be compared'
# An outbound connection to a CDN is not a client and must not be picked, even
# though it is by far the fastest thing on the box.
[[ "$(printf '%s' "$win" | cut -f1)" != "104.21.67.144" ]] \
  || fail 'an outbound connection must never set the reported ceiling'
pass 'an outbound connection is excluded from the ceiling report'
ss() { case "$1" in -tlnH) printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n' ;; -tinH) : ;; esac; }
if peer_window_ceiling >/dev/null 2>&1; then fail 'no flows means no ceiling to report'; fi
pass 'with no active flows there is no ceiling to report'
unset -f ss has


# ── 0.6.0 缓冲上限可手动覆盖 ───────────────────────────────────────────────
# The RAM ladder is derived from memory alone and ignores RTT. 16 MB with
# tcp_adv_win_scale=1 advertises an 8 MB receive window, capping an incoming
# transfer at 419 Mbps on a 160ms path — and the live node measured a 421 Mbps
# peak there. Overriding it is how that gets tested one variable at a time.
total_ram_bytes() { printf '%s\n' $((958 * 1024 * 1024)); }
BUF_MB=0
assert_eq "$((500 * 125 * 250 * 2 + 2 * 1024 * 1024))" "$(buffer_ceiling 500 250)" \
  'auto derives from the envelope when the budget has room'
BUF_MB=32
# The override must skip the ladder, or testing the ladder would be impossible.
assert_eq "$((32 * 1024 * 1024))" "$(buffer_ceiling 1000 400)" \
  'an explicit ceiling is not clamped back by the rule it exists to test'
assert_eq "$((32 * 1024 * 1024))" "$(buffer_ceiling 10 10)" \
  'an explicit ceiling ignores the derivation entirely'
BUF_MB=0

# ── 0.6.0 档位必须自成一体 ─────────────────────────────────────────────────
# Picking 速度优先 then 不整形 left SHAPE_PCT at 98, so "不整形" meant different
# things depending on what had been chosen before it.
apply_profile speed
apply_profile noshape
assert_eq '98|64|1048576|0' "$SHAPE_PCT|$INITCWND|$BUF_DEFAULT|$SHAPE" \
  'the no-shape profile sets every value it depends on'
apply_profile stable
apply_profile noshape
assert_eq '98|64|1048576|0' "$SHAPE_PCT|$INITCWND|$BUF_DEFAULT|$SHAPE" \
  'and does so regardless of what preceded it'
apply_profile balanced


# ── 0.7.0 目标不等于现值 ───────────────────────────────────────────────────
# raise refuses to lower, so a SMALLER target is silently never written. The
# live node ran at 31.4 MB the whole time while every panel printed the 16 MB
# ladder target as though it were the running value — and an entire round of
# analysis was built on that number.
assert_eq '31391744' "$(safe_value 31391744 16777216 raise)" \
  'a smaller target under raise leaves the live value alone'
if needs_write 31391744 16777216 raise; then
  fail 'lowering under raise must not be reported as a pending change'
fi
pass 'a smaller target under raise is correctly a no-op'

# The apply loop reports its count through a variable. It used to echo the count
# on stdout and the caller captured it, which threw away every progress line
# with it, so an apply that wrote nine keys looked like it wrote none.
tmp="$(mktemp -d)"; SYSCTL_SNAP="$tmp/snap"
writes="$tmp/w"; : > "$writes"
sysctl() {
  case "${1:-}" in
    -qw|-w) printf '%s\n' "$2" >> "$writes"; return 0 ;;
    -n) case "${2:-}" in *available*) printf 'reno cubic bbr\n' ;; *) printf '\n' ;; esac ;;
  esac
}
has() { [[ "$1" == sysctl ]]; }
total_ram_bytes() { printf '%s\n' $((958 * 1024 * 1024)); }
# A redirect, not a command substitution: the latter is a subshell and would
# lose SYSCTL_WROTE — which is the very thing that made the old design lose the
# progress lines.
apply_sysctl 500 250 > "$tmp/out" 2>&1
[[ "$(cat "$tmp/out")" == *"[写]"* ]] || fail 'apply must show what it wrote'
pass 'the apply loop prints each key it writes'
(( SYSCTL_WROTE > 0 )) || fail 'the count must come back to the caller'
assert_eq "$(grep -c '' < "$writes")" "$SYSCTL_WROTE" \
  'the reported count matches the keys actually written'
rm -rf "$tmp"
unset -f sysctl has total_ram_bytes


# ── 0.8.0 一键安装 ─────────────────────────────────────────────────────────
# Run as `bash <(curl ...)`, BASH_SOURCE points at a pipe under /dev/fd that
# bash is still reading, so copying it yields a truncated install. Piped into
# bash it is empty entirely. Both must end up with a real file.
tmp="$(mktemp -d)"
assert_eq "$ROOT/tcpwide.sh" "$(self_source)" \
  'run from a real file, that file is what gets installed'
# Simulate the pipe case: no BASH_SOURCE, fetch instead.
(
  SOURCE_URL="file://$ROOT/tcpwide.sh"
  self_source() {
    local src="" out
    if [[ -n "$src" && -f "$src" ]]; then printf '%s\n' "$src"; return 0; fi
    out="$tmp/fetched"; cp "$ROOT/tcpwide.sh" "$out"
    # A failed fetch that still writes something must never be installed.
    grep -q '^PROGRAM="tcpwide"' "$out" || { rm -f "$out"; return 1; }
    printf '%s\n' "$out"
  }
  f="$(self_source)"
  if [[ ! -f "$f" || "$(head -1 "$f")" != '#!/usr/bin/env bash' ]]; then
    fail 'the fetched copy must be a complete script'
  fi
)
pass 'without a real BASH_SOURCE a complete copy is fetched instead'
# A truncated or error-page download must be rejected rather than installed.
printf 'not the script\n' > "$tmp/junk"
if grep -q '^PROGRAM="tcpwide"' "$tmp/junk"; then fail 'junk must not pass the sanity check'; fi
pass 'a download that is not the script is rejected'
rm -rf "$tmp"

# Piped into bash, stdin IS the script: a prompt would read the next line of
# source as the operator's answer, so every value has to come from flags.
LINK_MBPS=""
out="$( ( need_root() { :; }; cmd_install ) < /dev/null 2>&1 )" || true
[[ "$out" == *"非交互安装需要 --egress"* ]] \
  || fail 'a non-interactive install without an egress figure must say so'
# The suggested wizard form must be one that survives sudo. `sudo bash <(curl …)`
# does not: sudo closes descriptors above 2, so the /dev/fd entry the process
# substitution created in the outer shell is gone before bash opens it.
[[ "$out" == *"-o /tmp/tcpwide.sh"* ]] || fail 'and must name a wizard form that works under sudo'
[[ "$out" != *"bash <(curl"* ]] || fail 'must not suggest a form sudo breaks'
pass 'a non-interactive install demands its parameters and names the wizard form'
LINK_MBPS=500


# ── 0.9.0 内存不够时要明说，不能默默封顶 ───────────────────────────────────
# 520 MB with a gigabit port cannot satisfy both a full-rate single flow at
# 250ms (61.6 MB of ceiling) and room for concurrent flows. Capping silently is
# how that becomes a mystery instead of a choice the operator made.
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
has() { [[ "$1" == sysctl ]]; }
sysctl() { [[ "$2" == net.ipv4.tcp_mem ]] && printf '8330\t16661\t33323\n'; }
suggest_cover_rtt() { printf '250\t177\t9\n'; }
COVER_RTT_MS=250
out="$(explain_cover_rtt 1000 2>&1)"
[[ "$out" == *"本该要"* ]] || fail 'a shortfall must name the ceiling the link needed'
[[ "$out" == *"单流因此封顶在约"* ]] || fail 'and the single-flow rate it leaves'
[[ "$out" == *"二选一"* ]] || fail 'and that it is a trade, not a misconfiguration'
pass 'a memory shortfall is stated with its cost rather than applied silently'
# The figure is only as honest as the RTT it was computed at, and filling in a
# worst case far above the real client population invents a shortfall that
# exists on no path the machine serves. That is precisely how this box got
# declared a 545 Mbps box while clearing a gigabit at 150ms, so the caveat
# travels with the number.
[[ "$out" == *"先确认"* ]] || fail 'a shortfall must name the RTT assumption it rests on'
pass 'the shortfall states which coverage RTT produced it'
# Being clamped is not being short. At 176ms the trimmed ceiling still supports
# 1033 Mbps on a 1000 Mbps port: announcing a shortage there tells the operator
# their machine cannot do what it plainly does.
COVER_RTT_MS=176
out="$(explain_cover_rtt 1000 2>&1)"
[[ "$out" != *"本该要"* ]] || fail 'a clamp that still clears the port is not a shortfall'
pass 'a trimmed ceiling that still clears the port raises no shortfall'
COVER_RTT_MS=250
# The wizard's table and buffer_ceiling must agree about what is clamped. The
# table computed its clamp once, up front, from RAM alone -- correct until the
# budget started following the need, and silently wrong afterwards.
out="$(explain_cover_rtt 1000 2>&1)"
[[ "$out" == *"43.3 MB/socket"* ]] || fail 'the wizard table must show the need-driven ceiling'
[[ "$out" != *"86.7 MB/socket"* ]] || fail 'the wizard table must not use the withdrawn RAM/6 clamp'
pass 'the wizard table agrees with buffer_ceiling about the ceiling'
# A machine with room says nothing of the sort.
total_ram_bytes() { printf '%s\n' $((32 * 1024 * 1024 * 1024)); }
out="$(explain_cover_rtt 100 2>&1)"
[[ "$out" != *"本该要"* ]] || fail 'a box with room must not claim a shortfall'
pass 'a box with room reports no shortfall'

# ── 0.9.0 同机房采样不能当成覆盖 RTT ───────────────────────────────────────
# On the gigabit box every live socket was same-datacentre, so the measurement
# was 1 ms and the suggestion 50 — which would cap every real client it has.
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
suggest_cover_rtt() { printf '50\t1\t8\n'; }
out="$(explain_cover_rtt 1000 2>&1)"
[[ "$out" == *"都在 20 ms 以内"* ]] || fail 'an all-local sample must be called out'
[[ "$out" != *"建议填 50"* ]] || fail 'and must not be turned into a suggestion'
pass 'an all-same-datacentre sample is refused as a coverage figure'
suggest_cover_rtt() { printf '250\t177\t9\n'; }
out="$(explain_cover_rtt 1000 2>&1)"
[[ "$out" == *"建议填 250"* ]] || fail 'a genuine remote sample still yields a suggestion'
pass 'a real remote sample still produces a suggestion'
unset -f has sysctl suggest_cover_rtt total_ram_bytes
COVER_RTT_MS=250

printf '%s\n' 'All tcpwide self-tests passed.'


# ── 0.10.0 单流跑不满时，先问「哪一个才是真的天花板」 ──────────────────────
# Three backends at 135/146/184 ms all topped out near 600 Mbps while the
# configured window supported 1011/935/742. The buffer had headroom on every
# one of them, so no amount of buffer tuning could have helped -- and the tool
# said nothing that would have revealed that. Both probes below exist so the
# next such measurement is read correctly the first time.

# window_headroom is gone. It measured a connection against net.core.rmem_max
# regardless of which way the data was moving, and the live samples were
# senders -- so it reported "the buffer here supports 2560 Mbps, only 37% used"
# about the receive buffer of a socket that was transmitting. That is the same
# category error window_ratio was fixed for one release earlier; this copy was
# missed. render_send_sample and render_recv_sample replace it and compare like
# with like.
grep -q 'window_headroom' "$ROOT/tcpwide.sh" \
  && fail 'window_headroom measured senders against the receive buffer'
grep -q '本机缓冲在这条' "$ROOT/tcpwide.sh" \
  && fail 'its output line must be gone with it'
pass 'the receive-buffer yardstick is no longer applied to senders'
# It also carried advice ruled out several rounds ago, and hedged on the peer
# window while the block directly below it concluded -- two verdicts on one
# screen.
grep -q '先看上面的 CPU' "$ROOT/tcpwide.sh" && fail 'stale CPU advice must not ship'
grep -q '这是一条要排除的可能，不是结论' "$ROOT/tcpwide.sh" \
  && fail 'the hedge contradicted the conclusion printed below it'
pass 'the diagnosis gives one verdict per direction, not two that disagree'

# A single flow through a userspace proxy runs on essentially one core, so the
# aggregate figure hides the ceiling: the busiest core is the one that answers.
# cpuN: user nice system idle iowait irq softirq steal
stat_a=$'cpu0 100 0 100 1000 0 0 0 0\ncpu1 100 0 100 1000 0 0 0 0'
stat_b=$'cpu0 200 0 200 1000 0 0 0 0\ncpu1 100 0 100 1200 0 0 0 0'
IFS=$'\t' read -r bmax bavg bcores bsteal <<< "$(
  printf '%s\n%s\n' "$stat_a" "$stat_b" | awk '
    { busy = 0; tot = 0
      for (i = 2; i <= NF; i++) { tot += $i; if (i != 5 && i != 6) busy += $i }
      st = (NF >= 9) ? $9 : 0
      if ($1 in seen) { d = tot - t[$1]
        if (d > 0) { p = (busy - u[$1]) * 100 / d; sp = (st - v[$1]) * 100 / d
          sum += p; n++; if (p > max) max = p; if (sp > maxst) maxst = sp } }
      else { seen[$1] = 1; t[$1] = tot; u[$1] = busy; v[$1] = st } }
    END { printf "%.0f\t%.0f\t%d\t%.0f", max, sum / n, n, maxst }')"
assert_eq '100' "$bmax"   'cpu0 went from idle to fully busy'
assert_eq '50'  "$bavg"   'the average hides it at 50%'
assert_eq '2'   "$bcores" 'both cores are counted'
assert_eq '0'   "$bsteal" 'no steal in this sample'
# The whole point: the aggregate would have said the box was half idle.
(( bmax >= 85 && bavg < 70 )) || fail 'this sample must trip the single-core warning'
pass 'a pinned core is visible even when the average says half idle'

# `mq` is one child qdisc per hardware TX queue, each with its own lock.
# Replacing the root with a single fq funnels every queue through one lock --
# invisible on a single-flow test, and the wrong trade for aggregate throughput.
# An unmatched glob leaves the literal pattern in the loop variable, and the
# failing -d test as the last command in the body made the function return
# non-zero under errexit.
IFACE='definitely-not-an-interface'
assert_eq '0' "$(tx_queue_count)" 'a missing interface counts zero queues rather than erroring'
IFACE=eth0

IFACE=eth0
tx_queue_count() { printf '2\n'; }
tc() {
  [[ "$1" == qdisc && "$2" == show ]] || return 1
  printf 'qdisc mq 8001: root\nqdisc fq 0: parent 8001:1 limit 10000p\nqdisc fq 0: parent 8001:2 limit 10000p\n'
}
assert_eq '8001:' "$(mq_root_handle)" 'the mq root handle is parsed for use as a leaf parent'
assert_eq '2' "$(mq_leaves_with fq)" 'leaves carrying the pacer are counted'
if mq_leaves_with cake >/dev/null 2>&1; then fail 'a kind no leaf carries must not match'; fi
pass 'a qdisc kind absent from the leaves does not match'
# And that layout is the intended one, so the panel must not nag about drift.
SHAPE=0; LINK_MBPS=1000; COVER_RTT_MS=250; QDISC_LAYOUT=mq-leaves
if qdisc_drift >/dev/null 2>&1; then fail 'mq carrying fq leaves is the intended layout, not drift'; fi
pass 'mq with fq leaves does not read as drift'
# Shaping is the one case that still has to take the root: CAKE can only shape
# what it can all see. An mq root there is real drift.
SHAPE=1
assert_eq 'mq ← 2×fq ' "$(qdisc_drift)" 'under shaping an mq root really is drift'
SHAPE=0

# ── 0.11.0 半套 pacing 比没有 pacing 更糟 ──────────────────────────────────
# A leaf without fq is paced by nothing, and BBR on an unpaced queue sends
# cwnd-sized bursts at line rate for the next policer to drop. Accepting any
# non-zero leaf count reported such a machine as consistent, hiding exactly the
# state apply_fq_leaves used to be able to create.
tc() {
  [[ "$1" == qdisc && "$2" == show ]] || return 1
  printf 'qdisc mq 8001: root\nqdisc fq 0: parent 8001:1 limit 10000p\nqdisc fq_codel 0: parent 8001:2 limit 10240p\n'
}
if mq_leaves_with fq >/dev/null 2>&1; then fail 'one paced leaf out of two is not a paced machine'; fi
pass 'a partially paced mq root does not count as carrying the pacer'
QDISC_LAYOUT=mq-leaves
# qdisc_drift reaches target_qdisc, which now sizes the fq queue limits from RAM.
total_ram_bytes() { printf '%s\n' $((8 * 1024 * 1024 * 1024)); }
assert_eq 'mq ← 1×fq 1×fq_codel ' "$(qdisc_drift)" \
  'a half-paced mq root reads as drift, naming which leaves are wrong'
unset -f tc

# All or nothing: a leaf that refuses the spec rolls back the ones already
# written, so the caller falls back to the single root fq that cannot be
# partially applied. The old code took ok>0 and printed "done".
IFACE=eth0
tx_queue_count() { printf '4\n'; }
mq_root_handle() { printf '8001:\n'; }
tc_log="$(mktemp)"
# "$*" joins on the FIRST character of IFS, and the script runs under
# IFS=$'\n\t' -- a mock that matches on spaces silently matches nothing. This
# trap has now bitten this codebase four times, so the mock pins IFS itself.
tc() {
  local IFS=' '
  printf '%s\n' "$*" >> "$tc_log"
  # The third leaf refuses, as a queue count mismatch would make it.
  # qdisc replace dev eth0 parent 8001:N ... -> the handle is the sixth word.
  [[ "$1" == qdisc && "$2" == replace && "$6" == '8001:3' ]] && return 1
  return 0
}
if apply_fq_leaves 'fq maxrate 980mbit' >/dev/null 2>&1; then
  fail 'a refused leaf must fail the whole application'
fi
pass 'one refused leaf fails the whole mq application'
assert_eq '2' "$(grep -c 'qdisc del dev eth0 parent' "$tc_log")" \
  'the two leaves already written are rolled back'
rm -f "$tc_log"
# unset -f cannot restore a shadowed definition, so only the mock that later
# blocks redefine is dropped here.
unset -f tc

# The default layout is the measured one. 0.10.0 shipped mq-leaves as the
# default on reasoning alone and three backends lost 42-47% together, so an mq
# root must still get a single root fq unless the layout is explicitly chosen.
IFACE=eth0
QDISC_LAYOUT=root; SHAPE=0
root_log="$(mktemp)"
tc() {
  local IFS=' '
  if [[ "$1" == qdisc && "$2" == show ]]; then printf 'qdisc mq 8001: root\n'; return 0; fi
  printf '%s\n' "$*" >> "$root_log"; return 0
}
ip() { printf 'default via 10.0.0.1 dev eth0\n'; }
has() { [[ "$1" == tc || "$1" == ip ]]; }
QDISC_SNAP="$(mktemp -d)/qdisc"; ROUTE_SNAP="$(mktemp -d)/route"
apply_link 1000 250 >/dev/null 2>&1 || true
grep -q 'qdisc del dev eth0 root' "$root_log" \
  || fail 'a queue that is not the target must be deleted first, not merged into'
grep -q 'qdisc add dev eth0 root fq' "$root_log" \
  || fail 'the default layout must take the root even when mq is there'
if grep -q 'parent 8001:' "$root_log"; then fail 'the default layout must not touch mq leaves'; fi
pass 'the default layout is root fq even on an mq-rooted interface'
rm -f "$root_log"
unset -f tc ip has

# A screenshot of a speedtest carries nothing about the configuration that
# produced it, which is why attributing a 44% regression needed a git diff
# between two releases. The fingerprint makes that a lookup.
live_value() { case "$1" in
  net.ipv4.tcp_congestion_control) printf 'bbr\n' ;;
  net.core.rmem_max) printf '45438293\n' ;;
  net.ipv4.tcp_rmem) printf '4096 1048576 45438293\n' ;;
  net.ipv4.tcp_wmem) printf '4096 1048576 45438293\n' ;;
esac; }
canonical_qdisc() { printf 'fq maxrate 980Mbit\n'; }
current_default_route() { printf 'default via 10.0.0.1 dev eth0 initcwnd 20\n'; }
COVER_RTT_MS=176
fp="$(config_fingerprint)"
for want in "$VERSION" bbr 43.3 'start 1.0/1.0 MB' 'fq maxrate 980Mbit' 'initcwnd 20' '176 ms'; do
  [[ "$fp" == *"$want"* ]] || fail "the fingerprint must carry $want"
done
pass 'the fingerprint identifies version, cc, buffer, layout, initcwnd and coverage'
unset -f live_value canonical_qdisc current_default_route

# BBR without a pacer bursts at line rate. The root qdisc is set explicitly, but
# any queue the kernel makes on its own takes default_qdisc, and the stock value
# paces nothing.
available_cc() { printf 'reno cubic bbr\n'; }
total_ram_bytes() { printf '%s\n' $((8 * 1024 * 1024 * 1024)); }
tgt="$(target_sysctl 500 250)"
assert_eq 'fq' "$(awk -F'\t' '$1 == "net.core.default_qdisc" {print $2}' <<< "$tgt")" \
  'queues the kernel creates itself must pace by default'
QDISC_LAYOUT=root


# ── 0.12.0 向导不能把 CPU 不够的机器推到 CAKE 上 ───────────────────────────
# Same box, same backend, minutes apart: `fq maxrate 980mbit` peaked at 629
# Mbps, `cake bandwidth 980Mbit` on the same two cores peaked at 332. The wizard
# had been recommending a CAKE profile by default, and profile 3 was labelled
# "速度优先" while being the slowest option on that machine.
SHAPE=1
cpu_count() { printf '2\n'; }
cake_over_budget 1000 || fail 'two cores cannot shape a gigabit of CAKE'
pass 'a 2-core box shaping a gigabit is over budget'
cake_over_budget 500 && fail 'two cores can shape 500 Mbps'
pass 'the same box shaping 500 Mbps is within budget'
cpu_count() { printf '8\n'; }
cake_over_budget 1000 && fail 'eight cores can shape a gigabit'
pass 'a box with cores to spare is not over budget'
# The budget question must not depend on whether shaping is currently on: the
# wizard asks it before the operator has picked a profile.
SHAPE=0
cpu_count() { printf '2\n'; }
cake_over_budget 1000 || fail 'the budget question is independent of the current profile'
pass 'the CPU budget is answerable before a profile is chosen'
SHAPE=1

# A label that promises speed while delivering half of it is worse than no
# label. Names describe shaping tightness; only measurement talks about speed.
for pf in stable balanced speed noshape; do
  apply_profile "$pf"
  [[ "$(profile_label "$pf")" != *速度优先* ]] || fail "$pf still promises speed in its name"
done
pass 'no profile name promises speed any more'
apply_profile speed
assert_eq '98' "$SHAPE_PCT" 'the profile keys are unchanged, so existing configs still load'
assert_eq 'speed' "$PROFILE" 'and the stored key stays speed for compatibility'

# ── 0.12.0 测量记录 ────────────────────────────────────────────────────────
# Eight rounds of "install, pick something, test, still slow" went by with
# nobody able to say which configuration produced which number.
STATE_DIR="$(mktemp -d)"; MEASURE_LOG="$STATE_DIR/measurements"
live_value() { case "$1" in
  net.ipv4.tcp_congestion_control) printf 'bbr\n' ;;
  net.core.rmem_max) printf '45438293\n' ;;
esac; }
current_default_route() { printf 'default via 10.0.0.1 dev eth0 initcwnd 20\n'; }
canonical_qdisc() { printf '%s\n' "${FAKE_Q:-fq maxrate 950mbit}"; }
COVER_RTT_MS=176
if best_measurement >/dev/null 2>&1; then fail 'an empty log has no best run'; fi
pass 'an empty measurement log reports no best run'
FAKE_Q='cake 950000kbit dual-dsthost' record_measurement 332.25 '上海 CAKE'
FAKE_Q='fq maxrate 950mbit'           record_measurement 629.10 '上海 不整形'
FAKE_Q='cake 950000kbit no-split-gso' record_measurement 540.00 '上海 CAKE+nogso'
IFS=$'\t' read -r b_mbps b_fp b_note _ <<< "$(best_measurement)"
assert_eq '629.10' "$b_mbps" 'the best run is the fastest one, not the newest'
[[ "$b_fp" == *'fq maxrate 950mbit'* ]] || fail 'the best run carries the configuration that produced it'
pass 'the best run carries its own configuration'
assert_eq '上海 不整形' "$b_note" 'and the note that identifies the test'
# A reading that is not a number must not silently land in the log.
if record_measurement 'fast' 'nope' 2>/dev/null; then fail 'a non-numeric reading must be refused'; fi
pass 'a non-numeric reading is refused rather than logged'
assert_eq '3' "$(awk 'END {print NR}' "$MEASURE_LOG")" 'the refused reading did not reach the log'
# A tab in the note would split the record into the wrong fields.
FAKE_Q='fq maxrate 950mbit' record_measurement 100 "$(printf 'a\tb')"
assert_eq '4' "$(awk -F'\t' 'NF == 6 {n++} END {print n + 0}' "$MEASURE_LOG")" \
  'a tab in the note cannot break the record into extra fields'
rm -rf "$STATE_DIR"
unset -f live_value current_default_route canonical_qdisc


# ── 0.13.0 指纹必须稳定，否则 A/B 无从谈起 ─────────────────────────────────
# The fingerprint used the raw `tc` line, which carries a handle the kernel
# reassigns on every replace (8006:, then 8007:) and a refcnt that moves on its
# own. Two runs of the identical configuration produced two different strings,
# so the panel's "the best run is the current configuration" test could never be
# true. An A/B is worthless if the same arm is not recognisable twice.
restore_lib          # the block above mocked canonical_qdisc; this needs the real one
IFACE=eth0
mq_root_handle() { printf ''; }
tc() {
  printf 'qdisc fq %s: root refcnt 2 limit 10000p flow_limit 100p buckets 1024 orphan_mask 1023 quantum 3028b initial_quantum 15140b maxrate 980Mbit low_rate_threshold 550Kbit refill_delay 40ms timer_slack 10us horizon 10s horizon_drop\n' "${FAKE_H:-8006}"
}
a="$(FAKE_H=8006 canonical_qdisc)"
b="$(FAKE_H=8007 canonical_qdisc)"
assert_eq "$a" "$b" 'a reassigned qdisc handle does not change the identity'
# limit and flow_limit are part of the identity since 0.14.0, because they are
# configuration now: flow_limit is what took a single thread from 546 to 927
# Mbps. Leaving them out gave the winning and losing configurations the same
# fingerprint, so the record log could not compare the very knob it exists for.
assert_eq 'fq limit 10000p flow_limit 100p initial_quantum 15140b maxrate 980Mbit' "$a" \
  'the canonical form keeps only what we chose'
for junk in 8006 refcnt buckets orphan_mask horizon low_rate_threshold refill_delay; do
  [[ "$a" != *"$junk"* ]] || fail "the canonical form must not carry $junk"
done
pass 'kernel bookkeeping and defaults are stripped from the identity'
# The two arms of the measurement that mattered must not collide.
tc() { printf 'qdisc fq 8006: root refcnt 2 limit 10240p flow_limit 2048p buckets 1024 maxrate 980Mbit
'; }
won="$(canonical_qdisc)"
tc() { printf 'qdisc fq 8007: root refcnt 2 limit 10000p flow_limit 100p buckets 1024 maxrate 980Mbit
'; }
lost="$(canonical_qdisc)"
[[ "$won" != "$lost" ]] || fail 'the flow_limit arms must be distinguishable'
pass 'the two flow_limit arms carry different identities'
tc() { printf 'qdisc cake 8005: root refcnt 2 bandwidth 950Mbit besteffort dual-dsthost nonat nowash no-ack-filter no-split-gso rtt 200ms raw overhead 0\n'; }
assert_eq 'cake 950Mbit dual-dsthost no-split-gso rtt 200ms' "$(canonical_qdisc)" \
  'CAKE keeps its bandwidth, isolation, gso choice and rtt'
mq_root_handle() { printf '8001:\n'; }
tc() {
  printf 'qdisc mq 8001: root\nqdisc fq 0: parent 8001:1 limit 10000p\nqdisc fq 0: parent 8001:2 limit 10000p\n'
}
assert_eq 'mq ← 2×fq ' "$(canonical_qdisc)" 'an mq root is identified by what its leaves carry'
unset -f tc mq_root_handle

# ── 0.13.0 单线程和多线程回答的是两个不同的问题 ────────────────────────────
# Multi-thread hit 917 Mbps on a 1000 Mbps port, 43 seconds after the same
# backend gave 558 single-threaded. That pair is what finally established the
# server side was already tuned, and it took five rounds of asking to obtain.
# The tool should state it rather than leaving it to be worked out by hand.
STATE_DIR="$(mktemp -d)"; MEASURE_LOG="$STATE_DIR/measurements"
live_value() { case "$1" in
  net.ipv4.tcp_congestion_control) printf 'bbr\n' ;;
  net.core.rmem_max) printf '45438293\n' ;;
esac; }
canonical_qdisc() { printf 'fq maxrate 980Mbit\n'; }
current_default_route() { printf 'default via 10.0.0.1 dev eth0 initcwnd 20\n'; }
COVER_RTT_MS=200
if throughput_verdict 1000 >/dev/null 2>&1; then fail 'one arm alone is not a verdict'; fi
pass 'a single-thread reading on its own yields no verdict'
record_measurement 557.8 '武汉 单线程' 1
if throughput_verdict 1000 >/dev/null 2>&1; then fail 'still only one arm'; fi
pass 'a verdict needs both arms, not just more readings'
record_measurement 917.4 '武汉 多线程' 4
IFS=$'\t' read -r v_s v_m v_pct v_state <<< "$(throughput_verdict 1000)"
assert_eq '557.8' "$v_s" 'the single-thread arm is the fastest single-thread run'
assert_eq '917.4' "$v_m" 'the multi-thread arm is the fastest multi-thread run'
assert_eq '92' "$v_pct" '917 of 1000 Mbps is 92% of line rate'
assert_eq 'tuned' "$v_state" 'aggregate near the port rate means the server side is done'
# The arms must never be averaged together: a fast multi-thread run is not a
# better single-thread run, and reading it as one is what sent this looking for
# a server-side cause that did not exist.
IFS=$'\t' read -r t_s t_m <<< "$(thread_split)"
assert_eq '557.8' "$t_s" 'a multi-thread run does not raise the single-thread best'
assert_eq '917.4' "$t_m" 'and the two are tracked separately'
# Records written before 0.13.0 have no thread column and were single-thread.
printf '%s\t%s\t%s\t%s\n' "$(date +%s)" 600 'old fingerprint' '旧记录' >> "$MEASURE_LOG"
IFS=$'\t' read -r t_s _ <<< "$(thread_split)"
assert_eq '600' "$t_s" 'a pre-0.13.0 record counts as the single-thread run it was'
# A machine that cannot fill its port even in aggregate is a different verdict.
: > "$MEASURE_LOG"
record_measurement 330 '单' 1; record_measurement 500 '多' 4
IFS=$'\t' read -r _ _ _ v_state <<< "$(throughput_verdict 1000)"
assert_eq 'short' "$v_state" 'aggregate well under the port keeps the search open'
rm -rf "$STATE_DIR"
unset -f live_value canonical_qdisc current_default_route

# ── 0.13.0 单流旋钮：默认必须和 0.12.0 逐字节相同 ──────────────────────────
# 0.10.0 shipped a queue layout that was reasoned rather than measured and cost
# 44% across three backends. These three are hypotheses too, so they ship as
# knobs at their existing values and only a measurement gets to promote one.
# initial_quantum stays a pure knob: unlike the queue limits it has no
# supporting measurement from anywhere, so it ships off and only a recorded A/B
# gets to promote it.
SHAPE=0; SHAPE_PCT=98; FQ_INITIAL_QUANTUM=0; FQ_FLOW_LIMIT=0; FQ_LIMIT=0
total_ram_bytes() { printf '%s\n' $((8 * 1024 * 1024 * 1024)); }
assert_eq 'fq limit 40960 flow_limit 8192' "$(target_qdisc 1000 200)" \
  'an untouched initial_quantum adds nothing to the spec'
FQ_INITIAL_QUANTUM=65536
assert_eq 'fq limit 40960 flow_limit 8192 initial_quantum 65536' \
  "$(target_qdisc 1000 200)" 'a set burst allowance reaches the spec'
FQ_INITIAL_QUANTUM=0

# ── 0.13.0 覆盖 RTT 的建议值不该越过拐点 ───────────────────────────────────
# The wizard said "above 173 ms the buffer stops growing" and recommended 200 in
# the same breath. Two numbers on screen arguing with each other.
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
knee="$(buffer_knee_ms 1000)"
assert_eq '173' "$knee" 'the knee is where the budget stops growing'
(( knee < 200 )) || fail 'this box must have its knee below the 200 the wizard suggests'
pass 'the knee sits below the suggestion, so the caveat is needed'
has() { [[ "$1" == sysctl ]]; }
sysctl() { [[ "$2" == net.ipv4.tcp_mem ]] && printf '8330\t16661\t33323\n'; }
suggest_cover_rtt() { printf '200\t167\t9\n'; }
COVER_RTT_MS=200
out="$(explain_cover_rtt 1000 2>&1)"
[[ "$out" == *"填 200 和填 173 效果相同"* ]] \
  || fail 'a suggestion past the knee must say it changes nothing'
pass 'a suggestion past the knee says so instead of contradicting itself'
total_ram_bytes() { printf '%s\n' $((8 * 1024 * 1024 * 1024)); }
unset -f has sysctl suggest_cover_rtt


# ── 0.14.1 面板上那几个假数字 ──────────────────────────────────────────────
# A 0.6ms same-datacentre neighbour won the "fastest connection" contest, and
# the panel then reported that the buffer supports 303318 Mbps on it -- true
# arithmetic about a connection nobody asked about. Local connections are not
# the client population.
restore_lib
IFACE=eth0
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:443 23.19.231.167:51000\n'
  printf '\t rtt:0.6/0.3 snd_wnd:131072 delivery_rate 42.0Mbps\n'
  printf 'ESTAB 0 0 10.0.0.5:443 1.2.3.4:52000\n'
  printf '\t rtt:155/4 snd_wnd:8388608 delivery_rate 900.0Mbps\n'
}
has() { [[ "$1" == ss ]]; }
IFS=$'\t' read -r pw_peer pw_rtt _ _ _ <<< "$(peer_window_ceiling)"
assert_eq '1.2.3.4' "$pw_peer" 'the real remote client is chosen over the local neighbour'
[[ "$pw_rtt" != 0.6 ]] || fail 'a 0.6ms connection must never be the sample'
pass 'a same-datacentre connection cannot become the single-flow reference'
# With nothing but local connections there is no reference at all, and saying so
# beats inventing one.
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:443 23.19.231.167:51000\n'
  printf '\t rtt:0.6/0.3 snd_wnd:131072 delivery_rate 42.0Mbps\n'
}
if peer_window_ceiling >/dev/null 2>&1; then fail 'an all-local sample yields no reference'; fi
pass 'an all-local sample reports no reference rather than a fabricated one'
unset -f ss has

# A five-second window on an idle box carries a handful of segments, and one
# retransmission out of fifty reads as a flat 2.0000% -- a suspiciously round
# number that is noise. Below a floor there is nothing to report.
has() { [[ "$1" == nstat ]]; }
NSTAT_R=0; NSTAT_S=0
nstat() { printf 'TcpRetransSegs %s 0\nTcpOutSegs %s 0\n' "$NSTAT_R" "$NSTAT_S"; }
sleep() { NSTAT_R=$(( NSTAT_R + STEP_R )); NSTAT_S=$(( NSTAT_S + STEP_S )); }
STEP_R=1; STEP_S=50
rc=0; retrans_rate 0 >/dev/null 2>&1 || rc=$?
assert_eq '2' "$rc" 'a 50-segment window is refused as too small to judge'
STEP_R=60; STEP_S=6000
assert_eq '1.0000' "$(retrans_rate 0)" 'a real transfer is measured normally'
unset -f nstat sleep has

# The advice has to match the profile that is running: telling someone on the
# no-shape profile to check the queue is really cake sends them to undo the
# setting that is correct for their machine.
grep -q '本机 fq 只做 pacing，不限速' "$ROOT/tcpwide.sh" \
  || fail 'the no-shape path needs its own retransmission advice'
pass 'the retransmission advice branches on the running profile'

# 0.13.0 asserted a single flow below the aggregate could not be moved by any
# buffer or queue setting. flow_limit moved it 70% in the next release. The
# verdict must point at the per-flow levers, not close the question.
grep -q '改缓冲或队列都不会动它' "$ROOT/tcpwide.sh" \
  && fail 'the withdrawn claim must not still ship'
pass 'the claim that per-flow limits cannot be moved is gone'


# ── 0.15.0 在途字节数才能分开「缓冲不够」和「别处的锅」 ────────────────────
# Four real readings from one machine, same configuration, minutes apart:
#   黄石 155ms 927.14 | 黄石 163ms 881.27 | 深圳 192ms 583.23 | 岳阳 202ms 580.54
# The two 黄石 points imply 17.13 and 17.12 MB in flight -- 0.06% apart, rate
# tracking 1/RTT exactly. The other two sit at 13.35 and 13.98. All four are
# well under the 21.7 MB this machine advertises, which is what says a bigger
# buffer, or a machine with more memory, would change nothing. That conclusion
# had to be reached by hand every single round.
restore_lib
STATE_DIR="$(mktemp -d)"; MEASURE_LOG="$STATE_DIR/measurements"
live_value() { case "$1" in net.core.rmem_max) printf '45497685\n' ;; *) printf 'bbr\n' ;; esac; }
canonical_qdisc() { printf 'fq limit 10240p flow_limit 2048p maxrate 980Mbit\n'; }
current_default_route() { printf 'default via 10.0.0.1 dev eth0 initcwnd 20\n'; }
COVER_RTT_MS=200
if window_utilisation >/dev/null 2>&1; then fail 'an empty log has no window analysis'; fi
pass 'an empty measurement log yields no window analysis'
# A reading without an RTT cannot enter the analysis: rate alone cannot tell a
# distant backend from a throttled one.
record_measurement 900 '没填RTT' 1 0
if window_utilisation >/dev/null 2>&1; then fail 'a reading with no RTT must not be analysed'; fi
pass 'a reading without an RTT is left out rather than guessed at'
# TcpQuality's 回程 figures, which are this box pulling from each node: the VPS
# is the receiver and the RTT is its own, so they answer a receive-window
# question. Six nodes at 0.00% retransmission, RTT 148-174ms.
record_measurement 642.6 '上海电信' 1 149
record_measurement 634.0 '上海联通' 1 151
record_measurement 638.9 '上海移动' 1 148
record_measurement 581.1 '北京电信' 1 168
record_measurement 558.7 '广东电信' 1 174
record_measurement 549.0 '广东移动' 1 174
assert_eq '6' "$(window_utilisation | awk 'END {print NR}')" 'only the readings carrying an RTT are analysed'
IFS=$'\t' read -r _ _ _ _ wu_pct <<< "$(window_utilisation | sed -n 1p)"
# These readings sit near half the advertised window, and the experiment that
# settles it was run on this very box: rmem_max was doubled from 43.4 to 86.8 MB
# and the same nine backends did not move -- median in flight 11.41 -> 11.40 MB.
# A flow at its window would have gone faster. 0.16.0 reported these as 104-107%
# by dividing by rmem/4 and concluded the box needed more memory; it did not.
(( wu_pct >= 45 && wu_pct <= 60 )) \
  || fail "these readings sit near half the window, expected 45-60%, got ${wu_pct}%"
pass 'the six-node sample sits at half the window, which doubling rmem confirmed'
# The in-flight bytes barely move while the RTT spreads 17%: that is what a
# fixed window looks like, and why rate alone could never have shown it.
lo="$(window_utilisation | awk -F'\t' '{print $4}' | sort -n | head -1)"
hi="$(window_utilisation | awk -F'\t' '{print $4}' | sort -n | tail -1)"
awk -v l="$lo" -v h="$hi" 'BEGIN {exit !(l > 0 && (h - l) / l < 0.05)}' \
  || fail "in-flight bytes must cluster within 5%, got $lo to $hi"
pass 'bytes in flight cluster while RTT spreads, which is a fixed window'
# An end-to-end reading through the proxy carries the CLIENT's RTT over a
# different leg, so it is not a measurement of this machine's receive window at
# all. Reported as a percentage of our window it reads 158%, and the report has
# to say what that means rather than treating it as a buffer verdict.
record_measurement 1600 '端到端' 1 155
out="$(render_window_report 2>&1)"
[[ "$out" == *"量的不是这台机器的接收腿"* ]] \
  || fail 'a reading past the window must be identified as measuring another leg'
pass 'an end-to-end reading is not mistaken for a receive-window measurement'
# Multi-thread readings are excluded: their in-flight is spread over N flows, so
# dividing by one window would overstate what a single flow reached.
record_measurement 917.4 '多线程' 4 175
assert_eq '7' "$(window_utilisation | awk 'END {print NR}')" 'a multi-thread reading stays out of the per-flow analysis'
# A buffer with genuine headroom is still cleared, and the levers ranked.
: > "$MEASURE_LOG"
record_measurement 400 '慢后端' 1 150
out="$(render_window_report 2>&1)"
[[ "$out" == *"本机缓冲还有余量"* ]] || fail 'below the threshold the buffer must be cleared'
[[ "$out" == *"notsent_lowat"* ]] || fail 'the remaining levers must be ranked'
pass 'a buffer with headroom is cleared and the remaining levers are ranked'
# 0.15.0 divided by rmem/2, reported these very readings as 52-54% and told the
# operator a machine with more memory "would make no difference". Under the
# measured ratio the box was at its window and memory-limited. The sentence must
# never ship again.
grep -q '换内存更大的机器，对这台都不会有任何作用' "$ROOT/tcpwide.sh" \
  && fail 'the withdrawn advice against more memory must not still ship'
pass 'the advice against buying more memory is withdrawn'
# And when something really is pressed against the window, say so instead.
: > "$MEASURE_LOG"
record_measurement 1050 '贴窗口' 1 150
out="$(render_window_report 2>&1)"
[[ "$out" == *"缓冲就是瓶颈"* ]] || fail 'a backend at the window must be reported as buffer-limited'
pass 'a backend pressed against the window is reported as buffer-limited'
rm -rf "$STATE_DIR"
unset -f live_value canonical_qdisc current_default_route


# ── 0.27.0 notsent_lowat 回到系统值 ───────────────────────────────────────
# 128 KiB beat 16 KiB, but that comparison only proved 16 KiB was worse. It did
# not compare either cap with the kernel default. The later high-low-high-low
# sequence reached 1.4 Gbps and 190 Mbps at the same RTT; at the peak 128 KiB is
# only 0.75 ms of refill slack, so it cannot remain an unqualified default.
restore_lib
available_cc() { printf 'reno cubic bbr\n'; }
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
assert_eq '0' "$NOTSENT_LOWAT" 'notsent_lowat is neutral by default'
[[ -z "$(target_sysctl 1000 200 | awk -F'\t' '$1 == "net.ipv4.tcp_notsent_lowat" {print $2}')" ]] \
  || fail 'the neutral default must not be emitted as a target'
grep -q '0=恢复系统值' "$ROOT/tcpwide.sh" \
  || fail 'the panel must state that zero restores the pre-tcpwide value'
pass 'notsent_lowat is an explicit A/B knob rather than a hidden default'


# ── 0.16.0 持久化默认开、手动上限告警、窗口比例诊断 ────────────────────────
restore_lib
# Without persistence every reboot silently reverts the machine to stock and the
# next speedtest measures something nobody configured.
assert_eq '1' "$PERSIST" 'persistence is on by default'

# A manual ceiling below what the derivation would pick is a cap set once during
# an experiment and forgotten, and nothing used to say so.
total_ram_bytes() { printf '%s\n' $((958 * 1024 * 1024)); }
BUF_MB=8
IFS=$'\t' read -r mb_manual mb_auto mb_capped <<< "$(manual_buffer_shortfall 1000 200)"
assert_eq "$((8 * 1024 * 1024))" "$mb_manual" 'the manual ceiling is reported as set'
(( mb_auto > mb_manual )) || fail 'the derivation would have picked more'
(( mb_capped < 1000 )) || fail 'and the manual value caps the port'
out="$(warn_manual_buffer 1000 200 2>&1)"
[[ "$out" == *"低于自动值"* ]] || fail 'a manual ceiling under the auto one must warn'
[[ "$out" == *"1000"* ]] || fail 'and name the port it is capping'
pass 'a manual ceiling below the derivation is reported with its cost'
# Above the derivation it is a deliberate choice and must stay silent. The
# 958 MB box's leftover 32 MB is this case once the multiplier went back to 2:
# the derivation asks for 25.6 MB there, so the override was never the cap that
# 0.16.0's arithmetic made it look like.
BUF_MB=32
if manual_buffer_shortfall 520 190 >/dev/null 2>&1; then
  fail 'a manual ceiling above the derivation is not a shortfall'
fi
pass 'a manual ceiling above the derivation raises nothing'
BUF_MB=0

# The receiving half answers WHY in-flight stalls, and its causes need different
# fixes. On two live boxes this answered from the idle SSH session; now it needs
# a loaded connection, and it is scored separately from the sending direction
# because delivery_rate only ever reports the send rate.
restore_lib
IFACE=eth0
RMEM=45497685; live_value() { printf '%s\n' "$RMEM"; }   # rmem_max 43.4 MB
has() { [[ "$1" == ss ]]; }
LINK_MBPS=1000; SHAPE_PCT=98
# The exact shape that fooled it: a real remote RTT, a trivial rate.
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:22 119.237.129.39:51000\n'
  printf '\t skmem:(r0,rb131072,t0,tb87040,f0,w0,o0,bl0,d0) rtt:139.4/4 bytes_sent:900 bytes_received:900 delivery_rate 5.6Mbps\n'
}
if window_ratio >/dev/null 2>&1; then fail 'an idle SSH session must not be the sample'; fi
pass 'an idle shell at 5.6 Mbps is refused as a buffer sample'
out="$(render_window_ratio 2>&1)"
[[ "$out" == *"跑测速"* ]] || fail 'with nothing under load it must say what it needs'
pass 'with no loaded connection it asks for one instead of inventing a verdict'

# Cause 1: the application is not draining the socket. Bigger buffers only make
# the backlog bigger, so this must never read as a buffer problem.
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:443 1.2.3.4:52000\n'
  printf '\t skmem:(r40000000,rb45497685,t0,tb87040,f0,w0,o0,bl0,d0) rtt:150/4 bytes_sent:9000 bytes_received:900000000 delivery_rate 640.0Mbps\n'
}
out="$(render_window_ratio 2>&1)"
[[ "$out" == *"应用没把数据读走"* ]] || fail 'a full receive queue means the app is not draining'
pass 'a backed-up receive queue is named as an application problem'

# Cause 2: packets discarded on the receive side, before TCP ever sees them.
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:443 1.2.3.4:52000\n'
  printf '\t skmem:(r1000,rb45497685,t0,tb87040,f0,w0,o0,bl0,d4211) rtt:150/4 bytes_sent:9000 bytes_received:900000000 delivery_rate 640.0Mbps\n'
}
out="$(render_window_ratio 2>&1)"
[[ "$out" == *"接收侧丢弃"* ]] || fail 'receive drops must be surfaced'
pass 'receive-side drops are named rather than blamed on the buffer'

# Cause 3: autotuning had no reason to grow, because the sender or the path is
# the limit. This is why doubling rmem_max on the live box moved nothing.
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:443 1.2.3.4:52000\n'
  printf '\t skmem:(r1000,rb12000000,t0,tb87040,f0,w0,o0,bl0,d0) rtt:150/4 bytes_sent:9000 bytes_received:900000000 delivery_rate 320.0Mbps\n'
}
out="$(render_window_ratio 2>&1)"
[[ "$out" == *"autotuning 没有理由长"* ]] || fail 'a small buffer with an empty queue is not a buffer fault'
[[ "$out" == *"翻倍"* ]] || fail 'and the experiment that proved it must be cited'
pass 'a small buffer with an empty queue points at the sender, not the buffer'

# Cause 4: genuinely window-limited -- buffer full, queue empty, in flight near
# half of it. Only here does raising the ceiling help.
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:443 1.2.3.4:52000\n'
  printf '\t skmem:(r1000,rb45497685,t0,tb87040,f0,w0,o0,bl0,d0) rtt:150/4 bytes_sent:9000 bytes_received:900000000 delivery_rate 1150.0Mbps\n'
}
out="$(render_window_ratio 2>&1)"
[[ "$out" == *"真的是窗口限制"* ]] || fail 'a full buffer at half in flight is the window-limited case'
pass 'the genuinely window-limited case is the only one that says raise the buffer'
unset -f ss has live_value


# ── 0.17.0 peer_window_ceiling 也要求连接在跑流量 ──────────────────────────
# Same fault as window_ratio: it picked the operator's SSH session and reported
# "the buffer supports 2611 Mbps on this 139ms connection, using 0%".
restore_lib
IFACE=eth0
has() { [[ "$1" == ss ]]; }
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:22 119.237.129.39:51000\n'
  printf '\t rtt:139.4/4 snd_wnd:131072 delivery_rate 5.6Mbps\n'
}
if peer_window_ceiling >/dev/null 2>&1; then fail 'an idle SSH session must not be the reference'; fi
pass 'the peer-window reference also refuses an idle shell'
# With a loaded connection present it is the one used.
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:22 119.237.129.39:51000\n'
  printf '\t rtt:139.4/4 snd_wnd:131072 delivery_rate 5.6Mbps\n'
  printf 'ESTAB 0 0 10.0.0.5:443 1.2.3.4:52000\n'
  printf '\t rtt:150/4 snd_wnd:8388608 delivery_rate 640.0Mbps\n'
}
IFS=$'\t' read -r pw_peer _ _ _ pw_obs _ <<< "$(peer_window_ceiling)"
assert_eq '1.2.3.4' "$pw_peer" 'the loaded connection is the reference'
assert_eq '640.0' "$pw_obs" 'and its rate is what gets reported'
pass 'a loaded connection is preferred over an idle one'
unset -f ss has

# The advice that a box at its memory ceiling needs more memory is withdrawn:
# doubling rmem_max on that box moved nine backends by nothing.
grep -q '这一条是真的' "$ROOT/tcpwide.sh" && fail 'the withdrawn memory advice must not still ship'
pass 'the claim that more memory would help is gone'


# ── 0.18.0/0.19.0 出站连接 + 收发要分开看 ──────────────────────────────────
# Both samplers required the local port to be a listening port, so a speedtest
# -- which dials OUT to each node -- was invisible and the SSH session won every
# time. And delivery_rate is always the SENDING rate, so a socket we are only
# receiving on could never win a contest scored on it either.
restore_lib
IFACE=eth0
has() { [[ "$1" == ss ]]; }
RMEM=90995370; live_value() { printf '%s\n' "$RMEM"; }
LINK_MBPS=1000; SHAPE_PCT=98
# A mixed speedtest: idle inbound SSH, a loaded outbound sender, a loaded
# outbound receiver. All three are what a real run looks like.
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:22 119.237.129.39:51000\n'
  printf '\t skmem:(r0,rb131072,t0,tb87040,f0,w0,o0,bl0,d0) rtt:139.4/4 snd_wnd:131072 bytes_sent:900 bytes_received:900 delivery_rate 5.6Mbps\n'
  printf 'ESTAB 0 0 10.0.0.5:41234 157.255.228.103:443\n'
  printf '\t skmem:(r0,rb131072,t0,tb4194304,f0,w2097152,o0,bl0,d0) rtt:169/4 snd_wnd:16777216 bytes_sent:900000000 bytes_received:120000 delivery_rate 792.4Mbps\n'
  printf 'ESTAB 0 0 10.0.0.5:41235 106.75.1.1:443\n'
  printf '\t skmem:(r131072,rb25165824,t0,tb87040,f0,w0,o0,bl0,d0) rtt:150/4 snd_wnd:262144 bytes_sent:90000 bytes_received:800000000 delivery_rate 620.0Mbps\n'
}
rows="$(window_ratio)"
assert_eq '2' "$(awk 'END {print NR}' <<< "$rows")" 'both directions produce a sample, and the idle shell neither'
IFS=$'\t' read -r k_s id_s dir_s _ rate_s _ _ _ wnd_s <<< "$(grep '^send' <<< "$rows")"
assert_eq 'send' "$k_s" 'the sending sample is labelled as such'
assert_eq '157.255.228.103:443' "$id_s" 'and is the loaded outbound sender'
assert_eq '出站' "$dir_s" 'and carries its direction'
assert_eq '792.4' "$rate_s" 'at the rate that selected it'
assert_eq '16777216' "$wnd_s" "and the peer's advertised window"
IFS=$'\t' read -r k_r id_r _ _ rate_r _ rb_r _ _ _ <<< "$(grep '^recv' <<< "$rows")"
assert_eq 'recv' "$k_r" 'the receiving sample is reported separately'
assert_eq '106.75.1.1:443' "$id_r" 'and is the loaded outbound receiver'
assert_eq '620.0' "$rate_r" 'which a send-rate contest would have buried'
assert_eq '25165824' "$rb_r" 'with its own rcvbuf, not the one from the sending sample'
pass 'a mixed run yields one sample per direction'

# The category error that printed 12965% on live data: in-flight from the SEND
# rate divided by the RECEIVE buffer. In-flight cannot exceed the buffer holding
# it, and anything past ~110% has to stop rather than feed a verdict.
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:41236 1.2.3.4:443\n'
  printf '\t skmem:(r0,rb131072,t0,tb87040,f0,w0,o0,bl0,d0) rtt:158.7/4 snd_wnd:262144 bytes_sent:1000 bytes_received:900000000 delivery_rate 856.5Mbps\n'
}
out="$(render_window_ratio 2>&1)"
[[ "$out" == *"本次对比无效"* ]] || fail 'an impossible ratio must be refused, not reasoned from'
[[ "$out" != *"autotuning 没有理由长"* ]] || fail 'and must not fall through to a verdict'
pass 'in-flight larger than the buffer holding it is called invalid'

# A peer window sitting on a power-of-two boundary was configured, not grown.
# Two unrelated peers both advertising exactly 16.0 MB is the tell.
assert_eq '16' "$(near_power_of_two_mb 16777216)" 'exactly 16 MiB is recognised'
assert_eq '16' "$(near_power_of_two_mb 16672358)" 'and so is 15.9 MiB, within tolerance'
if near_power_of_two_mb 11862343 >/dev/null 2>&1; then
  fail 'an arbitrary 11.3 MB window is not a configured ceiling'
fi
pass 'only round window sizes read as configured rather than autotuned'
# With the rate matching window/RTT, the hedge resolves to "their ceiling".
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:41234 157.255.228.103:443\n'
  printf '\t skmem:(r0,rb131072,t0,tb4194304,f0,w2097152,o0,bl0,d0) rtt:169/4 snd_wnd:16777216 bytes_sent:900000000 bytes_received:120000 delivery_rate 792.4Mbps\n'
}
out="$(render_window_ratio 2>&1)"
[[ "$out" == *"对端配置的 rmem_max"* ]] || fail 'a matched power-of-two window is the peer ceiling'
[[ "$out" == *"本机怎么调都拿不回来"* ]] || fail 'and must be named as external'
pass 'a peer window on a power-of-two boundary settles the hedge'

# Our own pacer is the other thing that caps a sender, and unlike the peer it is
# ours to change. DMIT sat at 95% of its own fq maxrate.
#
# Since 0.23.0 the ceiling is READ from the running queue rather than derived
# from LINK_MBPS: there is no per-flow cap unless the operator set one, so
# inferring it from the port speed would report a limit that is not installed.
LINK_MBPS=520
IFACE=eth0
tc() { printf 'qdisc fq 8005: root refcnt 2 limit 10240p flow_limit 2048p maxrate 509Mbit\n'; }
has() { [[ "$1" == ss || "$1" == tc ]]; }
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:41234 180.97.50.130:443\n'
  printf '\t skmem:(r0,rb131072,t0,tb4194304,f0,w1048576,o0,bl0,d0) rtt:146/4 snd_wnd:16672358 bytes_sent:900000000 bytes_received:120000 delivery_rate 483.8Mbps\n'
}
out="$(render_window_ratio 2>&1)"
[[ "$out" == *"顶在自己设的单流上限上"* ]] || fail 'a sender at its own maxrate must be told so'
[[ "$out" != *"对端配置的 rmem_max"* ]] || fail 'and must not be blamed on the peer'
pass 'a sender at its own pacer is distinguished from a peer ceiling'
# And with no maxrate installed, the same reading must NOT be blamed on a pacer.
tc() { printf 'qdisc fq 8005: root refcnt 2 limit 10240p flow_limit 2048p\n'; }
out="$(render_window_ratio 2>&1)"
[[ "$out" != *"顶在自己设的单流上限上"* ]] \
  || fail 'a limit that is not installed must not be reported'
pass 'no maxrate on the queue means no pacer verdict'
LINK_MBPS=1000
unset -f ss has live_value tc

# observed_client_rtt must NOT follow: it sizes the coverage RTT from the client
# population, and an outbound connection to a speedtest node is not a client.
has() { [[ "$1" == ss ]]; }
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:443 119.237.129.39:51000\n'
  printf '\t rtt:139.4/4 data_segs_out:900 delivery_rate 5.6Mbps\n'
  printf 'ESTAB 0 0 10.0.0.5:41234 106.75.1.1:443\n'
  printf '\t rtt:250/4 data_segs_out:900000 delivery_rate 640.0Mbps\n'
}
IFS=$'\t' read -r oc_rtt oc_n <<< "$(observed_client_rtt)"
assert_eq '139' "$oc_rtt" 'the client sample keeps only the inbound connection'
assert_eq '1' "$oc_n" 'and counts only it'
pass 'an outbound connection cannot inflate the client RTT distribution'
unset -f ss has

# ── 0.18.0 空字段会让 tab 读取整体错位 ─────────────────────────────────────
# Tab is IFS whitespace, so a RUN of tabs collapses into one delimiter and every
# field after an empty one shifts left. A record with no note handed the
# timestamp to the note variable, which is where the panel's
# "历史最好 580 Mbps (, 08-26 01:14)" came from.
STATE_DIR="$(mktemp -d)"; MEASURE_LOG="$STATE_DIR/measurements"
live_value() { printf 'bbr\n'; }
canonical_qdisc() { printf 'fq\n'; }
current_default_route() { printf 'default via 10.0.0.1 dev eth0\n'; }
printf '%s\t580\tfingerprint-here\t\t1\t0\n' "$(date +%s)" > "$MEASURE_LOG"
IFS=$'\t' read -r bm_mbps bm_fp bm_note bm_when <<< "$(best_measurement)"
assert_eq '580' "$bm_mbps" 'the rate reads back correctly'
assert_eq 'fingerprint-here' "$bm_fp" 'and so does the fingerprint'
assert_eq '-' "$bm_note" 'an absent note is a placeholder, not nothing'
[[ "$bm_when" =~ ^[0-9]{2}-[0-9]{2}\  ]] \
  || fail "the timestamp must survive an empty note, got [$bm_when]"
pass 'an empty note no longer shifts the timestamp out of its field'
# thread_split has the same exposure from either arm being absent.
: > "$MEASURE_LOG"
record_measurement 917.4 '只有多线程' 4 175
IFS=$'\t' read -r ts_single ts_multi <<< "$(thread_split)"
assert_eq '-' "$ts_single" 'a missing single-thread arm is a placeholder'
assert_eq '917.4' "$ts_multi" 'and the multi-thread arm stays in its own field'
if throughput_verdict 1000 >/dev/null 2>&1; then
  fail 'one arm present is not a verdict'
fi
pass 'a placeholder arm is not mistaken for a reading'
rm -rf "$STATE_DIR"
unset -f live_value canonical_qdisc current_default_route


# ── 0.23.0 缓冲起步值：降级回实验值 ────────────────────────────────────────
# tcp_[rw]mem's middle value is where autotuning starts, not a cap -- only the
# third value caps, and neither is a cwnd.
#
# 0.20.0 made 1 MB the default, taken from tcpfit's proxy role. That was a
# borrowing error: tcpfit calls 1 MB the CONSERVATIVE end of its own scale
# (bulk goes to 8 MB) and its comment names the per-socket cost out loud, so it
# is a relative choice on tcpfit's scale rather than an absolute recommendation.
# tcpfit's 2.2x figure also bundles every change it makes, so this knob has
# never been measured on its own -- here or there. Default 0 = whatever the
# kernel already starts sockets at.
restore_lib
available_cc() { printf 'reno cubic bbr\n'; }
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
live_value() {
  case "$1" in
    net.ipv4.tcp_rmem) printf '4096 131072 6291456\n' ;;
    net.ipv4.tcp_wmem) printf '4096 16384 4194304\n' ;;
    *) printf '\n' ;;
  esac
}
BUF_DEFAULT=0
tgt="$(target_sysctl 1000 190)"
mid() { awk -F'\t' -v k="$1" '$1 == k {split($2, f, " "); print f[2]}' <<< "$tgt"; }
assert_eq '131072' "$(mid net.ipv4.tcp_rmem)" \
  'BUF_DEFAULT=0 keeps the kernel receive starting size'
assert_eq '16384' "$(mid net.ipv4.tcp_wmem)" \
  'and the kernel send starting size'
# The direction on that field must be `exact`, not `raise`. As `raise` it
# ratcheted: a machine that once wrote 1 MB computed max(16384, 1048576) and
# reported "already at or better than target", so neither apply nor a reboot
# could walk it back.
dirof() { awk -F'\t' -v k="$1" '$1 == k {print $3}' <<< "$tgt"; }
assert_eq 'raise,exact,raise' "$(dirof net.ipv4.tcp_wmem)" \
  'the starting size can move both ways while the ceiling only rises'
assert_eq 'raise,exact,raise' "$(dirof net.ipv4.tcp_rmem)" 'same on the receive side'
BUF_DEFAULT=1048576
tgt="$(target_sysctl 1000 190)"
assert_eq '1048576' "$(mid net.ipv4.tcp_wmem)" 'the experiment is one setting away'
# The ceiling is still the third value, and the starting size must never exceed
# it -- a start above the cap would be a configuration the kernel rejects.
top() { awk -F'\t' -v k="$1" '$1 == k {split($2, f, " "); print f[3]}' <<< "$tgt"; }
(( $(mid net.ipv4.tcp_wmem) < $(top net.ipv4.tcp_wmem) )) \
  || fail 'the starting size must sit below the ceiling'
pass 'the starting size sits below the ceiling it grows toward'
BUF_DEFAULT=0
unset -f live_value

# What is deliberately NOT taken from tcpfit: netdev_budget. Its own comments
# record 600 against the kernel's 300 at 3751 vs 3745 Mbps, n=5, 0% coefficient
# of variation -- a 0.16% difference, and it warns that public 10G endpoints
# vary 23-45% and once produced a false "600 is harmful" verdict. Copying a
# setting whose own author measured it as noise is cargo cult.
grep -q 'netdev_budget' "$ROOT/tcpwide.sh" && fail 'netdev_budget is noise by its own measurement'
pass 'a setting its own author measured as noise is not copied'


# ── 0.21.0 已排队 ≠ 待发，以及峰值不是平均 ─────────────────────────────────
# skmem's w<N> is wmem_queued and INCLUDES bytes already sent awaiting
# acknowledgement. Printed as "待发队列 16.9 MB" it looked like a 17 MB backlog
# when in-flight was 16.2 MB and only 0.7 MB had yet to leave.
restore_lib
IFACE=eth0
has() { [[ "$1" == ss ]]; }
RMEM=90995370; live_value() { printf '%s\n' "$RMEM"; }
LINK_MBPS=2000; SHAPE_PCT=98
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:41234 36.151.164.132:443\n'
  printf '\t skmem:(r0,rb131072,t0,tb90995370,f0,w17720934,o0,bl0,d0) rtt:142.2/4 snd_wnd:16777216 bytes_sent:9000000000 bytes_received:120000 delivery_rate 958.3Mbps\n'
}
out="$(render_window_ratio 2>&1)"
[[ "$out" == *"含在途"* ]] || fail 'the queued figure must say it includes bytes in flight'
[[ "$out" != *"待发队列"* ]] || fail 'the misleading label must be gone'
[[ "$out" != *"应用喂得比网络快"* ]] \
  || fail '16.9 MB queued against 16.2 MB in flight is not an application backlog'
pass 'queued-including-in-flight is labelled as such and raises no false backlog'
# A genuine backlog still has to be caught: queued far above what is in flight.
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:41234 1.2.3.4:443\n'
  printf '\t skmem:(r0,rb131072,t0,tb41943040,f0,w41943040,o0,bl0,d0) rtt:150/4 snd_wnd:5242880 bytes_sent:9000000000 bytes_received:120000 delivery_rate 280.0Mbps\n'
}
out="$(render_window_ratio 2>&1)"
[[ "$out" == *"应用喂得比网络快"* ]] \
  || fail 'a queue far above in-flight is a real application backlog'
pass 'a real send backlog is still caught, measured on what has not left yet'

# The number a short speedtest reports is an average that includes the ramp. On
# these paths it sat at 70-72% of the peak across five unrelated nodes, and
# reading it as steady-state throughput is what made a tuned box look untuned.
ss() {
  [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }
  printf 'ESTAB 0 0 10.0.0.5:41234 36.151.164.132:443\n'
  printf '\t skmem:(r0,rb131072,t0,tb90995370,f0,w13946880,o0,bl0,d0) rtt:142.2/4 snd_wnd:16777216 bytes_sent:9000000000 bytes_received:120000 delivery_rate 958.3Mbps\n'
}
out="$(render_window_ratio 2>&1)"
[[ "$out" == *"瞬时峰值"* ]] || fail 'a sample at the peer window must say it is a peak'
[[ "$out" == *"爬升期"* ]] || fail 'and explain why a short test averages below it'
[[ "$out" == *"长连接"* ]] || fail 'and what a sustained transfer actually gets'
pass 'hitting the peer window explains the gap to the reported average'
unset -f ss has live_value


# ── 0.23.0 端口速率不是限速 ────────────────────────────────────────────────
# Until 0.23.0 one variable meant three things: the port capacity, CAKE's
# aggregate shaping rate, and fq's PER-FLOW maxrate. So "my port is 2 Gbps"
# silently became "no single connection may exceed 1.9 Gbps", and on the
# no-shape profile -- whose entire point is not to rate-limit anything -- it
# became a rate limit the panel could not turn off. Every single-flow
# measurement taken before 0.23.0 was taken with that cap installed.
restore_lib
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
cpu_count() { printf '1\n'; }
SHAPE=0; PROFILE=noshape; FLOW_MAXRATE_MBPS=0; SHAPER_MBPS=''
for link in 1000 2000; do
  spec="$(LINK_MBPS=$link target_qdisc "$link" 180)"
  [[ "$spec" != *maxrate* ]] \
    || fail "LINK_MBPS=$link must not become a per-flow limit: [$spec]"
done
pass 'the port speed never becomes a single-flow rate limit'

# The silent fallback was the same bug wearing a smaller number: with no port
# speed configured, `${EGRESS_MBPS:-200}` reached the queue builder and became
# `fq maxrate 190mbit` on a machine whose operator had configured nothing.
LINK_MBPS=''
spec="$(target_qdisc "$(sizing_mbps)" 180)"
[[ "$spec" != *maxrate* ]] || fail "an unset port speed must not produce a rate: [$spec]"
[[ "$spec" != *190* ]] || fail 'the sizing fallback must not reach the queue at all'
pass 'no port speed configured means no queue rate limit'
# It still has to size buffers off something, and that something is stated.
assert_eq "$UNKNOWN_LINK_MBPS" "$(sizing_mbps)" 'sizing falls back to a named constant'
LINK_MBPS=1000
assert_eq '1000' "$(sizing_mbps)" 'and uses the real port speed once it is known'

# A per-flow ceiling is available, but only because someone chose it.
FLOW_MAXRATE_MBPS=900
spec="$(target_qdisc 2000 180)"
[[ "$spec" == *"maxrate 900mbit"* ]] || fail "an explicit flow cap must be written: [$spec]"
pass 'an explicitly chosen single-flow limit is honoured'
FLOW_MAXRATE_MBPS=0

# CAKE's aggregate rate is a separate number and stays separate.
SHAPE=1; SHAPE_PCT=95
[[ "$(target_qdisc 2000 180)" == *"bandwidth 1900000kbit"* ]] \
  || fail 'the shaper still derives from the port speed by default'
SHAPER_MBPS=800
[[ "$(target_qdisc 2000 180)" == *"bandwidth 800000kbit"* ]] \
  || fail 'an explicit shaper rate overrides the derivation'
SHAPER_MBPS=''; SHAPE=0; PROFILE=noshape
pass 'the shaping rate and the port speed are separate numbers'


# ── 0.23.0 旧配置迁移 ──────────────────────────────────────────────────────
# A pre-0.23.0 config carries EGRESS_MBPS. Migrating it to LINK_MBPS is right;
# carrying it into FLOW_MAXRATE_MBPS would keep the exact rate limit this
# release exists to remove, and would do it silently.
CONFIG_FILE="$(mktemp)"
printf 'EGRESS_MBPS=2000\nCOVER_RTT_MS=180\nPROFILE=noshape\nSHAPE=0\n' > "$CONFIG_FILE"
LINK_MBPS=''; FLOW_MAXRATE_MBPS=0; MIGRATED_FROM_EGRESS=0
load_config
assert_eq '2000' "$LINK_MBPS" 'an old EGRESS_MBPS migrates to the port speed'
assert_eq '0' "$FLOW_MAXRATE_MBPS" 'and is NOT inherited as a single-flow limit'
assert_eq '1' "$MIGRATED_FROM_EGRESS" 'the migration is flagged so it can be announced'
[[ "$(migration_notice 2>&1)" == *"单流上限现在默认没有"* ]] \
  || fail 'the migration must say what changed'
pass 'an old config migrates without inheriting its hidden rate limit'
rm -f "$CONFIG_FILE"

# 0.26.0 also stored 128 KiB unconditionally. It must be retired from an old
# config, but the same number remains a valid explicit experiment after the
# new schema marker has made that intent distinguishable.
CONFIG_FILE="$(mktemp)"
printf 'NOTSENT_LOWAT=131072\n' > "$CONFIG_FILE"
NOTSENT_LOWAT=0; MIGRATED_NOTSENT_LOWAT=0
load_config
assert_eq '0' "$NOTSENT_LOWAT" 'the inherited 128 KiB application cap is retired'
assert_eq '1' "$MIGRATED_NOTSENT_LOWAT" 'the notsent migration is announced'
printf 'CONFIG_VERSION=27\nNOTSENT_LOWAT=131072\n' > "$CONFIG_FILE"
NOTSENT_LOWAT=0; MIGRATED_NOTSENT_LOWAT=0
load_config
assert_eq '131072' "$NOTSENT_LOWAT" 'a current explicit 128 KiB experiment is preserved'
assert_eq '0' "$MIGRATED_NOTSENT_LOWAT" 'a current config is not migrated again'
rm -f "$CONFIG_FILE"

# 0.28.0 moves only the two throughput profiles to a warm start. The exact old
# preset migrates once; a current schema carrying the same numbers is an
# operator choice and must not be overwritten.
CONFIG_FILE="$(mktemp)"
printf 'CONFIG_VERSION=27\nPROFILE=noshape\nSHAPE=0\nINITCWND=20\nBUF_DEFAULT=0\n' > "$CONFIG_FILE"
PROFILE=balanced; SHAPE=1; INITCWND=20; BUF_DEFAULT=0; MIGRATED_FAST_START=0
load_config
assert_eq '64|1048576' "$INITCWND|$BUF_DEFAULT" \
  'the old no-shape preset migrates to the warm start'
assert_eq '1' "$MIGRATED_FAST_START" 'the warm-start migration is announced'
printf 'CONFIG_VERSION=27\nPROFILE=speed\nSHAPE=1\nINITCWND=32\nBUF_DEFAULT=0\n' > "$CONFIG_FILE"
PROFILE=balanced; SHAPE=1; INITCWND=20; BUF_DEFAULT=0; MIGRATED_FAST_START=0
load_config
assert_eq '64|1048576' "$INITCWND|$BUF_DEFAULT" \
  'the old high-throughput shaped preset migrates too'
printf 'CONFIG_VERSION=28\nPROFILE=noshape\nSHAPE=0\nINITCWND=20\nBUF_DEFAULT=0\n' > "$CONFIG_FILE"
PROFILE=balanced; SHAPE=1; INITCWND=64; BUF_DEFAULT=1048576; MIGRATED_FAST_START=0
load_config
assert_eq '20|0' "$INITCWND|$BUF_DEFAULT" \
  'a current explicit cold start is preserved'
assert_eq '0' "$MIGRATED_FAST_START" 'the current profile is not migrated twice'
rm -f "$CONFIG_FILE"
CONFIG_FILE="/etc/tcpwide.conf"
MIGRATED_FROM_EGRESS=0
MIGRATED_NOTSENT_LOWAT=0
MIGRATED_FAST_START=0
apply_profile balanced


# ── 0.23.0 持久化复现实际布局 ──────────────────────────────────────────────
# The unit used to bake in `tc qdisc replace ... root <spec>`, so a machine on
# the mq-leaves layout came back after a reboot as a single root fq -- a
# different structure from the one apply built, which the drift check then
# reported as someone overwriting the queue. The unit now runs the same code
# path apply runs, so it cannot drift from apply.
IFACE=eth0; INSTALL_PATH=/usr/local/lib/tcpwide/tcpwide.sh
for layout in root mq-leaves; do
  line="$(QDISC_LAYOUT=$layout persist_qdisc_exec 2000 180)"
  [[ "$line" == *"apply-link"* ]] \
    || fail "the $layout unit must replay through apply-link: [$line]"
  [[ "$line" != *"qdisc replace"* ]] \
    || fail "the $layout unit must not hand-write tc: [$line]"
done
pass 'both queue layouts persist through the same code path apply uses'
grep -q 'apply-link) cmd_apply_link' "$ROOT/tcpwide.sh" \
  || fail 'apply-link must be dispatchable, or the unit fails at boot'
pass 'apply-link is a real command'


# ── 0.23.0 同窗口采样 ──────────────────────────────────────────────────────
# The old diagnostic slept 5s for retransmission, THEN 5s for CPU, THEN read
# ss -- three readings from three disjoint windows, over a speedtest lasting
# 7-9 seconds. Telling a CPU ceiling from a window ceiling is a question about
# what was true AT THE SAME TIME, so disjoint windows cannot answer it.
diag_body="$(sed -n '/^panel_diagnose() {/,/^}/p' "$ROOT/tcpwide.sh")"
[[ "$diag_body" != *"retrans_rate "* ]] \
  || fail 'the diagnostic must not re-open its own sampling window for retransmission'
[[ "$diag_body" != *"busiest_core_pct "* ]] \
  || fail 'nor a second one for CPU'
[[ "$diag_body" == *"diag_sample"* ]] || fail 'it must take one shared window'
for reader in retrans_delta busiest_core_delta render_qdisc_delta render_nic_delta render_connections; do
  [[ "$diag_body" == *"$reader"* ]] || fail "$reader must read from the shared window"
done
pass 'every diagnostic reading comes from one sampling window'

# And the readers still compute the same numbers from snapshots handed to them.
a="$(printf 'TcpRetransSegs 10 0\nTcpOutSegs 100000 0\n')"
b="$(printf 'TcpRetransSegs 1010 0\nTcpOutSegs 200000 0\n')"
assert_eq '1.0000' "$(retrans_delta "$a" "$b")" 'retransmission is computed from two snapshots'
rc=0; retrans_delta "$a" "$a" >/dev/null 2>&1 || rc=$?
assert_eq '2' "$rc" 'and too few segments is still refused rather than guessed at'

# fq exposes the exact counter that settles whether flow_limit was binding.
# Generic drops/overlimits cannot substitute for it.
qa="$(mktemp)"; qb="$(mktemp)"
printf 'qdisc fq 8001: root\n Sent 100 bytes 10 pkt (dropped 1, overlimits 2 requeues 3)\n backlog 0b 0p requeues 3\n flows 1 (inactive 0 throttled 0)\n gc 0 highprio 0 throttled 0 flows_plimit 4\n' > "$qa"
printf 'qdisc fq 8001: root\n Sent 200 bytes 20 pkt (dropped 2, overlimits 5 requeues 4)\n backlog 1200b 1p requeues 4\n flows 1 (inactive 0 throttled 0)\n gc 0 highprio 0 throttled 0 flows_plimit 9\n' > "$qb"
assert_eq $'1\t2\t3\t0b\t4' "$(qdisc_totals "$qa")" \
  'qdisc totals retain the fq per-flow-limit counter'
DIAG_DIR="$(mktemp -d)"; cp "$qa" "$DIAG_DIR/qdisc.a"; cp "$qb" "$DIAG_DIR/qdisc.b"
out="$(render_qdisc_delta 2>&1)"
[[ "$out" == *"flows_plimit 5"* && "$out" == *"真的撞到了 flow_limit"* ]] \
  || fail 'the queue report must name an observed per-flow limit hit'
[[ "$out" != *"overlimits 非零：有整形器"* ]] \
  || fail 'generic overlimits must not be called proof of a shaper'
pass 'fq flow_limit is judged by its own counter'
rm -f "$qa" "$qb"; rm -rf "$DIAG_DIR"; DIAG_DIR=""


# ── 0.23.0 ss 指标：区分四种天花板 ─────────────────────────────────────────
# Peer window, congestion window, our own pacer and CPU are four different
# ceilings, and each has one field that settles it. Before 0.23.0 the parser
# read rtt/delivery_rate/snd_wnd/skmem only, so cwnd-limited and rwnd-limited
# were indistinguishable -- and the panel guessed, wrongly, twice.
ss_fixture="$(mktemp)"
{
  printf 'ESTAB 0 0 10.0.0.5:41234 36.151.164.132:443\n'
  printf '\t bbr rtt:142.2/4.1 mss:1448 cwnd:8400 bytes_sent:9000000000 bytes_received:120000'
  printf ' pacing_rate 977Mbps delivery_rate 958.3Mbps rwnd_limited:1200us(0.0%%)'
  printf ' sndbuf_limited:44000us(0.5%%) unacked:8380 retrans:0/840 rcv_space:14480'
  printf ' snd_wnd:16777216\n'
  printf '\t skmem:(r0,rb131072,t0,tb90995370,f4096,w13946880,o0,bl0,d0)\n'
} > "$ss_fixture"
row="$(ss_metrics "$ss_fixture")"
IFS=$'\t' read -r m_lcl m_peer m_rtt m_mss m_cwnd m_unacked m_wnd m_rcvsp \
  m_pace m_dlv m_rwnd m_snd m_retr m_rb m_tb m_wq m_sent m_recv <<< "$row"
# The whole point of the record is that it has eighteen columns and none of them
# shift, so assert the shape before picking fields out of it.
assert_eq '18' "$(awk -F'\t' '{print NF}' <<< "$row")" 'the metric row has every column'
assert_eq '142.2' "$m_rtt" 'rtt is parsed'
assert_eq '14480' "$m_rcvsp" 'rcv_space is parsed'
assert_eq '131072' "$m_rb" 'the receive buffer is parsed out of skmem'
assert_eq '13946880' "$m_wq" 'and wmem_queued'
assert_eq '9000000000' "$m_sent" 'bytes_sent survives'
assert_eq '120000' "$m_recv" 'and bytes_received, which is what tells the legs apart'
assert_eq '10.0.0.5:41234' "$m_lcl" 'the local address is captured, so the two legs can be told apart'
assert_eq '36.151.164.132:443' "$m_peer" 'and the peer'
assert_eq '1448' "$m_mss" 'mss is parsed'
assert_eq '8400' "$m_cwnd" 'cwnd is parsed'
assert_eq '8380' "$m_unacked" 'unacked is parsed, which is what gives bytes in flight'
assert_eq '16777216' "$m_wnd" 'snd_wnd is parsed'
assert_eq '977.0' "$m_pace" 'pacing_rate is parsed and converted to Mbps'
assert_eq '958.3' "$m_dlv" 'delivery_rate too'
assert_eq '0.0' "$m_rwnd" 'rwnd_limited is parsed as a percentage'
assert_eq '0.5' "$m_snd" 'sndbuf_limited too'
assert_eq '840' "$m_retr" 'retrans total is parsed'
assert_eq '90995370' "$m_tb" 'and the send buffer out of skmem'
pass 'every field needed to separate the four ceilings is parsed'

# A Gbps pacing_rate must not read as 1.2 Mbps.
printf 'ESTAB 0 0 10.0.0.5:1 1.2.3.4:443\n\t rtt:10/1 mss:1448 unacked:1 pacing_rate 1.2Gbps delivery_rate 800Mbps\n' > "$ss_fixture"
assert_eq '1200.0' "$(ss_metrics "$ss_fixture" | cut -f9)" 'Gbps is converted, not truncated'
rm -f "$ss_fixture"

# The verdicts have to follow the field that establishes them. In-flight at the
# congestion window with rwnd_limited near zero is a congestion ceiling, and
# saying "peer window" there is the mistake this release is correcting.
out="$(render_conn_evidence 1.2.3.4:443 142.2 1448 8400 8380 16777216 14480 977 958.3 0.0 0.5 840 131072 90995370 13946880 2>&1)"
[[ "$out" == *"指向拥塞窗口"* ]] || fail 'in-flight at cwnd with no rwnd limiting is a congestion ceiling'
[[ "$out" != *"指向对端接收窗口"* ]] || fail 'and must not be blamed on the peer'
pass 'a congestion ceiling is named as one'
out="$(render_conn_evidence 1.2.3.4:443 32.1 1448 180 12 0 2600000 70.1 61.2 41.2 0.0 3 31266816 4194304 20480 2>&1)"
[[ "$out" == *"指向对端接收窗口"* ]] || fail 'rwnd_limited above the threshold is a peer ceiling'
[[ "$out" == *"本机怎么调都拿不回来"* ]] || fail 'and must be named as external'
pass 'a peer ceiling is named as one, on the field that establishes it'
# In-flight well below BOTH windows with no retransmission rules two candidates
# out, and that is a finding rather than an absence of one -- it is most of the
# search space, and it is what the live Shanghai connection actually showed
# (31% of cwnd, 20% of the peer window, zero retransmission).
out="$(render_conn_evidence 1.2.3.4:443 100 1448 8000 2000 16777216 14480 2000 400 0.0 0.0 0 131072 8388608 1048576 2>&1)"
[[ "$out" == *"两个窗口都没用满"* ]] || fail 'unused windows must be stated, not passed over'
[[ "$out" == *"往发送侧看"* ]] || fail 'and must point at what is left'
pass 'ruling out the peer window and congestion control is reported as evidence'

# But with retransmission present the same ratios mean something else, so that
# claim must not be made.
out="$(render_conn_evidence 1.2.3.4:443 100 1448 8000 5600 16777216 14480 2000 400 0.0 0.0 40 131072 8388608 1048576 2>&1)"
[[ "$out" != *"两个窗口都没用满"* ]] || fail 'loss on the path is not an idle sender'
pass 'the ruled-out verdict requires the zero-retransmission it rests on'

# A ratio over 110% is not a finding, it is two numbers that do not belong in
# the same fraction. The idle Apple socket produced "实测已是 pacing_rate 的
# 1205%" from a stale delivery_rate over a live pacing_rate.
out="$(render_conn_evidence 17.253.83.132:443 151.7 128 1 1 0 0 4.4 53.0 0.0 0.0 8 1048576 1048576 0 2>&1)"
[[ "$out" != *1205* ]] || fail 'a nonsense ratio must never be printed'
[[ "$out" != *"pacing_rate 的"* ]] || fail 'a ratio past the ceiling must be refused outright'
pass 'ratios past 110% are refused rather than reported'
assert_eq '' "$(pct_or_nothing 100 0 || printf '')" 'a zero denominator yields nothing'
assert_eq '50' "$(pct_or_nothing 50 100)" 'and an ordinary ratio still comes through'


# ── 0.23.0 幂等 ────────────────────────────────────────────────────────────
# Applying twice must be a no-op the second time. This is not decoration: the
# `raise` ratchet was discovered exactly here -- a key that cannot converge is
# a key that either rewrites forever or refuses forever, and tcp_wmem was doing
# the second.
restore_lib
available_cc() { printf 'reno cubic bbr\n'; }
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
cpu_count() { printf '1\n'; }
LINK_MBPS=2000; COVER_RTT_MS=180; SHAPE=0; PROFILE=noshape
BUF_DEFAULT=0; NOTSENT_LOWAT=131072; FLOW_MAXRATE_MBPS=0
live_value() {
  awk -F'\t' -v k="$1" '$1 == k {print $2; found = 1}
    END { if (!found) print "" }' <<< "$FAKE_LIVE"
}
# Pretend the machine is already exactly at target.
FAKE_LIVE="$(target_sysctl 2000 180 | awk -F'\t' '{printf "%s\t%s\n", $1, $2}')"
n=0
while IFS=$'\t' read -r k v dir _; do
  [[ -n "$k" ]] || continue
  needs_write "$(live_value "$k")" "$v" "$dir" && { n=$((n + 1)); printf 'rewrites: %s\n' "$k" >&2; }
done < <(target_sysctl 2000 180)
assert_eq '0' "$n" 'a second apply against an already-applied machine writes nothing'

# And converging from below still happens once, then stops.
FAKE_LIVE="$(printf 'net.ipv4.tcp_wmem\t4096 16384 4194304\n')"
needs_write "$(live_value net.ipv4.tcp_wmem)" '4096 16384 45438293' 'raise,exact,raise' \
  || fail 'a machine below target must be raised'
FAKE_LIVE="$(printf 'net.ipv4.tcp_wmem\t4096 16384 45438293\n')"
if needs_write "$(live_value net.ipv4.tcp_wmem)" '4096 16384 45438293' 'raise,exact,raise'; then
  fail 'and must then be left alone'
fi
pass 'sysctl application converges in one step and stays converged'

# The queue spec is a pure function of the configuration: same inputs, same
# bytes. A spec that varies between calls makes drift detection meaningless.
assert_eq "$(target_qdisc 2000 180)" "$(target_qdisc 2000 180)" \
  'the queue spec is deterministic'
unset -f live_value


# ── 0.24.0 起步值必须从快照读，不能从活跃值读 ──────────────────────────────
# 0.23.0 fixed the ratchet in safe_value and welded it back on in start_size:
# BUF_DEFAULT=0 meant "keep the kernel's starting size", implemented as "read
# the live middle field". On a machine where tcpwide had already written 1 MB,
# the live value IS that 1 MB, so it preserved its own past mistake forever.
# The user's box came back from the 0.23.0 upgrade still on 4096 1048576 ...
restore_lib
SYSCTL_SNAP="$(mktemp)"
printf 'net.ipv4.tcp_rmem\t4096 131072 6291456\nnet.ipv4.tcp_wmem\t4096 16384 4194304\n' \
  > "$SYSCTL_SNAP"
live_value() { printf '4096 1048576 90995370\n'; }
BUF_DEFAULT=0
assert_eq '131072' "$(start_size net.ipv4.tcp_rmem)" \
  'the starting size comes from before tcpwide ran, not from what tcpwide wrote'
assert_eq '16384' "$(start_size net.ipv4.tcp_wmem)" 'same on the send side'
# No snapshot at all: a machine tcpwide has never applied to.
rm -f "$SYSCTL_SNAP"; SYSCTL_SNAP="/nonexistent/snapshot"
assert_eq '131072' "$(start_size net.ipv4.tcp_rmem)" 'no snapshot falls back to the kernel default'
assert_eq '16384' "$(start_size net.ipv4.tcp_wmem)" 'and on the send side'
BUF_DEFAULT=262144
assert_eq '262144' "$(start_size net.ipv4.tcp_wmem)" 'an explicit choice still wins'
BUF_DEFAULT=0
unset -f live_value


# ── 0.24.0 撤回一个键必须还原它 ────────────────────────────────────────────
# apply_sysctl only writes the keys it emits, so dropping a key from
# target_sysctl does not unset it -- it freezes it. 0.23.0 withdrew tcp_frto and
# tcp_no_metrics_save and neither moved on the machine it was withdrawn for:
# they were still 0 and 1 after the upgrade.
restore_lib
SYSCTL_SNAP="$(mktemp)"
printf 'net.ipv4.tcp_frto\t2\nnet.ipv4.tcp_no_metrics_save\t0\nnet.ipv4.tcp_notsent_lowat\t4294967295\n' > "$SYSCTL_SNAP"
live_value() {
  case "$1" in
    net.ipv4.tcp_frto) printf '0\n' ;;
    net.ipv4.tcp_no_metrics_save) printf '1\n' ;;
    net.ipv4.tcp_notsent_lowat) printf '131072\n' ;;
    *) printf '\n' ;;
  esac
}
sysctl_log="$(mktemp)"
sysctl() { [[ "$1" == -qw ]] && printf '%s\n' "$2" >> "$sysctl_log"; return 0; }
assert_eq '3' "$(restore_retired_sysctl 1000 190 2>/dev/null)" \
  'withdrawn and neutral optional keys are put back'
grep -qx 'net.ipv4.tcp_frto=2' "$sysctl_log" || fail 'tcp_frto must be restored from the snapshot'
grep -qx 'net.ipv4.tcp_no_metrics_save=0' "$sysctl_log" \
  || fail 'tcp_no_metrics_save must be restored from the snapshot'
grep -qx 'net.ipv4.tcp_notsent_lowat=4294967295' "$sysctl_log" \
  || fail 'the old 128 KiB default must be restored from the snapshot'
pass 'a withdrawn key is restored, not merely left alone'
# Already correct: nothing to do, and it must not churn.
: > "$sysctl_log"
live_value() { case "$1" in
  net.ipv4.tcp_frto) printf '2\n' ;;
  net.ipv4.tcp_notsent_lowat) printf '4294967295\n' ;;
  *) printf '0\n' ;;
esac; }
assert_eq '0' "$(restore_retired_sysctl 1000 190 2>/dev/null)" 'a key already at its target is left alone'
# No snapshot: fall back to the documented kernel default rather than guessing.
rm -f "$SYSCTL_SNAP"; SYSCTL_SNAP="/nonexistent/snapshot"
: > "$sysctl_log"
live_value() { case "$1" in net.ipv4.tcp_frto) printf '0\n' ;; *) printf '1\n' ;; esac; }
restore_retired_sysctl 1000 190 >/dev/null 2>&1
grep -qx 'net.ipv4.tcp_frto=2' "$sysctl_log" || fail 'without a snapshot the kernel default is used'
grep -qx 'net.ipv4.tcp_notsent_lowat=4294967295' "$sysctl_log" \
  || fail 'notsent_lowat also falls back to the documented kernel default'
pass 'the kernel default is the fallback when there is no snapshot'
# An explicit experiment remains managed and must not be immediately restored.
: > "$sysctl_log"
NOTSENT_LOWAT=262144
live_value() { case "$1" in net.ipv4.tcp_notsent_lowat) printf '131072\n' ;; *) printf '0\n' ;; esac; }
restore_retired_sysctl 1000 190 >/dev/null 2>&1
if grep -q '^net.ipv4.tcp_notsent_lowat=' "$sysctl_log"; then
  fail 'an explicit notsent target must not fight the optional restoration path'
fi
pass 'an explicit notsent_lowat remains a real target'
NOTSENT_LOWAT=0
rm -f "$sysctl_log"
unset -f live_value sysctl

# A key cannot be both retired and current, or apply would fight itself.
restore_lib
available_cc() { printf 'reno cubic bbr\n'; }
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
tgt="$(target_sysctl 1000 190)"
for entry in "${RETIRED_SYSCTL[@]}"; do
  IFS=$'\t' read -r rk _ <<< "$(printf '%b' "$entry")"
  awk -F'\t' -v k="$rk" '$1 == k {exit 1}' <<< "$tgt" \
    || fail "$rk is both retired and still emitted by target_sysctl"
done
pass 'no key is both withdrawn and still written'


# ── 0.24.0 apply 必须自证 ──────────────────────────────────────────────────
# Five bugs reached a live machine together in 0.23.0 and apply reported success
# for all five, because it checked tc's exit code and the qdisc kind and nothing
# else. A tool that changes system state has to be able to answer "did that
# work" -- and any one of those bugs would have printed itself here.
restore_lib
available_cc() { printf 'reno cubic bbr\n'; }
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
cpu_count() { printf '1\n'; }
IFACE=eth0; LINK_MBPS=2000; COVER_RTT_MS=180; SHAPE=0; PROFILE=noshape
BUF_DEFAULT=0; QDISC_LAYOUT=root; FLOW_MAXRATE_MBPS=0; NOTSENT_LOWAT=131072
SYSCTL_SNAP="$(mktemp)"
printf 'net.ipv4.tcp_rmem\t4096 131072 6291456\nnet.ipv4.tcp_wmem\t4096 16384 4194304\nnet.ipv4.tcp_frto\t2\nnet.ipv4.tcp_no_metrics_save\t0\n' > "$SYSCTL_SNAP"
# The machine exactly as the user reported it after upgrading to 0.23.0.
live_value() {
  case "$1" in
    net.ipv4.tcp_rmem|net.ipv4.tcp_wmem) printf '4096 1048576 90995370\n' ;;
    net.ipv4.tcp_frto) printf '0\n' ;;
    net.ipv4.tcp_no_metrics_save) printf '1\n' ;;
    *) printf '\n' ;;
  esac
}
tc() { printf 'qdisc fq 8006: root refcnt 2 limit 10240p flow_limit 2048p buckets 1024 quantum 3028b initial_quantum 15140b maxrate 1960Mbit\n'; }
out="$(verify_applied 2000 180 2>&1)" && fail 'verify must fail on a machine that did not take the change'
[[ "$out" == *"应用后仍与目标不符"* ]] || fail 'and must say so'
[[ "$out" == *"net.ipv4.tcp_wmem"* ]] || fail 'the frozen starting size must be listed'
[[ "$out" == *"net.ipv4.tcp_frto"* ]] || fail 'the withdrawn key must be listed'
[[ "$out" == *maxrate* ]] || fail 'the stale per-flow cap must be listed'
pass 'apply catches every one of the 0.23.0 failures instead of reporting success'

# And a machine that DID take the change says so plainly.
live_value() { awk -F'\t' -v k="$1" '$1 == k {print $2; f = 1} END {if (!f) print ""}' <<< "$FAKE_LIVE"; }
FAKE_LIVE="$(target_sysctl 2000 180 | awk -F'\t' '{printf "%s\t%s\n", $1, $2}')
net.ipv4.tcp_frto	2
net.ipv4.tcp_no_metrics_save	0"
tc() { printf 'qdisc fq 8006: root refcnt 2 limit 10240p flow_limit 2048p buckets 1024 quantum 3028b initial_quantum 15140b\n'; }
out="$(verify_applied 2000 180 2>&1)" || fail 'a correctly applied machine must verify clean'
[[ "$out" == *"回读一致"* ]] || fail 'and must say so'
pass 'a machine that did take the change verifies clean'
unset -f live_value tc


# ── 0.25.0 每秒一次采样，按连接自己的区间算 ────────────────────────────────
# Two endpoint dumps only measure a connection present at BOTH. A speedtest runs
# 8 seconds and the window is 8 seconds, so they cannot be aligned: any flow
# that opened or closed mid-window failed to pair up and was dropped in silence.
# Three consecutive diagnostics reported "no connection moved data" while the
# box pushed 400 Mbps at 58% of its only core.
restore_lib
DIAG_DIR="$(mktemp -d)"
mk_conn() {  # lcl peer sent recv [extra]
  printf 'ESTAB 0 0 %s %s\n' "$1" "$2"
  printf '\t bbr rtt:150/4 mss:1448 cwnd:4872 unacked:1508 snd_wnd:10700000 bytes_sent:%s bytes_received:%s delivery_rate 400Mbps %s\n' \
    "$3" "$4" "${5:-}"
  printf '\t skmem:(r0,rb131072,t0,tb3355443,f0,w2200000,o0,bl0,d0)\n'
}
# Nine dumps. The transfer exists only in 3..6 -- neither starting nor ending
# inside the window, which is the case that produced nothing at all.
for i in 0 1 2 3 4 5 6 7 8; do
  {
    printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
    mk_conn 10.0.0.5:22 119.237.129.39:51000 $(( 1000 + i * 100 )) $(( 2000 + i * 100 ))
    if (( i >= 3 && i <= 6 )); then
      mk_conn 10.0.0.5:443 58.38.51.162:61324 $(( 100000000 + (i - 3) * 50000000 )) 1000
    fi
    (( i == 8 )) && mk_conn 10.0.0.5:41234 17.253.83.132:443 1000 71500000
  } > "$DIAG_DIR/ss.$i"
done
DIAG_SS_LAST=8; DIAG_SECS=8
moved="$(ss_throughput)"
# 150 MB over the three seconds it was actually alive -- not over the window's
# eight, which would understate it by more than half.
assert_eq '400.0' "$(awk -F'\t' '/58.38.51.162/ {print $3}' <<< "$moved")" \
  'a mid-window transfer is measured over its own interval, not the window'
assert_eq 'ok' "$(awk -F'\t' '/58.38.51.162/ {print $4}' <<< "$moved")" 'and is marked usable'
assert_eq 'send' "$(awk -F'\t' '/58.38.51.162/ {print $6}' <<< "$moved")" \
  'the payload direction is kept separate from ACK bytes'
# The rejects are EMITTED, with a reason. Dropping them is what made the
# diagnostic unable to explain its own silence.
assert_eq 'onesample' "$(awk -F'\t' '/17.253.83.132/ {print $4}' <<< "$moved")" \
  'a connection seen once has no interval, and says so instead of vanishing'
assert_eq '3' "$(grep -c '' <<< "$moved")" 'every connection seen is accounted for'
pass 'throughput comes from each connection own first-and-last appearance'

# ss_metrics must see connections that ended before the window closed, or a
# measured transfer gets dropped at the next step for not being in one file.
rows="$(ss_metrics)"
[[ "$rows" == *58.38.51.162* ]] || fail 'a flow that ended mid-window must still be described'
assert_eq '3' "$(grep -c '' <<< "$rows")" 'the metric rows are the union across the window'
pass 'instantaneous fields come from where each connection was last seen'

# Every connection is accounted for in the output, by category.
ss() { [[ "$1" == -tlnH ]] && { printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'; return 0; }; }
has() { [[ "$1" == ss ]]; }
out="$(render_connections 2>&1)"
[[ "$out" == *"看到 3 条 ESTAB，入选 1 条"* ]] || fail "the tally must be stated: [$out]"
[[ "$out" == *"只在一个采样点出现"*17.253.83.132* ]] \
  || fail 'a rejected connection must be named along with its reason'
[[ "$out" == *"低于 5 Mbps"*119.237.129.39* ]] || fail 'and so must a too-slow one'
[[ "$out" == *58.38.51.162* ]] || fail 'the real transfer must survive the filter'
[[ "$out" == *"入站：对方连进来"* ]] || fail 'the leg is still identified by the listen port'
pass 'the diagnostic accounts for every connection it saw, rejects included'

# Listing a connection and judging its windows are separate decisions. A tiny
# MSS cannot support cwnd arithmetic, but that is no reason to hide a flow that
# is genuinely moving data.
for i in 0 1 2; do
  {
    printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
    printf 'ESTAB 0 0 10.0.0.5:9999 1.2.3.4:443\n'
    printf '\t bbr rtt:20/4 mss:128 cwnd:1 unacked:1 bytes_sent:%s bytes_received:1000\n' \
      $(( 50000000 * i ))
  } > "$DIAG_DIR/ss.$i"
done
for i in 3 4 5 6 7 8; do rm -f "$DIAG_DIR/ss.$i"; done
DIAG_SS_LAST=2
out="$(render_connections 2>&1)"
[[ "$out" == *"入选 1 条"* ]] || fail 'a small-MSS flow that is moving data is still listed'
[[ "$out" == *"不作判断"* ]] || fail 'but must decline to reason about its windows'
[[ "$out" != *"cwnd×mss 的 100%"* ]] || fail 'and must never claim 100% of a 128-byte window'
pass 'showing a connection and judging its windows are separate decisions'
unset -f ss has mk_conn
rm -rf "$DIAG_DIR"; DIAG_DIR=""; DIAG_SS_LAST=0


# ── 0.25.0 CPU 拆分与单核上限 ──────────────────────────────────────────────
# A percentage on its own is not actionable. The old code only warned at >=85%,
# so one core at 58% while the box pushed 405 Mbps said nothing -- and that was
# the strongest signal in the sample.
restore_lib
IFS=$'\t' read -r c_max c_avg c_n c_steal c_user c_soft <<< \
  "$(busiest_core_delta 'cpu0 1000 0 500 8000 0 10 200 0 0 0' \
                        'cpu0 1460 0 620 8420 0 12 320 0 0 0')"
assert_eq '63' "$c_max" 'the busiest core is measured'
assert_eq '63' "$c_avg" 'and the mean, which on one core is the same number'
assert_eq '1' "$c_n" 'and how many cores that mean covers'
assert_eq '52' "$c_user" 'user plus system is broken out'
assert_eq '11' "$c_soft" 'and irq plus softirq'
assert_eq '0' "$c_steal" 'steal stays its own column'
(( c_user + c_soft <= c_max + 1 )) || fail 'the split cannot exceed the total'
pass 'the busiest core is split into proxy work and network stack'

# The ceiling is throughput divided by utilisation, and it is only printed when
# there IS throughput -- otherwise there is no denominator and no claim to make.
diag_total_mbps() { printf '405\n'; }
out="$(render_cpu_ceiling 58 46 12 1 2>&1)"
[[ "$out" == *"单核上限约 698 Mbps"* ]] || fail "the implied ceiling must be stated: [$out]"
[[ "$out" == *"头号候选瓶颈"* ]] || fail 'and 58% must warn, where the old 85% threshold was silent'
[[ "$out" == *"四线程"* ]] || fail 'with the test that would settle it'
pass 'a core utilisation figure is turned into the ceiling it implies'
out="$(render_cpu_ceiling 90 70 20 1 2>&1)"
[[ "$out" == *"已经到顶"* ]] || fail 'at 90% the wording must be stronger'
pass 'a saturated core is called saturated'
out="$(render_cpu_ceiling 20 15 5 1 2>&1)"
[[ "$out" != *"候选瓶颈"* ]] || fail 'an idle core must not be blamed'
pass 'a core with headroom raises nothing'
# No measured throughput means no extrapolation.
diag_total_mbps() { return 1; }
out="$(render_cpu_ceiling 58 46 12 1 2>&1)"
[[ "$out" != *"单核上限"* ]] || fail 'a ceiling cannot be computed without a denominator'
pass 'no throughput measured means no ceiling claimed'
unset -f diag_total_mbps

# The old floor stays where the old code still needs it.
assert_eq '50' "$SAMPLE_MBPS_FLOOR" 'the delivery_rate path keeps its protective floor'
assert_eq '5' "$DIAG_MIN_MBPS" 'and the measured path uses a much lower one'


# ── 0.26.0 每秒序列：一个平均值描述不了不稳 ────────────────────────────────
# A link bursting to 1.4 Gbps and stalling has the same eight-second average as
# one running steadily at 750, and they are not the same problem. On the live
# node the same connection was caught with in-flight at exactly 100% of the
# peer's window -- instantaneously capable of 1432 Mbps -- while its
# eight-second average read 426.
restore_lib
DIAG_DIR="$(mktemp -d)"
series_fixture() {  # rates...
  local i=0 by=0 r
  for r in "$@"; do
    {
      printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
      printf 'ESTAB 0 0 10.0.0.5:443 [::ffff:58.38.51.162]:5602\n'
      printf '\t bbr rtt:131.8/4 mss:1448 cwnd:46935 unacked:16308 snd_wnd:23592960'
      printf ' bytes_sent:%s bytes_received:1000 pacing_rate 4112.7Mbps' "$by"
      printf ' rwnd_limited:8000us(8.1%%) sndbuf_limited:24000us(24.0%%) retrans:0/0\n'
      printf '\t skmem:(r0,rb131072,t0,tb90995370,f0,w20000000,o0,bl0,d0)\n'
    } > "$DIAG_DIR/ss.$i"
    by=$(( by + r * 125000 ))
    i=$(( i + 1 ))
  done
  DIAG_SS_LAST=$(( i - 1 ))
}
series_fixture 1400 1400 120 100 1400 1400 110 90 0
row="$(ss_throughput)"
IFS=$'\t' read -r _ _ overall status series direction <<< "$row"
assert_eq 'ok' "$status" 'the burst-stall connection is measurable'
assert_eq 'send' "$direction" 'a send-heavy sample is labelled as send'
assert_eq '1400 1400 120 100 1400 1400 110 90' "$series" \
  'the per-second series reproduces the shape the average hides'
# The average is not wrong, it is answering a different question.
assert_eq '752.5' "$overall" 'and the eight-second average is what it always was'
IFS=$'\t' read -r sp_lo sp_med sp_hi <<< "$(series_spread "$series")"
assert_eq '90' "$sp_lo" 'the floor of the swing is reported'
assert_eq '760' "$sp_med" 'and the median, which is neither the peak nor the average'
assert_eq '1400' "$sp_hi" 'and the peak'
render_series_swing "$series" >/dev/null || fail 'a 15x swing must be called out'
pass 'a swinging link is distinguished from a steady one at the same average'

# A steady link must NOT be accused of swinging.
series_fixture 700 720 690 710 700 705 695 700 0
IFS=$'\t' read -r _ _ _ _ series _ <<< "$(ss_throughput)"
if render_series_swing "$series" >/dev/null 2>&1; then
  fail 'a link within a few percent of steady is not a swing'
fi
pass 'a steady link raises nothing'

# A proxy sees the same payload on its receive leg and its send leg. The old
# sum counted both and doubled the throughput used for the CPU extrapolation.
for i in 0 1 2; do
  {
    printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
    printf 'ESTAB 0 0 10.0.0.5:50000 203.0.113.10:443\n'
    printf '\t bytes_sent:1000 bytes_received:%s\n' $(( 1000 + i * 12500000 ))
    printf 'ESTAB 0 0 10.0.0.5:443 198.51.100.20:60000\n'
    printf '\t bytes_sent:%s bytes_received:1000\n' $(( 1000 + i * 12500000 ))
  } > "$DIAG_DIR/ss.$i"
done
for i in 3 4 5 6 7 8; do rm -f "$DIAG_DIR/ss.$i"; done
DIAG_SS_LAST=2
rows="$(ss_throughput)"
assert_eq 'recv' "$(awk -F'\t' '/203.0.113.10/ {print $6}' <<< "$rows")" \
  'the upstream relay leg is receive-heavy'
assert_eq 'send' "$(awk -F'\t' '/198.51.100.20/ {print $6}' <<< "$rows")" \
  'the downstream relay leg is send-heavy'
assert_eq '100.0' "$(diag_total_mbps)" \
  'one 100 Mbps relayed payload is not reported as 200 Mbps'
pass 'relay legs are separated instead of double-counted'

# The extrapolation has to rest on the median, not on a peak. One 1.4 Gbps
# second inside a window whose core was 8% busy produced "单核上限约 9882 Mbps".
series_fixture 1400 100 100 100 100 100 100 100 0
total="$(diag_total_mbps)"
awk -v t="$total" 'BEGIN {exit !(t < 200)}' \
  || fail "the total must follow the median, not the peak: got $total"
pass 'one burst cannot drag the single-core extrapolation up with it'
rm -rf "$DIAG_DIR"; DIAG_DIR=""; DIAG_SS_LAST=0
unset -f series_fixture


# ── 0.26.0 对端窗口换算成 Mbps ─────────────────────────────────────────────
# 22.5 MB is a number; 1432 Mbps is the ceiling it is. The live node measured a
# 1400 Mbps peak against exactly this window, which is what settles where the
# peak comes from -- and it is the client's rmem, not anything on this box.
restore_lib
live_value() { case "$1" in *notsent_lowat) printf '131072\n' ;; *) printf '\n' ;; esac; }
out="$(render_conn_evidence 1.2.3.4:443 131.8 1448 46935 16308 23592960 14480 \
  4112.7 426 8.1 0.0 0 131072 90995370 20000000 '' 90995370 2>&1)"
[[ "$out" == *"1432 Mbps 的上限"* ]] || fail "the peer window must be stated as a rate: [$out]"
[[ "$out" == *"指向对端接收窗口"* ]] || fail 'in-flight at the window is a peer ceiling'
[[ "$out" == *"÷ RTT 131.8 ms = 1432 Mbps"* ]] || fail 'and the verdict must carry the arithmetic'
[[ "$out" == *"客户端的 rmem"* ]] || fail 'and say whose it is'
pass 'the peer window is reported as the rate ceiling it represents'

# On a receive-heavy leg those fields describe the tiny reverse/ACK direction.
# Treating local retrans=0 as proof the remote sender saw no loss was the exact
# category error that made 0.26.0 blame every swing on application refill.
out="$(render_conn_evidence 1.2.3.4:443 131.8 1448 46935 16308 23592960 14480 \
  4112.7 426 8.1 0.0 0 131072 90995370 20000000 '1400 100 1400 100' 90995370 recv 2>&1)"
[[ "$out" == *"主数据方向  接收"* ]] || fail 'a receive-heavy leg must be labelled'
[[ "$out" == *"反向小流"* ]] || fail 'local sender metrics must be scoped to their real direction'
[[ "$out" != *"所以掉下去的那几秒不是丢包"* ]] \
  || fail 'local retrans=0 cannot clear loss on a remote sender'
[[ "$out" != *"指向对端接收窗口"* ]] \
  || fail 'snd_wnd on the ACK direction cannot cap the received payload'
pass 'receive-heavy legs do not inherit send-side verdicts'


# ── 0.26.0 sndbuf 已经顶到 wmem_max 时不能说「wmem 不够」 ──────────────────
# The live node was told "wmem 不够" against an sndbuf of 86.8 MB -- which IS
# wmem_max. That sends the operator to a knob that cannot move. When the buffer
# is already at the ceiling the remaining candidate is how fast the application
# refills it, and notsent_lowat is what governs that.
out="$(render_conn_evidence 1.2.3.4:443 131.8 1448 46935 8000 23592960 14480 \
  4112.7 426 0.0 24.0 0 131072 90995370 20000000 '' 90995370 2>&1)"
[[ "$out" != *"wmem 不够"* ]] || fail 'wmem cannot be the fix when sndbuf is already wmem_max'
[[ "$out" == *"已经贴着 wmem_max"* ]] || fail 'it must say the buffer is at its ceiling'
[[ "$out" == *"notsent_lowat"* ]] || fail 'and name the knob that can still move'
[[ "$out" == *ms* ]] || fail 'expressed as time, which is the unit that makes it decidable'
pass 'a buffer at its ceiling points at the refill rate, not at the ceiling'

# But a buffer with room left really is still growing, and says so.
out="$(render_conn_evidence 1.2.3.4:443 131.8 1448 46935 8000 23592960 14480 \
  4112.7 426 0.0 24.0 0 131072 4194304 20000000 '' 90995370 2>&1)"
[[ "$out" == *"还没长到 wmem_max"* ]] || fail 'a growing buffer is described as growing'
[[ "$out" != *"已经贴着"* ]] || fail 'and not as capped'
pass 'a buffer with headroom is described differently from one without'
unset -f live_value


# ── 0.26.0 拒绝列表去重 ────────────────────────────────────────────────────
# The raw list dumped sixteen addresses on one line with 184.28.121.22:80 four
# times over. A list nobody reads is not accountability.
restore_lib
out="$(summarise_peers 'a:80 b:443 a:80 c:80 a:80 d:80 e:80 f:80 a:80')"
[[ "$out" == *"a:80×4"* ]] || fail "duplicates must fold with a count: [$out]"
[[ "$(grep -o 'a:80' <<< "$out" | grep -c '')" == 1 ]] || fail 'and appear once'
[[ "$out" == *"还有 1 个地址"* ]] || fail 'and the tail must say how many were left out'
assert_eq '5' "$(grep -oE '[a-f]:[0-9]+' <<< "$out" | grep -c '')" \
  'at most five addresses are listed'
pass 'the reject list folds duplicates and truncates'

printf '\n%s\n' "All tcpwide self-tests passed ($PASS_COUNT assertions)."
