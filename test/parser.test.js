"use strict";
const assert = require("assert");
const { parseM3U, isHlsManifest, normalizeUrl } = require("../www/script.js");

let n = 0;
function t(name, fn) { fn(); n++; console.log("ok -", name); }

t("standard IPTV playlist with attributes", () => {
  const items = parseM3U([
    "#EXTM3U",
    '#EXTINF:-1 tvg-id="a.bd" tvg-logo="http://x/logo.png" group-title="News, Live",T Sports, HD',
    "http://host/live/1.m3u8",
    "#EXTINF:-1,Plain name",
    "https://host/2.m3u8",
  ].join("\n"));
  assert.strictEqual(items.length, 2);
  assert.deepStrictEqual(items[0], { name: "T Sports, HD", logo: "http://x/logo.png", group: "News, Live", url: "http://host/live/1.m3u8" });
  assert.strictEqual(items[1].name, "Plain name");
  assert.strictEqual(items[1].group, "");
});

t("CRLF line endings and BOM", () => {
  const items = parseM3U("﻿#EXTM3U\r\n#EXTINF:-1,One\r\nhttp://a/1.m3u8\r\n#EXTINF:-1,Two\r\nhttp://a/2.m3u8\r\n");
  assert.deepStrictEqual(items.map((i) => i.name), ["One", "Two"]);
});

t("#EXTGRP and ignored option tags", () => {
  const items = parseM3U("#EXTM3U\n#EXTINF:-1,A\n#EXTGRP:Sports\n#EXTVLCOPT:http-user-agent=X\nhttp://a/1.m3u8\n#EXTINF:-1,B\nhttp://a/2.m3u8");
  assert.strictEqual(items[0].group, "Sports");
  assert.strictEqual(items[1].group, "");
});

t("plain URL list without #EXTM3U", () => {
  const items = parseM3U("https://a/1.m3u8\n\nhttps://a/2.m3u8\n");
  assert.strictEqual(items.length, 2);
  assert.strictEqual(items[0].name, "1.m3u8");
});

t("HTML error page is not treated as a playlist", () => {
  assert.strictEqual(parseM3U("<html>\n<body>Not found</body>\n</html>").length, 0);
});

t("relative URLs resolve against the playlist URL", () => {
  const items = parseM3U("#EXTM3U\n#EXTINF:-1,Rel\nchannels/a.m3u8", "https://cdn.example.com/lists/main.m3u");
  assert.strictEqual(items[0].url, "https://cdn.example.com/lists/channels/a.m3u8");
});

t("Kodi-style |headers are split off and kept as headers", () => {
  const items = parseM3U("#EXTM3U\n#EXTINF:-1,K\nhttp://a/1.m3u8|User-Agent=Foo&Referer=http%3A%2F%2Fx");
  assert.strictEqual(items[0].url, "http://a/1.m3u8");
  assert.deepStrictEqual(items[0].headers, { "User-Agent": "Foo", Referer: "http://x" });
});

t("#EXTVLCOPT user-agent / referrer apply to the next channel only", () => {
  const items = parseM3U([
    "#EXTM3U",
    "#EXTINF:-1,A",
    "#EXTVLCOPT:http-user-agent=MyAgent/1.0",
    "#EXTVLCOPT:http-referrer=https://site.example/",
    "http://a/1.ts",
    "#EXTINF:-1,B",
    "http://a/2.ts",
  ].join("\n"));
  assert.deepStrictEqual(items[0].headers, { "User-Agent": "MyAgent/1.0", Referer: "https://site.example/" });
  assert.strictEqual(items[1].headers, undefined);
});

t("#EXTHTTP json headers", () => {
  const items = parseM3U('#EXTM3U\n#EXTINF:-1,A\n#EXTHTTP:{"Cookie":"a=b","N":1}\nhttp://a/1.m3u8');
  assert.deepStrictEqual(items[0].headers, { Cookie: "a=b" });
});

