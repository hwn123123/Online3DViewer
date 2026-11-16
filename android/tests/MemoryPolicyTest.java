package com.hwn.modelviewer;

public final class MemoryPolicyTest {
    private static final long M = 1024L * 1024;
    private static void check(long total,long free,boolean lowRam,boolean lowMemory,int expected) {
        int actual=MemoryPolicy.geometryBytes(total*M,free*M,lowRam,lowMemory);
        if(actual!=expected*M)throw new AssertionError("Expected "+expected+" MiB, got "+actual/M);
    }
    public static void main(String[] args) {
        check(16000,8000,false,false,192);
        check(6000,2000,false,false,96);
        check(3000,1500,false,false,48);
        check(16000,500,false,false,24);
        check(16000,8000,true,false,24);
        check(16000,8000,false,true,24);
        System.out.println("PASS memory budget adapts to available memory and low-memory signals");
    }
}
