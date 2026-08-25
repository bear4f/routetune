#!/usr/bin/env bash
# shellcheck disable=SC2317 # mock functions are invoked indirectly by sourced helpers
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTETUNE_LIB_ONLY=1
# shellcheck source=../routetune.sh
. "$ROOT/routetune.sh"

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

# ── 画像分类 ───────────────────────────────────────────────────────────────
# Signature: p50 jitter bloat tail retrans spread segs

# The real 4G client measured on a live relay: 208/344ms over a 164ms floor,
# 2.9% loss, 11960 segments. Loss with a spread tail is radio, not a policer.
assert_eq mobile "$(classify_peer 208.3 0.214 1.27 2.09 2.9181 1.65 11960)" \
  'the measured 4G client classifies as mobile'
# Same loss rate with flat latency is ambiguous in a passive snapshot. It is
# explicitly not enough evidence to claim that a policer exists.
assert_eq flatloss "$(classify_peer 161.9 0.031 1.02 1.05 3.30 1.05 260000)" \
  'loss with flat latency stays an unproven flat-loss observation'
# The two must never collapse into one class, or the policy implication flips.
[[ "$(classify_peer 208.3 0.214 1.27 2.09 2.9181 1.65 11960)" \
   != "$(classify_peer 161.9 0.031 1.02 1.05 3.30 1.05 260000)" ]] \
  || fail 'radio loss and a policer must not share a class'
pass 'radio-shaped and flat loss stay separate classes'

# Two consecutive live DMIT samples from the same mobile /24 exposed the old
# unstable decision: it was first called a policer, then healthy fixed-line.
assert_eq flatloss "$(classify_peer 189.2 0.094 1.14 1.25 3.0651 1.10 11960)" \
  'the first live DMIT window does not prove a policer'
assert_eq lossy "$(classify_peer 189.3 0.071 1.14 1.20 0.5074 1.06 11960)" \
  'the second live DMIT window is not misclassified as healthy far fixed-line'

assert_eq far "$(classify_peer 151.4 0.060 1.04 1.06 0.0 1.01 60000)" \
  'a stable 151ms peer classifies as far'
assert_eq near "$(classify_peer 45.0 0.050 1.10 1.20 0.0 1.10 60000)" \
  'a stable 45ms peer classifies as near'
assert_eq bloated "$(classify_peer 180.0 0.200 3.50 4.20 0.05 1.30 90000)" \
  'sustained queueing classifies as bloated'
assert_eq spiky "$(classify_peer 180.0 0.100 1.20 3.60 0.05 1.90 90000)" \
  'a calm median with a spiky tail classifies as spiky'
assert_eq variable "$(classify_peer 180.0 0.350 1.20 1.80 0.05 1.50 90000)" \
  'a variable no-loss path does not masquerade as stable fixed-line'

# Both gates come before every class that would earn a routing change.
assert_eq local "$(classify_peer 0.7 3.875 -1 -1 0.0 5.14 500000)" \
  'a same-datacentre peer is gated out'
assert_eq idle "$(classify_peer 170.5 0.443 1.11 1.15 33.3 1.05 3)" \
  'three segments cannot classify as anything actionable'
assert_eq far "$(classify_peer 147.0 0.035 1.01 1.04 0.0 1.03 991)" \
  '991 fresh segments can classify a stable RTT path without claiming clean loss'
assert_eq far "$(classify_peer 147.0 0.035 1.01 1.04 50.0 1.03 991)" \
  'sub-threshold retransmission percentages cannot drive a loss class'
[[ "$(diagnose_peer 1.14 0.116 0.0 191.1 1965 1.61 1.41)" == *"延迟尾部散开"* ]] \
  || fail 'a variable classification must not be diagnosed as healthy'
pass 'spread latency tails receive a matching diagnosis'
for c in mobile flatloss lossy far near bloated spiky variable; do
  [[ "$(classify_peer 170.5 0.443 4.0 5.0 33.3 2.0 3)" != "$c" ]] \
    || fail "an idle peer must never classify as $c"
done
pass 'an idle peer never reaches an actionable class'

# ── 策略映射 ───────────────────────────────────────────────────────────────
assert_eq 'initcwnd 32' "$(class_policy far | sed -n 1p)" \
  'far peers get a bigger initial window'
