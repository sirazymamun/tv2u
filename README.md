# tv2u (Android phone + Android TV)

Full-screen IPTV player. The video always fills the screen with no on-screen player controls. Groups and channels appear as a list on top of the running video when you tap the screen (or press OK on a remote).

- Playlists over **http and https**: `.m3u`, `.m3u8`, `m3u_plus` (Xtream `get.php?...type=m3u_plus`), from a URL, a file, or pasted text.
- Streams: **HLS (.m3u8), MPEG-TS (.ts / mpegts), MP4/MKV, DASH, RTSP**, with extension-less links handled too. Playback uses Android's native ExoPlayer, so it works like other IPTV apps (redirects, http streams, per-channel User-Agent/Referer from the playlist).
- **Android TV** launcher entry, remote control support, text scales with the screen.
- Search, favourites, last channel resumes on start, 40,000+ channel playlists are fine.

## Controls

| | Touch | TV remote / keyboard |
|---|---|---|
| Show / hide lists | tap the video | OK / Enter (Back hides) |
| Next / previous channel | | Up / Down (lists hidden) or CH+ / CH- |
| Pick group | tap | Left, then Up / Down |
| Pick channel | tap | Right (or Enter) on a group, then Up / Down, OK |
| Favourite | tap the star | Right on a channel |
| Playlist / Aspect / Reload / Search | top bar | Up from the top of a list, then Left / Right, OK |

The picture always fills the whole screen (stretch).
Use **Playlist > Play as stream** to open a single live `.ts` / `.m3u8` link directly.

## Typing links on a TV
On a TV, open **Playlist > Send from phone**. It shows an address; open it in your phone browser (same Wi-Fi), paste the link, press Send.

## Movies and series
Movies and series entries play like channels. While one is playing (lists hidden): Left = back 10 s, Right = forward 30 s. Up/Down switch item.

## Very large playlists (100 MB+)
Playlists over 6 MB are downloaded to a file and indexed into an on-device database; the screen only loads the group or search results you are looking at (500 at a time, more as you scroll). Memory use stays small. Groups: ▸ Live TV / Movies / Series appear when a playlist has several kinds.

## Big or Xtream playlists
Downloads run natively (progress shown), with player-like User-Agents; for Xtream `get.php` links the app falls back to the account login (`player_api.php`) like Televizo.

## Smooth playback
Playback uses Media3 ExoPlayer with OkHttp networking, hardware decoding, and a 15-50 s buffer cushion (starts after 0.8 s). **Info** shows the decoder in use, dropped frames, connection speed and buffer, which tells you whether lag comes from the device or the network.

## If a channel will not play
Tap **Info** in the top bar while the channel is selected. It shows the video/audio formats of the stream, whether this device can decode them, and the last error. Slow-starting streams get up to 40 s, refused requests (HTTP 401/403/406) are retried with other User-Agents, and a warning appears if a codec is unsupported.

## Build the APK

### Option A: GitHub builds it (no installs)
1. Upload everything in this folder to your GitHub repository (replace old files). Keep the `www`, `native` and `.github` folders.
2. **Actions** tab > **Build APK** > **Run workflow**.
3. When it finishes (about 5-8 min), download the **tv2u-apk** artifact and unzip it for `app-debug.apk`.

### Option B: on your computer
Needs Node 20+, JDK 21 and Android Studio (for the Android SDK).
```
npm install
npx cap add android
npx cap sync android
node native/apply.mjs
cd android && ./gradlew assembleDebug
```
APK: `android/app/build/outputs/apk/debug/app-debug.apk`.

### Install
Copy the APK to the phone or TV and open it. Allow "install unknown apps" if asked. On Android TV, a file-manager app (or `adb install`) is the easiest way.

## How it works
`native/apply.mjs` runs after the Android project is generated. It adds the native player (`native/java/`), the Media3 libraries, http (cleartext) permission, the Android TV launcher entry, landscape lock, the app icon and the TV banner. The web UI in `www/` is drawn over the video with a transparent background.

`npm test` runs the playlist parser and native-HTTP helper tests.

## Second player (VLC engine)

If ExoPlayer cannot play a channel (decoder failure such as 4K HEVC on a weak device, unsupported container, no picture after 30 s, refused stream), the app tries the same channel once with the VLC engine (`libvlc-all`), which has its own software decoders. The picture is still stretched to fill the screen. Info shows "Player: VLC engine (fallback)" when it is active. The APK is larger because of this library (arm and arm64 only).

## Audio language wizard

When a channel has several audio tracks (for example English, Bengali, Hindi, Tamil, Telugu), a small "Audio language" panel appears at the bottom right of the picture by itself. Up/Down and OK choose a track, Back closes it, and it also closes after 15 seconds. Tapping a language selects it directly. The panel shows once per channel, not again when the picture or sound is re-reported after you pick. The list comes from ExoPlayer (or VLC when the fallback is active).

## Recording

The **Record** button (between "tv2u" and "Playlist") starts recording the running channel or movie, picture and sound together, for any length. Press it again to stop and save (the lists close so you see the video). While recording, the button shows "■ Stop" with a timer and a red "● REC" badge appears. The recording is a copy of the data already being downloaded for playback (no second connection to the server). Changing channel stops and saves it.

Files are saved on the device: Movies/tv2u on Android 10+, otherwise in the app's own Movies/Music folder.
- Video: MP4 (H.264/H.265 + AAC). If the channel's sound can't be put into an MP4 (MPEG audio L2, AC3 ...) the original .ts file is saved instead, so the sound is kept.
Recording works with ExoPlayer; with the VLC fallback it relies on VLC's recorder.

Recorded files are named by the start time: dd-MM-yy_HH-mm (for example 10-10-26_04-20.mp4). Android does not allow ":" in file names, so the time uses a dash.

Switching to the VLC engine is kept quick: the VLC engine is loaded in the background at start-up, ExoPlayer waits only 10 seconds for a first picture (and 3 load retries), and a channel whose picture or sound this device can't decode is handed over immediately, without waiting for a decoder error.

## Playlists and "Send from phone"

My playlists keeps at most **3** playlists (newest first). Adding a fourth replaces the oldest. "Send from phone" runs one small web server for the whole app; if its port (8686) is already taken it uses the next free one and shows the address on screen, so the "address already in use" error can no longer block adding a playlist.
