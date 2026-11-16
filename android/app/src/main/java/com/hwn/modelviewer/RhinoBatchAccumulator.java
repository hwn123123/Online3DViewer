package com.hwn.modelviewer;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

/** Coalesces adjacent small objects of identical style while keeping pickable source ranges. */
final class RhinoBatchAccumulator {
    private static final int MAX_INPUT=256*1024, MAX_BATCH=1024*1024, MAX_PARTS=256;
    interface Sink { void add(JSONObject item) throws JSONException; void check() throws IOException; }
    private final File directory;
    private final Sink sink;
    private final ByteBuffer positions=buffer(), normals=buffer(), indices=buffer(), lines=buffer(), colors=buffer();
    private final JSONArray parts=new JSONArray();
    private final List<File> inputs=new ArrayList<>();
    private JSONObject first;
    private String key;
    private boolean colored;
    private final double[] origin=new double[3], bounds=new double[6];
    private long inputBytes, bytesSaved;
    private int serial;

    RhinoBatchAccumulator(File directory, Sink sink) {this.directory=directory;this.sink=sink;}
    private static ByteBuffer buffer(){return ByteBuffer.allocate(MAX_BATCH).order(ByteOrder.LITTLE_ENDIAN);}
    private int bytes(){return 32+positions.position()+normals.position()+indices.position()+lines.position()+colors.position();}
    long bytesSaved(){return bytesSaved;}
    private void keep(JSONObject item) throws JSONException { item.put("index", -1);sink.add(item); }

