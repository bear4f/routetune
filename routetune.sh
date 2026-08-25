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

VERSION="0.3.1"
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
  dsack = 0; reord = 0; dsegsin = 0; mss = 0; pmtu = 0
  rwndlim = 0; sndlim = 0; busy = 0
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
    else if (f ~ /^data_segs_in:/) dsegsin = substr(f, 14) + 0
    else if (f ~ /^cwnd:/) cwnd = substr(f, 6) + 0
    # ss only prints these when non-zero, so an absent field means zero.
    # dsack_dups is the receiver telling us a retransmit was unnecessary: the
    # per-socket version of the whole-host DSACK counter doctor already shows,
    # except this one can be attributed to a prefix.
    else if (f ~ /^dsack_dups:/) dsack = substr(f, 12) + 0
    else if (f ~ /^reord_seen:/) reord = substr(f, 12) + 0
    # advmss: and rcvmss: also end in "mss:", so these stay anchored.
    else if (f ~ /^mss:/) mss = substr(f, 5) + 0
    else if (f ~ /^pmtu:/) pmtu = substr(f, 6) + 0
    # Printed as "100ms(10.5%)". Numeric coercion takes the leading run of
    # digits, so the unit and the lifetime percentage fall away on their own.
    else if (f ~ /^rwnd_limited:/) rwndlim = substr(f, 14) + 0
    else if (f ~ /^sndbuf_limited:/) sndlim = substr(f, 16) + 0
    else if (f ~ /^busy:/) busy = substr(f, 6) + 0
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
  printf "%s\t%s\t%s\t%.3f\t%.3f\t%.3f\t%d\t%d\t%.3f\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
    local "|" peer, ipof(peer), cc, rtt, rttvar, minrtt, retr, dsegs, mbps, cwnd, dir, \
    dsack, reord, dsegsin, mss, pmtu, rwndlim, sndlim, busy
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
  dsack = $12 + 0; reord = $13 + 0; dsegsin = $14 + 0; mss = $15 + 0; pmtu = $16 + 0
  rwndlim = $17 + 0; sndlim = $18 + 0; busy = $19 + 0
  # Keep inbound and outbound sockets in separate buckets even when they share
  # a prefix. watch persists only inbound rows; otherwise a CDN connection in
  # the same /24 could contaminate a client profile.
  g = base SUBSEP dir; glabel[g] = base
  if (!(key in firstseen)) {
    firstseen[key] = 1; fretr[key] = retr; fsegs[key] = dsegs; kgroup[key] = g; kdir[key] = dir
    fdsack[key] = dsack; freord[key] = reord; fdsin[key] = dsegsin
    frwnd[key] = rwndlim; fsnd[key] = sndlim; fbusy[key] = busy
  }
  lretr[key] = retr; lsegs[key] = dsegs
  ldsack[key] = dsack; lreord[key] = reord; ldsin[key] = dsegsin
  lrwnd[key] = rwndlim; lsnd[key] = sndlim; lbusy[key] = busy
  # Point-in-time, not counters. The conservative reading of a group is its
  # smallest segment size against its smallest path MTU.
  if (mss > 0 && (!(g in gmss) || mss < gmss[g])) gmss[g] = mss
  if (pmtu > 0 && (!(g in gpmtu) || pmtu < gpmtu[g])) gpmtu[g] = pmtu
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
    # Everything the receiver reports about our sending shares the send-side
    # activity gate, so an idle socket cannot dilute the evidence of a busy one.
    if (ds > 0) {
      sumretr[g] += dr; sumsegs[g] += ds
      dk = ldsack[key] - fdsack[key]; if (dk > 0) sumdsack[g] += dk
      dz = lreord[key] - freord[key]; if (dz > 0) sumreord[g] += dz
      dw = lrwnd[key] - frwnd[key];   if (dw > 0) sumrwnd[g] += dw
      dn = lsnd[key]  - fsnd[key];    if (dn > 0) sumsnd[g]  += dn
      db = lbusy[key] - fbusy[key];   if (db > 0) sumbusy[g] += db
    }
    # The upload direction has its own gate: a client can be sending to us
    # while we send it almost nothing.
    di = ldsin[key] - fdsin[key]
    if (di > 0) sumdsin[g] += di
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
    # What share of our retransmissions the receiver told us were unnecessary.
    # -1 means "no retransmissions to attribute", which is not the same as 0%.
    spur = (sumretr[g] > 0) ? sumdsack[g] * 100 / sumretr[g] : -1
    # How much of the time we were actively sending we spent blocked, and on
    # what. These are the only two signals that say why a peer is not faster.
    rwpct = (sumbusy[g] > 0) ? sumrwnd[g] * 100 / sumbusy[g] : -1
    sbpct = (sumbusy[g] > 0) ? sumsnd[g] * 100 / sumbusy[g] : -1
    tot = sumsegs[g] + sumdsin[g]
    upl = (tot > 0) ? sumdsin[g] * 100 / tot : 0
    d = (nout[g] == 0) ? "in" : ((nin[g] == 0) ? "out" : "mix")
    # 16-22 are ready-to-print ratios for a single scan; 23-27 are the raw
    # additive counters, because only sums can be merged across rounds.
    printf "%s\t%d\t%s\t%.1f\t%.1f\t%.1f\t%.3f\t%.2f\t%.4f\t%.1f\t%d\t%d\t%s\t%.2f\t%d\t%.1f\t%d\t%.1f\t%.1f\t%.1f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
      glabel[g], conns[g], ccname[g], p50, p95, gmin[g], jit, bloat, rpct, at(m, n, 0.50), gcwnd[g], sumsegs[g], d, tail, sumretr[g], \
      spur, sumreord[g], upl, rwpct, sbpct, gmss[g], gpmtu[g], \
      sumdsack[g], sumrwnd[g], sumsnd[g], sumbusy[g], sumdsin[g]
  }
}
'

# ── 判定 ───────────────────────────────────────────────────────────────────

# Below this, rtt and rttvar are dominated by timer granularity, interrupt
# coalescing and scheduling — not by anything happening on the network. A
# same-datacenter peer at 0.7ms will happily report a jitter ratio of 0.4.
LOCAL_RTT_FLOOR_MS=5
# Stale RTT fields on an idle socket are not a path sample. A modest amount of
# fresh data is enough to trust the latency shape, while loss needs a larger
# denominator: one retransmit out of 1000 is already 0.1%.
MIN_SEGS_FOR_PATH=100
MIN_SEGS_FOR_RETRANS=1000
# A round whose RTT95 reached this multiple of the path floor counts as a
# spike. What matters for policy is how OFTEN that happens, not how bad the
# single worst round was, so this is a counting threshold rather than a verdict.
SPIKE_TAIL=2
# Share of our retransmissions that the receiver reported back as duplicates.
# dsack_dups counts DSACK blocks and retrans counts segments, so one block can
# cover several segments and the ratio is close but not exactly a percentage.
# Hence a deliberately conservative bar: a clear majority, not a plurality.
SPURIOUS_SHARE=50
MIN_RETRANS_FOR_SPURIOUS=20
# Share of active sending time spent blocked on the receiver window. Above
# this the peer, not the path and not our first window, is the constraint.
RWND_LIMITED_SHARE=25

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

