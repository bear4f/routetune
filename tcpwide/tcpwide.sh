#!/usr/bin/env bash
# tcpwide - one TCP configuration for a client population that is spread out.
#
# The tools this grew out of size the machine for one client. netshape asks the
# operator for "your latency to this box" and derives a buffer ceiling from it,
# which is right when every client looks like the operator and becomes a silent
# hard cap for everyone further away. tcpfit deleted its RTT probe entirely and
# hardcoded 150ms, on the argument that the error is asymmetric: overestimating
# costs a little congestion-control overshoot, underestimating is a ceiling
# nobody can diagnose. That argument is correct and it is the foundation here.
#
# The conclusion tcpwide draws from it is that a spread-out population does not
# need per-client policy. It needs one configuration sized for the FARTHEST
# client, built out of mechanisms that adapt to the rest on their own:
#
#   pacing        so a burst never leaves at line rate into a slow last mile
#   BBR           so random radio loss is not mistaken for congestion
#   AQM           so the queue that does form is managed instead of tail-dropped
#   host fairness so one device with 40 connections cannot starve one with 1
#
# What it deliberately does NOT do is cap per-flow rates. A cap tuned for a
# fixed line strangles it and never even binds for a mobile client, because the
# mobile client was never going that fast to begin with.
#
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION="0.17.0"
PROGRAM="tcpwide"
STATE_DIR="/var/lib/tcpwide"
SYSCTL_SNAP="$STATE_DIR/sysctl.snapshot"
QDISC_SNAP="$STATE_DIR/qdisc.snapshot"
MEASURE_LOG="$STATE_DIR/measurements"
ROUTE_SNAP="$STATE_DIR/route.snapshot"
PERSIST_SYSCTL="/etc/sysctl.d/90-tcpwide.conf"
PERSIST_UNIT="/etc/systemd/system/tcpwide-link.service"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
if [[ ! -t 1 || "${NO_COLOR:-}" ]]; then
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' DIM='' BOLD='' RESET=''
fi
RULE='──────────────────────────────────────────────────────────────────────'
HEAVY='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

title() {
  printf '\n%b%s%b\n' "$CYAN" "$HEAVY" "$RESET"
  printf '%b  %s%b  %bv%s%b\n' "$BOLD" "$1" "$RESET" "$DIM" "$VERSION" "$RESET"
  printf '%b%s%b\n' "$CYAN" "$HEAVY" "$RESET"
}
rule() { printf '%b%s%b\n' "$DIM" "$RULE" "$RESET"; }
log()  { printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"; }
info() { printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }
is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]]; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 运行：sudo $PROGRAM $*"; }

# ── 参数与默认值 ───────────────────────────────────────────────────────────

# Every distant client pays for an underestimate here, and nobody can see why,
# so the floor is deliberately generous. Intercontinental paths run 150-280ms;
# a mobile client on a moving vehicle is worse still.
COVER_RTT_MS=250
# Below this, a "farthest client" measurement is describing the datacentre, not
# the client population, and must not be turned into a coverage figure.
LOCAL_RTT_SAMPLE_MS=20

# A connection has to be carrying real traffic before anything about buffers can
# be read off it. Both samplers filtered on RTT alone, so on two machines they
# picked the operator's own SSH session -- 5.6 Mbps at 139ms from a phone -- and
# reported "rcvbuf 0.1 MB / rmem_max 86.8 MB = 0%, autotuning never grew". An
# idle shell has no reason to grow a buffer. The verdict was confident, specific
# and about nothing, which is worse than declining to answer.
SAMPLE_MBPS_FLOOR=50
# Shaping below the provider's own limit is the point: their policer drops
# bursts, a local AQM queues and marks them. Giving up a slice of peak buys
# that, and buys the fairness that only exists when the queue is ours.
SHAPE_PCT=95
# Linux ships 10. With pacing in front of it a larger opening burst is spread
# over an RTT instead of being dumped, so it buys ramp without buying loss.
INITCWND=20
BUF_FLOOR=$((8 * 1024 * 1024))
BUF_CAP=$((256 * 1024 * 1024))
# 2xBDP with no slack measurably underperforms. tcpfit A/B'd this on a real
# 300Mbps/168ms link: 11.25MB averaged 257.3 Mbps, the same buffer plus 2MiB
# averaged 272.7 Mbps, both at zero retransmission. A fixed margin recovers
# that without scaling up the buffers of faster machines proportionally.
BUF_SLACK=$((2 * 1024 * 1024))

# How many BDPs of rmem_max a flow needs to reach line rate.
#
# 0.16.0 moved this to 4 on the strength of two machines whose in-flight bytes
# both worked out to about a quarter of their rmem_max. A direct experiment on
# one machine then falsified it: doubling rmem_max from 43.4 to 86.8 MB left
# nine backends where they were, median in flight 11.41 -> 11.40 MB. If in
# flight really tracked rmem_max/4 it would have doubled.
#
# A correlation across two boxes was not causation, and the kernel story I
# offered for it did not survive either -- that box runs 6.1, before the release
# that replaced tcp_adv_win_scale with a measured scaling_ratio, so
# tcp_adv_win_scale=1 does mean half the buffer there.
#
# Back to 2, which is what tcp_adv_win_scale=1 actually promises. Nothing is
# lost: 86.8 MB and 43.4 MB measured identically. Under 2 those same readings
# sit at 26% (BWG) and 44-50% (DMIT) of the advertised window with 0.00%
# retransmission, so neither machine is receive-window limited and 0.15.0's
# original reading was right all along.
BDP_MULTIPLIER=2

EGRESS_MBPS=""
IFACE=""
SHAPE=1
# Persist by default. Without it every reboot silently reverts the machine to
# stock, and the next speedtest measures something nobody configured.
PERSIST=1
ASSUME_YES=0
# 0 means "leave whatever is there alone".
#
# The mechanism: at 400 Mbps a 16KB allowance is 0.33ms of data, so a userspace
# proxy has to finish a whole wake/read/decrypt/write cycle inside it or the
# pipe runs dry. netshape sets 16384 whenever RTT >= 120ms, which is right for
# seek latency and backwards for throughput.
#
# Measured on the live node with a bracketed A/B/A, which is the only structure
# that reads anything on a path this unstable — the two 16384 runs 14 minutes
# apart differed by 21% on average and 31% at the peak all by themselves.
# Interpolating between them for the moment the 131072 run happened:
#
#   16384 (interpolated)   avg 217.3   peak 298.1
#   131072 (measured)      avg 257.4   peak 330.0     +18.4% / +10.7%
#
# One B sample and a two-point trend is weak evidence, but it points the way the
# mechanism predicts and matches the usual server guidance of 128KB, so it is
# the default rather than a claim. Set it to 0 to keep the system value.
NOTSENT_LOWAT=131072

# Which layout the pacer takes when not shaping.
#
# `root`      one `fq` on the interface root. One write, one failure mode, and
#             every packet is paced. This is the layout that was measured.
# `mq-leaves` keep the driver's `mq` root and hang an `fq` on each leaf, so the
#             hardware TX queues keep their own locks. Better in theory for
#             aggregate throughput, and N separate writes instead of one: any
#             leaf that misses falls back to the kernel default and is paced by
#             nothing at all.
#
# 0.10.0 shipped `mq-leaves` as the default on reasoning alone, and three
# backends lost 42-47% together. Reasoning does not get to set defaults here;
# measurement does. It stays available so it can be A/B'd, not deleted.
QDISC_LAYOUT=root

# How many parallel streams a `record` reading came from. 1 unless told
# otherwise, because a single-thread reading is the common case and the one
# that keeps getting misread as a server problem.
RECORD_THREADS=1

# The RTT a `record` reading was taken at. 0 means not supplied, which costs the
# reading its place in the window analysis -- rate alone cannot tell a distant
# backend from a throttled one.
RECORD_RTT=0

# fq's queue limits. 0 means "leave the kernel's value alone"; anything else is
# written into the qdisc spec.
#
# fq_queue_limits() supplies the default, taken from netshape-manager, whose
# author reports it saturating a port on a single thread. It sets
# limit 10240 / flow_limit 2048 below 1 GB of RAM and 40960 / 8192 above,
# against kernel defaults of 10000 and 100.
#
# flow_limit is the interesting one, and the reason it is a default rather than
# a knob: it is a PER-FLOW packet quota. N flows each get their own 100, so the
# kernel default cannot hold back an aggregate transfer while it can hold back
# a single one. That is the exact shape of the measurement here -- 558 Mbps on
# one thread, 917 on several, on the same backend seconds apart.
#
# Whether 100 really binds is not established: fq counts skbs, and with GSO one
# skb can carry 64KB, so 100 of them is a lot of bytes. It is adopted because
# it comes from a configuration reported to saturate, not because the mechanism
# is proven -- and it stays overridable so it can be A/B'd back out.
FQ_INITIAL_QUANTUM=0
FQ_LIMIT=0
FQ_FLOW_LIMIT=0

# The ingress backlog, on netshape's memory ladder.
netdev_backlog() {
  local ram; ram="$(total_ram_bytes)"
  if (( ram > 0 && ram < 1024 * 1024 * 1024 )); then printf '4096\n'
  else printf '16384\n'; fi
}

# netshape's ladder. Returns "limit flow_limit".
fq_queue_limits() {
  local ram; ram="$(total_ram_bytes)"
  if (( ram > 0 && ram < 1024 * 1024 * 1024 )); then printf '10240 2048\n'
  else printf '40960 8192\n'; fi
}
# 0 means "derive it". An explicit value in MB overrides the whole derivation.
#
# netshape's RAM ladder exists because oversized buffers let BBR hold a huge
# cwnd on a policed link. But netshape pairs that ladder with fq maxrate, and
# once per-flow pacing is in place the overshoot is bounded by the pacing rate
# rather than by the window — so the ladder may now be costing receive window
# it no longer needs to protect.
#
# It matters because the ladder is derived from RAM alone and ignores RTT.
# 16 MB with tcp_adv_win_scale=1 advertises an 8 MB receive window, which caps
# an incoming transfer at 419 Mbps on a 160ms path and 298 on a 225ms one. The
# live node measured 421 and 234. This knob is here to settle whether that is
# the binding constraint, one variable at a time.
BUF_MB=0

total_ram_bytes() {
  local kb
  kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf '')"
  if ! is_uint "${kb:-}" || (( kb == 0 )); then printf '0\n'; return 0; fi
  printf '%s\n' $(( kb * 1024 ))
}

default_iface() {
  ip route show default 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}

available_cc() { sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true; }

# BBRv3 has never been in mainline. A stock kernel offering only "bbr" is
# offering v1, and no amount of poking at modinfo distinguishes them, so the
# name is all there is to go on.
pick_cc() {
  local avail=" ${1:-} "
  case "$avail" in
    *" bbr3 "*) printf 'bbr3\n'; return 0 ;;
    *" bbr2 "*) printf 'bbr2\n'; return 0 ;;
    *" bbr "*)  printf 'bbr\n';  return 0 ;;
  esac
  printf 'cubic\n'
}

# BBRv3 has never been in mainline, so a stock kernel offering only "bbr" is
# offering v1. But XanMod ships v3 UNDER THE NAME bbr, replacing the mainline
# one — so the algorithm name alone cannot tell them apart, and no amount of
# poking at modinfo helps either: the module carries no version field. The
# kernel's provenance is the only available answer.
bbr_variant() {
  local avail=" ${1:-} " release="${2:-}"
  [[ -n "$release" ]] || release="$(uname -r 2>/dev/null || printf '')"
  case "$avail" in
    *" bbr3 "*) printf 'v3\n'; return 0 ;;
    *" bbr2 "*) printf 'v2\n'; return 0 ;;
    *" bbr "*)  ;;
    *) printf 'none\n'; return 0 ;;
  esac
  case "$release" in
    *xanmod*|*XanMod*|*XANMOD*) printf 'nonstock\n' ;;
    *) printf 'v1\n' ;;
  esac
}

bbr_variant_note() {
  case "${1:-}" in
    v3) printf '%s\n' '显式的 bbr3 —— 会响应丢包和 ECN，ProbeRTT 也温和得多' ;;
    v2) printf '%s\n' '显式的 bbr2' ;;
    v1) printf '%s\n' 'BBRv1（主线内核只有 v1）—— 带宽估计是约 10 个 RTT 的最大值滤波，链路变差后会抱着旧估值继续超发' ;;
    nonstock) printf '%s\n' '非主线内核，算法名仍是 bbr —— XanMod 就是把 v3 装成这个名字，光看名字分不出版本，查该内核的构建说明' ;;
    *) printf '%s\n' '内核没有提供 BBR' ;;
  esac
}

have_cake() {
  has tc || return 1
  tc qdisc add dev lo root cake 2>/dev/null || return 1
  tc qdisc del dev lo root 2>/dev/null || true
  return 0
}

# When the full spec is refused, the useful question is WHICH option was
# refused: a kernel can carry sch_cake while the local tc does not know a
# keyword, and the reverse happens too. Build the spec up one option at a time
# and name the point where it starts failing. Loopback is used because it is the
# one interface where a momentary qdisc cannot disturb real traffic.
probe_cake_options() {
  local spec="${1:-}" acc=() w
  has tc || return 1
  split_words "$spec"
  for w in "${SPLIT_WORDS[@]}"; do
    acc+=("$w")
    # Options that take a value are only testable once the value is in.
    case "$w" in bandwidth|rtt) continue ;; esac
    if ! tc qdisc replace dev lo root "${acc[@]}" >/dev/null 2>&1; then
      tc qdisc del dev lo root >/dev/null 2>&1 || true
      # ${acc[*]} joins on the first character of IFS, which is a newline here.
      local IFS=' '
      printf '%s\n' "${acc[*]}"
      return 0
    fi
  done
  tc qdisc del dev lo root >/dev/null 2>&1 || true
  return 1
}

# Mbps x ms in bytes: rate * 1e6 / 8 * rtt / 1000 reduces exactly to
# rate * 125 * rtt, with no intermediate integer division.
bdp_bytes() { printf '%s\n' $(( ${1:-0} * 125 * ${2:-0} )); }

# tcp_adv_win_scale=1 hands the application half of the receive buffer, so a
# ceiling equal to the BDP delivers half a BDP. The clamps exist because a
# ceiling is per socket: unbounded tuning is how a small box dies of its own
# configuration.
# The global page budget for all of TCP. rmem_max is only a ceiling; this is the
# hard cap the kernel enforces, and past the pressure threshold it shrinks every
# socket regardless of what the ceiling says. Raising it is safe in a way that
# raising a per-socket ceiling is not, because it is the thing doing the
# catching. Formula follows tcpfit: 1/16, 1/8, 1/4 of RAM in pages.
target_tcp_mem() {
  local need="${1:-0}" ram page budget
  ram="$(total_ram_bytes)"
  (( ram > 0 )) || return 1
  page="$(getconf PAGESIZE 2>/dev/null || printf 4096)"
  budget="$(tcp_mem_budget_bytes "$ram" "$need")"
  awk -v b="$budget" -v pg="$page" 'BEGIN {
    max = int(b / pg); low = int(max / 4); pres = int(max / 2)
    if (low  < 4096)  low  = 4096
    if (pres < 8192)  pres = 8192
    if (max  < 16384) max  = 16384
    printf "%d %d %d", low, pres, max }'
}

# How much one socket may take of the global TCP budget: a quarter of it, so
# four large flows still fit before the kernel starts shrinking anyone.
#
# 0.16.0 halved this divisor -- lifting the per-socket ceiling from RAM/12 to
# RAM/6 -- purely to make room for the 4x multiplier above. That multiplier is
# withdrawn, so the reason for the wider ceiling is gone with it, and on the box
# it was meant to help the extra headroom measured exactly the same. Handing one
# connection half the budget on a 520 MB box was a real cost for no gain.
#
# The operator did choose RAM/6 when asked, but chose it from an analysis that
# turned out to be wrong; the honest thing is to put it back and say so. Both
# this and BDP_MULTIPLIER stay knobs.
socket_budget_cap() {
  local ram="${1:-0}" need="${2:-0}" budget
  (( ram > 0 )) || { printf '0\n'; return 0; }
  budget="$(tcp_mem_budget_bytes "$ram" "$need")"
  printf '%s\n' $(( budget / 4 ))
}

# The global TCP page budget in bytes. At least a quarter of RAM, grown toward a
# third when four sockets at the required ceiling would not otherwise fit.
# A third is the ceiling on the ceiling: past that a proxy box is handing too
# much of itself to socket buffers.
tcp_mem_budget_bytes() {
  local ram="${1:-0}" need="${2:-0}" budget
  (( ram > 0 )) || { printf '0\n'; return 0; }
  budget=$(( ram / 4 ))
  # Four sockets at the required ceiling, matching socket_budget_cap's divisor.
  if (( need > 0 )) && (( need * 4 > budget )); then budget=$(( need * 4 )); fi
  (( budget > ram / 3 )) && budget=$(( ram / 3 ))
  printf '%s\n' "$budget"
}

buffer_ceiling() {
  local rate="${1:-0}" rtt="${2:-0}" ram buf cap
  # An explicit figure skips both the derivation and the ladder: the point of
  # the override is to test the ladder, so the ladder must not clamp it back.
  if is_uint "$BUF_MB" && (( BUF_MB > 0 )); then
    printf '%s\n' $(( BUF_MB * 1024 * 1024 )); return 0
  fi
  buf=$(( $(bdp_bytes "$rate" "$rtt") * BDP_MULTIPLIER + BUF_SLACK ))
  (( buf > BUF_CAP )) && buf="$BUF_CAP"
  ram="$(total_ram_bytes)"
  # One socket may take at most an eighth of the global TCP budget, so at least
  # eight large flows can run at the ceiling before anyone hits pressure. Since
  # the budget's own cap is a quarter of RAM, that works out to RAM/32. Clamping
  # against RAM directly, as this used to, let a single connection monopolise
  # the budget on a small box.
  if (( ram > 0 )); then
    cap="$(socket_budget_cap "$ram" "$buf")"
    (( buf > cap )) && buf="$cap"
  fi
  (( buf < BUF_FLOOR )) && buf="$BUF_FLOOR"
  printf '%s\n' "$buf"
}

shaped_kbit() { printf '%s\n' $(( ${1:-0} * 1000 * SHAPE_PCT / 100 )); }

# ── 目标配置 ───────────────────────────────────────────────────────────────

