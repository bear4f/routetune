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

VERSION="0.7.0"
PROGRAM="tcpwide"
STATE_DIR="/var/lib/tcpwide"
SYSCTL_SNAP="$STATE_DIR/sysctl.snapshot"
QDISC_SNAP="$STATE_DIR/qdisc.snapshot"
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

EGRESS_MBPS=""
IFACE=""
SHAPE=1
PERSIST=0
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
  local ram page pages
  ram="$(total_ram_bytes)"
  (( ram > 0 )) || return 1
  page="$(getconf PAGESIZE 2>/dev/null || printf 4096)"
  pages=$(( ram / page ))
  awk -v p="$pages" 'BEGIN {
    low = int(p / 16); pres = int(p / 8); max = int(p / 4)
    if (low  < 4096)  low  = 4096
    if (pres < 8192)  pres = 8192
    if (max  < 16384) max  = 16384
    printf "%d %d %d", low, pres, max }'
}

# netshape's field-proven ladder. Its reason is the mirror image of tcpfit's
# asymmetry argument rather than a contradiction of it.
#
# tcpfit tunes CLEAN links, where a ceiling that is too small is a silent cap
# and one that is too large costs only a little overshoot. netshape tunes
# POLICED cross-border links, and its comment is blunt: oversized buffers let
# BBR hold a huge cwnd and retransmissions explode. Both are right in their own
# domain, and a cross-border relay is squarely netshape's.
#
# The arithmetic on the live 958 MB box makes it concrete. A 30 MB send buffer
# lets BBR put 1472 Mbps in flight on a 171ms path — 2.9x a 500 Mbps line. BBRv1
# does not back off on loss, so it keeps pushing that overshoot into whatever
# drops it. This ladder holds the same box to 16 MB, or 1.6x.
netshape_memory_cap() {
  local mb="${1:-1024}"
  if   (( mb < 512 ));  then printf '%s\n' $((8   * 1024 * 1024))
  elif (( mb < 1024 )); then printf '%s\n' $((16  * 1024 * 1024))
  elif (( mb < 2048 )); then printf '%s\n' $((32  * 1024 * 1024))
  elif (( mb < 4096 )); then printf '%s\n' $((64  * 1024 * 1024))
  else                       printf '%s\n' $((128 * 1024 * 1024))
  fi
}

buffer_ceiling() {
  local rate="${1:-0}" rtt="${2:-0}" ram buf cap ladder
  # An explicit figure skips both the derivation and the ladder: the point of
  # the override is to test the ladder, so the ladder must not clamp it back.
  if is_uint "$BUF_MB" && (( BUF_MB > 0 )); then
    printf '%s\n' $(( BUF_MB * 1024 * 1024 )); return 0
  fi
  buf=$(( $(bdp_bytes "$rate" "$rtt") * 2 + BUF_SLACK ))
  (( buf > BUF_CAP )) && buf="$BUF_CAP"
  ram="$(total_ram_bytes)"
  # One socket may take at most an eighth of the global TCP budget, so at least
  # eight large flows can run at the ceiling before anyone hits pressure. Since
  # the budget's own cap is a quarter of RAM, that works out to RAM/32. Clamping
  # against RAM directly, as this used to, let a single connection monopolise
  # the budget on a small box.
  if (( ram > 0 )); then
    cap=$(( ram / 32 ))
    ladder="$(netshape_memory_cap $(( ram / 1048576 )))"
    (( ladder < cap )) && cap="$ladder"
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
  if tcpmem="$(target_tcp_mem)"; then
    printf 'net.ipv4.tcp_mem\t%s\traise\t%s\n' "$tcpmem" \
      '全局 TCP 页预算（所有 socket 共享）。rmem_max 只是天花板，这个才是内核硬拦的总量——它太小的话，上限调多大都没用，几条大流一上来就触发压力被缩回去'
  fi
  # Only emitted when the operator has chosen a value. See NOTSENT_LOWAT above
  # for why this is not decided here.
  if is_uint "$NOTSENT_LOWAT" && (( NOTSENT_LOWAT > 0 )); then
    printf 'net.ipv4.tcp_notsent_lowat\t%s\texact\t%s\n' "$NOTSENT_LOWAT" \
      '未发送数据上限。400Mbps 下 16KB 只够 0.33ms，代理进程稍慢一下管道就空了。真机 A/B/A 夹逼对照下 131072 比 16384 高 18%（均）/11%（峰），但只有一个 B 样本，证据不算强。要极致低延迟可以调小，填 0 保持系统现值'
  fi
  printf 'net.core.netdev_max_backlog\t%s\traise\t%s\n' \
    "$( (( $(total_ram_bytes) < 1024 * 1024 * 1024 )) && printf 4096 || printf 16384 )" \
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
  (( SHAPE == 1 )) || { printf 'fq maxrate %smbit\n' "$perflow"; return 0; }
  # No `ecn` keyword: mainline sch_cake already marks ECN-capable packets
  # instead of dropping them, so there is nothing to switch on, and the option
  # does not exist in current iproute2 — the live node rejected the whole spec
  # over it with "What is \"ecn\"?". It was moot here anyway, since tcp_ecn is
  # set to 0 for the cross-border blackhole reason.
  printf 'cake bandwidth %skbit dual-dsthost besteffort rtt %sms\n' \
    "$(shaped_kbit "$rate")" "$rtt"
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
  printf '%s initcwnd %s\n' "$line" "$cwnd"
}