# These are observation bands, not cause labels. A passive retransmission
# counter cannot distinguish radio loss, random path loss and a policer by
# itself, even when latency happens to be flat during one short window.
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
  local tail="${6:-$1}" spread="${7:-1}" spurious="${8:--1}" retrcount="${9:-0}"
  awk -v b="$bloat" -v j="$jitter" -v r="$retrans" -v t="$rtt" -v sg="$segs" \
      -v tb="$tail" -v sp="$spread" -v spur="$spurious" -v rc="$retrcount" \
      -v spshare="$SPURIOUS_SHARE" -v minrc="$MIN_RETRANS_FOR_SPURIOUS" \
      -v floor="$LOCAL_RTT_FLOOR_MS" -v minpath="$MIN_SEGS_FOR_PATH" \
      -v minseg="$MIN_SEGS_FOR_RETRANS" 'BEGIN {
    if (t < floor) {
      print "同机房量级连接（RTT < " floor "ms）——这个量级上抖动和膨胀都是计时噪声，不用管";
      exit
    }
    if (sg < minpath) {
      print "基本空闲，采样窗口内只发了 " sg " 段，数据不足以判断";
      exit
    }
    trust_r = (sg >= minseg)
    if (b >= 3 && (!trust_r || r < 1)) {
      print "接入网排队膨胀——瓶颈队列不在服务器上；先做更长观测，再在可控机器上 A/B 测试 pacing 或 BBRv3";
      exit
    }
    if (trust_r && r >= 0.1 && rc >= minrc && spur >= spshare) {
      printf "虚假重传——%d%% 的重传被对端 DSACK 确认是重复包，这 %.2f%% 不是丢包，是乱序或过早重传；不要按这个数字降速\n", spur, r;
      exit
    }
    if (trust_r && r >= 1 && b >= 2) {
      print "既排队又丢包——被动快照不能判断队列或丢包发生在哪一段；先延长观测，不据此直接降速";
      exit
    }
    # A spread latency tail plus loss is useful evidence of radio scheduling.
    # Flat latency is not proof of a policer: the same mobile prefix can be
    # temporarily flat during one window and bursty during the next.
    if (trust_r && r >= 1 && (j >= 0.15 || sp >= 1.4)) {
      print "无线接入层丢包（4G/5G 典型）——没有持续排队，但丢包和延迟尾部都高。这类丢包不是拥塞信号，降速率收益有限，客户端播放器多缓冲更有效";
      exit
    }
    if (trust_r && r >= 1) {
      print "稳定延迟丢包——可能是暂时平稳的移动网、随机路径丢包或 policer；被动快照无法区分，不要据此直接降速，需主动复测";
      exit
    }
    if (trust_r && r >= 0.1) {
      print "轻度丢包——高于干净线但不足以归因；继续用 watch 累积画像，不据此改路由参数";
      exit
    }
    if (tb >= 3) { print "间歇性排队——中位队列不深，但尾部涨到底噪的 " sprintf("%.1f", tb) " 倍，卡顿多半发生在这些尖峰上"; exit }
    if (j >= 0.3) { print "链路抖动大（无线接入或路径拥塞）——速率波动来自这里，不是你的配置"; exit }
    if (sp >= 1.4) { print "延迟尾部散开——RTT95 是中位的 " sprintf("%.1f", sp) " 倍，链路存在时变尖峰；继续累积画像"; exit }
    if (b >= 1.5) { print "轻微排队——路径稳定坐在底噪之上，不影响使用，但已有存量队列时不适合再加大首窗"; exit }
    if (!trust_r) { print "路径延迟健康；窗口内 " sg " 段足以看 RTT，但未满 " minseg " 段，重传率暂不判断"; exit }
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


# Is there a congestion control in this kernel that is a real upgrade over
# what is running? BBRv3 has never been in mainline, so on a stock kernel the
# honest answer is no, and per-route congctl has nothing better to offer than
# the global default. Saying so is the point: the alternative is proposing a
# switch to cubic, which on random radio loss is a downgrade.
better_cc() {
  local avail=" ${1:-} " cur="${2:-}"
  case "$avail" in
    *" bbr3 "*) [[ "$cur" != bbr3 ]] && { printf 'bbr3\n'; return 0; } ;;
  esac
  case "$avail" in
    *" bbr2 "*) [[ "$cur" != bbr2 && "$cur" != bbr3 ]] && { printf 'bbr2\n'; return 0; } ;;
  esac
  return 1
}

# Every metric must be shown to bind before it is proposed. A parameter that
# provably changes nothing is not a cautious suggestion — it is noise that
# costs the reader time and the tool its credibility. Prints the surviving
# option string on line 1 and one "metric<TAB>why it was dropped" line after.
gate_metrics() {
  local opts="${1:-}" rwndpct="${2:--1}" keepers=() skipped=() name
  local -a words
  # The script runs under IFS=$'\n\t', so a default read -a would keep
  # "initcwnd 32" as a single word and every metric would sail past the case
  # below unexamined. Split on spaces here and nowhere else.
  local IFS=' '
  read -r -a words <<< "$opts"
  local i=0
  while (( i < ${#words[@]} )); do
    name="${words[i]}"
    case "$name" in
      initcwnd|initrwnd|rto_min|advmss|congctl|reordering)
        if metric_binds "$name" "$rwndpct"; then
          keepers+=("$name" "${words[i+1]:-}")
        else
          skipped+=("$name	$(metric_skip_reason "$name" "$rwndpct")")
        fi
        i=$((i + 2))
        ;;
      *) keepers+=("$name"); i=$((i + 1)) ;;
    esac
  done
  printf '%s\n' "${keepers[*]:-}"
  local line; for line in "${skipped[@]:-}"; do [[ -n "$line" ]] && printf '%s\n' "$line"; done
  return 0
}

metric_binds() {
  case "${1:-}" in
    # A bigger first window cannot help a transfer that is already stalling on
    # the receiver's advertised window: the peer, not our opening burst, is the
    # ceiling.
    initcwnd) awk -v w="${2:--1}" -v lim="$RWND_LIMITED_SHARE" 'BEGIN {exit !(w < lim)}' ;;
    *) return 0 ;;
  esac
}

metric_skip_reason() {
  case "${1:-}" in
    initcwnd) printf '该前缀 %s%% 的发送时间卡在对端接收窗口上，首窗不是瓶颈，加大它不会生效\n' "${2:-?}" ;;
    *) printf '证据不足以证明这个参数会生效\n' ;;
  esac
}

# ── 画像分类 ───────────────────────────────────────────────────────────────

# The classes exist because each one implies a different per-route policy.
# Order matters: the gates come first, because a peer we cannot measure must
# never be filed under a class that would earn it a routing change.
classify_peer() {
  local p50="${1:-0}" jit="${2:-0}" bloat="${3:-1}" tail="${4:-1}" \
        retrans="${5:-0}" spread="${6:-1}" segs="${7:-0}" spikefrac="${8:-0}" \
        spurious="${9:--1}" retrcount="${10:-0}"
  awk -v t="$p50" -v j="$jit" -v b="$bloat" -v tb="$tail" -v r="$retrans" \
      -v sp="$spread" -v sg="$segs" -v spf="$spikefrac" -v floor="$LOCAL_RTT_FLOOR_MS" \
      -v spur="$spurious" -v rc="$retrcount" -v spshare="$SPURIOUS_SHARE" \
      -v minrc="$MIN_RETRANS_FOR_SPURIOUS" \
      -v minpath="$MIN_SEGS_FOR_PATH" -v minseg="$MIN_SEGS_FOR_RETRANS" 'BEGIN {
    if (t < floor)   { print "local";  exit }
    if (sg < minpath) { print "idle";  exit }
    trust_r = (sg >= minseg)
    # Deep queueing is only the whole story when loss is low. With both
    # present, a passive snapshot cannot say which segment of the path owns
    # the queue or the drops, so it gets its own class rather than being
    # filed under one cause and handed the policy text for that cause.
    if (b >= 3 && (!trust_r || r < 1)) { print "bloated"; exit }
    # Before any class that treats the retransmission rate as loss, ask whether
    # those retransmissions were real. If the receiver told us most of them were
    # duplicates, the headline percentage is measuring our own impatience, and
    # every loss class below would be reasoning from a number that is not loss.
    if (trust_r && r >= 0.1 && rc >= minrc && spur >= spshare) { print "spurious"; exit }
    if (trust_r && r >= 1 && b >= 2)   { print "mixed";   exit }
    # Loss with a spread latency tail is evidence of radio scheduling. Flat
    # latency is deliberately not called a rate limiter: this DMIT mobile
    # prefix was flat in consecutive windows while loss moved 3.07% -> 0.51%.
    if (trust_r && r >= 1 && (j >= 0.15 || sp >= 1.4)) { print "mobile"; exit }
    if (trust_r && r >= 1)      { print "flatloss"; exit }
    if (trust_r && r >= 0.1)    { print "lossy"; exit }
    # How often, not how bad: a link that spikes in a tenth of its rounds is a
    # different animal from one that spiked once in a thousand.
    if (tb >= 3 || spf >= 0.1) { print "spiky"; exit }
    if (j >= 0.3 || sp >= 1.4) { print "variable"; exit }
    # Standing queue short of the bloat threshold. It used to fall through to
    # "far", which is the one class that hands out a bigger initial window --
    # exactly the wrong prescription for a path already sitting above its
    # floor. It is not alarming enough to act on either way, so it says so.
    if (b >= 1.5)    { print "queued"; exit }
    # The path shape is trustworthy at MIN_SEGS_FOR_PATH, but calling a prefix
    # a clean fixed line means asserting its loss is low, and that assertion
    # needs the larger denominator. Without it, no initcwnd change.
    if (!trust_r)    { print "unverified"; exit }
    if (t >= 120)    { print "far";    exit }
    print "near";
  }'
}

