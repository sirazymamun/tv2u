// Turns the freshly generated Capacitor Android project into the tv2u native-player app.
// Safe to run more than once. Runs automatically after `npx cap sync` (see package.json) and from the GitHub workflow.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const androidDir = path.join(root, "android");
const log = (m) => console.log("[tv2u] " + m);
const warn = (m) => console.log("[tv2u] WARNING: " + m);

if (!fs.existsSync(androidDir)) {
  log("android/ folder not found yet - nothing to patch.");
  process.exit(0);
}

const cfg = JSON.parse(fs.readFileSync(path.join(root, "capacitor.config.json"), "utf8"));
const pkg = cfg.appId;

/* 1. Java sources (MainActivity + native player plugin) */
const javaDir = path.join(androidDir, "app", "src", "main", "java", ...pkg.split("."));
fs.mkdirSync(javaDir, { recursive: true });
for (const f of ["MainActivity.java", "NativePlayerPlugin.java", "PlaylistInbox.java", "HttpFetch.java", "BigStore.java", "VlcFallback.java", "RecordingSaver.java"]) {
  const tpl = fs.readFileSync(path.join(here, "java", f + ".tpl"), "utf8").replaceAll("__PACKAGE__", pkg);
  fs.writeFileSync(path.join(javaDir, f), tpl);
  log("wrote " + path.relative(root, path.join(javaDir, f)));
}

/* 2. Media3 (ExoPlayer) dependencies */
const gradlePath = path.join(androidDir, "app", "build.gradle");
let gradle = fs.readFileSync(gradlePath, "utf8");
const MARK = "// tv2u-native-player";
if (!gradle.includes(MARK)) {
  gradle += `
${MARK}
dependencies {
    implementation "androidx.media3:media3-exoplayer:1.4.1"
    implementation "androidx.media3:media3-exoplayer-hls:1.4.1"
    implementation "androidx.media3:media3-exoplayer-dash:1.4.1"
    implementation "androidx.media3:media3-exoplayer-rtsp:1.4.1"
    implementation "androidx.media3:media3-exoplayer-smoothstreaming:1.4.1"
    implementation "androidx.media3:media3-datasource-okhttp:1.4.1"
    implementation "androidx.media3:media3-ui:1.4.1"
    implementation "com.squareup.okhttp3:okhttp:4.12.0"
}
`;
  fs.writeFileSync(gradlePath, gradle);
  log("added Media3 dependencies to app/build.gradle");
} else {
  log("Media3 dependencies already present");
}

/* 2b. VLC engine (second player, used only when ExoPlayer cannot play a channel). Phones and TVs are arm: skip x86 libraries to keep the APK smaller. */
gradle = fs.readFileSync(gradlePath, "utf8");
if (!gradle.includes("libvlc-all")) {
  gradle += `
// tv2u-vlc-fallback
dependencies {
    implementation "org.videolan.android:libvlc-all:3.6.0"
}
android {
    defaultConfig {
        ndk { abiFilters "armeabi-v7a", "arm64-v8a" }
    }
}
`;
  fs.writeFileSync(gradlePath, gradle);
  log("added the VLC fallback engine");
} else {
  log("VLC fallback engine already present");
}

/* 3. AndroidManifest: http streams, Android TV launcher, landscape */
const manifestPath = path.join(androidDir, "app", "src", "main", "AndroidManifest.xml");
let m = fs.readFileSync(manifestPath, "utf8");

if (!/android:largeHeap=/.test(m)) {
  m = m.replace(/<application\b/, '<application android:largeHeap="true"');
}
if (!/android:usesCleartextTraffic=/.test(m)) {
  m = m.replace(/<application\b/, '<application android:usesCleartextTraffic="true"');
  log("allowed http (cleartext) traffic");
}
if (!/android:banner=/.test(m)) {
  m = m.replace(/<application\b/, '<application android:banner="@drawable/tv_banner"');
  log("added TV banner");
}
if (!m.includes("android.software.leanback")) {
  m = m.replace(
    /<application\b/,
    '<uses-feature android:name="android.software.leanback" android:required="false" />\n' +
      '    <uses-feature android:name="android.hardware.touchscreen" android:required="false" />\n' +
      '    <application'
  );
  log("declared Android TV (leanback) support");
}
if (!m.includes("LEANBACK_LAUNCHER")) {
  const re = /<category\s+android:name="android\.intent\.category\.LAUNCHER"\s*\/>/;
  if (re.test(m)) {
    m = m.replace(re, (s) => s + '\n                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />');
    log("added Android TV launcher entry");
  } else {
    warn("LAUNCHER category not found in the manifest; the app may not appear on Android TV.");
  }
}
if (!/android:screenOrientation=/.test(m)) {
  m = m.replace(/<activity\b/, '<activity android:screenOrientation="sensorLandscape"');
  log("locked to landscape");
}
fs.writeFileSync(manifestPath, m);

/* 4. Icons + TV banner */
const resSrc = path.join(here, "res");
const resDst = path.join(androidDir, "app", "src", "main", "res");
if (fs.existsSync(resSrc)) {
  fs.cpSync(resSrc, resDst, { recursive: true, force: true });
  log("copied icons and TV banner");
}

log("done");