assert_eq '' "$(class_policy mobile | sed -n 1p)" \
  'mobile peers do not get a no-op initial-window route'
assert_eq '' "$(class_policy near | sed -n 1p)" 'near peers get no route change'
assert_eq '' "$(class_policy flatloss | sed -n 1p)" 'flat loss gets no unproven route change'
assert_eq '' "$(class_policy lossy | sed -n 1p)" 'light loss gets no route change'
# BBR ignoring loss is an advantage on random radio loss; cubic would halve
# the window on every one. Recommending cubic here would be actively wrong.
[[ "$(class_policy mobile | sed -n 2p)" == *"不要凭随机无线丢包换 cubic"* ]] \
  || fail 'the mobile note must warn against cubic'
pass 'the mobile policy warns against switching to cubic'
[[ "$(class_policy far | sed -n 2p)" == *"初始窗"* ]] || fail 'far note should explain itself'
pass 'the far policy explains why the window helps'

for c in local idle far near mobile flatloss lossy bloated spiky variable; do
  [[ -n "$(class_label "$c")" ]] || fail "class $c has no label"
done
pass 'every class has a human label'

# ── 画像库累积 ─────────────────────────────────────────────────────────────
tmp="$(mktemp -d)"
STATE_DIR="$tmp"; PROFILE_DB="$tmp/profiles.tsv"

# Aggregate rows: prefix conns cc p50 p95 minrtt jit bloat retrans% mbps cwnd segs dir tail retrans-count
r1="$tmp/r1"; r2="$tmp/r2"
printf '203.0.113.0/24\t2\tbbr\t100.0\t150.0\t80.0\t0.100\t1.25\t0.5000\t20.0\t40\t5000\tin\t1.88\t25\n' > "$r1"
printf '203.0.113.0/24\t4\tbbr\t200.0\t260.0\t70.0\t0.300\t2.85\t1.5000\t30.0\t60\t7000\tin\t3.71\t105\n' > "$r2"
merge_profiles "$r1"
merge_profiles "$r2"
row="$(profile_rows)"
assert_eq 1 "$(printf '%s\n' "$row" | grep -c '')" 'both rounds land on one prefix'
assert_eq '2' "$(printf '%s' "$row" | cut -f2)" 'observation count accumulates'
assert_eq '150.0' "$(printf '%s' "$row" | cut -f3)" 'p50 is averaged across rounds'
assert_eq '260.0' "$(printf '%s' "$row" | cut -f4)" 'p95 keeps the worst round'
assert_eq '70.0' "$(printf '%s' "$row" | cut -f5)" 'minrtt keeps the lowest floor ever seen'
assert_eq '3.71' "$(printf '%s' "$row" | cut -f8)" 'tail keeps the worst round'
assert_eq '1.0833' "$(printf '%s' "$row" | cut -f9)" 'retransmission rate is segment-weighted'
assert_eq '12000' "$(printf '%s' "$row" | cut -f10)" 'segment counts sum'
assert_eq '4' "$(printf '%s' "$row" | cut -f12)" 'connection count keeps the peak'

# A second prefix must not disturb the first.
printf '198.51.100.0/24\t1\tbbr\t20.0\t25.0\t18.0\t0.050\t1.11\t0.0\t99.0\t10\t9000\tin\t1.39\t0\n' > "$r1"
merge_profiles "$r1"
assert_eq 2 "$(profile_rows | grep -c '')" 'a new prefix is added alongside'
assert_eq '2' "$(profile_rows | awk -F'\t' '$1 == "203.0.113.0/24" {print $2}')" \
  'the existing prefix keeps its history'
printf '104.21.67.0/24\t1\tbbr\t2.0\t3.0\t1.0\t0.500\t2.0\t0.0\t50.0\t10\t9000\tout\t3.0\t0\n' > "$r1"
merge_profiles "$r1"
assert_eq 2 "$(profile_rows | grep -c '')" 'outbound CDN prefixes never enter the profile database'
printf '192.0.2.0/24\t1\tbbr\t147.0\t152.1\t145.8\t0.035\t1.01\t0.0\t2.0\t10\t991\tin\t1.04\t0\n' > "$r1"
merge_profiles "$r1"
assert_eq 1 "$(profile_rows | awk -F'\t' '$1 == "192.0.2.0/24" {n++} END {print n + 0}')" \
  'a 991-segment round contributes trustworthy latency evidence'
