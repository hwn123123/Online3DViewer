package com.hwn.modelviewer;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileNotFoundException;

/** Debug-only fixed fixture provider, used to exercise the real content URI import path. */
public final class TestFileProvider extends ContentProvider {
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return "application/octet-stream"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        MatrixCursor result = new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
        String name = "/fixture".equals(uri.getPath()) ? "android-test-fixture.stl" : "android-test-teapot.stl";
        File file = new File(getContext().getCacheDir(), name);
        result.addRow(new Object[]{name, file.length()});
        return result;
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if ((!"/teapot".equals(uri.getPath()) && !"/fixture".equals(uri.getPath())) || !"r".equals(mode)) throw new FileNotFoundException();
        String name = "/fixture".equals(uri.getPath()) ? "android-test-fixture.stl" : "android-test-teapot.stl";
        return ParcelFileDescriptor.open(new File(getContext().getCacheDir(), name), ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
