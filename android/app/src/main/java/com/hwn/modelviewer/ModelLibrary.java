package com.hwn.modelviewer;

import android.util.AtomicFile;
import android.util.JsonReader;
import android.util.JsonToken;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Collections;
import java.util.Locale;
import java.io.ByteArrayOutputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;

/** App-owned source copies live separately from discardable display data. */
final class ModelLibrary {
    private static final String META="model.json";
    final File root;
    ModelLibrary(File files, boolean testing) throws IOException {
        root=new File(files,testing?"model-library-test":"model-library");
        if(!root.isDirectory()&&!root.mkdirs())throw new IOException("无法创建模型库。");
    }
    File directory(String id) throws IOException {
        if(id==null || !id.matches("[0-9a-f-]{36}"))throw new IOException("模型标识无效。");
        File result=new File(root,id);
        if(!result.getCanonicalPath().startsWith(root.getCanonicalPath()+File.separator))throw new IOException("模型路径无效。");
        return result;
    }
    JSONObject read(File dir) throws IOException {
        File meta=new File(dir,META);
        try(FileInputStream in=new AtomicFile(meta).openRead()) {
            ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] buffer=new byte[8192];int n;
            while((n=in.read(buffer))!=-1) { if(out.size()+n>1024*1024)throw new IOException("模型记录过大。");out.write(buffer,0,n); }
            JSONObject item=new JSONObject(new String(out.toByteArray(),StandardCharsets.UTF_8));
            if(!dir.getName().equals(item.getString("id")))throw new IOException("模型记录无效。");
            JSONArray files=item.getJSONArray("files");if(files.length()==0)throw new IOException("模型记录没有文件。");
            for(int i=0;i<files.length();i++) {
                String name=files.getString(i);
                if(name.isEmpty()||name.equals(".")||name.equals("..")||!new File(name).getName().equals(name))throw new IOException("模型记录路径无效。");
            }
            return item;
        } catch(JSONException e){throw new IOException("模型记录无法读取。",e);}
    }
    void write(File dir,JSONObject item) throws IOException {
        AtomicFile file=new AtomicFile(new File(dir,META));FileOutputStream out=null;
        try {out=file.startWrite();out.write(item.toString().getBytes(StandardCharsets.UTF_8));file.finishWrite(out);}
        catch(IOException e){if(out!=null)file.failWrite(out);throw e;}
    }
    List<JSONObject> list() {
        ArrayList<JSONObject> result=new ArrayList<>();File[] dirs=root.listFiles();
        if(dirs!=null)for(File dir:dirs)if(dir.isDirectory())try{result.add(read(dir));}catch(IOException ignored){}
        result.sort(Comparator.comparingLong((JSONObject x)->x.optLong("lastOpened")).reversed());return result;
    }
    void cleanupInterruptedImports() {
        File[] dirs=root.listFiles();if(dirs==null)return;
        for(File dir:dirs) {
            File marker=new File(dir,".pending");
            if(!dir.isDirectory()||!marker.isFile())continue;
            try { if(new File(dir,META).isFile())marker.delete();else remove(dir); }
            catch(IOException ignored) { }
        }
    }
    /** Promote completed caches from the earlier prototype without deleting any old files. */
    void migrateLegacy(File legacyRoot) {
        File[] dirs=legacyRoot.listFiles();if(dirs==null)return;
        for(File dir:dirs) {
            try {
                if(!dir.isDirectory() || !dir.getName().matches("[0-9a-f-]{36}") || new File(root,dir.getName()).exists()
                    || new File(dir,META).exists() || new File(dir,".pending").exists())continue;
                File[] entries=dir.listFiles();if(entries==null)continue;
                List<String> files=new ArrayList<>(),models=new ArrayList<>();
                for(File entry:entries) {
                    if(!entry.isFile() || entry.getName().equals(META) || entry.getName().equals(".pending"))continue;
                    String name=entry.getName();files.add(name);
                    String lower=name.toLowerCase(Locale.ROOT);
                    if(lower.endsWith(".3dm")||lower.endsWith(".stl"))models.add(name);
                }
                if(models.size()!=1 || !validCache(dir,models.get(0).toLowerCase(Locale.ROOT).endsWith(".3dm")?"3dm":"stl"))continue;
                String primary=models.get(0);files.remove(primary);Collections.sort(files);files.add(0,primary);
                java.security.MessageDigest digest=java.security.MessageDigest.getInstance("SHA-256");long total=0;
                for(String name:files) {
                    byte[] bytes=name.getBytes(StandardCharsets.UTF_8);
                    digest.update(java.nio.ByteBuffer.allocate(4).putInt(bytes.length).array());digest.update(bytes);
                    java.security.MessageDigest fileDigest=java.security.MessageDigest.getInstance("SHA-256");long length=0;
                    try(FileInputStream in=new FileInputStream(new File(dir,name))) {
                        byte[] buffer=new byte[256*1024];int n;while((n=in.read(buffer))!=-1){fileDigest.update(buffer,0,n);length+=n;}
                    }
                    total+=length;digest.update(java.nio.ByteBuffer.allocate(8).putLong(length).array());digest.update(fileDigest.digest());
                }
                StringBuilder fingerprint=new StringBuilder();for(byte b:digest.digest())fingerprint.append(String.format(Locale.ROOT,"%02x",b&255));
                if(findFingerprint(fingerprint.toString())!=null)continue;
                JSONObject item=new JSONObject().put("id",dir.getName()).put("name",primary).put("files",new JSONArray(files))
                    .put("bytes",total).put("fingerprint",fingerprint.toString()).put("lastOpened",new File(dir,"stream/manifest.json").lastModified());
                write(dir,item);
                // Cache and files share the app's filesystem; if rename fails the old copy stays intact.
                dir.renameTo(new File(root,dir.getName()));
            } catch(Exception ignored) { /* Leave the legacy directory untouched for later recovery. */ }
        }
    }
    JSONObject findFingerprint(String digest) {
        for(JSONObject item:list())if(digest.equals(item.optString("fingerprint")))try {
            File dir=directory(item.getString("id"));JSONArray files=item.getJSONArray("files");long size=0;
            for(int i=0;i<files.length();i++){File source=new File(dir,files.getString(i));if(!source.isFile())throw new IOException("missing source");size+=source.length();}
            if(size==item.getLong("bytes"))return item;
        }catch(Exception ignored){}
        return null;
    }
    boolean validCache(File dir,String ext) {
        try {
            File cache=new File(dir,"stream"),manifest=new File(cache,"manifest.json");
            String expected=ext.equals("stl")?"stl-stream-1":ext.equals("3dm")?"opennurbs-android-1":"";
            if(manifest.length()==0 || expected.isEmpty())return false;
            boolean complete=false,foundObjects=false;String reader="";
            // Completed manifests can be larger than the Java heap. Validate them incrementally.
            try(JsonReader json=new JsonReader(new BufferedReader(new InputStreamReader(new FileInputStream(manifest),StandardCharsets.UTF_8)))) {
                json.beginObject();
                while(json.hasNext()) {
                    String key=json.nextName();
                    if(key.equals("complete"))complete=json.nextBoolean();
                    else if(key.equals("reader"))reader=json.nextString();
                    else if(key.equals("objects")) {
                        foundObjects=true;json.beginArray();
                        while(json.hasNext()) {
                            String name=null;long bytes=-1;json.beginObject();
                            while(json.hasNext()) {
                                String field=json.nextName();
                                if(field.equals("url"))name=json.nextString();
                                else if(field.equals("bytes"))bytes=json.nextLong();
                                else json.skipValue();
                            }
                            json.endObject();
                            if(name==null||name.isEmpty()||!new File(name).getName().equals(name)||bytes<0)return false;
                            File part=new File(cache,name);if(!part.isFile()||part.length()!=bytes)return false;
                        }
                        json.endArray();
                    } else json.skipValue();
                }
                json.endObject();
                return json.peek()==JsonToken.END_DOCUMENT && foundObjects && complete && expected.equals(reader);
            }
        } catch(Exception e){return false;}
    }
    static long size(File file) {
        if(!file.isDirectory())return file.length();long n=0;File[] entries=file.listFiles();
        if(entries!=null)for(File entry:entries)n+=size(entry);return n;
    }
    static void remove(File file) throws IOException {
        if(!file.exists())return;File[] children=file.listFiles();
        if(children!=null)for(File child:children)remove(child);
        if(!file.delete()&&file.exists())throw new IOException("无法删除文件："+file.getName());
    }
}
