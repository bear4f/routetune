#!/usr/bin/env bash
# routetune - per-prefix TCP policy for a client population spread across
# regions and access networks.
#
# The tools this grew out of all tune globally: one congestion control, one
# buffer ceiling, one root qdisc for everybody. That is the right shape when
# your clients look alike. It stops being right when they do not — a mobile
# peer losing 3% to its radio, a fixed line 250ms away, and a neighbour in
# the same datacentre all want different treatment, and sysctl cannot give
# it to them because sysctl is machine-wide.
#
# What can is the routing table. initcwnd, initrwnd, rto_min, window, advmss
# and congctl are all per-route metrics, so a prefix can carry its own policy.
# routetune observes each peer, groups them into profiles, and writes out the
# per-route policy those profiles imply.
#
# It does not apply anything. Phase one earns trust in the profiles first.
#
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION="0.1.0"
PROGRAM="routetune"
STATE_DIR="/var/lib/routetune"
PROFILE_DB="$STATE_DIR/profiles.tsv"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

if [[ ! -t 1 || "${NO_COLOR:-}" ]]; then
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' DIM='' BOLD='' RESET=''
fi

RULE_HEAVY='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
RULE_LIGHT='──────────────────────────────────────────────────────────────────────'

rule_heavy() { printf '%b%s%b\n' "$CYAN" "$RULE_HEAVY" "$RESET"; }
rule_light() { printf '%b%s%b\n' "$DIM" "$RULE_LIGHT" "$RESET"; }

panel_title() {
  printf '\n'; rule_heavy
  printf '%b  %s%b  %bv%s%b\n' "$BOLD" "$1" "$RESET" "$DIM" "$VERSION" "$RESET"
  rule_heavy
}

log()  { printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"; }
info() { printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }
is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo $PROGRAM $*"; }
available_cc() { sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true; }

SAMPLES=6
INTERVAL_S=5
GROUP_BY=net

# ── 采样与解析（移植自 peertune，已在真机上验证过两轮）───────────────────

# Ports this host listens on, so inbound connections can be told from the
# ones the host itself opened.
# Normalises `ss -tin` into one row per connection per sample:
#   key  peer  cc  rtt  rttvar  minrtt  retrans  data_segs_out  mbps  cwnd
# `ss` prints a socket line followed by an indented info line, and drops the
# State column when a state filter is used, so both layouts are handled.
# shellcheck disable=SC2016 # awk program; shell expansion is intentionally disabled
SS_PARSE_AWK='
function tomb(v,   n) {
  n = v + 0
  if (v ~ /Gbps/) return n * 1000
  if (v ~ /Mbps/) return n
  if (v ~ /Kbps/) return n / 1000
  return n / 1000000
}
function ipof(a,   i) {
  if (substr(a, 1, 1) == "[") { i = index(a, "]"); a = (i > 2) ? substr(a, 2, i - 2) : a }
  else {
    i = length(a)
    while (i > 0 && substr(a, i, 1) != ":") i--
    if (i > 1) a = substr(a, 1, i - 1)
  }
  # An IPv4 client reaching a dual-stack listener shows up as ::ffff:1.2.3.4.
  # Left alone, the same person appears as two different peers.
  if (substr(a, 1, 7) == "::ffff:") a = substr(a, 8)
  return a
}
function portof(a,   i) {
  i = length(a)
  while (i > 0 && substr(a, i, 1) != ":") i--
  return (i > 0) ? substr(a, i + 1) : ""
}
/^[ \t]/ {
  if (peer == "") next
  cc = $1; rtt = ""; rttvar = ""; minrtt = ""; retr = 0; dsegs = 0; cwnd = 0; mbps = 0
  for (i = 1; i <= NF; i++) {
    f = $i
    if (f ~ /^rtt:/) {
      s = substr(f, 5); p = index(s, "/")
      if (p > 0) { rtt = substr(s, 1, p - 1) + 0; rttvar = substr(s, p + 1) + 0 }
      else rtt = s + 0
    }
    else if (f ~ /^minrtt:/) minrtt = substr(f, 8) + 0
    else if (f ~ /^retrans:/) { s = substr(f, 9); p = index(s, "/"); retr = ((p > 0) ? substr(s, p + 1) : s) + 0 }
    else if (f ~ /^data_segs_out:/) dsegs = substr(f, 15) + 0
    else if (f ~ /^cwnd:/) cwnd = substr(f, 6) + 0
    else if (f == "delivery_rate" && i < NF) mbps = tomb($(i + 1))
  }
  # No RTT estimate yet, or nothing ever sent: nothing to say about this one.
  if (rtt == "" || rtt <= 0 || dsegs <= 0) { peer = ""; next }
  if (minrtt == "" || minrtt <= 0) minrtt = rtt
  if (rttvar == "") rttvar = 0
  # A relay also opens its own connections outward (CDNs, origins, updates).
  # Those are not clients, and mixing them in makes the table unreadable, so
  # the direction is decided by whether the local side is a listening port.
  dir = (index(listen, " " portof(local) " ") > 0) ? "in" : "out"
  printf "%s\t%s\t%s\t%.3f\t%.3f\t%.3f\t%d\t%d\t%.3f\t%d\t%s\n", \
    local "|" peer, ipof(peer), cc, rtt, rttvar, minrtt, retr, dsegs, mbps, cwnd, dir
  peer = ""
  next
}
{
  peer = ""
  if (NF >= 5 && $1 ~ /^[A-Z][A-Z0-9_-]*$/) { local = $4; peer = $5 }
  else if (NF >= 4) { local = $3; peer = $4 }
}
'

# Ports this host listens on, so inbound connections can be told from the
# ones the host itself opened.
listening_ports() {
  local ports
  ports="$(ss -tlnH 2>/dev/null | awk '{
    for (i = NF; i >= 1; i--) if ($i ~ /:[0-9]+$/) {
      j = length($i); while (j > 0 && substr($i, j, 1) != ":") j--
      print substr($i, j + 1); break
    }
  }' | sort -u | tr '\n' ' ')" || true
  printf ' %s\n' "$ports"
}

