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
 *  - 息屏不更新; 横屏自动隐藏(横屏状态栏本来也不显示时间)。
 *  - 位置 X/Y 可调, 字号 9sp。
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
    /** 中位数平滑窗口: 取最近 N 次采样的中位数再显示。
     *  原始频率在 883M↔1.55G 之间来回跳（差 667MHz），单纯加阈值要么挡不住、要么严重滞后；
     *  取中位数能让显示稳定在真实中位水平，且对突发尖峰不敏感。 */
    private static final int SMOOTH_N = 5;

    /** 显示防抖: 变化小于这些阈值就不刷文本, 免得数字跳得晃眼 */
    private static final int TH_FREQ = 150000;   // 150 MHz
    private static final int TH_TEMP = 1000;     // 1 ℃
    private static final int TH_GPU = 100;       // 100 MHz
    private static final int TH_PWR = 500;       // 0.5 W
    private static final long HEARTBEAT_MS = 30000L;  // 再稳也要 30 秒刷一次

    /** 防烧屏: 每 10 分钟整体随机挪一下, 幅度 ±2px(幅度太大会吃掉"下移 2px"这种微调) */
    private static final long JITTER_MS = 10 * 60 * 1000L;
    private static final int JITTER_RANGE = 2;
    private static final String CH = "hud";

    private WindowManager wm;
    private TextView tv;
    private WindowManager.LayoutParams lp;
    private Handler h;
    private SharedPreferences sp;
    private String lastText = "";
    // 最近一次读到的原始值 / 最近一次真正显示的原始值
    private int rLit, rBig, rT, rGc, rMw;
    private int sLit, sBig, sT, sGc, sMw;
    private long lastShownAt = 0;
    private GradientDrawable pillBg;
    private final int[] hLit = new int[SMOOTH_N];
    private final int[] hBig = new int[SMOOTH_N];
    private final int[] hT   = new int[SMOOTH_N];
    private final int[] hGc  = new int[SMOOTH_N];
    private final int[] hMw  = new int[SMOOTH_N];
    private int hIdx = 0, hCnt = 0;
    private boolean hidden = false;
    private final java.util.Random rnd = new java.util.Random();
    private long lastJitter = 0;
    private int jx = 0;
    private int jy = 0;

    @Override public IBinder onBind(Intent i) { return null; }

    @Override public void onCreate() {
        super.onCreate();
        sp = getSharedPreferences("hud", MODE_PRIVATE);
        startForeground(1, buildNotification());
        wm = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        h = new Handler(Looper.getMainLooper());

        tv = new TextView(this);
        // 默认黑字: 用户日常用的 App 绝大多数是白底, 白字在白底上看不见。
        // 底衬用半透明白, 这样落在深色壁纸上时黑字仍然清晰(白底上则几乎不可见, 无副作用)。
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
        lp.gravity = Gravity.TOP | Gravity.LEFT;
        lp.x = dp(sp.getInt("xoff", 96));
        lp.y = dp(sp.getInt("yoff", 0));

        try {
            wm.addView(tv, lp);
        } catch (Throwable e) {
            stopSelf();
            return;
        }
        applyOrientation();
        h.post(this);
    }

    /** 定时回调（本类实现 Runnable，避免匿名内部类） */
    @Override public void run() {
        try { update(); } catch (Throwable ignored) { }
        if (h != null) h.postDelayed(this, 2000);
    }

    private void applyOrientation() {
        boolean land = getResources().getConfiguration().orientation
                == Configuration.ORIENTATION_LANDSCAPE;
        hidden = land;
        if (tv != null) tv.setVisibility(land ? View.GONE : View.VISIBLE);
    }

    @Override public void onConfigurationChanged(Configuration c) {
        super.onConfigurationChanged(c);
        applyOrientation();
    }

    private void update() {
        // 每轮直接查一次方向: 不依赖 onConfigurationChanged 回调
        // (Service 的回调在某些 ROM 上不稳定, 自己查最保险)
        boolean land = getResources().getConfiguration().orientation
                == Configuration.ORIENTATION_LANDSCAPE;
        if (land != hidden) applyOrientation();
        if (hidden) return;
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm != null && !pm.isInteractive()) return;

        int xd = sp.getInt("xoff", 96);
        int yd = sp.getInt("yoff", 0);
        // 允许从 adb 直接调位置: echo "x y" > /data/local/tmp/k90_hud_pos.txt (单位 dp)
        // 这样不用打开 App 拖滑块, 我在这边改完立刻能看到效果
        File pf = new File(POS);
        if (pf.exists()) {
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
        // 防烧屏: 每 JITTER_MS 换一次随机偏移(-3..3 px), 让像素别长期压在同一处
        long now = System.currentTimeMillis();
        if (now - lastJitter > JITTER_MS) {
            lastJitter = now;
            jx = rnd.nextInt(JITTER_RANGE * 2 + 1) - JITTER_RANGE;
            jy = rnd.nextInt(JITTER_RANGE * 2 + 1) - JITTER_RANGE;
        }
        int x = dp(xd) + jx;
        int y = dp(yd) + BASE_DY_PX + jy;
        if (y < 0) y = 0;
        if (x < 0) x = 0;
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
        sLit = rLit; sBig = rBig; sT = rT; sGc = rGc; sMw = rMw;
        lastShownAt = System.currentTimeMillis();
    }

    /**
     * 读模块写的 "<超大核kHz> <小核kHz> <温度m℃>"，排版成 "2.34G/1.12G 39°"。
     * 排版放在 App 侧做的原因: 模块少做取模拼接, 也能随时改显示格式而不用动 shell。
     */
    /** 读一行 "<性能核kHz> <超大核kHz> <温度m℃> <GPUMHz> <功耗mW>" 到 r* 字段 */
    private boolean readRaw() {
        File f = new File(STATE);
        if (!f.exists()) return false;
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
            return rBig > 0;
        } catch (Throwable e) {
            return false;
        } finally {
            try { if (r != null) r.close(); } catch (Throwable ignored) { }
        }
    }

    /** 变化够不够大到值得重画 */










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

    private boolean changedEnough() {
        if (lastText.isEmpty()) return true;
        if (Math.abs(rLit - sLit) >= TH_FREQ) return true;
        if (Math.abs(rBig - sBig) >= TH_FREQ) return true;
        if (Math.abs(rT - sT) >= TH_TEMP) return true;
        if (Math.abs(rGc - sGc) >= TH_GPU) return true;
        if (Math.abs(rMw - sMw) >= TH_PWR) return true;
        return System.currentTimeMillis() - lastShownAt >= HEARTBEAT_MS;
    }

    /** 排版: CPU: 性能核/超大核  GPU: xxx  TEMP: 39℃  PWR: 1.2W */
    private String render() {
        // 频率/GPU 取中位数做平滑; 温度、功耗变化本来就慢, 直接用最新值(否则会滞后 20 秒)
        int lit = median(hLit), big = median(hBig), t = rT;
        int gc = median(hGc), mw = rMw;
        StringBuilder sb = new StringBuilder(48);
        sb.append("CPU: ").append(fmtFreq(lit)).append('/').append(fmtFreq(big));
        if (gc > 0) sb.append("  GPU: ").append(fmtMhz(gc));
        sb.append("  TEMP: ").append(t / 1000).append("\u2103");
        if (mw > 0) sb.append("  PWR: ").append(fmtW(mw));
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

    /** 功耗: 4700mW -> "4.7W" */
    private String fmtW(int mw) {
        return (mw / 1000) + "." + ((mw % 1000) / 100) + "W";
    }

    /** 1234567kHz -> "1.23G"; 812000kHz -> "812M" */
    private String fmtFreq(int khz) {
        if (khz >= 1000000) {
            int i = khz / 1000000;
            int d = (khz % 1000000) / 10000;      // 两位小数
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
                .setContentText("正在状态栏显示实时频率/温度")
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
        super.onDestroy();
    }
}