# Emits key<TAB>value<TAB>direction<TAB>why.
#   exact  the value is the point
#   raise  only ever increase. A ceiling above what is needed costs almost
#          nothing because autotuning settles well below it; one below it is a
#          cap nobody can diagnose. Same asymmetry as the floor, so it also
#          forbids shrinking whatever the operator already set higher.
#   lower  only ever decrease, so a knob someone already tightened stays tight.
target_sysctl() {
  local rate="${1:-0}" rtt="${2:-0}" buf cc
  buf="$(buffer_ceiling "$rate" "$rtt")"
  cc="$(pick_cc "$(available_cc)")"
  printf 'net.ipv4.tcp_congestion_control\t%s\texact\t%s\n' "$cc" \
    '丢包型算法每丢一次砍一次窗，无线链路上永远起不来；BBR 不把随机丢包当拥塞信号'
  # BBR needs a pacer. The root qdisc is set explicitly, but any queue the
  # kernel creates on its own -- an mq leaf, a new interface, a queue count
  # change -- takes this instead, and the stock value paces nothing. A queue
  # without pacing sends cwnd-sized bursts at line rate for the next policer to
  # drop, which is precisely the failure the mq layout could produce.
  printf 'net.core.default_qdisc\tfq\texact\t%s\n' \
    'BBR 必须配 pacing；内核自己新建的队列走这个默认值，装好的默认值不做 pacing'
  printf 'net.core.rmem_max\t%s\traise\t%s\n' "$buf" \
    "接收缓冲上限，按覆盖 RTT ${rtt}ms × ${rate}Mbps 的 BDP 两倍算"
  printf 'net.core.wmem_max\t%s\traise\t%s\n' "$buf" '发送缓冲上限，同上'
  printf 'net.ipv4.tcp_rmem\t4096 131072 %s\traise\t%s\n' "$buf" \
    '第三个是上限；中间那个是初始接收窗口，抬高它让对端在等窗口更新前多发一些'
  printf 'net.ipv4.tcp_wmem\t4096 65536 %s\traise\t%s\n' "$buf" '发送侧同上'
  printf 'net.ipv4.tcp_slow_start_after_idle\t0\texact\t%s\n' \
    '默认会在连接短暂空闲后把 cwnd 打回初始值重新慢启动，而流媒体分块之间正好是这种空闲——这是「看着看着掉速」的一个真实机制'
  printf 'net.ipv4.tcp_no_metrics_save\t1\texact\t%s\n' \
    '默认会把每个目标的 ssthresh 缓存下来。5G 波动时缓存到一个很低的值，下一条连接会带着这个悲观值起步、提前退出慢启动——这是波动链路「爬不起来」的直接原因'
  # A socket that has not been told otherwise starts here. TCP takes its
  # initial sizes from tcp_rmem/tcp_wmem instead, but anything that calls
  # setsockopt without a size, and every non-TCP socket, lands on these.
  printf 'net.core.rmem_default\t262144\traise\t%s\n' '默认接收缓冲，没显式设置的 socket 从这里起步'
  printf 'net.core.wmem_default\t262144\traise\t%s\n' '默认发送缓冲，同上'
  printf 'net.core.optmem_max\t4194304\traise\t%s\n' '辅助缓冲上限，高并发下不够会直接分配失败'
  # F-RTO and Fast Open join ECN in the cross-border blackhole family: all
  # three are negotiated behaviours that middleboxes on these paths mishandle.
  # tcpwide already took tcp_ecn=0 from netshape for exactly this reason.
  printf 'net.ipv4.tcp_frto\t0\texact\t%s\n' 'F-RTO 依赖中间设备如实转发，跨境链路上不成立'
  printf 'net.ipv4.tcp_fastopen\t0\texact\t%s\n' 'TFO 在跨境中间设备上会被黑洞，握手直接卡住'
  printf 'net.ipv4.tcp_mtu_probing\t1\texact\t%s\n' \
    '路径上有人钳制 MSS 时让内核探到能用的大小，而不是反复重传大包'
  # Everything above assumes the application gets half of a receive buffer.
  # If the kernel is set to 2 it gets a quarter, and every ceiling here is
  # wrong by a factor of two — so state it rather than assume it.
  printf 'net.ipv4.tcp_adv_win_scale\t1\texact\t%s\n' \
    '决定接收缓冲里有多少真正给应用当窗口用。上面所有上限都是按「一半」算的，这里必须是 1，否则那些数全部差一倍'
  printf 'net.ipv4.tcp_moderate_rcvbuf\t1\texact\t%s\n' \
    '接收缓冲自动伸缩。关掉的话上限就是摆设——连接永远停在默认值，涨不上去'
  local tcpmem
  if tcpmem="$(target_tcp_mem "$(( $(bdp_bytes "$rate" "$rtt") * BDP_MULTIPLIER + BUF_SLACK ))")"; then
    printf 'net.ipv4.tcp_mem\t%s\traise\t%s\n' "$tcpmem" \
      '全局 TCP 页预算（所有 socket 共享）。rmem_max 只是天花板，这个才是内核硬拦的总量——它太小的话，上限调多大都没用，几条大流一上来就触发压力被缩回去'
  fi
  # Only emitted when the operator has chosen a value. See NOTSENT_LOWAT above
  # for why this is not decided here.
  if is_uint "$NOTSENT_LOWAT" && (( NOTSENT_LOWAT > 0 )); then
    printf 'net.ipv4.tcp_notsent_lowat\t%s\texact\t%s\n' "$NOTSENT_LOWAT" \
      '未发送数据上限。400Mbps 下 16KB 只够 0.33ms，代理进程稍慢一下管道就空了。岳阳 201ms 上直接对照：131072 峰值 568，16384 只有 341，低 40%；而 131072 这一档 13 分钟内两次测得 580/568，稳定可复现。netshape 在高 RTT 上用 16384，在这条路径上被证伪。要极致低延迟可以调小，填 0 保持系统现值'
  fi
  printf 'net.core.netdev_max_backlog\t%s\traise\t%s\n' "$(netdev_backlog)" \
    '网卡收包队列。高 pps 时太小会在进入协议栈之前就丢包，看起来像上游丢包'
  # netshape turns ECN off on purpose, and its reason is specific and
  # field-earned: cross-border middleboxes blackhole ECN negotiation. That is
  # better evidence than the theory that passive mode is inherently safe, and
  # these are exactly cross-border paths. CAKE drops instead of marking, which
  # is still far gentler than the provider policer it replaces.
  printf 'net.ipv4.tcp_ecn\t0\texact\t%s\n' \
    '跨境中间盒会 blackhole ECN 协商（netshape 的实战结论）。关掉后 CAKE 改用丢包发信号，仍然比运营商那个 policer 温和得多'
}

# CAKE's AQM targets a round-trip time, and its default assumes 100ms. Pointing
# it at the population's coverage RTT is the whole multi-region adaptation: at
# the default a 250ms client gets marked long before its queue is actually
# standing, and reads that as congestion it does not have.
target_qdisc() {
  local rate="${1:-0}" rtt="${2:-0}"
  # fq maxrate paces every FLOW at the line rate. Without it a single BBR flow
  # with a large window probes far past the link, and whatever sits downstream —
  # the provider's policer, or our own shaper — drops the overshoot. BBRv1 does
  # not read those drops as congestion, so it keeps producing them. netshape
  # puts exactly this under its shaper; tcpwide had no equivalent, and shaping
  # the aggregate is not a substitute for pacing the individual flow.
  local perflow; perflow=$(( rate * SHAPE_PCT / 100 ))
  (( perflow > 0 )) || perflow="$rate"
  if (( SHAPE == 0 )); then
    local extra='' lim flim
    # The script runs under IFS=$'\n\t', so a bare `read` keeps both numbers in
    # the first variable. This is the fifth time that has bitten this file.
    IFS=' ' read -r lim flim <<< "$(fq_queue_limits)"
    is_uint "$FQ_LIMIT"      && (( FQ_LIMIT > 0 ))      && lim="$FQ_LIMIT"
    is_uint "$FQ_FLOW_LIMIT" && (( FQ_FLOW_LIMIT > 0 )) && flim="$FQ_FLOW_LIMIT"
    extra=" limit $lim flow_limit $flim"
    is_uint "$FQ_INITIAL_QUANTUM" && (( FQ_INITIAL_QUANTUM > 0 )) \
      && extra="$extra initial_quantum $FQ_INITIAL_QUANTUM"
    printf 'fq maxrate %smbit%s\n' "$perflow" "$extra"
    return 0
  fi
  # No `ecn` keyword: mainline sch_cake already marks ECN-capable packets
  # instead of dropping them, so there is nothing to switch on, and the option
  # does not exist in current iproute2 — the live node rejected the whole spec
  # over it with "What is \"ecn\"?". It was moot here anyway, since tcp_ecn is
  # set to 0 for the cross-border blackhole reason.
  # `split-gso` is CAKE's dominant per-packet cost: it breaks a 64KB GSO
  # superpacket into ~44 MTU-sized packets so it can pace each one. Turning it
  # off keeps the superpackets whole and drops the packet rate by more than an
  # order of magnitude, at the price of coarser pacing. On a box whose cores
  # cannot shape the port that is the difference between shaping being
  # affordable and shaping costing half the throughput -- and it is the only way
  # this machine gets per-host fairness AND speed.
  local gso=''
  if cake_over_budget "$rate"; then gso=' no-split-gso'; fi
  printf 'cake bandwidth %skbit dual-dsthost besteffort rtt %sms%s\n' \
    "$(shaped_kbit "$rate")" "$rtt" "$gso"
}

# The script runs under IFS=$'\n\t'. Every place that hands a multi-word spec
# to `tc` or `ip` therefore CANNOT rely on unquoted word splitting: the whole
# spec arrives as a single argument and the command fails. Splitting has to be
# asked for explicitly, so it goes through one helper rather than being
# rediscovered at each call site.
split_words() {
  local IFS=' '
  # shellcheck disable=SC2206 # splitting on spaces is the entire purpose
  SPLIT_WORDS=( $1 )
}
declare -a SPLIT_WORDS=()

current_default_route() { ip route show default 2>/dev/null | sed -n '1p'; }

# Refuse anything we cannot put back exactly. A default route is the one object
# on this box where a wrong edit costs the session.
route_is_simple() {
  local line="${1:-}"
  [[ -n "$line" ]] || return 1
  case " $line " in
    *" nhid "*|*" nexthop "*) return 1 ;;
  esac
  [[ "$(ip route show default 2>/dev/null | grep -c '')" == 1 ]]
}

route_with_initcwnd() {
  local line="${1:-}" cwnd="${2:-$INITCWND}"
  line="$(sed -E 's/ initcwnd [0-9]+//g; s/ initrwnd [0-9]+//g' <<< "$line")"
  # `ip route show` emits a trailing space on some route types (onlink is one),
  # so appending naively produced "... onlink  initcwnd 20". iproute2 accepts it
  # but the panel has to display it, and a snapshot has to compare against it.
  line="$(awk '{$1 = $1; print}' <<< "$line")"
  # initrwnd as well as initcwnd, following netshape. A relay is not only a
  # sender: it pulls from an upstream backend and forwards, and the initial
  # RECEIVE window governs how fast that upstream leg ramps. Setting only
  # initcwnd left half of every connection starting from the kernel default.
  printf '%s initcwnd %s initrwnd %s\n' "$line" "$cwnd" "$cwnd"
}

# ── 配置持久化 ─────────────────────────────────────────────────────────────

CONFIG_FILE="/etc/tcpwide.conf"
CLI_PATH="/usr/local/bin/tcpwide"
INSTALL_PATH="/usr/local/lib/tcpwide/tcpwide.sh"
SOURCE_URL="https://raw.githubusercontent.com/bear4f/routetune/main/tcpwide/tcpwide.sh"

# Where to copy the installed script from. Run as `bash <(curl ...)`,
# BASH_SOURCE points at a pipe under /dev/fd — bash is still reading it, so
# copying it is a race that yields a truncated file. Piped into bash it is empty
# altogether. Both cases fetch a real copy instead.
self_source() {
  local src="${BASH_SOURCE[0]:-}" tmp
  if [[ -n "$src" && -f "$src" && -r "$src" ]]; then printf '%s\n' "$src"; return 0; fi
  has curl || has wget || return 1
  tmp="$(mktemp)" || return 1
  if has curl; then curl -fsSL "$SOURCE_URL" -o "$tmp" 2>/dev/null
  else wget -qO "$tmp" "$SOURCE_URL" 2>/dev/null; fi || { rm -f "$tmp"; return 1; }
  # A failed fetch that still writes something must not be installed.
  grep -q '^PROGRAM="tcpwide"' "$tmp" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$tmp"
}
PROFILE=balanced

# Profiles move three numbers and nothing else. A preset that quietly swapped in
# a different mechanism would make the panel a liar about what is running.
apply_profile() {
  case "${1:-balanced}" in
    stable)   SHAPE_PCT=90; INITCWND=16; SHAPE=1; PROFILE=stable ;;
    balanced) SHAPE_PCT=95; INITCWND=20; SHAPE=1; PROFILE=balanced ;;
    speed)    SHAPE_PCT=98; INITCWND=32; SHAPE=1; PROFILE=speed ;;
    # Sets the percentage too, even though it does no aggregate shaping: it
    # still drives the per-flow fq maxrate, and leaving whatever the previous
    # profile set made "不整形" mean different things depending on history.
    noshape)  SHAPE_PCT=98; INITCWND=20; SHAPE=0; PROFILE=noshape ;;
    *) return 1 ;;
  esac
  return 0
}

profile_label() {
  case "${1:-}" in
    stable)   printf '整形 90%%\n' ;;
    balanced) printf '整形 95%%\n' ;;
    # Was "速度优先". It is the slowest option on a CPU-limited box, and a
    # label that promises speed while delivering half of it is worse than no
    # label. Names describe the shaping tightness; only measurement talks speed.
    speed)    printf '整形 98%%\n' ;;
    noshape)  printf '不整形\n' ;;
    *)        printf '自定义\n' ;;
  esac
}

load_config() {
  [[ -r "$CONFIG_FILE" ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      EGRESS_MBPS)  is_uint "$value" && (( value > 0 )) && EGRESS_MBPS="$value" ;;
      COVER_RTT_MS) is_uint "$value" && (( value >= 10 && value <= 2000 )) && COVER_RTT_MS="$value" ;;
      INITCWND)     is_uint "$value" && (( value >= 1 && value <= 64 )) && INITCWND="$value" ;;
      SHAPE_PCT)    is_uint "$value" && (( value >= 50 && value <= 100 )) && SHAPE_PCT="$value" ;;
      SHAPE)        [[ "$value" =~ ^[01]$ ]] && SHAPE="$value" ;;
      PERSIST)      [[ "$value" =~ ^[01]$ ]] && PERSIST="$value" ;;
      NOTSENT_LOWAT) is_uint "$value" && (( value <= 16777216 )) && NOTSENT_LOWAT="$value" ;;
      BUF_MB)       is_uint "$value" && (( value <= 512 )) && BUF_MB="$value" ;;
      PROFILE)      [[ "$value" =~ ^(stable|balanced|speed|noshape|custom)$ ]] && PROFILE="$value" ;;
      QDISC_LAYOUT) [[ "$value" =~ ^(root|mq-leaves)$ ]] && QDISC_LAYOUT="$value" ;;
      FQ_INITIAL_QUANTUM) is_uint "$value" && (( value <= 1048576 )) && FQ_INITIAL_QUANTUM="$value" ;;
      FQ_FLOW_LIMIT) is_uint "$value" && (( value <= 100000 )) && FQ_FLOW_LIMIT="$value" ;;
      FQ_LIMIT)      is_uint "$value" && (( value <= 1000000 )) && FQ_LIMIT="$value" ;;
      IFACE)        [[ "$value" =~ ^[a-zA-Z0-9_.:-]+$ ]] && IFACE="$value" ;;
    esac
  done < "$CONFIG_FILE"
  # A rejected value on the final line leaves the loop with a non-zero status,
  # which under errexit would take the whole script down instead of just
  # ignoring that one key.
  return 0
}

save_config() {
  local tmp
  mkdir -p "$(dirname "$CONFIG_FILE")"
  tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
  chmod 0644 "$tmp"
  {
    printf '# tcpwide persistent configuration\n'
    printf 'EGRESS_MBPS=%s\n'  "$EGRESS_MBPS"
    printf 'COVER_RTT_MS=%s\n' "$COVER_RTT_MS"
    printf 'INITCWND=%s\n'     "$INITCWND"
    printf 'SHAPE_PCT=%s\n'    "$SHAPE_PCT"
    printf 'SHAPE=%s\n'        "$SHAPE"
    printf 'PERSIST=%s\n'      "$PERSIST"
    printf 'NOTSENT_LOWAT=%s\n' "$NOTSENT_LOWAT"
    printf 'BUF_MB=%s\n'        "$BUF_MB"
    printf 'PROFILE=%s\n'      "$PROFILE"
    printf 'QDISC_LAYOUT=%s\n' "$QDISC_LAYOUT"
    printf 'FQ_INITIAL_QUANTUM=%s\n' "$FQ_INITIAL_QUANTUM"
    printf 'FQ_FLOW_LIMIT=%s\n' "$FQ_FLOW_LIMIT"
    printf 'FQ_LIMIT=%s\n' "$FQ_LIMIT"
    printf 'IFACE=%s\n'        "$IFACE"
  } > "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

# ── 当前状态 ───────────────────────────────────────────────────────────────

live_value() { sysctl -n "${1:-}" 2>/dev/null | tr -s ' \t' ' ' || printf ''; }

# The value it is safe to write, given the direction this key may move in.
# Multi-value keys merge field by field: tcp_rmem is min/default/max and those
# do not share a direction. Its middle field wants raising for a faster start
# while its ceiling may already be higher than we would ask for, and writing
# the tuple whole would raise one and shrink the other in the same call.
safe_value() {
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

needs_write() {
  local now="${1:-}" want="${2:-}" dir="${3:-exact}"
  [[ -n "$now" ]] || return 0
  [[ "$(safe_value "$now" "$want" "$dir")" != "$now" ]]
}

skip_note() {
  case "${1:-}" in
    raise) printf '当前值已经不低于目标，不动\n' ;;
    lower) printf '当前值已经比目标更紧，不动\n' ;;
    *)     printf '已经是目标值\n' ;;
  esac
}

conflicting_tool() {
  [[ -x /usr/local/bin/netshape || -e /etc/netshape.conf ]] && { printf 'netshape\n'; return 0; }
  [[ -x /usr/local/bin/routetune ]] && { printf 'routetune\n'; return 0; }
  return 1
}

resolve_iface() {
  [[ -n "$IFACE" ]] || IFACE="$(default_iface)"
  [[ -n "$IFACE" ]] || die "找不到默认出口网卡，用 --iface 指定"
}

require_egress() {
  if [[ -z "$EGRESS_MBPS" ]]; then
    die "需要 --egress <Mbps>：主机公平和 AQM 只有在瓶颈队列在本机时才生效，
       而这要求整形到运营商限速以下，所以必须知道你的出口带宽。
       不想整形就加 --no-shape（放弃按设备公平和 AQM，保留 pacing/BBR/缓冲尺寸）。"
  fi
  if ! is_uint "$EGRESS_MBPS" || (( EGRESS_MBPS == 0 )); then die "--egress 需为正整数 Mbps"; fi
}

