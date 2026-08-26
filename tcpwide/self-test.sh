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
  printf 'PASS: %s\n' "$label"
}
pass() { printf 'PASS: %s\n' "$1"; }
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
  win=$(( $(buffer_ceiling 1000 "$rtt") / 2 ))
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
assert_eq '1' "$(key net.ipv4.tcp_no_metrics_save)" 'a bad moment is not cached into the next connection'
assert_eq bbr "$(key net.ipv4.tcp_congestion_control)" 'the chosen congestion control lands in the set'
assert_eq "$(buffer_ceiling 500 250)" "$(key net.core.rmem_max)" 'the ceiling follows the coverage envelope'
# Every ceiling above is computed as twice the BDP, which is only right when the
# application gets half of the receive buffer. At 2 it gets a quarter and all of
# them are wrong by a factor of two, so the assumption is stated, not assumed.
assert_eq '1' "$(key net.ipv4.tcp_adv_win_scale)" 'the half-of-buffer assumption is asserted, not assumed'
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
# At 400 Mbps a 16KB allowance is 0.33ms of data, so a userspace proxy has to
# finish a whole wake/read/decrypt/write cycle inside it. A bracketed A/B/A on
# the live node — the only structure that reads anything on a path where the
# same config drifted 21% in 14 minutes — put 131072 at +18% average and +11%
# peak against the interpolated 16384 baseline.
assert_eq '131072' "$(key net.ipv4.tcp_notsent_lowat)" \
  'the measured unsent allowance is the default'
# It stays a knob, because one B sample and a two-point trend is weak evidence
# and the latency direction is a legitimate choice.
NOTSENT_LOWAT=0; tgt="$(target_sysctl 500 250)"
assert_eq '' "$(key net.ipv4.tcp_notsent_lowat)" \
  'zero means leave the system value alone'
NOTSENT_LOWAT=262144; tgt="$(target_sysctl 500 250)"
assert_eq '262144' "$(key net.ipv4.tcp_notsent_lowat)" \
  'an explicitly chosen allowance is applied exactly'
NOTSENT_LOWAT=131072; tgt="$(target_sysctl 500 250)"
while IFS=$'\t' read -r k v dir why; do
  [[ -n "$k" && -n "$v" && -n "$why" ]] || fail "key $k is missing a value or a rationale"
  [[ "$dir" =~ ^(exact|raise|lower)$ ]] || fail "key $k has no safe direction"
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
[[ "$spec" == 'fq maxrate 475mbit'* ]] \
  || fail 'unshaped still paces each flow at the line rate'
pass 'unshaped still paces each flow at the line rate'
# The queue limits come from netshape-manager, whose author reports it
# saturating a port on a single thread. flow_limit is the one that matters:
# it is a PER-FLOW packet quota, so N flows each get their own 100 and the
# kernel default cannot hold back an aggregate transfer while it can hold back
# a single one. That is the exact shape of 558 Mbps on one thread against 917
# on several, same backend, seconds apart.
assert_eq 'fq maxrate 475mbit limit 40960 flow_limit 8192' "$spec" \
  'the fq queue limits follow netshape rather than the kernel default'
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
assert_eq 'fq maxrate 475mbit limit 10240 flow_limit 2048' "$(target_qdisc 500 250)" \
  'a box under 1 GB gets the smaller rung of that ladder'
# Still overridable, so it can be A/B'd back to the kernel values.
FQ_LIMIT=10000; FQ_FLOW_LIMIT=100
assert_eq 'fq maxrate 475mbit limit 10000 flow_limit 100' "$(target_qdisc 500 250)" \
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
EGRESS_MBPS=""
if ( SHAPE=1; require_egress ) 2>/dev/null; then
  fail 'shaping without a bandwidth figure must be refused'
fi
pass 'shaping refuses to guess the line rate'
if ! ( SHAPE=0; EGRESS_MBPS=""; target_qdisc 200 250 >/dev/null ) 2>/dev/null; then
  fail 'no-shape mode must work without a bandwidth figure'
fi
pass 'no-shape mode needs no bandwidth figure'