t("m3u_plus (Xtream) style with ts and mpegts urls", () => {
  const items = parseM3U([
    "#EXTM3U",
    '#EXTINF:-1 tvg-id="x" tvg-name="BBC One HD" tvg-logo="http://l/x.png" group-title="UK | News",BBC One HD',
    "http://host:8080/live/user/pass/101.ts",
    '#EXTINF:-1 tvg-id="y" group-title="UK | News",Sky',
    "http://host:8080/live/user/pass/102.m3u8",
    '#EXTINF:-1 group-title="Movies",Extensionless',
    "http://host:8080/live/user/pass/103",
  ].join("\n"));
  assert.deepStrictEqual(items.map((i) => i.url), [
    "http://host:8080/live/user/pass/101.ts",
    "http://host:8080/live/user/pass/102.m3u8",
    "http://host:8080/live/user/pass/103",
  ]);
  assert.strictEqual(items[0].group, "UK | News");
  assert.strictEqual(items[2].group, "Movies");
});

t("single HLS manifests are detected, channel lists are not", () => {
  assert.ok(isHlsManifest("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlow.m3u8"));
  assert.ok(isHlsManifest("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg1.ts"));
  assert.ok(!isHlsManifest("#EXTM3U\n#EXTINF:-1,Chan\nhttp://a/1.m3u8"));
});

t("URL normalisation", () => {
  assert.strictEqual(normalizeUrl(" example.com/list.m3u "), "https://example.com/list.m3u");
  assert.strictEqual(normalizeUrl("https://github.com/u/r/blob/main/a.m3u"), "https://raw.githubusercontent.com/u/r/main/a.m3u");
});

t("large playlist parses quickly", () => {
  const lines = ["#EXTM3U"];
  for (let i = 0; i < 50000; i++) lines.push(`#EXTINF:-1 group-title="G${i % 40}",Channel ${i}`, `http://h/${i}.m3u8`);
  const s = Date.now();
  const items = parseM3U(lines.join("\n"));
  assert.strictEqual(items.length, 50000);
  assert.ok(Date.now() - s < 2000);
});

console.log(`\n${n} tests passed`);

{
  const { parseXtreamUrl, xtreamToM3U } = require("../www/script.js");
  t("Xtream get.php link is detected", () => {
    const x = parseXtreamUrl("http://h.example:8080/get.php?username=u1&password=p%401&type=m3u_plus&output=ts");
    assert.deepStrictEqual(x, { base: "http://h.example:8080", username: "u1", password: "p@1", output: "ts" });
    assert.strictEqual(parseXtreamUrl("https://a/list.m3u"), null);
  });
  t("Xtream API data becomes a playable playlist", () => {
    const x = { base: "http://h:8080", username: "u", password: "p", output: "ts" };
    const m3u = xtreamToM3U(x, [{ category_id: "1", category_name: "News" }], [{ stream_id: 7, name: "A, B", category_id: "1", stream_icon: "http://l/x.png" }]);
    const items = parseM3U(m3u);
    assert.strictEqual(items[0].url, "http://h:8080/live/u/p/7.ts");
    assert.strictEqual(items[0].group, "News");
    assert.strictEqual(items[0].name, "A, B");
  });
  console.log(`\n${n} tests passed`);
}

{
  const { xtreamToM3U } = require("../www/script.js");
  t("Xtream API fallback includes movies", () => {
    const x = { base: "http://h:8080", username: "u", password: "p", output: "ts" };
    const items = parseM3U(xtreamToM3U(x, [], [{ stream_id: 1, name: "L" }], [{ category_id: "9", category_name: "Movies | HD" }], [{ stream_id: 55, name: "Film", category_id: "9", container_extension: "mkv" }]));
    assert.deepStrictEqual(items.map((i) => i.url), ["http://h:8080/live/u/p/1.ts", "http://h:8080/movie/u/p/55.mkv"]);
    assert.strictEqual(items[1].group, "Movies | HD");
  });
}