# ── 报告 ───────────────────────────────────────────────────────────────────

# Shared by plan and apply so the preview cannot drift from what runs.
render_plan() {
  local rate="$1" rtt="$2" k v dir why now changes=0
  printf '  %b参数                                  当前 → 目标%b\n' "$BOLD" "$RESET"
  rule
  while IFS=$'\t' read -r k v dir why; do
    [[ -n "$k" ]] || continue
    now="$(live_value "$k")"
    if needs_write "$now" "$v" "$dir"; then
      changes=$((changes + 1))
      printf '  %b%-36s%b %b%s%b → %b%s%b\n' "$BOLD" "$k" "$RESET" \
        "$DIM" "${now:-未设置}" "$RESET" "$GREEN" "$(safe_value "$now" "$v" "$dir")" "$RESET"
      printf '    %b%s%b\n' "$DIM" "$why" "$RESET"
    else
      printf '  %b%-36s %-22s %s%b\n' "$DIM" "$k" "$now" "$(skip_note "$dir")" "$RESET"
    fi
  done < <(target_sysctl "$rate" "$rtt")
  rule
  printf '%s\n' "$changes" > "$STATE_DIR/.plancount" 2>/dev/null || true
  return 0
}

report_link() {
  local rate="$1" rtt="$2" want_q cur_q cur_r want_r
  want_q="$(target_qdisc "$rate" "$rtt")"
  cur_q="$(tc qdisc show dev "$IFACE" 2>/dev/null | sed -n '1p' | sed 's/^qdisc //')"
  printf '\n  %b链路层（%s）%b\n' "$BOLD" "$IFACE" "$RESET"
  rule
  printf '  %b根队列%b\n    当前：%s\n    目标：%s\n' "$BOLD" "$RESET" "${cur_q:-未知}" "$want_q"
  if (( SHAPE == 1 )); then
    printf '    %b整形到 %s%% = %s kbit。运营商的 policer 是丢包式的，你自己的 CAKE 是排队+标记式的%b\n' \
      "$DIM" "$SHAPE_PCT" "$(shaped_kbit "$rate")" "$RESET"
    printf '    %bdual-dsthost = 按客户端 IP 公平，不是按连接数——一台开 40 条连接的设备不会挤掉只开 1 条的那台%b\n' \
      "$DIM" "$RESET"
    printf '    %brtt %sms = CAKE 的 AQM 目标。它默认按 100ms 算，对 250ms 的客户端会过早标记%b\n' \
      "$DIM" "$rtt" "$RESET"
  else
    printf '    %b--no-shape：只做 pacing，不接管排队。放弃按设备公平和 AQM%b\n' "$DIM" "$RESET"
  fi
  cur_r="$(current_default_route)"
  want_r="$(route_with_initcwnd "$cur_r" "$INITCWND")"
  printf '\n  %b默认路由首窗%b\n' "$BOLD" "$RESET"
  if ! route_is_simple "$cur_r"; then
    printf '    %b（默认路由是 ECMP/多路径或不止一条，不动它——错改默认路由的代价是断连）%b\n' \
      "$YELLOW" "$RESET"
  elif [[ "$cur_r" == "$want_r" ]]; then
    printf '    %b已经是 initcwnd %s%b\n' "$DIM" "$INITCWND" "$RESET"
  else
    printf '    当前：%s\n    目标：%s\n' "$cur_r" "$want_r"
    printf '    %b首窗从内核默认的 10 抬到 %s。前面有 pacing，这一发会被摊到一个 RTT 上而不是直接灌出去%b\n' \
      "$DIM" "$INITCWND" "$RESET"
  fi
}

# ── 面板动态项 ─────────────────────────────────────────────────────────────

# What the root qdisc should be versus what it is. Config drifting away from
# reality is the normal state of a box that rebooted or that another tool
# touched, and a panel that cannot see the difference will confidently report a
# configuration that is not running.
# Counts leaves of the mq root carrying the given kind, and succeeds only when
# EVERY transmit queue has one. Accepting any non-zero count let a machine with
# one paced queue out of four report itself as consistent -- the same partial
# state apply_fq_leaves used to create, made invisible to the drift check that
# should have caught it.
mq_leaves_with() {
  local kind="${1:-}" handle n want
  handle="$(mq_root_handle)"
  [[ -n "$handle" ]] || return 1
  want="$(tx_queue_count)"
  is_uint "$want" && (( want > 0 )) || return 1
  n="$(tc qdisc show dev "$IFACE" 2>/dev/null |
    awk -v k="$kind" -v h="$handle" \
      '$1 == "qdisc" && $2 == k && $4 == "parent" && index($5, h) == 1 {n++}
       END {print n + 0}')"
  is_uint "$n" && (( n == want )) || return 1
  printf '%s\n' "$n"
}

qdisc_drift() {
  local want live
  want="$(target_qdisc "${EGRESS_MBPS:-200}" "$COVER_RTT_MS" | awk '{print $1}')"
  live="$(tc qdisc show dev "$IFACE" 2>/dev/null | sed -n '1p' | awk '{print $2}')"
  [[ -n "$live" ]] || return 1
  # An mq root carrying the pacer on its leaves is the intended layout, not
  # drift. Reporting it as drift would send the operator to press "apply" over
  # and over on a configuration that is already correct.
  if [[ "$live" == mq ]] && (( SHAPE == 0 )) && mq_leaves_with "$want" >/dev/null; then
    return 1
  fi
  [[ "$live" != "$want" ]] || return 1
  printf '%s\n' "$live"
}

# Fewer segments than this in the window and the ratio is noise: at 20 segments
# a single retransmission reads as 5%. Roughly a second of a real transfer.
RETRANS_MIN_SEGS=2000

# Retransmissions over a sampling window, not since boot. On a machine that has
# been up for weeks the lifetime average is a number that cannot move and
# therefore cannot tell you whether a change helped.
retrans_rate() {
  local secs="${1:-5}" a b out ra rb sa sb
  has nstat || return 1
  out="$(nstat -asz 2>/dev/null)" || return 1
  ra="$(awk '$1 == "TcpRetransSegs" {print $2; exit}' <<< "$out")"
  sa="$(awk '$1 == "TcpOutSegs" {print $2; exit}' <<< "$out")"
  sleep "$secs"
  out="$(nstat -asz 2>/dev/null)" || return 1
  rb="$(awk '$1 == "TcpRetransSegs" {print $2; exit}' <<< "$out")"
  sb="$(awk '$1 == "TcpOutSegs" {print $2; exit}' <<< "$out")"
  is_uint "${ra:-}" && is_uint "${rb:-}" && is_uint "${sa:-}" && is_uint "${sb:-}" || return 1
  a=$(( rb - ra )); b=$(( sb - sa ))
  # An idle box sends a handful of segments in five seconds, and one
  # retransmission out of fifty reads as a flat 2.0000% -- a suspiciously round
  # number that is noise, not a loss rate. Below a floor there is nothing to
  # report, so say so rather than print a figure that invites a wrong fix.
  (( b >= RETRANS_MIN_SEGS )) || return 2
  awk -v r="$a" -v s="$b" 'BEGIN {printf "%.4f\n", r * 100 / s}'
}

# A single flow through a userspace proxy is handled by essentially one core:
# one reader, one crypto path, one writer. So a box can be half idle in
# aggregate and still be at its per-flow ceiling, and the aggregate figure that
# `top` shows first is the one that hides it. Only the busiest core answers the
# question.
#
# steal is reported separately because on a small VPS it is a common and
# completely external cap: time the hypervisor gave to somebody else is
# throughput this machine cannot buy back with any sysctl.
#
# Prints "busiest<TAB>average<TAB>cores<TAB>steal".
busiest_core_pct() {
  local secs="${1:-5}" a b
  [[ -r /proc/stat ]] || return 1
  a="$(awk '/^cpu[0-9]+ /' /proc/stat)" || return 1
  [[ -n "$a" ]] || return 1
  sleep "$secs"
  b="$(awk '/^cpu[0-9]+ /' /proc/stat)" || return 1
  printf '%s\n%s\n' "$a" "$b" | awk '
    { busy = 0; tot = 0
      # $5 idle, $6 iowait: neither is work this machine is doing.
      for (i = 2; i <= NF; i++) { tot += $i; if (i != 5 && i != 6) busy += $i }
      st = (NF >= 9) ? $9 : 0
      if ($1 in seen) {
        d = tot - t[$1]
        if (d > 0) {
          p = (busy - u[$1]) * 100 / d
          sp = (st - v[$1]) * 100 / d
          sum += p; n++
          if (p > max) max = p
          if (sp > maxst) maxst = sp
        }
      } else { seen[$1] = 1; t[$1] = tot; u[$1] = busy; v[$1] = st } }
    END { if (n < 1) exit 1; printf "%.0f\t%.0f\t%d\t%.0f", max, sum / n, n, maxst }'
}

# Encoded because live data caught this reasoning error: a ceiling that is not
# being reached is not the constraint. Three backends at 135/146/184 ms all
# topped out near 600 Mbps while the configured window supported 1011/935/742 —
# the buffer had headroom everywhere and raising it could not have helped.
#
# Prints "supported<TAB>observed<TAB>usedpct" for the live receive ceiling at
# the given RTT.
window_headroom() {
  local rtt="${1:-0}" obs="${2:-0}" rmem
  rmem="$(live_value net.core.rmem_max)"
  is_uint "${rmem:-}" && (( rmem > 0 )) || return 1
  awk -v r="$rmem" -v rtt="$rtt" -v obs="$obs" 'BEGIN {
    if (rtt <= 0 || obs <= 0) exit 1
    # tcp_adv_win_scale=1: the application gets half the buffer as window.
    sup = (r / 2) * 8 / (rtt / 1000) / 1000000
    if (sup <= 0) exit 1
    printf "%.0f\t%.1f\t%.0f", sup, obs, obs * 100 / sup }'
}

# The kernel sizes tcp_mem from RAM, and it is a global page budget shared by
# every socket. A per-socket ceiling above a meaningful fraction of it means the
# ceiling is theoretical: a handful of flows will hit global pressure first and
# the kernel will shrink them all. Reporting the ceiling alone would be a lie by
# omission on a small box.
tcp_mem_high_bytes() {
  local pages page
  pages="$(sysctl -n net.ipv4.tcp_mem 2>/dev/null | awk '{print $3}')" || return 1
  is_uint "${pages:-}" || return 1
  page="$(getconf PAGESIZE 2>/dev/null || printf 4096)"
  printf '%s\n' $(( pages * page ))
}

mb() { awk -v b="${1:-0}" 'BEGIN {printf "%.1f", b / 1048576}'; }

cpu_count() { getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1; }

# Software shaping is not free. CAKE runs the whole egress through one qdisc and
# does per-packet work on it: deficit round robin, a per-packet hash for
# dual-dsthost, and above all `split-gso`, which breaks a 64KB GSO superpacket
# into ~44 MTU-sized packets so it can pace them precisely. On a small VPS that
# costs more throughput than the policer it replaces.
#
# Anchored to a measurement rather than a guess. Same box, same backend, minutes
# apart: `fq maxrate 980mbit` delivered 629 Mbps peak, `cake bandwidth 980Mbit`
# delivered 332. That box reports ONE core -- the earlier "2 cores" reading of
# it was wrong -- so ~300 Mbps of CAKE per core is what it actually managed.
#
# This was 400, and I raised it to 600 because the operator said a 2-core 0.5 GB
# box can push 2 Gbps. That is true, and it is about the PORT -- not about
# CAKE's per-packet cost. Raising a shaping-CPU threshold on a port-speed claim
# conflated two different things, and it removed the warning that would have
# caught exactly the configuration above: 2 x 400 = 800 warns on a gigabit,
# 2 x 600 = 1200 does not.
SHAPE_MBPS_PER_CORE=300

# True when this machine cannot shape the rate it is being asked to shape.
# Independent of SHAPE, because the wizard needs to know before the operator has
# chosen a profile.
cake_over_budget() {
  local rate="${1:-0}" cores
  cores="$(cpu_count)"
  is_uint "$cores" && (( cores > 0 )) || cores=1
  (( rate > cores * SHAPE_MBPS_PER_CORE ))
}
shaping_cpu_warning() {
  local rate="${1:-0}" cores
  (( SHAPE == 1 )) || return 1
  cores="$(cpu_count)"
  is_uint "$cores" && (( cores > 0 )) || cores=1
  (( rate > cores * SHAPE_MBPS_PER_CORE )) || return 1
  printf '%s\t%s\n' "$cores" "$rate"
}

# ── 命令 ───────────────────────────────────────────────────────────────────

cmd_check() {
  title 'tcpwide 环境检查'
  local avail cc cake
  avail="$(available_cc)"; cc="$(pick_cc "$avail")"
  printf '  内核:              %s\n' "$(uname -r 2>/dev/null || printf 未知)"
  printf '  可用拥塞控制:      %s\n' "${avail:-未知}"
  printf '  将会选用:          %s\n' "$cc"
  case "$cc" in
    cubic) printf '  %b内核没有 BBR。cubic 每丢一次砍一次窗，无线链路上会一直起不来%b\n' \
             "$YELLOW" "$RESET" ;;
    *)     printf '  版本判定:          %s\n' "$(bbr_variant_note "$(bbr_variant "$avail")")" ;;
  esac
  resolve_iface
  printf '  出口网卡:          %s\n' "$IFACE"
  if have_cake; then cake=yes; else cake=no; fi
  printf '  sch_cake:          %s' "$cake"
  [[ "$cake" == yes ]] || printf '  %b（没有 CAKE 就做不了按设备公平，会退回 fq）%b' "$YELLOW" "$RESET"
  printf '\n'
  printf '  内存:              %s MB\n' "$(( $(total_ram_bytes) / 1048576 ))"
  printf '  CPU:               %s 核\n' "$(cpu_count)"
  local warn_row cores rate
  if warn_row="$(shaping_cpu_warning "${EGRESS_MBPS:-500}")"; then
    IFS=$'\t' read -r cores rate <<< "$warn_row"
    printf '\n'
    warn "${cores} 核整形 ${rate} Mbps 可能撑不住"
    printf '  %bCAKE 把整个出口收敛到一个 qdisc 并逐包处理，小机器上这笔 CPU 开销可能比它%b\n' \
      "$DIM" "$RESET"
    printf '  %b替掉的 policer 还贵。单线程测速掉速的话，先用「4) 不整形」档对照一次。%b\n' \
      "$DIM" "$RESET"
  fi
  local other
  if other="$(conflicting_tool)"; then
    printf '\n'
    warn "检测到 $other：它同样接管全局 sysctl 和根队列。两者不是叠加，是谁后跑谁生效"
    printf '  %b先卸载它再 apply，否则重启或它下次运行时会盖掉这里的配置。%b\n' "$DIM" "$RESET"
  fi
}

cmd_plan() {
  local rate rtt
  if (( SHAPE == 1 )); then require_egress; rate="$EGRESS_MBPS"
  else rate="${EGRESS_MBPS:-200}"; fi
  rtt="$COVER_RTT_MS"
  resolve_iface
  title 'tcpwide 预演'
  printf '  %b按覆盖 RTT %s ms × %s Mbps 定尺寸。上限只是上限——近端连接的 autotuning 会自己停在低处，%b\n' \
    "$DIM" "$rtt" "$rate" "$RESET"
  printf '  %b给大几乎不亏；给小才是每个远端客户端都撞得到、却查不出原因的硬顶。%b\n\n' "$DIM" "$RESET"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  render_plan "$rate" "$rtt"
  report_link "$rate" "$rtt"
  printf '\n  %b这是预演，什么都没有改。确认后跑：%s apply%b\n' "$BOLD" "$PROGRAM" "$RESET"
}

# Writes SYSCTL_WROTE rather than echoing a count, because the caller used to
# capture stdout to read that count — which swallowed every progress line with
# it, so an apply looked like it had touched nothing.
SYSCTL_WROTE=0
apply_sysctl() {
  local rate="$1" rtt="$2" k v dir now n=0
  : > "$SYSCTL_SNAP.tmp"
  while IFS=$'\t' read -r k v dir _; do
    [[ -n "$k" ]] || continue
    now="$(live_value "$k")"
    printf '%s\t%s\n' "$k" "$now" >> "$SYSCTL_SNAP.tmp"
    needs_write "$now" "$v" "$dir" || continue
    v="$(safe_value "$now" "$v" "$dir")"
    if sysctl -qw "$k=$v" 2>/dev/null; then
      n=$((n + 1)); printf '  %b[写]%b %s = %s\n' "$GREEN" "$RESET" "$k" "$v"
    else
      printf '  %b[跳过]%b %s —— 这个内核不接受该键\n' "$YELLOW" "$RESET" "$k"
    fi
  done < <(target_sysctl "$rate" "$rtt")
  # Snapshot only on the first apply: revert must return the machine to what it
  # was before tcpwide ever ran, not to what the previous apply left behind.
  if [[ -e "$SYSCTL_SNAP" ]]; then rm -f "$SYSCTL_SNAP.tmp"
  else mv -f "$SYSCTL_SNAP.tmp" "$SYSCTL_SNAP"; chmod 0600 "$SYSCTL_SNAP"; fi
  SYSCTL_WROTE="$n"
  (( n > 0 )) || info "所有 sysctl 都已经是目标值或更好，没有写入任何一项"
}

# `mq` is what the driver puts on a multiqueue NIC: one child qdisc per hardware
# TX queue, each with its own lock, so cores do not serialise against each other
# on transmit. Replacing the root with a single `fq` throws that away and funnels
# every queue through one lock — invisible on a single-flow test, and exactly the
# wrong trade on a small box trying to push aggregate throughput.
#
# So when the root is `mq` and we are only pacing, keep `mq` and put the pacer on
# each leaf. Shaping is the one case that still has to take the root: CAKE can
# only shape what it can all see, and that serialisation is the price of an AQM.
mq_root_handle() {
  tc qdisc show dev "$IFACE" 2>/dev/null |
    awk '$1 == "qdisc" && $2 == "mq" && $4 == "root" {print $3; exit}'
}

# An unmatched glob leaves the literal pattern in $q, so the -d test fails. As
# the last command in the loop body that made the whole function return non-zero
# under errexit -- masked today only because every caller happens to run it in
# an `if` condition. A dud mine is still a mine.
tx_queue_count() {
  local n=0 q
  for q in /sys/class/net/"$IFACE"/queues/tx-*; do
    if [[ -d "$q" ]]; then n=$(( n + 1 )); fi
  done
  printf '%s\n' "$n"
}

