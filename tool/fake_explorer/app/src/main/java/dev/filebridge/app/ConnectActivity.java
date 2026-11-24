package dev.filebridge.app;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

import java.io.IOException;

/** The contract's CONNECT_COLLECTION, answering at once according to the fixture mode. */
public class ConnectActivity extends Activity {
    static final int GRANT = Intent.FLAG_GRANT_READ_URI_PERMISSION
            | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION;

    static Intent handoff(Activity a) throws IOException {
        return new Intent()
                .setData(Fixture.treeUri())
                .addFlags(GRANT)
                .putExtra("dev.goat.extra.COLLECTION_ID", Fixture.COLLECTION_ID)
                .putExtra("dev.goat.extra.COLLECTION_NAME", "Коллекция")
                .putExtra("dev.goat.extra.INDEX_VERSION", Fixture.indexVersion(a))
                .putExtra("dev.goat.extra.SERVER_NAME", "Fake PC");
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        String mode = Fixture.mode(this);
        String caller = getCallingPackage();
        if (!"com.example.goat".equals(caller)) {
            setResult(RESULT_CANCELED);
        } else if ("decline".equals(mode)) {
            setResult(RESULT_CANCELED);
        } else if (mode.equals("no_pc") || mode.equals("offline") || mode.equals("no_collection")) {
            setResult(RESULT_FIRST_USER, new Intent().putExtra("dev.goat.extra.ERROR", mode));
        } else {
            try {
                setResult(RESULT_OK, handoff(this));
            } catch (IOException e) {
                setResult(RESULT_FIRST_USER, new Intent().putExtra("dev.goat.extra.ERROR", "offline"));
            }
        }
        finish();
    }
}