class_label() {
  case "${1:-}" in
    local)   printf '同机房\n' ;;
    idle)    printf '数据不足\n' ;;
    bloated) printf '接入网排队\n' ;;
    spurious) printf '虚假重传\n' ;;
    mixed)   printf '排队且丢包\n' ;;
    mobile)  printf '移动网络\n' ;;
    flatloss) printf '稳定延迟丢包\n' ;;
    lossy)    printf '轻度丢包\n' ;;
    spiky)   printf '间歇排队\n' ;;
    variable) printf '时变链路\n' ;;
    queued)  printf '轻微排队\n' ;;
    unverified) printf '丢包未证实\n' ;;
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
      printf '%s\n' '' \
        '不改路由参数。initcwnd 只影响新连接的首窗，10 又通常已是 Linux 默认值，治不了长连接中的无线丢包和延迟尾峰。也不要凭随机无线丢包换 cubic；BBR 不会像丢包型算法那样把每次随机丢包都当成持续拥塞'
      ;;
    flatloss)
      printf '%s\n' '' \
        '延迟较稳但重传 ≥1%。被动观测不能区分暂时平稳的移动网、随机路径丢包和 policer；阶段一不降速、不改路由，只有可控主动测速找到重复出现的速率拐点后才能讨论 policer'
      ;;
    lossy)
      printf '%s\n' '' \
        '重传在 0.1%–1% 之间，高于干净线但不足以判断原因。继续累积画像；它不会被当作健康远端固网，也不会获得 initcwnd 32'
      ;;
    bloated)
      printf '%s\n' '' \
        '对端接入网在囤队列。服务器无法直接管理对方队列；若要试降 pacing 或 BBRv3，请在可回滚测试机上做 A/B，阶段一不自动下发'
      ;;
    spurious)
      printf '%s\n' '' \
        '重传的大部分被对端 DSACK 确认是重复包——这条链路没在丢包，是乱序或重传触发得太早。不改路由参数：现代内核默认用 RACK-TLP 按时间判丢包，per-route 的 reordering 基本不再参与这条路径，写上去多半是个 no-op。这一条的价值是诊断——它说明该前缀的重传率高估了真实丢包，别拿那个数字去降速'
      ;;
    mixed)
      printf '%s\n' '' \
        '同时有明显排队（膨胀 ≥2）和 ≥1% 重传。被动观测无法判断队列和丢包出在路径的哪一段，也就无法判断该压首窗还是该压速率；不改任何路由参数，先延长观测'
      ;;
    queued)
      printf '%s\n' '' \
        '路径稳定坐在底噪之上（膨胀 1.5–3），还不到接入网囤队列的程度。不给 initcwnd 32——路径已经有存量队列时加大首窗只会把尖峰推高'
      ;;
    unverified)
      printf '%s\n' '' \
        '延迟形状健康，但窗口内段数不够，重传率还没被证实。要判成干净固网就得先证明它低重传；证明之前不改首窗'
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
  # A pre-0.1.4 database has no sums, only the maxima. Seeding the sums from
  # the max assumes every past round was the worst one — the pessimistic
  # reading, so an upgrade never quietly turns a bad profile into a good one.
  # It decays toward the truth as new rounds land.
  if (NF >= 18 && $16 != "") { p95s[$1] = $16; tls[$1] = $17; spk[$1] = $18 }
  else { p95s[$1] = $5 * $3; tls[$1] = $9 * $3; spk[$1] = ($9 >= spiketail ? $3 : 0) }
  # Pre-0.2.0 rows carry none of the new evidence. Zero is the right seed here
  # (unlike the spike count): these are counters, and "we never observed any"
  # is exactly what the derived ratios should report as unknown.
  if (NF >= 26) {
    dsk[$1] = $19; rdr[$1] = $20; rwl[$1] = $21; sbl[$1] = $22
    bsy[$1] = $23; dsi[$1] = $24; msm[$1] = $25; pmt[$1] = $26
  }
  next
}
{
  if ($13 != "in") next
  k = $1
  if (!(k in n)) { n[k] = 0; trusted[k] = 0; first[k] = stamp }
  n[k]++
  if (($12 + 0) >= minpath) {
    trusted[k]++
    p50s[k] += $4
    p95s[k] += $5
    if ($5 > p95m[k]) p95m[k] = $5
    if (!(k in mins) || $6 < mins[k]) mins[k] = $6
    jits[k] += $7
    # -1 is the "no measurable floor" sentinel from the aggregator, not a
    # ratio. Summed as-is it dragged the tail total of a same-host prefix
    # below zero.
    bls[k]  += ($8 > 0 ? $8 : 0)
    tls[k]  += ($14 > 0 ? $14 : 0)
    if ($14 > tlm[k]) tlm[k] = $14
    if ($14 >= spiketail) spk[k]++
    retrs[k] += $15
    sgs[k] += $12
    dsk[k] += $23; rdr[k] += $17; rwl[k] += $24; sbl[k] += $25
    bsy[k] += $26; dsi[k] += $27
    if (($21 + 0) > 0 && (!(k in msm) || msm[k] == 0 || $21 < msm[k])) msm[k] = $21
    if (($22 + 0) > 0 && (!(k in pmt) || pmt[k] == 0 || $22 < pmt[k])) pmt[k] = $22
    if ($10 > mbm[k]) mbm[k] = $10
    if ($2 > cmx[k]) cmx[k] = $2
  }
  seen[k] = stamp
}
END {
  print "prefix", "obs", "trusted", "p50sum", "p95max", "minrtt", "jitsum", \
        "bloatsum", "tailmax", "retrtotal", "segtotal", "mbpsmax", "connmax", "first", "last", \
        "p95sum", "tailsum", "spikes", \
        "dsacktotal", "reordtotal", "rwndms", "sndbufms", "busyms", "uploadsegs", "mssmin", "pmtumin"
  for (k in n)
    print k, n[k], trusted[k], p50s[k], p95m[k], mins[k], jits[k], bls[k], tlm[k], \
          retrs[k], sgs[k], mbm[k], cmx[k], first[k], (k in seen ? seen[k] : last[k]), \
          p95s[k] + 0, tls[k] + 0, spk[k] + 0, \
          dsk[k] + 0, rdr[k] + 0, rwl[k] + 0, sbl[k] + 0, bsy[k] + 0, dsi[k] + 0, msm[k] + 0, pmt[k] + 0
}
'

