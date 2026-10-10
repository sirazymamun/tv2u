package __PACKAGE__;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/** Plain-Java playlist / JSON download: follows http <-> https redirects, reports progress, decodes UTF-8. */
public class HttpFetch {

    public interface Progress { void onBytes(long total); }

    public static String get(String start, String ua, Progress progress) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream(1 << 20);
        stream(start, ua, out, progress);
        return new String(out.toByteArray(), StandardCharsets.UTF_8);
    }

    /** Download straight into a file (no size limit besides disk space). Returns the byte count. */
    public static long toFile(String start, String ua, java.io.File file, Progress progress) throws Exception {
        try (java.io.OutputStream os = new java.io.BufferedOutputStream(new java.io.FileOutputStream(file), 1 << 16)) {
            return stream(start, ua, os, progress);
        }
    }

    private static long stream(String start, String ua, java.io.OutputStream out, Progress progress) throws Exception {
        String cur = start;
        for (int hop = 0; hop < 8; hop++) {
            HttpURLConnection c = (HttpURLConnection) new URL(cur).openConnection();
            c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(20000);
            c.setReadTimeout(60000);
            c.setRequestProperty("User-Agent", ua);
            c.setRequestProperty("Accept", "*/*");
            c.setRequestProperty("Connection", "close");
            int code = c.getResponseCode();
            if (code >= 300 && code < 400) {
                String loc = c.getHeaderField("Location");
                c.disconnect();
                if (loc == null) throw new Exception("Redirect without address (HTTP " + code + ")");
                cur = new URL(new URL(cur), loc).toString();
                continue;
            }
            if (code >= 400) { c.disconnect(); throw new Exception("Server answered HTTP " + code); }
            InputStream in = c.getInputStream();
            byte[] buf = new byte[65536];
            int n;
            long total = 0, lastEmit = 0;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
                total += n;
                if (progress != null && total - lastEmit > 262144) {
                    lastEmit = total;
                    progress.onBytes(total);
                }
            }
            in.close();
            c.disconnect();
            return total;
        }
        throw new Exception("Too many redirects");
    }
}
