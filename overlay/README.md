# K90 HUD 悬浮窗

把 CPU 频率/温度贴在**屏幕顶部水平居中**（v1.7.1 起默认 `Gravity.CENTER_HORIZONTAL|TOP`，横屏竖屏都居中显示）。
配套模块：`../K90ProMax-cpuctl`（v1.6.0 起把数据写进 `/data/local/tmp/k90_hud.txt`）。

## 为什么不是通知

试过两条路，都不行，最后才做悬浮窗：

| 方案 | 结果 |
|---|---|
| 常驻通知 | 图标只能出现在**左上角**，到不了网速那边 |
| 通知小图标画成文字（`-i file://...png`） | **MIUI 直接忽略自定义图标**，状态栏显示的是 shell 的默认图标（截图验证过） |
| 悬浮窗 | ✅ 默认顶部水平居中，X/Y 仍可调；横屏竖屏都显示 |

## 安装（一条命令）

```sh
cd ~/WorkBuddy/2026-10-30-20-32-42/k90-hud-overlay
./setup.sh
```

它会：装 APK → `appops` 给悬浮窗权限 → 拉起前台服务 → 回桌面截图。
之后调位置：打开「K90 HUD」App，两个滑块（X/Y，单位 dp），实时生效。

## 调位置（不用开 App）

v1.7.1 起坐标语义：**X = 相对屏幕水平中心的偏移（300=正中，越小越靠左）**，Y = 距顶部距离（0=贴顶）。

```sh
./tune.sh 300 0     # X=300(正中) Y=0(贴顶)，写 /data/local/tmp/k90_hud_pos.txt，2 秒内生效
./tune.sh shot      # 只截图
```

`HudService` 每 2 秒读一次这个文件，有它就用它、没有才用 App 里存的偏好。
所以可以完全从 adb 侧边看边调。

> 顶部挖孔区占 0~48dp，但**挖孔与屏幕顶端之间有一段空白带**，Y=0 时 HUD 正好落在挖孔上方的空白处，不会被遮挡（用户实测偏好此位置）。

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

## 显示内容（v1.8.2）

```
CPU: 883M/691M/12%  GPU: 539M/28%  TEMP: 39℃  PWR: 0.3W  FPS: 119/120Hz
```

| 段 | 含义 |
|---|---|
| `CPU: 性能核/能效核/占用%` | 频率取自各簇 `scaling_cur_freq`；占用 = PSI（`/proc/pressure/cpu` avg10，最近 10s 在等 CPU 的时间占比） |
| `GPU: 频率/占用%` | 频率取自 kgsl `clock_mhz`；占用取自 `gpu_busy_percentage`（0 时不显示括号） |
| `TEMP` | 21 个 `cpu*` thermal zone 取最大（排除 `*trip*` 硬件跳闸阈值） |
| `PWR` | 整机功耗 = 电池 `current_now × voltage_now`（µV×µA=pW，÷1e9 才是 mW）；充电时数值后加 `+` |
| `FPS` | **SurfaceFlinger 全局帧率**（见下节），分母是面板实测刷新率 `hw_vsync_info` |

- 刷新 **5 秒**一次（`cpuctl hud interval <秒>` 可改 1–60；0.1s 高频档因开销过大已回退）
- 整体**下移 3px**；每 **10 分钟**随机偏移 ±2px 防烧屏
- 竖屏恒定显示；横屏是否显示可在 App 里单独开关

### 帧率为什么不用内核 `measured_fps`

内核 `/sys/class/drm/card0-sde-crtc-0/measured_fps` 统计的是 **CRTC 提交的帧**，
SurfaceView 直通渲染的游戏（Unity 等）**不走 CRTC 计数**，会大量漏计。

同一个游戏实测：内核节点读 **36~56 乱跳**，SurfaceFlinger 读 **125 稳定**。

现在的做法：模块侧 `dumpsys SurfaceFlinger --timestats -dump` 取全局 `totalFrames` 与
`statsEnd`，**差分**算帧率（不判断前台包名）。每 10 秒一次（约 30ms），守护退出时 `-disable` 清理。

> `totalFrames` **必须先 `--timestats -enable` 才会累积**（不 enable 时恒定不变）。
> `statsEnd` 是**秒级**时间戳，帧率 = Δframes / Δ秒。

## 架构：App 不读 sysfs

```
hud.sh (root)  ──写──▶  /data/local/tmp/k90_hud.txt  (10 个整数)
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
| 模块侧采样 | 采样一轮 **5ms**（v1.8.2 从 439ms 优化下来）；温度每 30s 分级采样，GPU 占用单次读 + 保持。守护实测 **单核 0.22%** |
| App 侧 | 每 2s 读一行文本（用**文件 mtime 门控**，文件没变就跳过解析）；内容没变不 setText。实测 **单核 0.13%** |
| 内存 | 一个 TextView + 一个前台服务（RSS ~170MB 是 ART 运行时基线，与系统进程同量级） |

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
