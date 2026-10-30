package com.langrm.k90hud;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.LinearLayout;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;

/**
 * 极简控制页: 授悬浮窗权限 / 真正的悬浮窗开关 / 横屏显示独立开关 / 调 X、Y 位置。
 *
 * 注意: 本类**不能有 lambda 或匿名内部类** —— 本机这套 d8(8.2.2) 编译带 InnerClasses
 * 属性的 class 会 NPE, 换 JDK 21 也一样。所以让 Activity 自己 implements 监听接口。
 *
 * 坐标语义(v1.7.1 起): HUD 顶部水平居中。X = 相对屏幕水平中心的偏移(dp), 300=正中,
 * 越小越靠左; Y = 距屏幕顶部的距离(dp)。竖屏恒定显示; 横屏是否显示由横屏开关决定。
 */
public class MainActivity extends Activity
        implements View.OnClickListener, SeekBar.OnSeekBarChangeListener,
                   CompoundButton.OnCheckedChangeListener {

    private static final int X_CENTER = 300;   // 与 HudService 保持一致
    private static final String KEY_HUD_ON = "hud_on";           // 悬浮窗总开关
    private static final String KEY_LANDSCAPE = "landscape_show"; // 横屏显示开关

    private SharedPreferences sp;
    private TextView tvPos;
    private SeekBar sx;
    private SeekBar sy;
    private Button btnAuth;
    private Button btnToggle;
    private CheckBox ckbLandscape;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        sp = getSharedPreferences("hud", MODE_PRIVATE);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int p = dp(20);
        root.setPadding(p, dp(60), p, p);
        root.setBackgroundColor(Color.parseColor("#101418"));

        TextView t1 = new TextView(this);
        t1.setText("K90 状态栏 HUD");
        t1.setTextSize(20);
        t1.setTextColor(Color.WHITE);
        root.addView(t1);

        TextView t2 = new TextView(this);
        t2.setText("把 CPU 频率/温度居中显示在屏幕顶部。数据由模块写进 "
                + "/data/local/tmp/k90_hud.txt，本应用只负责显示，不需要 root。"
                + "竖屏恒定显示；横屏可在下方单独开关。");
        t2.setTextSize(13);
        t2.setTextColor(Color.parseColor("#9aa7b4"));
        t2.setPadding(0, dp(8), 0, dp(18));
        root.addView(t2);

        btnAuth = mkBtn("① 授予悬浮窗权限");
        btnAuth.setOnClickListener(this);
        root.addView(btnAuth);

        btnToggle = mkBtn("② 开启 / 关闭悬浮窗");
        btnToggle.setOnClickListener(this);
        root.addView(btnToggle);
        updateToggleLabel();

        // 横屏显示独立开关: 勾选=横屏也显示; 不勾=横屏隐藏、竖屏照常。
        // 先 setChecked 再绑监听, 避免 onCreate 里的赋值触发回调写 sp。
        ckbLandscape = new CheckBox(this);
        ckbLandscape.setText("横屏也显示（不勾则横屏隐藏、竖屏照常显示）");
        ckbLandscape.setTextSize(13);
        ckbLandscape.setTextColor(Color.WHITE);
        ckbLandscape.setPadding(0, dp(16), 0, dp(4));
        ckbLandscape.setChecked(sp.getBoolean(KEY_LANDSCAPE, true));
        ckbLandscape.setOnCheckedChangeListener(this);
        root.addView(ckbLandscape);

        tvPos = new TextView(this);
        tvPos.setTextSize(13);
        tvPos.setTextColor(Color.WHITE);
        tvPos.setPadding(0, dp(22), 0, dp(4));
        root.addView(tvPos);

        int[] cur = readPos();
        sx = new SeekBar(this);
        sx.setMax(600);
        sx.setProgress(cur[0]);
        sx.setOnSeekBarChangeListener(this);

        sy = new SeekBar(this);
        sy.setMax(120);
        sy.setProgress(cur[1]);
        sy.setOnSeekBarChangeListener(this);

        updatePosLabel(sx.getProgress(), sy.getProgress());
        root.addView(sx);
        root.addView(sy);

        TextView t3 = new TextView(this);
        t3.setText("上滑条 = X（相对屏幕水平中心偏移，300=正中，越小越靠左），"
                + "下滑条 = Y（距顶部距离，单位 dp）。改完实时生效。");
        t3.setTextSize(12);
        t3.setTextColor(Color.parseColor("#6b7885"));
        root.addView(t3);

        setContentView(root);
    }

    @Override protected void onResume() {
        super.onResume();
        updateToggleLabel();
    }

    @Override public void onClick(View v) {
        if (v == btnAuth) {
            try {
                startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:" + getPackageName())));
            } catch (Exception e) {
                Toast.makeText(this, "打开授权页失败: " + e, Toast.LENGTH_LONG).show();
            }
        } else if (v == btnToggle) {
            // 真正的开关: 把用户意图写进 hud_on, 再启/停服务。
            // 持久化是为了让 HudService 在开机 service.sh 拉起时读到 false 就自杀,
            // 不会把用户关掉的悬浮窗又复活。
            boolean on = sp.getBoolean(KEY_HUD_ON, true);
            if (on) {
                sp.edit().putBoolean(KEY_HUD_ON, false).apply();
                stopService(new Intent(this, HudService.class));
                Toast.makeText(this, "悬浮窗已关闭", Toast.LENGTH_SHORT).show();
            } else {
                if (!Settings.canDrawOverlays(this)) {
                    Toast.makeText(this, "先授予悬浮窗权限", Toast.LENGTH_SHORT).show();
                    return;
                }
                sp.edit().putBoolean(KEY_HUD_ON, true).apply();
                startForegroundService(new Intent(this, HudService.class));
                Toast.makeText(this, "悬浮窗已开启", Toast.LENGTH_SHORT).show();
            }
            updateToggleLabel();
        }
    }

    @Override public void onCheckedChanged(CompoundButton b, boolean checked) {
        if (b == ckbLandscape) {
            sp.edit().putBoolean(KEY_LANDSCAPE, checked).apply();
            Toast.makeText(this,
                    checked ? "横屏显示：开（横竖都显示）" : "横屏显示：关（横屏时隐藏）",
                    Toast.LENGTH_SHORT).show();
        }
    }

    @Override public void onProgressChanged(SeekBar s, int v, boolean fromUser) {
        // savedAt 让 HudService 知道"App 这边的设置比 adb 文件更新"，否则滑块永远不生效
        sp.edit().putInt("xoff", sx.getProgress())
                .putInt("yoff", sy.getProgress())
                .putLong("savedAt", System.currentTimeMillis())
                .apply();
        updatePosLabel(sx.getProgress(), sy.getProgress());
    }

    @Override public void onStartTrackingTouch(SeekBar s) { }

    @Override public void onStopTrackingTouch(SeekBar s) { }

    private void updateToggleLabel() {
        boolean on = sp.getBoolean(KEY_HUD_ON, true);
        btnToggle.setText(on ? "② 关闭悬浮窗（当前：开启）"
                             : "② 开启悬浮窗（当前：关闭）");
    }

    private void updatePosLabel(int x, int y) {
        int dx = x - X_CENTER;
        String hint = dx == 0 ? "正中" : (dx < 0 ? "左偏 " + (-dx) + "dp" : "右偏 " + dx + "dp");
        tvPos.setText("X = " + x + " (" + hint + ")    Y = " + y + " dp");
    }

    private Button mkBtn(String s) {
        Button btn = new Button(this);
        btn.setText(s);
        btn.setAllCaps(false);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(10);
        btn.setLayoutParams(lp);
        return btn;
    }

    /** 读 /data/local/tmp/k90_hud_pos.txt（若比 App 存的更新），否则用 App 存的 */
    private int[] readPos() {
        int x = sp.getInt("xoff", X_CENTER), y = sp.getInt("yoff", 0);
        try {
            java.io.File f = new java.io.File("/data/local/tmp/k90_hud_pos.txt");
            if (f.exists() && f.lastModified() > sp.getLong("savedAt", 0L)) {
                java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f));
                String ln = r.readLine();
                r.close();
                if (ln != null) {
                    String[] a = ln.trim().split("\\s+");
                    if (a.length >= 2) { x = Integer.parseInt(a[0]); y = Integer.parseInt(a[1]); }
                }
            }
        } catch (Throwable ignored) { }
        return new int[]{x, y};
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}
