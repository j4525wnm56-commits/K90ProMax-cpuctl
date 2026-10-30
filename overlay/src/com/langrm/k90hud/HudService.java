package com.langrm.k90hud;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;

/**
 * 把模块采样出来的频率/温度画成贴边小悬浮窗。
 *
 * 设计要点:
 *  - 自己不做采样: 模块的 hud.sh 以 root 身份读 sysfs(含 root-only 的 kgsl/backlight),
 *    结果写成 /data/local/tmp/k90_hud.txt。本服务只读这个文件, 完全不需要 root。
 *  - 息屏不更新; 竖屏恒定顶部水平居中显示; 横屏是否显示由 App 里的"横屏显示"开关决定。
 *  - 位置: X = 相对屏幕水平中心的偏移(dp, 300=正中), Y = 距屏幕顶部的距离(dp)。
 *  - 每 2s 读一次状态文件(模块每 5s 采样一次, 100ms 高频读是无谓开销, 已回退)。
 *  - 总开关 hud_on: App 里"关闭悬浮窗"写 false。本服务在 onCreate/onStartCommand 读取,
 *    false 就 stopSelf() 且返回 START_NOT_STICKY —— 这样连开机 service.sh 的强制拉起
 *    也不会把用户关掉的悬浮窗复活。
 *
 * 注意: 本类**不能有匿名内部类** —— 本机这套 d8(8.2.2) 在编译带 InnerClasses 属性的
 * class 时会 NPE("String.length() because parameter1 is null"), 换 JDK 21 也一样。
 * 所以直接 implements Runnable, 用 this 当回调。
 */
public class HudService extends Service implements Runnable {

    private static final String STATE = "/data/local/tmp/k90_hud.txt";
    private static final String POS = "/data/local/tmp/k90_hud_pos.txt";

    /** 整体下移 5 个物理像素(用户逐步调: 3 -> +2) */
    private static final int BASE_DY_PX = 5;
    /** X 滑块中点 = 屏幕水平正中(dp)。滑块 0..600 映射到 -300..+300 的水平偏移。 */
    private static final int X_CENTER = 300;
    /** 默认距顶部距离(dp): 0 = 贴状态栏那一行(用户偏好, 压挖孔也要贴顶)。 */
    private static final int Y_DEFAULT = 0;
    /** 中位数平滑窗口: 取最近 N 次采样的中位数再显示。 */
    private static final int SMOOTH_N = 5;

    /** 显示防抖: 变化小于这些阈值就不刷文本, 免得数字跳得晃眼 */
    private static final int TH_FREQ = 150000;   // 150 MHz
    private static final int TH_TEMP = 1000;     // 1 ℃
    private static final int TH_GPU = 100;       // 100 MHz
    private static final int TH_PWR = 500;       // 0.5 W
    private static final int TH_GPU_USE = 5;     // GPU 占用变化 5% 才重画, 免得数字乱跳
    private static final long HEARTBEAT_MS = 30000L;  // 再稳也要 30 秒刷一次

    /** 防烧屏: 每 10 分钟整体随机挪一下, 幅度 ±2px */
    private static final long JITTER_MS = 10 * 60 * 1000L;
    private static final int JITTER_RANGE = 2;
    private static final String CH = "hud";

    /** 用户总开关: App 里关闭后写 false, 本服务据此自杀, 开机自启也不会强行复活 */
    private static final String KEY_HUD_ON = "hud_on";
    /** 横屏显示独立开关: true=横屏也显示(默认), false=横屏隐藏、竖屏照常 */
    private static final String KEY_LANDSCAPE = "landscape_show";

    private WindowManager wm;
    private TextView tv;
    private WindowManager.LayoutParams lp;
    private Handler h;
    private SharedPreferences sp;
    private String lastText = "";
    // 最近一次读到的原始值 / 最近一次真正显示的原始值
    private int rLit, rBig, rT, rGc, rMw, rChg, rPsi, rFps, rRef, rGpu;
    private int sLit, sBig, sT, sGc, sMw, sChg, sPsi, sFps, sRef, sGpu;
    private long lastShownAt = 0;
    private GradientDrawable pillBg;
    private final int[] hLit = new int[SMOOTH_N];
    private final int[] hBig = new int[SMOOTH_N];
    private final int[] hT   = new int[SMOOTH_N];
    private final int[] hGc  = new int[SMOOTH_N];
    private final int[] hMw  = new int[SMOOTH_N];
    private int hIdx = 0, hCnt = 0;
    /** 当前是否因"横屏 + 关掉了横屏显示"被隐藏 */
    private boolean hidden = false;
    /** 状态文件的 mtime: 没变就跳过解析(模块 5s 写一次, App 2s 轮询一次, 多数轮次可省) */
    private long lastStateMtime = 0;
    /** 是否已经成功解析过至少一次(首轮不能跳过) */
    private boolean haveParsed = false;
    private final java.util.Random rnd = new java.util.Random();
    private long lastJitter = 0;
    private int jx = 0;
    private int jy = 0;