# ── 0.2.0 配置持久化 ───────────────────────────────────────────────────────
tmp="$(mktemp -d)"; CONFIG_FILE="$tmp/tcpwide.conf"
EGRESS_MBPS=750; COVER_RTT_MS=300; INITCWND=32; SHAPE_PCT=90
SHAPE=1; PERSIST=1; PROFILE=stable; IFACE=ens3
save_config
EGRESS_MBPS=1; COVER_RTT_MS=10; INITCWND=1; SHAPE_PCT=50
SHAPE=0; PERSIST=0; PROFILE=balanced; IFACE=lo
load_config
assert_eq '750'    "$EGRESS_MBPS"  'egress survives a config round trip'
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
# Profiles move three numbers and nothing else. A preset that quietly swapped in
# a different mechanism would make the panel a liar about what is running.
apply_profile stable
assert_eq '90|16|1' "$SHAPE_PCT|$INITCWND|$SHAPE" 'the stable profile trades peak for headroom'
apply_profile balanced
assert_eq '95|20|1' "$SHAPE_PCT|$INITCWND|$SHAPE" 'the balanced profile is the documented middle'
apply_profile speed
assert_eq '98|32|1' "$SHAPE_PCT|$INITCWND|$SHAPE" 'the speed profile shapes closer to the line rate'
apply_profile noshape
assert_eq '0' "$SHAPE" 'the no-shape profile stops shaping'
[[ "$(target_qdisc 500 250)" == 'fq maxrate 490mbit'* ]] \
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
IFACE=eth0; EGRESS_MBPS=500; COVER_RTT_MS=250; SHAPE=1
tc() { printf 'qdisc mq 0: root \n'; }
assert_eq 'mq' "$(qdisc_drift)" 'a live mq root against a cake config reports drift'
tc() { printf 'qdisc cake 8001: root refcnt 2 bandwidth 475Mbit\n'; }
if qdisc_drift >/dev/null 2>&1; then fail 'a matching qdisc must not report drift'; fi
pass 'a matching qdisc reports no drift'
SHAPE=0
tc() { printf 'qdisc fq 8001: root refcnt 2\n'; }
if qdisc_drift >/dev/null 2>&1; then fail 'fq matches the no-shape target'; fi
pass 'fq matches the no-shape target'
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
# And the global memory budget must be surfaced: a per-socket ceiling above a
# meaningful share of tcp_mem is theoretical, because a handful of flows hit
# global pressure first and the kernel shrinks them all.
[[ "$(render_panel 2>/dev/null)" == *"tcp_mem"* ]] \
  || fail 'the panel must surface the global tcp_mem budget beside the ceiling'
pass 'the panel shows the global memory budget beside the per-socket ceiling'
[[ "$(render_panel 2>/dev/null)" == *"实际生效的队列是 mq"* ]] \
  || fail 'the panel must warn when the live qdisc differs from the config'
pass 'the panel warns about a drifted qdisc'
unset -f ip tc sysctl has conflicting_tool


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
assert_eq "$((958 * 1024 * 1024 / 4096 / 4))" "$tm_max" \
  'the global budget cap is a quarter of RAM in pages'
[[ "$tm_low" -lt "$tm_pres" && "$tm_pres" -lt "$tm_max" ]] \
  || fail 'the three tcp_mem thresholds must be ordered'
pass 'the tcp_mem thresholds are ordered low < pressure < max'
# One socket takes at most a quarter of the budget, so four large flows still
# fit before the kernel starts shrinking everyone. Four rather than eight
# because on a small box with a fast port, eight would cap a single flow well
# under the port — and tcp_mem itself is the backstop that prevents an OOM.
buf="$(buffer_ceiling 500 250)"
(( buf * 4 <= tm_max * 4096 )) \
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


# ── 0.3.7 BBR 版本判定 ─────────────────────────────────────────────────────
# BBRv3 has never been in mainline, so a stock kernel offering only "bbr" is
# offering v1. But XanMod ships v3 under that same name, replacing the mainline
# one, so the algorithm name alone cannot tell them apart and check would have
# told a XanMod user they were on v1.
assert_eq v1 "$(bbr_variant 'reno cubic bbr' '6.1.0-50-amd64')" \
  'a stock Debian kernel offering only bbr is offering v1'
assert_eq nonstock "$(bbr_variant 'reno cubic bbr' '6.6.7-x64v3-xanmod1')" \
  'an out-of-tree kernel is not claimed to be v1 just because the name is bbr'
assert_eq v3 "$(bbr_variant 'reno cubic bbr bbr3' '6.1.0-50-amd64')" \
  'an explicit bbr3 wins over the kernel-provenance guess'
assert_eq v2 "$(bbr_variant 'reno cubic bbr bbr2' '6.1.0-50-amd64')" 'bbr2 is recognised'
assert_eq none "$(bbr_variant 'reno cubic' '6.1.0-50-amd64')" 'a kernel without BBR says so'
[[ "$(bbr_variant_note v1)" == *"最大值滤波"* ]] \
  || fail 'the v1 note must explain the stale bandwidth estimate'