merge_profiles() {
  local agg="$1" stamp merged
  stamp="$(date -u +%s 2>/dev/null || printf '0')"
  mkdir -p "$STATE_DIR"
  [[ -e "$PROFILE_DB" ]] || printf 'prefix\n' > "$PROFILE_DB"
  merged="$(mktemp)"
  awk -v db="$PROFILE_DB" -v stamp="$stamp" -v minpath="$MIN_SEGS_FOR_PATH" \
    -v spiketail="$SPIKE_TAIL" "$PROFILE_MERGE_AWK" "$PROFILE_DB" "$agg" > "$merged"
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

  printf '\n  %b前缀                      连接 RTT50 RTT95  最低  抖动  膨胀  尾涨  重传%%   虚假%%    段数  画像%b\n' "$BOLD" "$RESET"
  rule_light
  local prefix conns cc p50 p95 minrtt jit bloat rpct segs dir tail
  local retrc spur rwpct spread class hidden=0 shown=0
  while IFS=$'\t' read -r prefix conns cc p50 p95 minrtt jit bloat rpct _ _ segs dir tail \
      retrc spur _ _ rwpct _ _ _ _ _ _ _ _; do
    if [[ "$dir" == out ]] && (( show_all == 0 )); then hidden=$((hidden + 1)); continue; fi
    shown=$((shown + 1))
    spread="$(row_spread "$p95" "$p50")"
    class="$(classify_peer "$p50" "$jit" "$bloat" "$tail" "$rpct" "$spread" "$segs" 0 "$spur" "$retrc")"
    local color="$GREEN"
    case "$class" in mobile|flatloss|lossy|bloated|mixed|spurious|spiky|variable) color="$YELLOW" ;; esac
    local bt="$bloat" tt="$tail" rt="$rpct" sr="$spur"
    awk -v b="$bloat" 'BEGIN {exit !(b < 0)}' && { bt="—"; tt="—"; }
    (( segs < MIN_SEGS_FOR_RETRANS )) && rt="—"
    awk -v v="${spur:--1}" -v m="${retrc:-0}" -v n="$MIN_RETRANS_FOR_SPURIOUS" \
      'BEGIN {exit !(v < 0 || m < n)}' && sr="—"
    printf '  %b%-24s%b %4s %5s %5s %5s %5s %5s %5s %6s %6s %7s  %s\n' \
      "$color" "$prefix" "$RESET" "$conns" "$p50" "$p95" "$minrtt" "$jit" \
      "$bt" "$tt" "$rt" "$sr" "$segs" "$(class_label "$class")"
    printf '    %b→ %s%b\n' "$DIM" \
      "$(diagnose_peer "$bloat" "$jit" "$rpct" "$p50" "$segs" "$tail" "$spread" "$spur" "$retrc")" "$RESET"
    awk -v w="${rwpct:--1}" -v lim="$RWND_LIMITED_SHARE" 'BEGIN {exit !(w >= lim)}' && \
      printf '    %b  发送时间里有 %s%% 卡在对端接收窗口——瓶颈是对端的窗口，不是路径，也不是首窗%b\n' \
        "$DIM" "$rwpct" "$RESET"
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
  local total_prefixes trusted_inbound
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
      total_prefixes="$(awk 'END { print NR + 0 }' "$agg")"
      trusted_inbound="$(awk -F '\t' -v minpath="$MIN_SEGS_FOR_PATH" \
        '$13 == "in" && ($12 + 0) >= minpath { n++ } END { print n + 0 }' "$agg")"
      merge_profiles "$agg"
      if (( trusted_inbound > 0 )); then kept=$((kept + 1)); fi
      printf '  %b[%s/%s]%b 可信入站 %s 个（本轮共聚合 %s 个前缀）\n' \
        "$DIM" "$n" "$rounds" "$RESET" "$trusted_inbound" "$total_prefixes"
    else
      printf '  %b[%s/%s]%b 窗口内无活跃连接，跳过\n' "$DIM" "$n" "$rounds" "$RESET"
    fi
  done
  if (( kept == 0 )); then
    warn "没有采到达到样本门槛的入站数据；确认客户端在观测期间确实有持续流量"
    return 0
  fi
  log "观测完成，${kept}/${rounds} 轮有可信入站数据。看结果：$PROGRAM profiles"
}

# ── 画像与建议 ─────────────────────────────────────────────────────────────

