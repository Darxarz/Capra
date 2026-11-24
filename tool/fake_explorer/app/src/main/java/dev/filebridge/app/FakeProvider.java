package dev.filebridge.app;

import android.content.res.AssetFileDescriptor;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Point;
import android.media.MediaMetadataRetriever;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.ParcelFileDescriptor;
import android.os.ProxyFileDescriptorCallback;
import android.os.storage.StorageManager;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsContract.Root;
import android.provider.DocumentsProvider;
import android.system.ErrnoException;
import android.system.OsConstants;
import android.util.Log;
import android.webkit.MimeTypeMap;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.OutputStream;
import java.io.RandomAccessFile;

/**
 * Behaves like Explorer's BridgeProvider where the gallery can tell: same document ids, every
 * failure surfaces as FileNotFoundException, reads go through a seekable proxy descriptor and
 * thumbnails arrive through a pipe. Read-only.
 */
public class FakeProvider extends DocumentsProvider {
    private static final String TAG = "FakeExplorer";
    private static final String[] ROOTS = {Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE, Root.COLUMN_FLAGS, Root.COLUMN_ICON};
    private static final String[] DOCS = {Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS, Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED};

    @Override
    public boolean onCreate() {
        return true;
    }

    private void online() throws FileNotFoundException {
        if ("offline".equals(Fixture.mode(getContext()))) {
            throw new FileNotFoundException("offline");
        }
        // what the real PC answers once the collection has moved elsewhere
        if ("moved".equals(Fixture.mode(getContext()))) {
            throw new FileNotFoundException("вне коллекции");
        }
    }

    private File resolve(String documentId) throws FileNotFoundException {
        if (!documentId.equals(Fixture.TREE_ID) && !documentId.startsWith(Fixture.TREE_ID + "/")) {
            throw new FileNotFoundException(documentId);
        }
        String rel = documentId.substring(Fixture.TREE_ID.length());
        if (rel.contains("..")) throw new FileNotFoundException(documentId);
        if ("no_collection".equals(Fixture.mode(getContext())) && rel.contains("library-index")) {
            throw new FileNotFoundException("no index");
        }
        try {
            File f = new File(Fixture.library(getContext()), rel);
            if (!f.exists()) throw new FileNotFoundException(documentId);
            return f;
        } catch (FileNotFoundException e) {
            throw e;
        } catch (IOException e) {
            throw new FileNotFoundException(e.getMessage());
        }
    }

    @Override
    public Cursor queryRoots(String[] projection) {
        MatrixCursor c = new MatrixCursor(projection != null ? projection : ROOTS);
        c.newRow().add(Root.COLUMN_ROOT_ID, Fixture.SERVER)
                .add(Root.COLUMN_DOCUMENT_ID, Fixture.TREE_ID)
                .add(Root.COLUMN_TITLE, "Fake PC")
                .add(Root.COLUMN_FLAGS, Root.FLAG_SUPPORTS_IS_CHILD)
                .add(Root.COLUMN_ICON, android.R.drawable.ic_menu_gallery);
        return c;
    }

