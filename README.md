# routetune

[![CI](https://github.com/bear4f/routetune/actions/workflows/ci.yml/badge.svg)](https://github.com/bear4f/routetune/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

同一台服务器同时服务多地区固网、4G/5G 和同机房客户端时，
**单一 sysctl 失效不是因为它全局，是因为它总被按某一个客户端定尺寸。**

这个仓库里有两个工具，都围绕这件事。

---

## tcpwide —— 一套按最远客户端定尺寸的 TCP 配置

**要装的是这个。** 一个脚本，交互面板，直接落地，可完整还原。

单线程实测（BandwagonHost 洛杉矶 → 上海电信，133ms）：
**平均 1.08 Gbps / 峰值 1.40 Gbps**。

```bash
curl -fsSL https://raw.githubusercontent.com/bear4f/routetune/main/tcpwide/tcpwide.sh -o /tmp/tcpwide.sh
sudo bash /tmp/tcpwide.sh install
sudo tcpwide
```

```
──────────────────────────────────────────────────────────────────────
  tcpwide 1.0.0   不整形 · bbr · 已持久化 · 2000 Mbps 口
──────────────────────────────────────────────────────────────────────

   覆盖 RTT  180 ms             缓冲上限  86.8 MB/socket
   首窗      64                 根队列    fq
   历史最好  1080 Mbps 08-27    未发送    系统默认

 ── 档位 ─────────────────────────────────────────────────────────────
   1 整形 90%      2 整形 95%      3 整形 98%     >4 不整形
 ── 设置 ─────────────────────────────────────────────────────────────
   5 端口速率      6 覆盖 RTT      7 首窗          b 缓冲上限
   n 未发送上限    s 单流旋钮      l 队列布局
 ── 工具 ─────────────────────────────────────────────────────────────
   8 诊断          9 预演          t 跨地区对比    a 重新应用
   p 持久化        r 完整还原      m 手工补录      h 看说明
   0 退出
 ─────────────────────────────────────────────────────────────────────
```

它做的事：pacing（突发不会按线速灌进最慢那条末端链路）、BBR（不把随机无线丢包
当拥塞信号）、按覆盖 RTT 定尺寸的缓冲、可选的 AQM 和按设备公平。

它刻意**不做**单流限速——按固定宽带调的限速会勒死固定宽带，
而对移动客户端根本不会触发。

首次 apply 前自动快照，`revert` 完整还原。apply 完自动回读验证，
不一致就把「目标 vs 实际」逐行打出来。

**掉速时在测速跑到一半按 `8`**：一个 8 秒窗口内同时采重传、每核占用、
每秒 `ss` 快照、队列和网卡计数，然后逐条连接给出证据——
对端窗口、拥塞窗口、本机 pacing、CPU，四种天花板各由一个字段判定。

→ **[完整文档](./tcpwide/README.md)** ·
[调参规范](./tcpwide/TUNING.md) ·
[决策档案](./tcpwide/DECISIONS.md) ·
[变更记录](./tcpwide/CHANGELOG.md)

---

## routetune —— 按路由前缀观察客户端分布

另一个方向：不直接改配置，先**观察**。按路由前缀累积客户端画像，
再生成可审阅、可回滚的 per-route 参数建议。

`scan` / `profiles` / `recommend` / `doctor` 都不改系统；
只有你手动复制 `recommend` 输出的命令，路由表才会变化。

```bash
sudo ./routetune.sh scan
sudo ./routetune.sh recommend
```

尺寸取**单个前缀自己的** RTT × 它自己的**峰值**速率，在所有前缀里取最大——
必须同一个前缀。取「所有前缀里最大的 RTT」乘「所有前缀里最大的速率」
会得到一个不存在的工作点：高 RTT 的链路正是慢的那条。

→ **[完整文档](./ROUTETUNE.md)**

---

## 两个工具的关系

`tcpwide` 和 `routetune` 都会接管全局 sysctl，**同一台机器上只装一个**。
tcpwide 检测到 routetune 会直接中止并说明原因。

- 想要一套能直接用的配置 → **tcpwide**
- 想先弄清楚自己的客户端到底长什么样 → routetune

## 参考

思路和具体参数借鉴过 [netshape-manager](https://github.com/bear4f/netshape-manager)
和 [tcpfit](https://github.com/Kylin010/tcpfit)。借了什么、
为什么没借另一些，都在 tcpwide 的 TUNING.md 和 DECISIONS.md 里写了。

MIT。