# Collapses the running totals back into per-prefix averages plus the class.
# shellcheck disable=SC2016 # awk program; shell expansion is intentionally disabled
PROFILE_VIEW_AWK='
BEGIN { FS = OFS = "\t" }
NR == 1 || $1 == "prefix" || $1 == "" { next }
{
  obs = $3 + 0; if (obs < 1) next
  p50 = $4 / obs; p95mx = $5 + 0; mn = $6 + 0
  jit = $7 / obs; bl = $8 / obs; tlmx = $9 + 0
  sg = $11 + 0; rt = (sg > 0) ? ($10 * 100 / sg) : 0
  mb = $12 + 0; cn = $13 + 0
  # Classification runs on the typical round, not the worst one ever seen. A
  # max never decays, so classifying on it meant one freak round pinned a
  # prefix out of its class permanently and more observation could only ever
  # make a profile look worse. The maxima stay, but as displayed evidence.
  p95t = (NF >= 16 && $16 != "") ? $16 / obs : p95mx
  tlt  = (NF >= 17 && $17 != "") ? $17 / obs : tlmx
  # A pre-0.1.4 row has no spike count. That is "unknown", not "zero"; -1 makes
  # the display say so instead of claiming a clean record we never observed.
  spk  = (NF >= 18 && $18 != "") ? $18 + 0 : -1
  sp   = (p50 > 0) ? p95t / p50 : 1
  rc   = $10 + 0
  # -1 throughout means "no denominator", which downstream must not confuse
  # with a measured zero.
  spur = (NF >= 26 && rc > 0) ? $19 * 100 / rc : -1
  rdr  = (NF >= 26) ? $20 + 0 : 0
  bsy  = (NF >= 26) ? $23 + 0 : 0
  rwp  = (bsy > 0) ? $21 * 100 / bsy : -1
  sbp  = (bsy > 0) ? $22 * 100 / bsy : -1
  upt  = (NF >= 26) ? $24 + 0 : 0
  upl  = (sg + upt > 0) ? upt * 100 / (sg + upt) : 0
  mssv = (NF >= 26) ? $25 + 0 : 0
  pmtv = (NF >= 26) ? $26 + 0 : 0
  # p95t is also emitted verbatim: sizing reads it, and reconstructing it from
  # the two-decimal sp ratio loses enough precision to move a buffer figure.
  printf "%s\t%d\t%.1f\t%.1f\t%.1f\t%.3f\t%.2f\t%.2f\t%.4f\t%d\t%.1f\t%d\t%.2f\t%.3f\t%d\t%.1f\t%d\t%.1f\t%.1f\t%.1f\t%d\t%d\t%d\t%.1f\n", \
    $1, obs, p50, p95mx, mn, jit, bl, tlt, rt, sg, mb, cn, sp, (spk >= 0 ? spk / obs : 0), spk, \
    spur, rdr, rwp, sbp, upl, mssv, pmtv, rc, p95t
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
  printf '  %b前缀                      轮次 RTT50 峰95  最低  抖动  膨胀  尾涨   尖峰 重传%%  虚假%%    段数  画像%b\n' "$BOLD" "$RESET"
  rule_light
  local prefix obs p50 p95 mn jit bl tl rt sg sp spf spk spur rwp rc class
  while IFS=$'\t' read -r prefix obs p50 p95 mn jit bl tl rt sg _ _ sp spf spk \
      spur _ rwp _ _ _ _ rc; do
    class="$(classify_peer "$p50" "$jit" "$bl" "$tl" "$rt" "$sp" "$sg" "$spf" "$spur" "$rc")"
    local color="$GREEN"
    case "$class" in mobile|flatloss|lossy|bloated|mixed|spurious|spiky|variable) color="$YELLOW" ;; esac
    local spike="$spk/$obs"; (( spk < 0 )) && spike='—'
    local sr="$spur"
    awk -v v="${spur:--1}" -v m="${rc:-0}" -v n="$MIN_RETRANS_FOR_SPURIOUS" \
      'BEGIN {exit !(v < 0 || m < n)}' && sr="—"
    printf '  %b%-24s%b %4s %5s %5s %5s %5s %5s %5s %6s %5s %6s %7s  %s\n' \
      "$color" "$prefix" "$RESET" "$obs" "$p50" "$p95" "$mn" "$jit" "$bl" "$tl" \
      "$spike" "$rt" "$sr" "$sg" "$(class_label "$class")"
    awk -v w="${rwp:--1}" -v lim="$RWND_LIMITED_SHARE" 'BEGIN {exit !(w >= lim)}' && \
      printf '    %b发送时间 %s%% 卡在对端接收窗口——加大首窗对它无效%b\n' "$DIM" "$rwp" "$RESET"
  done <<< "$rows"
  rule_light
  printf '  %b轮次 = 这个前缀被观测到多少轮；轮次越多画像越可信%b\n' "$DIM" "$RESET"
  printf '  %b峰95 = 所有可信轮次中最高的一轮 RTT95，用来保留卡顿尾峰；不是整段观测的全量 P95%b\n' "$DIM" "$RESET"
  printf '  %b尾涨/抖动/膨胀 = 各轮的平均值；尖峰 = 有多少轮 RTT95 涨到底噪的 %s 倍以上%b\n' "$DIM" "$SPIKE_TAIL" "$RESET"
  printf '  %b膨胀用的是每轮自己的底噪，不是「最低」这一列（那是全程最低），所以它不等于 RTT50÷最低%b\n' "$DIM" "$RESET"
  printf '  %b分类看的是尖峰出现的频率，不是最差那一轮——偶发一次不该把一条链路永久打上标签%b\n' "$DIM" "$RESET"
  printf '  %b虚假%% = 重传里被对端 DSACK 确认是重复包的比例；高说明重传率高估了真实丢包%b\n' "$DIM" "$RESET"
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

  local prefix obs p50 p95 mn jit bl tl rt sg sp spf spk class opts reason commands rc
  local spur rdr rwp sbp upl mss pmtu retrc gated skips bettercc avail curcc
  local emitted=0 few_obs=0 not_actionable=0 route_skipped=0 noop_skipped=0
  avail="$(available_cc)"
  curcc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '')"
  bettercc="$(better_cc "$avail" "$curcc" || true)"
  while IFS=$'\t' read -r prefix obs p50 p95 mn jit bl tl rt sg _ _ sp spf spk \
      spur rdr rwp sbp upl mss pmtu retrc; do
    if (( obs < min_obs )); then few_obs=$((few_obs + 1)); continue; fi
    class="$(classify_peer "$p50" "$jit" "$bl" "$tl" "$rt" "$sp" "$sg" "$spf" "$spur" "$retrc")"
    case "$class" in local|idle) not_actionable=$((not_actionable + 1)); continue ;; esac
    opts="$(class_policy "$class" | sed -n '1p')"
    reason="$(class_policy "$class" | sed -n '2p')"
    # A kernel that actually carries a better congestion control turns
    # per-route congctl from a downgrade into a scoped experiment: roll the new
    # algorithm out to one prefix, leave every other client on the old one.
    case "$class" in
      mobile|bloated|variable|spiky)
        [[ -n "$bettercc" ]] && opts="${opts:+$opts }congctl $bettercc" ;;
    esac
    printf '  %b%s%b  %b%s%b  %s轮观测\n' "$BOLD" "$prefix" "$RESET" \
      "$CYAN" "$(class_label "$class")" "$RESET" "$obs"
    printf '    %bRTT %s ms 中位／最差一轮 %s（底噪 %s）｜抖动 %s｜膨胀 %s｜尖峰 %s/%s 轮｜重传 %s%%（%s 段）%b\n' \
      "$DIM" "$p50" "$p95" "$mn" "$jit" "$bl" "$( (( spk < 0 )) && printf '未知' || printf '%s' "$spk" )" \
      "$obs" "$rt" "$sg" "$RESET"
    awk -v v="${spur:--1}" -v m="${retrc:-0}" -v n="$MIN_RETRANS_FOR_SPURIOUS" \
      'BEGIN {exit !(v >= 0 && m >= n)}' && \
      printf '    %b其中 %s%% 的重传被对端 DSACK 确认是重复包（%s 次重传，乱序事件 %s）%b\n' \
        "$DIM" "$spur" "$retrc" "${rdr:-0}" "$RESET"
    awk -v w="${rwp:--1}" -v lim="$RWND_LIMITED_SHARE" 'BEGIN {exit !(w >= lim)}' && \
      printf '    %b发送时间 %s%% 卡在对端接收窗口，%s%% 卡在本机发送缓冲%b\n' \
        "$DIM" "$rwp" "${sbp:-0}" "$RESET"
    # A negotiated MSS far under what the path MTU allows means something on
    # the way is clamping it — usually a tunnel. Worth knowing before blaming
    # the transport for the throughput.
    awk -v m="${mss:-0}" -v u="${pmtu:-0}" 'BEGIN {exit !(m > 0 && u > 0 && m < u - 80)}' && \
      printf '    %bMSS %s 明显低于 PMTU %s 所允许的大小——路径上有人在钳制 MSS（多半是隧道）%b\n' \
        "$DIM" "$mss" "$pmtu" "$RESET"
    # Every policy here assumes the client is downloading. If it is mostly
    # uploading, that assumption is wrong and the reader should know.
    awk -v u="${upl:-0}" 'BEGIN {exit !(u >= 40)}' && \
      printf '    %b该前缀 %s%% 的段是上行——本工具的策略都是按下载场景推的，对它未必适用%b\n' \
        "$DIM" "$upl" "$RESET"
    # Drop any metric that cannot be shown to bind, and say why.
    gated="$(gate_metrics "$opts" "${rwp:--1}")"
    skips="$(printf '%s\n' "$gated" | sed -n '2,$p')"
    local had_opts="$opts"
    opts="$(printf '%s\n' "$gated" | sed -n '1p')"
    # If the gate emptied the list, the class reason below would still be
    # arguing for a parameter we just refused to emit. Say what actually
    # happened instead of printing both halves of a contradiction.
    if [[ -n "$had_opts" && -z "$opts" ]]; then
      reason="这个画像本身适用 ${had_opts%% *}，但该前缀的实测证据表明它不会生效，所以不出命令"
    fi
    if [[ -n "$skips" ]]; then
      while IFS=$'\t' read -r _ why; do
        [[ -n "$why" ]] || continue
        noop_skipped=$((noop_skipped + 1))
        printf '    %b（跳过：%s）%b\n' "$YELLOW" "$why" "$RESET"
      done <<< "$skips"
    fi
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
  (( noop_skipped > 0 )) && printf '；%s 个参数因证明不了会生效而被丢弃' "$noop_skipped"
  printf '\n'
  if [[ -z "$bettercc" ]]; then
    printf '  %b内核只提供 %s，没有比当前 %s 更适合移动链路的算法，所以不会给任何前缀建议 congctl。%b\n' \
      "$DIM" "${avail:-未知}" "${curcc:-未知}" "$RESET"
    printf '  %b换成带 BBRv3 的内核之后，这里会开始建议只给移动网段灰度，而不必整机切换。%b\n' "$DIM" "$RESET"
  fi
}

# ── 体检 ───────────────────────────────────────────────────────────────────

# Per-route congestion control landed in Linux 4.0 (RTAX_CC_ALGO), but only
# iproute2 knows whether the local `ip` can express it.
supports_congctl() {
  local help
  has ip || return 1
  # `ip route help` commonly prints valid help and exits non-zero. With the
  # script-wide pipefail setting, piping it directly into grep reports a false
  # negative even when the word is present.
  help="$(ip route help 2>&1 || true)"
  grep -q 'congctl' <<< "$help"
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

# ── 全局层：按观测到的客户端群体定尺寸 ─────────────────────────────────────

# Everything above this line is per-prefix. But the three things actually asked
# for — low retransmission, fast ramp, no mid-stream collapse — are dominated by
# machine-wide settings, and the reason a single global setting normally fails a
# mixed population is that it gets sized for one client. routetune has measured
# the population, so it can size for the real spread instead of guessing.

# Cheapest correct answer for "how far away is the farthest client": the worst
# typical round of the worst prefix, not the worst round ever seen anywhere.
#
# tcpfit deleted its RTT probe entirely and hardcoded 150ms, arguing the cost is
# asymmetric: overestimating costs a little BBR overshoot, underestimating puts
# a silent hard ceiling on every distant client. That argument is right, and its
# floor is kept here — but tcpfit had to guess because it could not see the
# clients. This can see them, so it takes the larger of the two.
COVER_RTT_FLOOR_MS=150
# A VPS that cannot be shown to be slower is assumed to be at least this fast,
# for the same asymmetry: sizing buffers off an idle sample is how a link ends
# up capped at a number the operator can never explain.
PEAK_MBPS_FLOOR=200
BUF_MIN_BYTES=$((8 * 1024 * 1024))
BUF_ABS_MAX_BYTES=$((512 * 1024 * 1024))

total_ram_bytes() {
  local kb
  kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf '')"
  if ! is_uint "${kb:-}" || (( kb == 0 )); then printf '0\n'; return 0; fi
  printf '%s\n' $(( kb * 1024 ))
}

