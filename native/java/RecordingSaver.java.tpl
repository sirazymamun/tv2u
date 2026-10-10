package __PACKAGE__;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;

/**
 * Turns a captured MPEG-TS recording into a normal file and stores it on the device:
 *  - video:  MP4 (H.264 / H.265 + AAC sound). When the sound cannot live in an MP4 (MPEG audio L2, AC3 ...) the
 *            original .ts is kept so nothing is lost.
 *  - audio:  .mp3 when the stream's sound is MP3, .m4a for AAC (the usual case; Android has no MP3 encoder),
 *            .mp2 for MPEG audio L2, otherwise the original .ts.
 * Android 10+: saved through MediaStore into Movies/tv2u or Music/tv2u (no permission needed).
 * Older Android: saved in the app's own Movies / Music folder.
 */
final class RecordingSaver {

    static final class Result {
        String path = "";
        String note = "";
        String error = "";
    }

    private RecordingSaver() { }

    static Result save(Context ctx, File ts, boolean wantVideo, String baseName) {
        Result r = new Result();
        File work = null;
        try {
            if (ts == null || !ts.exists() || ts.length() < 4096) {
                r.error = "Nothing was recorded (the stream gave no data).";
                return r;
            }
            MediaExtractor ex = new MediaExtractor();
            int vIdx = -1, aIdx = -1;
            MediaFormat vf = null, af = null;
            String vMime = "", aMime = "";
            try {
                ex.setDataSource(ts.getAbsolutePath());
                for (int i = 0; i < ex.getTrackCount(); i++) {
                    MediaFormat f = ex.getTrackFormat(i);
                    String m = f.getString(MediaFormat.KEY_MIME);
                    if (m == null) continue;
                    if (vIdx < 0 && m.startsWith("video/")) { vIdx = i; vf = f; vMime = m; }
                    else if (aIdx < 0 && m.startsWith("audio/")) { aIdx = i; af = f; aMime = m; }
                }
            } catch (Throwable t) {
                ex.release();
                return keepOriginal(ctx, ts, wantVideo, baseName, r, "The recording could not be converted, so the original .ts file was saved.");
            }

            boolean video = wantVideo && vIdx >= 0;
            if (video) {
                boolean videoOk = "video/avc".equals(vMime) || "video/hevc".equals(vMime);
                boolean soundOk = aIdx < 0 || "audio/mp4a-latm".equals(aMime);
                if (!videoOk || !soundOk) {
                    ex.release();
                    return keepOriginal(ctx, ts, true, baseName, r,
                            "An MP4 file cannot hold this " + (!soundOk ? "sound (" + aMime + ")" : "picture (" + vMime + ")")
                                    + ", so the full original recording (picture + sound) was saved unchanged. VLC and most TVs play it.");
                }
                work = new File(ctx.getCacheDir(), "rec_out.mp4");
                if (!mux(ex, work, vIdx, vf, aIdx, af)) {
                    ex.release();
                    return keepOriginal(ctx, ts, true, baseName, r, "The recording could not be converted to MP4, so the original .ts file was saved.");
                }
                ex.release();
                r.path = publish(ctx, work, baseName + ".mp4", "video/mp4", true);
                return r;
            }

            // audio only
            if (aIdx < 0) {
                ex.release();
                r.error = "This recording has no sound track.";
                return r;
            }
            if ("audio/mpeg".equals(aMime) || "audio/mpeg-L2".equals(aMime)) {
                boolean mp3 = "audio/mpeg".equals(aMime);
                work = new File(ctx.getCacheDir(), "rec_out.audio");
                rawFrames(ex, aIdx, work);
                ex.release();
                r.path = publish(ctx, work, baseName + (mp3 ? ".mp3" : ".mp2"), "audio/mpeg", false);
                if (!mp3) r.note = "The channel's sound is MPEG audio Layer 2, saved as .mp2 (VLC and most players open it).";
                return r;
            }
            if ("audio/mp4a-latm".equals(aMime)) {
                work = new File(ctx.getCacheDir(), "rec_out.m4a");
                if (!mux(ex, work, -1, null, aIdx, af)) {
                    ex.release();
                    return keepOriginal(ctx, ts, wantVideo, baseName, r, "The sound could not be converted, so the original .ts file was saved.");
                }
                ex.release();
                r.path = publish(ctx, work, baseName + ".m4a", "audio/mp4", false);
                r.note = "The channel's sound is AAC, saved as .m4a (plays everywhere).";
                return r;
            }
            ex.release();
            return keepOriginal(ctx, ts, wantVideo, baseName, r, "This sound format (" + aMime + ") can't be extracted, so the original .ts file was saved.");
        } catch (Throwable t) {
            r.error = String.valueOf(t.getMessage() != null ? t.getMessage() : t);
            return r;
        } finally {
            if (work != null) work.delete();
        }
    }

    private static Result keepOriginal(Context ctx, File ts, boolean video, String base, Result r, String note) {
        try {
            String ext = ".ts", mime = "video/mp2t";
            try (java.io.FileInputStream in = new java.io.FileInputStream(ts)) {
                byte[] h = new byte[12];
                int n = in.read(h);
                if (n >= 8 && h[4] == 'f' && h[5] == 't' && h[6] == 'y' && h[7] == 'p') { ext = ".mp4"; mime = "video/mp4"; }
                else if (n >= 4 && (h[0] & 0xFF) == 0x1A && (h[1] & 0xFF) == 0x45 && (h[2] & 0xFF) == 0xDF && (h[3] & 0xFF) == 0xA3) { ext = ".mkv"; mime = "video/x-matroska"; }
            } catch (Throwable ignored) { }
            r.path = publish(ctx, ts, base + ext, mime, true);
            r.note = note;
        } catch (Throwable t) {
            r.error = String.valueOf(t.getMessage() != null ? t.getMessage() : t);
        }
        return r;
    }