ss_parse() { awk -v listen="${1:- }" "$SS_PARSE_AWK"; }

# Aggregates the sample rows into one line per peer. Retransmissions are a
# delta between the first and last sighting of each connection, not a lifetime
# average: a connection that had a bad minute an hour ago is not having one now.
# shellcheck disable=SC2016 # awk program; shell expansion is intentionally disabled
AGGREGATE_AWK='
function sortarr(a, n,   i, j, t) {
  for (i = 2; i <= n; i++) { t = a[i]; j = i - 1
    while (j > 0 && a[j] > t) { a[j + 1] = a[j]; j-- }
    a[j + 1] = t }
}
function at(a, n, q,   idx) {
  idx = int(q * n + 0.5); if (idx < 1) idx = 1; if (idx > n) idx = n
  return a[idx]
}
function hexnorm(s) {
  s = tolower(s)
  while (length(s) > 1 && substr(s, 1, 1) == "0") s = substr(s, 2)
  return (s == "") ? "0" : s
}
function ipv6net(ip,   z,p,left,right,nl,nr,i,n,fill,a,b,h) {
  z = index(ip, "%"); if (z > 0) ip = substr(ip, 1, z - 1)
  p = index(ip, "::"); n = 0
  if (p > 0) {
    left = substr(ip, 1, p - 1); right = substr(ip, p + 2)
    nl = (left == "") ? 0 : split(left, a, ":")
    nr = (right == "") ? 0 : split(right, b, ":")
    for (i = 1; i <= nl; i++) h[++n] = hexnorm(a[i])
    fill = 8 - nl - nr
    for (i = 1; i <= fill; i++) h[++n] = "0"
    for (i = 1; i <= nr; i++) h[++n] = hexnorm(b[i])
  } else {
    n = split(ip, a, ":")
    for (i = 1; i <= n; i++) h[i] = hexnorm(a[i])
  }
  if (n < 4) return ip
  return h[1] ":" h[2] ":" h[3] ":" h[4] "::/64"
}
function groupof(ip,   i) {
  if (mode != "net") return ip
  if (index(ip, ":") > 0) return ipv6net(ip)
  for (i = length(ip); i > 0; i--) if (substr(ip, i, 1) == ".") { return substr(ip, 1, i - 1) ".0/24" }
  return ip
}
{
  key = $1; base = groupof($2); cc = $3
  rtt = $4 + 0; rttvar = $5 + 0; minrtt = $6 + 0
  retr = $7 + 0; dsegs = $8 + 0; mbps = $9 + 0; cwnd = $10 + 0; dir = $11
  # Keep inbound and outbound sockets in separate buckets even when they share
  # a prefix. watch persists only inbound rows; otherwise a CDN connection in
  # the same /24 could contaminate a client profile.
  g = base SUBSEP dir; glabel[g] = base
  if (!(key in firstseen)) { firstseen[key] = 1; fretr[key] = retr; fsegs[key] = dsegs; kgroup[key] = g; kdir[key] = dir }
  lretr[key] = retr; lsegs[key] = dsegs
  n = ++cnt[g]
  rtts[g, n] = rtt
  rates[g, n] = mbps
  vsum[g] += rttvar
  if (!(g in gmin) || minrtt < gmin[g]) gmin[g] = minrtt
  if (cwnd > gcwnd[g]) gcwnd[g] = cwnd
  ccname[g] = cc
}
END {
  for (key in firstseen) {
    g = kgroup[key]
    conns[g]++
    if (kdir[key] == "in") nin[g]++; else nout[g]++
    dr = lretr[key] - fretr[key]; ds = lsegs[key] - fsegs[key]
    # Never fall back to lifetime totals. An old, now-idle streaming socket can
    # have millions of lifetime segments and would otherwise pass the activity
    # gate even though this window observed no traffic at all.
    if (dr < 0) dr = 0
    if (ds > 0) { sumretr[g] += dr; sumsegs[g] += ds }
  }
  for (g in cnt) {
    n = cnt[g]
    for (i = 1; i <= n; i++) { r[i] = rtts[g, i]; m[i] = rates[g, i] }
    sortarr(r, n); sortarr(m, n)
    p50 = at(r, n, 0.50); p95 = at(r, n, 0.95)
    jit = (p50 > 0) ? (vsum[g] / n) / p50 : 0
    # ss reports minrtt to one decimal, so a same-host path prints 0.0 and the
    # ratio explodes (a real run produced a bloat of 101.86). Below 0.1ms there
    # is no floor to divide by; -1 means "not computable" downstream.
    bloat = (gmin[g] >= 0.1) ? p50 / gmin[g] : -1
    tail = (gmin[g] >= 0.1) ? p95 / gmin[g] : -1
    rpct = (sumsegs[g] > 0) ? sumretr[g] * 100 / sumsegs[g] : 0
    d = (nout[g] == 0) ? "in" : ((nin[g] == 0) ? "out" : "mix")
    printf "%s\t%d\t%s\t%.1f\t%.1f\t%.1f\t%.3f\t%.2f\t%.4f\t%.1f\t%d\t%d\t%s\t%.2f\t%d\n", \
      glabel[g], conns[g], ccname[g], p50, p95, gmin[g], jit, bloat, rpct, at(m, n, 0.50), gcwnd[g], sumsegs[g], d, tail, sumretr[g]
  }
}
'

# ── 判定 ───────────────────────────────────────────────────────────────────