# All or nothing. A leaf that does not take the spec keeps whatever the kernel
# put there -- `fq_codel` or `pfifo_fast`, neither of which paces anything -- and
# BBR on an unpaced queue sends cwnd-sized bursts at line rate for a downstream
# policer to drop. Half a machine paced is worse than none of it paced, because
# it is intermittent and looks like the network.
#
# The previous version accepted `ok > 0` and printed "done". Any leaf that fails
# now rolls back the ones already written and reports failure, so the caller
# falls back to the single root fq that cannot be partially applied.
#
# Prints the number of leaves that took the spec. Fails if there is no mq root,
# only one queue (nothing to preserve), or any leaf refused it.
apply_fq_leaves() {
  local spec="$1" handle n i j ok=0
  handle="$(mq_root_handle)"
  [[ -n "$handle" ]] || return 1
  n="$(tx_queue_count)"
  is_uint "$n" && (( n > 1 )) || return 1
  split_words "$spec"
  for (( i = 1; i <= n; i++ )); do
    if tc qdisc replace dev "$IFACE" parent "${handle}${i}" "${SPLIT_WORDS[@]}" 2>/dev/null; then
      ok=$(( ok + 1 ))
    else
      # Undo the partial state before handing back to the root path.
      for (( j = 1; j <= ok; j++ )); do
        tc qdisc del dev "$IFACE" parent "${handle}${j}" 2>/dev/null || true
      done
      return 1
    fi
  done
  (( ok == n )) || return 1
  printf '%s\n' "$ok"
}

# What is ACTUALLY on the interface after writing, read back from the kernel.
#
# Every "已设为" line before this was printed off `tc`'s exit code, which says a
# command was accepted, not that the interface ended up in the intended shape.
# That is the same class of bug as the panel printing a target value as though
# it were live, and it cost a whole round of analysis built on a number that had
# never applied. So the tool states the live layout, and if it disagrees with
# what was asked for it says so instead of claiming success.
live_qdisc_layout() {
  local root leaves handle
  root="$(tc qdisc show dev "$IFACE" 2>/dev/null | sed -n '1p' | sed 's/^qdisc //')"
  [[ -n "$root" ]] || return 1
  handle="$(mq_root_handle)"
  if [[ -n "$handle" ]]; then
    leaves="$(tc qdisc show dev "$IFACE" 2>/dev/null |
      awk -v h="$handle" '$1 == "qdisc" && $4 == "parent" && index($5, h) == 1 {
        print $2 }' | sort | uniq -c | awk '{printf "%s×%s ", $1, $2}')"
    printf 'mq root ← %s\n' "${leaves:-（没有叶子）}"
    return 0
  fi
  printf '%s\n' "$root"
}

# The default route half of apply_link, split out so both the mq-leaf path and
# the root path run exactly the same code rather than two copies that drift.
apply_route() {
  local cur_r want_r
  cur_r="$(current_default_route)"
  if ! route_is_simple "$cur_r"; then
    warn "默认路由是多路径或不止一条，跳过首窗设置（错改默认路由会断连）"
    return 0
  fi
  want_r="$(route_with_initcwnd "$cur_r" "$INITCWND")"
  [[ "$cur_r" != "$want_r" ]] || return 0
  [[ -e "$ROUTE_SNAP" ]] || { printf '%s\n' "$cur_r" > "$ROUTE_SNAP"; chmod 0600 "$ROUTE_SNAP"; }
  split_words "$want_r"
  if ip route replace "${SPLIT_WORDS[@]}" 2>/dev/null; then
    log "默认路由首窗已设为 initcwnd $INITCWND"
  else
    warn "无法修改默认路由，首窗保持内核默认"
  fi
}

# The coverage RTT past which the per-socket ceiling stops growing, because the
# global budget has reached its own cap. Both the suggestion and the explanation
# read it from here rather than each computing their own.
buffer_knee_ms() {
  local rate="${1:-0}" ram clamp knee
  (( rate > 0 )) || return 1
  ram="$(total_ram_bytes)"
  (( ram > 0 )) || return 1
  # Asking for a need nothing can satisfy returns the hard cap.
  clamp="$(socket_budget_cap "$ram" "$ram")"
  knee=$(( (clamp - BUF_SLACK) / (250 * rate) ))
  (( knee >= 10 && knee <= 2000 )) || return 1
  printf '%s\n' "$knee"
}

# One line that identifies exactly which configuration is running, built from
# LIVE values rather than intended ones.
#
# Working out which build produced a given speedtest took a `git diff` between
# two released versions, because a screenshot of a result carries nothing about
# the configuration that produced it. Pasted next to a measurement, this line
# makes attribution a lookup instead of an argument.
config_fingerprint() {
  local cc buf layout cwnd
  cc="$(live_value net.ipv4.tcp_congestion_control)"
  buf="$(live_value net.core.rmem_max)"
  layout="$(canonical_qdisc 2>/dev/null || printf '?')"
  cwnd="$(current_default_route | grep -o 'initcwnd [0-9]*' | awk '{print $2}')"
  printf '%s %s ｜ %s ｜ rmem %s MB ｜ %s ｜ initcwnd %s ｜ cover %s ms\n' \
    "$PROGRAM" "$VERSION" "${cc:-?}" "$(mb "${buf:-0}")" "$layout" \
    "${cwnd:-内核默认}" "$COVER_RTT_MS"
}

# Eight rounds of "install, pick something, run a speedtest, still slow" went by
# without anyone being able to say which configuration produced which number.
# The fingerprint made a configuration identifiable; this makes two of them
# comparable. Without it every round starts from opinion.
#
# One record per line: unix time, Mbps, fingerprint, note, threads, rtt.
#
# The RTT is what makes a pile of readings analysable. Rate alone cannot say
# whether a slow backend is slow because it is far away or because something is
# capping it: only rate x RTT separates those, and that product is the bytes
# actually in flight.
#
# The thread count is the field that turns a pile of numbers into a diagnosis.
# A single flow through a userspace proxy carries per-connection overhead that
# no sysctl removes, so single-thread and multi-thread readings answer two
# different questions and must never be averaged together.
record_measurement() {
  local mbps="${1:-}" note="${2:-}" threads="${3:-1}" rtt="${4:-0}"
  [[ "$mbps" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  is_uint "$threads" && (( threads > 0 )) || threads=1
  [[ "$rtt" =~ ^[0-9]+(\.[0-9]+)?$ ]] || rtt=0
  mkdir -p "$STATE_DIR"; chmod 0700 "$STATE_DIR" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" "$mbps" "$(config_fingerprint)" "${note//$'\t'/ }" "$threads" "$rtt" \
    >> "$MEASURE_LOG"
  chmod 0600 "$MEASURE_LOG" 2>/dev/null || true
}

# How much of the window this machine offers is actually being used.
#
# in-flight = rate x RTT. Compare it against the window we advertise
# (rmem_max / BDP_MULTIPLIER) and the answer to "is my buffer the limit" stops
# being a guess. Well under it means raising the ceiling -- or
# buying a machine with more memory -- changes nothing, which is the expensive
# wrong move this is here to prevent.
#
# Prints one row per single-thread reading that carries an RTT:
#   note<TAB>rtt<TAB>mbps<TAB>inflight_MB<TAB>pct_of_window
window_utilisation() {
  local rmem
  [[ -r "$MEASURE_LOG" ]] || return 1
  rmem="$(live_value net.core.rmem_max)"
  is_uint "${rmem:-}" && (( rmem > 0 )) || return 1
  awk -F'\t' -v wnd="$(( rmem / BDP_MULTIPLIER ))" '
    NF >= 6 && $6 + 0 > 0 && (($5 + 0) <= 1) {
      inflight = $2 * 1000000 * ($6 / 1000) / 8
      printf "%s\t%s\t%s\t%.2f\t%.0f\n", ($4 == "" ? "-" : $4), $6, $2,
             inflight / 1048576, inflight * 100 / wnd
      seen = 1 }
    END { if (!seen) exit 1 }' "$MEASURE_LOG" | sort -t"$(printf '\t')" -k5 -nr
}

# The fastest single-thread and multi-thread runs on record, as
# "single<TAB>multi". Either may be empty. Records written before 0.13.0 have no
# thread column and count as single-thread, which is what they were.
thread_split() {
  [[ -r "$MEASURE_LOG" ]] || return 1
  awk -F'\t' '{
      t = (NF >= 5 && $5 + 0 > 0) ? $5 + 0 : 1
      if (t > 1) { if ($2 + 0 > m + 0) m = $2 }
      else       { if ($2 + 0 > s + 0) s = $2 } }
    END { if (s == "" && m == "") exit 1; printf "%s\t%s", s, m }' "$MEASURE_LOG"
}

# What the two readings mean together. Aggregate near the port rate says the
# server side is done: the port, the memory, the queue and the TCP settings all
# deliver. A single flow well below it is per-connection overhead, and no
# amount of buffer or queue tuning moves it.
throughput_verdict() {
  local port="${1:-0}" row single multi
  row="$(thread_split)" || return 1
  IFS=$'\t' read -r single multi <<< "$row"
  [[ -n "$single" && -n "$multi" ]] || return 1
  awk -v s="$single" -v m="$multi" -v p="$port" 'BEGIN {
    if (p <= 0) exit 1
    pct = m * 100 / p
    printf "%s\t%s\t%.0f\t%s", s, m, pct, (pct >= 85) ? "tuned" : "short" }'
}

# The fastest run on record. Prints "mbps<TAB>fingerprint<TAB>note<TAB>when".
best_measurement() {
  [[ -r "$MEASURE_LOG" ]] || return 1
  awk -F'\t' 'NF >= 3 && $2 + 0 > best + 0 { best = $2; line = $0 }
    END { if (line == "") exit 1
      split(line, f, "\t")
      printf "%s\t%s\t%s\t%s", f[2], f[3], f[4], strftime("%m-%d %H:%M", f[1]) }' \
    "$MEASURE_LOG"
}

cmd_record() {
  local mbps="${1:-}" note="${2:-}" row bm bf bn bw
  [[ -n "$mbps" ]] || die "用法：$PROGRAM record <Mbps> [备注] [--threads N]    例：$PROGRAM record 629 上海电信"
  resolve_iface
  record_measurement "$mbps" "$note" "$RECORD_THREADS" "$RECORD_RTT" \
    || die "Mbps 需为数字，例：$PROGRAM record 629.1 上海电信"
  if [[ "$RECORD_RTT" == 0 ]]; then
    warn "没给 --rtt，这条进不了窗口分析。测速面板上那个「延迟RTT」就是它"
  fi
  title 'tcpwide 记录'
  log "已记录 $mbps Mbps"
  printf '  %b%s%b\n' "$DIM" "$(config_fingerprint)" "$RESET"
  if row="$(best_measurement)"; then
    IFS=$'\t' read -r bm bf bn bw <<< "$row"
    printf '\n  %b历史最好：%s Mbps%b（%s%s）\n' "$BOLD" "$bm" "$RESET" "$bw" \
      "$( [[ -n "$bn" ]] && printf '，%s' "$bn" )"
    printf '  %b%s%b\n' "$DIM" "$bf" "$RESET"
  fi
  render_verdict "${EGRESS_MBPS:-0}"
  render_window_ratio
  render_window_report
  printf '\n'
}

# The one measurement that can settle WHY bytes in flight land at a quarter of
# rmem_max instead of a half.
#
# Two explanations fit the field data equally well and call for different fixes:
#
#   the window ratio      rcvbuf reaches rmem_max, but the kernel only advertises
#                         a quarter of it -- then 4x BDP is the right size and
#                         rmem_max is the knob.
#   autotuning falls short rcvbuf never grows near rmem_max -- then raising
#                         rmem_max achieves nothing and the knobs are
#                         tcp_rmem[1] and tcp_moderate_rcvbuf.
#
# Reading the socket's ACTUAL rcvbuf separates them. ss reports it in the skmem
# block as rb<N>. Prints "rcvbuf<TAB>rmemmax<TAB>inflight<TAB>fill_pct<TAB>ratio_pct".
window_ratio() {
  local ports rmem
  has ss || return 1
  rmem="$(live_value net.core.rmem_max)"
  is_uint "${rmem:-}" && (( rmem > 0 )) || return 1
  ports="$(ss -tlnH 2>/dev/null | awk '{
    for (i = NF; i >= 1; i--) if ($i ~ /:[0-9]+$/) {
      j = length($i); while (j > 0 && substr($i, j, 1) != ":") j--
      print substr($i, j + 1); break
    }
  }' | sort -u | tr '\n' ' ')" || return 1
  ss -tinmH 2>/dev/null | awk -v listen=" $ports " -v floor="$LOCAL_RTT_SAMPLE_MS" \
      -v mbfloor="$SAMPLE_MBPS_FLOOR" -v rmem="$rmem" '
    function portof(a,   i) {
      i = length(a); while (i > 0 && substr(a, i, 1) != ":") i--
      return (i > 0) ? substr(a, i + 1) : ""
    }
    function tomb(v,   n) {
      n = v + 0
      if (v ~ /Gbps/) return n * 1000
      if (v ~ /Mbps/) return n
      if (v ~ /Kbps/) return n / 1000
      return n / 1000000
    }
    /^[ \t]/ {
      if (local == "") next
      rtt = 0; rate = 0; rb = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^rtt:/) { t = substr($i, 5); q = index(t, "/")
          rtt = ((q > 0) ? substr(t, 1, q - 1) : t) + 0 }
        else if ($i == "delivery_rate" && i < NF) rate = tomb($(i + 1))
        else if ($i ~ /^skmem:/) {
          if (match($i, /rb[0-9]+/)) rb = substr($i, RSTART + 2, RLENGTH - 2) + 0
          # r<N> is bytes sitting in the receive queue unread; d<N> is receive
          # drops. Together they say whether the application is keeping up.
          if (match($i, /\(r[0-9]+/)) rq = substr($i, RSTART + 2, RLENGTH - 2) + 0
          if (match($i, /d[0-9]+\)/)) dr = substr($i, RSTART + 1, RLENGTH - 2) + 0
        }
      }
      if (rtt >= floor && rb > 0 && rate >= mbfloor && rate > best \
          && index(listen, " " portof(local) " ") > 0) {
        best = rate; brtt = rtt; brb = rb; brq = rq; bdr = dr
      }
      local = ""; next
    }
    { local = ""
      if (NF >= 5 && $1 ~ /^[A-Z][A-Z0-9_-]*$/) local = $4
      else if (NF >= 4) local = $3 }
    END {
      if (best <= 0) exit 1
      inflight = best * 1000000 * (brtt / 1000) / 8
      printf "%d\t%d\t%d\t%.0f\t%.0f\t%d\t%d\t%.0f", brb, rmem, inflight,
             brb * 100 / rmem, inflight * 100 / brb, brq, bdr, brq * 100 / brb
    }'
}

render_window_ratio() {
  local row rb rmem inflight fill ratio rq drops qpct
  row="$(window_ratio)" || {
    printf '\n  %b窗口比例：现在没有跑到 %s Mbps 以上的入站连接，测不了。%b\n' \
      "$DIM" "$SAMPLE_MBPS_FLOOR" "$RESET"
    printf '  %b开两个 SSH：一个跑测速，跑的同时另一个进来按 8。%b\n' "$DIM" "$RESET"
    printf '  %b（空闲的 SSH 会话本身也是连接，但它的缓冲说明不了任何问题。）%b\n' "$DIM" "$RESET"
    return 0
  }
  IFS=$'\t' read -r rb rmem inflight fill ratio rq drops qpct <<< "$row"
  printf '\n  %b窗口比例实测（正在跑流量的那条连接）%b\n' "$BOLD" "$RESET"
  printf '    实际 rcvbuf %s MB ／ rmem_max %s MB = %s%%（autotuning 长到了多少）\n' \
    "$(mb "$rb")" "$(mb "$rmem")" "$fill"
  printf '    在途 %s MB ／ 实际 rcvbuf = %s%%（内核真正给出去的窗口比例）\n' \
    "$(mb "$inflight")" "$ratio"
  printf '    接收队列积压 %s MB（占 rcvbuf %s%%）｜接收丢弃 %s\n' \
    "$(mb "$rq")" "$qpct" "$drops"
  # Four causes, four different fixes. Guessing between them is what produced
  # two rounds of wrong advice.
  if (( qpct >= 50 )); then
    warn "接收队列积压到 rcvbuf 的 ${qpct}% —— 是应用没把数据读走"
    printf '    %b瓶颈在代理进程或 CPU，不在 TCP 配置。加大缓冲只会让积压更大。%b\n' \
      "$DIM" "$RESET"
  elif (( drops > 0 )); then
    warn "接收侧丢弃 ${drops} —— 数据在进协议栈之前就没了"
    printf '    %b看 netdev_max_backlog 和每核占用，不是缓冲的问题。%b\n' "$DIM" "$RESET"
  elif (( fill < 70 )); then
    printf '    %b→ rcvbuf 只长到 rmem_max 的 %s%%，而队列几乎是空的：%b\n' "$GREEN" "$fill" "$RESET"
    printf '    %b  autotuning 没有理由长——发送端或路径本来就只有这么快。%b\n' "$DIM" "$RESET"
    printf '    %b  加大 rmem_max 不会有任何作用（0.16.0 把它翻倍，实测一点没动）。%b\n' "$DIM" "$RESET"
  elif (( ratio >= 40 )); then
    printf '    %b→ rcvbuf 到顶了，而且在途已经接近它的一半：真的是窗口限制。%b\n' \
      "$YELLOW" "$RESET"
    printf '    %b  这时候加大覆盖 RTT／缓冲上限才有意义。%b\n' "$DIM" "$RESET"
  else
    printf '    %b→ rcvbuf 到顶但在途只有 %s%%，两头都不像瓶颈，看别处。%b\n' \
      "$DIM" "$ratio" "$RESET"
  fi
}

# A manual buffer ceiling below what the derivation would pick is a cap the
# operator set once during an experiment and then forgot. On the 958 MB box a
# leftover 32 MB held it to 353 Mbps on a 520 Mbps port while its memory would
# have allowed more, and nothing said so.
manual_buffer_shortfall() {
  local rate="${1:-0}" rtt="${2:-0}" auto manual
  is_uint "$BUF_MB" && (( BUF_MB > 0 )) || return 1
  manual=$(( BUF_MB * 1024 * 1024 ))
  auto="$(BUF_MB=0 buffer_ceiling "$rate" "$rtt")"
  (( auto > manual )) || return 1
  printf '%s\t%s\t%s\n' "$manual" "$auto" \
    "$(awk -v m="$manual" -v r="$rtt" -v d="$BDP_MULTIPLIER" \
        'BEGIN {printf "%.0f", m / d * 8 / (r / 1000) / 1e6}')"
}

