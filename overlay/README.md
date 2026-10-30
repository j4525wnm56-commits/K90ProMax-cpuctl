# K90 HUD 悬浮窗

把 CPU 频率/温度贴在**状态栏那一行**（网速左边、或挖孔左边，位置可调）。
配套模块：`../K90ProMax-cpuctl`（v1.6.0 起把数据写进 `/data/local/tmp/k90_hud.txt`）。

## 为什么不是通知

试过两条路，都不行，最后才做悬浮窗：

| 方案 | 结果 |
|---|---|
| 常驻通知 | 图标只能出现在**左上角**，到不了网速那边 |
| 通知小图标画成文字（`-i file://...png`） | **MIUI 直接忽略自定义图标**，状态栏显示的是 shell 的默认图标（截图验证过） |
| 悬浮窗 | ✅ 想放哪放哪，横屏自动隐藏 |

## 安装（一条命令）

```sh
cd ~/WorkBuddy/2026-10-30-20-32-42/k90-hud-overlay
./setup.sh
```

它会：装 APK → `appops` 给悬浮窗权限 → 拉起前台服务 → 回桌面截图。
之后调位置：打开「K90 HUD」App，两个滑块（X/Y，单位 dp），实时生效。

## 调位置（不用开 App）

```sh
./tune.sh 96 0     # X=96dp Y=0dp，写 /data/local/tmp/k90_hud_pos.txt，2 秒内生效
./tune.sh shot     # 只截图
```

`HudService` 每 2 秒读一次这个文件，有它就用它、没有才用 App 里存的偏好。
所以可以完全从 adb 侧边看边调。

## 文字颜色：默认黑色（v1.3）

用户日常用的 App 绝大多数是白底，所以**默认黑字**：

| 项 | 值 |
|---|---|
| 文字 | `Color.BLACK`（9sp 等宽加粗） |
| 底衬 | `0x99FFFFFF`（60% 白）—— 白底上几乎不可见，深色壁纸上形成浅色胶囊托住黑字 |
| 白晕 | `setShadowLayer(2f, 0, 0, 0x66FFFFFF)`，深色区兜底 |

实测两种场景都清晰：
- 白色设置页 → 黑字直接贴在白底上，胶囊看不出来，跟原生状态栏文字一致
- 深色壁纸桌面 → 半透明白胶囊变成浅灰底，黑字仍可读

（"自动跟随背景变色"已放弃，原因见下节。）

## 显示内容（v1.2）

```
CPU: 883M/691M  GPU: 539M  TEMP: 39℃  PWR: 0.3W
└─┬─┘ └──┬──┘   └──┬──┘   └──┬──┘   └──┬──┘
  │      │          │         │         └─ 整机功耗（电池 current×voltage）
  │      │          │         └─────────── CPU 最高温（21 个 cpu* zone 取最大）
  │      │          └───────────────────── GPU 频率（kgsl clock_mhz）
  │      └──────────────────────────────── 性能核 cpu0-5 / 超大核 cpu6-7
  └─────────────────────────────────────── 标签缩写，中文版太宽（占满半屏）故弃用
```

- 刷新 **5 秒**一次（`cpuctl hud interval <秒>` 可改 1–60；2s 太快、数字跳得晃眼，已调慢）
- 整体**下移 3px**；每 **5 分钟**随机偏移 ±3px 防烧屏
- 横屏隐藏（每轮自查 Configuration，不依赖回调）

## 架构：App 不读 sysfs

```
hud.sh (root)  ──写──▶  /data/local/tmp/k90_hud.txt  (5 个整数)
                                        │
                                        ▼  每 2s 轮询
                              HudService (普通 App, 无 root 权限)
                                        │
                                        ▼
                              TextView 悬浮窗贴在状态栏
```

这样 App 完全不需要 root，也不需要读 kgsl/backlight 那些 root-only 节点（那些由模块读）。

## 开销

| 项 | 值 |
|---|---|
| 模块侧采样 | **分级采样**：频率+GPU 每 5s，温度/功耗每 10s（21 个 zone 最贵）。实测约 **单核 0.2%** |
| App 侧 | 每 2s 读一行文本；内容没变不 setText；息屏/横屏跳过。实测 **单核 0.44%** |
| 内存 | 一个 TextView + 一个前台服务 |

## 那条"正在其他应用的上层显示内容"通知

悬浮窗一出现，系统（AOSP `AlertWindowNotification`，`pkg=android`）就会发一条 **ONGOING** 通知，
**划不掉**，也没有系统开关能关。实测唯一可行的手段是把它 snooze 掉：

```sh
cmd notification snooze --for 3600000 \
  "0|android|0|com.android.server.wm.AlertWindowNotification - com.langrm.k90hud|1000"
```

snooze 后它会进 "Snoozed notifications" 分区（重启悬浮窗也不会重新冒出来）。
模块的 `hud.sh` 已经在守护循环里**每 50 分钟自动续一次**。

## 已知的坑

0. **重装 APK 会把悬浮窗权限重置**（`dumpsys window` 里 `mAppOpVisibility=false`，窗口存在但完全不显示）。
   所以 `pm install -r` 之后必须重新 `appops set <pkg> SYSTEM_ALERT_WINDOW allow` 再重启服务。
   模块的 `service.sh` 已改成每次开机自动补一次授权 + 拉起服务。

1. **本机 d8 8.2.2 编不了带内部类的 class**（NPE: `String.length() because parameter1 is null`），
   换 JDK 21 也一样。所以代码里没有任何 lambda / 匿名内部类，全用 `implements`。
   加新功能时务必保持这个约束。
2. 构建不用 Gradle：`aapt2 link` → `javac --release 8` → `d8` → `zipalign` → `apksigner`。
3. 只在 `build-tools/android-14`（r34）+ `platforms/android-34` 上验证过。

## 文件

```
MainActivity.java   控制页（授权 / 开关 / X-Y 滑块）
HudService.java     悬浮窗服务（前台，Runnable 定时刷新）
build.sh            aapt2 + javac + d8 + 签名，不用 Gradle
setup.sh            装 + 授权 + 启动 + 截图
sbar.sh             只截图状态栏看效果
```