    private void addRow(MatrixCursor c, String id, File f) {
        String ext = MimeTypeMap.getFileExtensionFromUrl(Uri(f.getName()));
        String mime = f.isDirectory() ? Document.MIME_TYPE_DIR
                : MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext);
        c.newRow().add(Document.COLUMN_DOCUMENT_ID, id)
                .add(Document.COLUMN_DISPLAY_NAME, f.getName())
                .add(Document.COLUMN_MIME_TYPE, mime == null ? "application/octet-stream" : mime)
                .add(Document.COLUMN_FLAGS, f.isDirectory() ? 0 : Document.FLAG_SUPPORTS_THUMBNAIL)
                .add(Document.COLUMN_SIZE, f.isDirectory() ? null : f.length())
                .add(Document.COLUMN_LAST_MODIFIED, f.lastModified());
    }

    private static String Uri(String name) {
        return android.net.Uri.encode(name);
    }

    @Override
    public Cursor queryDocument(String documentId, String[] projection) throws FileNotFoundException {
        online();
        MatrixCursor c = new MatrixCursor(projection != null ? projection : DOCS);
        addRow(c, documentId, resolve(documentId));
        return c;
    }

    @Override
    public Cursor queryChildDocuments(String parent, String[] projection, String sortOrder)
            throws FileNotFoundException {
        online();
        MatrixCursor c = new MatrixCursor(projection != null ? projection : DOCS);
        File[] kids = resolve(parent).listFiles();
        if (kids != null) {
            for (File k : kids) {
                // like the real PC: the bookkeeping folder is reachable only by direct id
                if (k.getName().equals(".goat-archive-export")) continue;
                addRow(c, parent + "/" + k.getName(), k);
            }
        }
        return c;
    }

    @Override
    public boolean isChildDocument(String parent, String documentId) {
        return documentId.startsWith(parent + "/");
    }

    @Override
    public ParcelFileDescriptor openDocument(String documentId, String mode, CancellationSignal signal)
            throws FileNotFoundException {
        online();
        if (!"r".equals(mode)) throw new UnsupportedOperationException("read-only fixture");
        File file = resolve(documentId);
        final RandomAccessFile raf;
        try {
            raf = new RandomAccessFile(file, "r");
        } catch (IOException e) {
            throw new FileNotFoundException(e.getMessage());
        }
        Log.i(TAG, "open " + file.getName() + " size=" + file.length());
        HandlerThread thread = new HandlerThread("fixture-read");
        thread.start();
        ProxyFileDescriptorCallback cb = new ProxyFileDescriptorCallback() {
            long served;
            long firstOffset = -1;

            @Override
            public long onGetSize() {
                return file.length();
            }

            @Override
            public int onRead(long offset, int size, byte[] data) throws ErrnoException {
                if (firstOffset < 0) firstOffset = offset;
                // "fail_index": the link drops halfway through the index
                if ("fail_index".equals(Fixture.mode(getContext()))
                        && file.getName().startsWith("library-index")
                        && offset > file.length() / 2) {
                    throw new ErrnoException("read", OsConstants.EIO);
                }
                try {
                    raf.seek(offset);
                    int n = raf.read(data, 0, size);
                    served += Math.max(n, 0);
                    return Math.max(n, 0);
                } catch (IOException e) {
                    throw new ErrnoException("read", OsConstants.EIO);
                }
            }

            @Override
            public void onRelease() {
                Log.i(TAG, "release " + file.getName() + " servedBytes=" + served
                        + " of " + file.length() + " firstOffset=" + firstOffset);
                try {
                    raf.close();
                } catch (IOException ignored) {
                }
                thread.quitSafely();
            }
        };
        try {
            StorageManager storage = getContext().getSystemService(StorageManager.class);
            return storage.openProxyFileDescriptor(ParcelFileDescriptor.MODE_READ_ONLY, cb,
                    new Handler(thread.getLooper()));
        } catch (IOException e) {
            thread.quitSafely();
            throw new FileNotFoundException(e.getMessage());
        }
    }

    @Override
    public AssetFileDescriptor openDocumentThumbnail(String documentId, Point hint, CancellationSignal signal)
            throws FileNotFoundException {
        online();
        File file = resolve(documentId);
        byte[] bytes = thumbnail(file, Math.max(hint.x, hint.y));
        try {
            ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
            new Thread(() -> {
                try (OutputStream out = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                    out.write(bytes);
                } catch (IOException ignored) {
                    // the reader went away
                }
            }, "fixture-thumb").start();
            return new AssetFileDescriptor(pipe[0], 0, AssetFileDescriptor.UNKNOWN_LENGTH);
        } catch (IOException e) {
            throw new FileNotFoundException(e.getMessage());
        }
    }

    private static byte[] thumbnail(File file, int size) throws FileNotFoundException {
        Bitmap source;
        String name = file.getName().toLowerCase();
        if (name.endsWith(".mp4")) {
            MediaMetadataRetriever r = new MediaMetadataRetriever();
            try {
                r.setDataSource(file.getPath());
                source = r.getFrameAtTime(0);
            } finally {
                try {
                    r.release();
                } catch (IOException ignored) {
                }
            }
        } else {
            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inJustDecodeBounds = true;
            BitmapFactory.decodeFile(file.getPath(), o);
            o.inSampleSize = Math.max(1, Math.max(o.outWidth, o.outHeight) / Math.max(size, 1));
            o.inJustDecodeBounds = false;
            source = BitmapFactory.decodeFile(file.getPath(), o);
        }
        if (source == null) throw new FileNotFoundException("no preview");
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        source.compress(Bitmap.CompressFormat.JPEG, 85, out);
        source.recycle();
        return out.toByteArray();
    }
}
