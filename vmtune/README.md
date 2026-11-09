# vmtune —— VM 参数持久化（`k90_cpuctl` 的配套子模块）

这个目录不是主模块的一部分，是**独立模块** `k90_vmtune` 的源码，和 `k90_cpuctl` 并列安装、互不干扰。

它只做一件事：把两个 `vm.*` 内核参数钉住，开机应用、运行期自愈。之所以值得单独一个模块，是因为**只写一次是无效的**——见下面的时间线。

---

## 问题

排查 K90 Pro Max 待机发热、掉电时发现内存侧有异常压力：

| 指标（调整前 10 秒采样） | 值 |
|---|---|
| 换出页 `pswpout` | 34,028 |
| 换入页 `pswpin` | 7,046 |
| 主缺页 `pgmajfault` | 7,403 |
| `kswapd` 扫描页 | 113,934 |
| 内存压力 PSI `some avg10` | 5.63 % |
| IO 压力 PSI `some avg10` | 15.93 % |

8.3 GB 匿名内存被压进 zram 反复搓，`kswapd0` 累计烧了 167 分钟 CPU。抬高内存水位、加大 swap 预读能缓解直接回收。

## 排查时间线（这里我一开始判断错了）

| 时间 | 事实 |
|---|---|
| 2026-10-30 10:32 | `/data/adb/service.d/99-k90-powertune.sh` 写入（开机前就存在） |
| 2026-10-31 00:41 | 真实开机，`powertune.log` 首行 `boot apply`，`11584 -> 262144` |
| 2026-11-02 | 5 次 soft reboot，每次都有 `boot apply`，最后一次 17:06 写入 `262144` |
| 2026-11-09 23:00 | 读到 `min_free_kbytes = 22528`，**期间没有重启** |

**共有 7 条 `boot apply` 记录，`service.d` 路径一直是正常的。** 我最初只看 `tail` 的 4 条、以为"开机没跑"，那是错的。

真正的现象是：**写进去的值会在运行期被改回去**。而且首次记录的默认值是 `11584`，11-09 读到的是 `22528`，两次"默认值"都不一样——这符合内核重算内存水位的特征，不是某个脚本一次性覆盖。

结论：`service.d` 单点写入治不好，必须有运行期守护。

## 做法

`service.sh` 两件事：

1. **开机**：等 `sys.boot_completed`（最多 180 秒）→ 写 `vm.min_free_kbytes=262144`、`vm.page-cluster=2`，逐项记录 `旧值 -> 新值`，写不进去记 `FAIL` → 再等 15 秒复查一次（防厂商服务晚启动覆盖）
2. **常驻看门狗**：`vmtune_watch.sh` 每 300 秒巡检，发现漂移立刻重写并记 `drift` 日志，同时刷新 `watchdog.last` 存活标记

**去重**用 `mkdir` 原子锁 + 读 `/proc/PID/cmdline` 校验持有者身份。这不是过度设计：主模块的 `__watch` 曾经在 soft reboot 后累积到 6 份并发（v1.8.10 修的就是这个），同一类坑提前堵上。

## 验证（均为实测）

| 测试 | 结果 |
|---|---|
| 写入逻辑 | 打回默认值再执行：`22528 -> 262144`、`0 -> 2`，日志准确 |
| 重复执行去重 | 第二次输出 `watchdog 已在运行 (pid 9249)，跳过启动`，实例数始终 1 |
| 漂移自愈 | 23:28:33 手工注入 `22528` → **23:33:11 自动改回 `262144`**，日志 `drift mfk: 22528 -> 262144` |
| 存活标记 | `watchdog.last` 持续刷新，进程常驻 |

## 诚实说明：效果无法单独归因

调整后测到 `pswpout` 归零、PSI 从 5.63 % 降到 0.08 %——但那次采样前执行过 `drop_caches`，**归零部分是清缓存造成的假象**，之后换页又回来了。

真正让换页停下的是**杀掉微信空转进程**（`binder:*_10` 线程占 96.6 % 单核，每隔几分钟自触发复发）。VM 参数在这个场景里是缓解，不是根治。

所以这个模块的定位很明确：**保证参数不会悄悄漂回默认值**。它治不了 CPU 侧的病。

## 安装

```bash
# 自动取第一台在线设备
./deploy.sh

# 指定序列号
./deploy.sh 66041f48
```

`deploy.sh` 会推 `module.prop` / `service.sh` / `uninstall.sh` 到 `/data/adb/modules/k90_vmtune/`，然后**立即执行一次 `service.sh`**，不重启就生效。

手动方式：

```bash
adb push . /data/local/tmp/k90_vmtune
adb shell su -c 'mkdir -p /data/adb/modules/k90_vmtune && cp /data/local/tmp/k90_vmtune/* /data/adb/modules/k90_vmtune/'
adb shell su -c 'chmod 755 /data/adb/modules/k90_vmtune/*.sh'
adb shell su -c 'sh /data/adb/modules/k90_vmtune/service.sh'
```

## 运行状态

| 路径 | 内容 |
|---|---|
| `/data/adb/k90_vmtune/vmtune.log` | 应用 / 复查 / 漂移 / 去重全部记录 |
| `/data/adb/k90_vmtune/watchdog.last` | 看门狗最近一次心跳 |
| `/data/adb/k90_vmtune/watchdog.lock/pid` | 锁持有者 pid |
| `/data/adb/k90_vmtune/vmtune_watch.sh` | 由 `service.sh` 生成 |

```bash
# 一眼看当前值和最近日志
adb shell su -c 'cat /proc/sys/vm/min_free_kbytes; cat /proc/sys/vm/page-cluster; tail -5 /data/adb/k90_vmtune/vmtune.log'
```

## 局限

- 只对 **zram swap** 有意义的机型有效（这台机器 zram = 16 GB，由 `vendor.swap-hal` 统一管理，和"内存扩展"开关无关）
- `min_free_kbytes=262144` 是 256 MB 常驻预留，小内存机型不要照搬这个值
- 卸载读 `uninstall.sh`，只清 `/data/adb/k90_vmtune`，不改动参数（重启回默认）

## License

MIT，与主模块一致。
