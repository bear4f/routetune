# routetune

[![CI](https://github.com/bear4f/routetune/actions/workflows/ci.yml/badge.svg)](https://github.com/bear4f/routetune/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

按路由前缀观察 Linux TCP 客户端分布、累积画像，并生成可审阅、可回滚的 per-route 参数实验建议。

routetune 面向同一台服务器同时服务多地区固网、4G/5G 和同机房客户端的场景。第一阶段刻意保持保守：`scan`、`profiles`、`recommend`、`doctor` 都不改系统；只有你手动复制 `recommend` 输出的命令，路由表才会变化。

## 为什么不是再加一组 sysctl

sysctl 是全机共享的。一条丢 3% 的移动网、一条 250 ms 的稳定固网和一个 1 ms 的同机房客户端，不能分别拥有不同的全局 TCP 缓冲与拥塞控制。

Linux 路由可以携带 `initcwnd`、`initrwnd`、`rto_min`、`advmss`、`congctl` 等 TCP metrics。routetune 因而采用：

```text
ss 窗口采样 → 按 IPv4 /24、IPv6 /64 聚合 → 多轮画像 → per-route 实验建议
```

示例建议会复制内核当前为目标前缀选出的地址族、下一跳、网卡、源地址和路由表，只附加 TCP metrics：

```bash
sudo ip -4 route add 119.237.129.0/24 via 172.16.0.1 dev eth0 \
  src 192.0.2.10 table main initcwnd 32

# 对应回滚
sudo ip -4 route del 119.237.129.0/24 table main
```

安全边界：如果该前缀已有精确路由，或内核返回 ECMP/多路径，routetune 不生成命令。添加更具体的路由仍会固定当时的选路；默认路由以后发生变化时，它不会自动跟随，所以阶段一不持久化，并且每条建议都带精确回滚。

## 在 DMIT 上开始测试

依赖：Linux、Bash 4+、iproute2（`ss`、`ip`）；`doctor` 可选使用 `tc`、`nstat`。

```bash
curl -fsSL https://raw.githubusercontent.com/bear4f/routetune/main/routetune.sh \
  -o /tmp/routetune.sh
chmod +x /tmp/routetune.sh

# 纯只读快照；让 4G/5G 客户端保持真实视频流量
sudo bash /tmp/routetune.sh scan --samples 10 --interval 3

# 累积 30 分钟画像；写入 /var/lib/routetune/profiles.tsv，不改网络
sudo bash /tmp/routetune.sh watch --minutes 30 --samples 6 --interval 5
sudo bash /tmp/routetune.sh profiles
sudo bash /tmp/routetune.sh recommend --min-obs 5
sudo bash /tmp/routetune.sh doctor
```

`watch` 写入的画像库包含客户端前缀，权限为 `0600`。不再需要时可运行 `sudo bash /tmp/routetune.sh reset` 清空。

## 画像与当前策略

| 画像 | 判据 | 第一阶段输出 |
|---|---|---|
| 远端固网 | RTT ≥120 ms，低丢包且延迟稳定 | A/B 测试 `initcwnd 32` |
| 近端固网 | RTT <120 ms 且稳定 | 不改；额外首窗突发通常没有收益 |
| 移动网络 | 重传 ≥1%，且抖动或延迟尾部散开 | 可实验 `initcwnd 10`；不凭随机无线丢包改成 cubic |
| 稳定延迟丢包 | 重传 ≥1%，但延迟较平 | 不推断限速器；先用可控主动测速复测 |
| 轻度丢包 | 重传 0.1%–1% | 继续观察；不当作健康固网放大初始窗 |
| 接入网排队 | 中位 RTT / minRTT ≥3 | 不自动改；服务器无法直接管理对端队列 |
| 间歇排队 | 中位不深，但采样 P95 / minRTT ≥3 | 延长观察 |
| 时变链路 | 抖动或尾部散布高，但没有明确丢包/排队形状 | 延长观察，可在测试机 A/B BBRv3 |
| 同机房 / 数据不足 | RTT <5 ms / 窗口增量 <1000 段 | 不做判断 |

这些是画像启发式，不是运营商识别。一个前缀被标为“移动网络”，含义是它在采样窗口里呈现无线调度常见的延迟与重传形状，不等于 routetune 查询到了该 IP 的运营商类型。

### 无线丢包与 policer 不能靠被动快照区分

两者都可能出现 2%–3% 重传，但处置方向不同：

- 无线调度/换手通常同时拉开 RTT 尾部；降一点服务端速率未必减少射频层丢包。
- policer 可能表现为重传突然升高、延迟形状仍较平，但移动路径也可能在一个短窗口里暂时呈现平稳延迟；只有在可控测速中找到可重复的速率拐点，才适合推导速率。

DMIT 真机上的同一个移动 `/24` 已经出现过连续两轮 RTT 形状近似、重传却从 3.07% 降到 0.51% 的情况。旧版先判“限速器”、再判“健康固网”，两次都过度推断。现在这两轮数据都锁进回归测试：前者只叫“稳定延迟丢包”，后者叫“轻度丢包”，两者都不生成路由修改。

## 四道数据质量闸门

1. 默认只显示本机监听端口上的入站连接，过滤服务器主动访问的 CDN、源站和更新连接；`scan --all` 可查看全部。
2. RTT <5 ms 时不根据 `rttvar / rtt` 告警，避免计时粒度和中断合并噪声。
3. 只使用采样窗口内 `data_segs_out` 与 retrans 的增量；绝不拿连接生命周期累计值填补空闲窗口。
4. 窗口增量不足 1000 段时不分类，也不写入可信画像统计。

另有 `minrtt <0.1 ms` 的除零保护、IPv4-mapped 地址归一化，以及压缩/补零 IPv6 地址到规范 `/64` 的合并。

## 从 tcpfit 借鉴了什么

routetune 不复制 tcpfit 的全局调优模型，但采用了两个测量原则：

- RTT 是客户端分布，不应把一次 ping 当成整台服务器唯一的“地区 RTT”。routetune 直接观察真实连接，并按前缀保存分布。
- 低于预期的单次吞吐需要触发式补测并保留同一整组结果；因此 policer 画像当前只提示复测，不会拿一次 `delivery_rate` 快照直接生成限速。

如果后续加入主动 iperf3 验证，会使用 receiver goodput，并在首次结果低于基线阈值时才 best-of-N，避免正常链路无谓消耗流量。

## `doctor` 的解释边界

- 原厂主线内核只有名为 `bbr` 的主线实现时，脚本标为 BBRv1。非主线内核仍只显示 `bbr` 时，名称本身不足以判定 v1/v2/v3，需查内核构建说明。
- `TcpExtTCPDSACKRecv* / TcpRetransSegs` 只作为全机、开机以来的乱序/过早重传旁证。两个计数器单位不同，它不是“虚假重传百分比”，也不能归因到某个前缀。

## 做不到什么

- 无线射频层丢包不能由服务端 sysctl 或 per-route metrics 消除。
- BBRv3 需要内核提供；脚本不能把 BBRv1 变成 v3。
- 第一阶段不自动执行、不持久化路由、不生成 tc 速率。先用真实流量验证画像，再扩大动作面。
- NAT/CGNAT 后的一个前缀可能包含多个用户；前缀画像是聚合结果，不是单设备诊断。

## 测试

```bash
bash -n routetune.sh tests/self-test.sh
bash tests/self-test.sh
shellcheck -x -P SCRIPTDIR routetune.sh tests/self-test.sh
```

测试覆盖真机 4G/稳定延迟丢包/轻度丢包分类、时变无丢包链路、窗口增量、加权重传、IPv4-mapped 与 IPv6 `/64`、空闲连接闸门、路由上下文复制、ECMP/已有路由拒绝，以及 BBR/DSACK 解释。

## 项目状态

`v0.1.1` 是观测与建议阶段。下一阶段以 DMIT 真机数据校准阈值、画像稳定性和路由实验收益；在此之前不会加入自动 apply。

## 许可证

[MIT](./LICENSE)