warn_manual_buffer() {
  local rate="${1:-0}" rtt="${2:-0}" row manual auto capped
  row="$(manual_buffer_shortfall "$rate" "$rtt")" || return 0
  IFS=$'\t' read -r manual auto capped <<< "$row"
  warn "手动缓冲上限 $(mb "$manual") MB 低于自动值 $(mb "$auto") MB"
  printf '  %b按 %s ms 覆盖，手动这个值只支持约 %s Mbps，而端口是 %s Mbps。%b\n' \
    "$DIM" "$rtt" "$capped" "$rate" "$RESET"
  printf '  %b面板 b) 填 0 就交还给自动推导。%b\n' "$DIM" "$RESET"
}

# The per-backend window table and what it implies. This is the arithmetic that
# has had to be done by hand every round: rate x RTT against the window we
# advertise, which is the only thing separating "our buffer is the limit" from
# "the buffer has headroom and the limit is somewhere else".
render_window_report() {
  local rows peak=0 note rtt mbps mbytes pct
  rows="$(window_utilisation)" || return 0
  printf '\n  %b各后端实际用掉了本机窗口的多少%b\n' "$BOLD" "$RESET"
  printf '  %b后端            RTT      实测       在途    占本机窗口%b\n' "$DIM" "$RESET"
  while IFS=$'\t' read -r note rtt mbps mbytes pct; do
    [[ -n "$rtt" ]] || continue
    printf '  %-14s %5sms %7s Mbps %6s MB %8s%%\n' "${note:0:14}" "$rtt" "$mbps" "$mbytes" "$pct"
    (( pct > peak )) && peak="$pct"
  done <<< "$rows"
  printf '  %b本机可通告窗口 %s MB（rmem_max 的一半）%b\n\n' \
    "$DIM" "$(mb "$(( $(live_value net.core.rmem_max) / BDP_MULTIPLIER ))")" "$RESET"
  if (( peak > 115 )); then
    printf '  %b→ 有记录超过本机窗口 %s%%，说明它量的不是这台机器的接收腿。%b\n' \
      "$YELLOW" "$peak" "$RESET"
    printf '  %b  客户端穿代理测出来的端到端速度，带的是客户端自己的 RTT，%b\n' "$DIM" "$RESET"
    printf '  %b  和本机的接收窗口不是同一件事。要判断缓冲，用本机自己拉流的测法%b\n' "$DIM" "$RESET"
    printf '  %b  （TcpQuality 的回程速度就是），RTT 才和这台机器对得上。%b\n' "$DIM" "$RESET"
  elif (( peak >= 85 )); then
    printf '  %b→ 已经有后端贴着本机窗口跑，缓冲就是瓶颈。%b\n' "$YELLOW" "$RESET"
    printf '  %b  先把覆盖 RTT 填到实际最远客户端那个值。%b\n' "$DIM" "$RESET"
    # 0.16.0 added a line here telling the operator that a box at its memory
    # ceiling needed more memory. Doubling rmem_max on that very box moved nine
    # backends by nothing at all, so the advice was wrong and is gone. Being at
    # the ceiling is only worth acting on once window_ratio shows the buffer is
    # genuinely full, which is what the four-way verdict is for.
    printf '  %b  先用 8) 的窗口比例确认 rcvbuf 真的长到了顶再动缓冲——%b\n' "$DIM" "$RESET"
    printf '  %b  这台机器上 rmem_max 翻倍曾经一点效果都没有。%b\n' "$DIM" "$RESET"
  else
    printf '  %b→ 最高才用到 %s%%，本机缓冲还有余量。%b\n' "$GREEN" "$peak" "$RESET"
    printf '  %b  剩下的杠杆，按性价比：%b\n' "$BOLD" "$RESET"
    printf '  %b   1. 把 notsent_lowat 往【更大】试（面板 n，262144 / 524288）——%b\n' "$DIM" "$RESET"
    printf '  %b      131072 已经实测胜过 16384 四成，方向明确是越大越好，但上界没找到。%b\n' "$DIM" "$RESET"
    printf '  %b   2. BBRv3（面板 s → 4）—— v1 在高 RTT 且有丢包的路径上估值最吃亏。%b\n' "$DIM" "$RESET"
    printf '  %b   3. 换后端 —— 同一时刻不同后端差 20%%+ 且与 RTT 无关时，差的那块%b\n' "$DIM" "$RESET"
    printf '  %b      在对端或路径上，本机怎么调都拿不回来。%b\n' "$DIM" "$RESET"
  fi
}

# Says out loud what the single/multi pair means.
#
# 0.13.0 said something stronger and it was wrong: that a single flow below the
# aggregate is per-connection overhead which "no buffer or queue setting moves".
# The very next change moved it by 70% -- fq's flow_limit took one thread from
# 546 to 927 Mbps, level with what several threads had been managing. A gap
# between the two arms says where to look, never that looking is pointless.
render_verdict() {
  local port="${1:-0}" v single multi pct state
  v="$(throughput_verdict "$port")" || return 0
  IFS=$'\t' read -r single multi pct state <<< "$v"
  printf '\n  %b单线程 %s Mbps ｜ 多线程 %s Mbps（%s%% 线速）%b\n' \
    "$BOLD" "$single" "$multi" "$pct" "$RESET"
  if [[ "$state" == tuned ]]; then
    printf '  %b→ 聚合已经跑满端口，服务端的总能力没问题。%b\n' "$GREEN" "$RESET"
    if awk -v s="$single" -v m="$multi" 'BEGIN {exit !(s < m * 0.85)}'; then
      printf '  %b  但单流只有多线程的 %.0f%%，差的这块是「每流」的限制——%b\n' \
        "$YELLOW" "$(awk -v s="$single" -v m="$multi" 'BEGIN {print s * 100 / m}')" "$RESET"
      printf '  %b  fq 的 flow_limit、notsent_lowat、BBR 单流行为都在这一类里。面板 s) 逐个 A/B。%b\n' \
        "$DIM" "$RESET"
      printf '  %b  （0.13.0 曾断言这块动不了，随后 flow_limit 就把它抬了 70%%。）%b\n' \
        "$DIM" "$RESET"
    else
      printf '  %b  单流也追平了多线程，两条腿都到位了。%b\n' "$GREEN" "$RESET"
    fi
  else
    printf '  %b→ 多线程也没跑满端口，说明瓶颈还在服务端或上游，值得继续查。%b\n' \
      "$YELLOW" "$RESET"
  fi
}

# A stable identity for the running layout: the kind plus the options we chose,
# with the kernel's own bookkeeping stripped out.
#
# The fingerprint used the raw `tc` line, which carries a handle the kernel
# reassigns on every `tc qdisc replace` (8006:, then 8007:, ...) and a refcnt
# that moves on its own. Two runs of the identical configuration therefore
# produced two different fingerprint strings, and the panel's "this is the best
# run" comparison could never be true. An A/B is worthless if the two arms
# cannot be recognised as the same arm twice.
canonical_qdisc() {
  local raw kind handle leaves
  handle="$(mq_root_handle)"
  if [[ -n "$handle" ]]; then
    leaves="$(tc qdisc show dev "$IFACE" 2>/dev/null |
      awk -v h="$handle" '$1 == "qdisc" && $4 == "parent" && index($5, h) == 1 {
        print $2 }' | sort | uniq -c | awk '{printf "%s×%s ", $1, $2}')"
    printf 'mq ← %s\n' "${leaves:-（没有叶子）}"
    return 0
  fi
  raw="$(tc qdisc show dev "$IFACE" 2>/dev/null | sed -n '1p')" || return 1
  [[ -n "$raw" ]] || return 1
  kind="$(awk '{print $2}' <<< "$raw")"
  # Only the fields we set ourselves survive. Everything else is either a
  # kernel default that never varies with our configuration, or bookkeeping
  # that varies without it.
  # limit and flow_limit belong here even though they look like kernel defaults:
  # since 0.14.0 they ARE configuration, and flow_limit is the setting that took
  # a single thread from 546 to 927 Mbps. Leaving them out gave the winning
  # configuration and the losing one the same fingerprint, which would have made
  # the record log unable to tell apart the very knob it exists to compare.
  awk -v kind="$kind" '{
    out = kind
    for (i = 1; i <= NF; i++) {
      if ($i == "maxrate"    && i < NF) out = out " maxrate " $(i+1)
      if ($i == "bandwidth"  && i < NF) out = out " " $(i+1)
      if ($i == "rtt"        && i < NF) out = out " rtt " $(i+1)
      if ($i == "limit"      && i < NF) out = out " limit " $(i+1)
      if ($i == "flow_limit" && i < NF) out = out " flow_limit " $(i+1)
      if ($i == "initial_quantum" && i < NF) out = out " initial_quantum " $(i+1)
      if ($i == "dual-dsthost" || $i == "dual-srchost" || $i == "triple-isolate") out = out " " $i
      if ($i == "no-split-gso") out = out " no-split-gso"
    }
    print out }' <<< "$raw"
}

# Print the live layout beside what was asked for, and flag any disagreement.
report_live_qdisc() {
  local want="${1:-}" live
  live="$(live_qdisc_layout)" || { warn "无法回读队列，手动检查 tc qdisc show dev $IFACE"; return 0; }
  printf '  %b实际生效：%s%b\n' "$DIM" "$live" "$RESET"
  # Only the kind is compared: tc prints its own defaults (limit, flow_limit,
  # quantum) that were never asked for, so a full string match would cry wolf
  # on every correct application.
  local want_kind live_kind
  want_kind="$(awk '{print $1}' <<< "$want")"
  live_kind="$(awk '{print $1}' <<< "$live")"
  if [[ "$live_kind" == mq ]]; then
    if mq_leaves_with "$want_kind" >/dev/null; then return 0; fi
    warn "mq 的叶子没有全部挂上 $want_kind —— 没挂上的那些队列完全没有 pacing"
    return 0
  fi
  [[ "$live_kind" == "$want_kind" ]] && return 0
  warn "回读到的是 $live_kind，不是 $want_kind —— 写入被接受了但没有生效"
}

apply_link() {
  local rate="$1" rtt="$2" want_q leaves
  want_q="$(target_qdisc "$rate" "$rtt")"
  if [[ ! -e "$QDISC_SNAP" ]]; then
    tc qdisc show dev "$IFACE" 2>/dev/null | sed -n '1p' > "$QDISC_SNAP" || true
    chmod 0600 "$QDISC_SNAP" 2>/dev/null || true
  fi
  if (( SHAPE == 0 )) && [[ "$QDISC_LAYOUT" == mq-leaves ]] \
     && leaves="$(apply_fq_leaves "$want_q")"; then
    log "根队列保持 mq，${leaves} 个发送队列各挂一份：$want_q"
    printf '  %b每个硬件发送队列一个 pacer，各自一把锁——换成单个根 fq 会把它们串成一条。%b\n' \
      "$DIM" "$RESET"
    report_live_qdisc "$want_q"
    apply_route
    return 0
  fi
  split_words "$want_q"
  local tc_err bad
  if tc_err="$(tc qdisc replace dev "$IFACE" root "${SPLIT_WORDS[@]}" 2>&1)"; then
    log "根队列已设为：$want_q"
    report_live_qdisc "$want_q"
  else
    warn "无法设置根队列：tc qdisc replace dev $IFACE root $want_q"
    [[ -z "$tc_err" ]] || printf '  %btc 报错：%s%b\n' "$DIM" "$tc_err" "$RESET"
    if bad="$(probe_cake_options "$want_q")"; then
      printf '  %b逐项试出来，加到这里就被拒绝：%b%s%b\n' "$DIM" "$RESET" "$bad" "$RESET"
      printf '  %b最后那一项要么本机 tc 不认识，要么内核的 sch_cake 不支持。%b\n' "$DIM" "$RESET"
    fi
    # An older sch_cake without no-split-gso should lose that one option, not
    # the whole AQM. Dropping all the way to fq throws away per-host fairness
    # over a keyword -- the same over-reaction the `ecn` rejection caused.
    if [[ "$want_q" == *" no-split-gso"* ]]; then
      local without="${want_q% no-split-gso}"
      split_words "$without"
      if tc qdisc replace dev "$IFACE" root "${SPLIT_WORDS[@]}" 2>/dev/null; then
        warn "本机 sch_cake 不认识 no-split-gso，已去掉它：$without"
        printf '  %b整形保住了，但每包成本回到高位——CPU 不够时优先考虑 4) 不整形。%b\n' \
          "$DIM" "$RESET"
        report_live_qdisc "$without"
        apply_route
        return 0
      fi
    fi
    # Pacing is the single most important item in the whole set, so falling back
    # to fq is far better than leaving the interface on whatever it had.
    if tc qdisc replace dev "$IFACE" root fq >/dev/null 2>&1; then
      warn "已退回 fq：pacing 保住了，但没有按设备公平和 AQM"
    else
      printf '  %b没有 pacing 的话，突发会按线速打出去——这是重传的主要来源。%b\n' "$DIM" "$RESET"
    fi
    return 0
  fi
  apply_route
}

write_persistence() {
  local rate="$1" rtt="$2" k v dir now
  {
    printf '# 由 %s v%s 生成。删除本文件并 systemctl disable tcpwide-link 即可停用。\n' "$PROGRAM" "$VERSION"
    while IFS=$'\t' read -r k v dir _; do
      [[ -n "$k" ]] || continue
      now="$(live_value "$k")"
      printf '%s = %s\n' "$k" "$(safe_value "$now" "$v" "$dir")"
    done < <(target_sysctl "$rate" "$rtt")
  } > "$PERSIST_SYSCTL"
  chmod 0644 "$PERSIST_SYSCTL"
  # The qdisc and the route metric are not sysctls and do not survive a reboot
  # on their own.
  cat > "$PERSIST_UNIT" <<UNIT
[Unit]
Description=tcpwide link settings ($IFACE)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'tc qdisc replace dev $IFACE root $(target_qdisc "$rate" "$rtt")'
ExecStart=/bin/sh -c 'ip route replace $(route_with_initcwnd "$(current_default_route)" "$INITCWND") || true'

[Install]
WantedBy=multi-user.target
UNIT
  chmod 0644 "$PERSIST_UNIT"
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable tcpwide-link.service >/dev/null 2>&1 || true
  log "已持久化：$PERSIST_SYSCTL 与 $PERSIST_UNIT"
}

cmd_apply() {
  local rate rtt n other
  if (( SHAPE == 1 )); then require_egress; rate="$EGRESS_MBPS"
  else rate="${EGRESS_MBPS:-200}"; fi
  rtt="$COVER_RTT_MS"
  need_root apply
  resolve_iface
  has sysctl || die "缺少 sysctl"
  has tc || die "缺少 tc；请安装 iproute2"
  title 'tcpwide 应用'
  if other="$(conflicting_tool)"; then
    warn "检测到 $other，它会盖掉这里的配置"
    if (( ASSUME_YES == 0 )); then
      die "同一台机器只能留一个。先卸载 $other，或者确认要覆盖时加 --yes"
    fi
  fi
  mkdir -p "$STATE_DIR"; chmod 0700 "$STATE_DIR"
  warn_manual_buffer "$rate" "$rtt"
  apply_sysctl "$rate" "$rtt"; n="$SYSCTL_WROTE"
  apply_link "$rate" "$rtt"
  (( PERSIST == 1 )) && write_persistence "$rate" "$rtt"
  printf '\n'
  printf '  %b指纹:%b %s\n' "$BOLD" "$RESET" "$(config_fingerprint)"
  log "完成。$PROGRAM status 看状态，$PROGRAM revert 完整还原"
  (( PERSIST == 0 )) && printf '  %b没有持久化：重启后 sysctl 和根队列都会回到原样。要持久化加 --persist%b\n' \
    "$DIM" "$RESET"
  return 0
}

cmd_status() {
  local rate rtt
  rate="${EGRESS_MBPS:-200}"; rtt="$COVER_RTT_MS"
  resolve_iface
  title 'tcpwide 状态'
  if [[ -e "$SYSCTL_SNAP" ]]; then
    printf '  已应用:            %b是%b（快照 %s）\n' "$GREEN" "$RESET" "$SYSCTL_SNAP"
  else
    printf '  已应用:            %b否%b\n' "$YELLOW" "$RESET"
  fi
  printf '  持久化:            %s\n' \
    "$( [[ -e "$PERSIST_SYSCTL" ]] && printf '是' || printf '否（重启后失效）' )"
  printf '  %b指纹:%b              %s\n' "$BOLD" "$RESET" "$(config_fingerprint)"
  printf '  %b测速截图旁边贴这一行，就不用再靠版本号猜测的是哪份配置。%b\n' "$DIM" "$RESET"
  printf '\n'
  render_plan "$rate" "$rtt"
  report_link "$rate" "$rtt"
  printf '\n'
}

cmd_revert() {
  need_root revert
  title 'tcpwide 还原'
  local k v n=0 q r
  if [[ -r "$SYSCTL_SNAP" ]]; then
    while IFS=$'\t' read -r k v; do
      [[ -n "$k" ]] || continue
      if [[ -z "$v" ]]; then
        printf '  %b[跳过]%b %s 原本没有值\n' "$DIM" "$RESET" "$k"; continue
      fi
      if sysctl -qw "$k=$v" 2>/dev/null; then
        n=$((n + 1)); printf '  %b[还原]%b %s = %s\n' "$GREEN" "$RESET" "$k" "$v"
      fi
    done < "$SYSCTL_SNAP"
    rm -f "$SYSCTL_SNAP"
  else
    info "没有 sysctl 快照"
  fi
  resolve_iface
  if [[ -r "$QDISC_SNAP" ]]; then
    q="$(sed -n '1p' "$QDISC_SNAP" | sed 's/^qdisc //' | awk '{print $1}')"
    if [[ -n "$q" ]] && tc qdisc replace dev "$IFACE" root "$q" 2>/dev/null; then
      log "根队列已还原为 $q"
    else
      if tc qdisc del dev "$IFACE" root 2>/dev/null; then
        info "根队列已删除，回到内核默认"
      else
        warn "无法还原根队列，手动检查 tc qdisc show dev $IFACE"
      fi
    fi
    rm -f "$QDISC_SNAP"
  fi
  if [[ -r "$ROUTE_SNAP" ]]; then
    r="$(sed -n '1p' "$ROUTE_SNAP")"
    split_words "$r"
    if [[ -n "$r" ]] && ip route replace "${SPLIT_WORDS[@]}" 2>/dev/null; then
      log "默认路由已还原"
    else
      warn "无法还原默认路由，手动检查 ip route show default"
    fi
    rm -f "$ROUTE_SNAP"
  fi
  rm -f "$PERSIST_SYSCTL"
  if [[ -e "$PERSIST_UNIT" ]]; then
    systemctl disable tcpwide-link.service >/dev/null 2>&1 || true
    rm -f "$PERSIST_UNIT"; systemctl daemon-reload 2>/dev/null || true
  fi
  log "已还原 $n 项 sysctl，并清除持久化"
}

# ── SSH 面板 ───────────────────────────────────────────────────────────────

