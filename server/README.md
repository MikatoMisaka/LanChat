# LanChat Server Edition

This directory contains the self-hosted server edition deployment files.

The server edition retains the LAN P2P client features and adds remote text and
image messaging, account login, friend requests, Matrix-backed offline sync,
local notifications while the app process is alive, and an administrator web
console. Large-file transfer remains LAN-only.

Remote chat uses the official Matrix/Synapse server. LanChat's Dart control
service adds access-code validation, administrator configuration, quotas,
statistics, and Synapse user administration. Notifications are generated
locally by the running client; no external push service is required.

## First deployment

1. Create DNS `A`/`AAAA` records for the chat and admin domains.
2. Create `.env` from `.env.example` and replace every bootstrap placeholder.
3. Create `Caddyfile` from `Caddyfile.example`.
4. On Linux, create the bind-mount directories and give Synapse write access:

   ```text
   mkdir -p synapse/data data/control data/caddy data/caddy-config
   sudo chown -R 991:991 synapse/data
   ```

5. Generate the Synapse configuration and signing keys:

   ```text
   docker compose --env-file .env run --rm synapse generate
   ```

6. Review `synapse/data/homeserver.yaml`, set `public_baseurl`, disable public
   registration, enable user-directory search, limit media uploads to 20 MB,
   and configure the 30-day `retention` and `media_retention` policies.
7. Start the stack:

   ```text
   docker compose --env-file .env up -d --build
   ```

The chat domain serves Matrix and LanChat client endpoints. The admin domain
serves the administrator console.

## First administrator

The control console uses a separate administrator password from the client
access code. To create the first Synapse administrator, temporarily add a
`registration_shared_secret` to the generated homeserver configuration and run:

```text
docker compose --env-file .env exec synapse register_new_matrix_user http://localhost:8008 -c /data/homeserver.yaml -a
```

Remove the temporary shared secret and restart Synapse. Log in to the new admin
account through the Matrix `/login` API or a Matrix client, place its access
token in `SYNAPSE_ADMIN_TOKEN` in `.env`, and rebuild/restart the control service.
The web console can then create, reset, deactivate, and revoke ordinary users'
devices.

Build the server edition client from the repository root with:

```text
.\tooling\flutter-local-rust.ps1 build apk --release --dart-define=LANCHAT_SERVER_EDITION=true
```
