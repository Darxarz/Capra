package dev.goat.update;

import androidx.core.content.FileProvider;

/** A FileProvider of our own, so its manifest entry cannot collide with another plugin's. */
public class UpdateFileProvider extends FileProvider {
}