# Both the wizard and the panel explain the coverage RTT through this, so the
# advice cannot drift between them.
explain_cover_rtt() {
  local rate="${1:-500}" row sug max n buf tcpmem
  printf '  %b覆盖 RTT 决定缓冲上限，填的是「这台机器上最远那个客户端」的延迟——%b
' "$DIM" "$RESET"
  printf '  %b不是你自己到这台机器的延迟，也不是平均值。%b
' "$DIM" "$RESET"
  printf '  %b上限只是上限：近端客户端的 autotuning 会自己停在低处，用不到那么多；%b
' "$DIM" "$RESET"
  printf '  %b但填低了，每个远端客户端都会撞到一个查不出原因的硬顶。%b
' "$DIM" "$RESET"
  if row="$(suggest_cover_rtt)"; then
    IFS=$'	' read -r sug max n <<< "$row"
    printf '\n  %b实测：当前 %s 个活跃客户端里，最远的 RTT 是 %s ms%b\n' \
      "$GREEN" "$n" "$max" "$RESET"
    # Everything currently connected being nearby does not mean the population
    # is. Suggesting 50ms because the only live sockets are same-datacentre is
    # how a relay ends up capped for every real client it has.
    if awk -v m="$max" -v f="$LOCAL_RTT_SAMPLE_MS" 'BEGIN {exit !(m < f)}'; then
      printf '  %b[!] 全部都在 %s ms 以内 —— 这一刻连上的都是同机房或本地连接，%b\n' \
        "$YELLOW" "$LOCAL_RTT_SAMPLE_MS" "$RESET"
      printf '  %b不能代表你真实的客户端分布。按经验填：同区域 100，跨洋 250-300。%b\n' \
        "$DIM" "$RESET"
    else
      printf '  %b建议填 %s（实测 ×1.2 后向上取整，给移动客户端留波动余量）%b\n' \
        "$GREEN" "$sug" "$RESET"
      # Recommending a value past the knee while also printing "above N it stops
      # growing" puts two numbers on screen that argue with each other.
      local kn; kn="$(buffer_knee_ms "$rate")" || kn=''
      if [[ -n "$kn" ]] && (( sug > kn )); then
        printf '  %b（本机 %s ms 以上不再增加缓冲，填 %s 和填 %s 效果相同）%b\n' \
          "$DIM" "$kn" "$sug" "$kn" "$RESET"
      fi
      printf '  %b注意这是一次瞬时采样。如果刚好抓到某个客户端的尖峰，这个数会偏高。%b\n' \
        "$DIM" "$RESET"
    fi
  else
    printf '
  %b当前没有活跃的入站连接，量不到。用 routetune scan 在有流量时看一次，%b
' "$DIM" "$RESET"
    printf '  %b或者按经验：同区域 100，跨洋 250-300。%b
' "$DIM" "$RESET"
  fi
  # Over-filling is not free on a small box, and this is the only place the
  # operator can see that trade before choosing.
  if tcpmem="$(tcp_mem_high_bytes)"; then
    printf '
  %b填大一点不是没有代价——它决定几条连接能同时吃满上限：%b
' "$DIM" "$RESET"
    local r ram clamp knee rneed
    ram="$(total_ram_bytes)"
    # The clamp is not a constant: since 0.9.1 the global budget grows with the
    # need, so it has to be evaluated at each RTT rather than once up front.
    # Computing it once was how this table came to disagree with buffer_ceiling.
    for r in 100 250 400; do
      buf="$(buffer_ceiling "$rate" "$r")"
      rneed=$(( $(bdp_bytes "$rate" "$r") * BDP_MULTIPLIER + BUF_SLACK ))
      clamp="$(socket_budget_cap "$ram" "$rneed")"
      printf '    %b%-4s ms → 上限 %5s MB/socket，约 %s 条满上限就触发全局 tcp_mem 压力%s%b
'         "$DIM" "$r" "$(mb "$buf")" "$(( tcpmem / (buf > 0 ? buf : 1) ))" \
        "$( (( ram > 0 && rneed > clamp )) && printf '  <- 已被内存夹住' )" "$RESET"
    done
    # Past this point the budget has grown as far as it will go (RAM/3), so the
    # per-socket cap stops moving. Ask for it by naming a need nothing can
    # satisfy, so the number comes from the same function that sizes buffers.
    clamp="$(socket_budget_cap "$ram" "$ram")"
    # Two identical rows in that table read as "it makes no difference", when
    # what they actually mean is that the RAM clamp is already binding. Say so
    # rather than leaving the operator to notice the numbers repeat.
    if (( ram > 0 && rate > 0 )); then
      if knee="$(buffer_knee_ms "$rate")"; then
        printf '\n  %b这台机器 %s MB 内存，单 socket 上限最多长到 %s MB%b\n' \
          "$DIM" "$(( ram / 1048576 ))" "$(mb "$clamp")" "$RESET"
        printf '  %b（全局 TCP 预算的 1/4；预算本身会跟着需求从内存的 1/4 长到 1/3）。%b\n' "$DIM" "$RESET"
        printf '  %b所以覆盖 RTT 填超过 %s ms 不会再增加缓冲了。%b\n' "$DIM" "$knee" "$RESET"
        # The honest version of "capped": say what the link would need, what
        # memory allows, and what single-flow rate that leaves. On a small box
        # with a fast port these genuinely cannot both be satisfied, and
        # silently capping is how that becomes a mystery instead of a choice.
        local need cap_rate
        need=$(( $(bdp_bytes "$rate" "$COVER_RTT_MS") * BDP_MULTIPLIER + BUF_SLACK ))
        cap_rate="$(awk -v c="$clamp" -v r="$COVER_RTT_MS" \
          -v d="$BDP_MULTIPLIER" 'BEGIN {printf "%.0f", c / d * 8 / (r / 1000) / 1e6}')"
        # Being clamped is not the same as being short. The ceiling carries a
        # 2xBDP + 2MiB margin, so it can be trimmed and still support more than
        # the port sells — announcing a shortfall there tells the operator their
        # machine cannot do something it comfortably can. Only a real gap talks.
        if (( need > clamp )) && (( cap_rate < rate * 85 / 100 )); then
          printf '\n  %b[!] %s Mbps × %s ms 本该要 %s MB 的上限，内存只给得起 %s MB。%b\n' \
            "$YELLOW" "$rate" "$COVER_RTT_MS" "$(mb "$need")" "$(mb "$clamp")" "$RESET"
          printf '  %b单流因此封顶在约 %s Mbps。内存不够是物理事实，不是配置错误——%b\n' \
            "$DIM" "$cap_rate" "$RESET"
          printf '  %b这台机器上「单流跑满 %s Mbps」和「多条大流并发」二选一。%b\n' \
            "$DIM" "$rate" "$RESET"
          # This number is only as honest as the RTT it was computed at. Filling
          # in a worst case far above the real client population manufactures a
          # shortfall that does not exist on any path the machine actually
          # serves — which is exactly how a box that clears a gigabit at 150ms
          # got declared a 545 Mbps box at 250ms.
          printf '  %b注意这个数是按你填的 %s ms 算的。覆盖 RTT 填得比真实客户端高，%b\n' \
            "$YELLOW" "$COVER_RTT_MS" "$RESET"
          printf '  %b就会凭空造出一个任何真实路径上都不存在的短缺——先确认 %s ms 是真的。%b\n' \
            "$DIM" "$COVER_RTT_MS" "$RESET"
        fi
      fi
    fi
  fi
  printf '
'
}

# Pasting a multi-line block leaves the later lines sitting in the terminal
# buffer, and the first prompt swallows one as if it were an answer. Throw away
# anything already waiting before the wizard starts asking.
drain_stdin() {
  [[ -t 0 ]] || return 0
  while read -r -t 0 2>/dev/null; do
    # shellcheck disable=SC2034 # the buffered line is deliberately discarded
    read -r -t 0.1 _junk 2>/dev/null || break
  done
  return 0
}

prompt_uint() {
  local prompt="$1" default="$2" min="$3" max="$4" value
  while true; do
    if ! read -r -p "  $prompt [$default]: " value; then printf '\n' >&2; return 1; fi
    # Trim surrounding whitespace and any stray carriage return: a terminal that
    # sends CRLF, or a pasted line with trailing spaces, would otherwise fail
    # the numeric test for reasons the operator cannot see.
    value="${value//$'\r'/}"
    value="$(awk '{$1 = $1; print}' <<< "$value")"
    value="${value:-$default}"
    [[ "$value" == q || "$value" == Q ]] && return 1
    if is_uint "$value" && (( value >= min && value <= max )); then
      printf '%s\n' "$value"; return 0
    fi
    warn "请输入 $min-$max 之间的整数（直接回车用默认值 $default，q 返回）"
  done
}

# ── 覆盖 RTT 的实测建议 ────────────────────────────────────────────────────

# The coverage RTT is the one number an operator cannot guess from their own
# latency, because it is a property of the FARTHEST client, not of the console
# they are typing into. So measure it rather than asking them to estimate.
#
# Prints "max<TAB>count" over inbound connections that have actually sent data.
# Idle sockets carry a stale rtt field that is not a path sample.
observed_client_rtt() {
  local ports
  has ss || return 1
  ports="$(ss -tlnH 2>/dev/null | awk '{
    for (i = NF; i >= 1; i--) if ($i ~ /:[0-9]+$/) {
      j = length($i); while (j > 0 && substr($i, j, 1) != ":") j--
      print substr($i, j + 1); break
    }
  }' | sort -u | tr '\n' ' ')" || return 1
  ss -tinH 2>/dev/null | awk -v listen=" $ports " '
    function portof(a,   i) {
      i = length(a); while (i > 0 && substr(a, i, 1) != ":") i--
      return (i > 0) ? substr(a, i + 1) : ""
    }
    /^[ \t]/ {
      if (local == "") next
      rtt = 0; sent = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^rtt:/) { s = substr($i, 5); p = index(s, "/")
          rtt = ((p > 0) ? substr(s, 1, p - 1) : s) + 0 }
        else if ($i ~ /^data_segs_out:/) sent = substr($i, 15) + 0
      }
      # Inbound only: a relay opens its own connections outward to CDNs and
      # origins, and those are not the client population being sized for.
      if (rtt > 0 && sent > 0 && index(listen, " " portof(local) " ") > 0) {
        n++; if (rtt > max) max = rtt
      }
      local = ""; next
    }
    { local = ""
      if (NF >= 5 && $1 ~ /^[A-Z][A-Z0-9_-]*$/) local = $4
      else if (NF >= 4) local = $3 }
    END { if (n > 0) printf "%.0f\t%d\n", max, n; else exit 1 }'
}

# A single flow can never exceed what the PEER is willing to receive: its
# advertised window divided by the round trip. Nothing on this machine changes
# that number, so when a single-flow test falls short of the line rate this is
# the first thing to rule out — otherwise the search goes looking for a
# server-side cause that does not exist.
#
# Prints "peer<TAB>rtt<TAB>windowbytes<TAB>ceilingmbps<TAB>observedmbps" for the
# fastest inbound connection.
peer_window_ceiling() {
  local ports
  has ss || return 1
  ports="$(ss -tlnH 2>/dev/null | awk '{
    for (i = NF; i >= 1; i--) if ($i ~ /:[0-9]+$/) {
      j = length($i); while (j > 0 && substr($i, j, 1) != ":") j--
      print substr($i, j + 1); break
    }
  }' | sort -u | tr '\n' ' ')" || return 1
  ss -tinH 2>/dev/null | awk -v listen=" $ports " -v floor="$LOCAL_RTT_SAMPLE_MS" \
      -v mbfloor="$SAMPLE_MBPS_FLOOR" '
    function portof(a,   i) {
      i = length(a); while (i > 0 && substr(a, i, 1) != ":") i--
      return (i > 0) ? substr(a, i + 1) : ""
    }
    function ipof(a,   i) {
      if (substr(a, 1, 1) == "[") { i = index(a, "]"); return (i > 2) ? substr(a, 2, i - 2) : a }
      i = length(a); while (i > 0 && substr(a, i, 1) != ":") i--
      return (i > 1) ? substr(a, 1, i - 1) : a
    }
    function tomb(v,   n) {
      n = v + 0
      if (v ~ /Gbps/) return n * 1000
      if (v ~ /Mbps/) return n
      if (v ~ /Kbps/) return n / 1000
      return n / 1000000
    }
    /^[ \t]/ {
      if (local == "") next
      rtt = 0; wnd = 0; rate = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^rtt:/) { s = substr($i, 5); p = index(s, "/")
          rtt = ((p > 0) ? substr(s, 1, p - 1) : s) + 0 }
        else if ($i ~ /^snd_wnd:/) wnd = substr($i, 9) + 0
        else if ($i == "delivery_rate" && i < NF) rate = tomb($(i + 1))
      }
      # Same-datacentre and loopback connections are not the client population.
      # A 0.6ms neighbour won the "fastest" contest and the panel then reported
      # that the buffer supports 303318 Mbps on it -- an arithmetically correct
      # number about a connection nobody is asking about.
      if (rtt >= floor && wnd > 0 && rate >= mbfloor && rate > best \
          && index(listen, " " portof(local) " ") > 0) {
        best = rate; brtt = rtt; bwnd = wnd; bpeer = ipof(peer)
      }
      local = ""; peer = ""; next
    }
    { local = ""; peer = ""
      if (NF >= 5 && $1 ~ /^[A-Z][A-Z0-9_-]*$/) { local = $4; peer = $5 }
      else if (NF >= 4) { local = $3; peer = $4 } }
    END {
      if (best <= 0) exit 1
      printf "%s\t%.1f\t%d\t%.1f\t%.1f\n", bpeer, brtt, bwnd, bwnd * 8 / (brtt * 1000), best
    }'
}

# Round the measurement up to a round number and keep a little headroom: a
# mobile client that was calm during the sample will not be calm later.
suggest_cover_rtt() {
  local row max n
  row="$(observed_client_rtt)" || return 1
  IFS=$'\t' read -r max n <<< "$row"
  is_uint "${max:-}" && (( max > 0 )) || return 1
  printf '%s\t%s\t%s\n' $(( (max * 12 / 10 + 49) / 50 * 50 )) "$max" "$n"
}

