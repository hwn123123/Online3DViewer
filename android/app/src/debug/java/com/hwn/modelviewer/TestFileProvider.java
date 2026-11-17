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
    private String fixtureName(Uri uri) {
        switch (uri.getPath()) {
            case "/fixture3dm": return "android-test-fixture.3dm";
            case "/fixture": return "android-test-fixture.stl";
            case "/fixtureobj": return "android-test-fixture.obj";
            case "/fixturefbx": return "android-test-fixture.fbx";
            case "/teapot": return "android-test-teapot.stl";
            default: return null;
        }
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        MatrixCursor result = new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
        String name = fixtureName(uri);
        if (name == null) return result;
        File file = new File(getContext().getCacheDir(), name);
        result.addRow(new Object[]{name, file.length()});
        return result;
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        String name = fixtureName(uri);
        if (name == null || !"r".equals(mode)) throw new FileNotFoundException();
        return ParcelFileDescriptor.open(new File(getContext().getCacheDir(), name), ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
