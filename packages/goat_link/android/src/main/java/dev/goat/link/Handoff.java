package dev.goat.link;

import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.UriPermission;
import android.content.pm.PackageManager;
import android.content.pm.ProviderInfo;
import android.net.Uri;
import android.provider.DocumentsContract;

import java.util.HashMap;
import java.util.Map;

/** Validates a collection handed over by Goat Explorer and remembers it. */
final class Handoff {
    static final String EXPLORER = "dev.filebridge.app";
    static final String AUTHORITY = "dev.filebridge.app.documents";
    static final String ACTION_CONNECT = "dev.goat.action.CONNECT_COLLECTION";
    static final String ACTION_OPEN = "dev.goat.action.OPEN_COLLECTION";
    static final String EXTRA_ID = "dev.goat.extra.COLLECTION_ID";
    static final String EXTRA_NAME = "dev.goat.extra.COLLECTION_NAME";
    static final String EXTRA_VERSION = "dev.goat.extra.INDEX_VERSION";
    static final String EXTRA_SERVER = "dev.goat.extra.SERVER_NAME";
    static final String EXTRA_ERROR = "dev.goat.extra.ERROR";

    private static final String PREFS = "goat_link";

    private Handoff() {}

    /** Takes the persistable grant and stores the connection. False if it is not a real handoff. */
    static boolean accept(Context context, Intent intent) {
        if (intent == null) return false;
        Uri tree = intent.getData();
        if (!isExplorerTree(context, tree)) return false;
        int wanted = Intent.FLAG_GRANT_READ_URI_PERMISSION;
        if ((intent.getFlags() & wanted) == 0
                || (intent.getFlags() & Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) == 0) {
            return false;
        }
        try {
            context.getContentResolver().takePersistableUriPermission(tree, wanted);
        } catch (SecurityException e) {
            return false;
        }
        String id = intent.getStringExtra(EXTRA_ID);
        if (id == null || id.isEmpty()) return false;
        SharedPreferences.Editor edit = prefs(context).edit();
        String previous = prefs(context).getString("tree", null);
        edit.putString("tree", tree.toString())
                .putString("id", id)
                .putString("name", orEmpty(intent.getStringExtra(EXTRA_NAME)))
                .putString("version", orEmpty(intent.getStringExtra(EXTRA_VERSION)))
                .putString("server", orEmpty(intent.getStringExtra(EXTRA_SERVER)))
                .putBoolean("pending", true)
                .commit();
        // the collection moved (another disk, another PC): the old grant is dead weight
        if (previous != null && !previous.equals(tree.toString())) {
            release(context, Uri.parse(previous));
        }
        return true;
    }

    static boolean isExplorerTree(Context context, Uri uri) {
        if (uri == null || !ContentResolver.SCHEME_CONTENT.equals(uri.getScheme())) return false;
        if (!AUTHORITY.equals(uri.getAuthority())) return false;
        if (!DocumentsContract.isTreeUri(uri)) return false;
        // another app cannot pose as Explorer by declaring the same authority
        PackageManager pm = context.getPackageManager();
        ProviderInfo info = pm.resolveContentProvider(AUTHORITY, 0);
        return info != null && EXPLORER.equals(info.packageName);
    }

    static boolean hasGrant(Context context, Uri tree) {
        for (UriPermission p : context.getContentResolver().getPersistedUriPermissions()) {
            if (p.isReadPermission() && p.getUri().equals(tree)) return true;
        }
        return false;
    }

    static Map<String, Object> saved(Context context) {
        SharedPreferences p = prefs(context);
        String tree = p.getString("tree", null);
        if (tree == null) return null;
        Map<String, Object> out = new HashMap<>();
        out.put("treeUri", tree);
        out.put("collectionId", p.getString("id", ""));
        out.put("name", p.getString("name", ""));
        out.put("indexVersion", p.getString("version", ""));
        out.put("serverName", p.getString("server", ""));
        out.put("granted", hasGrant(context, Uri.parse(tree)));
        return out;
    }

    static void markPending(Context context) {
        prefs(context).edit().putBoolean("pending", true).apply();
    }

    /** True once after a new handoff arrived. */
    static boolean takePending(Context context) {
        SharedPreferences p = prefs(context);
        boolean pending = p.getBoolean("pending", false);
        if (pending) p.edit().putBoolean("pending", false).apply();
        return pending;
    }

    static void forget(Context context) {
        SharedPreferences p = prefs(context);
        String tree = p.getString("tree", null);
        if (tree != null) release(context, Uri.parse(tree));
        p.edit().clear().apply();
    }

    private static void release(Context context, Uri tree) {
        try {
            context.getContentResolver()
                    .releasePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION);
        } catch (SecurityException ignored) {
            // nothing was held
        }
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static String orEmpty(String s) {
        return s == null ? "" : s;
    }
}