    @Override public IBinder onBind(Intent i) { return null; }

    @Override public void onCreate() {
        super.onCreate();
        sp = getSharedPreferences("hud", MODE_PRIVATE);
        // 用户已在 App 里关闭 → 直接退出, 连窗口都不画。
        // 这条也拦住 service.sh 开机时的无条件 am start-foreground-service。
        if (!sp.getBoolean(KEY_HUD_ON, true)) {
            stopSelf();
            return;
        }
        startForeground(1, buildNotification());
        wm = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        h = new Handler(Looper.getMainLooper());

        tv = new TextView(this);
        tv.setTextColor(Color.BLACK);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 9f);      // 小字
        tv.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        tv.setShadowLayer(2f, 0f, 0f, 0x66FFFFFF);           // 极淡白晕, 深色区兜底
        tv.setIncludeFontPadding(false);
        pillBg = new GradientDrawable();
        pillBg.setColor(0x99FFFFFF);
        pillBg.setCornerRadius(dp(4));
        tv.setBackground(pillBg);
        tv.setPadding(dp(5), dp(1), dp(5), dp(1));
        tv.setText("--");

        lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        // 顶部水平居中: X 相对屏幕水平中心(300=正中), Y 距顶部距离
        lp.gravity = Gravity.CENTER_HORIZONTAL | Gravity.TOP;
        lp.x = dp(sp.getInt("xoff", X_CENTER) - X_CENTER);
        lp.y = dp(sp.getInt("yoff", Y_DEFAULT));

