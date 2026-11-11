package com.hwn.modelviewer;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/** Bounded STL decoder producing the same disk blocks consumed by the shared pager. */
final class StlStreamReader {
    static final int BLOCK_TRIANGLES = 16384;
    static final long STORAGE_RESERVE = 512L * 1024 * 1024;

    interface Listener {
        void check() throws IOException;
        void progress(long bytes, long total, long triangles);
        void manifestReady(File manifest);
    }

    private final File source, directory;
    private final Listener listener;
    private final JSONArray objects = new JSONArray();
    private final double[] globalBounds = initialBounds(), blockBounds = initialBounds();
    private final float[] positions = new float[BLOCK_TRIANGLES * 9];
    private final float[] normals = new float[BLOCK_TRIANGLES * 9];
    private final double[] origin = new double[3];
    private long triangles, geometryBytes, sourceObjects, lastPublish;
    private int blockTriangles;
    private String solidName, solidId = "stl-solid-0";
    private boolean started;
    private Input input;

    StlStreamReader(File source, File directory, Listener listener) {
        this.source = source;
        this.directory = directory;
        this.listener = listener;
        this.solidName = source.getName().replaceFirst("(?i)\\.stl$", "");
    }

    private static double[] initialBounds() {
        return new double[]{Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY,
                            Double.NEGATIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NEGATIVE_INFINITY};
    }

    void convert() throws Exception {
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("无法创建模型缓存。");
        if (source.length() == 0) throw new IOException("STL 文件为空。");
        try (Input stream = new Input(source)) {
            input = stream;
            listener.check();
            checkStorage(0);
            byte[] prefix = new byte[(int)Math.min(84, source.length())];
            stream.readFully(prefix);
            stream.rewind();
            long count = prefix.length == 84 ? Integer.toUnsignedLong(ByteBuffer.wrap(prefix, 80, 4).order(ByteOrder.LITTLE_ENDIAN).getInt()) : 0;
            boolean binary = prefix.length == 84 && 84L + count * 50L == source.length();
            if (binary) {
                if (count == 0) throw new IOException("STL 文件没有可显示的三角面。");
                long blocks = (count + BLOCK_TRIANGLES - 1) / BLOCK_TRIANGLES;
                checkStorage(Math.addExact(Math.multiplyExact(count, 84L), blocks * 4096L));
                stream.readFully(new byte[84]);
                sourceObjects = 1;
                byte[] record = new byte[50];
                for (long i = 0; i < count; i++) {
                    stream.readFully(record);
                    ByteBuffer values = ByteBuffer.wrap(record).order(ByteOrder.LITTLE_ENDIAN);
                    double[] normal = new double[3];
                    double[][] points = new double[3][3];
                    for (int k = 0; k < 3; k++) normal[k] = values.getFloat();
                    for (int j = 0; j < 3; j++) for (int k = 0; k < 3; k++) points[j][k] = values.getFloat();
                    add(points, normal);
                }
            } else {
                int begin = prefix.length >= 3 && (prefix[0] & 255) == 0xef && (prefix[1] & 255) == 0xbb && (prefix[2] & 255) == 0xbf ? 3 : 0;
                for (int i = begin; i < prefix.length; i++) {
                    int b = prefix[i] & 255;
                    if (b == 0 || (b < 32 && b != '\t' && b != '\r' && b != '\n' && b != '\f'))
                        throw new IOException("STL 二进制长度不匹配，文件可能已损坏或截断。");
                }
                if (begin == 3) stream.readFully(new byte[3]);
                parseAscii();
            }
            if (triangles == 0) throw new IOException("STL 文件没有可显示的三角面。");
            flush();
            listener.check();
            publish(true);
        }
    }

    private void parseAscii() throws Exception {
        Tokens tokens = new Tokens(input, listener);
        String word;
        boolean inside = false, solidHasFaces = false;
        long solids = 0;
        while ((word = tokens.next()) != null) {
            if (word.equals("solid") && !inside) {
                inside = true;
                solidHasFaces = false;
                solidId = "stl-solid-" + solids++;
                String name = tokens.restOfLine();
                solidName = name.isEmpty() ? source.getName().replaceFirst("(?i)\\.stl$", "") : name;
            } else if (word.equals("facet") && inside) {
                word = tokens.word();
                double[] normal = new double[3];
                if (word.equals("normal")) {
                    normal = tokens.vector();
                    tokens.expect("outer");
                } else if (!word.equals("outer")) throw new IOException("STL 三角面缺少 outer loop。");
                tokens.expect("loop");
                double[][] points = new double[3][];
                for (int i = 0; i < 3; i++) { tokens.expect("vertex"); points[i] = tokens.vector(); }
                tokens.expect("endloop");
                tokens.expect("endfacet");
                if (!solidHasFaces) { sourceObjects++; solidHasFaces = true; }
                add(points, normal);
            } else if (word.equals("endsolid") && inside) {
                flush();
                tokens.restOfLine();
                inside = false;
            } else throw new IOException("STL 文本结构无效，应包含完整的 solid 和三角面。");
        }
        if (inside) throw new IOException("STL 文本缺少 endsolid，文件可能已截断。");
    }

