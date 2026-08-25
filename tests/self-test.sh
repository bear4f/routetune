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
# 991 segments is enough to trust the latency shape but not the loss rate.
# "far" is the one class that asserts low retransmission and hands out a
# bigger initial window, so an unverified path must not land there.
assert_eq unverified "$(classify_peer 147.0 0.035 1.01 1.04 0.0 1.03 991)" \
  '991 fresh segments read the RTT shape without claiming the loss rate is clean'
assert_eq unverified "$(classify_peer 147.0 0.035 1.01 1.04 50.0 1.03 991)" \
  'sub-threshold retransmission percentages cannot drive a loss class'
[[ "$(diagnose_peer 1.14 0.116 0.0 191.1 1965 1.61 1.41)" == *"延迟尾部散开"* ]] \
  || fail 'a variable classification must not be diagnosed as healthy'
pass 'spread latency tails receive a matching diagnosis'
for c in mobile flatloss lossy far near bloated mixed queued unverified spiky variable; do
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
assert_eq '2.79' "$(printf '%s' "$row" | cut -f8)" 'tail reports the typical round, not the worst'
assert_eq '1' "$(printf '%s' "$row" | cut -f15)" 'the spiky round is counted'
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

# ── 尖峰频率而非最差一轮 ───────────────────────────────────────────────────
# A max never decays, so classifying on one meant a single freak round pinned a
# prefix out of its class forever and more observation could only make a profile
# look worse — the opposite of what "轮次越多画像越可信" promises.
tmp="$(mktemp -d)"; STATE_DIR="$tmp"; PROFILE_DB="$tmp/profiles.tsv"
# 18 columns: prefix obs trusted p50sum p95max minrtt jitsum bloatsum tailmax
#             retrtotal segtotal mbpsmax connmax first last p95sum tailsum spikes
hdr=$'prefix\tobs\ttrusted\tp50sum\tp95max\tminrtt\tjitsum\tbloatsum\ttailmax\tretrtotal\tsegtotal\tmbpsmax\tconnmax\tfirst\tlast\tp95sum\ttailsum\tspikes'
classify_db() {
  local out p50 jit bl tl rt sg sp spf
  out="$(profile_rows)"
  IFS=$'\t' read -r _ _ p50 _ _ jit bl tl rt sg _ _ sp spf _ <<< "$out"
  classify_peer "$p50" "$jit" "$bl" "$tl" "$rt" "$sp" "$sg" "$spf"
}

# 100 healthy rounds at 147/152ms over a 145.5ms floor, and one 620ms round.
printf '%s\n119.237.129.0/24\t100\t100\t14700\t620.0\t145.5\t3.0\t101.0\t4.26\t0\t120000\t95.0\t1\t0\t0\t15668\t108.21\t1\n' \
  "$hdr" > "$PROFILE_DB"
assert_eq far "$(classify_db)" 'one freak round in a hundred no longer pins the class'

# The same worst round, but now it is a third of the observation.
printf '%s\n119.237.129.0/24\t43\t43\t6321\t620.0\t145.5\t1.29\t43.43\t4.26\t0\t51600\t95.0\t1\t0\t0\t12152\t83.67\t12\n' \
  "$hdr" > "$PROFILE_DB"
assert_eq spiky "$(classify_db)" 'a link that spikes in a third of its rounds is still spiky'

# A pre-0.1.4 database has no sums. It must still read, and must degrade
# pessimistically — an upgrade may not quietly promote a bad profile.
printf 'prefix\n119.237.129.0/24\t101\t101\t14847\t620.0\t145.5\t3.03\t102.01\t4.26\t0\t121200\t95.0\t1\t0\t0\n' \
  > "$PROFILE_DB"
assert_eq spiky "$(classify_db)" 'a legacy database still classifies, on the pessimistic reading'
# "unknown", not "zero" — a legacy row never observed a clean spike record.
assert_eq '-1' "$(profile_rows | cut -f15)" 'a legacy row reports its spike count as unknown'
# And once merged, the seeded sums decay toward the truth instead of sticking.
r1="$tmp/r1"
printf '119.237.129.0/24\t1\tbbr\t147.0\t152.0\t145.5\t0.030\t1.01\t0.0\t95.0\t10\t1200\tin\t1.05\t0\n' > "$r1"
merge_profiles "$r1"
[[ "$(profile_rows | cut -f8)" != '4.26' ]] \
  || fail 'a merged legacy profile must stop reporting the worst round as typical'
pass 'seeded legacy sums decay as new rounds arrive'
unset -f classify_db
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


