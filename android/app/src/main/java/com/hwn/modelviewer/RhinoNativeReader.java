package com.hwn.modelviewer;

import java.io.IOException;
import java.nio.charset.StandardCharsets;

/** JNI adapter for incremental openNURBS reading. Callbacks run on the import worker. */
final class RhinoNativeReader {
    static { System.loadLibrary("o3dv_rhino"); }
    interface Listener {
        void checkpoint() throws IOException;
        void header(String json) throws IOException;
        void object(String json) throws IOException;
    }
    private final Listener listener;
    RhinoNativeReader(Listener listener) { this.listener = listener; }
    private void checkpoint() throws IOException { listener.checkpoint(); }
    private void header(String json) throws IOException { listener.header(json); }
    private void object(String json) throws IOException { listener.object(json); }
    String convert(String source, String outputDirectory) throws IOException {
        return convertBytes(source.getBytes(StandardCharsets.UTF_8), outputDirectory.getBytes(StandardCharsets.UTF_8));
    }
    private native String convertBytes(byte[] source, byte[] outputDirectory) throws IOException;
}
