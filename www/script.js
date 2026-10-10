/* tv2u — full-screen IPTV player UI.
 * On Android the video is drawn by a native ExoPlayer behind this transparent page (see native/).
 * In a normal browser it falls back to an HTML5 <video> (+ hls.js) so the UI can still be tested.
 */
(function (root) {
  "use strict";

  const DEFAULT_UA = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36";
  const HLS_CDN = "https://cdn.jsdelivr.net/npm/hls.js@1/dist/hls.min.js";

  /* =====================================================================
   * Parsing (pure functions)
   * ===================================================================== */
  const SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;
  const MEDIA_FILE_RE = /\.(mp4|m4v|mkv|webm|mov|avi|flv|mp3|aac|m4a|ogg|opus|wav|ts|mts|m2ts)(\?|#|$)/i;
  const HLS_URL_RE = /\.m3u8?(\?|#|$)/i;
  const UNSUPPORTED_RE = /^(rtmp|rtmps|rtmpe|mms|mmsh|srt):/i;

  function parseExtInf(line) {
    const body = line.replace(/^#EXTINF:/i, "");
    const attrs = {};
    const re = /([\w.-]+)="([^"]*)"/g;
    let m;
    while ((m = re.exec(body))) attrs[m[1].toLowerCase()] = m[2];
    const stripped = body.replace(/([\w.-]+)="[^"]*"/g, "");
    const comma = stripped.indexOf(",");
    const name = comma >= 0 ? stripped.slice(comma + 1).trim() : "";
    return {
      name: name || attrs["tvg-name"] || "",
      logo: attrs["tvg-logo"] || attrs["logo"] || "",
      group: attrs["group-title"] || "",
    };
  }

  function nameFromUrl(url) {
    try {
      const u = new URL(url);
      const last = decodeURIComponent(u.pathname.split("/").filter(Boolean).pop() || "");
      return last || u.hostname;
    } catch (e) {
      return String(url).slice(0, 60);
    }
  }

  /** "User-Agent=Foo&Referer=http%3A%2F%2Fx" -> { "User-Agent": "Foo", Referer: "http://x" } */
  function parseHeaderString(s) {
    const out = {};
    String(s).split("&").forEach((pair) => {
      const i = pair.indexOf("=");
      if (i <= 0) return;
      const k = pair.slice(0, i).trim();
      const raw = pair.slice(i + 1);
      try { out[k] = decodeURIComponent(raw); } catch (e) { out[k] = raw; }
    });
    return out;
  }

  /** True when the text is a single HLS manifest (master or media playlist) rather than a channel list. */
  function isHlsManifest(text) {
    return /#EXT-X-(STREAM-INF|TARGETDURATION|MEDIA-SEQUENCE|MEDIA:|I-FRAME-STREAM-INF)/i.test(text);
  }

  /** Parse an M3U / M3U_PLUS channel list (or a plain list of URLs). Returns [{name,url,logo,group,headers?}]. */
  function parseM3U(text, baseUrl) {
    text = String(text || "").replace(/^﻿/, "");
    const hasExt = /#EXTM3U|#EXTINF/i.test(text);
    const items = [];
    let cur = null;
    let pendingGroup = "";
    let optHeaders = {};

    for (const raw of text.split(/\r?\n/)) {
      const line = raw.trim();
      if (!line) continue;

      if (/^#EXTINF/i.test(line)) { cur = parseExtInf(line); continue; }
      if (/^#EXTGRP:/i.test(line)) { pendingGroup = line.slice(8).trim(); continue; }

      const vlc = line.match(/^#EXTVLCOPT:\s*http-(user-agent|referrer|referer)\s*=\s*(.*)$/i);
      if (vlc) { optHeaders[/^user/i.test(vlc[1]) ? "User-Agent" : "Referer"] = vlc[2].trim(); continue; }
      if (/^#EXTHTTP:/i.test(line)) {
        try {
          const obj = JSON.parse(line.slice(9));
          for (const k of Object.keys(obj)) if (typeof obj[k] === "string") optHeaders[k] = obj[k];
        } catch (e) { /* ignore malformed */ }
        continue;
      }
      if (line[0] === "#") continue; // other tags / comments

      let url = line;
      let pipeHeaders = null;
      // Kodi style "url|User-Agent=...&Referer=..."
      const pipe = url.indexOf("|");
      if (pipe > 0 && /^[\w-]+=/.test(url.slice(pipe + 1))) {
        pipeHeaders = parseHeaderString(url.slice(pipe + 1));
        url = url.slice(0, pipe);
      }

      if (!SCHEME_RE.test(url)) {
        if (!hasExt) continue; // plain-list mode: ignore junk lines (e.g. an HTML error page)
        if (baseUrl) {
          try { url = new URL(url, baseUrl).href; } catch (e) { cur = null; optHeaders = {}; continue; }
        } else {
          cur = null;
          optHeaders = {};
          continue;
        }
      }

      const entry = cur || { name: "", logo: "", group: "" };
      if (!entry.group && pendingGroup) entry.group = pendingGroup;
      entry.url = url;
      if (!entry.name) entry.name = nameFromUrl(url);
      const headers = Object.assign({}, optHeaders, pipeHeaders || {});
      if (Object.keys(headers).length) entry.headers = headers;
      items.push(entry);
      cur = null;
      pendingGroup = "";
      optHeaders = {};
    }
    return items;
  }

  /** Tidy user input into a fetchable URL. */
  function normalizeUrl(raw) {
    let url = String(raw || "").trim();
    if (!url) return "";
    if (!SCHEME_RE.test(url)) url = "https://" + url;
    const gh = url.match(/^https?:\/\/github\.com\/([^/]+)\/([^/]+)\/blob\/(.+)$/i);
    if (gh) url = `https://raw.githubusercontent.com/${gh[1]}/${gh[2]}/${gh[3]}`;
    return url;
  }

  /* ---------- native HTTP helper (no CORS, follows http<->https redirects) ---------- */
  function headerValue(headers, name) {
    if (!headers) return "";
    const n = name.toLowerCase();
    for (const k of Object.keys(headers)) if (k.toLowerCase() === n) return String(headers[k]);
    return "";
  }

  /** `call` is CapacitorHttp.request. Redirects are followed here because Android's HttpURLConnection will not cross http<->https. */
  async function httpGet(call, url, headers, responseType, timeoutMs) {
    let cur = url;
    for (let hop = 0; hop < 6; hop++) {
      const res = await call({
        url: cur,
        method: "GET",
        headers: Object.assign({ "User-Agent": DEFAULT_UA, Accept: "*/*" }, headers || {}),
        responseType: responseType || "text",
        disableRedirects: true,
        connectTimeout: 15000,
        readTimeout: timeoutMs || 30000,
      });
      if (res && res.status >= 300 && res.status < 400) {
        const loc = headerValue(res.headers, "location");
        if (loc) { cur = new URL(loc, cur).href; continue; }
      }
      res.finalUrl = cur;
      return res;
    }
    throw new Error("Too many redirects");
  }

  /* ---------- Xtream Codes login (what Televizo / IPTV Smarters do) ---------- */
  /** Detect an Xtream "get.php?username=..&password=.." link. */
  function parseXtreamUrl(raw) {
    let u;
    try { u = new URL(raw); } catch (e) { return null; }
    if (!/\/(get|panel_api)\.php$/i.test(u.pathname)) return null;
    const username = u.searchParams.get("username"), password = u.searchParams.get("password");
    if (!username || !password) return null;
    const dir = u.pathname.replace(/\/[^/]*$/, "");
    return { base: u.origin + dir, username, password, output: (u.searchParams.get("output") || "ts").toLowerCase() };
  }

  /** Build an M3U from player_api.php live categories + streams. */
  function xtreamToM3U(x, cats, streams, vodCats, vods) {
    const names = {};
    (Array.isArray(cats) ? cats : []).forEach((c) => { names[c.category_id] = c.category_name; });
    const ext = x.output === "m3u8" || x.output === "hls" ? "m3u8" : "ts";
    const q = (v) => String(v == null ? "" : v).replace(/"/g, "'").replace(/[\r\n]+/g, " ");
    const lines = ["#EXTM3U"];
    (Array.isArray(streams) ? streams : []).forEach((st) => {
      if (st.stream_id == null) return;
      lines.push(`#EXTINF:-1 tvg-id="${q(st.epg_channel_id)}" tvg-logo="${q(st.stream_icon)}" group-title="${q(names[st.category_id] || "")}",${q(st.name)}`);
      lines.push(`${x.base}/live/${encodeURIComponent(x.username)}/${encodeURIComponent(x.password)}/${st.stream_id}.${ext}`);
    });
    const vnames = {};
    (Array.isArray(vodCats) ? vodCats : []).forEach((c) => { vnames[c.category_id] = c.category_name; });
    (Array.isArray(vods) ? vods : []).forEach((st) => {
      if (st.stream_id == null) return;
      lines.push(`#EXTINF:-1 tvg-logo="${q(st.stream_icon)}" group-title="${q(vnames[st.category_id] || "Movies")}",${q(st.name)}`);
      lines.push(`${x.base}/movie/${encodeURIComponent(x.username)}/${encodeURIComponent(x.password)}/${st.stream_id}.${q(st.container_extension) || "mp4"}`);
    });
    return lines.join("\n");
  }

  /** Download through the native plugin (streams big playlists, delivers them in chunks). */
  async function fetchViaPlugin(plugin, url, kind, uas) {
    const r = await plugin.fetchStart({ url, kind: kind || "playlist", userAgents: uas });
    if (r && r.big) return { big: true, total: r.total, groups: r.groups || [] };
    let text = "", offset = 0;
    try {
      for (let i = 0; i < 400; i++) {
        const c = await plugin.fetchRead({ id: r.id, offset, length: 400000 });
        text += c.text;
        offset += c.text.length;
        if (c.done) break;
      }
    } finally {
      try { await plugin.fetchDone({ id: r.id }); } catch (e) { /* ignore */ }
    }
    return text;
  }

  const api = { fetchViaPlugin, parseXtreamUrl, xtreamToM3U, parseM3U, parseExtInf, parseHeaderString, isHlsManifest, normalizeUrl, nameFromUrl, headerValue, httpGet };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (typeof document === "undefined") return; // Node (tests): stop here

  /* =====================================================================
   * App
   * ===================================================================== */
  const $ = (id) => document.getElementById(id);
  const els = {
    msgText: $("msgText"), msgClose: $("msgClose"), webVideo: $("webVideo"), tapzone: $("tapzone"), zap: $("zap"), spinner: $("spinner"), msg: $("msg"),
    overlay: $("overlay"), audioWiz: $("audioWiz"), awList: $("awList"), awTitle: $("awTitle"), btnRecord: $("btnRecord"), recBadge: $("recBadge"), btnOpen: $("btnOpen"), plDlg: $("plDlg"), plList: $("plList"), plStatus: $("plStatus"), btnPlAdd: $("btnPlAdd"),
    btnRefresh: $("btnRefresh"), btnInfo: $("btnInfo"), search: $("search"), groupList: $("groupList"),
    listWrap: $("listWrap"), list: $("list"), emptyList: $("emptyList"), emptyText: $("emptyText"), welcome: $("welcome"), btnWelcomeAdd: $("btnWelcomeAdd"),
    dlg: $("dlg"), urlInput: $("urlInput"), btnLoadUrl: $("btnLoadUrl"), btnPlayUrl: $("btnPlayUrl"),
    btnFile: $("btnFile"), btnInbox: $("btnInbox"), inboxBox: $("inboxBox"), inboxInfo: $("inboxInfo"), fileBox: $("fileBox"), fileInput: $("fileInput"),
    dlgStatus: $("dlgStatus"), toast: $("toast"),
  };

  const PAGE = 100;
  const HIDE_AFTER_MS = 15000;
  els.search = els.search || document.createElement("input"); // search box was removed from the screen
  const KEY = { history: "m3u.history", cache: "m3u.cache", last: "m3u.last", favs: "m3u.favs", aspect: "m3u.aspect", big: "m3u.big", lastItem: "m3u.lastItem" };

  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); return true; } catch (e) { return false; } },
    del(k) { try { localStorage.removeItem(k); } catch (e) { /* ignore */ } },
  };

  const state = {
    items: [], view: [], rendered: 0, current: -1, big: null, winTotal: 0,
    label: "", source: "", group: "all", query: "", groups: [],
    favs: new Set(store.get(KEY.favs, [])),
  };
  const ui = { pane: "channels", gSel: 0, cSel: 0, bSel: 0, hideTimer: 0, zapTimer: 0, vod: false, toastTimer: 0 };

  /* ---------- small helpers ---------- */
  const clamp = (n, lo, hi) => Math.max(lo, Math.min(hi, n));
  function toast(msg, ms) {
    els.toast.textContent = msg;
    els.toast.hidden = false;
    clearTimeout(ui.toastTimer);
    ui.toastTimer = setTimeout(() => { els.toast.hidden = true; }, ms || 3500);
  }
  function setStatus(msg, isError) {
    els.plStatus.textContent = msg || "";
    els.plStatus.classList.toggle("error", !!isError);
    els.dlgStatus.textContent = msg || "";
    if (msg) { try { els.dlgStatus.scrollIntoView({ block: "nearest" }); } catch (e) { /* ignore */ } }
    els.dlgStatus.classList.toggle("error", !!isError);
  }
  function withTimeout(promise, ms, message) {
    let timer;
    const t = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), ms); });
    return Promise.race([promise, t]).finally(() => clearTimeout(timer));
  }
  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = src;
      s.onload = resolve;
      s.onerror = () => reject(new Error("Failed to load " + src));
      document.head.appendChild(s);
    });
  }

  /* ---------- native bridge ---------- */
  let fetchProgress = null;
  function nativePlugin() {
    const cap = root.Capacitor;
    if (!cap || !(cap.isNativePlatform && cap.isNativePlatform())) return null;
    try {
      if (cap.isPluginAvailable && !cap.isPluginAvailable("NativePlayer")) return null;
      const p = cap.registerPlugin ? cap.registerPlugin("NativePlayer") : (cap.Plugins && cap.Plugins.NativePlayer);
      return p && p.fetchStart ? p : null;
    } catch (e) { return null; }
  }
  /** Leave a note in native storage so we can tell what happened if the app stops unexpectedly. */
  function crumb(text) {
    try { const p = nativePlugin(); if (p && p.crumb) p.crumb({ text }); } catch (e) { /* ignore */ }
  }
  let progressHooked = false;
  function hookProgress(p) {
    if (progressHooked) return;
    progressHooked = true;
    try { p.addListener("fetchProgress", (e) => { if (fetchProgress && e) fetchProgress(e); }); } catch (err) { /* ignore */ }
  }

  function nativeCall() {
    const cap = root.Capacitor;
    if (!cap || !(cap.isNativePlatform && cap.isNativePlatform())) return null;
    const p = cap.Plugins && cap.Plugins.CapacitorHttp;
    if (p && p.request) return (o) => p.request(o);
    if (cap.nativePromise) return (o) => cap.nativePromise("CapacitorHttp", "request", o);
    return null;
  }

  /* =====================================================================
   * Playback engines
   * ===================================================================== */
  function createNativeEngine() {
    const cap = root.Capacitor;
    if (!cap || !(cap.isNativePlatform && cap.isNativePlatform())) return null;
    let plugin = null;
    try {
      if (cap.isPluginAvailable && !cap.isPluginAvailable("NativePlayer")) return null;
      plugin = cap.registerPlugin ? cap.registerPlugin("NativePlayer") : (cap.Plugins && cap.Plugins.NativePlayer);
    } catch (e) { return null; }
    if (!plugin) return null;
    return {
      native: true,
      onState(cb) { plugin.addListener("state", cb); },
      onAudioTracks(cb) { plugin.addListener("audioTracks", cb); },
      setAudioTrack(id) { return plugin.setAudioTrack({ id }); },
      recordStart(mode, name) { return plugin.recordStart({ mode, name }); },
      recordStop() { return plugin.recordStop(); },
      play(item) { return plugin.play({ url: item.url, headers: item.headers || {} }); },
      stop() { return plugin.stop(); },
      setAspect(mode) { return plugin.setResizeMode({ mode }); },
      seek(seconds) { return plugin.seekBy({ seconds }); },
      async info() { const r = await plugin.info(); return (r && r.text) || "No information yet."; },
    };
  }

  function createWebEngine() {
    const v = els.webVideo;
    let hls = null;
    let cb = () => {};
    v.hidden = false;
    v.addEventListener("waiting", () => cb({ state: "buffering" }));
    v.addEventListener("playing", () => cb({ state: "playing" }));
    v.addEventListener("ended", () => cb({ state: "ended" }));
    v.addEventListener("error", () => cb({ state: "error", message: "media error " + (v.error ? v.error.code : "") }));
    function stop() {
      if (hls) { try { hls.destroy(); } catch (e) { /* ignore */ } hls = null; }
      v.pause();
      v.removeAttribute("src");
      v.load();
    }
    return {
      native: false,
      onState(f) { cb = f; },
      onAudioTracks() { /* browser preview has no audio track choice */ },
      setAudioTrack() { return Promise.resolve(); },
      recordStart() { return Promise.reject(new Error("Recording works only in the Android app.")); },
      recordStop() { return Promise.resolve({}); },
      async play(item) {
        stop();
        cb({ state: "buffering" });
        const wantHls = HLS_URL_RE.test(item.url) || !MEDIA_FILE_RE.test(item.url);
        if (wantHls && !root.Hls) { try { await loadScript(HLS_CDN); } catch (e) { /* offline */ } }
        if (wantHls && root.Hls && root.Hls.isSupported()) {
          hls = new root.Hls();
          hls.on(root.Hls.Events.ERROR, (e, d) => { if (d.fatal) cb({ state: "error", message: d.details }); });
          hls.loadSource(item.url);
          hls.attachMedia(v);
        } else {
          v.src = item.url;
        }
        try { await v.play(); } catch (e) { /* autoplay blocked: user can tap */ }
      },
      stop() { stop(); return Promise.resolve(); },
      seek(seconds) { v.currentTime = Math.max(0, v.currentTime + seconds); return Promise.resolve(); },
      info() { return Promise.resolve("Browser preview mode: no native player details."); },
      setAspect(mode) { v.style.objectFit = mode === "zoom" ? "cover" : mode === "fill" ? "fill" : "contain"; return Promise.resolve(); },
    };
  }

  const engine = createNativeEngine() || createWebEngine();

  /* ---------- fetching playlists ---------- */
  const FETCH_UAS = [
    "VLC/3.0.18 LibVLC/3.0.18",
    DEFAULT_UA,
    "IPTVSmartersPro",
    "okhttp/4.12.0",
    "Lavf/60.16.100",
  ];
  async function fetchPlaylistNative(call, url) {
    let lastErr = "";
    for (const ua of FETCH_UAS) {
      try {
        const res = await withTimeout(httpGet(call, url, { "User-Agent": ua }, "text", 60000), 75000, "Timed out waiting for the server");
        const body = typeof res.data === "string" ? res.data : JSON.stringify(res.data || "");
        if (res.status >= 400) { lastErr = "Server answered HTTP " + res.status; continue; }
        if (!body.trim()) { lastErr = "Server sent an empty reply (account expired, too many connections, or blocked)"; continue; }
        if (/^\s*<(!doctype|html)/i.test(body)) { lastErr = "Server sent a web page instead of a playlist: " + body.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim().slice(0, 120); continue; }
        return { text: body };
      } catch (err) {
        lastErr = (err && err.message) || String(err);
      }
    }
    return { error: lastErr };
  }
  async function fetchJsonNative(call, url) {
    let lastErr = "";
    for (const ua of FETCH_UAS) {
      try {
        const res = await withTimeout(httpGet(call, url, { "User-Agent": ua }, "text", 90000), 100000, "Timed out waiting for the server");
        if (res.status >= 400) { lastErr = "HTTP " + res.status; continue; }
        const json = typeof res.data === "string" ? JSON.parse(res.data) : res.data;
        return { json };
      } catch (err) {
        lastErr = (err && err.message) || String(err);
      }
    }
    return { error: lastErr };
  }
  /** Many IPTV servers only answer to player-like User-Agents, so try several before giving up. */
  async function fetchText(url) {
    const plugin = nativePlugin();
    if (plugin) {
      hookProgress(plugin);
      fetchProgress = (e) => setStatus(e.entries != null ? "Reading channels… " + Number(e.entries).toLocaleString() : "Downloading playlist… " + (e.bytes / 1048576).toFixed(1) + " MB");
      try {
        let firstErr = "";
        try {
          return await fetchViaPlugin(plugin, url, "playlist", FETCH_UAS);
        } catch (err) { firstErr = (err && err.message) || String(err); }
        const x = parseXtreamUrl(url);
        if (x) {
          const api = x.base + "/player_api.php?username=" + encodeURIComponent(x.username) + "&password=" + encodeURIComponent(x.password);
          setStatus("Playlist download failed (" + firstErr + "). Trying account login…");
          try {
            const cats = JSON.parse(await fetchViaPlugin(plugin, api + "&action=get_live_categories", "json", FETCH_UAS));
            const streams = JSON.parse(await fetchViaPlugin(plugin, api + "&action=get_live_streams", "json", FETCH_UAS));
            let vodCats = [], vods = [];
            try {
              vodCats = JSON.parse(await fetchViaPlugin(plugin, api + "&action=get_vod_categories", "json", FETCH_UAS));
              vods = JSON.parse(await fetchViaPlugin(plugin, api + "&action=get_vod_streams", "json", FETCH_UAS));
            } catch (e3) { /* movies are optional */ }
            if (Array.isArray(streams) && streams.length) return xtreamToM3U(x, cats, streams, vodCats, vods);
            throw new Error("no live channels returned");
          } catch (err2) {
            throw new Error(firstErr + ". Account login also failed: " + ((err2 && err2.message) || err2));
          }
        }
        throw new Error(firstErr + ". If this link is a live stream and not a playlist, use “Play as stream”.");
      } finally {
        fetchProgress = null;
        crumb("ok (download finished)");
      }
    }
    return fetchTextLegacy(url);
  }
  async function fetchTextLegacy(url) {
    const call = nativeCall();
    if (call) {
      const first = await fetchPlaylistNative(call, url);
      if (first.text) return first.text;
      const x = parseXtreamUrl(url);
      if (x) {
        const api = x.base + "/player_api.php?username=" + encodeURIComponent(x.username) + "&password=" + encodeURIComponent(x.password);
        const cats = await fetchJsonNative(call, api + "&action=get_live_categories");
        const streams = await fetchJsonNative(call, api + "&action=get_live_streams");
        if (streams.json && Array.isArray(streams.json) && streams.json.length) return xtreamToM3U(x, cats.json, streams.json);
        throw new Error(first.error + ". Logging in with the account (player API) also failed: " + (streams.error || "no live channels returned") + ".");
      }
      throw new Error(first.error + ". If this link is a live stream and not a playlist, use “Play as stream”.");
    }
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 30000);
    try {
      const res = await fetch(url, { signal: ctrl.signal });
      if (!res.ok) throw new Error("Server answered HTTP " + res.status);
      return await res.text();
    } finally {
      clearTimeout(timer);
    }
  }

  /* =====================================================================
   * Playlist state
   * ===================================================================== */
  function setPlaylist(items, meta) {
    if (!items.length) throw new Error("No playable entries found. If this link is a stream (not a playlist), use “Play as stream”.");
    state.big = null;
    store.del(KEY.big);
    state.items = items;
    state.label = meta.label || "Playlist";
    state.source = meta.source || "";
    state.group = "all";
    state.query = "";
    els.search.value = "";
    buildGroups();
    applyFilter();
    els.btnRefresh.hidden = !state.source;

    const last = store.get(KEY.last, "");
    state.current = last ? items.findIndex((it) => it.url === last) : -1;

    // Remember the playlist for the next start (small streams are stored as a tiny playlist of their own).
    const cacheText = meta.text || (items.length <= 20 ? itemsToM3U(items) : "");
    if (cacheText && cacheText.length < 2500000 && store.set(KEY.cache, { label: state.label, source: state.source, text: cacheText })) { /* saved */ }
    else store.del(KEY.cache);
    if (state.source) addHistory(state.source);
  }

  function itemsToM3U(items) {
    const lines = ["#EXTM3U"];
    for (const it of items) {
      lines.push(`#EXTINF:-1 group-title="${(it.group || "").replace(/"/g, "'")}",${it.name}`);
      if (it.headers) {
        if (it.headers["User-Agent"]) lines.push("#EXTVLCOPT:http-user-agent=" + it.headers["User-Agent"]);
        if (it.headers.Referer) lines.push("#EXTVLCOPT:http-referrer=" + it.headers.Referer);
      }
      lines.push(it.url);
    }
    return lines.join("\n");
  }

  function loadFromText(text, meta) {
    meta = meta || {};
    if (text && typeof text === "object" && text.big) return { single: false, big: true, pending: loadBig(text, meta) };
    if (isHlsManifest(text)) {
      if (!meta.source) throw new Error("This is a single stream manifest, not a channel list. Use its URL with “Play as stream”.");
      const name = nameFromUrl(meta.source);
      setPlaylist([{ name, url: meta.source, group: "" }], { label: name, source: meta.source });
      return { single: true };
    }
    const items = parseM3U(text, meta.source);
    setPlaylist(items, { label: meta.label || (meta.source ? nameFromUrl(meta.source) : "Pasted playlist"), source: meta.source, text });
    return { single: false };
  }

  function playSingle(url) {
    const name = nameFromUrl(url);
    setPlaylist([{ name, url, group: "" }], { label: name, source: "" });
    closeDialog();
    closeOverlay();
    play(0);
  }

  async function loadFromUrl(raw, asStream) {
    const url = normalizeUrl(raw);
    if (!url) return;
    if (asStream || (MEDIA_FILE_RE.test(url) && !HLS_URL_RE.test(url))) { playSingle(url); return; }
    setStatus("Loading playlist…");
    els.btnLoadUrl.disabled = true;
    try {
      const text = await fetchText(url);
      if (typeof text === "string") {
        setStatus("Reading " + Math.round(text.length / 1024) + " KB of channels…");
        crumb("Reading the channel list (" + text.length + " characters)");
        await new Promise((r) => setTimeout(r, 30));
      }
      const out = loadFromText(text, { source: url });
      if (out.pending) await out.pending;
      crumb("Showing " + (state.big ? state.big.total : state.items.length) + " channels");
      closeDialog();
      crumb("ok");
      if (out.single) { closeOverlay(); play(0); } else openOverlay();
    } catch (err) {
      if (HLS_URL_RE.test(url)) {
        try { playSingle(url); toast("Couldn't read it as a playlist, playing it as a stream…"); return; } catch (e2) { /* fall through */ }
      }
      crumb("ok (failed: " + ((err && err.message) || err) + ")");
      setStatus("Couldn't load: " + (err && err.message ? err.message : err), true);
    } finally {
      els.btnLoadUrl.disabled = false;
    }
  }

  async function loadFromFile(file) {
    setStatus("Reading " + file.name + "…");
    try {
      loadFromText(await file.text(), { label: file.name });
      closeDialog();
      openOverlay();
    } catch (err) {
      setStatus(err.message || String(err), true);
    }
  }

  const MAX_PLAYLISTS = 3;
  function addHistory(url) {
    const list = store.get(KEY.history, []).filter((u) => u !== url);
    list.unshift(url);
    store.set(KEY.history, list.slice(0, MAX_PLAYLISTS)); // newest first; a 4th playlist replaces the oldest
  }
  /* =====================================================================
   * Groups + channel list
   * ===================================================================== */
  /* ---------- very large playlists: channels live in a native on-disk database ---------- */
  let bigSeq = 0, bigTimer = 0, bigLoading = false;
  const BIG_PAGE = 500;

  function bigPlugin() { return nativePlugin(); }

  function bigGroupsFrom(list) {
    return (list || []).map((g) => ({ key: g.key, label: g.label, count: g.count }));
  }

  function bigQueryPage(offset) {
    return bigPlugin().bigQuery({
      group: state.group, q: state.query.trim(), offset, limit: BIG_PAGE,
    });
  }

  function loadBig(info, meta) {
    state.big = { total: info.total, groupList: info.groups || [] };
    state.label = meta.label || (meta.source ? nameFromUrl(meta.source) : "Playlist");
    state.source = meta.source || "";
    state.group = "all";
    state.query = "";
    els.search.value = "";
    state.items = [];
    state.view = [];
    state.groups = bigGroupsFrom(state.big.groupList);
    syncWelcome();
    renderGroups();
    els.btnRefresh.hidden = !state.source;
    store.del(KEY.cache);
    store.set(KEY.big, { label: state.label, source: state.source });
    if (state.source) addHistory(state.source);
    return bigApply(0);
  }

  function bigApply(delay) {
    clearTimeout(bigTimer);
    const run = async () => {
      const seq = ++bigSeq;
      setBusy(true);
      try {
        const res = await bigQueryPage(0);
        if (seq !== bigSeq) return;
        state.items = res.items || [];
        state.view = state.items.map((_, i) => i);
        state.winTotal = res.total || 0;
        const last = store.get(KEY.last, "");
        state.current = last ? state.items.findIndex((it) => it.url === last) : -1;
        state.rendered = 0;
        els.list.textContent = "";
        els.listWrap.scrollTop = 0;
        renderMore();
        const empty = state.items.length === 0;
        els.emptyList.hidden = !empty;
        if (empty) els.emptyText.textContent = "No channels here.";
        ui.cSel = state.current < 0 ? 0 : state.current;
        paintCursor();
      } catch (err) {
        setMsg("Search failed: " + ((err && err.message) || err), true, 6000);
      } finally {
        if (seq === bigSeq) setBusy(false);
      }
    };
    if (delay === 0) return run();
    bigTimer = setTimeout(run, delay == null ? 120 : delay);
    return Promise.resolve();
  }

  async function bigLoadMore() {
    if (bigLoading || !state.big || state.items.length >= state.winTotal) return;
    bigLoading = true;
    const seq = bigSeq;
    try {
      const res = await bigQueryPage(state.items.length);
      if (seq !== bigSeq) return;
      for (const it of res.items || []) { state.view.push(state.items.length); state.items.push(it); }
      renderMore();
    } catch (err) { /* ignore */ } finally { bigLoading = false; }
  }

  function buildGroups() {
    const counts = new Map();
    for (const it of state.items) {
      const g = it.group || "";
      counts.set(g, (counts.get(g) || 0) + 1);
    }
    const groups = [];
    for (const [g, n] of counts) if (g) groups.push({ key: "g:" + g, label: g, count: n });
    if (counts.has("")) groups.push({ key: "g:", label: "Ungrouped", count: counts.get("") });
    state.groups = groups;
    renderGroups();
  }

  function renderGroups() {
    els.groupList.textContent = "";
    state.groups.forEach((g, i) => {
      const li = document.createElement("li");
      li.className = "row group" + (g.key === state.group ? " active" : "");
      li.dataset.g = String(i);
      const name = document.createElement("div");
      name.className = "name";
      name.textContent = g.label;
      const n = document.createElement("div");
      n.className = "count-badge";
      n.textContent = String(g.count);
      li.append(name, n);
      els.groupList.appendChild(li);
    });
    const idx = state.groups.findIndex((g) => g.key === state.group);
    ui.gSel = idx < 0 ? 0 : idx;
  }

  function applyFilter() {
    syncWelcome();
    if (state.big) { bigApply(); return; }
    const q = state.query.trim().toLowerCase();
    const g = state.group;
    const view = [];
    for (let i = 0; i < state.items.length; i++) {
      const it = state.items[i];
      if (g.startsWith("g:") && (it.group || "") !== g.slice(2)) continue;
      if (q && !(it.name.toLowerCase().includes(q) || (it.group || "").toLowerCase().includes(q))) continue;
      view.push(i);
    }
    state.view = view;
    state.rendered = 0;
    els.list.textContent = "";
    els.listWrap.scrollTop = 0;
    renderMore();

    const empty = view.length === 0;
    els.emptyList.hidden = !empty;
    if (empty) {
      const noPlaylist = state.items.length === 0;
      els.emptyText.textContent = "No channels here.";
    }
    const pos = state.view.indexOf(state.current);
    ui.cSel = pos < 0 ? 0 : pos;
  }

  function rowEl(viewPos) {
    const idx = state.view[viewPos];
    const it = state.items[idx];
    const li = document.createElement("li");
    li.className = "row" + (idx === state.current ? " active" : "");
    li.dataset.i = String(idx);
    li.dataset.v = String(viewPos);

    // No letter placeholder: a channel logo is shown only when the playlist gives one and it loads.
    const hasLogoUrl = !!it.logo && /^https?:/i.test(it.logo);
    let img = null;
    if (hasLogoUrl) {
      img = document.createElement("img");
      img.loading = "lazy";
      img.decoding = "async";
      img.referrerPolicy = "no-referrer";
      img.alt = "";
      img.onload = () => {
        const box = document.createElement("div");
        box.className = "logo";
        box.appendChild(img);
        li.insertBefore(box, li.firstChild);
        li.classList.add("haslogo");
      };
      img.src = it.logo;
    }

    const meta = document.createElement("div");
    meta.className = "meta";
    const name = document.createElement("div");
    name.className = "name";
    name.textContent = it.name;
    const grp = document.createElement("div");
    grp.className = "grp";
    grp.textContent = it.group || "";
    meta.append(name, grp);

    li.append(meta);
    return li;
  }

  function renderMore() {
    if (state.big && state.rendered >= state.view.length - 40) bigLoadMore();
    const frag = document.createDocumentFragment();
    const end = Math.min(state.rendered + PAGE, state.view.length);
    for (let i = state.rendered; i < end; i++) frag.appendChild(rowEl(i));
    els.list.appendChild(frag);
    state.rendered = end;
    // Keep filling while the list is visible but shorter than its box.
    const w = els.listWrap;
    if (w.clientHeight > 0 && w.scrollHeight <= w.clientHeight + 80 && state.rendered < state.view.length) renderMore();
  }
  function ensureRendered(viewPos) {
    if (state.big && viewPos >= state.view.length - 40) bigLoadMore();
    while (state.rendered <= viewPos && state.rendered < state.view.length) renderMore();
  }

  /* ---------- cursor (remote control / keyboard focus) ---------- */
  const barItems = () => [els.btnRecord, els.btnOpen, els.btnRefresh, els.btnInfo].filter((b) => !b.hidden);

  function paintCursor(scroll) {
    document.querySelectorAll(".sel").forEach((n) => n.classList.remove("sel"));
    if (els.overlay.hidden) return;
    if (ui.pane === "bar") {
      const items = barItems();
      ui.bSel = clamp(ui.bSel, 0, items.length - 1);
      if (items[ui.bSel]) items[ui.bSel].classList.add("sel");
    } else if (ui.pane === "groups") {
      const el = els.groupList.children[ui.gSel];
      if (el) { el.classList.add("sel"); if (scroll) el.scrollIntoView({ block: "nearest" }); }
    } else {
      ensureRendered(ui.cSel);
      const el = els.list.querySelector(`.row[data-v="${ui.cSel}"]`);
      if (el) { el.classList.add("sel"); if (scroll) el.scrollIntoView({ block: "nearest" }); }
    }
  }

  function selectGroup(i) {
    const g = state.groups[i];
    if (!g) return;
    ui.gSel = i;
    state.group = state.group === g.key ? "all" : g.key;
    applyFilter();
    for (const li of els.groupList.children) li.classList.toggle("active", state.groups[Number(li.dataset.g)].key === state.group);
  }

  function moveCursor(d) {
    if (ui.pane === "groups") {
      const i = clamp(ui.gSel + d, 0, Math.max(0, state.groups.length - 1));
      if (i !== ui.gSel) selectGroup(i);
      else if (d < 0) { ui.pane = "bar"; ui.bSel = 0; }
    } else if (ui.pane === "channels") {
      if (d < 0 && ui.cSel === 0) { ui.pane = "bar"; ui.bSel = 0; }
      else ui.cSel = clamp(ui.cSel + d, 0, Math.max(0, state.view.length - 1));
    } else if (ui.pane === "bar" && d > 0) {
      ui.pane = "channels";
    }
    paintCursor(true);
  }

  /* =====================================================================
   * Overlay (groups + channels over the video)
   * ===================================================================== */
  const overlayOpen = () => !els.overlay.hidden;

  function armHide() {
    clearTimeout(ui.hideTimer);
    if (!overlayOpen() || !state.items.length || dialogOpen()) return;
    ui.hideTimer = setTimeout(() => {
      // Hidden by the timer, not by the user: ignore Up/Down for a moment so a key press that was meant for the
      // lists can't zap to another channel.
      ui.noZapUntil = Date.now() + 2500;
      closeOverlay();
    }, HIDE_AFTER_MS);
  }
  function openOverlay() {
    els.overlay.hidden = false;
    els.zap.hidden = true;
    ui.pane = "channels";
    const pos = state.view.indexOf(state.current);
    ui.cSel = pos < 0 ? 0 : pos;
    renderGroups();
    paintCursor(true);
    armHide();
  }
  function closeOverlay() {
    clearTimeout(ui.hideTimer);
    els.overlay.hidden = true;
    if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
    paintCursor();
  }
  function toggleOverlay() { if (overlayOpen()) closeOverlay(); else openOverlay(); }

  function dialogOpen() { return els.dlg.open || els.plDlg.open; }

  function openDialog() {
    if (els.plDlg.open) els.plDlg.close();
    clearTimeout(ui.hideTimer);
    setStatus("");
    if (!els.dlg.open) els.dlg.showModal();
  }
  function closeDialog() {
    if (els.dlg.open) els.dlg.close();
    if (els.plDlg.open) els.plDlg.close();
    armHide();
  }

  /* ---------- saved playlists: switch / replace / remove ---------- */
  function playlistName(url) {
    try {
      const u = new URL(url);
      const user = u.searchParams.get("username");
      if (user) return u.hostname + " · " + user;
      const parts = u.pathname.split("/").filter(Boolean).map((x) => { try { return decodeURIComponent(x); } catch (e) { return x; } });
      const id = parts.find((x) => /^\d{3,}$/.test(x));
      if (id) return u.hostname + " · " + id;
      const last = parts[parts.length - 1] || "";
      return /^(m3u_?plus|m3u8?|get\.php|playlist)$/i.test(last) || !last ? u.hostname : last;
    } catch (e) { return String(url).slice(0, 40); }
  }
  function playlistHost(url) {
    try { const u = new URL(url); return u.host; } catch (e) { return ""; }
  }

  function renderPlaylists() {
    const list = store.get(KEY.history, []);
    els.plList.textContent = "";
    if (!list.length) {
      const p = document.createElement("li");
      p.className = "pl-empty";
      p.textContent = "No saved playlists yet.";
      els.plList.appendChild(p);
      return;
    }
    for (const url of list) {
      const li = document.createElement("li");
      const isCurrent = url === state.source;
      li.className = isCurrent ? "current" : "";
      const b = document.createElement("button");
      b.type = "button";
      b.className = "pl-pick";
      const name = document.createElement("span");
      name.className = "pl-name";
      name.textContent = playlistName(url);
      if (isCurrent) { const t = document.createElement("span"); t.className = "pl-tag"; t.textContent = "current"; name.appendChild(t); }
      const sub = document.createElement("span");
      sub.className = "pl-sub";
      sub.textContent = playlistHost(url);
      b.append(name, sub);
      b.addEventListener("click", () => {
        if (isCurrent) { closeDialog(); openOverlay(); return; }
        setStatus("Loading playlist…");
        loadFromUrl(url, false);
      });
      const x = document.createElement("button");
      x.type = "button";
      x.className = "icon-btn";
      x.setAttribute("aria-label", "Remove");
      x.textContent = "×";
      x.addEventListener("click", () => {
        store.set(KEY.history, store.get(KEY.history, []).filter((u) => u !== url));
        renderPlaylists();
      });
      li.append(b, x);
      els.plList.appendChild(li);
    }
  }

  /** The Playlist button: saved playlists to switch between, plus "Add playlist". */
  function openPlaylists(always) {
    // First start (welcome screen) goes straight to "Load playlist"; the Playlist button always shows "My playlists".
    if (always !== true && !store.get(KEY.history, []).length && !state.source) { openDialog(); return; }
    if (state.source && !store.get(KEY.history, []).includes(state.source)) addHistory(state.source);
    clearTimeout(ui.hideTimer);
    setStatus("");
    els.plStatus.textContent = "Up to " + MAX_PLAYLISTS + " playlists are kept. Adding a new one replaces the oldest.";
    renderPlaylists();
    if (!els.plDlg.open) els.plDlg.showModal();
  }

  /** The picture always fills the whole screen (stretch), so it fits every phone and TV. */
  function applyAspect() {
    try { const p = engine.setAspect("fill"); if (p && p.catch) p.catch(() => {}); } catch (e) { /* ignore */ }
  }

  /* =====================================================================
   * Playback control
   * ===================================================================== */
  function setBusy(on) { els.spinner.hidden = !on; }
  function setMsg(text, isError, ms, closable) {
    clearTimeout(ui.msgTimer);
    if (text && ms) ui.msgTimer = setTimeout(() => setMsg(""), ms);
    els.msgText.textContent = text || "";
    els.msg.hidden = !text;
    els.msg.classList.toggle("error", !!isError);
    els.msg.classList.toggle("closable", !!closable && !!text);
    els.msgClose.hidden = !(closable && text);
  }
  /** Movies and series episodes: Left = back 10 s, Right = forward 30 s (no on-screen controller). */
  function seekVod(seconds) {
    Promise.resolve(engine.seek(seconds)).then((r) => {
      clearTimeout(ui.zapTimer);
      els.zap.textContent = (seconds < 0 ? "◀ " : "▶ ") + Math.abs(seconds) + " s" + (r && r.position != null ? "   " + fmtTime(r.position) + (r.duration ? " / " + fmtTime(r.duration) : "") : "");
      els.zap.hidden = false;
      ui.zapTimer = setTimeout(() => { els.zap.hidden = true; }, 2000);
    }).catch(() => { /* ignore */ });
  }
  function fmtTime(sec) {
    sec = Math.max(0, Math.floor(sec));
    const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s2 = sec % 60;
    return (h ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(s2).padStart(2, "0");
  }
  function showZap(item, pos, total) {
    clearTimeout(ui.zapTimer);
    if (overlayOpen()) { els.zap.hidden = true; return; }
    els.zap.textContent = `${pos} / ${total}  ·  ${item.name}`;
    els.zap.hidden = false;
    ui.zapTimer = setTimeout(() => { els.zap.hidden = true; }, 3000);
  }

  /* ---------- audio language wizard (channels with several audio tracks) ---------- */
  const LANG_NAMES = {
    eng: "English", en: "English", ben: "Bengali", bn: "Bengali", hin: "Hindi", hi: "Hindi",
    tam: "Tamil", ta: "Tamil", tel: "Telugu", te: "Telugu", urd: "Urdu", ur: "Urdu",
    pan: "Punjabi", pa: "Punjabi", mal: "Malayalam", ml: "Malayalam", kan: "Kannada", kn: "Kannada",
    mar: "Marathi", mr: "Marathi", guj: "Gujarati", gu: "Gujarati", ori: "Odia", or: "Odia",
    asm: "Assamese", as: "Assamese", nep: "Nepali", ne: "Nepali", ara: "Arabic", ar: "Arabic",
    spa: "Spanish", es: "Spanish", fra: "French", fre: "French", fr: "French", deu: "German", ger: "German",
    de: "German", ita: "Italian", it: "Italian", por: "Portuguese", pt: "Portuguese", rus: "Russian", ru: "Russian",
    jpn: "Japanese", ja: "Japanese", kor: "Korean", ko: "Korean", chi: "Chinese", zho: "Chinese", zh: "Chinese",
    tur: "Turkish", tr: "Turkish", fas: "Persian", per: "Persian", fa: "Persian"
  };
  let awTracks = [], awSel = 0, awTimer = 0, awUrl = "", awDone = false, awCb = null;
  const audioWizOpen = () => !els.audioWiz.hidden;

  function audioName(t, i) {
    const lang = (t.lang || "").toLowerCase();
    const base = t.label || LANG_NAMES[lang] || (lang ? lang.toUpperCase() : "Track " + (i + 1));
    const ch = t.channels === 1 ? "mono" : t.channels === 2 ? "stereo" : t.channels > 2 ? t.channels + " ch" : "";
    return base + (ch ? "  ·  " + ch : "");
  }
  function paintAudioWiz() {
    els.awList.querySelectorAll(".aw-row").forEach((li, i) => li.classList.toggle("aw-cur", i === awSel));
  }
  function armAudioWizHide() {
    clearTimeout(awTimer);
    awTimer = setTimeout(hideAudioWiz, 15000);
  }
  function hideAudioWiz() {
    clearTimeout(awTimer);
    els.audioWiz.hidden = true;
  }
  /** Small choice panel at the bottom right (used for the audio language and for the Record choice). */
  function showWizard(title, labels, cursor, on, cb) {
    awCb = cb;
    awTracks = labels;
    awSel = Math.max(0, cursor | 0);
    els.awTitle.textContent = title;
    els.awList.textContent = "";
    labels.forEach((text, i) => {
      const li = document.createElement("li");
      li.className = "aw-row" + (i === on ? " on" : "");
      li.dataset.i = String(i);
      li.textContent = text;
      els.awList.appendChild(li);
    });
    els.audioWiz.hidden = false;
    paintAudioWiz();
    armAudioWizHide();
  }
  function showAudioWiz(tracks) {
    const cur = Math.max(0, tracks.findIndex((t) => t.selected));
    showWizard("Audio language", tracks.map(audioName), cur, cur, (i) => {
      const t = tracks[i];
      if (!t) return;
      awDone = true;
      const p = engine.setAudioTrack(t.id);
      if (p && p.catch) p.catch(() => {});
      els.zap.textContent = "♪ " + audioName(t, i);
      els.zap.hidden = false;
      clearTimeout(ui.zapTimer);
      ui.zapTimer = setTimeout(() => { els.zap.hidden = true; }, 2500);
    });
  }
  function pickAudio(i) {
    const cb = awCb;
    hideAudioWiz();
    if (cb && awTracks[i] != null) cb(i);
  }
  els.awList.addEventListener("click", (e) => {
    const li = e.target.closest(".aw-row");
    if (li) pickAudio(Number(li.dataset.i));
  });

  /* ---------- recording: video as MP4, audio only; saved on the device by the native side ---------- */
  const rec = { on: false, t0: 0, timer: 0, url: "", mode: "" };
  const two = (n) => String(n).padStart(2, "0");
  function recClock() {
    const s = Math.floor((Date.now() - rec.t0) / 1000);
    return two(Math.floor(s / 60)) + ":" + two(s % 60);
  }
  function paintRec() {
    els.btnRecord.textContent = rec.on ? "■ Stop " + recClock() : "Record";
    els.btnRecord.classList.toggle("recording", rec.on);
    els.recBadge.hidden = !rec.on;
    els.recBadge.textContent = "● REC " + recClock();
  }
  async function startRecording(mode) {
    const item = state.items[state.current];
    if (!item) { toast("Play a channel first, then press Record."); return; }
    try {
      await engine.recordStart(mode, item.name);
    } catch (err) {
      setMsg("Can't record: " + ((err && err.message) || err), true, 6000);
      return;
    }
    rec.on = true; rec.t0 = Date.now(); rec.url = item.url; rec.mode = mode;
    clearInterval(rec.timer);
    rec.timer = setInterval(paintRec, 1000);
    paintRec();
  }
  async function stopRecording() {
    if (!rec.on) return;
    rec.on = false;
    clearInterval(rec.timer);
    paintRec();
    setMsg("Saving the recording…");
    try {
      const r = (await engine.recordStop()) || {};
      if (r.error) setMsg("Recording failed: " + r.error, true, 9000);
      else if (r.path) setMsg("Saved: " + r.path + (r.note ? "\n" + r.note : ""), false, 9000);
      else setMsg("");
    } catch (err) {
      setMsg("Recording failed: " + ((err && err.message) || err), true, 9000);
    }
  }
  els.btnRecord.addEventListener("click", () => {
    if (rec.on) { closeOverlay(); stopRecording(); return; }
    closeOverlay();
    startRecording("video");
  });

  engine.onAudioTracks((e) => {
    const list = (e && e.tracks) || [];
    if (list.length < 2) { if (!audioWizOpen()) awDone = false; hideAudioWiz(); return; }
    // The picture or sound can report again after the user chose (the choice itself causes an update); keep the choice.
    if (awDone || audioWizOpen()) return;
    showAudioWiz(list);
  });

  engine.onState((e) => {
    if (!e) return;
    if (e.state === "buffering") setBusy(true);
    else if (e.state === "playing") { setBusy(false); setMsg(""); ui.vod = !!e.vod; }
    else if (e.state === "warning") { setBusy(false); setMsg(e.message || "Warning", true, 12000); }
    else if (e.state === "error") {
      setBusy(false);
      setMsg("Can't play this channel" + (e.message ? " — " + e.message : "") + ". Press OK / tap to choose another.", true);
    } else if (e.state === "ended") {
      // Only continue to the next item when the one that ended is still in the visible list; a live stream that
      // simply dropped is reconnected. Never jump to some other channel because the list shows another group.
      const item = state.items[state.current];
      if (item && state.view.indexOf(state.current) >= 0) {
        if (ui.vod) step(1);
        else {
          const now = Date.now();
          ui.reconnects = (ui.reconnects || []).filter((t) => now - t < 30000);
          if (ui.reconnects.length < 3) { ui.reconnects.push(now); play(state.current); }
        }
      }
    }
  });

  function play(idx) {
    ui.vod = false;
    const item = state.items[idx];
    if (!item) return;
    if (item.url !== awUrl) { awUrl = item.url; awDone = false; }
    hideAudioWiz();
    if (rec.on && item.url !== rec.url) stopRecording();
    state.current = idx;
    store.set(KEY.last, item.url);
    if (state.big) store.set(KEY.lastItem, item);
    for (const row of els.list.querySelectorAll(".row.active")) row.classList.remove("active");
    const row = els.list.querySelector(`.row[data-i="${idx}"]`);
    if (row) row.classList.add("active");
    const pos = state.view.indexOf(idx);
    showZap(item, (pos < 0 ? idx : pos) + 1, pos < 0 ? state.items.length : state.view.length);

    if (UNSUPPORTED_RE.test(item.url)) {
      setBusy(false);
      setMsg("This channel uses " + item.url.split(":")[0] + ":// which this player can't open.", true);
      try { const p = engine.stop(); if (p && p.catch) p.catch(() => {}); } catch (e) { /* ignore */ }
      return;
    }
    setMsg("");
    setBusy(true);
    try {
      const p = engine.play(item);
      if (p && p.catch) p.catch((err) => { setBusy(false); setMsg("Player error: " + (err && err.message ? err.message : err), true); });
    } catch (err) {
      setBusy(false);
      setMsg("Player error: " + (err && err.message ? err.message : err), true);
    }
  }

  function step(dir) {
    if (!state.view.length) return;
    const pos = state.view.indexOf(state.current);
    let next = pos < 0 ? (dir > 0 ? 0 : state.view.length - 1) : pos + dir;
    if (next < 0) next = state.view.length - 1;
    if (next >= state.view.length) next = 0;
    ensureRendered(next);
    ui.cSel = next;
    play(state.view[next]);
    if (overlayOpen()) paintCursor(true);
  }

  /* =====================================================================
   * Input: touch, keyboard, TV remote, Android back button
   * ===================================================================== */
  els.tapzone.addEventListener("click", toggleOverlay);
  els.overlay.addEventListener("click", (e) => {
    if (e.target === els.overlay || e.target.id === "panes") closeOverlay();
  });
  ["pointerdown", "keydown", "wheel", "touchmove"].forEach((evt) => els.overlay.addEventListener(evt, armHide, { passive: true }));

  els.list.addEventListener("click", (e) => {
    const row = e.target.closest(".row");
    if (!row) return;
    ui.cSel = Number(row.dataset.v);
    closeOverlay();
    play(Number(row.dataset.i));
  });
  els.groupList.addEventListener("click", (e) => {
    const row = e.target.closest(".row");
    if (!row) return;
    ui.pane = "groups";
    selectGroup(Number(row.dataset.g));
    paintCursor();
  });
  els.listWrap.addEventListener("scroll", () => {
    const w = els.listWrap;
    if (w.scrollTop + w.clientHeight > w.scrollHeight - 700) renderMore();
  }, { passive: true });

  els.btnOpen.addEventListener("click", () => { if (state.items.length || state.big) closeOverlay(); openPlaylists(true); });
  els.btnPlAdd.addEventListener("click", openDialog);
  els.btnWelcomeAdd.addEventListener("click", openPlaylists);
  function syncWelcome() { document.body.classList.toggle("empty", !state.items.length && !state.big); }
  els.btnInfo.addEventListener("click", async () => {
    closeOverlay();
    try { setMsg(await engine.info(), false, 20000, true); }
    catch (err) { setMsg("Info unavailable: " + (err.message || err), true, 6000); }
  });
  els.btnRefresh.addEventListener("click", async () => {
    if (!state.source) return;
    els.btnRefresh.disabled = true;
    closeOverlay();
    setMsg("Reloading playlist…");
    try {
      const keep = state.current >= 0 && state.items[state.current] ? state.items[state.current].url : "";
      const fresh = loadFromText(await fetchText(state.source), { source: state.source });
      if (fresh.pending) await fresh.pending;
      if (keep && !state.big) state.current = state.items.findIndex((i) => i.url === keep);
      setMsg("Playlist reloaded.", false, 2500);
    } catch (err) {
      setMsg("Reload failed: " + (err.message || err), true, 6000);
    } finally {
      els.btnRefresh.disabled = false;
    }
  });

  els.btnLoadUrl.addEventListener("click", () => loadFromUrl(els.urlInput.value, false));
  els.btnPlayUrl.addEventListener("click", () => loadFromUrl(els.urlInput.value, true));
  els.urlInput.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); loadFromUrl(els.urlInput.value, false); } });
  /* ---------- "send from phone": type the link on another device (handy on TV) ---------- */
  (async function setupInbox() {
    const cap = root.Capacitor;
    if (!cap || !(cap.isNativePlatform && cap.isNativePlatform())) return;
    let p = null;
    try { p = cap.registerPlugin ? cap.registerPlugin("NativePlayer") : (cap.Plugins && cap.Plugins.NativePlayer); } catch (e) { return; }
    if (!p || !p.inboxStart) return;
    els.inboxBox.hidden = false;
    /* "Choose file" stays visible on TV too (needs a file manager app on the TV) */
    p.addListener("inbox", (e) => {
      const data = e && e.data ? String(e.data).trim() : "";
      if (!data) return;
      openDialog();
      if (/^https?:\/\/\S+$/i.test(data)) { els.urlInput.value = data; loadFromUrl(data, false); }
      else {
        try { loadFromText(data, { label: "Sent playlist" }); closeDialog(); openOverlay(); }
        catch (err) { setStatus(err.message || String(err), true); }
      }
    });
    els.btnInbox.addEventListener("click", async () => {
      try {
        const r = await p.inboxStart();
        els.inboxInfo.hidden = false;
        els.inboxInfo.textContent = r && r.url
          ? "On your phone (same Wi-Fi) open this address in a browser, paste the link and press Send:  " + r.url
          : "No Wi-Fi / network address found. Connect this device to your network first.";
      } catch (err) { setStatus("Could not start: " + ((err && err.message) || err), true); }
    });
  })();

  els.btnFile.addEventListener("click", () => els.fileInput.click());
  els.fileInput.addEventListener("change", () => {
    const f = els.fileInput.files && els.fileInput.files[0];
    if (f) loadFromFile(f);
    els.fileInput.value = "";
  });
  els.dlg.addEventListener("close", armHide);
  els.plDlg.addEventListener("close", armHide);

  /** From the group column into the channel list; picks the highlighted group if it is not the active one. */
  function enterChannels() {
    const g = state.groups[ui.gSel];
    if (g && g.key !== state.group) selectGroup(ui.gSel);
    ui.pane = "channels";
    paintCursor(true);
  }

  function activateCursor() {
    if (ui.pane === "bar") {
      const el = barItems()[ui.bSel];
      if (!el) return;
      el.click();
    } else if (ui.pane === "groups") {
      enterChannels();
    } else {
      const idx = state.view[ui.cSel];
      if (idx != null) { closeOverlay(); play(idx); }
    }
  }

  const infoOpen = () => !els.msgClose.hidden && !els.msg.hidden;
  function closeInfo() { setMsg(""); }
  els.msgClose.addEventListener("click", (e) => { e.stopPropagation(); closeInfo(); });

  function handleBack() {
    if (infoOpen()) { closeInfo(); return; }
    if (dialogOpen()) { closeDialog(); return; }
    const a = document.activeElement;
    if (overlayOpen() && state.items.length) { closeOverlay(); return; }
    const App = root.Capacitor && root.Capacitor.Plugins && root.Capacitor.Plugins.App;
    if (App && App.exitApp) App.exitApp();
  }

  document.addEventListener("keydown", (e) => {
    if (dialogOpen()) return;
    if (overlayOpen()) armHide();   // every remote key counts as activity: keep the lists open while browsing
    if (infoOpen() && (e.key === "Escape" || e.key === "Backspace" || e.key === "GoBack" || e.keyCode === 4 || e.key === "ArrowLeft" || e.key === "Enter" || e.key === " " || e.keyCode === 23)) {
      e.preventDefault();
      closeInfo();
      return;
    }
    const k = e.key;
    const kc = e.keyCode;
    const typing = e.target && /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName);
    if (typing) {
      if (k === "Escape" || k === "ArrowDown" || k === "ArrowUp") { e.preventDefault(); e.target.blur(); ui.pane = k === "ArrowUp" ? "bar" : "channels"; paintCursor(true); }
      else if (k === "Enter") { e.preventDefault(); e.target.blur(); ui.pane = "channels"; paintCursor(true); }
      return;
    }
    const up = k === "ArrowUp", down = k === "ArrowDown", left = k === "ArrowLeft", right = k === "ArrowRight";
    const ok = k === "Enter" || k === " " || kc === 23;
    const chUp = k === "ChannelUp" || k === "PageUp" || kc === 166;
    const chDown = k === "ChannelDown" || k === "PageDown" || kc === 167;
    const back = k === "Escape" || k === "Backspace" || k === "GoBack" || kc === 4;

    // Audio wizard open: Up/Down choose, OK selects, Back closes. Channel keys still work.
    if (audioWizOpen()) {
      if (up || down) { e.preventDefault(); awSel = clamp(awSel + (up ? -1 : 1), 0, awTracks.length - 1); paintAudioWiz(); armAudioWizHide(); return; }
      if (ok) { e.preventDefault(); pickAudio(awSel); return; }
      if (back) { e.preventDefault(); hideAudioWiz(); return; }
    }

    if (!overlayOpen()) {
      if ((up || down) && Date.now() < (ui.noZapUntil || 0)) { e.preventDefault(); }
      else if (up || chUp) { e.preventDefault(); step(-1); }
      else if (down || chDown) { e.preventDefault(); step(1); }
      else if (ui.vod && (left || right)) { e.preventDefault(); seekVod(left ? -10 : 30); }
      else if (ok || left || right || k === "ContextMenu" || k === "m" || k === "Menu") { e.preventDefault(); openOverlay(); }
      else if (back) { e.preventDefault(); handleBack(); }
      return;
    }

    if (document.body.classList.contains("empty")) {
      e.preventDefault();
      if (back) handleBack(); else if (ok) openDialog();
      return;
    }
    if (back) { e.preventDefault(); handleBack(); return; }
    if (chUp) { e.preventDefault(); step(-1); return; }
    if (chDown) { e.preventDefault(); step(1); return; }
    if (up) { e.preventDefault(); moveCursor(-1); return; }
    if (down) { e.preventDefault(); moveCursor(1); return; }
    if (left) {
      e.preventDefault();
      if (ui.pane === "bar") ui.bSel = Math.max(0, ui.bSel - 1);
      else if (ui.pane === "channels") ui.pane = "groups";
      paintCursor(true);
      return;
    }
    if (right) {
      e.preventDefault();
      if (ui.pane === "bar") ui.bSel = Math.min(barItems().length - 1, ui.bSel + 1);
      else if (ui.pane === "groups") { enterChannels(); return; }
      paintCursor(true);
      return;
    }
    if (ok) { e.preventDefault(); activateCursor(); }
  });

  // Android hardware / remote Back button (Capacitor App plugin)
  (function bindBack() {
    const App = root.Capacitor && root.Capacitor.Plugins && root.Capacitor.Plugins.App;
    if (App && App.addListener) App.addListener("backButton", handleBack);
  })();

  /* =====================================================================
   * Start-up: restore the last playlist and resume the last channel
   * ===================================================================== */
  applyAspect();

  // Show unexpected script errors instead of failing silently.
  function reportProblem(text) {
    if (dialogOpen()) setStatus(text, true); else toast(text, 8000);
  }
  window.addEventListener("error", (e) => reportProblem("Problem: " + (e.message || "unknown error")));
  window.addEventListener("unhandledrejection", (e) => reportProblem("Problem: " + ((e.reason && e.reason.message) || e.reason || "unknown error")));

  // If the app stopped in the middle of loading last time, say where.
  (async function reportLastStop() {
    const p = nativePlugin();
    if (!p || !p.lastCrumb) return;
    try {
      const r = await p.lastCrumb();
      const t = r && r.text;
      if (t && !/^ok/.test(t)) {
        p.crumb({ text: "ok (reported)" });
        openDialog();
        setStatus("The app stopped unexpectedly last time. Last step: " + t + ". Please send this text to the developer.", true);
      }
    } catch (e) { /* ignore */ }
  })();

  (function restore() {
    const bigMeta = store.get(KEY.big, null);
    const bp = bigMeta && bigPlugin();
    if (bp) {
      setBusy(true);
      bp.bigOpen().then(async (info) => {
        if (!info || !info.total) throw new Error("empty");
        await loadBig(info, bigMeta);
        setBusy(false);
        const li = store.get(KEY.lastItem, null);
        if (li && li.url) {
          const i = state.items.findIndex((it) => it.url === li.url);
          if (i >= 0) play(i);
          else { state.current = -1; ui.vod = false; setBusy(true); engine.play(li); showZap(li, 1, 1); }
        } else openOverlay();
      }).catch(() => { setBusy(false); store.del(KEY.big); openOverlay(); });
      return;
    }
    let restored = false;
    const cache = store.get(KEY.cache, null);
    if (cache && cache.text) {
      try {
        const items = parseM3U(cache.text, cache.source || undefined);
        if (items.length) { setPlaylist(items, { label: cache.label, source: cache.source, text: cache.text }); restored = true; }
      } catch (e) { /* ignore a broken cache */ }
    }
    if (restored && state.current >= 0) { play(state.current); return; }
    if (restored) return openOverlay();

    // Playlist too big to keep in storage: download the last playlist URL again.
    const lastSource = store.get(KEY.history, [])[0];
    applyFilter();
    if (lastSource && store.get(KEY.last, "")) {
      setBusy(true);
      setMsg("Loading your playlist…");
      fetchText(lastSource).then((text) => {
        const out = loadFromText(text, { source: lastSource });
        setMsg("");
        setBusy(false);
        if (!out.single && state.current >= 0) play(state.current); else openOverlay();
      }).catch((err) => {
        setBusy(false);
        setMsg("");
        openOverlay();
        toast("Couldn't load your last playlist: " + (err.message || err), 5000);
      });
      return;
    }
    openOverlay();
  })();
})(typeof window !== "undefined" ? window : globalThis);