# Below this, rtt and rttvar are dominated by timer granularity, interrupt
# coalescing and scheduling — not by anything happening on the network. A
# same-datacenter peer at 0.7ms will happily report a jitter ratio of 0.4.
LOCAL_RTT_FLOOR_MS=5
# A percentage over a handful of segments is noise: one retransmit out of
# three is 33%, and it means nothing. Real streaming clients clear this easily.
MIN_SEGS_FOR_RETRANS=1000

# rtt / minrtt is how many times the path has grown above the connection's
# observed floor. It is evidence of queueing, not proof of where that queue is.
bloat_verdict() {
  awk -v b="${1:-1}" 'BEGIN {
    if (b < 1.5) print "队列健康";
    else if (b < 3) print "有排队";
    else print "排队膨胀";
  }'
}

# rttvar / rtt. A radio link that is scheduling around you shows up here long
# before it shows up in throughput.
jitter_verdict() {
  awk -v j="${1:-0}" 'BEGIN {
    if (j < 0.1) print "稳";
    else if (j < 0.3) print "抖";
    else print "剧烈抖";
  }'
}

# Same thresholds as netshape: across seven real hosts the clean side topped
# out at 0.0017% and the lowest reading from a policed path was 1.354%.
retrans_verdict() {
  awk -v p="${1:-0}" 'BEGIN {
    if (p < 0.1) print "干净";
    else if (p < 1) print "偏高";
    else print "丢包重";
  }'
}

# The whole point of collecting three independent signals is that their
# combination says something none of them says alone. Both gates matter more
# than the matrix does: without them a same-rack connection reads as a
# wobbling radio link, and an idle one reads as a policed path.
diagnose_peer() {
  local bloat="${1:-1}" jitter="${2:-0}" retrans="${3:-0}" rtt="${4:-999}" segs="${5:-999999}"
  local tail="${6:-$1}" spread="${7:-1}"
  awk -v b="$bloat" -v j="$jitter" -v r="$retrans" -v t="$rtt" -v sg="$segs" \
      -v tb="$tail" -v sp="$spread" \
      -v floor="$LOCAL_RTT_FLOOR_MS" -v minseg="$MIN_SEGS_FOR_RETRANS" 'BEGIN {
    if (t < floor) {
      print "同机房或本机出站连接（RTT < " floor "ms）——这个量级上抖动和膨胀都是计时噪声，不用管";
      exit
    }
    trust_r = (sg >= minseg)
    # An idle connection has too few RTT samples for rttvar to mean anything
    # either, so this gates jitter and bloat as much as it gates loss.
    if (!trust_r) { print "基本空闲，采样窗口内只发了 " sg " 段，数据不足以判断"; exit }
    if (b >= 3 && r < 1) {
      print "接入网排队膨胀——瓶颈队列不在服务器上；先做更长观测，再在可控机器上 A/B 测试 pacing 或 BBRv3";
      exit
    }
    if (r >= 1 && b >= 2) { print "既排队又丢包——多半打穿了限速器，优先降速率"; exit }
    # A policer drops without adding delay variance: latency stays flat and
    # only the loss rate moves. Radio loss comes with a spread tail and jitter,
    # and is not a congestion signal — lowering the rate buys little.
    if (r >= 1 && (j >= 0.15 || sp >= 1.4)) {
      print "无线接入层丢包（4G/5G 典型）——没有持续排队，但丢包和延迟尾部都高。这类丢包不是拥塞信号，降速率收益有限，客户端播放器多缓冲更有效";
      exit
    }
    if (r >= 1) { print "路径丢包或限速器——延迟很稳却在丢包，降单流速率有用"; exit }
    if (tb >= 3) { print "间歇性排队——中位队列不深，但尾部涨到底噪的 " sprintf("%.1f", tb) " 倍，卡顿多半发生在这些尖峰上"; exit }
    if (j >= 0.3) { print "链路抖动大（无线接入或路径拥塞）——速率波动来自这里，不是你的配置"; exit }
    if (b >= 1.5) { print "轻微排队，可接受"; exit }
    print "健康";
  }'
}

collect_samples() {
  local samples="$1" interval="$2" out="$3" i listen
  listen="$(listening_ports)"
  : > "$out"
  for (( i = 1; i <= samples; i++ )); do
    ss -tinH 2>/dev/null | ss_parse "$listen" >> "$out" || true
    if (( i < samples )); then sleep "$interval"; fi
  done
  # Without this the loop leaks the last guard's status and errexit kills us.
  return 0
}

# ── 内核能力 ───────────────────────────────────────────────────────────────

# BBRv3 has never been in mainline: it lives in XanMod and other out-of-tree
# trees. So a stock distro kernel that offers only "bbr" is offering v1, and
# no amount of poking at modinfo will say otherwise — the module carries no
# version field that distinguishes them. The kernel's provenance is the answer.
bbr_variant() {
  local avail=" ${1:-} " release="${2:-}"
  [[ -n "$release" ]] || release="$(uname -r 2>/dev/null || printf '')"
  case "$avail" in
    *" bbr3 "*) printf 'v3
'; return 0 ;;
    *" bbr2 "*) printf 'v2
'; return 0 ;;
  esac
  case "$avail" in
    *" bbr "*) ;;
    *) printf 'none
'; return 0 ;;
  esac
  case "$release" in
    *xanmod*|*XanMod*|*XANMOD*) printf 'nonstock
' ;;
    *) printf 'v1
' ;;
  esac
}

bbr_variant_note() {
  case "${1:-}" in
    v3) printf '%s\n' '检测到显式 bbr3 算法名' ;;
    v2) printf '%s\n' '检测到显式 bbr2 算法名' ;;
    v1) printf '%s\n' 'BBRv1（主线内核只提供 bbr）—— 容量剧变后的估值滞后对移动链路不利' ;;
    nonstock) printf '%s\n' '非主线内核且算法名仍为 bbr —— 仅凭名称无法可靠区分 v1/v2/v3，请查该内核的构建说明' ;;
    *) printf '%s\n' '内核没有提供 BBR' ;;
  esac
}


