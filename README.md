# airstar-cli

Play MKV files on your Mac, or stream them from the terminal to TVs over Google Cast (Chromecast, Google TV, and TVs with Chromecast built in) or AirPlay (Apple TV and AirPlay 1 receivers).

Many smart TVs (for example TCL Google TVs) advertise AirPlay 2 but only accept video from Apple devices. `cast` uses their Google Cast side automatically.

## Requirements

- macOS 14 or later, with Xcode or the Swift 6 toolchain
- ffmpeg: `brew install ffmpeg`

## Install

```sh
./install.sh                          # build and install to /usr/local/sbin for all users (asks for sudo)
./install.sh --prefix /usr/local/bin  # somewhere else
./install.sh --uninstall
```

`/usr/local/sbin` isn't on macOS's default PATH, so the installer adds it to `/etc/paths.d/airstar-cli`. Open a new terminal afterwards. Use `--no-path` to skip this step and `--skip-build` to reuse an existing release build. See [docs/installer-script-implementation.md](docs/installer-script-implementation.md) for details.

To build without installing, run `swift build -c release`; the binary is written to `.build/release/airstar-cli`.

## Usage

```sh
airstar-cli devices [--verbose] [--json]           # list AirPlay and Google Cast receivers
airstar-cli info movie.mkv                         # streams and the copy/transcode plan
airstar-cli play movie.mkv [--audio-lang jpn]      # play in a window on this Mac
airstar-cli cast movie.mkv -d "Living Room"        # stream to a TV (Google Cast if available, else AirPlay)
airstar-cli cast movie.mkv -d "Living Room" --via airplay
airstar-cli pair "Apple TV"                        # one-time PIN pairing (AirPlay 2 receivers)
```

| Key | Action |
| --- | --- |
| space | pause / resume |
| ← / → | seek -10 s / +10 s |
| ↑ / ↓ | seek +60 s / -60 s |
| + / - | volume |
| a | next audio track |
| q or Ctrl-C | quit (stops playback on the TV and deletes temp files) |

Useful `cast` options:

- `--audio-track N` or `--audio-lang eng` picks the audio track.
- `--force-h264` transcodes HEVC for TVs that can't play it.
- `--segment-format mpegts|fmp4` overrides the HLS segment container.
- `--port` fixes the media server port, for firewall rules.

Set `AIRSTAR_DEBUG=1` to log the AirPlay and Google Cast protocol exchanges.

## Test

```sh
swift test                  # library tests; the ffmpeg integration tests are skipped if ffmpeg isn't installed
scripts/test-install.sh     # installer tests (temporary prefix, no root needed)
```

See [docs/airplay-mkv-streaming-implementation.md](docs/airplay-mkv-streaming-implementation.md) and [docs/google-cast-implementation.md](docs/google-cast-implementation.md) for the design, the protocol details and findings from real receivers.