rm -rf "$tmp"

# ── 虚假重传 ───────────────────────────────────────────────────────────────
has() { [[ "$1" == nstat ]]; }
nstat() { printf 'TcpRetransSegs 1000 0.0\nTcpExtTCPDSACKRecv 300 0.0\nTcpExtTCPDSACKOfoRecv 50 0.0\n'; }
assert_eq '35.0' "$(dsack_ratio)" 'DSACK evidence ratio is reported'
nstat() { printf 'TcpRetransSegs 1000 0.0\nTcpExtTCPDSACKRecv 5 0.0\n'; }
assert_eq '0.5' "$(dsack_ratio)" 'a low DSACK evidence ratio reads low'
nstat() { printf 'TcpRetransSegs 0 0.0\nTcpExtTCPDSACKRecv 0 0.0\n'; }
if dsack_ratio >/dev/null 2>&1; then fail 'no retransmissions means no ratio';
else pass 'no retransmissions yields no ratio'; fi
has() { return 1; }
if dsack_ratio >/dev/null 2>&1; then fail 'no nstat means no ratio';
else pass 'missing nstat yields no ratio'; fi

# ── 继承自 peertune 的解析层（真机验证过，锁住不许回退）─────────────────────
has() { command -v "$1" >/dev/null 2>&1; }
row="$(printf 'ESTAB 0 0 10.0.0.1:443 203.0.113.5:51234\n\t bbr rtt:35.5/2.25 cwnd:120 data_segs_out:35900 delivery_rate 240.0Mbps retrans:0/125 minrtt:32.1\n' | ss_parse " 443 ")"
assert_eq '203.0.113.5' "$(printf '%s' "$row" | cut -f2)" 'peer IP parses'
assert_eq 'in' "$(printf '%s' "$row" | cut -f11)" 'inbound direction detected'
mapped="$(printf 'ESTAB 0 0 [::ffff:10.0.0.1]:443 [::ffff:23.19.231.167]:44000\n\t bbr rtt:0.7/0.28 data_segs_out:5000 retrans:0/0 minrtt:0.5\n' | ss_parse " 443 ")"
assert_eq '23.19.231.167' "$(printf '%s' "$mapped" | cut -f2)" 'IPv4-mapped peers normalise'
outb="$(printf 'ESTAB 0 0 10.0.0.1:51999 104.21.67.144:443\n\t bbr rtt:2.2/2.75 data_segs_out:900000 retrans:0/0 minrtt:1.0\n' | ss_parse " 443 ")"
assert_eq 'out' "$(printf '%s' "$outb" | cut -f11)" 'outbound direction detected'
# minrtt 0.0 must not produce a bloat of 101.86 the way it once did.
mr="$(printf 'k1\t1.1.1.1\tbbr\t0.7\t3.6\t0.0\t0\t5000\t8806.4\t10\tin\n' | awk -v mode=ip "$AGGREGATE_AWK")"
assert_eq '-1.00' "$(printf '%s' "$mr" | cut -f8)" 'a sub-0.1ms floor yields no bloat'

# No lifetime fallback: a connection with 9000 historical segments but no
# window delta is idle, not a trustworthy streaming sample.
idle="$(printf 'k1\t203.0.113.5\tbbr\t35\t1\t32\t10\t9000\t1\t10\tin\nk1\t203.0.113.5\tbbr\t36\t1\t32\t10\t9000\t1\t10\tin\n' | awk -v mode=ip "$AGGREGATE_AWK")"
assert_eq '0' "$(printf '%s' "$idle" | cut -f12)" 'idle sockets do not borrow lifetime segment totals'

