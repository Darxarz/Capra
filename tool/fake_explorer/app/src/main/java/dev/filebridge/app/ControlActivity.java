package dev.filebridge.app;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

import java.io.IOException;

/** adb-only switch: {@code --es mode offline}, or {@code --ez open true} to press "Gallery". */
public class ControlActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        String mode = getIntent().getStringExtra("mode");
        if (mode != null) {
            Fixture.setMode(this, mode);
            Log.i("FakeExplorer", "mode=" + mode);
        }
        if (getIntent().getBooleanExtra("open", false)) {
            try {
                // exactly as the real Explorer: straight to the gallery's launcher activity
                Intent launch = getPackageManager().getLaunchIntentForPackage("com.example.goat");
                startActivity(ConnectActivity.handoff(this)
                        .setAction("dev.goat.action.OPEN_COLLECTION")
                        .setComponent(launch.getComponent())
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION));
            } catch (IOException e) {
                Log.e("FakeExplorer", "open failed", e);
            }
        }
        finish();
    }
}
