"use strict";
const assert = require("assert");
const { httpGet, headerValue } = require("../www/script.js");

let n = 0;
async function t(name, fn) { await fn(); n++; console.log("ok -", name); }

(async () => {
  await t("headerValue is case-insensitive", async () => {
    assert.strictEqual(headerValue({ Location: "http://x" }, "location"), "http://x");
    assert.strictEqual(headerValue({ location: "http://y" }, "Location"), "http://y");
    assert.strictEqual(headerValue(null, "location"), "");
  });

  await t("sends a default User-Agent and merges custom headers", async () => {
    let seen;
    const call = async (o) => { seen = o; return { status: 200, data: "ok", headers: {} }; };
    const res = await httpGet(call, "http://a/list.m3u", { Referer: "http://r" }, "text", 1000);
    assert.strictEqual(res.status, 200);
    assert.ok(/Mozilla/.test(seen.headers["User-Agent"]));
    assert.strictEqual(seen.headers.Referer, "http://r");
    assert.strictEqual(seen.responseType, "text");
    assert.strictEqual(seen.disableRedirects, true);
  });

  await t("a custom User-Agent replaces the default", async () => {
    let seen;
    const call = async (o) => { seen = o; return { status: 200, data: "", headers: {} }; };
    await httpGet(call, "http://a/x", { "User-Agent": "VLC/3" }, "text");
    assert.strictEqual(seen.headers["User-Agent"], "VLC/3");
  });

  await t("follows http -> https and relative redirects", async () => {
    const urls = [];
    const call = async (o) => {
      urls.push(o.url);
      if (o.url === "http://a/list") return { status: 302, headers: { Location: "https://a/list2" } };
      if (o.url === "https://a/list2") return { status: 301, headers: { location: "/final.m3u" } };
      return { status: 200, data: "#EXTM3U", headers: {} };
    };
    const res = await httpGet(call, "http://a/list", {}, "text");
    assert.deepStrictEqual(urls, ["http://a/list", "https://a/list2", "https://a/final.m3u"]);
    assert.strictEqual(res.finalUrl, "https://a/final.m3u");
    assert.strictEqual(res.data, "#EXTM3U");
  });

  await t("gives up on redirect loops", async () => {
    const call = async () => ({ status: 302, headers: { Location: "http://a/loop" } });
    await assert.rejects(() => httpGet(call, "http://a/loop", {}, "text"), /redirects/);
  });

  await t("passes HTTP error codes back to the caller", async () => {
    const call = async () => ({ status: 403, data: "", headers: {} });
    const res = await httpGet(call, "http://a/x", {}, "text");
    assert.strictEqual(res.status, 403);
  });

  console.log(`\n${n} tests passed`);
})().catch((e) => { console.error(e); process.exit(1); });

(async () => {
  const { fetchViaPlugin } = require("../www/script.js");
  const big = "#EXTM3U\n" + "é".repeat(1000000);
  let done = false;
  const plugin = {
    fetchStart: async () => ({ id: "d1" }),
    fetchRead: async ({ offset, length }) => ({ text: big.slice(offset, offset + length), done: offset + length >= big.length }),
    fetchDone: async () => { done = true; },
  };
  const out = await fetchViaPlugin(plugin, "http://x", "playlist", ["a"]);
  require("assert").strictEqual(out, big);
  require("assert").ok(done);
  console.log("ok - chunked native download reassembles a 1M-character playlist");
})().catch((e) => { console.error(e); process.exit(1); });
