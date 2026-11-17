package com.hwn.modelviewer;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.BufferedWriter;
import java.io.OutputStreamWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Incrementally reads 3DM on the worker and publishes pager-compatible local caches. */
final class RhinoStreamReader {
    interface Listener {
        void checkpoint() throws IOException;
        void progress(long objects);
        void manifestReady(File manifest);
    }
    private final File source, directory;
    private final Listener listener;
    private final JSONArray layers = new JSONArray(), materials = new JSONArray(), unsupported = new JSONArray();
    private final List<String> objects = new ArrayList<>();
    private final List<JSONObject> references = new ArrayList<>();
    private final Map<String, JSONObject> definitions = new HashMap<>(), sources = new HashMap<>();
    private final Set<String> definitionMembers = new HashSet<>();
    private final Map<Integer, JSONObject> materialByIndex = new HashMap<>();
    private long lastPublish, geometryBytes, triangles, vertices, lines;
    private final double[] bounds={Double.POSITIVE_INFINITY,Double.POSITIVE_INFINITY,Double.POSITIVE_INFINITY,Double.NEGATIVE_INFINITY,Double.NEGATIVE_INFINITY,Double.NEGATIVE_INFINITY};
    private long sourceCount;
    private RhinoBatchAccumulator batch;
    private boolean started;

    RhinoStreamReader(File source, File directory, Listener listener) {
        this.source = source; this.directory = directory; this.listener = listener;
    }

    void convert() throws IOException {
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("无法创建 3DM 缓存目录。");
        RhinoNativeReader reader = new RhinoNativeReader(new RhinoNativeReader.Listener() {
            @Override public void checkpoint() throws IOException { RhinoStreamReader.this.checkpoint(); }
            @Override public void header(String json) throws IOException {
                try { readHeader(new JSONObject(json)); }
                catch (JSONException e) { throw new IOException("3DM 图层或材质信息无效。", e); }
            }
            @Override public void object(String json) throws IOException {
                try { addObject(new JSONObject(json)); }
                catch (JSONException e) { throw new IOException("3DM 对象信息无效。", e); }
            }
        });
        String failure = reader.convert(source.getAbsolutePath(), directory.getAbsolutePath());
        if (failure == null || !failure.isEmpty()) throw new IOException(failure == null ? "3DM 读取已停止。" : failure);
        try { if(batch!=null)batch.flush(); resolveInstances(); publish(true); }
        catch (JSONException e) { throw new IOException("3DM 对象清单无效。", e); }
    }

    private void checkpoint() throws IOException {
        listener.checkpoint();
        if (directory.getUsableSpace() < StlStreamReader.STORAGE_RESERVE) throw new IOException("设备存储空间不足，请清理空间后重试。");
    }

    private void readHeader(JSONObject header) throws JSONException {
        JSONArray sourceLayers = header.getJSONArray("layers"), sourceMaterials = header.getJSONArray("materials");
        for (int i = 0; i < sourceLayers.length(); i++) layers.put(sourceLayers.getJSONObject(i));
        for (int i = 0; i < sourceMaterials.length(); i++) {
            JSONObject item = sourceMaterials.getJSONObject(i); materials.put(item); materialByIndex.put(item.optInt("index"), item);
        }
        JSONArray defs = header.getJSONArray("definitions");
        for (int i = 0; i < defs.length(); i++) {
            JSONObject item = defs.getJSONObject(i); definitions.put(item.getString("id"), item);
            JSONArray members=item.getJSONArray("members");
            for(int j=0;j<members.length();j++)definitionMembers.add(members.getString(j));
        }
    }

    private void addObject(JSONObject item) throws IOException, JSONException {
        checkpoint();
        sourceCount++;
        boolean definitionMember=definitionMembers.contains(item.getString("id"));
        if (definitionMember) sources.put(item.getString("id"), item);
        geometryBytes += item.optLong("bytes");
        if (!item.optBoolean("available") && !item.has("instanceDefinitionId")) addUnsupported(item, "不支持此对象或文件没有保存可用的显示网格");
        else if (item.has("partialReason")) addUnsupported(item, item.getString("partialReason"));
        if (sourceCount > 1024) {
            if(batch==null)batch=new RhinoBatchAccumulator(directory,new RhinoBatchAccumulator.Sink() {
                @Override public void add(JSONObject value) throws JSONException { addItem(value); }
                @Override public void check() throws IOException { checkpoint(); }
            });
            if(definitionMember){batch.flush();addItem(item);}else batch.accept(item);
        } else addItem(item);
        listener.progress(sourceCount);
        long publishInterval=Math.min(4_000_000_000L,250_000_000L+sourceCount/1000*250_000_000L);
        if (!started || (sourceCount % 8 == 0 && System.nanoTime() - lastPublish > publishInterval)) {
            if(batch!=null)batch.flush();
            publish(false);
        }
    }