    /** Copies the chosen tracks into an MP4 / M4A container (timestamps start at zero). */
    private static boolean mux(MediaExtractor ex, File out, int vIdx, MediaFormat vf, int aIdx, MediaFormat af) {
        MediaMuxer muxer = null;
        boolean started = false;
        try {
            if (out.exists()) out.delete();
            muxer = new MediaMuxer(out.getAbsolutePath(), MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            int[] map = new int[ex.getTrackCount()];
            java.util.Arrays.fill(map, -1);
            if (vIdx >= 0) { map[vIdx] = muxer.addTrack(vf); ex.selectTrack(vIdx); }
            if (aIdx >= 0) { map[aIdx] = muxer.addTrack(af); ex.selectTrack(aIdx); }
            muxer.start();
            started = true;
            ByteBuffer buf = ByteBuffer.allocate(4 * 1024 * 1024);
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            long base = -1;
            long written = 0;
            while (true) {
                buf.clear();
                int size = ex.readSampleData(buf, 0);
                if (size < 0) break;
                int ti = ex.getSampleTrackIndex();
                long t = ex.getSampleTime();
                if (base < 0) base = t;
                long pts = Math.max(0, t - base);
                int flags = (ex.getSampleFlags() & MediaExtractor.SAMPLE_FLAG_SYNC) != 0 ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0;
                info.set(0, size, pts, flags);
                if (ti >= 0 && ti < map.length && map[ti] >= 0) { muxer.writeSampleData(map[ti], buf, info); written++; }
                ex.advance();
            }
            muxer.stop();
            started = false;
            muxer.release();
            muxer = null;
            return written > 0 && out.length() > 1024;
        } catch (Throwable t) {
            return false;
        } finally {
            try { if (muxer != null) { if (started) muxer.stop(); muxer.release(); } } catch (Throwable ignored) { }
        }
    }

    /** Writes the sound frames one after another (valid for MP3 / MP2 streams). */
    private static void rawFrames(MediaExtractor ex, int aIdx, File out) throws IOException {
        ex.selectTrack(aIdx);
        ByteBuffer buf = ByteBuffer.allocate(256 * 1024);
        byte[] tmp = new byte[256 * 1024];
        try (OutputStream os = new FileOutputStream(out)) {
            while (true) {
                buf.clear();
                int size = ex.readSampleData(buf, 0);
                if (size < 0) break;
                buf.position(0);
                buf.get(tmp, 0, size);
                os.write(tmp, 0, size);
                ex.advance();
            }
        }
    }

    /** Stores the file in the device's Movies / Music folder; returns a readable location. */
    private static String publish(Context ctx, File src, String displayName, String mime, boolean video) throws IOException {
        String folder = video ? Environment.DIRECTORY_MOVIES : Environment.DIRECTORY_MUSIC;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ContentResolver cr = ctx.getContentResolver();
            boolean asVideo = mime.startsWith("video/");
            Uri collection = asVideo
                    ? MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    : MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY);
            String rel = (asVideo ? Environment.DIRECTORY_MOVIES : Environment.DIRECTORY_MUSIC) + "/tv2u";
            ContentValues v = new ContentValues();
            v.put(MediaStore.MediaColumns.DISPLAY_NAME, displayName);
            v.put(MediaStore.MediaColumns.MIME_TYPE, mime);
            v.put(MediaStore.MediaColumns.RELATIVE_PATH, rel);
            v.put(MediaStore.MediaColumns.IS_PENDING, 1);
            Uri uri = cr.insert(collection, v);
            if (uri == null) throw new IOException("The device refused to create the file.");
            try (InputStream in = new FileInputStream(src); OutputStream os = cr.openOutputStream(uri)) {
                if (os == null) throw new IOException("Could not open the new file.");
                copy(in, os);
            } catch (IOException e) {
                try { cr.delete(uri, null, null); } catch (Throwable ignored) { }
                throw e;
            }
            ContentValues done = new ContentValues();
            done.put(MediaStore.MediaColumns.IS_PENDING, 0);
            cr.update(uri, done, null, null);
            return rel + "/" + displayName;
        }
        File base = ctx.getExternalFilesDir(asFolder(mime, folder));
        if (base == null) base = new File(ctx.getFilesDir(), "recordings");
        File dir = new File(base, "tv2u");
        if (!dir.exists() && !dir.mkdirs()) throw new IOException("Could not create " + dir);
        File dst = new File(dir, displayName);
        try (InputStream in = new FileInputStream(src); OutputStream os = new FileOutputStream(dst)) {
            copy(in, os);
        }
        return dst.getAbsolutePath();
    }

    private static String asFolder(String mime, String fallback) {
        return mime.startsWith("video/") ? Environment.DIRECTORY_MOVIES : Environment.DIRECTORY_MUSIC;
    }

    private static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] b = new byte[64 * 1024];
        int n;
        while ((n = in.read(b)) > 0) out.write(b, 0, n);
    }
}
