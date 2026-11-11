package com.hwn.modelviewer;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.database.Cursor;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.webkit.JavascriptInterface;
import android.webkit.MimeTypeMap;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Offline Android experiment. Large native stream readers have not yet been ported. */
public final class MainActivity extends Activity {
    private static final String HOST = "appassets.androidplatform.net";
    private static final String BASE = "https://" + HOST + "/";
    private static final int PICK = 42;
    private static final Set<String> MODELS = new HashSet<>(Arrays.asList(
        "3dm", "3ds", "3mf", "amf", "bim", "brep", "dae", "fbx", "fcstd", "gltf", "glb",
        "ifc", "iges", "igs", "step", "stp", "stl", "obj", "off", "ply", "wrl", "zip"));
    private final ExecutorService importer = Executors.newSingleThreadExecutor();
    private WebView web;
    private TextView title, status;
    private Button open;
    private FrameLayout busyOverlay;
    private boolean ready, loading;
    private JSONArray waiting;
    private File imports;
    private File currentImport;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        imports = new File(getCacheDir(), "viewer-imports");
        imports.mkdirs();
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(247, 248, 250));
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                v.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            } else {
                v.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                    insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
        LinearLayout header = new LinearLayout(this);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(dp(16), dp(4), dp(8), dp(4));
        title = new TextView(this);
        title.setText("3D 模型查看器 · 安卓测试");
        title.setTextSize(17);
        title.setTextColor(Color.rgb(30, 35, 42));
        header.addView(title, new LinearLayout.LayoutParams(0, dp(48), 1));
        title.setGravity(Gravity.CENTER_VERTICAL);
        open = new Button(this);
        open.setText("打开文件");
        open.setOnClickListener(v -> pickFiles());
        header.addView(open);
        root.addView(header);
        status = new TextView(this);
        status.setText("本机离线测试版 · 请选择模型文件");
        status.setPadding(dp(16), dp(5), dp(16), dp(7));
        root.addView(status);
        FrameLayout container = new FrameLayout(this);
        web = new WebView(this);
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setSupportMultipleWindows(false);
        web.addJavascriptInterface(new Bridge(), "AndroidBridge");
        web.setWebViewClient(new LocalClient());
        container.addView(web, new FrameLayout.LayoutParams(-1, -1));
        busyOverlay = new FrameLayout(this);
        busyOverlay.setBackgroundColor(0x33000000);
        busyOverlay.setClickable(true);
        ProgressBar spinner = new ProgressBar(this);
        FrameLayout.LayoutParams spin = new FrameLayout.LayoutParams(dp(48), dp(48), Gravity.CENTER);
        busyOverlay.addView(spinner, spin);
        busyOverlay.setVisibility(View.GONE);
        container.addView(busyOverlay, new FrameLayout.LayoutParams(-1, -1));
        root.addView(container, new LinearLayout.LayoutParams(-1, 0, 1));
        setContentView(root);
        web.loadUrl(BASE + "index.html");
        handleIntent(getIntent());
        if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            String sample = getIntent().getStringExtra("debug-sample");
            if ("teapot".equals(sample)) {
                waiting = new JSONArray().put(BASE + "assets/models/utah_teapot.stl");
                setLoading(true, "正在打开内置测试模型…");
            } else if ("glb".equals(sample) || "3dm".equals(sample)) {
                String asset = "glb".equals(sample) ? "DamagedHelmet.glb" : "RhinoLogo.3dm";
                waiting = new JSONArray().put(BASE + "assets/models/" + asset);
                setLoading(true, "正在打开内置测试模型…");
            } else if ("picker".equals(sample)) {
                pickFiles();
            } else if ("import".equals(sample)) {
                try (InputStream input = getAssets().open("assets/models/utah_teapot.stl");
                     FileOutputStream output = new FileOutputStream(new File(getCacheDir(), "android-test-teapot.stl"))) {
                    byte[] buffer = new byte[8192];
                    int count;
                    while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
                    importFiles(Arrays.asList(Uri.parse("content://com.hwn.modelviewer.test/teapot")));
                } catch (Exception e) { showError("测试文件无法读取"); }
            }
        }
    }

    private int dp(int value) { return (int)(value * getResources().getDisplayMetrics().density + .5f); }

    private void pickFiles() {
        if (loading) return;
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        startActivityForResult(intent, PICK);
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != PICK || resultCode != RESULT_OK || data == null) return;
        List<Uri> files = new ArrayList<>();
        ClipData clip = data.getClipData();
        if (clip != null) for (int i = 0; i < clip.getItemCount(); i++) files.add(clip.getItemAt(i).getUri());
        else if (data.getData() != null) files.add(data.getData());
        importFiles(files);
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleIntent(intent);
    }

    private void handleIntent(Intent intent) {
        if (intent == null) return;
        Uri uri = null;
        if (Intent.ACTION_VIEW.equals(intent.getAction())) uri = intent.getData();
        if (Intent.ACTION_SEND.equals(intent.getAction())) {
            if (android.os.Build.VERSION.SDK_INT >= 33) uri = intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri.class);
            else uri = intent.getParcelableExtra(Intent.EXTRA_STREAM);
        }
        if (uri != null && "content".equals(uri.getScheme())) importFiles(Arrays.asList(uri));
    }

    private String fileName(Uri uri) {
        try (Cursor c = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                String name = c.getString(0);
                if (name != null) return name.replace('/', '_').replace('\\', '_');
            }
        } catch (Exception ignored) { }
        return "file";
    }

    private static String ext(String name) {
        int dot = name.lastIndexOf('.');
        return dot < 0 ? "" : name.substring(dot + 1).toLowerCase(Locale.ROOT);
    }

    private void importFiles(List<Uri> files) {
        if (files.isEmpty()) return;
        if (loading) { showError("当前模型正在处理，请等待完成后再打开其他文件。"); return; }
        List<String> names = new ArrayList<>();
        int modelCount = 0;
        int primaryIndex = -1;
        for (int index = 0; index < files.size(); index++) {
            Uri uri = files.get(index);
            String name = fileName(uri);
            String extension = ext(name);
            if (extension.equals("max") || extension.equals("blend")) {
                showError("安卓测试版暂不支持直接打开 MAX 或 BLEND 工程，请先从原软件导出。"); return;
            }
            if (MODELS.contains(extension)) { modelCount++; primaryIndex = index; }
            if (names.contains(name)) { showError("选择的文件中有同名文件，请分别处理。"); return; }
            names.add(name);
        }
        if (modelCount != 1) {
            showError("每次选择一个模型，可同时选择材质、贴图或 BIN 等配套文件。SKP、DWG 和 DXF 尚未移植。"); return;
        }
        List<Uri> orderedFiles = new ArrayList<>(files);
        if (primaryIndex != 0) {
            orderedFiles.add(0, orderedFiles.remove(primaryIndex));
            names.add(0, names.remove(primaryIndex));
        }
        setLoading(true, "正在复制文件到设备缓存…");
        File directory = new File(imports, UUID.randomUUID().toString());
        ActivityManager manager = (ActivityManager)getSystemService(ACTIVITY_SERVICE);
        final long maxBytes = Math.min(128L * 1024 * 1024, (long)manager.getMemoryClass() * 1024 * 1024 / 5);
        importer.execute(() -> {
            try {
                if (!directory.mkdirs()) throw new Exception("无法创建缓存目录");
                long copied = 0;
                JSONArray urls = new JSONArray();
                for (int i = 0; i < orderedFiles.size(); i++) {
                    Uri uri = orderedFiles.get(i);
                    String name = names.get(i);
                    try (InputStream input = getContentResolver().openInputStream(uri);
                         FileOutputStream output = new FileOutputStream(new File(directory, name))) {
                        if (input == null) throw new Exception("无法读取 " + name);
                        byte[] buffer = new byte[256 * 1024];
                        int n;
                        while ((n = input.read(buffer)) != -1) {
                            copied += n;
                            if (copied > maxBytes) throw new Exception("安卓原型暂不支持此大小的文件；原生分块读取尚未移植。请先用较小的模型测试。");
                            output.write(buffer, 0, n);
                        }
                    }
                    urls.put(BASE + "imports/" + directory.getName() + "/" + Uri.encode(name));
                }
                runOnUiThread(() -> {
                    if (isFinishing() || isDestroyed()) return;
                    waiting = urls;
                    currentImport = directory;
                    title.setText(names.get(0));
                    status.setText("正在解析模型，请稍候…");
                    startPending();
                });
            } catch (Exception e) {
                deleteTree(directory);
                runOnUiThread(() -> {
                    if (isFinishing() || isDestroyed()) return;
                    setLoading(false, "导入失败，可重新选择文件");
                    showError(e.getMessage() == null ? "无法读取所选文件" : e.getMessage());
                });
            }
        });
    }

    private void startPending() {
        if (!ready || waiting == null) return;
        JSONArray urls = waiting;
        waiting = null;
        web.evaluateJavascript("window.O3DVOpenFiles(" + urls.toString() + ");", null);
    }

    private void setLoading(boolean value, String message) {
        loading = value;
        open.setEnabled(!value);
        busyOverlay.setVisibility(value ? View.VISIBLE : View.GONE);
        status.setText(message);
    }

    private void showError(String message) {
        new AlertDialog.Builder(this).setTitle("无法打开模型").setMessage(message).setPositiveButton("确定", null).show();
    }

    private final class Bridge {
        @JavascriptInterface public void postMessage(String json) {
            runOnUiThread(() -> {
                try {
                    JSONObject message = new JSONObject(json);
                    String type = message.optString("type");
                    if (type.equals("ready")) { ready = true; startPending(); }
                    else if (type.equals("request_file_picker")) pickFiles();
                    else if (type.equals("model_loaded")) {
                        JSONArray missing = message.optJSONArray("missingFiles");
                        setLoading(false, missing != null && missing.length() > 0 ? "模型已显示，部分配套文件缺失" : "模型已显示");
                        final File keep = currentImport;
                        importer.execute(() -> {
                            File[] old = imports.listFiles();
                            if (old != null) for (File file : old) if (!file.equals(keep)) deleteTree(file);
                        });
                    } else if (type.equals("load_progress")) {
                        setLoading(true, "正在解析模型，请稍候…");
                    } else if (type.equals("no_importable_file") || type.equals("failed_to_load_file") || type.equals("import_failed") || type.equals("javascript_error")) {
                        setLoading(false, "打开失败，可重新选择文件");
                        showError("无法解析或显示此模型。请检查格式和配套文件；安卓原生读取器尚未移植。");
                    }
                } catch (Exception ignored) { }
            });
        }
    }

    private final class LocalClient extends WebViewClient {
        @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            Uri u = request.getUrl();
            return !"https".equals(u.getScheme()) || !HOST.equals(u.getHost());
        }

        @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
            Uri u = request.getUrl();
            if (!"https".equals(u.getScheme()) || !HOST.equals(u.getHost())) return denied();
            String path = u.getPath();
            if (path == null || path.contains("..") || path.contains("\\")) return denied();
            try {
                if (path.startsWith("/imports/")) {
                    File file = new File(imports, path.substring("/imports/".length()));
                    if (!file.getCanonicalPath().startsWith(imports.getCanonicalPath() + File.separator) || !file.isFile()) return denied();
                    return response(path, new FileInputStream(file));
                }
                String asset = path.equals("/") ? "index.html" : path.substring(1);
                InputStream input = getAssets().open(asset);
                if (asset.equals("index.html")) {
                    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                    byte[] buffer = new byte[8192];
                    int count;
                    while ((count = input.read(buffer)) != -1) bytes.write(buffer, 0, count);
                    String html = new String(bytes.toByteArray(), StandardCharsets.UTF_8);
                    input.close();
                    String shim = "window.webkit={messageHandlers:{o3dv:{postMessage:function(m){AndroidBridge.postMessage(JSON.stringify(m));}}}};";
                    html = html.replace("window.O3DVNativeBridge = true;", "window.O3DVNativeBridge = true;" + shim);
                    input = new ByteArrayInputStream(html.getBytes(StandardCharsets.UTF_8));
                }
                return response(path, input);
            } catch (Exception e) { return denied(); }
        }

        @Override public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
            if (view.getParent() instanceof ViewGroup) ((ViewGroup)view.getParent()).removeView(view);
            view.destroy();
            web = null;
            android.widget.Toast.makeText(MainActivity.this, "查看器进程已退出，请尝试较小的模型。", android.widget.Toast.LENGTH_LONG).show();
            setIntent(new Intent(MainActivity.this, MainActivity.class));
            recreate();
            return true;
        }
    }

    private WebResourceResponse response(String path, InputStream stream) {
        String extension = ext(path);
        String mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension);
        if (extension.equals("wasm")) mime = "application/wasm";
        if (extension.equals("js")) mime = "application/javascript";
        if (mime == null) mime = "application/octet-stream";
        return new WebResourceResponse(mime, null, stream);
    }

    private WebResourceResponse denied() {
        return new WebResourceResponse("text/plain", "utf-8", 404, "Not Found", java.util.Collections.emptyMap(), new ByteArrayInputStream(new byte[0]));
    }

    private static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteTree(child);
        file.delete();
    }

    @Override protected void onDestroy() {
        importer.shutdown();
        if (web != null) { web.removeJavascriptInterface("AndroidBridge"); web.destroy(); }
        super.onDestroy();
    }
}