render_panel() {
  local buf tcpmem drift live_cc live_q cwnd_now p1=' ' p2=' ' p3=' ' p4=' '
  case "$PROFILE" in
    stable) p1='▸' ;; balanced) p2='▸' ;; speed) p3='▸' ;; noshape) p4='▸' ;;
  esac
  buf="$(buffer_ceiling "${EGRESS_MBPS:-200}" "$COVER_RTT_MS")"
  # The live value, not the computed one. These diverge whenever the safe
  # direction refuses a write — a smaller target under `raise` is silently kept
  # out — and a panel that prints the target as though it were running is
  # exactly how an analysis ends up resting on a number that never applied.
  local live_buf; live_buf="$(live_value net.core.rmem_max)"
  title 'tcpwide 调优面板'
  local fp; fp="$(config_fingerprint)"
  printf '  %b%s%b\n' "$DIM" "$fp" "$RESET"
  # The best run on record, and whether it is the one currently loaded. Eight
  # rounds of reconfiguration went by with no way to see this.
  local brow bm bf bn bw
  if brow="$(best_measurement)"; then
    IFS=$'\t' read -r bm bf bn bw <<< "$brow"
    if [[ "$bf" == "$fp" ]]; then
      printf '  %b历史最好 %s Mbps%b（%s%s）—— 就是当前这份配置%b\n' \
        "$GREEN" "$bm" "$DIM" "$bw" "$( [[ -n "$bn" ]] && printf '，%s' "$bn" )" "$RESET"
    else
      printf '  %b历史最好 %s Mbps%b（%s%s），配置是：%b\n' \
        "$YELLOW" "$bm" "$DIM" "$bw" "$( [[ -n "$bn" ]] && printf '，%s' "$bn" )" "$RESET"
      printf '  %b  %s%b\n' "$DIM" "$bf" "$RESET"
    fi
  fi
  render_verdict "${EGRESS_MBPS:-0}"
  printf '\n'
  if (( SHAPE == 1 )); then
    printf '  %b出口带宽%b   %s Mbps%b（整形到 %s%% = %s Mbps）%b\n' "$DIM" "$RESET" \
      "${EGRESS_MBPS:-未设置}" "$DIM" "$SHAPE_PCT" \
      "$(( ${EGRESS_MBPS:-0} * SHAPE_PCT / 100 ))" "$RESET"
  else
    printf '  %b出口带宽%b   %s Mbps%b（不整形，只做 pacing）%b\n' "$DIM" "$RESET" \
      "${EGRESS_MBPS:-未设置}" "$DIM" "$RESET"
  fi
  printf '  %b覆盖 RTT%b   %s ms%b  ← 按最远的客户端，不是按你自己%b\n' \
    "$DIM" "$RESET" "$COVER_RTT_MS" "$DIM" "$RESET"
  live_cc="$(live_value net.ipv4.tcp_congestion_control)"
  printf '  %b拥塞控制%b   %s' "$DIM" "$RESET" "${live_cc:-未知}"
  [[ "$live_cc" == bbr ]] && printf '%b（主线只有 v1，容量剧变后估值滞后）%b' "$DIM" "$RESET"
  [[ "$live_cc" == cubic ]] && printf '%b（每丢一次砍一次窗，无线链路上起不来）%b' "$YELLOW" "$RESET"
  printf '\n'
  # The raw dump is ~200 characters of kernel defaults, so it was cut to 58 and
  # ended mid-word ("...flow_limit 2048p bucke"). The canonical form is the same
  # information the fingerprint uses and fits without truncation.
  live_q="$(canonical_qdisc 2>/dev/null)"
  printf '  %b根队列%b     %s\n' "$DIM" "$RESET" "${live_q:-未知}"
  local show_buf="$buf"; [[ -z "$live_buf" ]] || show_buf="$live_buf"
  printf '  %b缓冲上限%b   %s MB/socket' "$DIM" "$RESET" "$(mb "$show_buf")"
  if tcpmem="$(tcp_mem_high_bytes)"; then
    printf '%b ｜ 全局 tcp_mem 高水位 %s MB（约 %s 条满上限就触发压力）%b' \
      "$DIM" "$(mb "$tcpmem")" "$(( tcpmem / (buf > 0 ? buf : 1) ))" "$RESET"
  fi
  printf '\n'
  # A route without the metric makes grep exit 1, which under pipefail takes
  # the whole panel down mid-render rather than reporting the kernel default.
  if [[ -n "$live_buf" && "$live_buf" != "$buf" ]]; then
    printf '  %b            目标是 %s MB —— 目标更小时不会下调（上限只升不降）%b\n' \
      "$DIM" "$(mb "$buf")" "$RESET"
  fi
  cwnd_now="$(current_default_route | awk '{for (i = 1; i < NF; i++) if ($i == "initcwnd") {print $(i + 1); exit}}')"
  printf '  %b首窗%b       initcwnd %s%b（内核默认 10）%b\n' "$DIM" "$RESET" \
    "${cwnd_now:-10}" "$DIM" "$RESET"
  printf '  %b持久化%b     %s\n' "$DIM" "$RESET" \
    "$( [[ -e "$PERSIST_SYSCTL" ]] && printf '是' || printf '否（重启后失效）' )"
  if drift="$(qdisc_drift)"; then
    printf '  %b[!] 实际生效的队列是 %s，与配置不一致%b\n' "$YELLOW" "$drift" "$RESET"
    printf '      %b可能是重启后没应用，或被别的服务覆盖。按 a 重新应用%b\n' "$DIM" "$RESET"
  fi
  local cpu_row cores rate
  if cpu_row="$(shaping_cpu_warning "${EGRESS_MBPS:-0}")"; then
    IFS=$'\t' read -r cores rate <<< "$cpu_row"
    printf '  %b[!] %s 核整形 %s Mbps 可能是 CPU 瓶颈——单线程掉速时先用 4) 不整形 对照%b\n' \
      "$YELLOW" "$cores" "$rate" "$RESET"
  fi
  if (( SHAPE == 1 )); then
    printf '  %b注：整形按定义会让出 %s%% 峰值，而按设备公平对单线程测速没有帮助。%b\n' \
      "$DIM" "$(( 100 - SHAPE_PCT ))" "$RESET"
    printf '  %b    单线程跑分是这套设计主动交换掉的那一面；多设备并发才是它换来的东西。%b\n' \
      "$DIM" "$RESET"
  fi
  local other
  if other="$(conflicting_tool)"; then
    printf '  %b[!] 检测到 %s —— 它同样接管根队列和全局 sysctl，谁后跑谁生效%b\n' \
      "$YELLOW" "$other" "$RESET"
  fi
  rule
  printf '  %b档位%b%b                                          ▸ 当前%b\n' \
    "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b%s%b %b1)%b 整形 90%%    首窗 16%b  丢包敏感、跨境线路%b\n' \
    "$GREEN" "$p1" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b%s%b %b2)%b 整形 95%%    首窗 20%b  多设备共享，要按设备公平%b\n' \
    "$GREEN" "$p2" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b%s%b %b3)%b 整形 98%%    首窗 32%b  几乎等于不整形，却付全额 CAKE 开销%b\n' \
    "$GREEN" "$p3" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b%s%b %b4)%b 不整形      首窗 20%b  只做 pacing；CPU 不够时这是最快的%b\n' \
    "$GREEN" "$p4" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b设置%b\n' "$BOLD" "$RESET"
  printf '    %b5)%b 出口带宽%b（当前 %s Mbps）%b   %b6)%b 覆盖 RTT%b（当前 %s ms）%b   %b7)%b 首窗%b（当前 %s）%b\n' \
    "$BOLD" "$RESET" "$DIM" "${EGRESS_MBPS:-未设置}" "$RESET" \
    "$BOLD" "$RESET" "$DIM" "$COVER_RTT_MS" "$RESET" \
    "$BOLD" "$RESET" "$DIM" "$INITCWND" "$RESET"
  printf '    %bn)%b 未发送数据上限 notsent_lowat%b（当前 %s，实测胜 16384 四成；更大的还没试）%b\n' \
    "$BOLD" "$RESET" "$DIM" \
    "$( (( NOTSENT_LOWAT > 0 )) && printf '%s' "$NOTSENT_LOWAT" || printf '不改' )" "$RESET"
  printf '    %bb)%b 缓冲上限%b（当前 %s，接收窗口是它的一半，直接决定单流上限）%b\n' \
    "$BOLD" "$RESET" "$DIM" \
    "$( (( BUF_MB > 0 )) && printf '%s MB（手动）' "$BUF_MB" || printf '自动 %s MB' "$(mb "$(buffer_ceiling "${EGRESS_MBPS:-500}" "$COVER_RTT_MS")")" )" \
    "$RESET"
  printf '  %b查看与工具%b\n' "$BOLD" "$RESET"
  printf '    %b8)%b 状态与诊断（实时重传率、队列、冲突）\n' "$BOLD" "$RESET"
  printf '    %b9)%b 预演（逐项列出 当前值 → 目标值 和理由）\n' "$BOLD" "$RESET"
  printf '    %bm)%b 记一次实测%b（跑完测速把数字填进来，和配置绑在一起）%b\n' \
    "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '    %bs)%b 单流旋钮%b（notsent_lowat / fq 参数 / BBRv3，都还没测过）%b\n' \
    "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '    %bl)%b 队列布局%b（当前：%s%s）%b\n' "$BOLD" "$RESET" "$DIM" \
    "$QDISC_LAYOUT" \
    "$( [[ "$QDISC_LAYOUT" == root ]] && printf '，有实测支撑' || printf '，未经实测' )" \
    "$RESET"
  printf '    %ba)%b 重新应用（重启后或队列被覆盖时用）\n' "$BOLD" "$RESET"
  printf '    %bp)%b 持久化开关%b（当前：%s）%b\n' "$BOLD" "$RESET" "$DIM" \
    "$( [[ -e "$PERSIST_SYSCTL" ]] && printf '开' || printf '关' )" "$RESET"
  printf '    %br)%b 完整还原到 tcpwide 介入之前\n' "$BOLD" "$RESET"
  printf '    %b0)%b 退出\n' "$BOLD" "$RESET"
  rule
}

# Actions run in a subshell so one that calls die drops back to the menu instead
# of closing the panel. Everything durable goes through save_config, and the
# loop reloads it, so nothing is lost across the boundary.
run_action() { ( "$@" ) || warn "操作未完成，已返回菜单"; }

pause_menu() {
  [[ -t 0 ]] || return 0
  printf '\n'
  # shellcheck disable=SC2034 # the reply is deliberately discarded
  read -r -p "  $(printf '%b按回车返回菜单…%b' "$DIM" "$RESET")" _discard || printf '\n'
}

panel_set_profile() {
  apply_profile "$1" || die "未知档位"
  save_config
  log "已切换到「$(profile_label "$PROFILE")」，正在应用…"
  cmd_apply
}

panel_reapply() { cmd_apply; }

panel_diagnose() {
  title 'tcpwide 诊断'
  local pct drift other
  printf '  %b正在采样 5 秒的实时重传率…%b\n' "$DIM" "$RESET"
  local rc=0
  pct="$(retrans_rate 5)" || rc=$?
  if (( rc == 0 )); then
    printf '  实时重传率:        %s%%%b（5 秒窗口增量，不是自开机累计）%b\n' "$pct" "$DIM" "$RESET"
    if awk -v p="$pct" 'BEGIN {exit !(p >= 2)}'; then
      # The advice has to match the profile that is running. Telling someone on
      # the no-shape profile to "check the queue is really cake" sends them to
      # undo the setting that is correct for their machine.
      if (( SHAPE == 1 )); then
        warn "重传偏高。先确认根队列真的是 cake（有 pacing），再看是不是客户端侧无线丢包"
      else
        warn "重传偏高。fq maxrate 已经在给每条流限速，所以先看客户端侧无线丢包和上游线路"
      fi
    fi
  elif (( rc == 2 )); then
    printf '  实时重传率:        %b样本太少，不作判断%b（5 秒内不足 %s 个报文，一次重传就能读成 2%%）\n' \
      "$DIM" "$RESET" "$RETRANS_MIN_SEGS"
    printf '  %b要测这个数，就在跑测速的同时进来看。%b\n' "$DIM" "$RESET"
  else
    printf '  实时重传率:        无法采样（缺少 nstat 或窗口内没有流量）\n'
  fi
  local bc bmax bavg bcores bsteal
  printf '  %b正在采样 5 秒的每核占用…%b\n' "$DIM" "$RESET"
  if bc="$(busiest_core_pct 5)"; then
    IFS=$'\t' read -r bmax bavg bcores bsteal <<< "$bc"
    printf '  CPU（5 秒窗口）:   最忙的核 %s%%｜%s 核平均 %s%%｜steal 峰值 %s%%\n' \
      "$bmax" "$bcores" "$bavg" "$bsteal"
    if (( bmax >= 85 )) && (( bavg < 70 )); then
      warn "有单核接近打满而平均只有 ${bavg}% —— 单条连接在用户态代理里基本只用得到一个核"
      printf '    %b这个天花板和 RTT 无关，所以调缓冲、调窗口都不会让它变快。%b\n' "$DIM" "$RESET"
      printf '    %b验证：多线程测速。多线程能上去 = 每流受 CPU 限，服务端配置没问题。%b\n' "$DIM" "$RESET"
    elif (( bmax >= 85 )); then
      warn "所有核都接近打满 —— 这台机器的转发能力本身就到顶了"
    fi
    if (( bsteal >= 10 )); then
      warn "steal ${bsteal}% —— 宿主机超售，这部分算力买不回来，调什么都没用"
    fi
  else
    printf '  CPU（5 秒窗口）:   无法采样\n'
  fi
  local win peer wrtt wbytes wceil wobs
  if ! win="$(peer_window_ceiling)"; then
    printf '\n  %b没有 %s ms 以外的活跃入站连接可看。%b\n' "$DIM" "$LOCAL_RTT_SAMPLE_MS" "$RESET"
    printf '  %b同机房和本地连接不是你的客户端，拿它们算单流上限只会得到无意义的大数。%b\n' \
      "$DIM" "$RESET"
  fi
  if [[ -n "${win:-}" ]]; then
    IFS=$'\t' read -r peer wrtt wbytes wceil wobs <<< "$win"
    printf '\n  %b最快的那条连接：%s%b\n' "$BOLD" "$peer" "$RESET"
    printf '    RTT %s ms｜对端通告窗口 %s MB｜实测 %s Mbps\n' \
      "$wrtt" "$(mb "$wbytes")" "$wobs"
    local hd hsup hpct
    if hd="$(window_headroom "$wrtt" "$wobs")"; then
      IFS=$'\t' read -r hsup _ hpct <<< "$hd"
      printf '    %b本机缓冲在这条 %s ms 上支持 %s Mbps，实测只用到 %s%%%b\n' \
        "$BOLD" "$wrtt" "$hsup" "$hpct" "$RESET"
      if (( hpct < 75 )); then
        printf '    %b→ 缓冲还有余量，它不是瓶颈。再往大调不会变快，先看上面的 CPU。%b\n' \
          "$YELLOW" "$RESET"
      else
        printf '    %b→ 已经贴着缓冲上限跑，加大覆盖 RTT 或缓冲上限有望继续涨。%b\n' \
          "$DIM" "$RESET"
      fi
    fi
    printf '    %b对端窗口决定的单流上限：%s Mbps%b\n' "$BOLD" "$wceil" "$RESET"
    printf '    %b单流不会超过「对端愿意收多少 ÷ 往返时间」。但对端窗口是自动伸缩的：%b\n' \
      "$DIM" "$RESET"
    printf '    %b我们推得多快它就长到多大，所以这两个数吻合既可能是对端封顶，也可能只是%b\n' \
      "$DIM" "$RESET"
    printf '    %b它跟着我们的发送量长到那儿。这是一条要排除的可能，不是结论——%b\n' \
      "$DIM" "$RESET"
    printf '    %b真正判定看多线程：多线程到线速而单线程到不了，才是对端窗口的锅。%b\n' \
      "$DIM" "$RESET"
  fi
  printf '\n  %b跨后端判据（拿几个 RTT 差得远的后端各测一次）：%b\n' "$BOLD" "$RESET"
  printf '    %b受窗口限 → 速率 ∝ 1/RTT，RTT 大的明显慢。%b\n' "$DIM" "$RESET"
  printf '    %b受 CPU 限 → 各后端峰值几乎一样，跟 RTT 没关系。%b\n' "$DIM" "$RESET"
  printf '\n  根队列:            %s\n' \
    "$(tc qdisc show dev "$IFACE" 2>/dev/null | sed -n '1p' | sed 's/^qdisc //')"
  if drift="$(qdisc_drift)"; then
    warn "实际是 $drift，与配置不一致 —— 按 a 重新应用"
  else
    log "队列与配置一致"
  fi
  printf '  默认路由:          %s\n' "$(current_default_route)"
  if other="$(conflicting_tool)"; then
    warn "检测到 $other，它会盖掉这里的配置"
  else
    log "没有检测到冲突的调优工具"
  fi
  render_window_ratio
  render_window_report
  printf '\n'
  render_plan "${EGRESS_MBPS:-200}" "$COVER_RTT_MS"
}

# The three single-flow levers, grouped so an A/B is a couple of keypresses
# rather than a reinstall. All three are hypotheses: the panel says so, and
# `record` is what settles them.
panel_single_flow() {
  title '单流旋钮（都还没测过）'
  printf '  %b多线程已经能跑满端口时，下面这些是单流仅剩的几个杠杆。%b\n' "$DIM" "$RESET"
  printf '  %b每改一个就 A/B/A 测一次并 record，别一次改两个。%b\n\n' "$DIM" "$RESET"
  printf '    %b1)%b tcp_notsent_lowat   当前 %s\n' "$BOLD" "$RESET" \
    "$(live_value net.ipv4.tcp_notsent_lowat)"
  printf '       %b558 Mbps 下 128KB 只有 1.8ms 的数据。单核机器上代理的调度抖动%b\n' "$DIM" "$RESET"
  printf '       %b一旦超过这个数就会饿死网卡。岳阳 201ms 直接对照：131072 峰值 568，%b\n' "$DIM" "$RESET"
  printf '       %b16384 只有 341（低 40%%）。方向明确是越大越好，但上界还没找到——%b\n' "$DIM" "$RESET"
  printf '       %b下一个该试的是 262144 和 524288。%b\n' "$DIM" "$RESET"
  printf '       %bnetshape 在 RTT≥120ms 时反而用 16384。那条建议在这条路径上已被证伪：%b\n' "$DIM" "$RESET"
  printf '       %b131072 这一档 13 分钟内两次测得 580/568，16384 比两次都低四成。%b\n' "$DIM" "$RESET"
  printf '    %b2)%b fq initial_quantum  当前 %s%b（0 = 用内核的 15140b）%b\n' "$BOLD" "$RESET" \
    "$FQ_INITIAL_QUANTUM" "$DIM" "$RESET"
  printf '    %b3)%b fq flow_limit       当前 %s%b（0 = 用内核的 100p，约 3ms 数据）%b\n' "$BOLD" "$RESET" \
    "$FQ_FLOW_LIMIT" "$DIM" "$RESET"
  printf '    %b4)%b BBRv3 怎么上（只给方法，不替你装）\n' "$BOLD" "$RESET"
  printf '    %b0)%b 返回\n\n' "$BOLD" "$RESET"
  local pick value
  read -r -p '  请选择 [0]: ' pick || return 0
  case "${pick:-0}" in
    1) if value="$(prompt_uint 'tcp_notsent_lowat（0=不动，试 262144 / 524288）' \
           "$NOTSENT_LOWAT" 0 16777216)"; then
         NOTSENT_LOWAT="$value"; save_config; cmd_apply
       else info "已取消"; fi ;;
    2) if value="$(prompt_uint 'initial_quantum 字节（0=用内核的，试 65536）' \
           "$FQ_INITIAL_QUANTUM" 0 1048576)"; then
         FQ_INITIAL_QUANTUM="$value"; save_config; cmd_apply
       else info "已取消"; fi ;;
    3) if value="$(prompt_uint 'flow_limit 包数（0=用内核的，试 500）' \
           "$FQ_FLOW_LIMIT" 0 100000)"; then
         FQ_FLOW_LIMIT="$value"; save_config; cmd_apply
       else info "已取消"; fi ;;
    4) explain_bbr3 ;;
    *) return 0 ;;
  esac
}

# Mainline has only ever carried BBRv1. v3 means a different kernel, which is a
# reboot and a real risk on a box that is serving traffic -- so this prints the
# path and the way back out, and does not run any of it. Installing a kernel on
# someone's production machine is not something a tuning script should do
# quietly, however much the operator wants the throughput.
explain_bbr3() {
  title 'BBRv3'
  printf '  %b当前内核：%s%b\n' "$DIM" "$(uname -r)" "$RESET"
  printf '  %b拥塞控制：%s%b\n\n' "$DIM" "$(live_value net.ipv4.tcp_congestion_control)" "$RESET"
  printf '  %b主线内核只有 BBRv1，而且一直只会有 v1。XanMod 以「bbr」这个名字发 v3，%b\n' "$DIM" "$RESET"
  printf '  %b所以看名字分不出版本，只能看内核版本串。%b\n\n' "$DIM" "$RESET"
  printf '  %bv1 单流吃亏最重的地方：ProbeRTT 每 10 秒把 cwnd 砸到 4 个包并保持 200ms。%b\n' "$DIM" "$RESET"
  printf '  %bv3 改成只降到一半，并且会对丢包做出反应。单流受益最明显。%b\n\n' "$DIM" "$RESET"
  printf '  %b换内核（Debian/Ubuntu）：%b\n' "$BOLD" "$RESET"
  printf '    curl -fsSL https://dl.xanmod.org/archive.key | gpg --dearmor -o /usr/share/keyrings/xanmod.gpg\n'
  printf '    echo "deb [signed-by=/usr/share/keyrings/xanmod.gpg] http://deb.xanmod.org releases main" > /etc/apt/sources.list.d/xanmod.list\n'
  printf '    apt update && apt install linux-xanmod-x64v2\n'
  printf '    reboot\n\n'
  printf '  %b回滚：%b重启时在 grub 菜单选 Advanced options 里的旧内核；%b\n' "$BOLD" "$RESET" "$DIM"
  printf '  确认旧内核能起来之后再 apt remove 掉 xanmod。%b\n\n' "$RESET"
  printf '  %b[!] 这台机器 520 MB 内存，/boot 也可能装不下第二个内核——先 df -h /boot。%b\n' \
    "$YELLOW" "$RESET"
  printf '  %b[!] 换完内核 tcpwide 的 sysctl 不会自动回来（没加 --persist 的话），%b\n' \
    "$YELLOW" "$RESET"
  printf '  %b    重启后要重新 sudo tcpwide apply。%b\n' "$DIM" "$RESET"
}