pass 'each variant carries an explanation of what it means'


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
assert_eq '98|20|0' "$SHAPE_PCT|$INITCWND|$SHAPE" 'the no-shape profile sets every value it depends on'
apply_profile stable
apply_profile noshape
assert_eq '98|20|0' "$SHAPE_PCT|$INITCWND|$SHAPE" 'and does so regardless of what preceded it'
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
EGRESS_MBPS=""
out="$( ( need_root() { :; }; cmd_install ) < /dev/null 2>&1 )" || true
[[ "$out" == *"非交互安装需要 --egress"* ]] \
  || fail 'a non-interactive install without an egress figure must say so'
# The suggested wizard form must be one that survives sudo. `sudo bash <(curl …)`
# does not: sudo closes descriptors above 2, so the /dev/fd entry the process
# substitution created in the outer shell is gone before bash opens it.
[[ "$out" == *"-o /tmp/tcpwide.sh"* ]] || fail 'and must name a wizard form that works under sudo'
[[ "$out" != *"bash <(curl"* ]] || fail 'must not suggest a form sudo breaks'
pass 'a non-interactive install demands its parameters and names the wizard form'
EGRESS_MBPS=500


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
[[ "$out" != *"32.5 MB/socket"* ]] || fail 'the wizard table must not use the pre-0.9.1 clamp'
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

# A ceiling that is not being reached is not the constraint.
live_value() { printf '34123264\n'; }   # the 32.5 MB ceiling 0.9.0 applied
IFS=$'\t' read -r sup _ pct <<< "$(window_headroom 146 639.7)"
assert_eq '935' "$sup" 'the live ceiling supports 935 Mbps at 146 ms'
(( pct < 75 )) || fail 'a flow at 68% of what the window allows is not window-limited'
pass 'headroom against the live ceiling is reported, not assumed away'
# And when a flow really is pinned to the window, it must not be waved off.
IFS=$'\t' read -r sup _ pct <<< "$(window_headroom 146 920)"
(( pct >= 75 )) || fail 'a flow at 98% of the window must read as window-limited'
pass 'a genuinely window-limited flow still reads as one'
unset -f live_value

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
SHAPE=0; EGRESS_MBPS=1000; COVER_RTT_MS=250; QDISC_LAYOUT=mq-leaves
if qdisc_drift >/dev/null 2>&1; then fail 'mq carrying fq leaves is the intended layout, not drift'; fi
pass 'mq with fq leaves does not read as drift'
# Shaping is the one case that still has to take the root: CAKE can only shape
# what it can all see. An mq root there is real drift.
SHAPE=1
assert_eq 'mq' "$(qdisc_drift)" 'under shaping an mq root really is drift'
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
assert_eq 'mq' "$(qdisc_drift)" 'a half-paced mq root reads as drift'
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
grep -q 'qdisc replace dev eth0 root fq' "$root_log" \
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
esac; }
canonical_qdisc() { printf 'fq maxrate 980Mbit\n'; }
current_default_route() { printf 'default via 10.0.0.1 dev eth0 initcwnd 20\n'; }
COVER_RTT_MS=176
fp="$(config_fingerprint)"
for want in "$VERSION" bbr 43.3 'fq maxrate 980Mbit' 'initcwnd 20' '176 ms'; do
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
assert_eq '3' "$(wc -l < "$MEASURE_LOG")" 'the refused reading did not reach the log'
# A tab in the note would split the record into the wrong fields.
FAKE_Q='fq maxrate 950mbit' record_measurement 100 "$(printf 'a\tb')"
assert_eq '4' "$(awk -F'\t' 'NF == 6' "$MEASURE_LOG" | wc -l)" \
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
assert_eq 'fq maxrate 980mbit limit 40960 flow_limit 8192' "$(target_qdisc 1000 200)" \
  'an untouched initial_quantum adds nothing to the spec'
FQ_INITIAL_QUANTUM=65536
assert_eq 'fq maxrate 980mbit limit 40960 flow_limit 8192 initial_quantum 65536' \
  "$(target_qdisc 1000 200)" 'a set burst allowance reaches the spec'
FQ_INITIAL_QUANTUM=0