        try {
            wm.addView(tv, lp);
        } catch (Throwable e) {
            stopSelf();
            return;
        }
        applyOrientation();
        h.post(this);
    }

    /** 开机 service.sh / 安装脚本用 am start-foreground-service 拉起时也会经过这里。
     *  hud_on=false → 自杀并返回 START_NOT_STICKY, 防止系统把已关的服务复活。 */
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (sp == null) sp = getSharedPreferences("hud", MODE_PRIVATE);
        if (!sp.getBoolean(KEY_HUD_ON, true)) {
            stopSelf();
            return START_NOT_STICKY;
        }
        return START_STICKY;
    }

    /** 定时回调（本类实现 Runnable，避免匿名内部类）
     *  模块每 5s 采样一次, 这里 2s 读一次文件即可, 不必 100ms 高频空转。 */
    @Override public void run() {
        try { update(); } catch (Throwable ignored) { }
        if (h != null) h.postDelayed(this, 2000);
    }

    /** 每轮自查方向(MIUI 上 onConfigurationChanged 不可靠, 所以轮询):
     *  竖屏 → 恒显示; 横屏 → 取决于 App 里的"横屏显示"开关。 */
    private void applyOrientation() {
        if (tv == null) return;
        Configuration cfg = getResources().getConfiguration();
        boolean landscape = cfg.orientation == Configuration.ORIENTATION_LANDSCAPE;
        boolean shouldHide = landscape && !sp.getBoolean(KEY_LANDSCAPE, true);
        if (shouldHide == hidden) return;   // 状态没变, 不重复 setVisibility
        hidden = shouldHide;
        tv.setVisibility(shouldHide ? View.INVISIBLE : View.VISIBLE);
    }

    @Override public void onConfigurationChanged(Configuration c) {
        super.onConfigurationChanged(c);
        applyOrientation();
    }

    private void update() {
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm != null && !pm.isInteractive()) return;

        applyOrientation();          // 每轮自查方向(不依赖回调)
        if (hidden) return;          // 横屏且关掉了横屏显示 → 不读文件、不渲染

        int xd = sp.getInt("xoff", X_CENTER);
        int yd = sp.getInt("yoff", Y_DEFAULT);
        // 允许从 adb 直接调位置: echo "x y" > /data/local/tmp/k90_hud_pos.txt (单位 dp)
        // 优先级按"谁更新"决定: 比较文件 mtime 与 App 保存时写入的 savedAt, 谁新用谁。
        File pf = new File(POS);
        long prefTs = sp.getLong("savedAt", 0L);
        if (pf.exists() && pf.lastModified() > prefTs) {
            BufferedReader pr = null;
            try {
                pr = new BufferedReader(new FileReader(pf));
                String ln = pr.readLine();
                if (ln != null) {
                    String[] a = ln.trim().split("\\s+");
                    if (a.length >= 2) { xd = Integer.parseInt(a[0]); yd = Integer.parseInt(a[1]); }
                }
            } catch (Throwable ignored) {
            } finally {
                try { if (pr != null) pr.close(); } catch (Throwable ignored) { }
            }
        }
        // 防烧屏: 每 JITTER_MS 换一次随机偏移(-2..2 px)
        long now = System.currentTimeMillis();
        if (now - lastJitter > JITTER_MS) {
            lastJitter = now;
            jx = rnd.nextInt(JITTER_RANGE * 2 + 1) - JITTER_RANGE;
            jy = rnd.nextInt(JITTER_RANGE * 2 + 1) - JITTER_RANGE;
        }
        // X 相对水平中心(可为负=左偏), Y 距顶部(不为负)
        int x = dp(xd - X_CENTER) + jx;
        int y = dp(yd) + BASE_DY_PX + jy;
        if (y < 0) y = 0;
        if (lp.x != x || lp.y != y) {
            lp.x = x; lp.y = y;
            try { wm.updateViewLayout(tv, lp); } catch (Throwable ignored) { }
        }

        if (!readRaw()) return;
        pushSample();
        if (!changedEnough()) return;
        String s = render();
        if (!s.equals(lastText)) {
            lastText = s;
            tv.setText(s);
        }
        sLit = rLit; sBig = rBig; sT = rT; sGc = rGc; sMw = rMw; sChg = rChg; sPsi = rPsi; sFps = rFps; sRef = rRef; sGpu = rGpu;
        lastShownAt = now;
    }

    /** 读一行 "<性能核kHz> <超大核kHz> <温度m℃> <GPUMHz> <功耗mW> <充电> <PSI> <帧率> <刷新率> <GPU占用%>" 到 r* 字段
     *  性能: 模块每 5s 才写一次文件, 这里 2s 轮询一次, 所以有 60% 的轮次是白读。
     *  用 mtime 门控 —— 文件没变就直接返回 false(不解析不重画), 省掉 open+read+split+parse。
     *  注意: 返回 false 会让 update() 提前返回, 但位置更新在 readRaw 之前, 不受影响。 */
    private boolean readRaw() {
        File f = new File(STATE);
        if (!f.exists()) return false;
        long mt = f.lastModified();
        if (mt == lastStateMtime && haveParsed) return false;   // 文件没更新, 跳过
        lastStateMtime = mt;
        BufferedReader r = null;
        try {
            r = new BufferedReader(new FileReader(f));
            String line = r.readLine();
            if (line == null) return false;
            line = line.trim();
            if (line.isEmpty() || "--".equals(line)) return false;
            String[] p = line.split("\\s+");
            if (p.length < 3) return false;
            rLit = Integer.parseInt(p[0]);
            rBig = Integer.parseInt(p[1]);
            rT   = Integer.parseInt(p[2]);
            rGc  = p.length > 3 ? Integer.parseInt(p[3]) : 0;
            rMw  = p.length > 4 ? Integer.parseInt(p[4]) : 0;
            rChg = p.length > 5 ? Integer.parseInt(p[5]) : 0;   // 1 = 正在充电
            rPsi = p.length > 6 ? Integer.parseInt(p[6]) : 0;   // CPU 压力 avg10, %
            rFps = p.length > 7 ? Integer.parseInt(p[7]) : 0;   // 屏幕合成帧率, 静止=0
            rRef = p.length > 8 ? Integer.parseInt(p[8]) : 0;   // 面板刷新率 Hz, 0=节点不存在
            rGpu = p.length > 9 ? Integer.parseInt(p[9]) : 0;   // GPU 占用 %, 静止=0(v1.8.1 新增第10字段)
            haveParsed = true;
            return rBig > 0;
        } catch (Throwable e) {
            return false;
        } finally {
            try { if (r != null) r.close(); } catch (Throwable ignored) { }
        }
    }

    /** 把本次采样压进环形缓冲 */
    private void pushSample() {
        hLit[hIdx] = rLit; hBig[hIdx] = rBig; hT[hIdx] = rT; hGc[hIdx] = rGc; hMw[hIdx] = rMw;
        hIdx = (hIdx + 1) % SMOOTH_N;
        if (hCnt < SMOOTH_N) hCnt++;
    }

    /** 取缓冲里的中位数（未填满时取已填部分） */
    private int median(int[] a) {
        int n = hCnt;
        if (n <= 0) return 0;
        int[] b = new int[n];
        System.arraycopy(a, 0, b, 0, n);
        java.util.Arrays.sort(b);
        return b[n / 2];
    }

    /** 变化够不够大到值得重画 */
    private boolean changedEnough() {
        if (lastText.isEmpty()) return true;
        if (Math.abs(rLit - sLit) >= TH_FREQ) return true;
        if (Math.abs(rBig - sBig) >= TH_FREQ) return true;
        if (Math.abs(rT - sT) >= TH_TEMP) return true;
        if (Math.abs(rGc - sGc) >= TH_GPU) return true;
        if (Math.abs(rMw - sMw) >= TH_PWR) return true;
        if (rChg != sChg) return true;
        if (Math.abs(rPsi - sPsi) >= 2) return true;
        if (Math.abs(rFps - sFps) >= 2) return true;
        if (rRef != sRef) return true;
        if (Math.abs(rGpu - sGpu) >= TH_GPU_USE) return true;
        return System.currentTimeMillis() - lastShownAt >= HEARTBEAT_MS;
    }

    /** 排版: CPU: 性能核/能效核/占用%  GPU: 频率/占用%  TEMP: 39℃  PWR: 1.2W  FPS: -/120Hz
     *  CPU 占用复用 PSI(/proc/pressure/cpu avg10 = 最近10s 在等 CPU 的时间占比), 不额外采样。 */
    private String render() {
        int lit = median(hLit), big = median(hBig), t = rT;
        int gc = median(hGc), mw = rMw;
        StringBuilder sb = new StringBuilder(48);
        sb.append("CPU: ").append(fmtFreq(lit)).append('/').append(fmtFreq(big));
        sb.append('/').append(rPsi).append('%');
        if (gc > 0) {
            sb.append(" GPU: ").append(fmtMhz(gc)).append('/').append(rGpu).append('%');
        }
        sb.append(" TEMP: ").append(t / 1000).append("\u2103");
        sb.append(" PWR: ").append(fmtW(mw));
        if (rChg > 0) sb.append('+');
        if (rRef > 0) {
            sb.append(" FPS: ");
            if (rFps > 0) sb.append(rFps); else sb.append('-');
            sb.append('/').append(rRef).append("Hz");
        }
        return sb.toString();
    }

    /** GPU 频率: 539 -> "539M", 1222 -> "1.22G" */
    private String fmtMhz(int mhz) {
        if (mhz >= 1000) {
            int i = mhz / 1000;
            int d = (mhz % 1000) / 10;
            return i + "." + (d < 10 ? "0" + d : String.valueOf(d)) + "G";
        }
        return mhz + "M";
    }

    /** 功耗: 4700mW -> "4.7W"; 22mW -> "22mW" */
    private String fmtW(int mw) {
        if (mw < 1000) return mw + "mW";
        return (mw / 1000) + "." + ((mw % 1000) / 100) + "W";
    }

    /** 1234567kHz -> "1.23G"; 812000kHz -> "812M" */
    private String fmtFreq(int khz) {
        if (khz >= 1000000) {
            int i = khz / 1000000;
            int d = (khz % 1000000) / 10000;
            return i + "." + (d < 10 ? "0" + d : String.valueOf(d)) + "G";
        }
        return (khz / 1000) + "M";
    }

    private Notification buildNotification() {
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm != null && nm.getNotificationChannel(CH) == null) {
            NotificationChannel c = new NotificationChannel(CH, "状态栏 HUD", NotificationManager.IMPORTANCE_MIN);
            c.setShowBadge(false);
            nm.createNotificationChannel(c);
        }
        return new Notification.Builder(this, CH)
                .setContentTitle("状态栏 HUD")
                .setContentText("正在屏幕顶部居中显示实时频率/温度")
                .setSmallIcon(android.R.drawable.ic_menu_info_details)
                .setOngoing(true)
                .build();
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }

    @Override public void onDestroy() {
        if (h != null) h.removeCallbacks(this);
        try { if (wm != null && tv != null) wm.removeView(tv); } catch (Throwable ignored) { }
        stopForeground(true);
        super.onDestroy();
    }
}
