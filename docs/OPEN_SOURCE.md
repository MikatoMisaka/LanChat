# Open-Source Release Checklist

## Repository

- `LICENSE` identifies LanChat as GPL-3.0-or-later.
- `README.md` describes the current client and the self-hosted server edition.
- `THIRD_PARTY_NOTICES.md` records direct software and external-service notices.
- `pubspec.lock` remains committed so dependency versions are reproducible.

## Never Commit

- `android/key.properties`
- Android keystores (`*.jks`)
- Docker `.env` files containing passwords or provider credentials
- SQLite databases, uploaded images, or user chat data
- Flutter and Gradle build caches
- Generated release folders

## Server Edition

The server edition publishes its Dockerfiles, Compose configuration, example
environment files, reverse-proxy example, control service, and deployment
documentation. Real administrator passwords, access codes, and server data
must remain outside the repository.

If a mature server such as Matrix or Prosody is used, prefer its official image
or protocol integration instead of copying its source into this repository.
Preserve all required upstream license and attribution notices.
