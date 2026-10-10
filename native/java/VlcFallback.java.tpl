package __PACKAGE__;

import android.content.Context;
import android.net.Uri;
import android.view.ViewGroup;

import org.videolan.libvlc.LibVLC;
import org.videolan.libvlc.Media;
import org.videolan.libvlc.MediaPlayer;
import org.videolan.libvlc.util.VLCVideoLayout;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Map;

/**
 * Second player (VLC's engine). Used only when ExoPlayer cannot play a channel: VLC has its own software decoders
 * (HEVC / H.264 / MPEG-2 / AV1 ... in any container), and falls back to software by itself when the hardware cannot cope.
 * The picture is stretched to fill the whole screen, like the main player.
 */
final class VlcFallback {

    interface Listener {
        void onPlaying(boolean vod);
        void onBuffering();
        void onError();
        void onEnded();
        void onAudio(JSONArray tracks);
    }

    private final Context context;
    private final ViewGroup parent;
    private VLCVideoLayout layout;
    private LibVLC libVlc;
    private MediaPlayer mp;
    private boolean playing = false;

    VlcFallback(Context context, ViewGroup parent) {
        this.context = context;
        this.parent = parent;
    }

    boolean isActive() { return mp != null; }

    /** The VLC engine is created once and kept (starting it from scratch takes a noticeable moment). */
    private synchronized LibVLC lib() {
        if (libVlc == null) {
            ArrayList<String> args = new ArrayList<>();
            args.add("--no-drop-late-frames");      // keep every frame; slow software decoding just plays a little late
            args.add("--no-skip-frames");
            args.add("--avcodec-skiploopfilter=3"); // lighter software decoding of big pictures (4K), barely visible
            args.add("--avcodec-threads=0");        // use all CPU cores
            args.add("--network-caching=1000");     // short start-up delay
            args.add("--live-caching=1000");
            libVlc = new LibVLC(context, args);
        }
        return libVlc;
    }

    /** Loads the VLC engine in the background so a later switch from ExoPlayer is quick. */
    void prewarm() {
        new Thread(() -> { try { lib(); } catch (Throwable ignored) { } }, "tv2u-vlc-warm").start();
    }

    /** App is closing: free the engine for good. */
    synchronized void shutdown() {
        release();
        try { if (libVlc != null) libVlc.release(); } catch (Throwable ignored) { }
        libVlc = null;
    }

    void start(String url, String userAgent, Map<String, String> headers, final Listener listener) {
        release();
        libVlc = lib();
        mp = new MediaPlayer(libVlc);

        layout = new VLCVideoLayout(context);
        layout.setFocusable(false);
        layout.setFocusableInTouchMode(false);
        layout.setKeepScreenOn(true);
        parent.addView(layout, 0, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        mp.attachViews(layout, null, false, false);
        mp.setVideoScale(MediaPlayer.ScaleType.SURFACE_FILL);

        mp.setEventListener(new MediaPlayer.EventListener() {
            @Override
            public void onEvent(MediaPlayer.Event event) {
                if (mp == null) return;
                switch (event.type) {
                    case MediaPlayer.Event.Buffering:
                        if (event.getBuffering() >= 100f) {
                            markPlaying(listener);
                        } else if (!playing) {
                            listener.onBuffering();
                        }
                        break;
                    case MediaPlayer.Event.Playing:
                        markPlaying(listener);
                        break;
                    case MediaPlayer.Event.EncounteredError:
                        listener.onError();
                        break;
                    case MediaPlayer.Event.EndReached:
                        listener.onEnded();
                        break;
                    default:
                        break;
                }
            }
        });

        Media media = new Media(libVlc, Uri.parse(url));
        media.setHWDecoderEnabled(true, false); // hardware when it works, software automatically when it does not
        if (userAgent != null && !userAgent.isEmpty()) media.addOption(":http-user-agent=" + userAgent);
        if (headers != null) {
            for (Map.Entry<String, String> e : headers.entrySet()) {
                String k = e.getKey();
                if ("referer".equalsIgnoreCase(k) || "referrer".equalsIgnoreCase(k)) media.addOption(":http-referrer=" + e.getValue());
            }
        }
        media.addOption(":http-reconnect");
        mp.setMedia(media);
        media.release();
        playing = false;
        mp.play();
    }

    private void markPlaying(Listener listener) {
        if (playing) return;
        playing = true;
        listener.onPlaying(isVod());
        listener.onAudio(audioTracks());
    }

    /** Audio tracks of the current channel: {id, lang, label, channels, selected, supported}. */
    JSONArray audioTracks() {
        JSONArray arr = new JSONArray();
        try {
            if (mp == null) return arr;
            MediaPlayer.TrackDescription[] list = mp.getAudioTracks();
            int cur = mp.getAudioTrack();
            if (list == null) return arr;
            for (MediaPlayer.TrackDescription td : list) {
                if (td.id < 0) continue; // -1 is "no audio"
                JSONObject o = new JSONObject();
                o.put("id", td.id);
                o.put("lang", "");
                o.put("label", td.name == null ? "" : td.name);
                o.put("channels", 0);
                o.put("selected", td.id == cur);
                o.put("supported", true);
                arr.put(o);
            }
        } catch (Throwable ignored) { }
        return arr;
    }

    /** Records what is being played (original container, usually .ts) into a folder. Uses reflection so the build never depends on it. */
    boolean startRecord(String directory) {
        try {
            if (mp == null) return false;
            Object r = mp.getClass().getMethod("record", String.class).invoke(mp, directory);
            return !(r instanceof Boolean) || (Boolean) r;
        } catch (Throwable t) { return false; }
    }

    void stopRecord() {
        try { if (mp != null) mp.getClass().getMethod("record", String.class).invoke(mp, (Object) null); } catch (Throwable ignored) { }
    }

    boolean setAudio(int id) {
        try { return mp != null && mp.setAudioTrack(id); } catch (Throwable t) { return false; }
    }

    private boolean isVod() {
        try { return mp != null && mp.isSeekable() && mp.getLength() > 60000; } catch (Throwable t) { return false; }
    }

    /** Returns {position seconds, duration seconds} or null when not seekable. */
    long[] seekBy(long ms) {
        if (mp == null || !isVod()) return null;
        long dur = mp.getLength();
        long target = Math.max(0, mp.getTime() + ms);
        if (dur > 0 && target > dur - 1000) target = dur - 1000;
        mp.setTime(target);
        return new long[]{target / 1000, dur > 0 ? dur / 1000 : 0};
    }

    void pause() { try { if (mp != null) mp.pause(); } catch (Throwable ignored) { } }
    void resume() { try { if (mp != null) mp.play(); } catch (Throwable ignored) { } }

    String describe() {
        StringBuilder sb = new StringBuilder("Player: VLC engine (fallback)");
        try {
            if (mp != null) {
                Object vt = mp.getCurrentVideoTrack();
                if (vt != null) {
                    int w = vt.getClass().getField("width").getInt(vt);
                    int h = vt.getClass().getField("height").getInt(vt);
                    if (w > 0 && h > 0) sb.append("\nPicture: ").append(w).append("x").append(h);
                }
                sb.append("\nPlayed: ").append(mp.getTime() / 1000).append(" s");
            }
        } catch (Throwable ignored) { }
        return sb.toString();
    }

    void release() {
        playing = false;
        try { if (mp != null) { mp.setEventListener(null); mp.stop(); mp.detachViews(); mp.release(); } } catch (Throwable ignored) { }
        try { if (layout != null) parent.removeView(layout); } catch (Throwable ignored) { }
        mp = null;
        layout = null;
    }
}