# The largest bandwidth-delay product any single observed prefix actually
# reaches, and which prefix reaches it. Prints
# "bdpbytes<TAB>rtt<TAB>mbps<TAB>prefix<TAB>prefixcount"; zeros when the
# database has nothing to say.
#
# It has to be per prefix. Taking the widest RTT across all prefixes and the
# highest rate across all prefixes and multiplying them describes an operating
# point that does not exist: high-RTT links are the slow ones. A single
# sampling window taken on a train produced 975ms from a link doing 9 Mbps,
# and pairing that RTT with an unrelated rate sized the machine at 46 MB.
observed_envelope() {
  local rows
  rows="$(profile_rows 2>/dev/null || true)"
  [[ -n "$rows" ]] || { printf '0\t0\t0\t\t0\n'; return 0; }
  awk -F '\t' '
    { n++
      p95 = $24 + 0             # mean p95 of this prefix, not its worst round
      rate = $11 + 0
      bdp = p95 * 125 * rate    # Mbps x ms in bytes
      if (bdp > best) { best = bdp; brtt = p95; brate = rate; bpfx = $1 } }
    END { printf "%.0f\t%.0f\t%.0f\t%s\t%d\n", best + 0, brtt + 0, brate + 0, bpfx, n + 0 }
  ' <<< "$rows"
}

# The sysctl set, with the measurement each value came from. Emits
# key<TAB>value<TAB>why. Nothing here is applied by this function.
# Prints "bdp<TAB>source" where source is 'observed' or 'headroom'.
sizing_bdp() {
  local force_rtt="${1:-}" force_peak="${2:-}"
  local env obs_bdp rtt peak _pfx _n head_bdp
  env="$(observed_envelope)"
  IFS=$'\t' read -r obs_bdp rtt peak _pfx _n <<< "$env"
  # An operator stating an envelope outright is making a decision, not a
  # measurement, so it replaces both terms rather than competing with them.
  if [[ -n "$force_rtt" || -n "$force_peak" ]]; then
    [[ -n "$force_rtt" ]]  || force_rtt="$COVER_RTT_FLOOR_MS"
    [[ -n "$force_peak" ]] || force_peak="$PEAK_MBPS_FLOOR"
    printf '%s\tforced\n' $(( force_peak * 125 * force_rtt ))
    return 0
  fi
  # Headroom for clients we have never seen. The floors belong here and only
  # here: applied to the measurement they would inflate a slow link's RTT by a
  # rate that link never reaches.
  head_bdp=$(( PEAK_MBPS_FLOOR * 125 * COVER_RTT_FLOOR_MS ))
  if (( obs_bdp > head_bdp )); then printf '%s\tobserved\n' "$obs_bdp"
  else printf '%s\theadroom\n' "$head_bdp"; fi
}

derive_tuning() {
  local force_rtt="${1:-}" force_peak="${2:-}"
  local ram bdp buf cc qdisc avail rmem_default
  IFS=$'\t' read -r bdp _ <<< "$(sizing_bdp "$force_rtt" "$force_peak")"
  ram="$(total_ram_bytes)"
  # Doubled: with tcp_adv_win_scale=1 the kernel reserves half the receive
  # buffer for overhead, so a ceiling equal to the BDP delivers half of one.
  buf=$(( bdp * 2 ))
  (( buf < BUF_MIN_BYTES )) && buf="$BUF_MIN_BYTES"
  (( buf > BUF_ABS_MAX_BYTES )) && buf="$BUF_ABS_MAX_BYTES"
  # A ceiling is per socket. Leaving it unbounded relative to RAM is how a small
  # box gets OOM-killed by its own tuning.
  if (( ram > 0 )) && (( buf > ram / 16 )); then
    buf=$(( ram / 16 ))
    (( buf < BUF_MIN_BYTES )) && buf="$BUF_MIN_BYTES"
  fi
  rmem_default=131072
  avail="$(available_cc)"
  case " $avail " in
    *" bbr3 "*) cc=bbr3 ;;
    *" bbr2 "*) cc=bbr2 ;;
    *" bbr "*)  cc=bbr ;;
    *) cc=cubic ;;
  esac
  qdisc=fq
  # Column 4 is the direction in which a difference is worth acting on.
  #   exact  the value itself is the point
  #   raise  only ever increase it. A ceiling that is larger than needed costs
  #          almost nothing because autotuning stops well below it, while one
  #          that is too small is a cap nobody can diagnose. That is tcpfit's
  #          asymmetry argument, and it forbids shrinking just as much as it
  #          forbids underestimating.
  #   lower  only ever decrease it. An operator who already tightened a knob
  #          must not have it quietly loosened.
  printf 'net.core.default_qdisc\t%s\t%s\texact\n' "$qdisc" \
    '发送侧 pacing。混合客户端下降低重传的最大单一杠杆：没有 pacing 时一个突发按线速打出去，会直接冲垮最慢那条末端链路的缓冲'
  printf 'net.ipv4.tcp_congestion_control\t%s\t%s\texact\n' "$cc" \
    '爬升快且不会因随机丢包塌陷——丢包型算法每丢一次砍一次窗，无线链路上永远起不来'
  printf 'net.core.rmem_max\t%s\t%s\traise\n' "$buf" \
    '接收缓冲上限。上限只是上限，autotuning 会让近端连接自己停在低处；给小了才是查不出来的硬天花板'
  printf 'net.core.wmem_max\t%s\t%s\traise\n' "$buf" '发送缓冲上限，同上'
  printf 'net.ipv4.tcp_rmem\t4096 %s %s\t%s\traise\n' "$rmem_default" "$buf" \
    '第三个数是上限（同上）；中间那个是初始接收窗口，抬高它让发送方在等窗口更新前多发一些——这一项影响的是爬升速度，不是天花板'
  printf 'net.ipv4.tcp_wmem\t4096 16384 %s\t%s\traise\n' "$buf" '发送侧上限，同上'
  printf 'net.ipv4.tcp_slow_start_after_idle\t0\t%s\texact\n' \
    '流媒体分块之间会短暂空闲，默认行为是把 cwnd 打回初始值再慢启动一次——这正是「看着看着掉速」的机制'
  printf 'net.ipv4.tcp_notsent_lowat\t131072\t%s\tlower\n' \
    '限制本机 socket 里堆积的未发送数据，降低本地排队延迟；已经调得更紧就保持不动'
  printf 'net.ipv4.tcp_mtu_probing\t1\t%s\texact\n' \
    '路径上有人钳制 MSS 时（scan 会提示）让内核自己探到能用的大小，而不是一直重传大包'
}

# The value actually safe to write, given the direction this key may move in.
# Multi-value keys (tcp_rmem, tcp_wmem) merge field by field: their fields are
# min/default/max and do not share a direction in practice. tcp_rmem wants its
# middle field raised for a faster ramp while its ceiling is already higher
# than we would ask for, and writing the whole tuple naively would raise one
# and shrink the other in the same call.
safe_target() {
  local now="${1:-}" want="${2:-}" dir="${3:-exact}"
  if [[ -z "$now" || "$dir" == exact ]]; then printf '%s\n' "$want"; return 0; fi
  awk -v a="$now" -v b="$want" -v d="$dir" 'BEGIN {
    na = split(a, x, " "); nb = split(b, y, " ")
    if (na != nb) { print b; exit }
    out = ""
    for (i = 1; i <= nb; i++) {
      v = (d == "raise") ? (y[i] + 0 > x[i] + 0 ? y[i] : x[i]) \
                         : (y[i] + 0 < x[i] + 0 ? y[i] : x[i])
      out = (out == "") ? v : out " " v
    }
    print out }'
}