# Compressed and padded IPv6 spellings of the same /64 must coalesce.
v6="$(printf 'a\t2001:0db8:0:1::5\tbbr\t40\t1\t38\t0\t0\t1\t10\tin\na\t2001:0db8:0:1::5\tbbr\t41\t1\t38\t0\t2000\t1\t10\tin\nb\t2001:db8:0:1:abcd::9\tbbr\t42\t1\t38\t0\t0\t1\t10\tin\nb\t2001:db8:0:1:abcd::9\tbbr\t43\t1\t38\t0\t2000\t1\t10\tin\n' | awk -v mode=net "$AGGREGATE_AWK")"
assert_eq '1' "$(printf '%s\n' "$v6" | grep -c '')" 'equivalent IPv6 addresses coalesce into one prefix'
assert_eq '2001:db8:0:1::/64' "$(printf '%s' "$v6" | cut -f1)" 'IPv6 /64 is canonicalised'

# ── 路由命令安全层 ─────────────────────────────────────────────────────────
ip() {
  local args old_ifs="$IFS"
  IFS=' '; args="$*"; IFS="$old_ifs"
  case "$args" in
    '-4 route get 203.0.113.0') printf '203.0.113.0 via 172.16.0.1 dev eth0 src 192.0.2.10 uid 0\n' ;;
    '-4 route show table main exact 203.0.113.0/24') : ;;
    '-6 route get 2001:db8:0:1::') printf '2001:db8:0:1:: dev ens3 src 2001:db8::10 metric 1024\n' ;;
    '-6 route show table main exact 2001:db8:0:1::/64') : ;;
    '-4 route get 198.51.100.0') printf '198.51.100.0 nhid 10 via 172.16.0.1 dev eth0 src 192.0.2.10\n' ;;
    '-4 route get 192.0.2.0') printf '192.0.2.0 via 172.16.0.1 dev eth0 src 192.0.2.10\n' ;;
    '-4 route show table main exact 192.0.2.0/24') printf '192.0.2.0/24 via 172.16.0.9 dev eth0 metric 50\n' ;;
    *) return 1 ;;
  esac
}
routes="$(route_commands 203.0.113.0/24 'initcwnd 32')"
assert_eq 'sudo ip -4 route add 203.0.113.0/24 via 172.16.0.1 dev eth0 src 192.0.2.10 table main initcwnd 32' \
  "$(printf '%s\n' "$routes" | sed -n '1p')" 'IPv4 recommendation copies the selected route context'
assert_eq 'sudo ip -4 route del 203.0.113.0/24 table main' \
  "$(printf '%s\n' "$routes" | sed -n '2p')" 'every generated route has an exact rollback'
routes="$(route_commands 2001:db8:0:1::/64 'initcwnd 32')"
assert_eq 'sudo ip -6 route add 2001:db8:0:1::/64 dev ens3 src 2001:db8::10 table main initcwnd 32' \
  "$(printf '%s\n' "$routes" | sed -n '1p')" 'gateway-less IPv6 is supported'
if route_commands 198.51.100.0/24 'initcwnd 32' >/dev/null 2>&1; then
  fail 'ECMP must be rejected'
else
  assert_eq '2' "$?" 'ECMP is rejected instead of pinning one nexthop'
fi
if route_commands 192.0.2.0/24 'initcwnd 32' >/dev/null 2>&1; then
  fail 'existing exact route must be rejected'
else
  assert_eq '3' "$?" 'existing exact routes are never overwritten'
fi
unset -f ip

# `ip route help` prints its help to stderr and commonly exits non-zero. The
# capability detector must still inspect that output under global pipefail.
has() { [[ "$1" == ip ]]; }
ip() { printf 'OPTIONS := [ congctl NAME ]\n' >&2; return 255; }
supports_congctl || fail 'congctl help survives the non-zero ip help exit'
pass 'congctl capability detection survives ip route help exit status'
unset -f ip
has() { command -v "$1" >/dev/null 2>&1; }

# ── BBR 版本判定 ───────────────────────────────────────────────────────────
assert_eq v1 "$(bbr_variant 'reno cubic bbr' '6.1.0-50-amd64')" 'stock Debian 6.1 is BBRv1'
assert_eq v3 "$(bbr_variant 'reno cubic bbr bbr3' '6.1.0-50-amd64')" 'an explicit bbr3 wins'
assert_eq nonstock "$(bbr_variant 'reno cubic bbr' '6.6.7-x64v3-xanmod1')" 'XanMod is not assumed v1'

printf '%s\n' 'All routetune self-tests passed.'