# ── 画像分类 ───────────────────────────────────────────────────────────────

# The classes exist because each one implies a different per-route policy.
# Order matters: the gates come first, because a peer we cannot measure must
# never be filed under a class that would earn it a routing change.
classify_peer() {
  local p50="${1:-0}" jit="${2:-0}" bloat="${3:-1}" tail="${4:-1}" \
        retrans="${5:-0}" spread="${6:-1}" segs="${7:-0}"
  awk -v t="$p50" -v j="$jit" -v b="$bloat" -v tb="$tail" -v r="$retrans" \
      -v sp="$spread" -v sg="$segs" -v floor="$LOCAL_RTT_FLOOR_MS" \
      -v minseg="$MIN_SEGS_FOR_RETRANS" 'BEGIN {
    if (t < floor)   { print "local";  exit }
    if (sg < minseg) { print "idle";   exit }
    if (b >= 3)      { print "bloated"; exit }
    # Loss with a spread latency tail is the radio signature; loss with flat
    # latency is a rate limiter. Same loss rate, opposite treatment.
    if (r >= 1 && (j >= 0.15 || sp >= 1.4)) { print "mobile"; exit }
    if (r >= 1)      { print "policed"; exit }
    if (tb >= 3)     { print "spiky";  exit }
    if (j >= 0.3 || sp >= 1.4) { print "variable"; exit }
    if (t >= 120)    { print "far";    exit }
    print "near";
  }'
}

class_label() {
  case "${1:-}" in
    local)   printf '同机房\n' ;;
    idle)    printf '数据不足\n' ;;
    bloated) printf '接入网排队\n' ;;
    mobile)  printf '移动网络\n' ;;
    policed) printf '限速器\n' ;;
    spiky)   printf '间歇排队\n' ;;
    variable) printf '时变链路\n' ;;
    far)     printf '远端固网\n' ;;
    near)    printf '近端固网\n' ;;
    *)       printf '未知\n' ;;
  esac
}

# What each class implies, and — as importantly — what it does not.
class_policy() {
  case "${1:-}" in
    far)
      printf '%s\n' 'initcwnd 32' \
        '稳定、低重传的高 RTT 路径可 A/B 测试更大的发送初始窗，减少短连接慢启动等待；不改 initrwnd，因为下载场景的客户端上传通常不是瓶颈'
      ;;
    near)
      printf '%s\n' '' '默认即可。BDP 小，加大起步窗口只会制造首窗突发，没有收益'
      ;;
    mobile)
      printf '%s\n' 'initcwnd 10' \
        '保守起步，别把首窗突发灌进调度受限的无线链路。注意：不要给移动网段换 cubic —— BBR 忽略丢包这一点在随机无线丢包上恰恰是优势，cubic 会每丢一次就砍窗'
      ;;
    policed)
      printf '%s\n' '' \
        '延迟很稳却在丢包，形状像 policer。当前 delivery_rate 不是可靠容量估计，阶段一不据此生成 tc 限速；先用可控的 iperf3 对端做触发式复测'
      ;;
    bloated)
      printf '%s\n' '' \
        '对端接入网在囤队列。服务器无法直接管理对方队列；若要试降 pacing 或 BBRv3，请在可回滚测试机上做 A/B，阶段一不自动下发'
      ;;
    spiky)
      printf '%s\n' '' \
        '中位队列不深但尾部有尖峰，卡顿发生在尖峰上。先观察，样本多了再决定'
      ;;
    variable)
      printf '%s\n' '' \
        'RTT 或延迟尾部持续变化，但没有足够证据归因于排队或限速器。不要凭一轮快照改参数；优先延长观测，并在可控机器上对比 BBRv3'
      ;;
    *)
      printf '%s\n' '' '样本不足或同机房对端，不做任何改动'
      ;;
  esac
}

# ── 画像库 ─────────────────────────────────────────────────────────────────

# Running totals per prefix, so a profile is what a peer looks like over
# hours rather than what it looked like during one 30-second window.
# shellcheck disable=SC2016 # awk program; shell expansion is intentionally disabled
PROFILE_MERGE_AWK='
BEGIN { FS = OFS = "\t" }
# Existing database first, then the new observations.
FNR == NR && FILENAME == db {
  if ($1 == "prefix" || $1 == "") next
  n[$1] = $2; trusted[$1] = $3; p50s[$1] = $4; p95m[$1] = $5
  mins[$1] = $6; jits[$1] = $7; bls[$1] = $8; tlm[$1] = $9
  retrs[$1] = $10; sgs[$1] = $11; mbm[$1] = $12; cmx[$1] = $13
  first[$1] = $14; last[$1] = $15
  next
}
{
  if ($13 != "in") next
  k = $1
  if (!(k in n)) { n[k] = 0; trusted[k] = 0; first[k] = stamp }
  n[k]++
  if (($12 + 0) >= minseg) {
    trusted[k]++
    p50s[k] += $4
    if ($5 > p95m[k]) p95m[k] = $5
    if (!(k in mins) || $6 < mins[k]) mins[k] = $6
    jits[k] += $7
    bls[k]  += ($8 > 0 ? $8 : 0)
    if ($14 > tlm[k]) tlm[k] = $14
    retrs[k] += $15
    sgs[k] += $12
    if ($10 > mbm[k]) mbm[k] = $10
    if ($2 > cmx[k]) cmx[k] = $2
  }
  seen[k] = stamp
}
END {
  print "prefix", "obs", "trusted", "p50sum", "p95max", "minrtt", "jitsum", \
        "bloatsum", "tailmax", "retrtotal", "segtotal", "mbpsmax", "connmax", "first", "last"
  for (k in n)
    print k, n[k], trusted[k], p50s[k], p95m[k], mins[k], jits[k], bls[k], tlm[k], \
          retrs[k], sgs[k], mbm[k], cmx[k], first[k], (k in seen ? seen[k] : last[k])
}
'