# Changing anything is worth doing only when the safe target differs from what
# is live.
needs_change() {
  local now="${1:-}" want="${2:-}" dir="${3:-exact}"
  [[ -n "$now" ]] || return 0            # unset always needs setting
  [[ "$(safe_target "$now" "$want" "$dir")" != "$now" ]]
}

# When a key is left alone, say which way the live value already went.
already_ok_note() {
  case "${1:-}" in
    raise) printf '当前值已经不低于目标，不动（上限只升不降）
' ;;
    lower) printf '当前值已经比目标更紧，不动（这一项只降不升）
' ;;
    *)     printf '已经是目标值
' ;;
  esac
}

# What the machine currently has, for the same keys.
current_sysctl() {
  local k
  while IFS=$'\t' read -r k _ _; do
    printf '%s\t%s\n' "$k" "$(sysctl -n "$k" 2>/dev/null | tr -s ' \t' ' ' || printf '')"
  done
}

SYSCTL_SNAPSHOT="$STATE_DIR/sysctl-before.tsv"

# netshape drives the same knobs plus the root qdisc. Two tools writing one
# machine-wide setting is not a merge, it is whichever ran last.
netshape_present() {
  [[ -x /usr/local/bin/netshape || -e /etc/netshape.conf ]] \
    || systemctl list-unit-files 2>/dev/null | grep -q '^netshape'
}

cmd_tune() {
  local apply=0 force_rtt='' force_peak=''
  while (( $# )); do
    case "$1" in
      --yes) apply=1; shift ;;
      --cover-rtt) [[ $# -ge 2 ]] || die "--cover-rtt 缺少值"; force_rtt="$2"; shift 2 ;;
      --peak-mbps) [[ $# -ge 2 ]] || die "--peak-mbps 缺少值"; force_peak="$2"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ -z "$force_rtt" ]] || is_uint "$force_rtt" || die "--cover-rtt 需为正整数"
  [[ -z "$force_peak" ]] || is_uint "$force_peak" || die "--peak-mbps 需为正整数"
  has sysctl || die "缺少 sysctl"

  panel_title 'routetune 全局调优'
  local obs_bdp rtt peak pfx nprefix sz_bdp sz_src
  IFS=$'\t' read -r obs_bdp rtt peak pfx nprefix <<< "$(observed_envelope)"
  IFS=$'\t' read -r sz_bdp sz_src <<< "$(sizing_bdp "$force_rtt" "$force_peak")"
  if (( nprefix == 0 )); then
    warn "画像库是空的，下面的尺寸完全来自保守默认值，不是你机器上的实测"
    printf '  %b先跑 %s watch --minutes 30，让尺寸按你真实的客户端分布来算。%b\n\n' \
      "$DIM" "$PROGRAM" "$RESET"
  else
    printf '  %b依据 %s 个前缀的实测。BDP 最大的是 %s：它自己的 %s ms × %s Mbps = %s MB%b\n' \
      "$DIM" "$nprefix" "${pfx:-未知}" "$rtt" "$peak" \
      "$(awk -v b="$obs_bdp" 'BEGIN {printf "%.2f", b / 1048576}')" "$RESET"
    printf '  %bRTT 和速率必须取自同一个前缀——最慢的链路正是最远的那条，把两个轴各自的最大值相乘，得到的是一个不存在的工作点%b\n' \
      "$DIM" "$RESET"
    local sz_mb; sz_mb="$(awk -v b="$sz_bdp" 'BEGIN {printf "%.2f", b / 1048576}')"
    case "$sz_src" in
      headroom) printf '  %b实测 BDP 不到未观测客户端的兜底值（%s ms × %s Mbps = %s MB），按兜底算%b\n' \
        "$DIM" "$COVER_RTT_FLOOR_MS" "$PEAK_MBPS_FLOOR" "$sz_mb" "$RESET" ;;
      forced)   printf '  %b你指定了覆盖范围（BDP %s MB），实测值不参与%b\n' "$DIM" "$sz_mb" "$RESET" ;;
      *)        printf '  %b尺寸来自实测的 %s MB，不是兜底值%b\n' "$DIM" "$sz_mb" "$RESET" ;;
    esac
  fi
  if netshape_present; then
    warn "检测到 netshape：它和 routetune 都会写全局 sysctl 和根队列，同一台机器只能留一个"
    printf '  %b两者不是叠加关系，是谁后跑谁生效。先卸载 netshape 再 --yes。%b\n' "$DIM" "$RESET"
  fi
  printf '\n'

  local derived cur k v why dir now changed=0
  derived="$(derive_tuning "$force_rtt" "$force_peak")"
  cur="$(printf '%s\n' "$derived" | current_sysctl)"
  printf '  %b参数                                  当前值 → 目标值%b\n' "$BOLD" "$RESET"
  rule_light
  while IFS=$'\t' read -r k v why dir; do
    [[ -n "$k" ]] || continue
    now="$(awk -F'\t' -v key="$k" '$1 == key {print $2; exit}' <<< "$cur")"
    if needs_change "$now" "$v" "$dir"; then
      changed=$((changed + 1))
      printf '  %b%-36s%b %b%s%b → %b%s%b\n' "$BOLD" "$k" "$RESET" \
        "$DIM" "${now:-未设置}" "$RESET" "$GREEN" "$(safe_target "$now" "$v" "$dir")" "$RESET"
      printf '    %b%s%b\n' "$DIM" "$why" "$RESET"
    else
      printf '  %b%-36s %-24s %s%b\n' "$DIM" "$k" "$now" "$(already_ok_note "$dir")" "$RESET"
    fi
  done <<< "$derived"
  rule_light

  if (( changed == 0 )); then
    log "现有配置已经覆盖你实测的客户端分布，不需要 routetune 接管"
    printf '  %b这台机器上没有可加的东西。routetune 在这里的价值是 scan / watch / profiles%b\n' "$DIM" "$RESET"
    printf '  %b——客户端分布是 netshape 看不到、而它能看到的部分。%b\n' "$DIM" "$RESET"
    return 0
  fi

  if (( apply == 0 )); then
    printf '  %b这是预演，什么都没有改。%b\n' "$BOLD" "$RESET"
    printf '  %b%s 项值得改。确认无误后加 --yes 才会真的写入。%b\n' "$DIM" "$changed" "$RESET"
    printf '  %b写入前会先快照当前值，%s revert 可以完整还原。%b\n' "$DIM" "$PROGRAM" "$RESET"
    return 0
  fi

  need_root tune --yes
  mkdir -p "$STATE_DIR"
  # Snapshot before the first write only: re-running tune must not overwrite the
  # record of what the machine looked like before routetune ever touched it.
  if [[ ! -e "$SYSCTL_SNAPSHOT" ]]; then
    printf '%s\n' "$cur" > "$SYSCTL_SNAPSHOT"
    chmod 0600 "$SYSCTL_SNAPSHOT"
    log "已快照原始值到 $SYSCTL_SNAPSHOT"
  else
    info "已存在快照，保留最初那份（revert 要还原到 routetune 介入之前）"
  fi
  local failed=0
  while IFS=$'\t' read -r k v _ dir; do
    [[ -n "$k" ]] || continue
    now="$(awk -F'\t' -v key="$k" '$1 == key {print $2; exit}' <<< "$cur")"
    needs_change "$now" "$v" "$dir" || continue
    v="$(safe_target "$now" "$v" "$dir")"
    if sysctl -qw "$k=$v" 2>/dev/null; then
      printf '  %b[OK]%b %s = %s\n' "$GREEN" "$RESET" "$k" "$v"
    else
      failed=$((failed + 1))
      printf '  %b[跳过]%b %s —— 这个内核不接受该键\n' "$YELLOW" "$RESET" "$k"
    fi
  done <<< "$derived"
  # default_qdisc only affects interfaces brought up afterwards.
  local iface
  iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  if [[ -n "$iface" ]] && has tc; then
    if tc qdisc replace dev "$iface" root fq 2>/dev/null; then
      log "已把 $iface 的根队列换成 fq（default_qdisc 只对之后启动的接口生效，所以这里直接换）"
    else
      warn "无法在 $iface 上设置 fq，pacing 不会生效——这是低重传最重要的一项"
    fi
  fi
  if (( failed == 0 )); then
    log "全局调优已生效。还原：$PROGRAM revert"
  else
    warn "$failed 项未生效，其余已生效。还原：$PROGRAM revert"
  fi
}