# ── 表格标签与箭头说明必须一致 ─────────────────────────────────────────────
# scan prints class_label(classify_peer(...)) on the row and diagnose_peer(...)
# on the arrow beneath it. They were two independent ladders, so a prefix with
# both queueing and loss showed 接入网排队 on the row and 既排队又丢包 below it.
expect_arrow() {
  case "$1" in
    bloated)    printf '接入网排' ;;  mixed)      printf '既排队又' ;;
    spurious)   printf '虚假重传' ;;
    mobile)     printf '无线接入' ;;  flatloss)   printf '稳定延迟' ;;
    lossy)      printf '轻度丢包' ;;  spiky)      printf '间歇性排' ;;
    variable)   printf '链路抖动|延迟尾部' ;;
    queued)     printf '轻微排队' ;;  unverified) printf '路径延迟' ;;
    far|near)   printf '健康' ;;      idle)       printf '基本空闲' ;;
    local)      printf '同机房' ;;
  esac
}
mismatches=0
for b in 1.0 1.6 2.4 3.5; do for j in 0.05 0.2 0.35; do
for r in 0.0 0.5 1.5; do for sp in 1.1 1.5; do for sg in 500 50000; do
  tl="$(awk -v b="$b" -v s="$sp" 'BEGIN {printf "%.2f", b * s}')"
  cls="$(classify_peer 200 "$j" "$b" "$tl" "$r" "$sp" "$sg" 0.0)"
  arrow="$(diagnose_peer "$b" "$j" "$r" 200 "$sg" "$tl" "$sp")"
  printf '%s' "$arrow" | grep -qE "^($(expect_arrow "$cls"))" || {
    printf 'FAIL: %s b=%s j=%s r=%s sp=%s sg=%s -> %s\n' \
      "$cls" "$b" "$j" "$r" "$sp" "$sg" "$arrow" >&2
    mismatches=$((mismatches + 1))
  }
done; done; done; done; done
(( mismatches == 0 )) || fail "table label and arrow disagree in $mismatches combinations"
pass 'every class label agrees with its arrow diagnosis'

# ── 只有真正干净的远端路径才拿得到 initcwnd 32 ─────────────────────────────
assert_eq far "$(classify_peer 200 0.01 1.00 1.05 0.0 1.05 80000 0.0)" \
  'a clean, verified far path still earns the wider first window'
assert_eq 'initcwnd 32' "$(class_policy far | sed -n 1p)" 'the far policy is unchanged'
assert_eq '' "$(class_policy unverified | sed -n 1p)" \
  'an unverified path is never handed initcwnd 32'
# Bloat 2.4 used to fall through to far, handing a bigger initial burst to a
# path already sitting 2.4x above its own floor.
assert_eq queued "$(classify_peer 200 0.05 2.40 2.60 0.0 1.10 50000 0.0)" \
  'a standing queue short of the bloat threshold no longer reads as a clean fixed line'
assert_eq '' "$(class_policy queued | sed -n 1p)" \
  'a queueing path is never handed a wider initial window'
# Queueing and loss together: passive observation confirms neither cause, so
# the profile must not inherit the policy text of either one.
assert_eq mixed "$(classify_peer 200 0.20 2.40 3.00 1.5 1.25 50000 0.0)" \
  'queueing plus loss gets its own class instead of being filed as mobile'
assert_eq mixed "$(classify_peer 200 0.20 3.50 4.20 1.5 1.20 50000 0.0)" \
  'deep queueing plus loss is not filed as pure access-network bloat'
assert_eq bloated "$(classify_peer 200 0.05 3.50 3.85 0.0 1.10 50000 0.0)" \
  'deep queueing with clean loss is still access-network bloat'
assert_eq '' "$(class_policy mixed | sed -n 1p)" \
  'a mixed profile changes no route parameters'

# ── 真机画像在改动后必须分类不变 ───────────────────────────────────────────
assert_eq far "$(classify_peer 146.0 0.010 1.00 1.07 0.0000 1.06 81573 0.05)" \
  'the DMIT fixed-line profile still classifies as a healthy far path'
assert_eq mobile "$(classify_peer 212.8 0.248 1.27 3.64 6.6001 1.30 433794 0.30)" \
  'the DMIT 4G profile still classifies as mobile'


