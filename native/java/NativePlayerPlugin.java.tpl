package __PACKAGE__;

import android.content.SharedPreferences;
import android.graphics.Color;
import android.os.Handler;
import android.os.Looper;
import android.view.ViewGroup;
import android.webkit.WebView;

import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.TrackSelectionOverride;
import androidx.media3.common.Tracks;
import androidx.media3.datasource.DataSink;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.TeeDataSource;
import androidx.media3.datasource.okhttp.OkHttpDataSource;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy;
import androidx.media3.extractor.DefaultExtractorsFactory;
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory;
import androidx.media3.ui.AspectRatioFrameLayout;
import androidx.media3.ui.PlayerView;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.io.File;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.Iterator;
import java.util.Map;

/**
 * Full-screen native video player (Media3 ExoPlayer) drawn BEHIND the transparent web view.
 * It plays HLS (.m3u8), raw MPEG-TS (.ts / mpegts), MP4/MKV, RTSP and DASH over http and https,
 * follows redirects (including http <-> https) and sends custom headers from the playlist.
 * No on-screen controller is ever shown.
 *
 * Robustness: slow-starting streams get long timeouts, a refused request (HTTP 401/403/406) is retried
 * with other User-Agents, failing decoders fall back to other decoders, and the plugin reports exactly
 * which video / audio formats a channel uses and whether this device can decode them.
 */
@CapacitorPlugin(name = "NativePlayer")
public class NativePlayerPlugin extends Plugin {

    private static final String[] USER_AGENTS = {
            "VLC/3.0.18 LibVLC/3.0.18",
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36",
            "Lavf/60.16.100",
            "okhttp/4.12.0"
    };
    private static final long STALL_MS = 10000; // no picture after this long: hand the channel to the VLC engine

    private PlayerView playerView;
    private ExoPlayer player;
    private final Handler main = new Handler(Looper.getMainLooper());

    private String tracksSummary = "";
    private String videoDecoder = "";
    private String lastError = "";
    private boolean videoUnsupported = false;
    private boolean audioUnsupported = false;
    private String videoMime = "";
    private String audioMime = "";

    private final Runnable stallWatchdog = new Runnable() {
        @Override
        public void run() {
            if (player != null && player.getPlaybackState() != Player.STATE_READY) {
                String msg = "No picture after " + (STALL_MS / 1000) + " seconds. ";
                if (tracksSummary.isEmpty()) {
                    msg += "No video or audio was found in the stream yet (the server may be slow, refusing the connection, or the stream is in an unsupported format).";
                } else {
                    msg += tracksSummary;
                }
                if (tryVlc(msg)) return;
                lastError = msg;
                emit("error", msg);
            }
        }
    };