cmd_revert() {
  need_root revert
  [[ -r "$SYSCTL_SNAPSHOT" ]] || die "没有快照可还原（没跑过 $PROGRAM tune --yes）"
  panel_title 'routetune 还原'
  local k v n=0
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] || continue
    if [[ -z "$v" ]]; then
      printf '  %b[跳过]%b %s 原本就没有值\n' "$DIM" "$RESET" "$k"
      continue
    fi
    if sysctl -qw "$k=$v" 2>/dev/null; then
      n=$((n + 1)); printf '  %b[还原]%b %s = %s\n' "$GREEN" "$RESET" "$k" "$v"
    else
      printf '  %b[失败]%b %s\n' "$RED" "$RESET" "$k"
    fi
  done < "$SYSCTL_SNAPSHOT"
  rm -f "$SYSCTL_SNAPSHOT"
  log "已还原 $n 项到 routetune 介入之前的值，并删除快照"
  printf '  %b根队列没有自动还原——它原本是什么由发行版决定；用 tc qdisc replace dev <网卡> root <原值> 手动改回。%b\n' \
    "$DIM" "$RESET"
}

cmd_status() {
  panel_title 'routetune 状态'
  local derived cur k v now drift=0 applied=0
  derived="$(derive_tuning)"
  cur="$(printf '%s\n' "$derived" | current_sysctl)"
  if [[ -e "$SYSCTL_SNAPSHOT" ]]; then
    applied=1
    printf '  全局调优:          %b已应用%b（快照在 %s）\n' "$GREEN" "$RESET" "$SYSCTL_SNAPSHOT"
  else
    printf '  全局调优:          %b未应用%b（%s tune 看预演）\n' "$YELLOW" "$RESET" "$PROGRAM"
  fi
  local iface qdisc
  iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  if [[ -n "$iface" ]] && has tc; then
    qdisc="$(tc qdisc show dev "$iface" 2>/dev/null | awk '$1 == "qdisc" {print $2; exit}')"
    if [[ "$qdisc" == fq ]]; then
      printf '  %s 根队列:      %bfq%b（pacing 生效）\n' "$iface" "$GREEN" "$RESET"
    else
      printf '  %s 根队列:      %b%s%b —— 不是 fq，发送侧没有 pacing\n' \
        "$iface" "$YELLOW" "${qdisc:-未知}" "$RESET"
    fi
  fi
  printf '\n  %b当前值与目标值的差异%b\n' "$BOLD" "$RESET"
  rule_light
  while IFS=$'\t' read -r k v _ dir; do
    [[ -n "$k" ]] || continue
    now="$(awk -F'\t' -v key="$k" '$1 == key {print $2; exit}' <<< "$cur")"
    if needs_change "$now" "$v" "$dir"; then
      drift=$((drift + 1))
      printf '  %b✗ %-36s%b %s（目标 %s）\n' "$YELLOW" "$k" "$RESET" "${now:-未设置}" \
        "$(safe_target "$now" "$v" "$dir")"
    else
      printf '  %b✓ %-36s %s%b\n' "$GREEN" "$k" "${now:-$v}" "$RESET"
    fi
  done <<< "$derived"
  rule_light
  if (( drift == 0 )); then
    log "全部与目标一致"
  elif (( applied == 1 )); then
    warn "$drift 项已偏离目标——可能是重启后失效（tune 不持久化），重跑 $PROGRAM tune --yes"
  else
    printf '  %b%s 项与目标不同。%s tune 看逐项理由。%b\n' "$DIM" "$drift" "$PROGRAM" "$RESET"
  fi
  printf '\n'
  if [[ -r "$PROFILE_DB" ]]; then
    local n; n="$(profile_rows 2>/dev/null | grep -c "" || printf '0')"
    printf '  画像库:            %s 个前缀\n' "$n"
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

  观测
  routetune scan                    看当前一轮的分布
  routetune scan --group ip         按 IP 而不是前缀聚合
  routetune scan --all              连本机出站对端一起看
  routetune watch --minutes 30      持续观测并累积画像
  routetune profiles                看已累积的画像

  调优
  routetune tune                    按观测到的客户端群体算全局参数（预演，不写）
  routetune tune --yes              真的写入，写前自动快照
  routetune tune --cover-rtt 250    手动指定覆盖 RTT，不用实测值
  routetune status                  当前生效情况与目标值的差异
  routetune revert                  还原到 routetune 介入之前

  per-route
  routetune recommend               输出 per-route 策略命令（不执行）
  routetune recommend --min-obs 5   只对观测够 5 轮的前缀出建议

  其他
  routetune doctor                  内核能力、BBR 判定与全机 DSACK 旁证
  routetune reset                   清空画像库

全局层为什么能兼顾多地区：单一 sysctl 之所以在混合客户端上失效，是因为它总是按
「某一个客户端」定的尺寸。routetune 观测过整个群体，所以缓冲上限按**最远那个客户端**
算——上限只是上限，autotuning 会让近端连接自己停在低处，给大几乎不亏；给小才是查不
出来的硬天花板（这条论证来自 tcpfit，它因为看不到客户端只能硬编码 150ms，这里取实测
与 150ms 的较大者）。

三个目标各自靠什么：
  低重传     fq pacing——没有 pacing 时突发按线速打出去，冲垮最慢那条末端链路
  爬升快     缓冲上限给足 + BBR + slow_start_after_idle=0 + 干净远端路径的 initcwnd
  不掉速     BBR 不因随机丢包塌陷；不设会绑死的单流限速；分块间不重置 cwnd

画像分类与对应策略：

  远端固网   RTT ≥120ms、无排队、已证实低重传 → A/B 测试 initcwnd 32
  虚假重传   多数重传被对端 DSACK 确认是重复包 → 没在丢包；别按重传率降速
  近端固网   RTT <120ms 且稳定      → 默认即可，加大起步只会制造突发
  轻微排队   膨胀 1.5-3、无明显丢包  → 已有存量队列，不加大首窗
  丢包未证实 延迟形状够看、段数不够   → 没证实低重传就不算干净固网
  移动网络   丢包 + 延迟尾部散开     → 不改首窗；长连接问题不靠 initcwnd 修
  排队且丢包 膨胀 ≥2 且重传 ≥1%      → 分不清队列和丢包在哪一段，什么都不改
  稳定延迟丢包 重传 ≥1%、延迟较稳    → 不推断限速器；主动复测前不改参数
  轻度丢包   重传 0.1%-1%           → 继续观测，不当作健康固网优化
  接入网排队 中位膨胀 ≥3 且丢包低     → 服务端限速无效，根治靠 BBRv3
  间歇排队   尾峰反复出现（≥10% 轮次） → 先观察；偶发一次不算
  时变链路   抖动或尾部散布高、无明确丢包 → 延长观测，不凭快照改参数

只有「远端固网」会输出命令。任何一项证据不成立——有存量队列、有丢包、或段数不够
证实低重传——都会落到别的类，拿不到 initcwnd 32。

而且每个参数还要单独过一道「它会不会真的生效」的闸门：证明不了就丢掉，并说明原因。
例如某前缀的发送时间大量卡在对端接收窗口上时，首窗就不是瓶颈，initcwnd 不会下发。
congctl 同理——只有内核里真的存在比当前更合适的算法（bbr2/bbr3）时才会提议，
在只有 reno/cubic/bbr 的内核上不会建议你降级到 cubic。

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
    tune) shift; cmd_tune "$@" ;;
    status) cmd_status ;;
    revert) cmd_revert ;;
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
