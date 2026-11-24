package dev.goat.update;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.content.pm.SigningInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.core.content.FileProvider;

import java.io.File;
import java.io.IOException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * Hands GOAT's own update to the system installer. The APK is downloaded by the Dart side into
 * files/goat_update/; this class only shares that one folder through a FileProvider and opens the
 * standard install screen. Android itself checks that the update carries the same signing key and
 * a version code that is not lower, and asks the owner to confirm. Nothing here works around that.
 */
public class GoatUpdatePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler,
        ActivityAware, PluginRegistry.ActivityResultListener {

    private static final String TAG = "GoatUpdate";
    private static final String DIR = "goat_update";
    private static final int REQUEST_SETTINGS = 0x60B1;
    private static final int REQUEST_INSTALL = 0x60B2;
    private static final String APK_TYPE = "application/vnd.android.package-archive";

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();

    private MethodChannel channel;
    private Context context;
    private ActivityPluginBinding binding;
    private MethodChannel.Result settingsResult;
    private MethodChannel.Result installResult;

    // ---------- plugin lifecycle ----------

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutter) {
        context = flutter.getApplicationContext();
        channel = new MethodChannel(flutter.getBinaryMessenger(), "dev.goat.update");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding flutter) {
        channel.setMethodCallHandler(null);
        channel = null;
        worker.shutdown();
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding b) {
        binding = b;
        b.addActivityResultListener(this);
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
        if (binding != null) binding.removeActivityResultListener(this);
        binding = null;
    }

    // ---------- calls ----------

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "updateDir":
                result.success(updateDir().getAbsolutePath());
                break;
            case "freeSpace":
                result.success(updateDir().getUsableSpace());
                break;
            case "canInstall":
                result.success(canInstall());
                break;
            case "openInstallSettings":
                openInstallSettings(result);
                break;
            case "inspect":
                inspect(call.argument("path"), result);
                break;
            case "install":
                install(call.argument("path"), result);
                break;
            default:
                result.notImplemented();
        }
    }

    private File updateDir() {
        File dir = new File(context.getFilesDir(), DIR);
        if (!dir.isDirectory() && !dir.mkdirs()) Log.w(TAG, "could not create " + dir);
        return dir;
    }

    /** "Install unknown apps" for GOAT. Before Android 8 this is one global switch the installer asks about itself. */
    private boolean canInstall() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true;
        return context.getPackageManager().canRequestPackageInstalls();
    }

    /** Opens GOAT's own "install unknown apps" page and answers once the owner comes back. */
    private void openInstallSettings(MethodChannel.Result result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || canInstall()) {
            result.success(true);
            return;
        }
        Activity activity = binding == null ? null : binding.getActivity();
        if (activity == null) {
            result.error("no_activity", "no activity", null);
            return;
        }
        if (settingsResult != null) settingsResult.success(canInstall());
        settingsResult = result;
        Intent intent = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:" + context.getPackageName()));
        try {
            activity.startActivityForResult(intent, REQUEST_SETTINGS);
        } catch (ActivityNotFoundException e) {
            settingsResult = null;
            result.error("no_settings", "settings page not available", null);
        }
    }

    /** Only files GOAT itself downloaded may go to the installer. */
    private File ownFile(String path) throws IOException {
        if (path == null) throw new IOException("no path");
        File file = new File(path).getCanonicalFile();
        String root = updateDir().getCanonicalPath() + File.separator;
        if (!file.getPath().startsWith(root) || !file.isFile()) throw new IOException("not an update file");
        return file;
    }

    /**
     * What the downloaded file is, so the app can say plainly why Android would refuse it instead
     * of showing the installer's generic "app not installed". The installer checks again anyway.
     */
    private void inspect(String path, MethodChannel.Result result) {
        worker.execute(() -> {
            Map<String, Object> out = new HashMap<>();
            String error = null;
            try {
                File file = ownFile(path);
                PackageManager pm = context.getPackageManager();
                int flags = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                        ? PackageManager.GET_SIGNING_CERTIFICATES : PackageManager.GET_SIGNATURES;
                PackageInfo archive = pm.getPackageArchiveInfo(file.getPath(), flags);
                PackageInfo installed = pm.getPackageInfo(context.getPackageName(), flags);
                if (archive == null) {
                    out.put("readable", false);
                } else {
                    out.put("readable", true);
                    out.put("package", archive.packageName);
                    out.put("ownPackage", context.getPackageName());
                    out.put("versionCode", versionCode(archive));
                    out.put("installedVersionCode", versionCode(installed));
                    Boolean same = sameSigner(archive, installed);
                    if (same != null) out.put("sameSigner", same);
                }
            } catch (IOException | PackageManager.NameNotFoundException | RuntimeException e) {
                error = e.toString();
            }
            final String failure = error;
            main.post(() -> {
                if (failure != null) result.error("inspect_failed", failure, null);
                else result.success(out);
            });
        });
    }

    private static long versionCode(PackageInfo info) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) return info.getLongVersionCode();
        return info.versionCode;
    }

    /** null when Android does not tell; then only the installer decides. */
    private static Boolean sameSigner(PackageInfo archive, PackageInfo installed) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            SigningInfo a = archive.signingInfo;
            SigningInfo b = installed.signingInfo;
            if (a == null || b == null) return null;
            Signature[] now = b.hasMultipleSigners() ? b.getApkContentsSigners() : b.getSigningCertificateHistory();
            if (now == null || now.length == 0) return null;
            if (a.hasMultipleSigners() || b.hasMultipleSigners()) {
                Signature[] next = a.getApkContentsSigners();
                return next != null && sameSet(next, b.getApkContentsSigners());
            }
            // a rotated key still counts when the new lineage includes the key installed now
            Signature current = now[now.length - 1];
            Signature[] lineage = a.getSigningCertificateHistory();
            if (lineage == null || lineage.length == 0) return null;
            for (Signature s : lineage) {
                if (s.equals(current)) return true;
            }
            return false;
        }
        if (archive.signatures == null || installed.signatures == null) return null;
        return sameSet(archive.signatures, installed.signatures);
    }

    private static boolean sameSet(Signature[] a, Signature[] b) {
        if (a == null || b == null || a.length != b.length) return false;
        String[] x = new String[a.length];
        String[] y = new String[b.length];
        for (int i = 0; i < a.length; i++) {
            x[i] = a[i].toCharsString();
            y[i] = b[i].toCharsString();
        }
        Arrays.sort(x);
        Arrays.sort(y);
        return Arrays.equals(x, y);
    }

    /** Opens the system install screen for the downloaded APK and reports how it ended. */
    private void install(String path, MethodChannel.Result result) {
        Activity activity = binding == null ? null : binding.getActivity();
        if (activity == null) {
            result.error("no_activity", "no activity", null);
            return;
        }
        Uri uri;
        try {
            File file = ownFile(path);
            uri = FileProvider.getUriForFile(context, context.getPackageName() + ".goat_update.files", file);
        } catch (IOException | IllegalArgumentException e) {
            result.error("bad_file", e.toString(), null);
            return;
        }
        if (installResult != null) installResult.success("canceled");
        installResult = result;
        Intent intent = new Intent(Intent.ACTION_INSTALL_PACKAGE);
        intent.setDataAndType(uri, APK_TYPE);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        intent.putExtra(Intent.EXTRA_RETURN_RESULT, true);
        try {
            activity.startActivityForResult(intent, REQUEST_INSTALL);
            Log.i(TAG, "installer opened for " + uri);
        } catch (ActivityNotFoundException e) {
            // very old or unusual system: the plain viewer intent reaches the same installer
            installResult = null;
            Intent view = new Intent(Intent.ACTION_VIEW);
            view.setDataAndType(uri, APK_TYPE);
            view.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
            try {
                activity.startActivity(view);
                result.success("opened");
            } catch (ActivityNotFoundException e2) {
                result.error("no_installer", "no installer", null);
            }
        }
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == REQUEST_SETTINGS) {
            MethodChannel.Result result = settingsResult;
            settingsResult = null;
            if (result != null) result.success(canInstall());
            return true;
        }
        if (requestCode == REQUEST_INSTALL) {
            MethodChannel.Result result = installResult;
            installResult = null;
            if (result == null) return true;
            // On success the system replaces this app and ends its process, so "ok" is rarely seen.
            if (resultCode == Activity.RESULT_OK) {
                result.success("ok");
            } else if (resultCode == Activity.RESULT_CANCELED) {
                result.success("canceled");
            } else {
                int code = data == null ? 0 : data.getIntExtra("android.intent.extra.INSTALL_RESULT", 0);
                Log.w(TAG, "installer finished with " + resultCode + ", install result " + code);
                result.success("failed:" + code);
            }
            return true;
        }
        return false;
    }
}
