# LanChat

LanChat is a privacy-oriented Flutter chat application for Android and
Windows. It focuses on direct communication inside a local network, with
secure pairing, encrypted messages, large-file transfer, and a calm green and
warm-white interface.

## Current Features

- LAN device discovery through multicast, broadcast, and manual fallback.
- Six-digit confirmation before a device is trusted.
- Authenticated X25519 key agreement and ChaCha20-Poly1305 message frames.
- Text, image, and file messages over the local network.
- Confirm-before-receive file offers with a 5 GiB file limit.
- Chunked transfer with resumable transfer records.
- Windows text selection, copy/paste, and multi-file drag and drop.
- Full-screen image preview with zoom, save, and share actions.
- Emoji, recent stickers, favorites, custom stickers, and an online sticker tab.

## Build

Install Flutter and the platform toolchains, then run:

```text
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

The Android release build expects a local `android/key.properties` file and a
keystore. Copy `android/key.properties.example`, keep the real file out of Git,
and never publish the keystore.

## Planned Server Edition

The planned server edition will include all LAN features and add a separate
server tab for self-hosted remote text and image messaging. Large files will
remain LAN-only. The server implementation and Docker deployment files will be
added under `server/` after the server backend has been evaluated against the
project requirements.

## Third-Party Content

Online sticker metadata and images are fetched from PigHub. Their content and
service terms are separate from this project. See
`THIRD_PARTY_NOTICES.md` for software dependency licenses.

## License

LanChat source code is licensed under the GNU General Public License version 3
or any later version. See `LICENSE`.

Third-party dependencies retain their own licenses and are not relicensed by
this notice.
