package dev.filebridge.app;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

/** Lets the gallery's "back to Explorer" button land somewhere visible. */
public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        TextView text = new TextView(this);
        text.setText("Fake Goat Explorer (test fixture)\nmode: " + Fixture.mode(this));
        text.setTextSize(22);
        setContentView(text);
    }
}
