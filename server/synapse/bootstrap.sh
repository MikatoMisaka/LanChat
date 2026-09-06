#!/bin/sh
set -eu

CONTROL_DIR=/control
CONFIG=/data/homeserver.yaml
PASSWORD_FILE="$CONTROL_DIR/matrix-admin-password"
TOKEN_FILE="$CONTROL_DIR/matrix-admin-token"

if [ ! -f "$CONFIG" ]; then
  echo "Synapse configuration is missing: $CONFIG" >&2
  exit 1
fi

umask 077
mkdir -p "$CONTROL_DIR"

if ! grep -Eq '^[[:space:]]*registration_shared_secret:' "$CONFIG"; then
  secret="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
  printf '\nregistration_shared_secret: "%s"\n' "$secret" >> "$CONFIG"
fi

if [ ! -s "$PASSWORD_FILE" ]; then
  python -c 'import secrets; print(secrets.token_urlsafe(32))' > "$PASSWORD_FILE"
fi

login_admin() {
  python - "$PASSWORD_FILE" "$TOKEN_FILE" <<'PY'
import json
import os
import sys
import urllib.request

password_path, token_path = sys.argv[1:]
with open(password_path, encoding='utf-8') as handle:
    password = handle.read().strip()
payload = json.dumps({
    'type': 'm.login.password',
    'identifier': {'type': 'm.id.user', 'user': 'lanchat-control'},
    'password': password,
    'initial_device_display_name': 'LanChat control service',
}).encode('utf-8')
request = urllib.request.Request(
    'http://synapse:8008/_matrix/client/v3/login',
    data=payload,
    headers={'content-type': 'application/json'},
)
with urllib.request.urlopen(request, timeout=15) as response:
    result = json.load(response)
token = result.get('access_token')
if not isinstance(token, str) or not token:
    raise RuntimeError('Synapse did not return an access token.')
temporary = token_path + '.tmp'
with open(temporary, 'w', encoding='utf-8') as handle:
    handle.write(token)
os.replace(temporary, token_path)
PY
}

if ! login_admin; then
  register_new_matrix_user \
    http://synapse:8008 \
    -c "$CONFIG" \
    -u lanchat-control \
    -p "$(cat "$PASSWORD_FILE")" \
    -a
  login_admin
fi

echo "LanChat internal Matrix bridge is ready."
