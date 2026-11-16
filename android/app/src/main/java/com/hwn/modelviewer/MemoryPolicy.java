package com.hwn.modelviewer;

/** Geometry cache budget only; the WebView, GPU and process need separate memory. */
final class MemoryPolicy {
    private static final long MIB = 1024L * 1024;
    static int geometryBytes(long total, long available, boolean lowRam, boolean lowMemory) {
        if (lowMemory || lowRam || available < 768 * MIB) return (int)(24 * MIB);
        if (total >= 6L * 1024 * MIB && available >= 3L * 1024 * MIB) return (int)(192 * MIB);
        if (total >= 4L * 1024 * MIB && available >= 1536 * MIB) return (int)(96 * MIB);
        return (int)(48 * MIB);
    }
}
