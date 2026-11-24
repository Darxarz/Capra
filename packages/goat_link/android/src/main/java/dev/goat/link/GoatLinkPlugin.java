package dev.goat.link;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Point;
import android.net.Uri;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.os.OperationCanceledException;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import android.util.Log;

import androidx.annotation.NonNull;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * Reads the PC collection through Goat Explorer's DocumentsProvider. Every read goes through
 * ContentResolver with the read-only grant Explorer handed over; there is no write path here.
 */
public class GoatLinkPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler,
        ActivityAware, PluginRegistry.ActivityResultListener, PluginRegistry.NewIntentListener {

    private static final String TAG = "GoatLink";
    private static final int REQUEST_CONNECT = 0x60A7;
    private static final String INDEX_REL = ".goat-archive-export/library-index.sqlite3";
    private static final long THUMB_CACHE_BYTES = 1024L * 1024 * 1024;
    private static final long FULL_CACHE_BYTES = 1024L * 1024 * 1024;
    private static final int TRIM_EVERY = 200;

    private static volatile GoatLinkPlugin active;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newFixedThreadPool(8);
    private final ExecutorService control = Executors.newCachedThreadPool();
    private final Map<Integer, CancellationSignal> signals = new ConcurrentHashMap<>();
    private final AtomicInteger writes = new AtomicInteger();

    private MethodChannel channel;
    private Context context;
    private ActivityPluginBinding binding;
    private MethodChannel.Result connectResult;

    static void notifyHandoff() {
        GoatLinkPlugin plugin = active;
        if (plugin == null) return; // the app picks it up from takeHandoff on start
        plugin.main.post(() -> {
            if (plugin.channel != null) plugin.channel.invokeMethod("handoff", null);
        });
    }

    // ---------- plugin lifecycle ----------

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutter) {
        context = flutter.getApplicationContext();
        channel = new MethodChannel(flutter.getBinaryMessenger(), "dev.goat.link");
        channel.setMethodCallHandler(this);
        active = this;
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding flutter) {
        channel.setMethodCallHandler(null);
        channel = null;
        if (active == this) active = null;
        for (CancellationSignal s : signals.values()) s.cancel();
        io.shutdown();
        control.shutdown();
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding b) {
        binding = b;
        b.addActivityResultListener(this);
        b.addOnNewIntentListener(this);
        // started by Explorer's Gallery button while the app was closed
        if (consumeOpen(b.getActivity().getIntent())) Handoff.markPending(context);
    }

    /** Explorer addresses the launcher activity directly, so a running app gets it here. */
    @Override
    public boolean onNewIntent(@NonNull Intent intent) {
        if (!Handoff.ACTION_OPEN.equals(intent.getAction())) return false;
        if (consumeOpen(intent)) notifyHandoff();
        return true;
    }

    /**
     * Keeps the grant, then strips the intent: Flutter would otherwise treat the content URI as a
     * deep link to a route, and a recreated activity would handle the same handoff again.
     */
    private boolean consumeOpen(Intent intent) {
        if (intent == null || !Handoff.ACTION_OPEN.equals(intent.getAction())) return false;
        boolean accepted = Handoff.accept(context, intent);
        intent.setAction(Intent.ACTION_MAIN);
        intent.setData(null);
        return accepted;
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding b) {
        onAttachedToActivity(b);
    }

    @Override
    public void onDetachedFromActivity() {
        if (binding != null) {
            binding.removeActivityResultListener(this);
            binding.removeOnNewIntentListener(this);
        }
        binding = null;
    }

    // ---------- calls ----------

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "explorerInstalled":
                result.success(explorerInstalled());
                break;
            case "openExplorer":
                result.success(openExplorer());
                break;
            case "saved":
                result.success(Handoff.saved(context));
                break;
            case "takeHandoff":
                result.success(Handoff.takePending(context));
                break;
            case "forget":
                Handoff.forget(context);
                result.success(null);
                break;
            case "connect":
                connect(result);
                break;
            case "probe":
                background(control, result, () -> probe(tree(call)));
                break;
            case "copyIndex": {
                Uri tree = tree(call);
                String dest = call.argument("dest");
                background(control, result, () -> copyIndex(tree, dest));
                break;
            }
            case "thumbnail": {
                Uri tree = tree(call);
                int id = call.argument("id");
                String rel = call.argument("rel");
                String key = call.argument("key");
                int size = call.argument("size");
                CancellationSignal signal = register(id);
                background(io, result, id, () -> thumbnail(tree, rel, key, size, signal));
                break;
            }
            case "full": {
                Uri tree = tree(call);
                int id = call.argument("id");
                String rel = call.argument("rel");
                String key = call.argument("key");
                CancellationSignal signal = register(id);
                background(io, result, id, () -> full(tree, rel, key, signal));
                break;
            }
            case "cancel": {
                int id = call.argument("id");
                CancellationSignal signal = signals.remove(id);
                if (signal != null) signal.cancel();
                result.success(null);
                break;
            }
            case "openFd": {
                Uri tree = tree(call);
                String rel = call.argument("rel");
                background(control, result, () -> openFd(tree, rel));
                break;
            }
            case "closeFd": {
                int fd = call.argument("fd");
                control.execute(() -> closeFd(fd));
                result.success(null);
                break;
            }
            default:
                result.notImplemented();
        }
    }

    private Uri tree(MethodCall call) {
        return Uri.parse(call.<String>argument("treeUri"));
    }

    private interface Job {
        Object run() throws Exception;
    }

    private CancellationSignal register(int id) {
        CancellationSignal signal = new CancellationSignal();
        signals.put(id, signal);
        return signal;
    }

    private void background(ExecutorService pool, MethodChannel.Result result, Job job) {
        background(pool, result, null, job);
    }

    private void background(ExecutorService pool, MethodChannel.Result result, Integer id, Job job) {
        pool.execute(() -> {
            Object value = null;
            String code = null;
            String message = null;
            try {
                value = job.run();
            } catch (OperationCanceledException e) {
                code = "canceled";
            } catch (SecurityException e) {
                code = "revoked";
                message = e.getMessage();
            } catch (FileNotFoundException e) {
                // Explorer reports every failure this way, a refused grant included
                code = isRefused(e.getMessage()) ? "revoked" : "offline";
                message = e.getMessage();
            } catch (Exception e) {
                code = "failed";
                message = String.valueOf(e);
            }
            if (id != null) signals.remove(id);
            final Object v = value;
            final String c = code;
            final String m = message;
            main.post(() -> {
                if (c == null) result.success(v);
                else result.error(c, m, null);
            });
        });
    }

    // ---------- Explorer ----------

    private boolean explorerInstalled() {
        return context.getPackageManager().getLaunchIntentForPackage(Handoff.EXPLORER) != null;
    }

    private boolean openExplorer() {
        Intent intent = context.getPackageManager().getLaunchIntentForPackage(Handoff.EXPLORER);
        if (intent == null) return false;
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        context.startActivity(intent);
        return true;
    }

    private void connect(MethodChannel.Result result) {
        Activity activity = binding == null ? null : binding.getActivity();
        if (activity == null) {
            result.error("failed", "no activity", null);
            return;
        }
        if (connectResult != null) {
            result.error("busy", "already connecting", null);
            return;
        }
        Intent intent = new Intent(Handoff.ACTION_CONNECT).setPackage(Handoff.EXPLORER);
        connectResult = result;
        try {
            activity.startActivityForResult(intent, REQUEST_CONNECT);
        } catch (ActivityNotFoundException e) {
            connectResult = null;
            Map<String, Object> out = new HashMap<>();
            out.put("status", explorerInstalled() ? "outdated" : "not_installed");
            result.success(out);
        }
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQUEST_CONNECT) return false;
        MethodChannel.Result result = connectResult;
        connectResult = null;
        if (result == null) return true;
        Map<String, Object> out = new HashMap<>();
        if (resultCode == Activity.RESULT_OK) {
            if (Handoff.accept(context, data)) {
                Handoff.takePending(context); // this screen is handling it right now
                out.put("status", "ok");
                out.put("connection", Handoff.saved(context));
            } else {
                out.put("status", "error");
                out.put("error", "bad_grant");
            }
        } else if (resultCode == Activity.RESULT_FIRST_USER) {
            out.put("status", "error");
            String error = data == null ? null : data.getStringExtra(Handoff.EXTRA_ERROR);
            out.put("error", error == null ? "offline" : error);
        } else {
            out.put("status", "canceled");
        }
        result.success(out);
        return true;
    }

    // ---------- documents ----------

    private static String requireRelative(String rel) throws FileNotFoundException {
        if (rel == null || rel.isEmpty() || rel.startsWith("/") || rel.contains("\\")) {
            throw new FileNotFoundException("bad path");
        }
        for (String segment : rel.split("/")) {
            if (segment.isEmpty() || segment.equals(".") || segment.equals("..")) {
                throw new FileNotFoundException("bad path");
            }
        }
        return rel;
    }

    private static Uri documentUri(Uri tree, String rel) throws FileNotFoundException {
        String base = DocumentsContract.getTreeDocumentId(tree);
        return DocumentsContract.buildDocumentUriUsingTree(tree, base + "/" + requireRelative(rel));
    }

    /**
     * The PC refuses a tree that is no longer the collection (it moved), and Explorer drops a PC
     * that was unpaired. The provider can only say so in the FileNotFoundException text.
     */
    private static boolean isRefused(String message) {
        return message != null
                && (message.contains("вне коллекции") || message.contains("больше не подключён"));
    }

    /** A query only returns null; opening the index tells a refusal from a dead network. */
    private String whyUnavailable(ContentResolver resolver, Uri index, String otherwise) {
        try (ParcelFileDescriptor pfd = resolver.openFileDescriptor(index, "r")) {
            return otherwise;
        } catch (SecurityException e) {
            return "revoked";
        } catch (IOException | RuntimeException e) {
            return isRefused(e.getMessage()) ? "revoked" : otherwise;
        }
    }

    private Map<String, Object> probe(Uri tree) {
        Map<String, Object> out = new HashMap<>();
        if (!Handoff.isExplorerTree(context, tree)) {
            out.put("state", explorerInstalled() ? "revoked" : "not_installed");
            return out;
        }
        if (!Handoff.hasGrant(context, tree)) {
            out.put("state", "revoked");
            return out;
        }
        ContentResolver resolver = context.getContentResolver();
        try {
            Uri rootDoc = DocumentsContract.buildDocumentUriUsingTree(
                    tree, DocumentsContract.getTreeDocumentId(tree));
            Uri indexDoc = documentUri(tree, INDEX_REL);
            if (stat(resolver, rootDoc) == null) {
                out.put("state", whyUnavailable(resolver, indexDoc, "offline"));
                return out;
            }
            // by its direct id: directory listings do not show the bookkeeping folder
            long[] index = stat(resolver, indexDoc);
            if (index == null) {
                out.put("state", whyUnavailable(resolver, indexDoc, "no_collection"));
                return out;
            }
            out.put("state", "ok");
            out.put("indexVersion", index[0] + ":" + index[1]);
            out.put("indexSize", index[1]);
        } catch (SecurityException e) {
            out.put("state", "revoked");
        } catch (FileNotFoundException | RuntimeException e) {
            out.put("state", "offline");
        }
        return out;
    }

    /** {mtime, size}, or null when the provider could not answer. */
    private static long[] stat(ContentResolver resolver, Uri doc) throws FileNotFoundException {
        String[] columns = {Document.COLUMN_LAST_MODIFIED, Document.COLUMN_SIZE};
        try (Cursor c = resolver.query(doc, columns, null, null, null)) {
            if (c == null || !c.moveToFirst()) return null;
            return new long[]{c.isNull(0) ? 0 : c.getLong(0), c.isNull(1) ? 0 : c.getLong(1)};
        }
    }

    /**
     * Copies the index (about 220 MB) to the cache. An interrupted copy continues from where it
     * stopped, but only while the index on the PC is still the same version.
     */
    private Map<String, Object> copyIndex(Uri tree, String dest) throws IOException {
        File target = new File(dest);
        File parent = target.getParentFile();
        if (parent != null) parent.mkdirs();
        File part = new File(dest + ".part");
        File stamp = new File(dest + ".part.version");
        ContentResolver resolver = context.getContentResolver();
        Uri doc = documentUri(tree, INDEX_REL);
        long[] before = stat(resolver, doc);
        if (before == null) {
            throw new FileNotFoundException(whyUnavailable(resolver, doc, "offline").equals("revoked")
                    ? "вне коллекции" : "no index");
        }
        String version = before[0] + ":" + before[1];
        long have = 0;
        if (part.exists() && version.equals(readText(stamp)) && part.length() <= before[1]) {
            have = part.length();
        } else {
            part.delete();
            writeText(stamp, version);
        }
        long done = have;
        long lastReport = have;
        long expected;
        try (ParcelFileDescriptor pfd = resolver.openFileDescriptor(doc, "r")) {
            if (pfd == null) throw new FileNotFoundException("no index");
            expected = pfd.getStatSize();
            try (FileInputStream in = new FileInputStream(pfd.getFileDescriptor());
                 FileOutputStream out = new FileOutputStream(part, have > 0)) {
                if (have > 0) {
                    in.getChannel().position(have);
                    Log.i(TAG, "index copy resumed at " + have + " of " + expected);
                    reportCopy(done, expected);
                }
                byte[] buffer = new byte[1024 * 1024];
                while (true) {
                    int n;
                    try {
                        n = in.read(buffer);
                    } catch (IOException e) {
                        // the network, not this device: what is already here stays for the retry
                        throw new FileNotFoundException(e.getMessage());
                    }
                    if (n <= 0) break;
                    out.write(buffer, 0, n);
                    done += n;
                    if (done - lastReport >= 4L * 1024 * 1024) {
                        lastReport = done;
                        reportCopy(done, expected);
                    }
                }
                out.getFD().sync();
            }
        }
        long[] after = stat(resolver, doc);
        if (after == null) throw new FileNotFoundException("no index");
        if (done != expected || after[0] != before[0] || after[1] != before[1]) {
            part.delete();
            stamp.delete();
            throw new IOException("index changed while copying");
        }
        if (!part.renameTo(target)) {
            target.delete();
            if (!part.renameTo(target)) {
                part.delete();
                stamp.delete();
                throw new IOException("could not store the index copy");
            }
        }
        stamp.delete();
        reportCopy(done, expected);
        Map<String, Object> out = new HashMap<>();
        out.put("bytes", done);
        out.put("resumedFrom", have);
        return out;
    }

    private static String readText(File file) {
        try (FileInputStream in = new FileInputStream(file)) {
            byte[] bytes = new byte[128];
            int n = in.read(bytes);
            return n <= 0 ? "" : new String(bytes, 0, n, StandardCharsets.UTF_8);
        } catch (IOException e) {
            return "";
        }
    }

    private static void writeText(File file, String text) throws IOException {
        try (FileOutputStream out = new FileOutputStream(file)) {
            out.write(text.getBytes(StandardCharsets.UTF_8));
        }
    }

    private void reportCopy(long done, long total) {
        main.post(() -> {
            if (channel == null) return;
            Map<String, Object> args = new HashMap<>();
            args.put("done", done);
            args.put("total", total);
            channel.invokeMethod("copyProgress", args);
        });
    }

    private File cacheDir(String name) {
        File dir = new File(context.getCacheDir(), "goat_link/" + name);
        dir.mkdirs();
        return dir;
    }

    private static String safeKey(String key) throws FileNotFoundException {
        if (key == null || !key.matches("[0-9A-Za-z_-]{1,120}")) {
            throw new FileNotFoundException("bad key");
        }
        return key;
    }

    private String thumbnail(Uri tree, String rel, String key, int size, CancellationSignal signal)
            throws IOException {
        File file = new File(cacheDir("thumbs"), safeKey(key) + "-" + size + ".jpg");
        if (file.length() > 0) {
            file.setLastModified(System.currentTimeMillis());
            return file.getPath();
        }
        signal.throwIfCanceled();
        Uri doc = documentUri(tree, rel);
        Bitmap bitmap = DocumentsContract.getDocumentThumbnail(
                context.getContentResolver(), doc, new Point(size, size), signal);
        if (bitmap == null) throw new FileNotFoundException("no thumbnail");
        File part = new File(file.getPath() + ".part");
        try (OutputStream out = new FileOutputStream(part)) {
            bitmap.compress(Bitmap.CompressFormat.JPEG, 84, out);
        } finally {
            bitmap.recycle();
        }
        if (!part.renameTo(file)) {
            part.delete();
            throw new IOException("could not store thumbnail");
        }
        maybeTrim();
        return file.getPath();
    }

    private String full(Uri tree, String rel, String key, CancellationSignal signal) throws IOException {
        String name = safeKey(key) + extensionOf(rel);
        File file = new File(cacheDir("full"), name);
        if (file.length() > 0) {
            file.setLastModified(System.currentTimeMillis());
            return file.getPath();
        }
        File part = new File(file.getPath() + ".part" + Thread.currentThread().getId());
        Uri doc = documentUri(tree, rel);
        try (ParcelFileDescriptor pfd =
                     context.getContentResolver().openFileDescriptor(doc, "r", signal)) {
            if (pfd == null) throw new FileNotFoundException(rel);
            try (FileInputStream in = new FileInputStream(pfd.getFileDescriptor());
                 FileOutputStream out = new FileOutputStream(part)) {
                byte[] buffer = new byte[256 * 1024];
                int n;
                while ((n = in.read(buffer)) > 0) {
                    signal.throwIfCanceled();
                    out.write(buffer, 0, n);
                }
            }
            if (!part.renameTo(file) && !file.exists()) {
                throw new IOException("could not store picture");
            }
        } catch (IOException | RuntimeException e) {
            part.delete();
            if (e instanceof OperationCanceledException || e instanceof SecurityException
                    || e instanceof FileNotFoundException) {
                throw e;
            }
            throw new FileNotFoundException(e.getMessage());
        } finally {
            part.delete();
        }
        maybeTrim();
        return file.getPath();
    }

    private static String extensionOf(String rel) {
        int slash = rel.lastIndexOf('/');
        int dot = rel.lastIndexOf('.');
        if (dot <= slash) return "";
        String ext = rel.substring(dot).toLowerCase();
        return ext.matches("\\.[0-9a-z]{1,8}") ? ext : "";
    }

    private void maybeTrim() {
        if (writes.incrementAndGet() % TRIM_EVERY != 0) return;
        control.execute(() -> {
            trim(cacheDir("thumbs"), THUMB_CACHE_BYTES);
            trim(cacheDir("full"), FULL_CACHE_BYTES);
        });
    }

    /** Oldest-used files go first, down to 80% of the budget. */
    static void trim(File dir, long budget) {
        File[] files = dir.listFiles();
        if (files == null) return;
        long total = 0;
        final long[][] entries = new long[files.length][];
        for (int i = 0; i < files.length; i++) {
            long length = files[i].length();
            total += length;
            entries[i] = new long[]{files[i].lastModified(), length, i};
        }
        if (total <= budget) return;
        Arrays.sort(entries, Comparator.comparingLong(e -> e[0]));
        long goal = budget / 5 * 4;
        for (long[] e : entries) {
            if (total <= goal) break;
            if (files[(int) e[2]].delete()) total -= e[1];
        }
    }

    /** A detached descriptor for the video player. The caller closes it with closeFd. */
    private int openFd(Uri tree, String rel) throws IOException {
        ParcelFileDescriptor pfd =
                context.getContentResolver().openFileDescriptor(documentUri(tree, rel), "r");
        if (pfd == null) throw new FileNotFoundException(rel);
        return pfd.detachFd();
    }

    private static void closeFd(int fd) {
        try {
            ParcelFileDescriptor.adoptFd(fd).close();
        } catch (IOException ignored) {
            // already gone
        }
    }
}
