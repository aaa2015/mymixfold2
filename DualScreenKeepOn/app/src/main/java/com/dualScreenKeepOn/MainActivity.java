package com.dualscreen.keepon;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.widget.GridLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class MainActivity extends Activity {

    private static final String ENABLED_FILE = "/data/local/tmp/dualscreen_enabled";
    private static final String LOG_FILE = "/data/local/tmp/dualscreen_v3.log";
    private static final String PREVIEW_FILE = "/data/local/tmp/small_preview.png";
    private static final int SMALL_DISPLAY = 1;

    private ScrollView allContainer;
    private LinearLayout contentLayout;
    private ImageView previewImg;
    private Handler handler;
    private boolean isEnabled = true;
    private boolean previewing = false;
    private String smallScreenSfId = null;
    private SharedPreferences prefs;
    private List<String> pinnedList;
    private List<ResolveInfo> allApps;
    private Thread previewThread;
    private Set<String> runningDisplay1Pkgs = new HashSet<>();
    private Thread runningAppsPollerThread;
    private long lastLaunchTime = 0;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        handler = new Handler(Looper.getMainLooper());
        prefs = getSharedPreferences("ds_prefs", MODE_PRIVATE);
        loadPinned();

        LinearLayout root = new LinearLayout(this);
        root.setBackgroundColor(0xFF1a1a2e);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(12), dp(48), dp(12), dp(12));

        contentLayout = new LinearLayout(this);
        contentLayout.setLayoutParams(new LinearLayout.LayoutParams(-1, -1));
        root.addView(contentLayout);

        previewImg = new ImageView(this);
        previewImg.setBackgroundColor(Color.TRANSPARENT);
        previewImg.setScaleType(ImageView.ScaleType.FIT_CENTER);
        previewImg.setAdjustViewBounds(true);
        previewImg.setMaxHeight(800);
        previewImg.setVisibility(ImageView.INVISIBLE);
        contentLayout.addView(previewImg);

        // 所有应用
        allContainer = new ScrollView(this);
        allContainer.setVerticalScrollBarEnabled(false);
        contentLayout.addView(allContainer);

        setContentView(root);

        loadApps();
        rebuildUI();
        refreshToggle();

        if (isEnabled && prefs.getBoolean("was_previewing", false)) {
            startPreview();
        }

        startRunningAppsPoller();

        handler.postDelayed(new Runnable() {
            public void run() {
                refreshToggle();
                handler.postDelayed(this, 5000);
            }
        }, 5000);
    }

    // ========== 小屏预览 ==========

    private void startPreview() {
        if (previewing) return;
        // 获取 SurfaceFlinger display ID
        if (smallScreenSfId == null) {
            String out = rootExec("dumpsys SurfaceFlinger --display-id");
            smallScreenSfId = parseDisplayId(out);
            if (smallScreenSfId == null) {
                // 默认回退到小米 Mix Fold 2 物理小屏 ID
                smallScreenSfId = "4630946220589295747";
            }
        }

        previewing = true;
        previewImg.setVisibility(ImageView.VISIBLE);

        previewThread = new Thread(() -> {
            while (previewing) {
                rootExec("screencap -d " + smallScreenSfId + " -p " + PREVIEW_FILE);
                runOnUiThread(() -> {
                    try {
                        Bitmap bmp = BitmapFactory.decodeFile(PREVIEW_FILE);
                        if (bmp != null) {
                            previewImg.setImageBitmap(bmp);
                        }
                    } catch (Exception e) {}
                });
                try { Thread.sleep(1500); } catch (Exception e) { break; }
            }
        });
        previewThread.start();
    }

    private String parseDisplayId(String out) {
        if (out == null || out.trim().isEmpty()) return null;
        for (String line : out.split("\n")) {
            if (line.contains("HWC display 1") || line.contains("port=131")) {
                Matcher m = Pattern.compile("\\d{15,}").matcher(line);
                if (m.find()) return m.group();
            }
        }
        Matcher m = Pattern.compile("\\d{15,}").matcher(out);
        List<String> ids = new ArrayList<>();
        while (m.find()) ids.add(m.group());
        if (ids.size() >= 2) {
            return ids.get(1);
        } else if (ids.size() == 1) {
            return ids.get(0);
        }
        return null;
    }

    private void stopPreview() {
        previewing = false;
        if (previewThread != null) previewThread.interrupt();
        previewImg.setVisibility(ImageView.INVISIBLE);
    }

    // ========== UI 构建 ==========

    private TextView makeButton(String text, int color, int radius) {
        TextView btn = new TextView(this);
        btn.setText(text);
        btn.setTextSize(16);
        btn.setTextColor(0xFFFFFFFF);
        btn.setGravity(Gravity.CENTER);
        btn.setPadding(0, dp(12), 0, dp(12));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(color);
        bg.setCornerRadius(dp(radius));
        btn.setBackground(bg);
        return btn;
    }

    private void addText(LinearLayout p, String text, int size, int color, boolean bold, int topM, int botM) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(size);
        tv.setTextColor(color);
        if (bold) tv.setTypeface(Typeface.DEFAULT_BOLD);
        tv.setGravity(Gravity.CENTER_HORIZONTAL);
        tv.setPadding(0, topM, 0, botM);
        p.addView(tv);
    }

    private int dp(int dp) {
        return (int) (dp * getResources().getDisplayMetrics().density);
    }

    private void savePinned() {
        StringBuilder sb = new StringBuilder();
        for (String s : pinnedList) {
            if (sb.length() > 0) sb.append(",");
            sb.append(s);
        }
        prefs.edit().putString("pinned_apps", sb.toString()).apply();
    }

    private void loadPinned() {
        pinnedList = new ArrayList<>();
        String s = prefs.getString("pinned_apps", "");
        if (!s.isEmpty()) {
            for (String part : s.split(",")) {
                if (!part.trim().isEmpty()) {
                    pinnedList.add(part.trim());
                }
            }
        }
    }

    private void loadApps() {
        PackageManager pm = getPackageManager();
        Intent i = new Intent(Intent.ACTION_MAIN);
        i.addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> rawApps = pm.queryIntentActivities(i, 0);

        List<ResolveInfo> filtered = new ArrayList<>();
        String myPkg = getPackageName();
        for (ResolveInfo info : rawApps) {
            if (!info.activityInfo.packageName.equals(myPkg)) {
                filtered.add(info);
            }
        }
        rawApps = filtered;

        // 按照安装时间倒序展示
        Collections.sort(rawApps, (a, b) -> {
            long tA = getInstallTime(pm, a.activityInfo.packageName);
            long tB = getInstallTime(pm, b.activityInfo.packageName);
            return Long.compare(tB, tA); // 最新安装的在最前
        });

        // 构造置顶与非置顶列表
        List<ResolveInfo> pinnedResolve = new ArrayList<>();
        List<ResolveInfo> nonPinnedResolve = new ArrayList<>();

        // 按置顶顺序依次加入
        for (String comp : pinnedList) {
            for (ResolveInfo info : rawApps) {
                String c = info.activityInfo.packageName + "/" + info.activityInfo.name;
                if (c.equals(comp)) {
                    pinnedResolve.add(info);
                    break;
                }
            }
        }

        for (ResolveInfo info : rawApps) {
            String c = info.activityInfo.packageName + "/" + info.activityInfo.name;
            if (!pinnedList.contains(c)) {
                nonPinnedResolve.add(info);
            }
        }

        allApps = new ArrayList<>();
        allApps.addAll(pinnedResolve);
        allApps.addAll(nonPinnedResolve);
    }

    private long getInstallTime(PackageManager pm, String pkg) {
        try {
            return pm.getPackageInfo(pkg, 0).firstInstallTime;
        } catch (Exception e) {
            return 0;
        }
    }

    private void rebuildUI() {
        loadApps();
        allContainer.removeAllViews();
        PackageManager pm = getPackageManager();

        boolean isPortrait = getResources().getConfiguration().orientation == android.content.res.Configuration.ORIENTATION_PORTRAIT;

        // 动态设置 contentLayout 布局方向与权重占比
        contentLayout.setOrientation(isPortrait ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        contentLayout.setLayoutParams(new LinearLayout.LayoutParams(-1, -1));

        // 设置小屏预览容器尺寸与自适应占比
        LinearLayout.LayoutParams imgP;
        if (isPortrait) {
            imgP = new LinearLayout.LayoutParams(0, -1, 1.0f);
            imgP.leftMargin = dp(8);
            imgP.rightMargin = 0; imgP.topMargin = 0; imgP.bottomMargin = 0;
            previewImg.setMaxHeight(Integer.MAX_VALUE);
        } else {
            imgP = new LinearLayout.LayoutParams(-1, 0, 1.0f);
            imgP.topMargin = 0; imgP.bottomMargin = dp(8);
            imgP.leftMargin = 0; imgP.rightMargin = 0;
            previewImg.setMaxHeight(Integer.MAX_VALUE);
        }
        previewImg.setLayoutParams(imgP);

        // 设置所有应用容器尺寸与自适应占比
        LinearLayout.LayoutParams allP;
        if (isPortrait) {
            allP = new LinearLayout.LayoutParams(0, -1, 1.2f);
            allP.rightMargin = dp(8);
            allP.leftMargin = 0; allP.topMargin = 0; allP.bottomMargin = 0;
        } else {
            allP = new LinearLayout.LayoutParams(-1, 0, 1.2f);
            allP.topMargin = 0; allP.bottomMargin = dp(8);
            allP.leftMargin = 0; allP.rightMargin = 0;
        }
        allContainer.setLayoutParams(allP);

        // 动态控制子 View 左右 / 上下顺序
        contentLayout.removeAllViews();
        if (isPortrait) {
            contentLayout.addView(allContainer);
            contentLayout.addView(previewImg);
        } else {
            contentLayout.addView(previewImg);
            contentLayout.addView(allContainer);
        }

        int columns = isPortrait ? 6 : 10;

        GridLayout grid = new GridLayout(this);
        grid.setColumnCount(columns);
        grid.setLayoutParams(new LinearLayout.LayoutParams(-1, -2));

        int idx = 0;
        for (ResolveInfo info : allApps) {
            String comp = info.activityInfo.packageName + "/" + info.activityInfo.name;
            boolean isPinned = pinnedList.contains(comp);
            String pkgName = info.activityInfo.packageName;
            boolean isRunning = runningDisplay1Pkgs.contains(pkgName);
            String name = info.loadLabel(pm).toString();

            LinearLayout cell = new LinearLayout(this);
            cell.setOrientation(LinearLayout.VERTICAL);
            cell.setGravity(Gravity.CENTER);
            cell.setPadding(dp(2), dp(8), dp(2), dp(8));
            
            GradientDrawable bg = new GradientDrawable();
            bg.setCornerRadius(dp(8));

            ImageView iv = new ImageView(this);
            iv.setImageDrawable(info.loadIcon(pm));
            LinearLayout.LayoutParams ip = new LinearLayout.LayoutParams(dp(36), dp(36));
            ip.gravity = Gravity.CENTER;
            iv.setLayoutParams(ip);
            cell.addView(iv);

            TextView tv = new TextView(this);
            tv.setTextSize(8);
            tv.setGravity(Gravity.CENTER);
            tv.setMaxLines(1);
            tv.setPadding(0, dp(4), 0, 0);
            cell.addView(tv);

            tv.setText(name);

            if (isRunning) {
                // 正在运行的应用：森林绿背景，白色文本，无边框
                bg.setColor(0xFF2E7D32);
                tv.setTextColor(0xFFFFFFFF);
            } else if (isPinned) {
                // 置顶的应用：亮金黄色背景，深色文本
                bg.setColor(0xFFFBC02D);
                tv.setTextColor(0xFF1a1a2e);
            } else {
                // 普通应用：深蓝黑色背景，浅灰色文本
                bg.setColor(0xFF16213e);
                tv.setTextColor(0xFFcccccc);
            }
            cell.setBackground(bg);

            GridLayout.LayoutParams gp = new GridLayout.LayoutParams();
            gp.width = 0;
            gp.height = -2;
            gp.columnSpec = GridLayout.spec(idx % columns, 1, 1f);
            gp.rowSpec = GridLayout.spec(idx / columns);
            gp.setMargins(dp(2), dp(2), dp(2), dp(2));
            cell.setLayoutParams(gp);

            cell.setOnClickListener(v -> {
                if (isRunning) {
                    Toast.makeText(this, "🛑 终止: " + name, Toast.LENGTH_SHORT).show();
                    stopPreview();
                    prefs.edit().putBoolean("was_previewing", false).apply();
                    setModuleEnabled(false, true);

                    new Thread(() -> {
                        rootExec("am force-stop " + pkgName);
                        try { Thread.sleep(500); } catch (Exception e) {}
                        Set<String> latest = getRunningDisplay1Packages();
                        runningDisplay1Pkgs = latest;
                        runOnUiThread(() -> rebuildUI());
                    }).start();
                } else {
                    lastLaunchTime = System.currentTimeMillis();
                    // 自动置顶：非置顶应用加入到末尾，已置顶应用不再调整位置
                    if (!pinnedList.contains(comp)) {
                        pinnedList.add(comp);
                        savePinned();
                    }

                    // 自动开启预览
                    if (!previewing) {
                        startPreview();
                    }
                    prefs.edit().putBoolean("was_previewing", true).apply();

                    // 启用双屏模式 (manualClick is true)
                    setModuleEnabled(true, true);

                    // 启动新应用前，在后台强行停止其他已经在小屏运行的应用，并延迟在主线程拉起新应用
                    new Thread(() -> {
                        for (String runningPkg : new java.util.ArrayList<>(runningDisplay1Pkgs)) {
                            if (!runningPkg.equals(pkgName)) {
                                rootExec("am force-stop " + runningPkg);
                            }
                        }
                        try { Thread.sleep(300); } catch (Exception e) {}
                        runOnUiThread(() -> launch(comp, name));
                    }).start();

                    // 瞬间触发 1.5 秒后的状态校验，实现极速响应
                    new Thread(() -> {
                        try { Thread.sleep(1500); } catch (Exception e) {}
                        Set<String> latest = getRunningDisplay1Packages();
                        runningDisplay1Pkgs = latest;
                        runOnUiThread(() -> rebuildUI());
                    }).start();

                    rebuildUI();
                }
            });
            cell.setOnLongClickListener(v -> {
                if (pinnedList.contains(comp)) {
                    pinnedList.remove(comp);
                    Toast.makeText(this, "📌 已取消置顶: " + name, Toast.LENGTH_SHORT).show();
                } else {
                    pinnedList.add(comp); // 新增置顶应用放到最后一位
                    Toast.makeText(this, "📌 已置顶到末尾: " + name, Toast.LENGTH_SHORT).show();
                }
                savePinned();
                rebuildUI();
                return true;
            });

            grid.addView(cell);
            idx++;
        }
        allContainer.addView(grid);
    }

    private void launch(String comp, String name) {
        Toast.makeText(this, "启动: " + name, Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            String r = rootExec("am start --display " + SMALL_DISPLAY + " -n " + comp + " -f 0x10000000");
            boolean success = r.contains("Starting") || r.contains("Warning") || 
                              (!r.trim().isEmpty() && !r.contains("Error") && !r.contains("Exception"));
            runOnUiThread(() -> Toast.makeText(this,
                success ? "✅ " + name : "❌ " + name,
                Toast.LENGTH_SHORT).show());

            // 启动后延迟 4 秒重新拉起控制台，防止系统折叠屏切换过渡时将控制台隐藏
            try { Thread.sleep(4000); } catch (Exception e) {}
            rootExec("am start --display 0 -n com.dualscreen.keepon/.MainActivity");
        }).start();
    }

    // ========== 状态管理 ==========

    private void refreshToggle() {
        isEnabled = readEnabled();
    }

    private void setModuleEnabled(boolean enable) {
        setModuleEnabled(enable, false);
    }

    private void setModuleEnabled(boolean enable, boolean manualClick) {
        // 仅在用户手动点击触发“关闭”时，延迟 4 秒重新拉起控制台，防止系统折叠屏切换过渡时将控制台隐藏
        if (manualClick && !enable) {
            new Thread(() -> {
                try { Thread.sleep(4000); } catch (Exception e) {}
                rootExec("am start --display 0 -n com.dualscreen.keepon/.MainActivity");
            }).start();
        }

        if (isEnabled == enable) return;
        isEnabled = enable;
        try {
            FileWriter w = new FileWriter(ENABLED_FILE);
            w.write(isEnabled ? "1" : "0"); w.close();
        } catch (Exception e) {
            rootExec("echo " + (isEnabled ? "1" : "0") + " > " + ENABLED_FILE);
        }
        if (!isEnabled) {
            stopPreview();
            stopDisplay1Apps();
        }
    }

    private String getDisplay1Section(String out) {
        if (out == null || out.isEmpty()) return "";
        int idx1 = out.indexOf("Display #1");
        if (idx1 == -1) return "";
        int idxNext = out.indexOf("Display #", idx1 + 10);
        String section = idxNext == -1 ? out.substring(idx1) : out.substring(idx1, idxNext);
        int idxSupervisor = section.indexOf("ActivityTaskSupervisor state:");
        if (idxSupervisor != -1) {
            section = section.substring(0, idxSupervisor);
        }
        return section;
    }

    private void stopDisplay1Apps() {
        new Thread(() -> {
            String out = rootExec("dumpsys activity activities");
            String display1Section = getDisplay1Section(out);
            if (display1Section.isEmpty()) return;
            Pattern p = Pattern.compile("ActivityRecord\\{[a-fA-F0-9]+ u\\d+ ([a-zA-Z0-9\\._]+)/");
            Matcher m = p.matcher(display1Section);
            Set<String> packages = new HashSet<>();
            while (m.find()) {
                String pkg = m.group(1);
                if (!pkg.contains("dualscreen") && !pkg.contains("keepon") && 
                    !pkg.contains("launcher") && !pkg.contains("home") && 
                    !pkg.contains("systemui") && !pkg.equals("android")) {
                    packages.add(pkg);
                }
            }
            for (String pkg : packages) {
                rootExec("am force-stop " + pkg);
            }
        }).start();
    }

    private boolean readEnabled() {
        try {
            File f = new File(ENABLED_FILE);
            if (f.exists()) {
                BufferedReader r = new BufferedReader(new FileReader(f));
                String l = r.readLine(); r.close();
                return !"0".equals(l);
            }
        } catch (Exception e) {}
        return true;
    }

    private String rootExec(String cmd) {
        try {
            Process p = Runtime.getRuntime().exec(new String[]{"su", "-c", cmd});
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            BufferedReader e = new BufferedReader(new InputStreamReader(p.getErrorStream()));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) sb.append(line).append("\n");
            while ((line = e.readLine()) != null) sb.append(line).append("\n");
            r.close(); e.close(); p.waitFor();
            return sb.toString();
        } catch (Exception ex) { return ""; }
    }

    private Set<String> getRunningDisplay1Packages() {
        Set<String> packages = new HashSet<>();
        String out = rootExec("dumpsys activity activities");
        String display1Section = getDisplay1Section(out);
        if (display1Section.isEmpty()) return packages;
        Pattern p = Pattern.compile("ActivityRecord\\{[a-fA-F0-9]+ u\\d+ ([a-zA-Z0-9\\._]+)/");
        Matcher m = p.matcher(display1Section);
        while (m.find()) {
            String pkg = m.group(1);
            if (!pkg.contains("dualscreen") && !pkg.contains("keepon") && 
                !pkg.contains("launcher") && !pkg.contains("home") && 
                !pkg.contains("systemui") && !pkg.equals("android")) {
                packages.add(pkg);
            }
        }
        return packages;
    }

    private void startRunningAppsPoller() {
        runningAppsPollerThread = new Thread(() -> {
            while (!isFinishing() && !isDestroyed()) {
                try {
                    Set<String> latest = getRunningDisplay1Packages();
                    
                    // 没有正在运行的应用且已超过启动保护期，自动关闭双屏模式和小屏预览
                    if (isEnabled && latest.isEmpty() && (System.currentTimeMillis() - lastLaunchTime > 8000)) {
                        runOnUiThread(() -> {
                            stopPreview();
                            prefs.edit().putBoolean("was_previewing", false).apply();
                            setModuleEnabled(false);
                        });
                    }

                    if (!latest.equals(runningDisplay1Pkgs)) {
                        runningDisplay1Pkgs = latest;
                        runOnUiThread(this::rebuildUI);
                    }
                } catch (Exception e) {}
                try { Thread.sleep(3000); } catch (InterruptedException e) { break; }
            }
        });
        runningAppsPollerThread.start();
    }

    @Override
    public void onConfigurationChanged(android.content.res.Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        rebuildUI();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        previewing = false;
        if (previewThread != null) previewThread.interrupt();
        if (runningAppsPollerThread != null) runningAppsPollerThread.interrupt();
        handler.removeCallbacksAndMessages(null);
    }
}
