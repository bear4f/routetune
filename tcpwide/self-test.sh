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
# One socket may take at most an eighth of the global TCP budget, so at least
# eight large flows fit before anyone hits pressure. The budget's own cap is a
# quarter of RAM, which puts the per-socket clamp at RAM/32. Clamping against
# RAM directly let one connection monopolise the budget on a small box.
total_ram_bytes() { printf '%s\n' $((512 * 1024 * 1024)); }
assert_eq "$((512 * 1024 * 1024 / 32))" "$(buffer_ceiling 2000 1000)" \
  'one socket is capped at an eighth of the global TCP budget'
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
# notsent_lowat was briefly forced to 131072 on the theory that 16KB is only
# 0.33ms of data at 400 Mbps and a userspace proxy cannot refill that fast. An
# A/B on the live node could not measure it: two runs of the SAME config 14
# minutes apart differed by 22% at the peak, larger than the effect under test.
# So it is a knob with no default opinion, not an assertion.
assert_eq '' "$(key net.ipv4.tcp_notsent_lowat)" \
  'an untested theory does not become a default'
NOTSENT_LOWAT=131072; tgt="$(target_sysctl 500 250)"
assert_eq '131072' "$(key net.ipv4.tcp_notsent_lowat)" \
  'an explicitly chosen unsent allowance is applied exactly'
NOTSENT_LOWAT=0; tgt="$(target_sysctl 500 250)"
while IFS=$'\t' read -r k v dir why; do
  [[ -n "$k" && -n "$v" && -n "$why" ]] || fail "key $k is missing a value or a rationale"
  [[ "$dir" =~ ^(exact|raise|lower)$ ]] || fail "key $k has no safe direction"
done <<< "$tgt"
pass 'every key carries a value, a direction and a rationale'

# ── 队列 ───────────────────────────────────────────────────────────────────
q="$(target_qdisc 500 250)"
[[ "$q" == *"dual-dsthost"* ]] || fail 'host fairness is the whole point of shaping'
pass 'the qdisc asks for per-host fairness, not per-flow'
[[ "$q" == *"bandwidth 475000kbit"* ]] || fail 'the shaper must sit under the line rate'
pass 'the shaper sits under the provider line rate'
# CAKE targets 100ms by default. At that setting a 250ms client is marked long
# before its queue is actually standing, and reads that as congestion.
[[ "$q" == *"rtt 250ms"* ]] || fail 'the AQM target must follow the coverage RTT'
pass 'the AQM target follows the coverage RTT rather than CAKE default'
SHAPE=0
assert_eq fq "$(target_qdisc 500 250)" 'without shaping we still pace, but claim nothing more'
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
assert_eq 'default via 10.0.0.1 dev eth0 proto static initcwnd 20' \
  "$(route_with_initcwnd "$(current_default_route)" 20)" 'initcwnd is appended to the existing route'
# Re-applying must not stack a second initcwnd onto the line.
assert_eq 'default via 10.0.0.1 dev eth0 proto static initcwnd 32' \
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
assert_eq fq "$(target_qdisc 500 250)" 'the no-shape profile yields fq, not cake'
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
assert_eq 'default via 193.41.250.250 dev eth0 onlink initcwnd 20' \
  "$(route_with_initcwnd 'default via 193.41.250.250 dev eth0 onlink ' 20)" \
  'a trailing space in the route does not produce a doubled separator'
# Re-applying must replace the metric, never stack a second one.
assert_eq 'default via 10.0.0.1 dev eth0 initcwnd 32' \
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
# A per-socket ceiling above an eighth of the budget means fewer than eight
# large flows fit, which is the case the clamp exists to prevent.
buf="$(buffer_ceiling 500 250)"
(( buf * 8 <= tm_max * 4096 )) \
  || fail 'the ceiling must leave room for eight flows inside the global budget'
pass 'eight flows at the ceiling fit inside the global budget'

# ── 0.3.0 整形的 CPU 代价 ──────────────────────────────────────────────────
# CAKE funnels the whole egress through one qdisc and does per-packet work. On a
# small VPS that can cost more than the policer it replaces, and the operator
# needs to know before choosing, not after a slow speedtest.
SHAPE=1
cpu_count() { printf '1\n'; }
[[ -n "$(shaping_cpu_warning 500)" ]] || fail 'one core shaping 500 Mbps must warn'
pass 'shaping well past one core of headroom warns'
if shaping_cpu_warning 200 >/dev/null 2>&1; then fail '200 Mbps on one core needs no warning'; fi
pass 'a modest rate on one core does not warn'
cpu_count() { printf '4\n'; }
if shaping_cpu_warning 500 >/dev/null 2>&1; then fail 'four cores at 500 Mbps needs no warning'; fi
pass 'enough cores means no shaping warning'
SHAPE=0
cpu_count() { printf '1\n'; }
if shaping_cpu_warning 5000 >/dev/null 2>&1; then fail 'no-shape mode has no shaping cost'; fi
pass 'no-shape mode never warns about shaping CPU'
SHAPE=1
unset -f cpu_count

printf '%s\n' 'All tcpwide self-tests passed.'