    private void addUnsupported(JSONObject item, String reason) throws JSONException {
        unsupported.put(new JSONObject().put("id", item.optString("id")).put("name", item.optString("name"))
            .put("type", item.optString("type")).put("reason", reason));
    }

    private void addItem(JSONObject item) throws JSONException {
        item.put("index",objects.size());
        if(item.has("instanceDefinitionId")&&!item.optBoolean("definitionMember"))references.add(item);
        if(item.optBoolean("available")&&!item.optBoolean("definitionMember")) {
            triangles+=item.optLong("triangles");vertices+=item.optLong("vertices");lines+=item.optLong("lineSegments");
            JSONArray b=item.getJSONArray("bounds");
            for(int k=0;k<3;k++){bounds[k]=Math.min(bounds[k],b.getDouble(k));bounds[k+3]=Math.max(bounds[k+3],b.getDouble(k+3));}
        }
        // Retain a compact JSON representation instead of thousands of JSONObject trees.
        objects.add(item.toString());
    }

    private static double[] matrix(JSONArray values) throws JSONException {
        if (values == null || values.length() != 16) throw new JSONException("invalid matrix");
        double[] result = new double[16];
        for (int i = 0; i < 16; i++) { result[i] = values.getDouble(i); if (!Double.isFinite(result[i])) throw new JSONException("invalid matrix"); }
        if (result[3] != 0 || result[7] != 0 || result[11] != 0 || result[15] != 1) throw new JSONException("non-affine matrix");
        double determinant = result[0]*(result[5]*result[10]-result[9]*result[6])
            - result[4]*(result[1]*result[10]-result[9]*result[2])
            + result[8]*(result[1]*result[6]-result[5]*result[2]);
        if (!Double.isFinite(determinant) || determinant == 0) throw new JSONException("singular matrix");
        return result;
    }
    private static double[] multiply(double[] a, double[] b) {
        double[] out = new double[16];
        for (int c=0;c<4;c++) for (int r=0;r<4;r++) for (int k=0;k<4;k++) out[c*4+r] += a[k*4+r]*b[c*4+k];
        return out;
    }
    private static JSONArray json(double[] values) throws JSONException {
        JSONArray out = new JSONArray(); for (double v : values) out.put(v); return out;
    }
    private static double[] transformBounds(JSONArray bounds, double[] m) throws JSONException {
        double[] result = {Double.POSITIVE_INFINITY,Double.POSITIVE_INFINITY,Double.POSITIVE_INFINITY,Double.NEGATIVE_INFINITY,Double.NEGATIVE_INFINITY,Double.NEGATIVE_INFINITY};
        for (int mask=0;mask<8;mask++) {
            double x=bounds.getDouble((mask&1)==0?0:3), y=bounds.getDouble((mask&2)==0?1:4), z=bounds.getDouble((mask&4)==0?2:5);
            double[] point={m[0]*x+m[4]*y+m[8]*z+m[12],m[1]*x+m[5]*y+m[9]*z+m[13],m[2]*x+m[6]*y+m[10]*z+m[14]};
            for(int i=0;i<3;i++) {if(!Double.isFinite(point[i]))throw new JSONException("invalid bounds");result[i]=Math.min(result[i],point[i]);result[i+3]=Math.max(result[i+3],point[i]);}
        }
        return result;
    }

    private void resolveInstances() throws JSONException, IOException {
        for (JSONObject item : references) {
            checkpoint();
            try {
                List<JSONObject> placements = new ArrayList<>();
                expand(item, new double[]{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}, null,
                    new ArrayList<>(), new ArrayList<>(), new ArrayList<>(), item.getString("id"), new HashSet<>(), placements, 0);
                for (JSONObject placement : placements) addItem(placement);
            } catch (JSONException e) { addUnsupported(item, "块实例数据不完整或包含无效变换"); }
        }
    }