panel_record() {
  local mbps note
  read -r -p '  刚测到多少 Mbps（峰值，q 返回）: ' mbps || return 0
  [[ "$mbps" =~ ^[qQ]$ || -z "$mbps" ]] && { info "已取消"; return 0; }
  read -r -p '  备注（后端名字之类，可留空）: ' note || note=''
  local threads rtt
  read -r -p '  几个线程（默认 1）: ' threads || threads=1
  is_uint "${threads:-}" && (( threads > 0 )) || threads=1
  read -r -p '  这次测速的 RTT（ms，测速面板上那个延迟；留空跳过）: ' rtt || rtt=0
  [[ "${rtt:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || rtt=0
  record_measurement "$mbps" "$note" "$threads" "$rtt" \
    || { warn "需要一个数字，例：629.1"; return 0; }
  log "已记录 $mbps Mbps（${threads} 线程），和当前配置绑在一起了"
  [[ "$rtt" == 0 ]] && warn "没填 RTT，这条进不了窗口分析"
  render_verdict "${EGRESS_MBPS:-0}"
  render_window_ratio
  render_window_report
}

# The layout is a knob rather than a decision so it can be A/B'd on the machine
# that actually cares. Flipping it re-applies, so an A/B/A run is three presses.
panel_toggle_layout() {
  if [[ "$QDISC_LAYOUT" == root ]]; then
    QDISC_LAYOUT=mq-leaves
    warn "切到 mq 挂叶子。这是没有实测支撑的那个布局——0.10.0 把它设成默认时三个后端齐掉 44%"
  else
    QDISC_LAYOUT=root
    log "切回根 fq（有实测支撑的布局）"
  fi
  save_config
  cmd_apply
}

panel_toggle_persist() {
  if [[ -e "$PERSIST_SYSCTL" ]]; then
    rm -f "$PERSIST_SYSCTL"
    if [[ -e "$PERSIST_UNIT" ]]; then
      systemctl disable tcpwide-link.service >/dev/null 2>&1 || true
      rm -f "$PERSIST_UNIT"; systemctl daemon-reload 2>/dev/null || true
    fi
    PERSIST=0; save_config
    log "已关闭持久化。重启后会回到系统原样"
  else
    PERSIST=1; save_config
    write_persistence "${EGRESS_MBPS:-200}" "$COVER_RTT_MS"
  fi
}

menu() {
  [[ -t 0 ]] || { usage; return 0; }
  local answer value
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    warn "当前不是 root，面板为只读模式；要修改请运行：sudo $PROGRAM"
  fi
  resolve_iface
  while true; do
    load_config
    render_panel
    if ! read -r -p '  请选择 [0-9 / a / b / n / p / r]: ' answer; then printf '\n'; return 0; fi
    case "$answer" in
      1) run_action panel_set_profile stable ;;
      2) run_action panel_set_profile balanced ;;
      3) run_action panel_set_profile speed ;;
      4) run_action panel_set_profile noshape ;;
      5)
        if value="$(prompt_uint '出口带宽（Mbps，按你套餐的实际端口速率，q 返回）' "${EGRESS_MBPS:-500}" 1 100000)"; then
          EGRESS_MBPS="$value"; PROFILE=custom; save_config; run_action cmd_apply
        else info "已取消"; continue; fi
        ;;
      6)
        explain_cover_rtt "${EGRESS_MBPS:-500}"
        if value="$(prompt_uint '覆盖 RTT（ms，q 返回）' "$COVER_RTT_MS" 10 2000)"; then
          COVER_RTT_MS="$value"; save_config; run_action cmd_apply
        else info "已取消"; continue; fi
        ;;
      7)
        if value="$(prompt_uint '默认路由首窗 initcwnd（内核默认 10，q 返回）' "$INITCWND" 1 64)"; then
          INITCWND="$value"; PROFILE=custom; save_config; run_action cmd_apply
        else info "已取消"; continue; fi
        ;;
      n|N)
        printf '  %b小=低延迟（seek 更跟手），大=给代理进程更多喂数据的余量。%b\n' "$DIM" "$RESET"
        printf '  %b真机 A/B/A 夹逼对照：131072 比 16384 高 18%%（均）/11%%（峰）。%b\n' "$DIM" "$RESET"
        printf '  %b131072 已实测胜 16384 四成，往下调只会更慢。填 0 = 保持系统现值。%b\n' "$DIM" "$RESET"
        if value="$(prompt_uint 'notsent_lowat 字节（0=不改，q 返回）' "$NOTSENT_LOWAT" 0 16777216)"; then
          NOTSENT_LOWAT="$value"; save_config; run_action cmd_apply
        else info "已取消"; continue; fi
        ;;
      b|B)
        printf '  %b接收窗口 ≈ 缓冲上限 ÷ %s（实测比例），单流上限 = 窗口 ÷ RTT。%b\n' \
          "$DIM" "$BDP_MULTIPLIER" "$RESET"
        local bw
        for bw in 16 32 64; do
          printf '    %b%2s MB → 窗口 %2s MB → %3.0f Mbps @160ms，%3.0f Mbps @%sms%b\n' \
            "$DIM" "$bw" "$((bw / 2))" \
            "$(awk -v b="$bw" -v d="$BDP_MULTIPLIER" 'BEGIN {print b * 1048576 / d * 8 / 0.160 / 1e6}')" \
            "$(awk -v b="$bw" -v r="$COVER_RTT_MS" -v d="$BDP_MULTIPLIER" 'BEGIN {print b * 1048576 / d * 8 / (r / 1000) / 1e6}')" \
            "$COVER_RTT_MS" "$RESET"
        done
        printf '  %b填 0 = 自动推导（会被 netshape 的内存档位夹住）。往大调之前先确认 fq maxrate 生效，%b\n' \
          "$DIM" "$RESET"
        printf '  %b否则大缓冲会让 BBR 攒出巨大 cwnd，超发被丢、重传爆掉。%b\n' "$DIM" "$RESET"
        if value="$(prompt_uint '缓冲上限 MB（0=自动，q 返回）' "$BUF_MB" 0 512)"; then
          BUF_MB="$value"; save_config; run_action cmd_apply
        else info "已取消"; continue; fi
        ;;
      8) run_action panel_diagnose ;;
      9) run_action cmd_plan ;;
      m|M) run_action panel_record ;;
      s|S) run_action panel_single_flow ;;
      l|L) run_action panel_toggle_layout ;;
      a|A) run_action panel_reapply ;;
      p|P) run_action panel_toggle_persist ;;
      r|R) run_action cmd_revert ;;
      0|q|Q) return 0 ;;
      *) warn "无效选项"; continue ;;
    esac
    pause_menu
  done
}

# ── 安装 ───────────────────────────────────────────────────────────────────

cmd_install() {
  need_root install
  local other value answer interactive=1
  # Piped into bash, stdin IS the script: a prompt would read the next line of
  # source as the operator's answer. So when there is no terminal, every value
  # has to come from flags instead of being asked for.
  [[ -t 0 ]] || interactive=0
  if (( interactive == 0 )) && [[ -z "$EGRESS_MBPS" ]]; then
    die "非交互安装需要 --egress <Mbps>。想要向导就先把脚本落到磁盘：
       curl -fsSL $SOURCE_URL -o /tmp/tcpwide.sh && sudo bash /tmp/tcpwide.sh install"
  fi
  title 'tcpwide 安装向导'
  if other="$(conflicting_tool)"; then
    warn "检测到 $other"
    printf '  %b它和 tcpwide 都会接管根队列和全局 sysctl，不是叠加关系，是谁后跑谁生效。%b\n' \
      "$DIM" "$RESET"
    printf '  %b请先卸载它，再回来装 tcpwide：%b\n' "$DIM" "$RESET"
    printf '      %bsudo %s uninstall%b\n' "$BOLD" "$other" "$RESET"
    # Uninstalling belongs to the other tool: it knows what it changed (its own
    # HTB classes, nginx snippet, units, sysctl snapshot) and tcpwide would be
    # guessing.
    die "已中止，什么都没有改"
  fi
  has tc || die "缺少 tc；请安装 iproute2"
  has sysctl || die "缺少 sysctl"
  resolve_iface
  printf '  出口网卡：%s\n' "$IFACE"
  printf '  内核拥塞控制：%s → 将选用 %s\n\n' "$(available_cc)" "$(pick_cc "$(available_cc)")"
  local sug_rtt=250 row
  if (( interactive == 1 )); then
    drain_stdin
    value="$(prompt_uint '这台机器的出口带宽（Mbps，按你套餐的端口速率）' "${EGRESS_MBPS:-500}" 1 100000)" \
      || die "已取消安装"
    EGRESS_MBPS="$value"
    printf '\n'
    explain_cover_rtt "$EGRESS_MBPS"
    if row="$(suggest_cover_rtt)"; then sug_rtt="$(cut -f1 <<< "$row")"; fi
    value="$(prompt_uint '覆盖 RTT（ms）' "$sug_rtt" 10 2000)" || die "已取消安装"
  else
    # Measured if there is traffic to measure, otherwise the documented default.
    if row="$(suggest_cover_rtt)"; then sug_rtt="$(cut -f1 <<< "$row")"; fi
    value="$COVER_RTT_MS"
    [[ "$COVER_RTT_MS" == 250 ]] && value="$sug_rtt"
    info "非交互安装：出口 ${EGRESS_MBPS} Mbps，覆盖 RTT ${value} ms，档位 $(profile_label "$PROFILE")"
  fi
  COVER_RTT_MS="$value"
  if (( interactive == 1 )); then
    # The default comes from the machine, not from a constant. Recommending a
    # CAKE profile on a box whose cores cannot shape the port is how this one
    # ended up on `cake bandwidth 980Mbit` at half the throughput `fq` gave it.
    local dflt=2 tight=0
    if cake_over_budget "$EGRESS_MBPS"; then dflt=4; tight=1; fi
    printf '\n  %b档位%b\n' "$BOLD" "$RESET"
    printf '    1) 整形 90%%    首窗 16   丢包敏感、跨境线路\n'
    printf '    2) 整形 95%%    首窗 20   多设备共享，要按设备公平\n'
    printf '    3) 整形 98%%    首窗 32   几乎等于不整形，却付全额 CAKE 开销\n'
    printf '    4) 不整形      首窗 20   只做 pacing；CPU 不够时这是最快的\n'
    if (( tight == 1 )); then
      printf '\n  %b[!] 这台机器 %s 核，整形 %s Mbps 超出 CAKE 的处理能力%b\n' \
        "$YELLOW" "$(cpu_count)" "$EGRESS_MBPS" "$RESET"
      printf '  %b实测同一台机器同一后端：fq 峰值 629 Mbps，CAKE 峰值 332 Mbps。%b\n' \
        "$DIM" "$RESET"
      printf '  %b所以默认给 4。真要按设备公平，选 2——会自动加 no-split-gso 降开销。%b\n' \
        "$DIM" "$RESET"
    fi
    read -r -p "  请选择 [$dflt]: " answer || answer="$dflt"
    case "${answer:-$dflt}" in
      1) apply_profile stable ;; 2) apply_profile balanced ;;
      3) apply_profile speed ;;  4) apply_profile noshape ;;
      *) if (( dflt == 4 )); then apply_profile noshape
         else apply_profile balanced; fi ;;
    esac
  fi
  save_config
  printf '\n'
  cmd_apply
  mkdir -p "$(dirname "$INSTALL_PATH")"
  local src; src="$(self_source)" || src=""
  if [[ -n "$src" ]] && cp -f "$src" "$INSTALL_PATH" 2>/dev/null; then
    chmod 0755 "$INSTALL_PATH"
    ln -sfn "$INSTALL_PATH" "$CLI_PATH"
    log "已安装。以后直接运行 sudo tcpwide 进面板"
  else
    warn "无法复制脚本到 $INSTALL_PATH，软链未创建"
    printf '  %b先落到磁盘再装最稳（也避免 sudo 关掉进程替换的 fd）：%b\n' "$DIM" "$RESET"
    printf '      %bcurl -fsSL %s -o /tmp/tcpwide.sh && sudo bash /tmp/tcpwide.sh install%b\n' \
      "$BOLD" "$SOURCE_URL" "$RESET"
  fi
}

cmd_uninstall() {
  need_root uninstall
  cmd_revert
  rm -f "$CONFIG_FILE" "$CLI_PATH" "$INSTALL_PATH"
  rmdir "$(dirname "$INSTALL_PATH")" 2>/dev/null || true
  log "已卸载 tcpwide 并还原配置"
}

usage() {
  cat <<'EOF'
tcpwide - 面向多地区、多设备客户端的一套 TCP 配置（SSH 面板）

一键安装（进向导）：
  curl -fsSL https://raw.githubusercontent.com/bear4f/routetune/main/tcpwide/tcpwide.sh -o /tmp/tcpwide.sh && sudo bash /tmp/tcpwide.sh install

一键安装（不进向导，直接给参数）：
  curl -fsSL https://raw.githubusercontent.com/bear4f/routetune/main/tcpwide/tcpwide.sh | sudo bash -s -- install --egress 500 --profile noshape

之后直接进面板：
  sudo tcpwide

两条不能互换，各有各的坑：

  sudo bash <(curl …)  ——  不要用。sudo 默认关掉 2 号以上的文件描述符，而 <(…) 造出来的
                           /dev/fd/63 属于外层 shell，sudo bash 启动时它已经没了，
                           报 "No such file or directory"。已经是 root 时去掉 sudo 才行。

  curl … | sudo bash   ——  stdin 就是脚本本身，向导提问会把脚本下一行当成你的回答读走。
                           所以这条必须用 --egress 把参数给全（缺了会直接报错）。

分散的客户端不需要「每个客户端一套参数」。它需要一套按最远客户端定尺寸的配置，
再用能自己适应其余客户端的机制搭起来：

  pacing        突发不会按线速灌进最慢那条末端链路
  BBR           不把随机无线丢包当拥塞信号
  AQM           真的排起队时是被管理的，不是尾部直接丢
  按设备公平    一台开 40 条连接的设备挤不掉只开 1 条的那台

它刻意不做的事：不设单流限速。按固定宽带调的限速会勒死固定宽带，而对移动客户端
根本不会触发——它本来也没跑那么快。

  tcpwide                              进面板（等同 tcpwide panel）
  tcpwide install                      安装向导
  tcpwide uninstall                    还原并卸载
  tcpwide check                        看内核支不支持、有没有冲突的工具
  tcpwide plan --egress 500            预演，什么都不改
  tcpwide apply --egress 500           应用（先快照，可完整还原）
  tcpwide apply --egress 500 --persist 应用并持久化（重启仍在）
  tcpwide status                       当前状态
  tcpwide record <Mbps> [备注] [--threads N] [--rtt MS]
                                       记下一次实测，和当前配置绑在一起
                                       多线程结果一定要加 --threads，它和单线程
                                       回答的是两个不同的问题
  tcpwide revert                       完整还原到 tcpwide 介入之前

参数：
  --egress <Mbps>    出口带宽。整形必须知道这个数
  --cover-rtt <ms>   覆盖 RTT，默认 250。按你最远的客户端填，不是按你自己
  --initcwnd <N>     默认路由首窗，默认 20（内核默认是 10）
  --shape-pct <N>    整形到出口带宽的百分之多少，默认 95
  --iface <名字>     出口网卡，默认自动探测
  --profile <名字>   stable | balanced | speed | noshape
  --buf-mb <N>       缓冲上限 MB，0=自动
  --no-shape         不接管根队列，只做 pacing。放弃按设备公平和 AQM
  --persist          写 /etc/sysctl.d 和 systemd unit
  --yes              检测到冲突工具时仍然继续

为什么必须整形才能拿到公平和 AQM：VPS 的出口通常被运营商限速，队列堆在他们那边，
你的 qdisc 根本排不上队。整形到限速的 95% 才能让瓶颈回到本机——代价是让出 5% 峰值，
换来的是运营商那个丢包式 policer 被换成你自己的排队+标记式 AQM。
EOF
}

main() {
  local cmd="${1:-}"
  local POSITIONAL=()
  # No arguments on a terminal means the panel, the way `netshape` behaves.
  # Anywhere else (pipes, cron, CI) it must stay a predictable CLI.
  if [[ -z "$cmd" ]]; then
    if [[ -t 0 && -t 1 ]]; then cmd=panel; else cmd=help; fi
  else
    shift || true
  fi
  # Config first, flags second: a flag is this invocation, the file is the
  # standing configuration.
  load_config
  while (( $# )); do
    case "$1" in
      --egress)    [[ $# -ge 2 ]] || die "--egress 缺少值"; EGRESS_MBPS="$2"; shift 2 ;;
      --cover-rtt) [[ $# -ge 2 ]] || die "--cover-rtt 缺少值"; COVER_RTT_MS="$2"; shift 2 ;;
      --initcwnd)  [[ $# -ge 2 ]] || die "--initcwnd 缺少值"; INITCWND="$2"; shift 2 ;;
      --shape-pct) [[ $# -ge 2 ]] || die "--shape-pct 缺少值"; SHAPE_PCT="$2"; shift 2 ;;
      --iface)     [[ $# -ge 2 ]] || die "--iface 缺少值"; IFACE="$2"; shift 2 ;;
      --profile)   [[ $# -ge 2 ]] || die "--profile 缺少值"
                   apply_profile "$2" || die "--profile 只能是 stable|balanced|speed|noshape"
                   shift 2 ;;
      --buf-mb)    [[ $# -ge 2 ]] || die "--buf-mb 缺少值"; BUF_MB="$2"; shift 2 ;;
      --no-shape)  apply_profile noshape; shift ;;
      --persist)   PERSIST=1; shift ;;
      --no-persist) PERSIST=0; shift ;;
      --threads)   [[ $# -ge 2 ]] || die "--threads 缺少值"; RECORD_THREADS="$2"; shift 2 ;;
      --rtt)       [[ $# -ge 2 ]] || die "--rtt 缺少值"; RECORD_RTT="$2"; shift 2 ;;
      --yes)       ASSUME_YES=1; shift ;;
      # `record` takes its reading and note as positional arguments. Everything
      # else still refuses unknown words rather than silently ignoring a typo.
      *) if [[ "$cmd" == record ]]; then POSITIONAL+=("$1"); shift
         else die "未知参数：$1"; fi ;;
    esac
  done
  if ! is_uint "$COVER_RTT_MS" || (( COVER_RTT_MS < 10 || COVER_RTT_MS > 2000 )); then
    die "--cover-rtt 需为 10-2000"
  fi
  if ! is_uint "$INITCWND" || (( INITCWND < 1 || INITCWND > 64 )); then
    die "--initcwnd 需为 1-64"
  fi
  if ! is_uint "$SHAPE_PCT" || (( SHAPE_PCT < 50 || SHAPE_PCT > 100 )); then
    die "--shape-pct 需为 50-100"
  fi
  if ! is_uint "$BUF_MB" || (( BUF_MB > 512 )); then die "--buf-mb 需为 0-512"; fi
  # Not resolved here: resolve_iface dies when there is no default route, and
  # `version`/`help` must work on a box that has none. Each command that needs
  # an interface resolves it itself.
  case "$cmd" in
    panel|menu) menu ;;
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    check)  cmd_check ;;
    plan)   cmd_plan ;;
    apply)  cmd_apply ;;
    status) cmd_status ;;
    record) cmd_record "${POSITIONAL[@]+"${POSITIONAL[@]}"}" ;;
    revert) cmd_revert ;;
    help|-h|--help) usage ;;
    version|--version) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    *) die "未知命令：$cmd（--help 看帮助）" ;;
  esac
}

if [[ "${TCPWIDE_LIB_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