    void accept(JSONObject item) throws IOException, JSONException {
        sink.check();
        boolean eligible=item.optBoolean("available") && !item.optBoolean("definitionMember") && !item.has("instanceDefinitionId")
            && !item.has("transform") && !item.has("parts") && item.optDouble("opacity",1)>=1 && item.optLong("bytes")<=MAX_INPUT;
        if(!eligible) {flush();keep(item);return;}
        String name=item.getString("url");
        if(!new File(name).getName().equals(name))throw new IOException("模型缓存文件名无效。");
        File file=new File(directory,name);
        long length=file.length();
        if(length<32 || length>MAX_INPUT || length!=item.getLong("bytes"))throw new IOException("模型缓存长度不正确。");
        byte[] bytes=new byte[(int)length];
        try(FileInputStream in=new FileInputStream(file)) {
            int at=0,n;while(at<bytes.length&&(n=in.read(bytes,at,bytes.length-at))>0)at+=n;
            if(at!=bytes.length)throw new IOException("模型缓存不完整。");
        }
        ByteBuffer data=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        int magic=data.getInt(0),version=data.getInt(4),vertices=data.getInt(8),indexCount=data.getInt(12),lineCount=data.getInt(16),hasColors=data.getInt(20);
        long expected=32L+vertices*(24L+(hasColors!=0?12L:0L))+indexCount*4L+lineCount*12L;
        if(magic!=0x3144334f||version!=1||vertices<0||indexCount<0||lineCount<0||hasColors<0||hasColors>1||indexCount%3!=0||lineCount%2!=0||data.getInt(24)!=0||data.getInt(28)!=0||expected!=length)
            throw new IOException("模型缓存格式无效。");
        String style=new JSONArray().put(item.optInt("layerIndex")).put(item.optInt("materialIndex",-1))
            .put(item.optJSONArray("color")).put(item.optJSONArray("lineColor")).put(item.optDouble("opacity",1))
            .put(item.optBoolean("visible",true)).put(item.optJSONArray("visibilityLayers")).put(hasColors).toString();
        if(first!=null&&(!style.equals(key)||parts.length()>=MAX_PARTS||bytes()+length-32>MAX_BATCH||!fits(data,item,vertices,indexCount,lineCount)))flush();
        if(first==null) {
            first=item;key=style;colored=hasColors!=0;
            for(int axis=0;axis<3;axis++){origin[axis]=item.getJSONArray("origin").getDouble(axis);bounds[axis]=item.getJSONArray("bounds").getDouble(axis);bounds[axis+3]=item.getJSONArray("bounds").getDouble(axis+3);}
        }
        if(!fits(data,item,vertices,indexCount,lineCount)){flush();keep(item);return;}
        int base=positions.position()/12, faceStart=indices.position()/4,lineStart=lines.position()/12;
        for(int i=0;i<vertices;i++)for(int axis=0;axis<3;axis++) positions.putFloat((float)(data.getFloat(32+i*12+axis*4)+item.getJSONArray("origin").getDouble(axis)-origin[axis]));
        int normalAt=32+vertices*12,facesAt=normalAt+vertices*12,lineAt=facesAt+indexCount*4,colorAt=lineAt+lineCount*12;
        for(int i=0;i<vertices*3;i++)normals.putFloat(data.getFloat(normalAt+i*4));
        for(int i=0;i<indexCount;i++){int index=data.getInt(facesAt+i*4);if(index<0||index>=vertices)throw new IOException("模型缓存顶点索引无效。");indices.putInt(base+index);}
        for(int i=0;i<lineCount;i++)for(int axis=0;axis<3;axis++)lines.putFloat((float)(data.getFloat(lineAt+i*12+axis*4)+item.getJSONArray("origin").getDouble(axis)-origin[axis]));
        if(colored)for(int i=0;i<vertices*3;i++)colors.putFloat(data.getFloat(colorAt+i*4));
        parts.put(new JSONObject().put("id",item.getString("id")).put("name",item.optString("name")).put("type",item.optString("type"))
            .put("start",faceStart).put("end",indices.position()/4).put("lineStart",lineStart).put("lineEnd",lines.position()/12));
        for(int axis=0;axis<3;axis++){bounds[axis]=Math.min(bounds[axis],item.getJSONArray("bounds").getDouble(axis));bounds[axis+3]=Math.max(bounds[axis+3],item.getJSONArray("bounds").getDouble(axis+3));}
        inputs.add(file);inputBytes+=length;
    }
    private boolean fits(ByteBuffer data,JSONObject item,int vertices,int indexCount,int lineCount) throws JSONException {
        JSONArray from=item.getJSONArray("origin");
        for(int kind=0;kind<2;kind++) {
            int offset=kind==0?32:32+vertices*24+indexCount*4,count=kind==0?vertices:lineCount;
            for(int i=0;i<count;i++)for(int axis=0;axis<3;axis++) {
                float value=data.getFloat(offset+i*12+axis*4);double shifted=(double)value+from.getDouble(axis)-origin[axis];
                if(!Double.isFinite(shifted)||Math.abs((double)(float)shifted-shifted)>Math.max(1e-4,Math.abs((double)value)*1e-6))return false;
            }
        }
        return true;
    }
    void flush() throws IOException, JSONException {
        if(first==null)return;
        sink.check();
        if(parts.length()==1) {keep(first);reset();return;}
        int count=bytes();ByteBuffer out=ByteBuffer.allocate(count).order(ByteOrder.LITTLE_ENDIAN);
        out.putInt(0x3144334f).putInt(1).putInt(positions.position()/12).putInt(indices.position()/4).putInt(lines.position()/12).putInt(colored?1:0).putInt(0).putInt(0);
        for(ByteBuffer source:new ByteBuffer[]{positions,normals,indices,lines,colors}){source.flip();out.put(source);}
        String name=String.format(java.util.Locale.ROOT,"batch-%06d.bin",serial++);
        try(FileOutputStream f=new FileOutputStream(new File(directory,name))){f.write(out.array());}
        JSONObject result=new JSONObject(first.toString());
        JSONArray originJson=new JSONArray(),boundsJson=new JSONArray();
        for(double v:origin)originJson.put(v);for(double v:bounds)boundsJson.put(v);
        result.put("id","o3dv-android-batch-"+serial).put("name","").put("type","GeometryBatch").put("url",name).put("bytes",count)
            .put("origin",originJson).put("bounds",boundsJson).put("vertices",positions.limit()/12).put("triangles",indices.limit()/12)
            .put("lineSegments",lines.limit()/24).put("parts",new JSONArray(parts.toString()));
        keep(result);
        for(File input:inputs)if(!input.delete())throw new IOException("无法清理已整理的模型缓存。");
        bytesSaved+=inputBytes-count;
        reset();
    }
    private void reset() {
        first=null;key=null;positions.clear();normals.clear();indices.clear();lines.clear();colors.clear();
        while(parts.length()>0)parts.remove(parts.length()-1);inputs.clear();inputBytes=0;
    }
}