# ── 0.2.0 新证据：解析层 ───────────────────────────────────────────────────
# ss only prints dsack_dups/reord_seen/rwnd_limited when non-zero, and prints
# the limited timers as "1800ms(20.0%)".
ev="$(cat <<'SS'
ESTAB 0 0 10.0.0.1:443 203.0.113.5:51234
	 bbr rtt:35.5/2.25 mss:1448 pmtu:1500 rcvmss:536 advmss:1448 cwnd:120 data_segs_out:35900 data_segs_in:412 delivery_rate 240.0Mbps busy:9000ms rwnd_limited:1800ms(20.0%) sndbuf_limited:450ms(5.0%) retrans:0/125 dsack_dups:37 reord_seen:4 minrtt:32.1
SS
)"
ev="$(printf '%s\n' "$ev" | ss_parse " 443 ")"
assert_eq '37'   "$(printf '%s' "$ev" | cut -f12)" 'dsack_dups parses'
assert_eq '4'    "$(printf '%s' "$ev" | cut -f13)" 'reord_seen parses'
assert_eq '412'  "$(printf '%s' "$ev" | cut -f14)" 'data_segs_in parses'
# advmss: and rcvmss: both end in "mss:"; only the anchored mss: may match.
assert_eq '1448' "$(printf '%s' "$ev" | cut -f15)" 'mss parses without matching advmss or rcvmss'
assert_eq '1500' "$(printf '%s' "$ev" | cut -f16)" 'pmtu parses'
assert_eq '1800' "$(printf '%s' "$ev" | cut -f17)" 'rwnd_limited drops its unit and percentage'
assert_eq '450'  "$(printf '%s' "$ev" | cut -f18)" 'sndbuf_limited drops its unit and percentage'
assert_eq '9000' "$(printf '%s' "$ev" | cut -f19)" 'busy parses'
# A socket without any of the optional fields must read as zero, not empty.
plain="$(printf 'ESTAB 0 0 10.0.0.1:443 203.0.113.5:51234\n\t bbr rtt:35.5/2.25 data_segs_out:100 retrans:0/0 minrtt:32.1\n' | ss_parse " 443 ")"
assert_eq '0' "$(printf '%s' "$plain" | cut -f12)" 'an absent dsack_dups reads as zero'

# ── 0.2.0 新证据：聚合层 ───────────────────────────────────────────────────
# Two samples of one connection: 100 retransmissions in the window, 80 of them
# reported back by the receiver as duplicates.
sp="$(printf 'k\t203.0.113.5\tbbr\t35\t1\t32\t100\t10000\t1\t10\tin\t10\t1\t100\t1448\t1500\t100\t0\t1000\nk\t203.0.113.5\tbbr\t35\t1\t32\t200\t20000\t1\t10\tin\t90\t5\t300\t1448\t1500\t900\t0\t3000\n' | awk -v mode=ip "$AGGREGATE_AWK")"
assert_eq '80.0' "$(printf '%s' "$sp" | cut -f16)" 'the spurious share is a window delta, not a lifetime ratio'
assert_eq '4'    "$(printf '%s' "$sp" | cut -f17)" 'reordering events are a window delta'
assert_eq '40.0' "$(printf '%s' "$sp" | cut -f19)" 'receive-window stall is a share of active sending time'
# No retransmissions at all means no denominator: -1, never a measured 0%.
nr="$(printf 'k\t203.0.113.5\tbbr\t35\t1\t32\t0\t10000\t1\t10\tin\t0\t0\t0\t1448\t1500\t0\t0\t1000\nk\t203.0.113.5\tbbr\t35\t1\t32\t0\t20000\t1\t10\tin\t0\t0\t0\t1448\t1500\t0\t0\t3000\n' | awk -v mode=ip "$AGGREGATE_AWK")"
assert_eq '-1.0' "$(printf '%s' "$nr" | cut -f16)" 'no retransmissions yields no spurious share rather than zero'

# ── 0.2.0 虚假重传分类 ─────────────────────────────────────────────────────
# The same 6.6% retransmission rate is two different links depending on whether
# the receiver confirmed those retransmissions were duplicates.
assert_eq spurious "$(classify_peer 212.8 0.248 1.27 3.64 6.6 1.30 433794 0.30 80 5000)" \
  'a majority-DSACK retransmission rate is not read as loss'
assert_eq mobile "$(classify_peer 212.8 0.248 1.27 3.64 6.6 1.30 433794 0.30 5 5000)" \
  'the same rate with little DSACK evidence stays radio loss'
# Below the retransmission floor the ratio is noise and must not classify.
assert_eq mobile "$(classify_peer 212.8 0.248 1.27 3.64 6.6 1.30 433794 0.30 100 3)" \
  'three retransmissions cannot prove a spurious majority'