# ── 配置持久化 ─────────────────────────────────────────────────────────────

CONFIG_FILE="/etc/tcpwide.conf"
CLI_PATH="/usr/local/bin/tcpwide"
INSTALL_PATH="/usr/local/lib/tcpwide/tcpwide.sh"
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
    noshape)  SHAPE_PCT=98; SHAPE=0; PROFILE=noshape ;;
    *) return 1 ;;
  esac
  return 0
}

profile_label() {
  case "${1:-}" in
    stable)   printf '稳定优先\n' ;;
    balanced) printf '均衡\n' ;;
    speed)    printf '速度优先\n' ;;
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
qdisc_drift() {
  local want live
  want="$(target_qdisc "${EGRESS_MBPS:-200}" "$COVER_RTT_MS" | awk '{print $1}')"
  live="$(tc qdisc show dev "$IFACE" 2>/dev/null | sed -n '1p' | awk '{print $2}')"
  [[ -n "$live" ]] || return 1
  [[ "$live" != "$want" ]] || return 1
  printf '%s\n' "$live"
}

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
  (( b > 0 )) || return 1
  awk -v r="$a" -v s="$b" 'BEGIN {printf "%.4f\n", r * 100 / s}'
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
# does per-packet work on it; on a single-core VPS at several hundred Mbps that
# can cost more throughput than the policer it is replacing. Roughly 400 Mbps
# per core is where it starts to matter on a small box.
shaping_cpu_warning() {
  local rate="${1:-0}" cores
  (( SHAPE == 1 )) || return 1
  cores="$(cpu_count)"
  is_uint "$cores" && (( cores > 0 )) || cores=1
  (( rate > cores * 400 )) || return 1
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

apply_link() {
  local rate="$1" rtt="$2" want_q cur_r want_r
  want_q="$(target_qdisc "$rate" "$rtt")"
  if [[ ! -e "$QDISC_SNAP" ]]; then
    tc qdisc show dev "$IFACE" 2>/dev/null | sed -n '1p' > "$QDISC_SNAP" || true
    chmod 0600 "$QDISC_SNAP" 2>/dev/null || true
  fi
  split_words "$want_q"
  local tc_err bad
  if tc_err="$(tc qdisc replace dev "$IFACE" root "${SPLIT_WORDS[@]}" 2>&1)"; then
    log "根队列已设为：$want_q"
  else
    warn "无法设置根队列：tc qdisc replace dev $IFACE root $want_q"
    [[ -z "$tc_err" ]] || printf '  %btc 报错：%s%b\n' "$DIM" "$tc_err" "$RESET"
    if bad="$(probe_cake_options "$want_q")"; then
      printf '  %b逐项试出来，加到这里就被拒绝：%b%s%b\n' "$DIM" "$RESET" "$bad" "$RESET"
      printf '  %b最后那一项要么本机 tc 不认识，要么内核的 sch_cake 不支持。%b\n' "$DIM" "$RESET"
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
  apply_sysctl "$rate" "$rtt"; n="$SYSCTL_WROTE"
  apply_link "$rate" "$rtt"
  (( PERSIST == 1 )) && write_persistence "$rate" "$rtt"
  printf '\n'
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
    printf '
  %b实测：当前 %s 个活跃客户端里，最远的 RTT 是 %s ms%b
'       "$GREEN" "$n" "$max" "$RESET"
    printf '  %b建议填 %s（实测 ×1.2 后向上取整，给移动客户端留波动余量）%b
'       "$GREEN" "$sug" "$RESET"
    printf '  %b注意这是一次瞬时采样。如果刚好抓到某个客户端的尖峰，这个数会偏高。%b
'       "$DIM" "$RESET"
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
    local r ram clamp knee
    ram="$(total_ram_bytes)"
    # Whichever of the two caps actually binds, so the marker and the knee
    # below describe the rule the operator is really up against.
    clamp=$(( ram / 32 ))
    local ladder; ladder="$(netshape_memory_cap $(( ram / 1048576 )))"
    (( ladder < clamp )) && clamp="$ladder"
    for r in 100 250 400; do
      buf="$(buffer_ceiling "$rate" "$r")"
      printf '    %b%-4s ms → 上限 %5s MB/socket，约 %s 条满上限就触发全局 tcp_mem 压力%s%b
'         "$DIM" "$r" "$(mb "$buf")" "$(( tcpmem / (buf > 0 ? buf : 1) ))" \
        "$( (( ram > 0 && buf >= clamp )) && printf '  <- 已被内存夹住' )" "$RESET"
    done
    # Two identical rows in that table read as "it makes no difference", when
    # what they actually mean is that the RAM clamp is already binding. Say so
    # rather than leaving the operator to notice the numbers repeat.
    if (( ram > 0 && rate > 0 )); then
      knee=$(( (clamp - BUF_SLACK) / (250 * rate) ))
      if (( knee >= 10 && knee <= 2000 )); then
        printf '\n  %b这台机器 %s MB 内存，单 socket 上限被夹在 %s MB。%b\n' \
          "$DIM" "$(( ram / 1048576 ))" "$(mb "$clamp")" "$RESET"
        if (( clamp == $(netshape_memory_cap $(( ram / 1048576 ))) )); then
          printf '  %b这是 netshape 实战得出的档位：跨境线路上被限速时，缓冲给太大会让 BBR%b\n' \
            "$DIM" "$RESET"
          printf '  %b攒起巨大的 cwnd，超发的部分被丢掉，重传就爆了。%b\n' "$DIM" "$RESET"
        else
          printf '  %b（全局 TCP 预算的 1/8，保证至少 8 条大流能同时到顶）%b\n' "$DIM" "$RESET"
        fi
        printf '  %b所以覆盖 RTT 填超过 %s ms 不会再增加缓冲了。%b\n' "$DIM" "$knee" "$RESET"
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
  ss -tinH 2>/dev/null | awk -v listen=" $ports " '
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
      if (rtt > 0 && wnd > 0 && rate > best && index(listen, " " portof(local) " ") > 0) {
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
  live_q="$(tc qdisc show dev "$IFACE" 2>/dev/null | sed -n '1p' | sed 's/^qdisc //' | cut -c1-58)"
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
  printf '  %b%s%b %b1)%b 稳定优先   整形 90%%｜首窗 16%b  丢包敏感、跨境线路%b\n' \
    "$GREEN" "$p1" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b%s%b %b2)%b 均衡       整形 95%%｜首窗 20%b  推荐%b\n' \
    "$GREEN" "$p2" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b%s%b %b3)%b 速度优先   整形 98%%｜首窗 32%b  干净直连%b\n' \
    "$GREEN" "$p3" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b%s%b %b4)%b 不整形     只做 pacing%b  放弃按设备公平和 AQM%b\n' \
    "$GREEN" "$p4" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '  %b设置%b\n' "$BOLD" "$RESET"
  printf '    %b5)%b 出口带宽%b（当前 %s Mbps）%b   %b6)%b 覆盖 RTT%b（当前 %s ms）%b   %b7)%b 首窗%b（当前 %s）%b\n' \
    "$BOLD" "$RESET" "$DIM" "${EGRESS_MBPS:-未设置}" "$RESET" \
    "$BOLD" "$RESET" "$DIM" "$COVER_RTT_MS" "$RESET" \
    "$BOLD" "$RESET" "$DIM" "$INITCWND" "$RESET"
  printf '    %bn)%b 未发送数据上限 notsent_lowat%b（当前 %s，没有可靠依据，留给你 A/B）%b\n' \
    "$BOLD" "$RESET" "$DIM" \
    "$( (( NOTSENT_LOWAT > 0 )) && printf '%s' "$NOTSENT_LOWAT" || printf '不改' )" "$RESET"
  printf '    %bb)%b 缓冲上限%b（当前 %s，接收窗口是它的一半，直接决定单流上限）%b\n' \
    "$BOLD" "$RESET" "$DIM" \
    "$( (( BUF_MB > 0 )) && printf '%s MB（手动）' "$BUF_MB" || printf '自动 %s MB' "$(mb "$(buffer_ceiling "${EGRESS_MBPS:-500}" "$COVER_RTT_MS")")" )" \
    "$RESET"
  printf '  %b查看与工具%b\n' "$BOLD" "$RESET"
  printf '    %b8)%b 状态与诊断（实时重传率、队列、冲突）\n' "$BOLD" "$RESET"
  printf '    %b9)%b 预演（逐项列出 当前值 → 目标值 和理由）\n' "$BOLD" "$RESET"
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
  if pct="$(retrans_rate 5)"; then
    printf '  实时重传率:        %s%%%b（5 秒窗口增量，不是自开机累计）%b\n' "$pct" "$DIM" "$RESET"
    if awk -v p="$pct" 'BEGIN {exit !(p >= 2)}'; then
      warn "重传偏高。先确认根队列真的是 cake（有 pacing），再看是不是客户端侧无线丢包"
    fi
  else
    printf '  实时重传率:        无法采样（缺少 nstat 或窗口内没有流量）\n'
  fi
  local win peer wrtt wbytes wceil wobs
  if win="$(peer_window_ceiling)"; then
    IFS=$'\t' read -r peer wrtt wbytes wceil wobs <<< "$win"
    printf '\n  %b最快的那条连接：%s%b\n' "$BOLD" "$peer" "$RESET"
    printf '    RTT %s ms｜对端通告窗口 %s MB｜实测 %s Mbps\n' \
      "$wrtt" "$(mb "$wbytes")" "$wobs"
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
  printf '\n'
  render_plan "${EGRESS_MBPS:-200}" "$COVER_RTT_MS"
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
        printf '  %b只有一个 B 样本，证据不算强。填 0 = 保持系统现值。%b\n' "$DIM" "$RESET"
        if value="$(prompt_uint 'notsent_lowat 字节（0=不改，q 返回）' "$NOTSENT_LOWAT" 0 16777216)"; then
          NOTSENT_LOWAT="$value"; save_config; run_action cmd_apply
        else info "已取消"; continue; fi
        ;;
      b|B)
        printf '  %b接收窗口 = 缓冲上限 ÷ 2（tcp_adv_win_scale=1），单流上限 = 窗口 ÷ RTT。%b\n' \
          "$DIM" "$RESET"
        local bw
        for bw in 16 32 64; do
          printf '    %b%2s MB → 窗口 %2s MB → %3.0f Mbps @160ms，%3.0f Mbps @%sms%b\n' \
            "$DIM" "$bw" "$((bw / 2))" \
            "$(awk -v b="$bw" 'BEGIN {print b * 1048576 / 2 * 8 / 0.160 / 1e6}')" \
            "$(awk -v b="$bw" -v r="$COVER_RTT_MS" 'BEGIN {print b * 1048576 / 2 * 8 / (r / 1000) / 1e6}')" \
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
  [[ -t 0 ]] || die "install 需要交互终端"
  local other value answer
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
  drain_stdin
  value="$(prompt_uint '这台机器的出口带宽（Mbps，按你套餐的端口速率）' 500 1 100000)" \
    || die "已取消安装"
  EGRESS_MBPS="$value"
  printf '\n'
  explain_cover_rtt "$EGRESS_MBPS"
  local sug_rtt=250 row
  if row="$(suggest_cover_rtt)"; then sug_rtt="$(cut -f1 <<< "$row")"; fi
  value="$(prompt_uint '覆盖 RTT（ms）' "$sug_rtt" 10 2000)" || die "已取消安装"
  COVER_RTT_MS="$value"
  printf '\n  %b档位%b\n' "$BOLD" "$RESET"
  printf '    1) 稳定优先   整形 90%%｜首窗 16   丢包敏感、跨境线路\n'
  printf '    2) 均衡       整形 95%%｜首窗 20   推荐\n'
  printf '    3) 速度优先   整形 98%%｜首窗 32   干净直连\n'
  printf '    4) 不整形     只做 pacing，放弃按设备公平和 AQM\n'
  read -r -p '  请选择 [2]: ' answer || answer=2
  case "${answer:-2}" in
    1) apply_profile stable ;; 3) apply_profile speed ;;
    4) apply_profile noshape ;; *) apply_profile balanced ;;
  esac
  save_config
  printf '\n'
  cmd_apply
  mkdir -p "$(dirname "$INSTALL_PATH")"
  if cp -f "${BASH_SOURCE[0]}" "$INSTALL_PATH" 2>/dev/null; then
    chmod 0755 "$INSTALL_PATH"
    ln -sfn "$INSTALL_PATH" "$CLI_PATH"
    log "已安装。以后直接运行 sudo tcpwide 进面板"
  else
    warn "无法复制脚本到 $INSTALL_PATH，软链未创建；仍可用 bash 直接运行本脚本"
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

首次安装（向导会问出口带宽、覆盖 RTT、档位，然后装好软链）：
  sudo bash tcpwide.sh install

之后直接进面板：
  sudo tcpwide

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
  tcpwide revert                       完整还原到 tcpwide 介入之前

参数：
  --egress <Mbps>    出口带宽。整形必须知道这个数
  --cover-rtt <ms>   覆盖 RTT，默认 250。按你最远的客户端填，不是按你自己
  --initcwnd <N>     默认路由首窗，默认 20（内核默认是 10）
  --shape-pct <N>    整形到出口带宽的百分之多少，默认 95
  --iface <名字>     出口网卡，默认自动探测
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
      --no-shape)  SHAPE=0; shift ;;
      --persist)   PERSIST=1; shift ;;
      --yes)       ASSUME_YES=1; shift ;;
      *) die "未知参数：$1" ;;
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
    revert) cmd_revert ;;
    help|-h|--help) usage ;;
    version|--version) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    *) die "未知命令：$cmd（--help 看帮助）" ;;
  esac
}

if [[ "${TCPWIDE_LIB_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
