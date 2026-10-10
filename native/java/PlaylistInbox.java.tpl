package __PACKAGE__;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.Collections;

/**
 * Tiny web page served from the TV / phone so a playlist link can be typed on another device's keyboard.
 * Open http://<this device>:<port> on a phone or computer on the same Wi-Fi, paste the link, press Send.
 */
public class PlaylistInbox {

    public interface Listener { void onData(String data); }

    private static final String PAGE =
            "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
          + "<title>tv2u</title><style>body{font-family:sans-serif;background:#0b0f17;color:#eee;margin:0;padding:20px}"
          + "textarea{width:100%;height:9em;font-size:16px;padding:10px;box-sizing:border-box}"
          + "button{margin-top:12px;font-size:18px;padding:12px 22px;background:#2f9bff;color:#fff;border:0;border-radius:8px}</style></head>"
          + "<body><h2>Send a playlist to tv2u</h2><p>Paste a playlist link (http / https, m3u, m3u_plus, Xtream get.php) or the playlist text.</p>"
          + "<form method=post action=/send><textarea name=data autofocus placeholder='http://...'></textarea><br><button>Send to tv2u</button></form></body></html>";

    // One server for the whole app process: a second start() just reuses it (no "address already in use").
    private static ServerSocket server;
    private static volatile boolean running;
    private static volatile Listener current;

    public synchronized int start(int port, final Listener listener) throws Exception {
        current = listener;
        synchronized (PlaylistInbox.class) {
            if (server != null && !server.isClosed() && running) return server.getLocalPort();
            ServerSocket s = null;
            Exception last = null;
            // preferred port first, then the next few, and finally any free port
            for (int i = 0; i <= 12 && s == null; i++) {
                int tryPort = i <= 10 ? port + i : 0;
                try {
                    ServerSocket x = new ServerSocket();
                    x.setReuseAddress(true);
                    x.bind(new java.net.InetSocketAddress(tryPort));
                    s = x;
                } catch (Exception e) {
                    last = e;
                }
            }
            if (s == null) throw last != null ? last : new java.io.IOException("no free port");
            server = s;
            running = true;
            final ServerSocket ss = s;
            Thread t = new Thread(() -> {
                while (running && !ss.isClosed()) {
                    try {
                        final Socket c = ss.accept();
                        new Thread(() -> { Listener l = current; if (l != null) handle(c, l); else { try { c.close(); } catch (Exception ignored) { } } }, "tv2u-inbox-client").start();
                    } catch (Exception e) {
                        break;
                    }
                }
            }, "tv2u-inbox");
            t.setDaemon(true);
            t.start();
            return s.getLocalPort();
        }
    }

    public void stop() {
        // kept for API compatibility: the server stays up for the life of the app so "Send from phone" can be pressed again
    }

    public static synchronized void shutdown() {
        running = false;
        try { if (server != null) server.close(); } catch (Exception ignored) { }
        server = null;
    }

    private void handle(Socket c, Listener listener) {
        try {
            c.setSoTimeout(15000);
            InputStream in = c.getInputStream();
            ByteArrayOutputStream head = new ByteArrayOutputStream();
            int b, state = 0;
            while (head.size() < 16384 && (b = in.read()) >= 0) {
                head.write(b);
                state = (b == '\r' && (state == 0 || state == 2)) ? state + 1 : (b == '\n' && (state == 1 || state == 3)) ? state + 1 : 0;
                if (state == 4) break;
            }
            String h = new String(head.toByteArray(), StandardCharsets.ISO_8859_1);
            String first = h.split("\r\n", 2)[0];
            String reply;
            if (first.startsWith("POST")) {
                int len = 0;
                for (String line : h.split("\r\n")) {
                    if (line.toLowerCase().startsWith("content-length:")) len = Integer.parseInt(line.substring(15).trim());
                }
                len = Math.min(len, 8 * 1024 * 1024);
                byte[] body = new byte[len];
                int off = 0;
                while (off < len) {
                    int n = in.read(body, off, len - off);
                    if (n < 0) break;
                    off += n;
                }
                String form = new String(body, 0, off, StandardCharsets.UTF_8);
                String data = "";
                for (String kv : form.split("&")) {
                    if (kv.startsWith("data=")) data = URLDecoder.decode(kv.substring(5), "UTF-8");
                }
                data = data.trim();
                if (!data.isEmpty()) listener.onData(data);
                reply = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
                      + "<body style='font-family:sans-serif;background:#0b0f17;color:#eee;padding:20px'><h2>"
                      + (data.isEmpty() ? "Nothing was sent" : "Sent. Look at your TV.") + "</h2><a style=color:#7cc4ff href=/>Send another</a></body>";
            } else {
                reply = PAGE;
            }
            byte[] out = reply.getBytes(StandardCharsets.UTF_8);
            OutputStream os = c.getOutputStream();
            os.write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + out.length
                    + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.ISO_8859_1));
            os.write(out);
            os.flush();
        } catch (Exception ignored) {
        } finally {
            try { c.close(); } catch (Exception ignored) { }
        }
    }

    /** The device's Wi-Fi / LAN address, or null. */
    public static String localIp() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (InetAddress a : Collections.list(ni.getInetAddresses())) {
                    if (a instanceof Inet4Address && !a.isLoopbackAddress()) return a.getHostAddress();
                }
            }
        } catch (Exception ignored) { }
        return null;
    }
}