# ── 0.13.0 覆盖 RTT 的建议值不该越过拐点 ───────────────────────────────────
# The wizard said "above 173 ms the buffer stops growing" and recommended 200 in
# the same breath. Two numbers on screen arguing with each other.
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
knee="$(buffer_knee_ms 1000)"
assert_eq '173' "$knee" 'the knee is where the budget stops growing'
(( knee < 200 )) || fail 'this box must have its knee below the 200 the wizard suggested'
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
grep -q 'fq maxrate 已经在给每条流限速' "$ROOT/tcpwide.sh" \
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
record_measurement 927.14 '黄石' 1 155
record_measurement 881.27 '黄石' 1 163
record_measurement 583.23 '深圳' 1 192
record_measurement 580.54 '岳阳' 1 202
assert_eq '4' "$(window_utilisation | wc -l)" 'only the readings carrying an RTT are analysed'
IFS=$'\t' read -r wu_note _ _ _ wu_pct <<< "$(window_utilisation | sed -n 1p)"
assert_eq '黄石' "$wu_note" 'the table leads with the backend using the most window'
assert_eq '79' "$wu_pct" 'the fastest backend reaches 79% of the advertised window'
# The two 黄石 points are the evidence for a fixed window: same in-flight bytes
# at two different RTTs, so the rate difference is entirely the RTT.
a="$(window_utilisation | awk -F'\t' '$2 == 155 {print $4}')"
b="$(window_utilisation | awk -F'\t' '$2 == 163 {print $4}')"
awk -v x="$a" -v y="$b" 'BEGIN {exit !(x > 0 && y > 0 && (x - y < 0.05) && (y - x < 0.05))}' \
  || fail "the two 黄石 points must imply the same in-flight bytes, got $a and $b"
pass 'two RTTs on one backend imply the same bytes in flight'
# Multi-thread readings are excluded: their in-flight is spread over N flows, so
# dividing by one window would overstate what a single flow reached.
record_measurement 917.4 '多线程' 4 175
assert_eq '4' "$(window_utilisation | wc -l)" 'a multi-thread reading stays out of the per-flow analysis'
# Under the threshold the report must say the buffer is NOT the limit, because
# the expensive wrong move here is buying a machine with more memory.
out="$(render_window_report 2>&1)"
[[ "$out" == *"本机缓冲不是瓶颈"* ]] || fail 'below the threshold the buffer must be cleared'
[[ "$out" == *"换内存更大的机器，对这台都不会有任何作用"* ]] \
  || fail 'and the expensive wrong move must be named'
[[ "$out" == *"notsent_lowat"* ]] || fail 'the remaining levers must be ranked'
pass 'a buffer with headroom is cleared and the remaining levers are ranked'
# And when something really is pressed against the window, say so instead.
record_measurement 1150 '近端' 1 155
out="$(render_window_report 2>&1)"
[[ "$out" == *"缓冲就是瓶颈"* ]] || fail 'a backend at the window must be reported as buffer-limited'
pass 'a backend pressed against the window is reported as buffer-limited'
rm -rf "$STATE_DIR"
unset -f live_value canonical_qdisc current_default_route


# ── 0.15.1 notsent_lowat 的争议已被实测裁决 ────────────────────────────────
# netshape sets tcp_notsent_lowat to 16384 above 120ms RTT; tcpwide kept
# 131072. Measured head to head on 岳阳 at ~200ms, 55 seconds apart:
#   131072  201ms  avg 458.46  max 568.42
#   16384   198ms  avg 282.13  max 341.16   -40% peak, -38% average
# And the 131072 arm reproduced: 580.54 at 09:12 and 568.42 at 09:25, 2.1%
# apart across 13 minutes, with 16384 sitting 40% below both. Two A readings
# around one B is an A/B/A in everything but name.
restore_lib
available_cc() { printf 'reno cubic bbr\n'; }
total_ram_bytes() { printf '%s\n' $((520 * 1024 * 1024)); }
NOTSENT_LOWAT=131072
why="$(target_sysctl 1000 200 | awk -F'\t' '$1 == "net.ipv4.tcp_notsent_lowat" {print $4}')"
[[ "$why" == *"568"* && "$why" == *"341"* ]] \
  || fail 'the rationale must carry the measurement that settled it'
[[ "$why" != *"证据不算强"* ]] || fail 'the weak-evidence caveat is obsolete'
pass 'the notsent_lowat rationale cites the measurement that settled it'
# The surviving claim is directional, not final: bigger beat smaller by 40%, and
# nothing above 131072 has been tried. Saying "settled" would stop the search at
# a value that was only ever the larger of two.
grep -q '262144 和 524288' "$ROOT/tcpwide.sh" \
  || fail 'the panel must name the untried larger values as the next test'
pass 'the next test is named rather than the question being closed'
# Every place that called this unresolved has to stop saying so, or the tool
# sends the operator to re-run a test that already has an answer.
for stale in '没有可靠依据' '只能靠你这条路径裁决' '唯一还没测过的便宜项'; do
  grep -q "$stale" "$ROOT/tcpwide.sh" && fail "stale claim still ships: $stale"
done
pass 'no surface still calls the notsent_lowat question open'
NOTSENT_LOWAT=131072
