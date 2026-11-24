package dev.filebridge.app;

import android.content.Context;
import android.content.res.AssetManager;
import android.net.Uri;
import android.provider.DocumentsContract;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** The synthetic library, unpacked from assets, and the switchable failure mode. */
final class Fixture {
    static final String AUTHORITY = "dev.filebridge.app.documents";
    static final String SERVER = "fake-pc";
    static final String SHARE = "disk";
    static final String TREE_ID = SERVER + "/" + SHARE + "/Коллекция";
    static final String COLLECTION_ID = "fixturecollection01";

    private Fixture() {}

    static Uri treeUri() {
        return DocumentsContract.buildTreeDocumentUri(AUTHORITY, TREE_ID);
    }

    static String mode(Context c) {
        return c.getSharedPreferences("fixture", Context.MODE_PRIVATE).getString("mode", "ok");
    }

    static void setMode(Context c, String mode) {
        c.getSharedPreferences("fixture", Context.MODE_PRIVATE).edit().putString("mode", mode).commit();
    }

    static synchronized File library(Context c) throws IOException {
        File root = new File(c.getFilesDir(), "library");
        File done = new File(c.getFilesDir(), "library.done");
        if (!done.exists()) {
            copy(c.getAssets(), "library", root);
            if (!done.createNewFile()) throw new IOException("marker");
        }
        return root;
    }

    private static void copy(AssetManager assets, String path, File target) throws IOException {
        String[] names = assets.list(path);
        if (names != null && names.length > 0) {
            target.mkdirs();
            for (String n : names) copy(assets, path + "/" + n, new File(target, n));
            return;
        }
        try (InputStream in = assets.open(path); OutputStream out = new FileOutputStream(target)) {
            byte[] b = new byte[256 * 1024];
            int n;
            while ((n = in.read(b)) > 0) out.write(b, 0, n);
        }
    }

    static String indexVersion(Context c) throws IOException {
        File index = new File(library(c), ".goat-archive-export/library-index.sqlite3");
        return index.lastModified() + ":" + index.length();
    }
}