    private static double[] unit(double[] vector) {
        double scale = Math.max(Math.abs(vector[0]), Math.max(Math.abs(vector[1]), Math.abs(vector[2])));
        if (scale == 0) return new double[3];
        double x = vector[0] / scale, y = vector[1] / scale, z = vector[2] / scale;
        double len = Math.sqrt(x*x + y*y + z*z);
        return new double[]{x / len, y / len, z / len};
    }

    private static void addBounds(double[] bounds, double[] point) {
        for (int k = 0; k < 3; k++) {
            bounds[k] = Math.min(bounds[k], point[k]);
            bounds[k + 3] = Math.max(bounds[k + 3], point[k]);
        }
    }

    private void add(double[][] points, double[] normal) throws Exception {
        for (double[] p : points) for (double value : p) if (!Double.isFinite(value)) throw new IOException("STL 包含非有限坐标。");
        for (double value : normal) if (!Double.isFinite(value)) throw new IOException("STL 包含非有限法线。");
        if (blockTriangles == 0) System.arraycopy(points[0], 0, origin, 0, 3);
        normal = unit(normal);
        if (normal[0] == 0 && normal[1] == 0 && normal[2] == 0) {
            double[] u = unit(new double[]{points[1][0]-points[0][0], points[1][1]-points[0][1], points[1][2]-points[0][2]});
            double[] v = unit(new double[]{points[2][0]-points[0][0], points[2][1]-points[0][1], points[2][2]-points[0][2]});
            normal = unit(new double[]{u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]});
        }
        int at = blockTriangles * 9;
        for (double[] point : points) {
            addBounds(blockBounds, point);
            addBounds(globalBounds, point);
            for (int k = 0; k < 3; k++) {
                double local = point[k] - origin[k];
                if (!Double.isFinite(local) || Math.abs(local) > Float.MAX_VALUE) throw new IOException("STL 坐标超出显示范围。");
                positions[at] = (float)local;
                normals[at] = (float)normal[k];
                at++;
            }
        }
        blockTriangles++;
        triangles++;
        if (blockTriangles == BLOCK_TRIANGLES) flush();
        if ((triangles & 1023) == 0) {
            listener.check();
            listener.progress(input.consumed, source.length(), triangles);
        }
    }

    private void checkStorage(long required) throws IOException {
        long free = directory.getUsableSpace();
        if (free < STORAGE_RESERVE || required > free - STORAGE_RESERVE)
            throw new IOException("设备存储空间不足以保存模型缓存，请清理空间后重试。");
    }

    private static JSONArray numbers(double[] values) throws org.json.JSONException {
        JSONArray result = new JSONArray();
        for (double value : values) result.put(value);
        return result;
    }

    private void flush() throws Exception {
        if (blockTriangles == 0) return;
        listener.check();
        int vertexCount = blockTriangles * 3;
        int byteCount = 32 + vertexCount * 28;
        checkStorage(byteCount + (long)(objects.length() + 1) * 4096 + 16384);
        ByteBuffer bytes = ByteBuffer.allocate(byteCount).order(ByteOrder.LITTLE_ENDIAN);
        bytes.putInt(0x3144334f).putInt(2).putInt(vertexCount).putInt(vertexCount).putInt(0).putInt(0).putInt(0).putInt(0);
        for (int i = 0; i < vertexCount * 3; i++) bytes.putFloat(positions[i]);
        for (int i = 0; i < vertexCount * 3; i++) bytes.putFloat(normals[i]);
        for (int i = 0; i < vertexCount; i++) bytes.putInt(i);
        String name = String.format(java.util.Locale.ROOT, "object-%06d.bin", objects.length());
        try (FileOutputStream out = new FileOutputStream(new File(directory, name))) { out.write(bytes.array()); }
        JSONObject part = new JSONObject().put("id", solidId).put("name", solidName).put("type", "Mesh")
            .put("start", 0).put("end", vertexCount).put("lineStart", 0).put("lineEnd", 0)
            .put("sourceTriangleStart", triangles - blockTriangles);
        JSONObject object = new JSONObject().put("id", "chunk-" + objects.length()).put("index", objects.length())
            .put("name", solidName).put("type", "Mesh").put("layerIndex", 0).put("materialIndex", -1)
            .put("color", new JSONArray().put(.7).put(.72).put(.75)).put("opacity", 1)
            .put("lineColor", new JSONArray().put(.25).put(.25).put(.25)).put("visible", true)
            .put("definitionMember", false).put("available", true).put("origin", numbers(origin))
            .put("bounds", numbers(blockBounds)).put("url", name).put("bytes", byteCount)
            .put("vertices", vertexCount).put("triangles", blockTriangles).put("lineSegments", 0)
            .put("parts", new JSONArray().put(part));
        objects.put(object);
        geometryBytes += byteCount;
        blockTriangles = 0;
        System.arraycopy(initialBounds(), 0, blockBounds, 0, 6);
        if (!started || System.nanoTime() - lastPublish >= 200_000_000L) publish(false);
    }

    private void publish(boolean complete) throws Exception {
        listener.check();
        checkStorage((long)objects.length() * 4096 + 16384);
        JSONObject layer = new JSONObject().put("id", "model").put("index", 0).put("name", "模型").put("visible", true);
        JSONObject manifest = new JSONObject().put("format", "o3dv-stream-1").put("reader", "stl-stream-1")
            .put("name", source.getName()).put("sourceBytes", source.length()).put("maxBlockTriangles", BLOCK_TRIANGLES)
            .put("layers", new JSONArray().put(layer)).put("materials", new JSONArray()).put("objects", objects)
            .put("unsupported", new JSONArray()).put("missingFiles", new JSONArray()).put("complete", complete)
            .put("objectCount", objects.length()).put("sourceObjectCount", sourceObjects)
            .put("geometryBytes", geometryBytes).put("vertices", triangles * 3).put("triangles", triangles)
            .put("sourceTriangles", triangles).put("lineSegments", 0).put("bounds", numbers(globalBounds));
        File tmp = new File(directory, "manifest.tmp"), dest = new File(directory, "manifest.json");
        try (FileOutputStream output = new FileOutputStream(tmp)) { output.write(manifest.toString().getBytes(StandardCharsets.UTF_8)); }
        if (!tmp.renameTo(dest)) throw new IOException("无法写入 STL 模型清单。");
        lastPublish = System.nanoTime();
        listener.progress(input.consumed, source.length(), triangles);
        if (!started) { started = true; listener.manifestReady(dest); }
    }

    private static final class Input implements AutoCloseable {
        final File file;
        BufferedInputStream stream;
        int pending = -2;
        long consumed;
        Input(File file) throws IOException { this.file = file; rewind(); }
        void rewind() throws IOException {
            if (stream != null) stream.close();
            stream = new BufferedInputStream(new FileInputStream(file), 65536);
            consumed = 0; pending = -2;
        }
        int peek() throws IOException { if (pending == -2) pending = stream.read(); return pending; }
        int get() throws IOException { int c = peek(); pending = -2; if (c != -1) consumed++; return c; }
        void readFully(byte[] data) throws IOException {
            int offset = 0;
            if (pending != -2 && data.length > 0) {
                int b = get(); if (b < 0) throw new EOFException("STL 文件已截断。"); data[offset++] = (byte)b;
            }
            while (offset < data.length) {
                int count = stream.read(data, offset, data.length - offset);
                if (count < 0) throw new EOFException("STL 文件已截断。");
                offset += count; consumed += count;
            }
        }
        @Override public void close() throws IOException { stream.close(); }
    }

    private static final class Tokens {
        final Input input;
        final Listener listener;
        int sinceCheck;
        Tokens(Input input, Listener listener) { this.input = input; this.listener = listener; }
        int get() throws IOException { if (++sinceCheck >= 4096) { listener.check(); sinceCheck = 0; } return input.get(); }
        static boolean space(int c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == 11; }
        String restOfLine() throws IOException {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            boolean comment = false;
            while (input.peek() != -1 && input.peek() != '\n' && input.peek() != '\r') {
                int c = get();
                if (c == '#') comment = true;
                if (!comment && bytes.size() < 1024) bytes.write(c);
            }
            return new String(bytes.toByteArray(), StandardCharsets.UTF_8).trim();
        }
        String next() throws IOException {
            while (true) {
                int c = input.peek();
                if (c == -1) return null;
                if (c == '#') { restOfLine(); continue; }
                if (space(c)) { get(); continue; }
                break;
            }
            StringBuilder word = new StringBuilder();
            while (input.peek() != -1 && !space(input.peek()) && input.peek() != '#') {
                int c = get();
                if (c == 0 || c > 127 || word.length() >= 1024) throw new IOException("STL 文本包含无效或过长的数据项。");
                word.append((char)c);
            }
            return word.toString();
        }
        String word() throws IOException { String value = next(); if (value == null) throw new EOFException("STL 文本未完成。"); return value; }
        void expect(String expected) throws IOException { if (!word().equals(expected)) throw new IOException("STL 文本三角面结构无效。"); }
        double[] vector() throws IOException {
            double[] values = new double[3];
            for (int i = 0; i < 3; i++) {
                try { values[i] = Double.parseDouble(word()); }
                catch (NumberFormatException e) { throw new IOException("STL 包含无效数值。", e); }
                if (!Double.isFinite(values[i])) throw new IOException("STL 包含非有限数值。");
            }
            return values;
        }
    }
}
