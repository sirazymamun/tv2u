package __PACKAGE__;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.BufferedReader;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Disk-backed channel store for very large playlists (hundreds of MB).
 * The playlist is parsed as a stream and each channel is written to entries.dat; only a few bytes per channel
 * (offset, group, kind) stay in memory, so memory use does not grow with the size of the playlist.
 * Pure Java: no Android classes.
 */
public class BigStore {

    public interface Progress { void onEntries(long n); }

    public static class Item {
        public String name = "", logo = "", url = "", ua = "", ref = "", group = "";
    }

    public static class Page {
        public List<Item> items = new ArrayList<>();
        public long total;
    }

    public static class Group {
        public String key, label;
        public int count;
    }

    private static final String DAT = "entries.dat", IDX = "index.bin";

    private final File dir;
    private int n;
    private long[] offsets;
    private int[] gids;
    private byte[] kinds;
    private final List<String> groupNames = new ArrayList<>();
    private final Map<String, Integer> groupId = new HashMap<>();
    private int[] groupCount = new int[16];
    private final int[] kindCount = new int[3];

    private BigStore(File dir) { this.dir = dir; }

    /* ------------------------------------------------------------ build */

    public static BigStore build(File m3u, File dir, Progress progress) throws Exception {
        deleteDir(dir);
        if (!dir.mkdirs() && !dir.isDirectory()) throw new Exception("Cannot create storage folder");
        BigStore s = new BigStore(dir);
        s.offsets = new long[1 << 16];
        s.gids = new int[1 << 16];
        s.kinds = new byte[1 << 16];

        long pos = 0;
        try (BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(m3u), StandardCharsets.UTF_8), 1 << 16);
             DataOutputStream out = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(new File(dir, DAT)), 1 << 16))) {
            String line;
            String name = null, logo = "", group = "", pendingGroup = "", ua = "", ref = "";
            boolean haveInf = false;
            boolean first = true;
            while ((line = r.readLine()) != null) {
                if (first) { first = false; if (!line.isEmpty() && line.charAt(0) == '﻿') line = line.substring(1); }
                line = line.trim();
                if (line.isEmpty()) continue;
                if (line.regionMatches(true, 0, "#EXTINF", 0, 7)) {
                    String[] f = parseExtInf(line);
                    name = f[0]; logo = f[1]; group = f[2]; haveInf = true;
                    continue;
                }
                if (line.regionMatches(true, 0, "#EXTGRP:", 0, 8)) { pendingGroup = line.substring(8).trim(); continue; }
                if (line.regionMatches(true, 0, "#EXTVLCOPT:", 0, 11)) {
                    String v = line.substring(11).trim();
                    int eq = v.indexOf('=');
                    if (eq > 0) {
                        String k = v.substring(0, eq).trim().toLowerCase(Locale.ROOT);
                        String val = v.substring(eq + 1).trim();
                        if (k.equals("http-user-agent")) ua = val;
                        else if (k.equals("http-referrer") || k.equals("http-referer")) ref = val;
                    }
                    continue;
                }
                if (line.charAt(0) == '#') continue;

                String url = line;
                int pipe = url.indexOf('|');
                if (pipe > 0 && pipe + 1 < url.length() && url.substring(pipe + 1).matches("^[\\w-]+=.*")) {
                    for (String pair : url.substring(pipe + 1).split("&")) {
                        int eq = pair.indexOf('=');
                        if (eq <= 0) continue;
                        String k = pair.substring(0, eq).trim().toLowerCase(Locale.ROOT);
                        String val = pair.substring(eq + 1);
                        try { val = java.net.URLDecoder.decode(val, "UTF-8"); } catch (Exception ignored) { }
                        if (k.equals("user-agent")) ua = val; else if (k.equals("referer") || k.equals("referrer")) ref = val;
                    }
                    url = url.substring(0, pipe);
                }
                int sc = url.indexOf("://");
                if (sc < 1 || !url.substring(0, sc).matches("[A-Za-z][A-Za-z0-9+.-]*")) { haveInf = false; name = null; ua = ""; ref = ""; pendingGroup = ""; continue; }

                String g = haveInf ? group : "";
                if (g.isEmpty() && !pendingGroup.isEmpty()) g = pendingGroup;
                String nm = (haveInf && name != null && !name.isEmpty()) ? name : nameFromUrl(url);
                String lg = haveInf ? logo : "";

                int gid = s.groupIdFor(g);
                int kind = url.contains("/movie/") ? 1 : url.contains("/series/") ? 2 : 0;
                s.add(pos, gid, kind);
                pos += writeField(out, nm) + writeField(out, lg) + writeField(out, url) + writeField(out, ua) + writeField(out, ref);

                haveInf = false; name = null; logo = ""; group = ""; pendingGroup = ""; ua = ""; ref = "";
                if (progress != null && (s.n & 0x3FFF) == 0) progress.onEntries(s.n);
            }
        }
        if (s.n == 0) { deleteDir(dir); throw new Exception("No playable entries found in the playlist"); }
        if (progress != null) progress.onEntries(s.n);
        s.saveIndex();
        return s;
    }

    private static int writeField(DataOutputStream out, String v) throws Exception {
        byte[] b = v.getBytes(StandardCharsets.UTF_8);
        if (b.length > 60000) { b = Arrays.copyOf(b, 60000); }
        out.writeShort(b.length);
        out.write(b);
        return 2 + b.length;
    }

    private static String readField(DataInputStream in) throws Exception {
        int len = in.readUnsignedShort();
        byte[] b = new byte[len];
        in.readFully(b);
        return new String(b, StandardCharsets.UTF_8);
    }

    private static void skipField(DataInputStream in) throws Exception {
        int len = in.readUnsignedShort();
        int left = len;
        while (left > 0) { int k = in.skipBytes(left); if (k <= 0) { in.readByte(); k = 1; } left -= k; }
    }

    private int groupIdFor(String g) {
        Integer id = groupId.get(g);
        if (id == null) {
            id = groupNames.size();
            groupNames.add(g);
            groupId.put(g, id);
            if (id >= groupCount.length) groupCount = Arrays.copyOf(groupCount, groupCount.length * 2);
        }
        return id;
    }

    private void add(long off, int gid, int kind) {
        if (n == offsets.length) {
            int cap = n * 2;
            offsets = Arrays.copyOf(offsets, cap);
            gids = Arrays.copyOf(gids, cap);
            kinds = Arrays.copyOf(kinds, cap);
        }
        offsets[n] = off; gids[n] = gid; kinds[n] = (byte) kind;
        groupCount[gid]++;
        kindCount[kind]++;
        n++;
    }

    static String[] parseExtInf(String line) {
        String body = line.substring(line.indexOf(':') >= 0 ? line.indexOf(':') + 1 : line.length());
        String tvgName = "", logo = "", group = "";
        StringBuilder stripped = new StringBuilder();
        int i = 0, len = body.length();
        while (i < len) {
            // attribute  key="value"
            int eq = body.indexOf("=\"", i);
            if (eq < 0) { stripped.append(body, i, len); break; }
            int ks = eq;
            while (ks > i && isKeyChar(body.charAt(ks - 1))) ks--;
            int ve = body.indexOf('"', eq + 2);
            if (ve < 0) { stripped.append(body, i, len); break; }
            if (ks == eq) { stripped.append(body, i, eq + 2); i = eq + 2; continue; }
            stripped.append(body, i, ks);
            String key = body.substring(ks, eq).toLowerCase(Locale.ROOT);
            String val = body.substring(eq + 2, ve);
            if (key.equals("tvg-name")) tvgName = val;
            else if (key.equals("tvg-logo") || (key.equals("logo") && logo.isEmpty())) logo = val;
            else if (key.equals("group-title")) group = val;
            i = ve + 1;
        }
        int comma = stripped.indexOf(",");
        String name = comma >= 0 ? stripped.substring(comma + 1).trim() : "";
        if (name.isEmpty()) name = tvgName;
        return new String[]{name, logo, group};
    }

    private static boolean isKeyChar(char c) {
        return Character.isLetterOrDigit(c) || c == '_' || c == '.' || c == '-';
    }

    static String nameFromUrl(String url) {
        try {
            String p = new java.net.URL(url).getPath();
            String[] parts = p.split("/");
            for (int i = parts.length - 1; i >= 0; i--) if (!parts[i].isEmpty()) return java.net.URLDecoder.decode(parts[i], "UTF-8");
            return new java.net.URL(url).getHost();
        } catch (Exception e) {
            return url.length() > 60 ? url.substring(0, 60) : url;
        }
    }

    /* ------------------------------------------------------------ index file */

    private void saveIndex() throws Exception {
        try (DataOutputStream o = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(new File(dir, IDX)), 1 << 16))) {
            o.writeInt(n);
            o.writeInt(groupNames.size());
            for (String g : groupNames) { byte[] b = g.getBytes(StandardCharsets.UTF_8); o.writeShort(Math.min(b.length, 60000)); o.write(b, 0, Math.min(b.length, 60000)); }
            for (int i = 0; i < n; i++) { o.writeLong(offsets[i]); o.writeInt(gids[i]); o.writeByte(kinds[i]); }
        }
    }

    public static BigStore open(File dir) {
        File idx = new File(dir, IDX), dat = new File(dir, DAT);
        if (!idx.isFile() || !dat.isFile()) return null;
        try (DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(idx), 1 << 16))) {
            BigStore s = new BigStore(dir);
            int cnt = in.readInt();
            int groups = in.readInt();
            for (int g = 0; g < groups; g++) { String name = readField(in); s.groupIdFor(name); }
            s.offsets = new long[Math.max(cnt, 16)];
            s.gids = new int[Math.max(cnt, 16)];
            s.kinds = new byte[Math.max(cnt, 16)];
            for (int i = 0; i < cnt; i++) {
                long off = in.readLong(); int gid = in.readInt(); int kind = in.readByte();
                s.add(off, gid, kind);
            }
            return s;
        } catch (Exception e) {
            return null;
        }
    }

    /* ------------------------------------------------------------ info + query */

    public int total() { return n; }

    public List<Group> groups() {
        List<Group> list = new ArrayList<>();
        String[] kl = {"Live TV", "Movies", "Series"}, kk = {"k:live", "k:movie", "k:series"};
        int kindsWithData = 0;
        for (int k = 0; k < 3; k++) if (kindCount[k] > 0) kindsWithData++;
        if (kindsWithData > 1) {
            for (int k = 0; k < 3; k++) if (kindCount[k] > 0) { Group g = new Group(); g.key = kk[k]; g.label = "▸ " + kl[k]; g.count = kindCount[k]; list.add(g); }
        }
        for (int i = 0; i < groupNames.size(); i++) {
            Group g = new Group();
            String nm = groupNames.get(i);
            g.key = "g:" + nm;
            g.label = nm.isEmpty() ? "Ungrouped" : nm;
            g.count = groupCount[i];
            list.add(g);
        }
        return list;
    }

    private boolean matches(int i, String group, int gidWanted, int kindWanted) {
        if (kindWanted >= 0) return kinds[i] == kindWanted;
        if (gidWanted >= 0) return gids[i] == gidWanted;
        return group.equals("all") || group.equals("fav");
    }

    /** group: "all", "fav" (needs urls), "k:live|movie|series", "g:<name>". q: case-insensitive name/group filter. */
    public Page query(String group, String q, int offset, int limit, Set<String> urls) throws Exception {
        if (group == null) group = "all";
        int kindWanted = group.equals("k:live") ? 0 : group.equals("k:movie") ? 1 : group.equals("k:series") ? 2 : -1;
        int gidWanted = -1;
        if (group.startsWith("g:")) { Integer id = groupId.get(group.substring(2)); gidWanted = id == null ? Integer.MAX_VALUE : id; }
        boolean isFav = group.equals("fav");
        String needle = q == null ? "" : q.trim().toLowerCase(Locale.ROOT);
        Page page = new Page();

        if (needle.isEmpty() && !isFav) {
            // Fast path: positions come from the in-memory arrays, only the visible page is read from disk.
            long total = 0;
            List<Integer> wanted = new ArrayList<>();
            for (int i = 0; i < n; i++) {
                if (!matches(i, group, gidWanted, kindWanted)) continue;
                if (total >= offset && wanted.size() < limit) wanted.add(i);
                total++;
            }
            page.total = total;
            if (!wanted.isEmpty()) {
                try (FileInputStream fis = new FileInputStream(new File(dir, DAT))) {
                    for (int i : wanted) {
                        fis.getChannel().position(offsets[i]);
                        page.items.add(readItem(new DataInputStream(new BufferedInputStream(fis, 4096)), gids[i]));
                    }
                }
            }
            return page;
        }

        long total = 0;
        try (DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(new File(dir, DAT)), 1 << 16))) {
            for (int i = 0; i < n; i++) {
                if (!matches(i, group, gidWanted, kindWanted)) { for (int k = 0; k < 5; k++) skipField(in); continue; }
                Item it = readItem(in, gids[i]);
                if (isFav && (urls == null || !urls.contains(it.url))) continue;
                if (!needle.isEmpty() && !(it.name.toLowerCase(Locale.ROOT).contains(needle) || it.group.toLowerCase(Locale.ROOT).contains(needle))) continue;
                if (total >= offset && page.items.size() < limit) page.items.add(it);
                total++;
            }
        }
        page.total = total;
        return page;
    }

    private Item readItem(DataInputStream in, int gid) throws Exception {
        Item it = new Item();
        it.name = readField(in);
        it.logo = readField(in);
        it.url = readField(in);
        it.ua = readField(in);
        it.ref = readField(in);
        it.group = groupNames.get(gid);
        return it;
    }

    /* ------------------------------------------------------------ helpers */

    public static void deleteDir(File d) {
        File[] files = d.listFiles();
        if (files != null) for (File f : files) { if (f.isDirectory()) deleteDir(f); else f.delete(); }
        d.delete();
    }
}
