# K90 Pro Max 调频模块（CPU + GPU）

![license](https://img.shields.io/badge/license-MIT-blue.svg)
![platform](https://img.shields.io/badge/platform-Magisk%20%7C%20KernelSU-brightgreen)
![device](https://img.shields.io/badge/device-myron%20%2F%20SM8850-orange)

Redmi K90 Pro Max 的 **CPU + GPU** 频率档位管理模块。

### 机型标识

| 项目 | 值 |
|---|---|
| 机型 | Redmi K90 Pro Max |
| 机型代号 | `25102RKBEC`（`ro.product.model`） |
| 设备代号 | `myron`（`ro.product.device`，`customize.sh` 的机型判断用它） |
| SoC | 高通 SM8850 骁龙 8 Elite Gen 5，kernel 6.12 GKI |
| 系统 | Android 16，`BP2A.250605.031.A3` |

九个预设档位覆盖「最低频率 → 全拉满测速」，带本地网页界面：手机浏览器打开 `http://127.0.0.1:8088/` 就能看两簇 CPU 与 GPU 的实时频率、切档、下拉式自定义频率。单文件 HTML，零外部依赖。

---

## 特性

- **9 个档位**：出厂默认 / 最低频率 / 极致省电 / 日常省电 / 日常均衡 / 日常增强 / 轻度游戏 / 重度游戏 / 全拉满测速
- **GPU 联动**：每个档位同时设 CPU 与 GPU 功耗等级（`cooling_device37`，18 档 160–1200 MHz）
- **自定义频率**：下拉选择框 + `确认应用`。选完不生效，点确认才一次性原子写入两簇与 GPU；`恢复本档默认` 一键回到预设
- **自动维持守护**：每 10 秒校正一次（`CPUCTL_INTERVAL` 可调），被系统偷偷改回来会拉回去；测速档 5 分钟自动回落到重度游戏
- **温度保护**：CPU 温度达到上限（默认 48 °C）时让权给系统温控
- **配置备份/还原**：抓取出厂 sysfs 快照，界面按钮、命令行、卸载三个入口都能还原
- **纯 sysfs + KGSL**：只读写 `/sys`，不注入进程、不 hook 内核
- **低开销**：单次状态请求 ~1.4 s（优化前 4 s），前端轮询在页面闲置时自动降频到 6 s / 15 s

---

## 环境

| 项目 | 内容 |
|---|---|
| Root | KernelSU（**临时 root 也能用**，见下文） |
| CPU 集群 | `policy0` = cpu0–5（6 性能核，384 MHz–3.63 GHz）、`policy6` = cpu6–7（2 超大核，768 MHz–4.61 GHz） |
| 调速器 | `walt`（另有 `performance` / `powersave` / `schedutil` / `conservative` / `migov`） |
| GPU | `kgsl-3d0`，18 个功耗等级：0 = 1200 MHz → 17 = 160 MHz |
| GPU 限频点 | `cooling_device37`（`type=gpu`），`cur_state` 即功耗等级 |

---

## 安装

**方式一：管理器刷入**

下载 Release 里的 `K90ProMax-cpuctl-v1.3.zip`，在 KernelSU / Magisk 的「模块 → 从本地安装」中选它。

**方式二：命令行**

```bash
adb push K90ProMax-cpuctl-v1.3.zip /data/local/tmp/
su -c 'magisk --install-module /data/local/tmp/K90ProMax-cpuctl-v1.3.zip'
```

**方式三：不重启立即用（临时 root 场景）**

```bash
adb push K90ProMax-cpuctl-v1.3.zip /data/local/tmp/
su -c 'M=/data/adb/modules/k90_cpuctl; rm -rf $M; mkdir -p $M; \
       busybox unzip -o /data/local/tmp/K90ProMax-cpuctl-v1.3.zip -d $M >/dev/null; \
       chmod 755 $M/bin/* $M/service.sh $M/action.sh $M/uninstall.sh \
                 $M/webroot/cgi-bin/api.cgi'
su -c '/data/adb/modules/k90_cpuctl/bin/cpuctl boot'
```

自己打包：`./package.sh`，产物在 `dist/`。

---

## 档位

| 键 | 名称 | CPU 0-5 | CPU 6-7 | GPU | 说明 |
|---|---|---|---|---|---|
| `stock` | 出厂默认 | 按快照还原 | 按快照还原 | 按快照还原 | 系统原生调度，不做任何约束 |
| `floor` | 最低频率 | 锁 0.38 GHz | 锁 0.77 GHz | 160 MHz | 全集群 min=max 锁死最低频，只保证系统活着 |
| `eco` | 极致省电 | 0.38–1.11 GHz | 0.77–1.02 GHz | 422 MHz | 屏蔽睿频，续航拉满 |
| `saver` | 日常省电 | 0.38–1.56 GHz | 0.77–1.75 GHz | 539 MHz | 刷视频看小说够用 |
| `balanced` | 日常均衡 | 0.38–2.11 GHz | 0.77–2.44 GHz | 726 MHz | 默认推荐 |
| `boost` | 日常增强 | 0.38–2.75 GHz | 0.77–3.13 GHz | 902 MHz | 应用启动更快 |
| `light` | 轻度游戏 | 0.88–3.19 GHz | 1.02–3.65 GHz | 1050 MHz | 王者/和平类，稳帧优先 |
| `heavy` | 重度游戏 | 1.11–3.51 GHz | 1.38–4.07 GHz | 1200 MHz | 原神/绝区零高画质 |
| `max` | 全拉满测速 | 锁 3.63 GHz | 锁 4.61 GHz | 1200 MHz | `performance` 调速器，**5 分钟自动回落到 `heavy`** |

> `floor` 是 min=max 硬锁，实测守护可长期维持，但切换动画、滑动会有肉眼可见延迟，属于挂机/应急档而非日常档。
> `max` 只适合跑分，持续用发热明显。

---

## 重要：平台存在动态频率上限

这是本机最关键的一条限制：

**写入 `scaling_max_freq` 超过平台当前允许的上限时，内核会静默丢弃（不报错）。**

| 场景 | policy0 上限 | policy6 上限 |
|---|---|---|
| 稳态（日常/负载） | 2.22 – 2.88 GHz | 2.22 – 2.88 GHz |
| 亮屏/交互瞬时 | 一度到 3.51 GHz | 一度到 4.07 GHz |
| 厂商标称 | 3.63 GHz | 4.61 GHz |

排除了这些可能：`msm_performance/cpu_max_freq`（只负责压低，写 1 GHz 立刻生效）、`perfmgr/max_freq_limit_level`（无效）、thermal cooling device（`state=0` 已是最宽松）、`cpufreq/boost=1`、抬高 `scaling_min_freq`（同样被钳）。

结论：**CPU 侧有厂商功耗策略层，无法通过 sysfs 突破**。所以：

- 省电/均衡档（上限低于 2.2 GHz）**完全按设定生效**
- 游戏档会把目标值写下去，实际跑到平台当时允许的上限
- 界面显示的是**实时生效值**，与标称值不同属正常现象

GPU 侧不一样，热限频是显式可关的：原厂 `cooling_device37` 默认 `state=1`（1050 MHz），模块置 0 后 GPU 可满血 1200 MHz，实测稳定不回退。

---

## 使用

| 方式 | 操作 |
|---|---|
| 模块按钮 | 管理器里点本模块「操作」按钮，起服务并拉起浏览器 |
| 终端 | `su -c 'sh /data/adb/modules/k90_cpuctl/bin/cpuctl web open'` |
| 手动 | 浏览器打开 `http://127.0.0.1:8088/`（占用时自动顺延到 8092） |

> 只监听 `127.0.0.1`。电脑上调试用 `adb forward tcp:18090 tcp:8088`。

### 界面

- **顶部**：当前档位、CPU/GPU/电池温度、在线状态
- **三张卡**：性能核 0-5、超大核 6-7、GPU，实时频率 + 区间条 + 当前位置，2 秒刷新
- **档位区**：9 个按钮两列排布，当前档绿色高亮
- **自定义频率**：三组下拉框（两簇上下限 + GPU 上限），选项直接来自 `scaling_available_frequencies` 与 GPU 18 档表
  - 选完**不生效**，出现「有未确认的修改」提示、`确认应用` 按钮点亮
  - 点确认才通过 `cpuctl setall` 一次性写入两簇 + GPU，避免连发三次 `set` 的中间态被守护插队
  - `恢复本档默认` 重新应用当前档位预设；若当前已是「自定义」档，则把下拉框回滚到硬件实际生效值
  - GPU 没动过就不下发，免得把系统温控压下来的等级固化成自定义值
- **高级**：自动维持开关、温度保护上限 35–65 °C、重新备份、恢复出厂默认

### 命令

```bash
C=/data/adb/modules/k90_cpuctl/bin/cpuctl
su -c "sh $C status"                                    # 当前状态
su -c "sh $C list"                                      # 档位表
su -c "sh $C apply heavy"                               # 切档
su -c "sh $C set p0 384000 1900800"                     # 自定义单集群（kHz）
su -c "sh $C setall 691200 1785600 883200 1862400 10"   # 两簇 + GPU 一次写入
su -c "sh $C gpu 3"                                     # GPU 等级 0-17（也可写 902 这样的 MHz）
su -c "sh $C watch on|off|status"                       # 自动维持
su -c "sh $C temp"                                      # 温度
su -c "sh $C backup"                                    # 重新备份
su -c "sh $C restore"                                   # 恢复出厂
su -c "sh $C web start|stop|restart|status|open"
su -c "sh $C boot"                                      # 手动跑一次开机流程
```

---

## 架构

```
浏览器 ──HTTP──> busybox httpd (127.0.0.1:8088)
                    └─ CGI ──> api.cgi ──> bin/cpuctl ──> /sys/.../cpufreq/*
                                                       └→ /sys/class/kgsl/kgsl-3d0
```

```
/
├── module.prop              模块元数据
├── customize.sh             刷入时：机型提示 + 权限修正
├── service.sh               开机自启
├── action.sh                管理器「操作」按钮入口
├── uninstall.sh             卸载：停服务 + 按快照还原
├── httpd.conf               busybox httpd 路由
├── bin/
│   ├── cpuctl               命令行 + 服务生命周期
│   ├── profiles.sh          档位定义表（cpuctl 与 api.cgi 共用）
│   ├── watch_run.sh         独立拉起守护
│   └── web_spawn.sh         独立拉起 httpd
└── webroot/
    ├── index.html           单文件前端
    └── cgi-bin/api.cgi      CGI 接口
```

档位表集中在 `bin/profiles.sh`，格式：

```
键|名称|一句话说明|p0下限|p0上限|p6下限|p6上限|调速器|GPU等级
```

前端按钮、`cpuctl list`、CGI 白名单都从这张表动态生成——**加档位只改这一个文件**。

运行时状态在 `/data/adb/k90_cpuctl/`：`profile`、`watch_enabled`、`web_port`、`temp_limit`、`backup/stock.conf`，以及温度 zone 缓存 `tz_cpu.list` / `tz_batt.list`（删掉会自动重建）。

---

## 性能与开销

调频模块本身必须是「零感知」的，否则压频率省下来的电会被守护进程自己吃掉。这台机器上一个 `fork` 在内存紧张时要 20 ms，所以脚本里的每次 `$(cat ...)` 都很贵。

| 项 | v1.2 | v1.3 |
|---|---|---|
| 单次 `action=state` | 4.0 s | **1.4 s** |
| 每请求 fork 次数 | 200+ | ~20 |
| 守护校正间隔 | 3 s | 10 s |
| 前端轮询（闲置） | 固定 2 s | 2 s → 6 s → 15 s 自适应 |
| 页面切到后台 | 继续轮询 | 停止 |

三条原则，改代码时请守住：

1. **一次 `awk` 读多个文件**，不要写 `a=$(cat f1); b=$(cat f2)`，每次都是 fork。
2. **任何「遍历一个目录再挨个读」的循环都要缓存**。96 个 thermal zone 跑一次要几百毫秒。
3. **不要用 `sed` / `tr` 做大字符串处理**，bash/mksh 的 `${var//a/b}` 零 fork。

前端轮询必须尊重三种状态：操作中快速刷新、长时间闲置降频、`document.hidden` 直接停。只写 `setInterval(2000)` 会在慢接口上把请求堆到几十个并发。

---

## HTTP API

`GET /cgi-bin/api.cgi?action=...`

| action | 参数 | 说明 |
|---|---|---|
| `state` | — | 档位、温度、守护状态、两簇与 GPU 详情、档位表 |
| `apply` | `profile=<键>` | 切档，键来自 `profiles.sh` |
| `set` | `cluster=p0\|p6`、`min`、`max` | 自定义单簇 |
| `setall` | `p0min`、`p0max`、`p6min`、`p6max`、`gpu`(可选) | 原子写入多目标 |
| `gpu` | `level=0..17` | GPU 功耗等级 |
| `watch` | `value=0\|1` | 开关守护 |
| `temp_limit` | `value=35000..65000` | 温度上限（毫摄氏度） |
| `restore` | — | 恢复出厂快照 |

参数走白名单与纯数字校验，没有 `eval`，非法输入返回 `{"ok":false}`。

---

## 备份与还原

| 位置 | 路径 |
|---|---|
| 设备内 | `/data/adb/k90_cpuctl/backup/stock.conf` |

快照内容：两簇的调速器与上下限、GPU 的 `min/max_pwrlevel`、`pwrscale`、`force_clk_on`、`thermal_pwrlevel`、`cooling_device35/37` 状态、`msm_performance` 限制值、`cpufreq/boost`。

三种还原方式：

```bash
su -c "sh /data/adb/modules/k90_cpuctl/bin/cpuctl restore"   # 命令行
# 界面 -> 高级 -> 恢复出厂默认（有二次确认）
# 卸载模块时 uninstall.sh 自动读快照写回
```

重新抓基线：**先切到「出厂默认」再 `backup`**，否则会把当前调节值当成基线存进去。

---

## 临时 root 注意事项

当前 root 可能是临时的，重启后丢失：

- 模块**不会**开机自启，开机后频率自动回到出厂状态（这本身也是安全的）
- 重新拿到 root 后跑一次 `su -c 'sh /data/adb/modules/k90_cpuctl/bin/cpuctl boot'`，恢复上次档位、守护与界面
- `/data/adb` 下的文件与备份持久化，重启不丢

换成持久 root 后，`service.sh` 会自动接管开机自启（等 `boot_completed` 再等 20 秒，避开 perf HAL 初始化）。

---

## 改代码前必读（都是踩过的坑）

| 问题 | 原因 | 处理 |
|---|---|---|
| 所有 CGI 返回 401 | busybox httpd 配置要用**空格**分隔，写成冒号会被当「地址 用户名 密码」认证规则 | `httpd.conf` 写 `/cgi-bin *.cgi /system/bin/sh` |
| 点了按钮有反馈但不切换 | 前端请求少了 `action=` 前缀，落到「读取状态」分支 | `api("action="+q)` |
| 滑块误触改频率 | `input[type=range]` 在移动端抢手势 | 自定义面板整体换成 `<select>`，值不变不下发 |
| 切档后某簇没变 | 守护在「写频率」与「写档位」之间用旧档位覆盖一次 | 先写 `profile` 再写频率 |
| 出现 min=max 的异常档 | 撞上系统 boost，min 被抬到 max | 写入后校验并重试 |
| 守护自我复制 | `mksh` 遇到函数体内 `&` 会把调用上下文 fork 成子 shell | 后台启动挪到 `web_spawn.sh` / `watch_run.sh`，`mkdir` 原子锁保单实例 |
| `setsid` 留空壳进程 | toybox 的 `setsid` 不支持 `-f` | 改 `nohup` |
| 读 `max_clock_mhz` 偶发 Permission denied | 与写入同一时刻竞争 | 重试即可，无实际影响 |
| `adb forward` 突然失效 | adb server 被重启，转发规则丢失 | 重新 `adb forward` |
| 待机也耗电、内核态跑满一个核 | **内存耗尽（15 G 只剩 142 MB，swap 8.7 G）时 fork 从 2 ms 涨到 20 ms**；CGI 单请求 fork 上百次 → 一次 `state` 要 4 s，而前端每 2 s 轮询一次，请求无限堆积 | `api.cgi` 合并 sysfs 读取、缓存 thermal zone 列表、`jstr` 改纯 shell 替换；前端轮询自适应 |
| CGI 特别慢 | `cpu_temp()` 遍历 96 个 `thermal_zone`，每个读 `type`+`temp` 两次 = 192 次 fork | 首次运行缓存 zone 路径到 `$STATE/tz_*.list`，之后一次 `awk` 读完 |
| 一条 `printf` 发 30 个参数 | 每个 `$(get ...)` 都是一次 fork | 一次 `awk` 批量读 15 个标量，`while IFS='\|' read` 分发到变量 |

---

## 适配其他机型

1. `bin/profiles.sh` 的频点与 GPU 等级
2. `bin/cpuctl` 顶部的 `policy*` 路径、KGSL 节点路径、温度聚合方式
3. `uninstall.sh` 的出厂还原项

界面与 CGI 都是动态读表，一般不需求改。

---

## 卸载

管理器里删除模块即可。`uninstall.sh` 依次：停守护 → 停界面 → 读快照还原 CPU/GPU → 清理运行状态（**保留备份文件**）。

---

## License

[MIT](LICENSE)