merge_profiles() {
  local agg="$1" stamp merged
  stamp="$(date -u +%s 2>/dev/null || printf '0')"
  mkdir -p "$STATE_DIR"
  [[ -e "$PROFILE_DB" ]] || printf 'prefix\n' > "$PROFILE_DB"
  merged="$(mktemp)"
  awk -v db="$PROFILE_DB" -v stamp="$stamp" -v minseg="$MIN_SEGS_FOR_RETRANS" \
    "$PROFILE_MERGE_AWK" "$PROFILE_DB" "$agg" > "$merged"
  mv -f "$merged" "$PROFILE_DB"
  chmod 0600 "$PROFILE_DB"
}

# ── 采集一轮 ───────────────────────────────────────────────────────────────

# Produces the aggregate rows for one sampling round. Shared by scan and watch
# so the numbers a profile is built from are the same ones scan showed you.
collect_round() {
  local samples="$1" interval="$2" group="$3" out="$4" raw
  raw="$(mktemp)"
  collect_samples "$samples" "$interval" "$raw"
  if [[ ! -s "$raw" ]]; then rm -f "$raw"; return 1; fi
  awk -v mode="$group" "$AGGREGATE_AWK" "$raw" > "$out"
  rm -f "$raw"
  [[ -s "$out" ]]
}

row_spread() { awk -v a="${1:-1}" -v b="${2:-1}" 'BEGIN {printf "%.2f", (b > 0) ? a / b : 1}'; }