    private void expand(JSONObject sourceItem, double[] parent, JSONObject parentStyle, List<String> path, List<String> names,
                        List<Integer> visibility, String root, Set<String> visiting, List<JSONObject> placements, int depth) throws IOException, JSONException {
        checkpoint();
        if (depth >= 256) throw new JSONException("instance depth");
        JSONObject item = new JSONObject(sourceItem.toString());
        if (parentStyle != null && item.optInt("colorSource") == 3) item.put("lineColor", parentStyle.getJSONArray("lineColor"));
        if (parentStyle != null && item.optInt("materialSource") == 3) item.put("materialIndex", parentStyle.getInt("materialIndex"));
        JSONObject material=materialByIndex.get(item.optInt("materialIndex"));
        if(item.optInt("colorSource")==2 && material!=null)item.put("lineColor",material.getJSONArray("color"));
        item.put("color",material!=null?material.getJSONArray("color"):item.getJSONArray("lineColor"));
        item.put("opacity",material!=null?material.optDouble("opacity",1):1);
        item.put("visible", item.optBoolean("visible",true) && (parentStyle==null || parentStyle.optBoolean("visible",true)));
        List<Integer> nextVisibility=new ArrayList<>(visibility);
        int layer=item.getInt("layerIndex");if(!nextVisibility.contains(layer))nextVisibility.add(layer);
        String definitionId=item.optString("instanceDefinitionId", "");
        if (!definitionId.isEmpty()) {
            if(!visiting.add(definitionId))throw new JSONException("recursive instance");
            JSONObject definition=definitions.get(definitionId);if(definition==null)throw new JSONException("missing definition");
            double[] combined=multiply(parent,matrix(item.optJSONArray("instanceTransform")));
            List<String> nextPath=new ArrayList<>(path);nextPath.add(item.getString("id"));
            List<String> nextNames=new ArrayList<>(names);String name=item.optString("name");if(name.isEmpty())name=definition.optString("name");if(!name.isEmpty())nextNames.add(name);
            JSONArray members=definition.getJSONArray("members");
            for(int i=0;i<members.length();i++) {
                JSONObject member=sources.get(members.getString(i));if(member==null)throw new JSONException("missing member");
                expand(member,combined,item,nextPath,nextNames,nextVisibility,root,visiting,placements,depth+1);
            }
            visiting.remove(definitionId);return;
        }
        if(!item.optBoolean("available"))throw new JSONException("unsupported member");
        List<String> fullPath=new ArrayList<>(path);fullPath.add(item.getString("id"));
        List<String> fullNames=new ArrayList<>(names);if(!item.optString("name").isEmpty())fullNames.add(item.getString("name"));
        item.put("id",String.join("/",fullPath)).put("index",objects.size())
            .put("name",fullNames.isEmpty()?item.getString("type"):String.join(" / ",fullNames))
            .put("definitionMember",false).put("transform",json(parent)).put("bounds",json(transformBounds(item.getJSONArray("bounds"),parent)))
            .put("visibilityLayers",new JSONArray(nextVisibility)).put("instanceId",root).put("instancePath",new JSONArray(path))
            .put("sourceObjectId",sourceItem.getString("id"));
        placements.add(item);
    }

    private void publish(boolean complete) throws IOException, JSONException {
        checkpoint();
        double[] publishedBounds=Double.isFinite(bounds[0])?bounds:new double[6];
        JSONObject manifest=new JSONObject().put("format","o3dv-stream-1").put("reader","opennurbs-android-1")
            .put("name",source.getName()).put("sourceBytes",source.length()).put("layers",layers).put("materials",materials)
            .put("missingFiles",new JSONArray()).put("complete",complete)
            .put("warnings",new JSONArray().put("Rhino 贴图和部分渲染材质暂未完整显示"))
            .put("objectCount",objects.size()).put("sourceObjectCount",sourceCount).put("geometryBytes",geometryBytes-(batch==null?0:batch.bytesSaved()))
            .put("triangles",triangles).put("vertices",vertices).put("lineSegments",lines).put("bounds",json(publishedBounds));
        File temp=new File(directory,"manifest.tmp"), dest=new File(directory,"manifest.json");
        // Avoid creating several full-size copies of a potentially huge object list on the Java heap.
        try(BufferedWriter out=new BufferedWriter(new OutputStreamWriter(new FileOutputStream(temp),StandardCharsets.UTF_8))) {
            String header=manifest.toString();out.write(header,0,header.length()-1);out.write(",\"objects\":[");
            for(int i=0;i<objects.size();i++){if(i>0)out.write(',');out.write(objects.get(i));}
            out.write("],\"unsupported\":[");
            for(int i=0;i<unsupported.length();i++){if(i>0)out.write(',');out.write(unsupported.getJSONObject(i).toString());}
            out.write("]}");
        }
        if(!temp.renameTo(dest))throw new IOException("无法写入 3DM 模型清单。");
        lastPublish=System.nanoTime();
        if(!started){started=true;listener.manifestReady(dest);}
    }
}
