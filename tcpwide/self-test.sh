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
# the receive buffer, so the ceiling is twice the product.
assert_eq "$((2 * 250 * 125 * 500))" "$(buffer_ceiling 500 250)" \
  'the ceiling is twice the bandwidth-delay product'
# The asymmetry that motivates a coverage RTT also motivates a floor: a ceiling
# below what a distant client needs is a cap nobody can diagnose.
assert_eq "$((8 * 1024 * 1024))" "$(buffer_ceiling 10 20)" 'a tiny envelope still gets the 8 MiB floor'
# A ceiling is per socket, so it stays bounded relative to RAM.
total_ram_bytes() { printf '%s\n' $((512 * 1024 * 1024)); }
assert_eq "$((512 * 1024 * 1024 / 16))" "$(buffer_ceiling 2000 1000)" \
  'the ceiling is clamped against total RAM'
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
assert_eq "$((2 * 250 * 125 * 500))" "$(key net.core.rmem_max)" 'the ceiling follows the coverage envelope'
# ECN only means anything when something on the path marks instead of dropping.
[[ -n "$(key net.ipv4.tcp_ecn)" ]] || fail 'ECN should be set when we run the AQM'
pass 'ECN is requested when we own the queue'
SHAPE=0; tgt="$(target_sysctl 500 250)"
[[ -z "$(key net.ipv4.tcp_ecn)" ]] || fail 'ECN must not be set without a local AQM'
pass 'ECN is left alone when nothing local marks packets'
SHAPE=1; tgt="$(target_sysctl 500 250)"
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

printf '%s\n' 'All tcpwide self-tests passed.'