cmd_scan() {
  local samples="$SAMPLES" interval="$INTERVAL_S" group="$GROUP_BY" show_all=0 agg
  while (( $# )); do
    case "$1" in
      --samples) [[ $# -ge 2 ]] || die "--samples 缺少值"; samples="$2"; shift 2 ;;
      --interval) [[ $# -ge 2 ]] || die "--interval 缺少值"; interval="$2"; shift 2 ;;
      --group) [[ $# -ge 2 ]] || die "--group 缺少值"; group="$2"; shift 2 ;;
      --all) show_all=1; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done
  if ! is_uint "$samples" || (( samples < 2 || samples > 60 )); then die "--samples 需为 2-60"; fi
  if ! is_uint "$interval" || (( interval < 1 || interval > 60 )); then die "--interval 需为 1-60"; fi
  [[ "$group" =~ ^(ip|net)$ ]] || die "--group 只能是 ip 或 net"
  has ss || die "缺少 ss；请安装 iproute2"

  panel_title 'routetune 当前分布'
  info "采样 ${samples} 次 × ${interval}s，按 $( [[ "$group" == net ]] && printf '前缀' || printf 'IP' )聚合…"
  agg="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$agg'" RETURN
  collect_round "$samples" "$interval" "$group" "$agg" || {
    warn "采样窗口内没有活跃 TCP 连接（有流量时再测）"; return 0; }

  printf '\n  %b前缀                      连接 RTT50 RTT95  最低  抖动  膨胀  尾涨  重传%%  画像%b\n' "$BOLD" "$RESET"
  rule_light
  local prefix conns cc p50 p95 minrtt jit bloat rpct segs dir tail
  local spread class hidden=0 shown=0
  while IFS=$'\t' read -r prefix conns cc p50 p95 minrtt jit bloat rpct _ _ segs dir tail _; do
    if [[ "$dir" == out ]] && (( show_all == 0 )); then hidden=$((hidden + 1)); continue; fi
    shown=$((shown + 1))
    spread="$(row_spread "$p95" "$p50")"
    class="$(classify_peer "$p50" "$jit" "$bloat" "$tail" "$rpct" "$spread" "$segs")"
    local color="$GREEN"
    case "$class" in mobile|policed|bloated|spiky|variable) color="$YELLOW" ;; esac
    local bt="$bloat" tt="$tail" rt="$rpct"
    awk -v b="$bloat" 'BEGIN {exit !(b < 0)}' && { bt="—"; tt="—"; }
    (( segs < MIN_SEGS_FOR_RETRANS )) && rt="—"
    printf '  %b%-24s%b %4s %5s %5s %5s %5s %5s %5s %6s  %s\n' \
      "$color" "$prefix" "$RESET" "$conns" "$p50" "$p95" "$minrtt" "$jit" \
      "$bt" "$tt" "$rt" "$(class_label "$class")"
    printf '    %b→ %s%b\n' "$DIM" \
      "$(diagnose_peer "$bloat" "$jit" "$rpct" "$p50" "$segs" "$tail" "$spread")" "$RESET"
  done < "$agg"
  rule_light
  (( hidden > 0 )) && printf '  %b已隐藏 %s 个本机出站对端；--all 可以看%b\n' "$DIM" "$hidden" "$RESET"
  printf '  %b这是一轮快照。routetune watch 会把多轮观测累积成画像，再据此出策略%b\n' "$DIM" "$RESET"
}

cmd_watch() {
  need_root "$@"
  local minutes=30 samples="$SAMPLES" interval="$INTERVAL_S" group="$GROUP_BY"
  while (( $# )); do
    case "$1" in
      --minutes) [[ $# -ge 2 ]] || die "--minutes 缺少值"; minutes="$2"; shift 2 ;;
      --samples) [[ $# -ge 2 ]] || die "--samples 缺少值"; samples="$2"; shift 2 ;;
      --interval) [[ $# -ge 2 ]] || die "--interval 缺少值"; interval="$2"; shift 2 ;;
      --group) [[ $# -ge 2 ]] || die "--group 缺少值"; group="$2"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  if ! is_uint "$minutes" || (( minutes < 1 || minutes > 1440 )); then die "--minutes 需为 1-1440"; fi
  if ! is_uint "$samples" || (( samples < 2 || samples > 60 )); then die "--samples 需为 2-60"; fi
  if ! is_uint "$interval" || (( interval < 1 || interval > 60 )); then die "--interval 需为 1-60"; fi
  [[ "$group" =~ ^(ip|net)$ ]] || die "--group 只能是 ip 或 net"
  has ss || die "缺少 ss；请安装 iproute2"
  local round_s=$((samples * interval)) rounds agg n=0 kept=0
  rounds=$(( minutes * 60 / round_s )); (( rounds < 1 )) && rounds=1
  panel_title 'routetune 观测'
  info "每轮 ${round_s}s，共 ${rounds} 轮（约 ${minutes} 分钟），结果累积到 $PROFILE_DB"
  info "中途 Ctrl-C 也会保留已经写入的画像。"
  agg="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$agg'" RETURN
  while (( n < rounds )); do
    n=$((n + 1))
    if collect_round "$samples" "$interval" "$group" "$agg"; then
      merge_profiles "$agg"
      kept=$((kept + 1))
      printf '  %b[%s/%s]%b 已合并 %s 个前缀\n' "$DIM" "$n" "$rounds" "$RESET" "$(($(grep -c "" "$agg")))"
    else
      printf '  %b[%s/%s]%b 窗口内无活跃连接，跳过\n' "$DIM" "$n" "$rounds" "$RESET"
    fi
  done
  if (( kept == 0 )); then
    warn "没有采到任何数据；确认这台机器上确实有客户端在用"
    return 0
  fi
  log "观测完成，${kept}/${rounds} 轮有数据。看结果：$PROGRAM profiles"
}

# ── 画像与建议 ─────────────────────────────────────────────────────────────

# Collapses the running totals back into per-prefix averages plus the class.
# shellcheck disable=SC2016 # awk program; shell expansion is intentionally disabled
PROFILE_VIEW_AWK='
BEGIN { FS = OFS = "\t" }
NR == 1 || $1 == "prefix" || $1 == "" { next }
{
  obs = $3 + 0; if (obs < 1) next
  p50 = $4 / obs; p95 = $5 + 0; mn = $6 + 0
  jit = $7 / obs; bl = $8 / obs; tl = $9 + 0
  sg = $11 + 0; rt = (sg > 0) ? ($10 * 100 / sg) : 0
  mb = $12 + 0; cn = $13 + 0
  sp  = (p50 > 0) ? p95 / p50 : 1
  printf "%s\t%d\t%.1f\t%.1f\t%.1f\t%.3f\t%.2f\t%.2f\t%.4f\t%d\t%.1f\t%d\t%.2f\n", \
    $1, obs, p50, p95, mn, jit, bl, tl, rt, sg, mb, cn, sp
}
'

profile_rows() {
  [[ -r "$PROFILE_DB" ]] || return 1
  awk "$PROFILE_VIEW_AWK" "$PROFILE_DB"
}

cmd_profiles() {
  local rows
  rows="$(profile_rows)" || die "还没有画像，先跑：$PROGRAM watch --minutes 30"
  [[ -n "$rows" ]] || die "画像库是空的，先跑：$PROGRAM watch --minutes 30"
  panel_title 'routetune 画像'
  printf '  %b前缀                      轮次 RTT50 RTT95  最低  抖动  膨胀  尾涨  重传%%  画像%b\n' "$BOLD" "$RESET"
  rule_light
  local prefix obs p50 p95 mn jit bl tl rt sg mb cn sp class
  while IFS=$'\t' read -r prefix obs p50 p95 mn jit bl tl rt sg mb cn sp; do
    class="$(classify_peer "$p50" "$jit" "$bl" "$tl" "$rt" "$sp" "$sg")"
    local color="$GREEN"
    case "$class" in mobile|policed|bloated|spiky|variable) color="$YELLOW" ;; esac
    printf '  %b%-24s%b %4s %5s %5s %5s %5s %5s %5s %6s  %s\n' \
      "$color" "$prefix" "$RESET" "$obs" "$p50" "$p95" "$mn" "$jit" "$bl" "$tl" "$rt" \
      "$(class_label "$class")"
  done <<< "$rows"
  rule_light
  printf '  %b轮次 = 这个前缀被观测到多少轮；轮次越多画像越可信%b\n' "$DIM" "$RESET"
  printf '  %b出策略：%s recommend%b\n' "$DIM" "$PROGRAM" "$RESET"
}

# Resolve every prefix through the kernel instead of assuming one IPv4 default
# gateway. This supports gateway-less VPS routes, IPv6, and policy tables. We
# still decline multipath routes: copying one selected nexthop into a /24 would
# silently destroy ECMP semantics.
route_context() {
  local prefix="$1" probe family out via dev src table
  probe="${prefix%/*}"
  if [[ "$probe" == *:* ]]; then family=-6; else family=-4; fi
  out="$(ip "$family" route get "$probe" 2>/dev/null | sed -n '1p')" || return 1
  [[ -n "$out" ]] || return 1
  case " $out " in
    *" unreachable "*|*" prohibit "*|*" blackhole "*|*" local "*) return 1 ;;
    *" nhid "*|*" nexthop "*) return 2 ;;
  esac
  via="$(awk '{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}' <<< "$out")"
  dev="$(awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' <<< "$out")"
  src="$(awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}' <<< "$out")"
  table="$(awk '{for(i=1;i<NF;i++) if($i=="table"){print $(i+1); exit}}' <<< "$out")"
  [[ -n "$dev" ]] || return 1
  [[ -n "$table" ]] || table=main
  printf '%s|%s|%s|%s|%s\n' "$family" "$via" "$dev" "$src" "$table"
}

route_commands() {
  local prefix="$1" opts="$2" ctx family via dev src table existing
  ctx="$(route_context "$prefix")" || return $?
  IFS='|' read -r family via dev src table <<< "$ctx"
  existing="$(ip "$family" route show table "$table" exact "$prefix" 2>/dev/null || true)"
  [[ -z "$existing" ]] || return 3
  printf 'sudo ip %s route add %s' "$family" "$prefix"
  [[ -z "$via" ]] || printf ' via %s' "$via"
  printf ' dev %s' "$dev"
  [[ -z "$src" ]] || printf ' src %s' "$src"
  printf ' table %s %s\n' "$table" "$opts"
  printf 'sudo ip %s route del %s table %s\n' "$family" "$prefix" "$table"
}

# Emits commands. Never runs them. Phase one is about earning trust in the
# profiles, and a wrong profile that only prints is a wasted minute, while a
# wrong profile that writes to the routing table is an outage.
cmd_recommend() {
  local rows min_obs=3
  while (( $# )); do
    case "$1" in
      --min-obs) [[ $# -ge 2 ]] || die "--min-obs 缺少值"; min_obs="$2"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  if ! is_uint "$min_obs" || (( min_obs < 1 )); then die "--min-obs 需为正整数"; fi
  rows="$(profile_rows)" || die "还没有画像，先跑：$PROGRAM watch --minutes 30"
  has ip || die "缺少 ip；请安装 iproute2"

  panel_title 'routetune 策略建议'
  printf '  %b下面的命令 routetune 不会替你执行。%b\n' "$BOLD" "$RESET"
  printf '  %b每条命令都复制内核当前为该前缀选择的出口、下一跳和路由表，只增加 TCP metrics。%b\n' "$DIM" "$RESET"
  printf '  %b若已存在精确路由或检测到多路径，routetune 会拒绝生成命令，避免覆盖现网语义。%b\n' "$DIM" "$RESET"
  printf '  %b重启后失效（阶段一不做持久化），先手动跑一条看效果再说。%b\n\n' "$DIM" "$RESET"

  local prefix obs p50 p95 mn jit bl tl rt sg sp class opts reason commands rc
  local emitted=0 few_obs=0 not_actionable=0 route_skipped=0
  while IFS=$'\t' read -r prefix obs p50 p95 mn jit bl tl rt sg _ _ sp; do
    if (( obs < min_obs )); then few_obs=$((few_obs + 1)); continue; fi
    class="$(classify_peer "$p50" "$jit" "$bl" "$tl" "$rt" "$sp" "$sg")"
    case "$class" in local|idle) not_actionable=$((not_actionable + 1)); continue ;; esac
    opts="$(class_policy "$class" | sed -n '1p')"
    reason="$(class_policy "$class" | sed -n '2p')"
    printf '  %b%s%b  %b%s%b  %s轮观测\n' "$BOLD" "$prefix" "$RESET" \
      "$CYAN" "$(class_label "$class")" "$RESET" "$obs"
    printf '    %bRTT %s/%s ms（底噪 %s）｜抖动 %s｜膨胀 %s｜重传 %s%%%b\n' \
      "$DIM" "$p50" "$p95" "$mn" "$jit" "$bl" "$rt" "$RESET"
    if [[ -n "$opts" ]]; then
      if commands="$(route_commands "$prefix" "$opts")"; then
        printf '    %b%s%b\n' "$GREEN" "$(sed -n '1p' <<< "$commands")" "$RESET"
        printf '    %b回滚：%s%b\n' "$DIM" "$(sed -n '2p' <<< "$commands")" "$RESET"
        emitted=$((emitted + 1))
      else
        rc=$?; route_skipped=$((route_skipped + 1))
        case "$rc" in
          2) printf '    %b（检测到多路径/ECMP；为避免固定到单个下一跳，不生成命令）%b\n' "$YELLOW" "$RESET" ;;
          3) printf '    %b（该前缀已有精确路由；为避免覆盖现有属性，不生成命令）%b\n' "$YELLOW" "$RESET" ;;
          *) printf '    %b（无法可靠解析该前缀的实际出口，不生成命令）%b\n' "$YELLOW" "$RESET" ;;
        esac
      fi
    else
      printf '    %b（不建议改路由参数）%b\n' "$DIM" "$RESET"
    fi
    printf '    %b%s%b\n\n' "$DIM" "$reason" "$RESET"
  done <<< "$rows"
  rule_light
  printf '  %s 条可执行建议' "$emitted"
  (( few_obs > 0 )) && printf '；%s 个前缀观测不足 %s 轮，先攒够再说' "$few_obs" "$min_obs"
  (( not_actionable > 0 )) && printf '；%s 个是同机房或样本太少的对端，本来就不该动' "$not_actionable"
  (( route_skipped > 0 )) && printf '；%s 个前缀因路由安全检查跳过' "$route_skipped"
  printf '\n'
}

# ── 体检 ───────────────────────────────────────────────────────────────────

# Per-route congestion control landed in Linux 4.0 (RTAX_CC_ALGO), but only
# iproute2 knows whether the local `ip` can express it.
supports_congctl() {
  has ip || return 1
  ip route help 2>&1 | grep -q 'congctl'
}

# DSACK reports duplicate data observed by the receiver. It is useful evidence
# for reordering/spurious retransmission, but the counters below do not share a
# unit: DSACK counts events or blocks, while TcpRetransSegs counts segments.
# The ratio is therefore a whole-host proxy, never an exact false-loss share.
dsack_ratio() {
  local out retr dsack
  has nstat || return 1
  out="$(nstat -asz 2>/dev/null)" || return 1
  retr="$(printf '%s\n' "$out" | awk '$1 == "TcpRetransSegs" {print $2; exit}')"
  dsack="$(printf '%s\n' "$out" | awk '$1 ~ /^TcpExtTCPDSACK(Recv|OfoRecv)$/ {s += $2} END {print s + 0}')"
  is_uint "${retr:-}" && is_uint "${dsack:-}" || return 1
  (( retr > 0 )) || return 1
  awk -v d="$dsack" -v r="$retr" 'BEGIN {printf "%.1f\n", d * 100 / r}'
}

cmd_doctor() {
  panel_title 'routetune 体检'
  local avail cc variant iface via table qdisc dsack ctx family src
  avail="$(available_cc)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
  printf '  内核版本:          %s\n' "$(uname -r 2>/dev/null || printf 'unknown')"
  printf '  可用拥塞控制:      %s\n' "${avail:-未知}"
  printf '  当前生效:          %s\n' "$cc"
  if [[ "$cc" == bbr || "$cc" == bbr2 || "$cc" == bbr3 ]]; then
    variant="$(bbr_variant "$avail")"
    printf '  BBR 版本判定:      %s\n' "$(bbr_variant_note "$variant")"
  fi
  printf '\n'
  if supports_congctl; then
    log "iproute2 支持 per-route congctl，可以给单个前缀单独指定拥塞控制"
  else
    warn "本机 iproute2 不认识 congctl；initcwnd/initrwnd/rto_min 仍然可用"
  fi
  ctx="$(route_context 1.1.1.1 2>/dev/null || route_context 2606:4700:4700::1111 2>/dev/null || true)"
  if [[ -n "$ctx" ]]; then
    IFS='|' read -r family via iface src table <<< "$ctx"
    printf '  实际出口样例:      %s%s dev %s table %s\n' "$family" "${via:+ via $via}" "$iface" "$table"
  else
    printf '  实际出口样例:      无法解析\n'
  fi
  if [[ -n "$iface" ]] && has tc; then
    qdisc="$(tc qdisc show dev "$iface" 2>/dev/null | awk '$1 == "qdisc" {print $2; exit}')"
    printf '  根队列:            %s\n' "${qdisc:-未知}"
  fi
  printf '\n'
  dsack="$(dsack_ratio || true)"
  if [[ -n "$dsack" ]]; then
    printf '  %b▸ 全机重传旁证%b\n' "$BOLD" "$RESET"
    printf '    DSACK 事件 / 重传段 = %s%%（自开机累计，仅作旁证）\n' "$dsack"
    printf '    %b两者计数单位不同，这不是“虚假重传占比”，也不能归因到某个前缀。%b\n' "$DIM" "$RESET"
    if awk -v s="$dsack" 'BEGIN {exit !(s >= 20)}'; then
      warn "DSACK 信号较强：乱序或过早重传值得排查，别只按丢包去降速"
    fi
  fi
  printf '\n'
  if [[ -r "$PROFILE_DB" ]]; then
    local n; n="$(profile_rows | grep -c "" || printf '0')"
    printf '  画像库:            %s 个前缀（%s）\n' "$n" "$PROFILE_DB"
  else
    printf '  画像库:            还是空的，跑 %s watch 开始积累\n' "$PROGRAM"
  fi
}

cmd_reset() {
  need_root reset
  [[ -e "$PROFILE_DB" ]] || { info "画像库本来就是空的"; return 0; }
  rm -f "$PROFILE_DB"
  log "已清空画像库"
}

usage() {
  cat <<'EOF'
routetune - 按路由前缀分区调优

sysctl 是全机器一套的：一个拥塞控制、一个缓冲上限、一个根队列。客户端长得像的时候
这没问题，客户端分散在不同地区和接入网时就不行了——丢 3% 的移动网、250ms 外的固网、
和同机房的邻居，想要的参数完全不同。

能表达这种差异的是路由表：initcwnd / initrwnd / rto_min / window / advmss / congctl
都是 per-route 的。routetune 观测每个对端、聚成画像、再输出画像对应的 per-route 策略。

  routetune scan                    看当前一轮的分布
  routetune scan --group ip         按 IP 而不是前缀聚合
  routetune scan --all              连本机出站对端一起看
  routetune watch --minutes 30      持续观测并累积画像
  routetune profiles                看已累积的画像
  routetune recommend               输出 per-route 策略命令（不执行）
  routetune recommend --min-obs 5   只对观测够 5 轮的前缀出建议
  routetune doctor                  内核能力、BBR 判定与全机 DSACK 旁证
  routetune reset                   清空画像库

画像分类与对应策略：

  远端固网   RTT ≥120ms 且稳定      → A/B 测试 initcwnd 32
  近端固网   RTT <120ms 且稳定      → 默认即可，加大起步只会制造突发
  移动网络   丢包 + 延迟尾部散开     → initcwnd 保守；不要换 cubic
  限速器     丢包 + 延迟纹丝不动     → 对该前缀单独限速，而不是全局限速
  接入网排队 中位膨胀 ≥3            → 服务端限速无效，根治靠 BBRv3
  间歇排队   中位不深但尾部有尖峰    → 先观察
  时变链路   抖动或尾部散布高、无明确丢包 → 延长观测，不凭快照改参数

阶段一只出建议不落地。画像准不准要先用真实流量验证过，再谈自动下发。

做不到的事：无线层丢包服务端消不掉，per-route 也不行；BBRv3 要换内核，脚本给不了。
EOF
}

main() {
  local command="${1:-help}"
  case "$command" in
    scan) shift; cmd_scan "$@" ;;
    watch) shift; cmd_watch "$@" ;;
    profiles) cmd_profiles ;;
    recommend) shift; cmd_recommend "$@" ;;
    doctor) cmd_doctor ;;
    reset) cmd_reset ;;
    help|-h|--help) usage ;;
    version|--version) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    *) die "未知命令：${command}（用 --help 查看帮助）" ;;
  esac
}

if [[ "${ROUTETUNE_LIB_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
