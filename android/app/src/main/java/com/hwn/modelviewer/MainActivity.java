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
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

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
    private Button cancel;
    private FrameLayout busyOverlay;
    private boolean ready, loading;
    private JSONArray waiting;
    private boolean waitingStream;
    private boolean streaming;
    private volatile boolean severeMemoryPressure;
    private AtomicBoolean cancellation;
    private File activeDirectory;
    private File imports;
    private File currentImport;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        imports = new File(getCacheDir(), "viewer-imports");
        imports.mkdirs();
        if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) new File(getCacheDir(), "viewer-debug-status.json").delete();
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
        cancel = new Button(this);
        cancel.setText("取消");
        cancel.setVisibility(View.GONE);
        cancel.setOnClickListener(v -> cancelLoading());
        header.addView(cancel);
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
            } else if ("fixture".equals(sample)) {
                importFiles(Arrays.asList(Uri.parse("content://com.hwn.modelviewer.test/fixture")));
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
        activeDirectory = directory;
        ActivityManager manager = (ActivityManager)getSystemService(ACTIVITY_SERVICE);
        final long maxBytes = Math.min(128L * 1024 * 1024, (long)manager.getMemoryClass() * 1024 * 1024 / 5);
        final boolean stl = ext(names.get(0)).equals("stl");
        final AtomicBoolean cancelled = new AtomicBoolean(false);
        cancellation = cancelled;
        streaming = stl;
        importer.execute(() -> {
            try {
                if (!directory.mkdirs()) throw new Exception("无法创建缓存目录");
                long copied = 0;
                long lastReport = 0;
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
                            checkResources(cancelled, directory, n);
                            copied += n;
                            if (!stl && copied > maxBytes) throw new Exception("此格式的原生分块读取尚未移植，请先用较小的模型测试。");
                            output.write(buffer, 0, n);
                            if (System.nanoTime() - lastReport > 250_000_000L) {
                                lastReport = System.nanoTime();
                                final long bytes = copied;
                                runOnUiThread(() -> { if (!cancelled.get()) status.setText("正在导入模型 · 已复制 " + formatBytes(bytes)); });
                            }
                        }
                    }
                    urls.put(BASE + "imports/" + directory.getName() + "/" + Uri.encode(name));
                }
                checkResources(cancelled, directory, 0);
                if (stl) {
                    File modelFile = new File(directory, names.get(0));
                    File streamDirectory = new File(directory, "stream");
                    StlStreamReader reader = new StlStreamReader(modelFile, streamDirectory, new StlStreamReader.Listener() {
                        private long lastReport;
                        @Override public void check() throws IOException { checkResources(cancelled, directory, 0); }
                        @Override public void progress(long bytes, long total, long triangles) {
                            if (System.nanoTime() - lastReport < 200_000_000L) return;
                            lastReport = System.nanoTime();
                            runOnUiThread(() -> {
                                if (!cancelled.get()) status.setText("正在分块读取 · " + formatBytes(bytes) + " / " + formatBytes(total));
                            });
                        }
                        @Override public void manifestReady(File manifest) {
                            runOnUiThread(() -> {
                                if (cancelled.get() || isFinishing() || isDestroyed()) return;
                                currentImport = directory;
                                title.setText(names.get(0));
                                waiting = new JSONArray().put(BASE + "imports/" + directory.getName() + "/stream/manifest.json");
                                waitingStream = true;
                                startPending();
                            });
                        }
                    });
                    reader.convert();
                    return;
                }
                runOnUiThread(() -> {
                    if (cancelled.get() || isFinishing() || isDestroyed()) return;
                    waiting = urls;
                    waitingStream = false;
                    currentImport = directory;
                    title.setText(names.get(0));
                    status.setText("正在解析模型，请稍候…");
                    startPending();
                });
            } catch (Exception | OutOfMemoryError e) {
                deleteTree(directory);
                runOnUiThread(() -> {
                    if (cancelled.get() || isFinishing() || isDestroyed()) return;
                    try { debugStatus(new JSONObject().put("type", "native_read_error").put("message", e.getMessage())); }
                    catch (org.json.JSONException ignored) { }
                    setLoading(false, "导入失败，可重新选择文件");
                    streaming = false;
                    waiting = null;
                    ready = false;
                    web.evaluateJavascript("window.O3DVStop?.();", null);
                    web.reload();
                    title.setText("3D 模型查看器 · 安卓测试");
                    showError(e instanceof OutOfMemoryError ? "设备可用内存不足，已停止读取。" : (e.getMessage() == null ? "无法读取所选文件" : e.getMessage()));
                });
            }
        });
    }

    private void startPending() {
        if (!ready || waiting == null) return;
        JSONArray urls = waiting;
        waiting = null;
        if (waitingStream) {
            String url = JSONObject.quote(urls.optString(0));
            int budget = 50331648;
            if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0)
                budget = Math.max(262144, Math.min(budget, getIntent().getIntExtra("debug-budget", budget)));
            web.evaluateJavascript("window.O3DVSetMemoryPolicy({geometryBytes:" + budget + ",textureBytes:12582912,framePixels:2000000});window.O3DVOpenStream(" + url + ");", null);
        } else web.evaluateJavascript("window.O3DVOpenFiles(" + urls.toString() + ");", null);
    }

    private void setLoading(boolean value, String message) {
        loading = value;
        open.setEnabled(!value);
        cancel.setVisibility(value ? View.VISIBLE : View.GONE);
        busyOverlay.setVisibility(value ? View.VISIBLE : View.GONE);
        status.setText(message);
    }

    private static String formatBytes(long bytes) {
        return String.format(Locale.ROOT, "%.1f MiB", bytes / 1048576.0);
    }

    private void checkResources(AtomicBoolean cancelled, File directory, long required) throws IOException {
        if (cancelled.get() || Thread.currentThread().isInterrupted()) throw new IOException("读取已取消。");
        if (severeMemoryPressure) throw new IOException("设备可用内存不足，已停止读取。");
        ActivityManager.MemoryInfo info = new ActivityManager.MemoryInfo();
        ((ActivityManager)getSystemService(ACTIVITY_SERVICE)).getMemoryInfo(info);
        Runtime runtime = Runtime.getRuntime();
        long javaAvailable = runtime.maxMemory() - (runtime.totalMemory() - runtime.freeMemory());
        if (info.lowMemory || javaAvailable < 8L * 1024 * 1024) throw new IOException("设备可用内存不足，已停止读取。");
        long free = directory.getUsableSpace();
        if (free < StlStreamReader.STORAGE_RESERVE || required > free - StlStreamReader.STORAGE_RESERVE)
            throw new IOException("设备存储空间不足，请清理空间后重试。");
    }

    private void cancelLoading() {
        if (!loading) return;
        if (cancellation != null) cancellation.set(true);
        final File doomed = activeDirectory;
        if (doomed != null) importer.execute(() -> deleteTree(doomed));
        activeDirectory = null;
        waiting = null;
        streaming = false;
        ready = false;
        web.evaluateJavascript("window.O3DVStop?.();", null);
        web.reload();
        title.setText("3D 模型查看器 · 安卓测试");
        setLoading(false, "已取消，可重新选择模型");
        try { debugStatus(new JSONObject().put("type", "load_cancelled")); }
        catch (org.json.JSONException ignored) { }
    }

    private void showError(String message) {
        new AlertDialog.Builder(this).setTitle("无法打开模型").setMessage(message).setPositiveButton("确定", null).show();
    }

    private void debugStatus(JSONObject state) {
        if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0) return;
        try (FileOutputStream output = new FileOutputStream(new File(getCacheDir(), "viewer-debug-status.json"))) {
            output.write(state.toString().getBytes(StandardCharsets.UTF_8));
        } catch (IOException ignored) { }
    }

    private final class Bridge {
        @JavascriptInterface public void postMessage(String json) {
            runOnUiThread(() -> {
                try {
                    JSONObject message = new JSONObject(json);
                    String type = message.optString("type");
                    if (type.equals("model_loaded") || type.equals("javascript_error") || type.equals("stream_progress")) debugStatus(message);
                    if (type.equals("ready")) { ready = true; startPending(); }
                    else if (type.equals("request_file_picker")) pickFiles();
                    else if (type.equals("model_loaded")) {
                        JSONArray missing = message.optJSONArray("missingFiles");
                        setLoading(false, missing != null && missing.length() > 0 ? "模型已显示，部分配套文件缺失" : "模型已显示");
                        streaming = false;
                        cancellation = null;
                        activeDirectory = null;
                        final File keep = currentImport;
                        importer.execute(() -> {
                            File[] old = imports.listFiles();
                            if (old != null) for (File file : old) if (!file.equals(keep)) deleteTree(file);
                        });
                    } else if (type.equals("load_progress")) {
                        setLoading(true, "正在解析模型，请稍候…");
                    } else if (type.equals("stream_progress")) {
                        if (streaming && !message.optBoolean("complete")) {
                            status.setText("正在生成画面 · 已显示 " + message.optInt("displayed") + " 个数据块");
                        }
                    } else if (type.equals("no_importable_file") || type.equals("failed_to_load_file") || type.equals("import_failed") || type.equals("javascript_error")) {
                        if (cancellation != null) cancellation.set(true);
                        File failed = activeDirectory;
                        if (failed != null) importer.execute(() -> deleteTree(failed));
                        activeDirectory = null;
                        streaming = false;
                        setLoading(false, "打开失败，可重新选择文件");
                        waiting = null;
                        ready = false;
                        web.evaluateJavascript("window.O3DVStop?.();", null);
                        web.reload();
                        title.setText("3D 模型查看器 · 安卓测试");
                        showError("无法解析或显示此模型。请检查格式和配套文件，或释放设备资源后重试。");
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
                    if (!file.getCanonicalPath().startsWith(imports.getCanonicalPath() + File.separator) || !file.isFile()) {
                        if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) android.util.Log.w("O3DVHttp", "Missing local resource: " + path);
                        return denied();
                    }
                    return fileResponse(path, file, request);
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
            } catch (Exception e) {
                if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) android.util.Log.w("O3DVHttp", "Local read failed: " + path, e);
                return denied();
            }
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
        return new WebResourceResponse(mime(path), null, stream);
    }

    private String mime(String path) {
        String extension = ext(path);
        String mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension);
        if (extension.equals("wasm")) mime = "application/wasm";
        if (extension.equals("js")) mime = "application/javascript";
        if (mime == null) mime = "application/octet-stream";
        return mime;
    }

    private WebResourceResponse fileResponse(String path, File file, WebResourceRequest request) throws IOException {
        long size = file.length(), first = 0, last = size - 1;
        String range = null;
        for (Map.Entry<String, String> header : request.getRequestHeaders().entrySet())
            if (header.getKey().equalsIgnoreCase("Range")) range = header.getValue();
        if (range != null) {
            java.util.regex.Matcher match = java.util.regex.Pattern.compile("bytes=(\\d+)-(\\d*)").matcher(range.trim());
            if (!match.matches()) return invalidRange(size);
            try {
                first = Long.parseLong(match.group(1));
                if (!match.group(2).isEmpty()) last = Long.parseLong(match.group(2));
            } catch (NumberFormatException e) { return invalidRange(size); }
            if (first >= size || last < first) return invalidRange(size);
            last = Math.min(last, size - 1);
        }
        // WebView applies the request's start offset to the supplied stream itself.
        // Bound the stream at the requested end so it cannot return the rest of the file.
        long accessibleBytes = range == null ? size : last + 1;
        FileInputStream input = new FileInputStream(file);
        InputStream bounded = new FilterInputStream(input) {
            private long remaining = accessibleBytes;
            @Override public int available() throws IOException { return (int)Math.min(super.available(), remaining); }
            @Override public long skip(long count) throws IOException {
                long skipped = super.skip(Math.min(count, remaining));
                remaining -= skipped;
                return skipped;
            }
            @Override public int read() throws IOException {
                if (remaining == 0) return -1;
                int value = super.read();
                if (value >= 0) remaining--;
                return value;
            }
            @Override public int read(byte[] data, int offset, int length) throws IOException {
                if (remaining == 0) return -1;
                int count = super.read(data, offset, (int)Math.min(length, remaining));
                if (count > 0) remaining -= count;
                return count;
            }
        };
        Map<String, String> headers = new HashMap<>();
        headers.put("Accept-Ranges", "bytes");
        headers.put("Cache-Control", "no-store");
        if (range != null) headers.put("Content-Range", "bytes " + first + "-" + last + "/" + size);
        return new WebResourceResponse(mime(path), null, range == null ? 200 : 206,
            range == null ? "OK" : "Partial Content", headers, bounded);
    }

    private WebResourceResponse invalidRange(long size) {
        Map<String, String> headers = new HashMap<>();
        headers.put("Content-Range", "bytes */" + size);
        return new WebResourceResponse("text/plain", "utf-8", 416, "Range Not Satisfiable", headers, new ByteArrayInputStream(new byte[0]));
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
        if (cancellation != null) cancellation.set(true);
        importer.shutdown();
        if (web != null) { web.removeJavascriptInterface("AndroidBridge"); web.destroy(); }
        super.onDestroy();
    }

    @Override public void onTrimMemory(int level) {
        super.onTrimMemory(level);
        if (level == TRIM_MEMORY_RUNNING_CRITICAL || level >= TRIM_MEMORY_COMPLETE) severeMemoryPressure = true;
        if (web != null && level >= TRIM_MEMORY_RUNNING_LOW) {
            web.evaluateJavascript("window.O3DVSetMemoryPolicy?.({geometryBytes:12582912,textureBytes:4194304,framePixels:1000000});", null);
        }
    }

    @Override protected void onResume() {
        super.onResume();
        severeMemoryPressure = false;
        if (web != null) web.evaluateJavascript("window.O3DVSetForeground?.(true);", null);
    }

    @Override protected void onPause() {
        if (web != null) web.evaluateJavascript("window.O3DVSetForeground?.(false);", null);
        super.onPause();
    }
}
