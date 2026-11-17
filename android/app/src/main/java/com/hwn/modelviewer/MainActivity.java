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
import android.widget.ScrollView;

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
    private JSONArray unsupportedDetails;
    private JSONArray displayWarnings;
    private JSONArray modelLayers;
    private final Map<Integer, Boolean> layerOverrides = new HashMap<>();
    private Button open;
    private Button cancel;
    private Button layersButton;
    private FrameLayout busyOverlay;
    private boolean ready, loading;
    private boolean resetting;
    private JSONArray waiting;
    private boolean waitingStream;
    private boolean streaming;
    private volatile boolean severeMemoryPressure;
    private volatile JSONObject debugMemoryFailure;
    private AtomicBoolean cancellation;
    private File activeDirectory;
    private File imports;
    private ModelLibrary library;
    private LinearLayout libraryRows;
    private ScrollView libraryView;
    private FrameLayout viewerContainer;
    private Button libraryButton;
    private boolean showingLibrary;
    private File currentImport;
    private volatile File rebuildingDirectory;
    private boolean libraryBusy;
    private boolean benchmarkStarted;
    private long lastMemoryPressureMs;
    private boolean foreground;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        imports = new File(getCacheDir(), "viewer-imports");
        imports.mkdirs();
        boolean testLibrary = (getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0 && getIntent().getBooleanExtra("debug-library-test", false);
        try { library = new ModelLibrary(getFilesDir(), testLibrary); }
        catch (IOException e) { throw new IllegalStateException("无法初始化模型库", e); }
        importer.execute(() -> {
            library.cleanupInterruptedImports();
            if (!testLibrary && !getIntent().hasExtra("debug-cache")) library.migrateLegacy(imports);
            runOnUiThread(() -> {if(showingLibrary && !loading)refreshLibrary();});
        });
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
        libraryButton = new Button(this);
        libraryButton.setText("模型库");
        libraryButton.setOnClickListener(v -> showLibrary());
        header.addView(libraryButton);
        open = new Button(this);
        open.setText("打开文件");
        open.setOnClickListener(v -> pickFiles());
        header.addView(open);
        layersButton = new Button(this);
        layersButton.setText("图层");
        layersButton.setVisibility(View.GONE);
        layersButton.setOnClickListener(v -> showLayers());
        header.addView(layersButton);
        cancel = new Button(this);
        cancel.setText("取消");
        cancel.setVisibility(View.GONE);
        cancel.setOnClickListener(v -> cancelLoading());
        header.addView(cancel);
        root.addView(header);
        status = new TextView(this);
        status.setText("本机离线测试版 · 请选择模型文件");
        status.setOnClickListener(v -> {
            if ((unsupportedDetails == null || unsupportedDetails.length() == 0) && (displayWarnings == null || displayWarnings.length() == 0)) return;
            StringBuilder text = new StringBuilder();
            if(displayWarnings!=null)for(int i=0;i<displayWarnings.length();i++) {
                if(text.length()>0)text.append('\n');text.append(displayWarnings.optString(i));
            }
            for (int i=0;unsupportedDetails!=null && i<unsupportedDetails.length();i++) {
                JSONObject item=unsupportedDetails.optJSONObject(i);
                if(item==null)continue;
                if(text.length()>0)text.append('\n');
                text.append(item.optString("name").isEmpty()?item.optString("type", "对象"):item.optString("name"));
                String reason=item.optString("reason");if(!reason.isEmpty())text.append("：").append(reason);
            }
            new AlertDialog.Builder(this).setTitle("显示说明").setMessage(text.toString()).setPositiveButton("确定",null).show();
        });
        status.setPadding(dp(16), dp(5), dp(16), dp(7));
        root.addView(status);
        FrameLayout container = new FrameLayout(this);
        viewerContainer = container;
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
        libraryView = new ScrollView(this);
        libraryRows = new LinearLayout(this);
        libraryRows.setOrientation(LinearLayout.VERTICAL);
        libraryRows.setPadding(dp(16), dp(12), dp(16), dp(16));
        libraryView.addView(libraryRows);
        root.addView(libraryView, new LinearLayout.LayoutParams(-1, 0, 1));
        setContentView(root);
        web.loadUrl(BASE + "index.html");
        showLibrary();
        handleIntent(getIntent());
        if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            String sample = getIntent().getStringExtra("debug-sample");
            String libraryId = getIntent().getStringExtra("debug-library-item");
            if (libraryId != null) openLibraryItem(libraryId);
            String debugAction = getIntent().getStringExtra("debug-library-action");
            String debugActionId = getIntent().getStringExtra("debug-action-item");
            if (debugActionId != null && ("clear".equals(debugAction) || "delete".equals(debugAction)))
                performLibraryAction(debugActionId, "delete".equals(debugAction));
            if (sample != null || getIntent().hasExtra("debug-cache")) showViewer();
            String cacheId = getIntent().getStringExtra("debug-cache");
            if (cacheId != null && cacheId.matches("[0-9a-f-]{36}") && new File(imports, cacheId + "/stream/manifest.json").isFile()) {
                currentImport = new File(imports, cacheId);
                waiting = new JSONArray().put(BASE + "imports/" + cacheId + "/stream/manifest.json");
                waitingStream = true;
                streaming = true;
                setLoading(true, "正在打开测试模型…");
            }
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
            } else if ("fixture3dm".equals(sample)) {
                importFiles(Arrays.asList(Uri.parse("content://com.hwn.modelviewer.test/fixture3dm")));
            } else if ("fixtureobj".equals(sample) || "fixturefbx".equals(sample)) {
                importFiles(Arrays.asList(Uri.parse("content://com.hwn.modelviewer.test/" + sample)));
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

    private void showViewer() {
        showingLibrary=false;
        if(libraryView!=null)libraryView.setVisibility(View.GONE);
        if(viewerContainer!=null)viewerContainer.setVisibility(View.VISIBLE);
        if(status!=null)status.setVisibility(View.VISIBLE);
    }

    private void showLibrary() {
        if(loading)return;
        showingLibrary=true;
        if(viewerContainer!=null)viewerContainer.setVisibility(View.GONE);
        if(libraryView!=null)libraryView.setVisibility(View.VISIBLE);
        if(status!=null)status.setVisibility(View.GONE);
        if(layersButton!=null)layersButton.setVisibility(View.GONE);
        if(title!=null)title.setText("模型库");
        modelLayers=null;layerOverrides.clear();unsupportedDetails=null;displayWarnings=null;
        if(web!=null && ready) { ready=false;resetting=true;web.evaluateJavascript("window.O3DVStop?.();",null);web.reload(); }
        refreshLibrary();
    }

    private void refreshLibrary() {
        if(libraryRows==null)return;
        libraryRows.removeAllViews();
        TextView heading=new TextView(this);heading.setText("最近打开");heading.setTextSize(20);heading.setTextColor(Color.rgb(30,35,42));
        libraryRows.addView(heading);
        List<JSONObject> items=library.list();
        if(items.isEmpty()) {
            TextView empty=new TextView(this);empty.setText("还没有模型。点击上方“打开文件”导入，模型保存在这台设备上。");
            empty.setPadding(0,dp(25),0,dp(25));libraryRows.addView(empty);return;
        }
        for(JSONObject item:items) {
            String id=item.optString("id"),name=item.optString("name","模型");
            LinearLayout card=new LinearLayout(this);card.setOrientation(LinearLayout.VERTICAL);card.setPadding(dp(8),dp(10),dp(8),dp(10));
            Button openItem=new Button(this);openItem.setText(name+"  ·  "+formatBytes(item.optLong("bytes")));openItem.setAllCaps(false);
            openItem.setContentDescription("打开 "+name);openItem.setOnClickListener(v -> openLibraryItem(id));card.addView(openItem);
            LinearLayout actions=new LinearLayout(this);
            Button clear=new Button(this);clear.setText("清理缓存");clear.setContentDescription(name+" 清理缓存");
            clear.setOnClickListener(v -> confirmLibraryAction(id,name,false));actions.addView(clear,new LinearLayout.LayoutParams(0,-2,1));
            Button remove=new Button(this);remove.setText("删除");remove.setContentDescription(name+" 删除");
            remove.setOnClickListener(v -> confirmLibraryAction(id,name,true));actions.addView(remove,new LinearLayout.LayoutParams(0,-2,1));
            card.addView(actions);libraryRows.addView(card);
        }
    }

    private void confirmLibraryAction(String id,String name,boolean delete) {
        if(loading || libraryBusy)return;
        new AlertDialog.Builder(this).setTitle(delete?"删除模型？":"清理显示缓存？")
            .setMessage(delete?"将删除 App 内的模型副本和缓存，导入前的原始文件不会受影响。":"保留模型文件，下次打开时重新生成显示数据。")
            .setPositiveButton(delete?"删除":"清理",(dialog,which)-> performLibraryAction(id,delete))
            .setNegativeButton("取消",null).show();
    }

    private void performLibraryAction(String id,boolean delete) {
        if(loading || libraryBusy)return;
        libraryBusy=true;open.setEnabled(false);libraryButton.setEnabled(false);
        importer.execute(() -> {
            try {
                File dir=library.directory(id);
                library.read(dir); // Refuse to operate on a directory that is not a saved model.
                ModelLibrary.remove(delete?dir:new File(dir,"stream"));
                runOnUiThread(() -> {
                    libraryBusy=false;open.setEnabled(true);libraryButton.setEnabled(true);refreshLibrary();
                    try { debugStatus(new JSONObject().put("type","library_action_complete").put("id",id).put("action",delete?"delete":"clear")); }
                    catch(org.json.JSONException ignored) { }
                });
            } catch(IOException e) {runOnUiThread(() -> {libraryBusy=false;open.setEnabled(true);libraryButton.setEnabled(true);showError(e.getMessage());});}
        });
    }

    private void openLibraryItem(String id) {
        if(loading || libraryBusy)return;
        debugMemoryFailure=null;
        try {
            File directory=library.directory(id);JSONObject item=library.read(directory);List<String> names=jsonNames(item);
            showViewer();setLoading(true,"正在打开模型…");title.setText(item.optString("name"));
            AtomicBoolean cancelled=new AtomicBoolean(false);cancellation=cancelled;activeDirectory=directory;
            streaming=ext(names.get(0)).equals("stl")||ext(names.get(0)).equals("3dm");
            importer.execute(() -> {
                try {processDirectory(directory,names,cancelled);}
                catch(Exception | OutOfMemoryError e) {
                    if(cancelled.get()){cleanupFailed(directory);return;}
                    runOnUiThread(() -> {
                        if(cancelled.get()||isFinishing()||isDestroyed())return;
                        setLoading(false,"打开失败，可重新选择文件");waiting=null;ready=false;resetting=true;
                        web.evaluateJavascript("window.O3DVStop?.();",null);web.reload();
                        cleanupFailed(directory);showError(e.getMessage()==null?"模型打开失败。":e.getMessage());showLibrary();
                    });
                }
            });
        } catch(Exception e){showError(e.getMessage()==null?"模型打开失败。":e.getMessage());}
    }

    @Override public void onBackPressed() {
        if(loading){cancelLoading();showLibrary();}
        else if(!showingLibrary)showLibrary();
        else super.onBackPressed();
    }

    private void pickFiles() {
        if (loading || libraryBusy) return;
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
        debugMemoryFailure=null;
        List<String> names = new ArrayList<>();
        int modelCount = 0;
        int primaryIndex = -1;
        for (int index = 0; index < files.size(); index++) {
            Uri uri = files.get(index);
            String name = fileName(uri);
            if(name.equals("model.json") || name.equals(".pending") || name.equals("stream") || name.equals(".") || name.equals("..")) {
                showError("所选文件名与模型库内部名称冲突，请先重命名文件。");return;
            }
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
        showViewer();
        setLoading(true, "正在复制模型到本机…");
        File directory = new File(library.root, UUID.randomUUID().toString());
        activeDirectory = directory;
        ActivityManager manager = (ActivityManager)getSystemService(ACTIVITY_SERVICE);
        final long maxBytes = Math.min(128L * 1024 * 1024, (long)manager.getMemoryClass() * 1024 * 1024 / 5);
        final boolean stl = ext(names.get(0)).equals("stl");
        final boolean rhino = ext(names.get(0)).equals("3dm");
        unsupportedDetails = null;
        displayWarnings = null;
        modelLayers = null;
        layerOverrides.clear();
        layersButton.setVisibility(View.GONE);
        // Stable companion ordering makes duplicate detection independent of picker order.
        for (int i=1;i<orderedFiles.size();i++) for (int j=i+1;j<orderedFiles.size();j++) if(names.get(i).compareTo(names.get(j))>0) {
            java.util.Collections.swap(names,i,j); java.util.Collections.swap(orderedFiles,i,j);
        }
        final AtomicBoolean cancelled = new AtomicBoolean(false);
        cancellation = cancelled;
        streaming = stl || rhino;
        importer.execute(() -> {
            final File[] workDirectory={directory};
            try {
                if (!directory.mkdirs()) throw new Exception("无法创建缓存目录");
                if(!new File(directory,".pending").createNewFile())throw new IOException("无法准备模型导入。");
                java.security.MessageDigest digest = java.security.MessageDigest.getInstance("SHA-256");
                long copied = 0;
                long lastReport = 0;
                JSONArray urls = new JSONArray();
                for (int i = 0; i < orderedFiles.size(); i++) {
                    Uri uri = orderedFiles.get(i);
                    String name = names.get(i);
                    byte[] nameBytes = name.getBytes(StandardCharsets.UTF_8);
                    digest.update(java.nio.ByteBuffer.allocate(4).putInt(nameBytes.length).array()); digest.update(nameBytes);
                    java.security.MessageDigest fileDigest=java.security.MessageDigest.getInstance("SHA-256");
                    long fileBytes=0;
                    try (InputStream input = getContentResolver().openInputStream(uri);
                         FileOutputStream output = new FileOutputStream(new File(directory, name))) {
                        if (input == null) throw new Exception("无法读取 " + name);
                        byte[] buffer = new byte[256 * 1024];
                        int n;
                        while ((n = input.read(buffer)) != -1) {
                            checkResources(cancelled, directory, n);
                            copied += n; fileBytes += n; fileDigest.update(buffer,0,n);
                            if (!stl && !rhino && copied > maxBytes) throw new Exception("此格式的原生分块读取尚未移植，请先用较小的模型测试。");
                            output.write(buffer, 0, n);
                            if (System.nanoTime() - lastReport > 250_000_000L) {
                                lastReport = System.nanoTime();
                                final long bytes = copied;
                                runOnUiThread(() -> { if (!cancelled.get()) status.setText("正在导入模型 · 已复制 " + formatBytes(bytes)); });
                            }
                        }
                    }
                    digest.update(java.nio.ByteBuffer.allocate(8).putLong(fileBytes).array()); digest.update(fileDigest.digest());
                    urls.put(BASE + "library/" + directory.getName() + "/" + Uri.encode(name));
                }
                checkResources(cancelled, directory, 0);
                String fingerprint=bytesHex(digest.digest());
                JSONObject duplicate=library.findFingerprint(fingerprint);
                if(duplicate!=null) {
                    ModelLibrary.remove(directory);
                    File existing=library.directory(duplicate.getString("id"));
                    workDirectory[0]=existing;
                    runOnUiThread(() -> { if(!cancelled.get()) { activeDirectory=null; status.setText("已找到相同模型，正在打开…"); } });
                    processDirectory(existing,jsonNames(duplicate),cancelled);
                    return;
                }
                JSONObject item=new JSONObject().put("id",directory.getName()).put("name",names.get(0))
                    .put("files",new JSONArray(names)).put("bytes",copied).put("fingerprint",fingerprint)
                    .put("lastOpened",System.currentTimeMillis());
                library.write(directory,item);
                if(!new File(directory,".pending").delete())throw new IOException("无法完成模型导入。");
                checkResources(cancelled,directory,0);
                processDirectory(directory,names,cancelled);
            } catch (Exception | OutOfMemoryError e) {
                if (cancelled.get()) { cleanupFailed(workDirectory[0]); return; }
                runOnUiThread(() -> {
                    if (cancelled.get() || isFinishing() || isDestroyed()) { cleanupFailed(workDirectory[0]); return; }
                    try { debugStatus(new JSONObject().put("type", "native_read_error").put("message", e.getMessage()).put("memory", debugMemoryFailure)); }
                    catch (org.json.JSONException ignored) { }
                    if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) android.util.Log.w("O3DVReader", "读取失败", e);
                    setLoading(false, "导入失败，可重新选择文件");
                    streaming = false;
                    waiting = null;
                    ready = false;
                    resetting = true;
                    web.evaluateJavascript("window.O3DVStop?.();", null);
                    web.reload();
                    title.setText("3D 模型查看器 · 安卓测试");
                    showError(e instanceof OutOfMemoryError ? "设备可用内存不足，已停止读取。" : (e.getMessage() == null ? "无法读取所选文件" : e.getMessage()));
                    cleanupFailed(workDirectory[0]);
                    showLibrary();
                });
            }
        });
    }

    private void processDirectory(File directory, List<String> names, AtomicBoolean cancelled) throws Exception {
        checkResources(cancelled,directory,0);
        boolean stl=ext(names.get(0)).equals("stl"),rhino=ext(names.get(0)).equals("3dm");
        JSONArray urls=new JSONArray();
        for(String name:names) {
            if(!new File(directory,name).isFile())throw new IOException("模型副本不完整，请重新导入。");
            urls.put(BASE+"library/"+directory.getName()+"/"+Uri.encode(name));
        }
        if((stl || rhino) && library.validCache(directory,ext(names.get(0)))) {
            runOnUiThread(() -> {
                if(cancelled.get()||isFinishing()||isDestroyed())return;
                activeDirectory=null; currentImport=directory; streaming=true; title.setText(names.get(0));
                waiting=new JSONArray().put(BASE+"library/"+directory.getName()+"/stream/manifest.json");
                waitingStream=true;status.setText("正在从缓存打开模型…");startPending();
            });
            return;
        }
        if(stl||rhino) {
            rebuildingDirectory=directory;
            runOnUiThread(() -> {if(!cancelled.get())activeDirectory=directory;});
            checkResources(cancelled,directory,0);
            ModelLibrary.remove(new File(directory,"stream"));
        }
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
                                if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0 && getIntent().getBooleanExtra("debug-library-test", false) && getIntent().getBooleanExtra("debug-cancel-on-stream", false)) { cancelLoading(); return; }
                                currentImport = directory;
                                title.setText(names.get(0));
                                waiting = new JSONArray().put(BASE + "library/" + directory.getName() + "/stream/manifest.json");
                                waitingStream = true;
                                startPending();
                            });
                        }
                    });
                    reader.convert();
                    return;
                }
                if (rhino) {
                    File modelFile = new File(directory, names.get(0));
                    File streamDirectory = new File(directory, "stream");
                    RhinoStreamReader reader = new RhinoStreamReader(modelFile, streamDirectory, new RhinoStreamReader.Listener() {
                        private long lastReport;
                        @Override public void checkpoint() throws IOException { checkResources(cancelled, directory, 0); }
                        @Override public void progress(long objects) {
                            if (System.nanoTime() - lastReport < 200_000_000L) return;
                            lastReport = System.nanoTime();
                            runOnUiThread(() -> { if (!cancelled.get()) status.setText("正在分块读取 · 已读取 " + objects + " 个对象"); });
                        }
                        @Override public void manifestReady(File manifest) {
                            runOnUiThread(() -> {
                                if (cancelled.get() || isFinishing() || isDestroyed()) return;
                                currentImport = directory;
                                title.setText(names.get(0));
                                waiting = new JSONArray().put(BASE + "library/" + directory.getName() + "/stream/manifest.json");
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
    }

    private static List<String> jsonNames(JSONObject item) throws org.json.JSONException {
        List<String> result=new ArrayList<>();JSONArray names=item.getJSONArray("files");
        for(int i=0;i<names.length();i++)result.add(names.getString(i));return result;
    }
    private static String bytesHex(byte[] data) {
        StringBuilder value=new StringBuilder();for(byte b:data)value.append(String.format(Locale.ROOT,"%02x",b & 255));return value.toString();
    }

    private void startPending() {
        if (!ready || waiting == null) return;
        JSONArray urls = waiting;
        waiting = null;
        if (waitingStream) {
            String url = JSONObject.quote(urls.optString(0));
            int budget = geometryBudget();
            if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0)
                budget = Math.max(262144, Math.min(201326592, getIntent().getIntExtra("debug-budget", budget)));
            web.evaluateJavascript("window.O3DVSetMemoryPolicy({geometryBytes:" + budget + ",textureBytes:12582912,framePixels:2000000});window.O3DVOpenStream(" + url + ");", null);
        } else web.evaluateJavascript("window.O3DVOpenFiles(" + urls.toString() + ");", null);
    }

    private void setLoading(boolean value, String message) {
        loading = value;
        open.setEnabled(!value);
        libraryButton.setEnabled(!value);
        layersButton.setEnabled(!value);
        cancel.setVisibility(value ? View.VISIBLE : View.GONE);
        busyOverlay.setVisibility(value ? View.VISIBLE : View.GONE);
        status.setText(message);
    }

    private static String formatBytes(long bytes) {
        return String.format(Locale.ROOT, "%.1f MiB", bytes / 1048576.0);
    }

    private int geometryBudget() {
        ActivityManager manager = (ActivityManager)getSystemService(ACTIVITY_SERVICE);
        ActivityManager.MemoryInfo info = new ActivityManager.MemoryInfo();
        manager.getMemoryInfo(info);
        return MemoryPolicy.geometryBytes(info.totalMem, info.availMem, manager.isLowRamDevice(), info.lowMemory);
    }

    private void showLayers() {
        if (loading || modelLayers == null || modelLayers.length() == 0) return;
        String[] labels = new String[modelLayers.length()];
        boolean[] selected = new boolean[modelLayers.length()];
        int[] ids = new int[modelLayers.length()];
        for (int i=0;i<modelLayers.length();i++) {
            JSONObject layer=modelLayers.optJSONObject(i);
            ids[i]=layer.optInt("index");
            labels[i]=layer.optString("name", "图层 " + ids[i]);
            selected[i]=layerOverrides.getOrDefault(ids[i], layer.optBoolean("visible", true));
        }
        new AlertDialog.Builder(this).setTitle("图层")
            .setMultiChoiceItems(labels, selected, (dialog, which, checked) -> selected[which]=checked)
            .setPositiveButton("应用", (dialog, which) -> {
                JSONObject values=new JSONObject();
                try {
                    for(int i=0;i<ids.length;i++) { layerOverrides.put(ids[i],selected[i]); values.put(Integer.toString(ids[i]),selected[i]); }
                    web.evaluateJavascript("window.O3DVSetStreamLayers("+values+");", null);
                } catch (org.json.JSONException ignored) { }
            }).setNegativeButton("取消", null).show();
    }

    private void checkResources(AtomicBoolean cancelled, File directory, long required) throws IOException {
        if (cancelled.get() || Thread.currentThread().isInterrupted()) throw new IOException("读取已取消。");
        ActivityManager.MemoryInfo info = new ActivityManager.MemoryInfo();
        ((ActivityManager)getSystemService(ACTIVITY_SERVICE)).getMemoryInfo(info);
        Runtime runtime = Runtime.getRuntime();
        long javaAvailable = runtime.maxMemory() - (runtime.totalMemory() - runtime.freeMemory());
        long nativeAllocated = android.os.Debug.getNativeHeapAllocatedSize();
        if (severeMemoryPressure || info.lowMemory || javaAvailable < 8L * 1024 * 1024 || nativeAllocated > 512L * 1024 * 1024) {
            if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) try {
                debugMemoryFailure = new JSONObject().put("severePressure", severeMemoryPressure).put("systemLowMemory", info.lowMemory)
                    .put("systemAvailableBytes", info.availMem).put("javaAvailableBytes", javaAvailable).put("nativeAllocatedBytes", nativeAllocated);
            } catch (org.json.JSONException ignored) { }
            throw new IOException("设备可用内存不足，已停止读取。");
        }
        long free = directory.getUsableSpace();
        if (free < StlStreamReader.STORAGE_RESERVE || required > free - StlStreamReader.STORAGE_RESERVE)
            throw new IOException("设备存储空间不足，请清理空间后重试。");
    }

    private void cancelLoading() {
        if (!loading) return;
        if (cancellation != null) cancellation.set(true);
        final File doomed = activeDirectory;
        if (doomed != null) cleanupFailed(doomed);
        activeDirectory = null;
        waiting = null;
        streaming = false;
        modelLayers = null;
        layersButton.setVisibility(View.GONE);
        ready = false;
        resetting = true;
        web.evaluateJavascript("window.O3DVStop?.();", null);
        web.reload();
        title.setText("3D 模型查看器 · 安卓测试");
        setLoading(false, "已取消，可重新选择模型");
        showLibrary();
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
                    if (resetting && !type.equals("ready")) return;
                    if (type.equals("model_loaded") || type.equals("javascript_error") || type.equals("stream_progress") || type.equals("navigation_benchmark_complete") || (type.equals("stream_view_progress") && message.optBoolean("complete"))) debugStatus(message);
                    if (type.equals("ready")) { resetting = false; ready = true; startPending(); }
                    else if (type.equals("request_file_picker")) pickFiles();
                    else if (type.equals("stream_metadata")) {
                        JSONArray availableLayers=message.optJSONArray("layers");
                        if(availableLayers!=null && availableLayers.length()>0)modelLayers=availableLayers;
                    }
                    else if (type.equals("model_loaded")) {
                        JSONArray missing = message.optJSONArray("missingFiles");
                        int unsupported = message.optInt("unsupportedCount");
                        unsupportedDetails = message.optJSONArray("unsupportedObjects");
                        displayWarnings = message.optJSONArray("warnings");
                        setLoading(false, missing != null && missing.length() > 0 ? "模型已显示，部分配套文件缺失" : unsupported > 0 ? "模型已显示 · " + unsupported + " 个对象暂不支持，点击查看" : displayWarnings != null && displayWarnings.length() > 0 ? "模型已显示 · 点击查看显示说明" : "模型已显示");
                        layersButton.setVisibility(modelLayers != null && modelLayers.length() > 0 ? View.VISIBLE : View.GONE);
                        streaming = false;
                        cancellation = null;
                        activeDirectory = null;
                        rebuildingDirectory = null;
                        if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0 && getIntent().getBooleanExtra("debug-benchmark", false) && !benchmarkStarted) {
                            benchmarkStarted = true;
                            web.postDelayed(() -> web.evaluateJavascript("window.O3DVBenchmarkNavigation().catch(e=>AndroidBridge.postMessage(JSON.stringify({type:'javascript_error',name:String(e)})));", null), 500);
                        }
                        final File opened = currentImport;
                        if(opened!=null && opened.getParentFile().equals(library.root)) importer.execute(() -> {
                            try { JSONObject item=library.read(opened);item.put("lastOpened",System.currentTimeMillis());library.write(opened,item); }
                            catch(Exception e) { android.util.Log.w("O3DVLibrary","无法更新最近打开时间",e); }
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
                        if (failed != null) cleanupFailed(failed);
                        activeDirectory = null;
                        streaming = false;
                        setLoading(false, "打开失败，可重新选择文件");
                        waiting = null;
                        ready = false;
                        resetting = true;
                        web.evaluateJavascript("window.O3DVStop?.();", null);
                        web.reload();
                        title.setText("3D 模型查看器 · 安卓测试");
                        showError("无法解析或显示此模型。请检查格式和配套文件，或释放设备资源后重试。");
                        showLibrary();
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
                if (path.startsWith("/library/")) {
                    File file=new File(library.root,path.substring("/library/".length()));
                    if(!file.getCanonicalPath().startsWith(library.root.getCanonicalPath()+File.separator)||!file.isFile())return denied();
                    return fileResponse(path,file,request);
                }
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
                    if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0 && getIntent().getBooleanExtra("debug-benchmark", false)) shim += "window.O3DVNativeDebug=true;";
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

    private void cleanupFailed(File directory) {
        boolean removeStream=directory.equals(rebuildingDirectory);
        try { importer.execute(() -> {
            try { if(new File(directory,"model.json").isFile()) {if(removeStream)ModelLibrary.remove(new File(directory,"stream"));} else ModelLibrary.remove(directory); }
            catch(IOException e) { android.util.Log.w("O3DVLibrary","无法清理未完成的导入",e); }
        }); } catch(java.util.concurrent.RejectedExecutionException e) { android.util.Log.w("O3DVLibrary","无法安排清理",e); }
    }

    private void cleanupLater(File directory) {
        try { importer.execute(() -> deleteTree(directory)); }
        catch (java.util.concurrent.RejectedExecutionException e) { new Thread(() -> deleteTree(directory), "viewer-cleanup").start(); }
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
        if (web != null && (level == TRIM_MEMORY_RUNNING_LOW || level == TRIM_MEMORY_RUNNING_CRITICAL || level >= TRIM_MEMORY_BACKGROUND)) {
            lastMemoryPressureMs = android.os.SystemClock.elapsedRealtime();
            web.evaluateJavascript("window.O3DVSetMemoryPolicy?.({geometryBytes:12582912,textureBytes:4194304,framePixels:1000000});", null);
            final long pressureAt = lastMemoryPressureMs;
            web.postDelayed(() -> {
                if (lastMemoryPressureMs != pressureAt || !foreground || !ready || loading || web == null) return;
                ActivityManager.MemoryInfo info = new ActivityManager.MemoryInfo();
                ((ActivityManager)getSystemService(ACTIVITY_SERVICE)).getMemoryInfo(info);
                if (info.lowMemory || info.availMem < 1536L * 1024 * 1024) return;
                severeMemoryPressure = false;
                int budget = geometryBudget();
                web.evaluateJavascript("window.O3DVSetMemoryPolicy?.({geometryBytes:"+budget+",textureBytes:12582912,framePixels:2000000});", null);
            }, 30000);
        }
    }

    @Override protected void onResume() {
        super.onResume();
        foreground = true;
        severeMemoryPressure = false;
        if (web != null) web.evaluateJavascript("window.O3DVSetForeground?.(true);", null);
        if (web != null && ready && !loading && (lastMemoryPressureMs == 0 || android.os.SystemClock.elapsedRealtime()-lastMemoryPressureMs >= 30000)) {
            int budget=geometryBudget();
            web.evaluateJavascript("window.O3DVSetMemoryPolicy?.({geometryBytes:"+budget+",textureBytes:12582912,framePixels:2000000});", null);
        }
    }

    @Override protected void onPause() {
        foreground = false;
        if (web != null) web.evaluateJavascript("window.O3DVSetForeground?.(false);", null);
        super.onPause();
    }
}