# Unknown (-1) evidence must behave exactly like the pre-0.2.0 default.
assert_eq mobile "$(classify_peer 212.8 0.248 1.27 3.64 6.6 1.30 433794 0.30 -1 0)" \
  'absent DSACK evidence leaves the old classification untouched'
assert_eq '' "$(class_policy spurious | sed -n 1p)" \
  'a spurious-retransmission prefix gets no route parameters'
[[ "$(class_policy spurious | sed -n 2p)" == *"RACK"* ]] \
  || fail 'the spurious note must explain why reordering is a no-op on modern kernels'
pass 'the spurious policy explains why it prescribes nothing'

# ── 0.2.0 no-op 闸门 ───────────────────────────────────────────────────────
# The script runs under IFS=$'\n\t'. A default read -a would keep "initcwnd 32"
# as one word and every gate below would be skipped without examining anything.
assert_eq 'initcwnd 32' "$(gate_metrics 'initcwnd 32' 5 | sed -n 1p)" \
  'a metric survives when nothing disproves it'
assert_eq '' "$(gate_metrics 'initcwnd 32' 60 | sed -n 1p)" \
  'a wider first window is dropped when the receiver window is the ceiling'
[[ "$(gate_metrics 'initcwnd 32' 60 | sed -n 2p | cut -f1)" == initcwnd ]] \
  || fail 'the dropped metric must be named'
pass 'a dropped metric is reported with the metric name'
assert_eq 'congctl bbr3' "$(gate_metrics 'initcwnd 32 congctl bbr3' 60 | sed -n 1p)" \
  'gating drops only the metric that fails, keeping the rest'
# Unknown receive-window evidence must not silently suppress a recommendation.
assert_eq 'initcwnd 32' "$(gate_metrics 'initcwnd 32' -1 | sed -n 1p)" \
  'unknown receive-window evidence does not block the recommendation'

# ── 0.2.0 per-route congctl 只在内核真有更好算法时才提议 ────────────────────
if better_cc 'reno cubic bbr' bbr >/dev/null 2>&1; then
  fail 'a stock kernel must not offer a per-route congestion control upgrade'
fi
pass 'a stock reno/cubic/bbr kernel proposes no congctl'
assert_eq bbr3 "$(better_cc 'reno cubic bbr bbr3' bbr)" 'bbr3 is offered over bbr'
assert_eq bbr2 "$(better_cc 'reno cubic bbr bbr2' bbr)" 'bbr2 is offered over bbr'
if better_cc 'reno cubic bbr bbr3' bbr3 >/dev/null 2>&1; then
  fail 'already running the best available algorithm must offer nothing'
fi
pass 'no congctl is proposed when the best algorithm is already running'

# ── 0.2.0 旧画像库仍可读 ───────────────────────────────────────────────────
tmp="$(mktemp -d)"; STATE_DIR="$tmp"; PROFILE_DB="$tmp/profiles.tsv"
{
  printf 'prefix\tobs\ttrusted\tp50sum\tp95max\tminrtt\tjitsum\tbloatsum\ttailmax\tretrtotal\tsegtotal\tmbpsmax\tconnmax\tfirst\tlast\tp95sum\ttailsum\tspikes\n'
  printf '203.0.113.0/24\t40\t40\t8000\t215\t195\t0.40\t41.2\t1.12\t0\t80000\t400\t4\t0\t0\t8320\t44.4\t0\n'
} > "$PROFILE_DB"
legacy="$(profile_rows)"
assert_eq '-1.0' "$(printf '%s' "$legacy" | cut -f16)" \
  'a pre-0.2.0 profile reports unknown spurious evidence, not a measured zero'
assert_eq far "$(classify_peer "$(printf '%s' "$legacy" | cut -f3)" \
  "$(printf '%s' "$legacy" | cut -f6)" "$(printf '%s' "$legacy" | cut -f7)" \
  "$(printf '%s' "$legacy" | cut -f8)" "$(printf '%s' "$legacy" | cut -f9)" \
  "$(printf '%s' "$legacy" | cut -f13)" "$(printf '%s' "$legacy" | cut -f10)" \
  "$(printf '%s' "$legacy" | cut -f14)" "$(printf '%s' "$legacy" | cut -f16)" \
  "$(printf '%s' "$legacy" | cut -f23)")" \
  'a pre-0.2.0 profile classifies exactly as it did before the upgrade'
rm -rf "$tmp"

printf '%s\n' 'All routetune self-tests passed.'
