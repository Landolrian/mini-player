# Mini Player for Amazon Music (Mac)

A small, always-on-top player for the **Amazon Music desktop app** on macOS. Pin it over anything, make it as big or as small as you want, and pick your own colors.

> **Unofficial.** Not made by, endorsed by, or affiliated with Amazon. It works by talking to the Amazon Music app's own web interface, so an Amazon Music update can break it at any time.

## What it does

- **Stays on top** of your other windows when pinned 📌 — click the pin again to let it act like a normal window.
- **Resize freely** — from a tiny one-line bar up to a big window with your whole queue.
- **Colors** 🎨 — 8 ready-made looks, sliders for your own, and a see-through slider.
- **Play / pause / skip / back / shuffle / repeat**, with album art and a progress bar.
- **Your queue** — scroll through the playlist you're listening to and click any song to play it.
  - **Play next** puts a song right after the current one.
  - **Add to queue** lines songs up in the order you add them (#1, #2, #3…), instead of dumping them at the end.
- **Find new music** ✨ — suggests songs that *aren't* in your playlist yet, with a short reason for each pick. Play, play next, or queue them right from the list. (How it picks: Mini Player has a built-in map of which artists sound alike, across lots of genres. It looks at the artists in what you're playing, picks related artists you don't have yet, and finds their songs through Amazon Music's own search. If your playlist's artists aren't in the map, it suggests other songs by the artists you already have. No AI service, account, or internet beyond Amazon Music is involved.)
- **Add to playlist** ➕ — add the current song (or any song, by right-clicking) to one of your playlists. Already in there? It tells you instead of adding a duplicate.
- **Optional "master" playlist** — choose one playlist that every added song also goes into (right-click → *Also add every song to…*).

## Install

1. You need **macOS 14 (Sonoma) or newer** and the **Amazon Music app** from amazon.com/music.
2. Download **Mini-Player.zip** from the [latest release](../../releases/latest), unzip it, and drag **Mini Player** into your Applications folder.
3. The first time you open it, macOS will say it can't verify the app (it isn't from the App Store and isn't signed by a paid Apple developer account). Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
4. Open **Mini Player** instead of Amazon Music — it opens Amazon Music for you and connects.
   If Amazon Music was already open, press **Connect**: Amazon Music restarts once (your music pauses for a few seconds).

## ⚠️ Please read: how it connects

To control Amazon Music, Mini Player starts it with a **local remote-control port** (Chrome's DevTools port 9333). That port only listens on your own Mac (`127.0.0.1`) and can't be reached from the internet, **but while Amazon Music runs this way, any program on your Mac could use it to control Amazon Music or read what it shows**. If that's not OK for you, don't use this app. Opening Amazon Music normally (without Mini Player) turns the port off again.

No admin rights, Accessibility access, or extra drivers are needed.

## Build it yourself

```sh
git clone https://github.com/Landolrian/mini-player.git
cd mini-player
./build.sh          # builds and installs to ~/Applications/Mini Player.app
```

Needs the Xcode command-line tools (`xcode-select --install`). The whole app is one file, `MiniPlayer.swift`.

## Like it?

It's free. If it makes your day a little better, you can [tip me on Venmo ☕](https://venmo.com/u/LandonHopkins1) — totally optional.

## License

MIT — see [LICENSE](LICENSE).
