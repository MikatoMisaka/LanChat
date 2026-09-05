# Third-Party Notices

LanChat is distributed under GPL-3.0-or-later for the project code. Third-party
packages, native libraries, and services retain their own licenses. The exact
resolved versions are recorded in `pubspec.lock`.

The following direct dependencies are used by the current Flutter client. The
license names below follow the package metadata available when this notice was
prepared; consult each linked package before redistributing a modified build.

| Component | License | Source |
| --- | --- | --- |
| Flutter SDK | BSD-3-Clause | https://github.com/flutter/flutter |
| cupertino_icons | MIT | https://pub.dev/packages/cupertino_icons |
| http | BSD-3-Clause | https://pub.dev/packages/http |
| sqflite | BSD-2-Clause | https://pub.dev/packages/sqflite |
| sqflite_common_ffi | BSD-2-Clause | https://pub.dev/packages/sqflite_common_ffi |
| path_provider | BSD-3-Clause | https://pub.dev/packages/path_provider |
| path_provider_android | BSD-3-Clause | https://pub.dev/packages/path_provider_android |
| file_picker | MIT | https://pub.dev/packages/file_picker |
| image_picker | BSD-3-Clause | https://pub.dev/packages/image_picker |
| qr_flutter | MIT | https://pub.dev/packages/qr_flutter |
| mobile_scanner | BSD-3-Clause | https://pub.dev/packages/mobile_scanner |
| uuid | MIT | https://pub.dev/packages/uuid |
| shared_preferences | BSD-3-Clause | https://pub.dev/packages/shared_preferences |
| share_plus | BSD-3-Clause | https://pub.dev/packages/share_plus |
| path | MIT | https://pub.dev/packages/path |
| intl | BSD-3-Clause | https://pub.dev/packages/intl |
| cryptography | Apache-2.0 | https://pub.dev/packages/cryptography |
| crypto | BSD-3-Clause | https://pub.dev/packages/crypto |
| desktop_drop | Apache-2.0 | https://pub.dev/packages/desktop_drop |
| gal | BSD-3-Clause | https://pub.dev/packages/gal |

## Native and External Services

- Android ML Kit is used by `mobile_scanner` through the declared Android
  dependency. Its terms are provided by Google and remain separate from this
  project license.
- PigHub is an external online sticker service. Its API, metadata, and image
  content are not part of the LanChat copyright grant. Users and distributors
  must follow PigHub's current terms.
- Android, Windows, SQLite, and other operating-system components are system
  libraries and retain their respective licenses.

## License Verification

Before publishing a binary release, re-check the resolved package metadata and
native plugin licenses. Do not add a dependency with incompatible terms without
updating this file and reviewing the release license model.