    @Override
    public void load() {
        installCrashRecorder();
        getActivity().runOnUiThread(() -> {
            WebView web = getBridge().getWebView();
            ViewGroup parent = (ViewGroup) web.getParent();
            parent.setBackgroundColor(Color.BLACK);
            web.setBackgroundColor(Color.TRANSPARENT);

            playerView = new PlayerView(getActivity());
            playerView.setUseController(false);
            playerView.setKeepScreenOn(true);
            playerView.setFocusable(false);
            playerView.setFocusableInTouchMode(false);
            playerView.setShowBuffering(PlayerView.SHOW_BUFFERING_NEVER);
            playerView.setShutterBackgroundColor(Color.BLACK);
            playerView.setResizeMode(AspectRatioFrameLayout.RESIZE_MODE_FILL);
            videoParent = parent;
            try { vlc = new VlcFallback(getActivity(), parent); vlc.prewarm(); } catch (Throwable ignored) { }
            parent.addView(playerView, 0, new ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            web.requestFocus();
        });
    }

    @PluginMethod
    public void play(PluginCall call) {
        final String url = call.getString("url");
        if (url == null || url.isEmpty()) {
            call.reject("No URL");
            return;
        }
        final Map<String, String> headers = new HashMap<>();
        JSObject h = call.getObject("headers");
        if (h != null) {
            Iterator<String> keys = h.keys();
            while (keys.hasNext()) {
                String k = keys.next();
                String v = h.optString(k, "");
                if (!v.isEmpty()) headers.put(k, v);
            }
        }
        getActivity().runOnUiThread(() -> {
            vlcTriedUrl = "";
            videoVariants = 0;
            if (!url.equals(curUrl)) clearAudioOverride();
            startPlayback(url, headers, false, 0);
            call.resolve();
        });
    }

    @PluginMethod
    public void stop(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            stopVlc();
            stopPlayback();
            call.resolve();
        });
    }

    /** Movies / series episodes: jump forward or back (seconds). Live channels ignore it. */
    @PluginMethod
    public void seekBy(PluginCall call) {
        final long ms = (long) (call.getDouble("seconds", 10.0) * 1000);
        getActivity().runOnUiThread(() -> {
            if (vlcActive && vlc != null) {
                long[] r = vlc.seekBy(ms);
                if (r != null) {
                    JSObject o = new JSObject();
                    o.put("position", r[0]);
                    o.put("duration", r[1]);
                    call.resolve(o);
                } else call.resolve();
                return;
            }
            if (player != null && player.isCurrentMediaItemSeekable() && !player.isCurrentMediaItemLive()) {
                long target = Math.max(0, player.getCurrentPosition() + ms);
                long dur = player.getDuration();
                if (dur > 0 && target > dur - 1000) target = dur - 1000;
                player.seekTo(target);
                JSObject r = new JSObject();
                r.put("position", target / 1000);
                r.put("duration", dur > 0 ? dur / 1000 : 0);
                call.resolve(r);
            } else {
                call.resolve();
            }
        });
    }

    @PluginMethod
    public void setResizeMode(PluginCall call) {
        final String mode = call.getString("mode", "fit");
        getActivity().runOnUiThread(() -> {
            if (playerView != null) {
                int m = AspectRatioFrameLayout.RESIZE_MODE_FIT;
                if ("zoom".equals(mode)) m = AspectRatioFrameLayout.RESIZE_MODE_ZOOM;
                else if ("fill".equals(mode)) m = AspectRatioFrameLayout.RESIZE_MODE_FILL;
                playerView.setResizeMode(m);
            }
            call.resolve();
        });
    }

    /** Technical details of the current channel, for the "Info" button. */
    /* ---------- breadcrumbs: remember where the app stopped, even after a crash ---------- */
    private SharedPreferences crumbPrefs() {
        return getContext().getSharedPreferences("tv2u_trace", android.content.Context.MODE_PRIVATE);
    }

    private void writeCrumb(String text) {
        try { crumbPrefs().edit().putString("text", text).commit(); } catch (Throwable ignored) { }
    }

    private void installCrashRecorder() {
        final Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((thread, throwable) -> {
            try {
                StringBuilder sb = new StringBuilder("CRASH in " + thread.getName() + ": " + throwable);
                StackTraceElement[] st = throwable.getStackTrace();
                for (int i = 0; i < st.length && i < 4; i++) sb.append(" | ").append(st[i]);
                writeCrumb(sb.toString());
            } catch (Throwable ignored) { }
            if (previous != null) previous.uncaughtException(thread, throwable);
        });
    }

    @PluginMethod
    public void crumb(PluginCall call) {
        writeCrumb(call.getString("text", ""));
        call.resolve();
    }

    @PluginMethod
    public void lastCrumb(PluginCall call) {
        JSObject r = new JSObject();
        r.put("text", crumbPrefs().getString("text", ""));
        call.resolve(r);
    }

    /* ------------------------------------------------------------------
     * Native playlist download (big Xtream / XUI playlists, player-like User-Agents,
     * http <-> https redirects, progress, delivered to the page in small chunks).
     * ------------------------------------------------------------------ */
    private final Map<String, String> downloads = new ConcurrentHashMap<>();
    private int downloadSeq = 0;

    private static final long BIG_BYTES = 6L * 1024 * 1024;
    private BigStore bigStore;

    private File bigDir() { return new File(getContext().getFilesDir(), "bigstore"); }

    @PluginMethod
    public void fetchStart(final PluginCall call) {
        final String url = call.getString("url");
        final boolean json = "json".equals(call.getString("kind", "playlist"));
        final List<String> uas = new ArrayList<>();
        try {
            org.json.JSONArray arr = call.getData().optJSONArray("userAgents");
            if (arr != null) for (int i = 0; i < arr.length(); i++) uas.add(arr.getString(i));
        } catch (Exception ignored) { }
        if (uas.isEmpty()) uas.add("VLC/3.0.18 LibVLC/3.0.18");
        if (url == null || url.isEmpty()) { call.reject("No URL"); return; }
        new Thread(() -> {
          File tmp = new File(getContext().getCacheDir(), "tv2u_download.tmp");
          try {
            writeCrumb("Downloading " + url.replaceAll("(?i)(password=)[^&]*", "$1***"));
            String lastErr = "no answer";
            for (String ua : uas) {
                try {
                    long size = HttpFetch.toFile(url, ua, tmp, bytes -> {
                        JSObject p = new JSObject();
                        p.put("bytes", bytes);
                        notifyListeners("fetchProgress", p);
                    });
                    String head = readHead(tmp);
                    if (size == 0 || head.isEmpty()) { lastErr = "Server sent an empty reply (account expired, too many connections, or blocked)"; continue; }
                    if (!json && (head.regionMatches(true, 0, "<!doctype", 0, 9) || head.regionMatches(true, 0, "<html", 0, 5))) {
                        lastErr = "Server sent a web page instead of the data: " + head.replaceAll("<[^>]+>", " ").replaceAll("\\s+", " ").trim();
                        if (lastErr.length() > 160) lastErr = lastErr.substring(0, 160);
                        continue;
                    }
                    JSObject r = new JSObject();
                    r.put("userAgent", ua);
                    if (!json && size > BIG_BYTES) {
                        writeCrumb("Downloaded " + (size / 1048576) + " MB, building the channel database");
                        bigStore = null;
                        BigStore st = BigStore.build(tmp, bigDir(), n -> {
                            JSObject p = new JSObject();
                            p.put("entries", n);
                            notifyListeners("fetchProgress", p);
                        });
                        bigStore = st;
                        r.put("big", true);
                        putBigInfo(r, st);
                    } else {
                        String body = readAll(tmp);
                        String id = "d" + (++downloadSeq);
                        downloads.put(id, body);
                        r.put("id", id);
                        r.put("length", body.length());
                        writeCrumb("Downloaded " + body.length() + " characters, now reading the channels");
                    }
                    call.resolve(r);
                    return;
                } catch (java.net.UnknownHostException | java.net.ConnectException | java.net.SocketTimeoutException e) {
                    boolean connectProblem = !(e instanceof java.net.SocketTimeoutException) || String.valueOf(e.getMessage()).toLowerCase().contains("connect");
                    lastErr = e.getClass().getSimpleName() + (e.getMessage() != null ? ": " + e.getMessage() : "");
                    if (connectProblem) break;
                } catch (Exception e) {
                    lastErr = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
                }
            }
            call.reject(lastErr);
          } catch (Throwable t) {
            call.reject("Download failed: " + t);
          } finally {
            tmp.delete();
          }
        }, "tv2u-download").start();
    }

    private static String readAll(File f) throws Exception {
        try (java.io.FileInputStream in = new java.io.FileInputStream(f)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream((int) Math.min(f.length() + 16, 16L << 20));
            byte[] b = new byte[65536];
            int n;
            while ((n = in.read(b)) > 0) out.write(b, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static String readHead(File f) {
        try (java.io.FileInputStream in = new java.io.FileInputStream(f)) {
            byte[] b = new byte[4096];
            int n = in.read(b);
            return n <= 0 ? "" : new String(b, 0, n, StandardCharsets.UTF_8).trim();
        } catch (Exception e) {
            return "";
        }
    }

    private void putBigInfo(JSObject r, BigStore st) throws Exception {
        r.put("total", st.total());
        org.json.JSONArray arr = new org.json.JSONArray();
        for (BigStore.Group g : st.groups()) {
            JSObject o = new JSObject();
            o.put("key", g.key);
            o.put("label", g.label);
            o.put("count", g.count);
            arr.put(o);
        }
        r.put("groups", arr);
    }

    /** Re-open the channel database from the last big playlist (after the app was restarted). */
    @PluginMethod
    public void bigOpen(PluginCall call) {
        new Thread(() -> {
            try {
                if (bigStore == null) bigStore = BigStore.open(bigDir());
                JSObject r = new JSObject();
                if (bigStore == null) { r.put("total", 0); call.resolve(r); return; }
                putBigInfo(r, bigStore);
                call.resolve(r);
            } catch (Throwable t) {
                call.reject("Could not open the saved playlist: " + t);
            }
        }, "tv2u-bigopen").start();
    }

    @PluginMethod
    public void bigQuery(final PluginCall call) {
        final BigStore st = bigStore;
        if (st == null) { call.reject("The big playlist is not loaded"); return; }
        final String group = call.getString("group", "all");
        final String q = call.getString("q", "");
        final int offset = call.getInt("offset", 0);
        final int limit = call.getInt("limit", 500);
        final Set<String> urls = new HashSet<>();
        try {
            org.json.JSONArray arr = call.getData().optJSONArray("urls");
            if (arr != null) for (int i = 0; i < arr.length(); i++) urls.add(arr.getString(i));
        } catch (Exception ignored) { }
        new Thread(() -> {
            try {
                BigStore.Page page = st.query(group, q, offset, limit, urls);
                org.json.JSONArray arr = new org.json.JSONArray();
                for (BigStore.Item it : page.items) {
                    JSObject o = new JSObject();
                    o.put("name", it.name);
                    o.put("logo", it.logo);
                    o.put("group", it.group);
                    o.put("url", it.url);
                    if (!it.ua.isEmpty() || !it.ref.isEmpty()) {
                        JSObject h = new JSObject();
                        if (!it.ua.isEmpty()) h.put("User-Agent", it.ua);
                        if (!it.ref.isEmpty()) h.put("Referer", it.ref);
                        o.put("headers", h);
                    }
                    arr.put(o);
                }
                JSObject r = new JSObject();
                r.put("items", arr);
                r.put("total", page.total);
                call.resolve(r);
            } catch (Throwable t) {
                call.reject("Search failed: " + t);
            }
        }, "tv2u-bigquery").start();
    }

    @PluginMethod
    public void bigClear(PluginCall call) {
        bigStore = null;
        BigStore.deleteDir(bigDir());
        call.resolve();
    }

    @PluginMethod
    public void fetchRead(PluginCall call) {
        String id = call.getString("id");
        String text = id == null ? null : downloads.get(id);
        if (text == null) { call.reject("Download expired"); return; }
        int offset = call.getInt("offset", 0);
        int length = call.getInt("length", 400000);
        int end = Math.min(text.length(), offset + length);
        JSObject r = new JSObject();
        r.put("text", offset >= text.length() ? "" : text.substring(offset, end));
        r.put("done", end >= text.length());
        call.resolve(r);
    }

    @PluginMethod
    public void fetchDone(PluginCall call) {
        String id = call.getString("id");
        if (id != null) downloads.remove(id);
        call.resolve();
    }

    /* ---------- "send from phone" inbox + TV detection ---------- */
    private PlaylistInbox inbox;

    @PluginMethod
    public void inboxStart(PluginCall call) {
        try {
            if (inbox == null) inbox = new PlaylistInbox();
            int port = inbox.start(8686, data -> {
                JSObject o = new JSObject();
                o.put("data", data);
                notifyListeners("inbox", o);
            });
            String ip = PlaylistInbox.localIp();
            JSObject r = new JSObject();
            r.put("url", ip == null ? "" : "http://" + ip + ":" + port);
            call.resolve(r);
        } catch (Throwable t) {
            call.reject("Could not start: " + t);
        }
    }

    @PluginMethod
    public void inboxStop(PluginCall call) {
        if (inbox != null) inbox.stop();
        call.resolve();
    }

    @PluginMethod
    public void isTv(PluginCall call) {
        android.app.UiModeManager um = (android.app.UiModeManager) getContext().getSystemService(android.content.Context.UI_MODE_SERVICE);
        JSObject r = new JSObject();
        r.put("tv", um != null && um.getCurrentModeType() == android.content.res.Configuration.UI_MODE_TYPE_TELEVISION);
        call.resolve(r);
    }

    @PluginMethod
    public void info(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            StringBuilder sb = new StringBuilder();
            if (vlcActive && vlc != null) {
                sb.append(vlc.describe());
            } else if (player == null) {
                sb.append("Nothing is playing.");
            } else {
                sb.append("State: ").append(stateName(player.getPlaybackState()));
                Format vf = player.getVideoFormat();
                Format af = player.getAudioFormat();
                sb.append("\nPicture: ").append(vf == null ? "none is being shown" : describeFormat(vf));
                sb.append("\nSound: ").append(af == null ? "none is being played" : describeFormat(af));
                if (!videoDecoder.isEmpty()) sb.append("\nPicture decoder: ").append(videoDecoder);
                androidx.media3.exoplayer.DecoderCounters dc = player.getVideoDecoderCounters();
                if (dc != null) {
                    dc.ensureUpdated();
                    sb.append("\nFrames shown: ").append(dc.renderedOutputBufferCount).append(", dropped: ").append(dc.droppedBufferCount);
                }
                long bps = androidx.media3.exoplayer.upstream.DefaultBandwidthMeter.getSingletonInstance(getContext()).getBitrateEstimate();
                if (bps > 0) sb.append("\nConnection speed: about ").append(String.format(java.util.Locale.US, "%.1f", bps / 1000000.0)).append(" Mbit/s");
                sb.append("\nBuffered ahead: ").append(String.format(java.util.Locale.US, "%.1f", player.getTotalBufferedDuration() / 1000.0)).append(" s");
                if (!tracksSummary.isEmpty()) sb.append("\nStream contains: ").append(tracksSummary);
            }
            if (!lastError.isEmpty()) sb.append("\nLast problem: ").append(lastError);
            JSObject o = new JSObject();
            o.put("text", sb.toString());
            call.resolve(o);
        });
    }

    /** Must run on the main thread. */
    // The request being played right now (the shared listener reads these when it has to retry).
    private String curUrl = "";
    private Map<String, String> curHeaders = new HashMap<>();
    private boolean curForceHls = false;
    private int curUaIndex = 0;
    private boolean curUaFixed = false;
    private DefaultTrackSelector trackSelector;
    private boolean strictTracks = false;
    private int videoVariants = 0;

    /* ---------- recording ---------- */
    /** Receives a copy of the downloaded stream while a recording is running; ignores playlists / text. */
    private static final class RecordSink implements DataSink {
        private java.io.OutputStream out;
        private boolean first, accept;
        private long bytes;

        synchronized void begin(File f) throws java.io.IOException {
            out = new java.io.BufferedOutputStream(new java.io.FileOutputStream(f), 1 << 16);
            bytes = 0;
        }
        synchronized long end() throws java.io.IOException {
            java.io.OutputStream o = out;
            out = null;
            if (o != null) { o.flush(); o.close(); }
            return bytes;
        }
        synchronized boolean active() { return out != null; }
        @Override public synchronized void open(DataSpec dataSpec) { first = true; accept = false; }
        @Override public synchronized void write(byte[] buffer, int offset, int length) throws java.io.IOException {
            if (out == null || length <= 0) return;
            if (first) {
                first = false;
                int c = buffer[offset] & 0xFF;
                accept = !(c == 0x23 || c == 0x3C || c == 0x7B || c == 0xEF || c == 0x20 || c == 0x0D || c == 0x0A || c == 0x09); // any media (TS, MP4, audio...), but not text such as #EXTM3U playlists, xml or json
            }
            if (accept) { out.write(buffer, offset, length); bytes += length; }
        }
        @Override public void close() { }
    }

    private final RecordSink recSink = new RecordSink();
    private boolean recording = false, recViaVlc = false, recVideo = true;
    private String recName = "channel";
    private File recFile, recDir;
    private long recStartMs;

    @PluginMethod
    public void recordStart(final PluginCall call) {
        final String mode = "video"; // always picture + sound together
        final String name = call.getString("name", "channel");
        getActivity().runOnUiThread(() -> {
            if (recording) { call.reject("Already recording."); return; }
            boolean playingNow = vlcActive || (player != null && player.getPlaybackState() != Player.STATE_IDLE);
            if (curUrl.isEmpty() || !playingNow) { call.reject("Nothing is playing yet."); return; }
            try {
                File dir = new File(getContext().getCacheDir(), "rec");
                dir.mkdirs();
                File[] old = dir.listFiles();
                if (old != null) for (File f : old) f.delete();
                recVideo = "video".equals(mode);
                recName = name;
                recDir = dir;
                recStartMs = System.currentTimeMillis();
                if (vlcActive && vlc != null) {
                    if (!vlc.startRecord(dir.getAbsolutePath())) { call.reject("Recording is not possible with this player for this channel."); return; }
                    recViaVlc = true;
                    recFile = null;
                } else {
                    recFile = new File(dir, "rec_" + recStartMs + ".ts");
                    recSink.begin(recFile);
                    recViaVlc = false;
                }
                recording = true;
                call.resolve();
            } catch (Throwable t) {
                call.reject("Could not start recording: " + t);
            }
        });
    }

    @PluginMethod
    public void recordStop(final PluginCall call) {
        getActivity().runOnUiThread(() -> {
            if (!recording) { call.resolve(new JSObject()); return; }
            recording = false;
            File ts = recFile;
            try {
                if (recViaVlc) {
                    if (vlc != null) vlc.stopRecord();
                    ts = newestIn(recDir, recStartMs);
                } else {
                    recSink.end();
                }
            } catch (Throwable ignored) { }
            final File captured = ts;
            final boolean video = recVideo;
            // dd-MM-yy_HH-mm, e.g. 10-10-26_04-20 (Android does not allow ":" in file names)
            final String base = new java.text.SimpleDateFormat("dd-MM-yy_HH-mm", java.util.Locale.getDefault()).format(new java.util.Date(recStartMs));
            new Thread(() -> {
                RecordingSaver.Result r = RecordingSaver.save(getContext(), captured, video, base);
                try { if (captured != null) captured.delete(); } catch (Throwable ignored) { }
                JSObject o = new JSObject();
                o.put("path", r.path);
                o.put("note", r.note);
                o.put("error", r.error);
                call.resolve(o);
            }, "tv2u-save").start();
        });
    }

    private static File newestIn(File dir, long sinceMs) {
        File best = null;
        File[] list = dir == null ? null : dir.listFiles();
        if (list == null) return null;
        for (File f : list) {
            if (f.isFile() && f.lastModified() >= sinceMs - 2000 && (best == null || f.lastModified() > best.lastModified())) best = f;
        }
        return best;
    }

    private static String safeName(String s) {
        String t = (s == null ? "channel" : s).replaceAll("[^A-Za-z0-9._-]+", "_").replaceAll("^_+|_+$", "");
        if (t.isEmpty()) t = "channel";
        return t.length() > 40 ? t.substring(0, 40) : t;
    }

    /* ---------- audio tracks (languages): reported to the page, chosen from its wizard ---------- */
    private final List<Tracks.Group> audioGroups = new ArrayList<>();
    private final List<Integer> audioIdx = new ArrayList<>();

    /** Lists every audio track of the current channel: {id, lang, label, channels, selected, supported}. */
    private org.json.JSONArray buildAudioList(Tracks tracks) {
        audioGroups.clear();
        audioIdx.clear();
        org.json.JSONArray arr = new org.json.JSONArray();
        for (Tracks.Group g : tracks.getGroups()) {
            if (g.getType() != C.TRACK_TYPE_AUDIO) continue;
            for (int i = 0; i < g.length; i++) {
                Format f = g.getTrackFormat(i);
                audioGroups.add(g);
                audioIdx.add(i);
                JSObject o = new JSObject();
                o.put("id", audioGroups.size() - 1);
                o.put("lang", f.language == null ? "" : f.language);
                o.put("label", f.label == null ? "" : f.label);
                o.put("channels", f.channelCount);
                o.put("selected", g.isTrackSelected(i));
                o.put("supported", g.isTrackSupported(i));
                arr.put(o);
            }
        }
        return arr;
    }

    private void emitAudioList(org.json.JSONArray list) {
        JSObject o = new JSObject();
        o.put("tracks", list);
        notifyListeners("audioTracks", o);
    }

    private boolean selectExoAudio(int id) {
        if (trackSelector == null || id < 0 || id >= audioGroups.size()) return false;
        Tracks.Group g = audioGroups.get(id);
        int ti = audioIdx.get(id);
        trackSelector.setParameters(trackSelector.buildUponParameters()
                .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
                .setOverrideForType(new TrackSelectionOverride(g.getMediaTrackGroup(), ti)));
        return true;
    }

    private void clearAudioOverride() {
        if (trackSelector == null) return;
        trackSelector.setParameters(trackSelector.buildUponParameters().clearOverridesOfType(C.TRACK_TYPE_AUDIO));
    }

    /** The page's wizard chose an audio track (id from the list it received). */
    @PluginMethod
    public void setAudioTrack(PluginCall call) {
        final int id = call.getInt("id", -1);
        getActivity().runOnUiThread(() -> {
            boolean ok = (vlcActive && vlc != null) ? vlc.setAudio(id) : selectExoAudio(id);
            JSObject r = new JSObject();
            r.put("ok", ok);
            call.resolve(r);
        });
    }

    /* ---------- VLC engine: second player when ExoPlayer cannot play a channel ---------- */
    private VlcFallback vlc;
    private boolean vlcActive = false;
    private String vlcTriedUrl = "";
    private ViewGroup videoParent;

    private boolean tryVlc(String why) {
        if (videoParent == null || curUrl.isEmpty() || curUrl.equals(vlcTriedUrl)) return false;
        vlcTriedUrl = curUrl;
        try {
            if (vlc == null) vlc = new VlcFallback(getContext(), videoParent);
            if (player != null) { player.stop(); player.clearMediaItems(); }
            main.removeCallbacks(stallWatchdog);
            if (playerView != null) playerView.setVisibility(android.view.View.GONE);
            vlcActive = true;
            lastError = "ExoPlayer: " + why;
            String ua = USER_AGENTS[0];
            for (Map.Entry<String, String> e : curHeaders.entrySet()) if ("user-agent".equalsIgnoreCase(e.getKey())) ua = e.getValue();
            emit("buffering", null);
            vlc.start(curUrl, ua, curHeaders, new VlcFallback.Listener() {
                @Override public void onAudio(org.json.JSONArray tracks) { emitAudioList(tracks); }
                @Override public void onPlaying(boolean vod) {
                    JSObject o = new JSObject();
                    o.put("state", "playing");
                    o.put("vod", vod);
                    notifyListeners("state", o);
                }
                @Override public void onBuffering() { emit("buffering", null); }
                @Override public void onError() {
                    String msg = "Neither player could play this channel. " + lastError;
                    lastError = msg;
                    emit("error", msg);
                }
                @Override public void onEnded() { emit("ended", null); }
            });
            return true;
        } catch (Throwable t) {
            vlcActive = false;
            if (playerView != null) playerView.setVisibility(android.view.View.VISIBLE);
            lastError = why + " | VLC could not start: " + t;
            return false;
        }
    }

    private void stopVlc() {
        if (vlc != null && vlcActive) vlc.release();
        vlcActive = false;
        if (playerView != null) playerView.setVisibility(android.view.View.VISIBLE);
    }

    /** Strict: never pick a picture/sound track this device cannot decode (plays the rest, e.g. sound only for 4K HEVC on a weak box). */
    private void setStrictTracks(boolean strict) {
        strictTracks = strict;
        if (trackSelector == null) return;
        trackSelector.setParameters(trackSelector.buildUponParameters()
                .setExceedRendererCapabilitiesIfNecessary(!strict)
                .setExceedVideoConstraintsIfNecessary(!strict));
    }

    private void startPlayback(final String url, final Map<String, String> headers, final boolean forceHls, final int uaIndex) {
        if (playerView == null) return;
        stopVlc();
        tracksSummary = "";
        lastError = "";
        videoUnsupported = false;
        audioUnsupported = false;
        videoMime = "";
        audioMime = "";
        videoDecoder = "";

        String ua = USER_AGENTS[Math.min(uaIndex, USER_AGENTS.length - 1)];
        boolean uaFromPlaylist = false;
        Map<String, String> props = new HashMap<>();
        for (Map.Entry<String, String> e : headers.entrySet()) {
            if ("user-agent".equalsIgnoreCase(e.getKey())) {
                ua = e.getValue();
                uaFromPlaylist = true;
            } else {
                props.put(e.getKey(), e.getValue());
            }
        }
        curUrl = url;
        curHeaders = headers;
        curForceHls = forceHls;
        curUaIndex = uaIndex;
        curUaFixed = uaFromPlaylist;

        // OkHttp is faster and steadier than the built-in HTTP stack (connection reuse, HTTP/2, http <-> https redirects).
        okhttp3.OkHttpClient client = new okhttp3.OkHttpClient.Builder()
                .connectTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
                .readTimeout(40, java.util.concurrent.TimeUnit.SECONDS)
                .followRedirects(true)
                .followSslRedirects(true)
                .retryOnConnectionFailure(true)
                .build();
        OkHttpDataSource.Factory http = new OkHttpDataSource.Factory(client)
                .setUserAgent(ua)
                .setDefaultRequestProperties(props);

        // Live MPEG-TS often lacks clean keyframe markers; these flags make it start reliably.
        DefaultExtractorsFactory extractors = new DefaultExtractorsFactory()
                .setTsExtractorFlags(DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES
                        | DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS);

        // While recording, every byte that is downloaded for playback is also written to the recording file
        // (no second connection to the server).
        final DataSource.Factory baseFactory = new DefaultDataSource.Factory(getContext(), http);
        final DataSource.Factory teeFactory = () -> new TeeDataSource(baseFactory.createDataSource(), recSink);
        DefaultMediaSourceFactory sources = new DefaultMediaSourceFactory(teeFactory, extractors)
                .setLoadErrorHandlingPolicy(new DefaultLoadErrorHandlingPolicy(3));

        // One player is kept for the whole session: changing channel only swaps the media (much faster than rebuilding).
        final ExoPlayer exo = ensurePlayer();
        MediaItem.Builder item = new MediaItem.Builder().setUri(url);
        if (forceHls) item.setMimeType(MimeTypes.APPLICATION_M3U8);
        setStrictTracks(false); // every new channel first tries everything the stream offers
        exo.setMediaSource(sources.createMediaSource(item.build()), true);
        exo.setPlayWhenReady(true);
        exo.prepare();
        main.removeCallbacks(stallWatchdog);
        main.postDelayed(stallWatchdog, STALL_MS);
    }

    private ExoPlayer ensurePlayer() {
        if (player != null) return player;

        // If a decoder fails to start, try the next one; use extension decoders (e.g. FFmpeg) when present.
        DefaultRenderersFactory renderers = new DefaultRenderersFactory(getContext())
                .setEnableDecoderFallback(true)
                .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON);

        // Start playing after a very short buffer so channel changes feel instant.
        DefaultLoadControl loadControl = new DefaultLoadControl.Builder()
                // Starts quickly (0.8 s) but keeps a healthy cushion (up to 50 s) so Full HD / 4K streams do not stutter.
                .setBufferDurationsMs(15000, 50000, 800, 3000)
                .setTargetBufferBytes(48 * 1024 * 1024)
                .setPrioritizeTimeOverSizeThresholds(false)
                .build();

        trackSelector = new DefaultTrackSelector(getContext());
        final ExoPlayer exo = new ExoPlayer.Builder(getContext(), renderers)
                .setTrackSelector(trackSelector)
                .setLoadControl(loadControl)
                .build();
        player = exo;

        exo.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(), true);

        exo.addListener(new Player.Listener() {
            @Override
            public void onTracksChanged(Tracks tracks) {
                if (exo != player) return;
                summariseTracks(tracks);
                // The device can't decode the sound (e.g. MPEG audio Layer 2 on Fire TV): VLC decodes it in software.
                if ((audioUnsupported || videoUnsupported) && !vlcActive) {
                    final String why = "This device can't decode the " + (videoUnsupported ? "picture (" + videoMime : "sound (" + audioMime) + ")";
                    main.post(() -> tryVlc(why));
                    return;
                }
                emitAudioList(buildAudioList(tracks));
            }

            @Override
            public void onPlaybackStateChanged(int state) {
                if (exo != player) return;
                if (state == Player.STATE_BUFFERING) {
                    emit("buffering", null);
                } else if (state == Player.STATE_READY) {
                    main.removeCallbacks(stallWatchdog);
                    JSObject playing = new JSObject();
                    playing.put("state", "playing");
                    playing.put("vod", exo.isCurrentMediaItemSeekable() && !exo.isCurrentMediaItemLive() && exo.getDuration() > 60000);
                    notifyListeners("state", playing);
                    if (videoUnsupported) {
                        emit("warning", "This device can't decode the picture (" + videoMime + "), so you only hear sound.");
                    } else if (audioUnsupported) {
                        emit("warning", "This device can't decode the sound (" + audioMime + "), so the picture has no sound.");
                    }
                } else if (state == Player.STATE_ENDED) {
                    emit("ended", null);
                }
            }

            @Override
            public void onPlayerError(PlaybackException error) {
                if (exo != player) return; // stale player
                final String url = curUrl;
                final Map<String, String> headers = curHeaders;
                final boolean forceHls = curForceHls;
                final int uaIndex = curUaIndex;
                if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
                    exo.seekToDefaultPosition();
                    exo.prepare();
                    return;
                }
                // The picture (e.g. 4K HEVC) can't be decoded by this device: retry once, skipping tracks it can't handle,
                // so HLS streams switch to a smaller picture and single 4K streams still play their sound.
                if (!strictTracks && videoVariants > 1 && (error.errorCode == PlaybackException.ERROR_CODE_DECODING_FAILED
                        || error.errorCode == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED
                        || error.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES)) {
                    setStrictTracks(true);
                    exo.prepare();
                    return;
                }
                // Extension-less URLs that are really HLS playlists: retry once as HLS.
                if (!forceHls && error.errorCode == PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED) {
                    main.post(() -> startPlayback(url, headers, true, uaIndex));
                    return;
                }
                // The server refused us: some servers only accept certain player User-Agents.
                int code = httpStatusOf(error);
                if (!curUaFixed && (code == 401 || code == 403 || code == 406) && uaIndex + 1 < USER_AGENTS.length) {
                    main.post(() -> startPlayback(url, headers, forceHls, uaIndex + 1));
                    return;
                }
                String msg = describeError(error);
                if (tryVlc(msg)) return;
                lastError = msg;
                emit("error", msg);
            }
        });

        exo.addAnalyticsListener(new androidx.media3.exoplayer.analytics.AnalyticsListener() {
            @Override
            public void onVideoDecoderInitialized(androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime eventTime,
                                                  String decoderName, long initializedTimestampMs, long initializationDurationMs) {
                videoDecoder = decoderName;
                String n = decoderName.toLowerCase();
                boolean software = n.startsWith("omx.google") || n.startsWith("c2.android") || n.contains("sw") || n.contains("ffmpeg");
                // (no on-screen message: the decoder name is shown in Info)
            }
        });

        playerView.setKeepContentOnPlayerReset(true);
        playerView.setPlayer(exo);
        return exo;
    }

    /** Stop playing but keep the player ready for the next channel. */
    private void stopPlayback() {
        main.removeCallbacks(stallWatchdog);
        if (player != null) {
            player.stop();
            player.clearMediaItems();
        }
    }

    private void releasePlayer() {
        main.removeCallbacks(stallWatchdog);
        if (playerView != null) playerView.setPlayer(null);
        if (player != null) {
            player.release();
            player = null;
        }
    }

    private void summariseTracks(Tracks tracks) {
        StringBuilder sb = new StringBuilder();
        videoUnsupported = false;
        audioUnsupported = false;
        boolean anyAudio = false, anyAudioOk = false;
        for (Tracks.Group g : tracks.getGroups()) {
            int type = g.getType();
            if ((type != C.TRACK_TYPE_VIDEO && type != C.TRACK_TYPE_AUDIO) || g.length == 0) continue;
            Format f = g.getTrackFormat(0);
            boolean ok = g.isSupported();
            if (sb.length() > 0) sb.append("; ");
            sb.append(type == C.TRACK_TYPE_VIDEO ? "video " : "audio ").append(describeFormat(f));
            sb.append(ok ? " (ok)" : " (NOT SUPPORTED on this device)");
            if (type == C.TRACK_TYPE_VIDEO) {
                videoVariants = Math.max(videoVariants, g.length);
                videoMime = String.valueOf(f.sampleMimeType);
                if (!ok) videoUnsupported = true;
            } else {
                audioMime = String.valueOf(f.sampleMimeType);
                anyAudio = true;
                if (ok) anyAudioOk = true;
            }
        }
        audioUnsupported = anyAudio && !anyAudioOk;
        tracksSummary = sb.toString();
    }

    private static String describeFormat(Format f) {
        StringBuilder sb = new StringBuilder(String.valueOf(f.sampleMimeType));
        if (f.width > 0 && f.height > 0) sb.append(' ').append(f.width).append('x').append(f.height);
        if (f.channelCount > 0) sb.append(' ').append(f.channelCount).append("ch");
        if (f.sampleRate > 0) sb.append(' ').append(f.sampleRate).append("Hz");
        return sb.toString();
    }

    private static int httpStatusOf(Throwable t) {
        int depth = 0;
        while (t != null && depth < 6) {
            if (t instanceof HttpDataSource.InvalidResponseCodeException) {
                return ((HttpDataSource.InvalidResponseCodeException) t).responseCode;
            }
            t = t.getCause();
            depth++;
        }
        return 0;
    }

    private String describeError(PlaybackException error) {
        StringBuilder sb = new StringBuilder(error.getErrorCodeName());
        int code = httpStatusOf(error);
        if (code != 0) sb.append(" | server answered HTTP ").append(code);
        Throwable c = error.getCause();
        int depth = 0;
        while (c != null && depth < 3) {
            String m = c.getMessage();
            if (m != null && !m.isEmpty() && !(code != 0 && m.contains(String.valueOf(code)))) sb.append(" | ").append(m);
            c = c.getCause();
            depth++;
        }
        if (!tracksSummary.isEmpty()) sb.append(" | ").append(tracksSummary);
        return sb.toString();
    }

    private static String stateName(int s) {
        switch (s) {
            case Player.STATE_IDLE: return "idle";
            case Player.STATE_BUFFERING: return "loading";
            case Player.STATE_READY: return "playing";
            case Player.STATE_ENDED: return "ended";
            default: return String.valueOf(s);
        }
    }

    private void emit(String state, String message) {
        JSObject o = new JSObject();
        o.put("state", state);
        if (message != null) o.put("message", message);
        notifyListeners("state", o);
    }

    @Override
    protected void handleOnPause() {
        if (player != null) player.pause();
        if (vlcActive && vlc != null) vlc.pause();
        super.handleOnPause();
    }

    @Override
    protected void handleOnResume() {
        super.handleOnResume();
        if (vlcActive && vlc != null) vlc.resume();
        else if (player != null) player.play();
    }

    @Override
    protected void handleOnDestroy() {
        if (vlc != null) vlc.shutdown();
        releasePlayer();
        super.handleOnDestroy();
    }
}
