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

python - "$CONFIG" <<'PY'
import os
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
replacement = 'max_upload_size: 500M'
pattern = re.compile(r'(?m)^max_upload_size:\s*.*$')
if pattern.search(text):
    text = pattern.sub(replacement, text, count=1)
else:
    text = re.sub(
        r'(?m)^(server_name:\s*.*)$',
        r'\1\n\n' + replacement,
        text,
        count=1,
    )

def set_scalar(source, key, value):
    expression = re.compile(rf'(?m)^{re.escape(key)}:\s*.*$')
    line = f'{key}: {value}'
    if expression.search(source):
        return expression.sub(line, source, count=1)
    return source.rstrip() + f'\n{line}\n'

def set_nested_scalar(source, section, key, value):
    section_match = re.search(
        rf'(?m)^{re.escape(section)}:\s*$\n',
        source,
    )
    if section_match is None:
        return source.rstrip() + f'\n{section}:\n  {key}: {value}\n'
    start = section_match.end()
    next_section = re.search(r'(?m)^[^ \t#][^:\n]*:\s*.*$', source[start:])
    end = start + next_section.start() if next_section else len(source)
    block = source[start:end]
    key_match = re.search(rf'(?m)^  {re.escape(key)}:\s*.*$', block)
    if key_match:
        block = block[:key_match.start()] + f'  {key}: {value}' + block[key_match.end():]
    else:
        block = f'  {key}: {value}\n' + block
    return source[:start] + block + source[end:]

public_baseurl = os.environ.get('LANCHAT_PUBLIC_BASEURL', '').strip()
if not public_baseurl:
    chat_domain = os.environ.get('CHAT_DOMAIN', '').strip()
    if chat_domain:
        public_baseurl = f'https://{chat_domain}/'
if public_baseurl:
    text = set_scalar(text, 'public_baseurl', repr(public_baseurl))
text = set_scalar(text, 'enable_registration', 'false')
text = set_nested_scalar(text, 'user_directory', 'enabled', 'true')
text = set_nested_scalar(text, 'user_directory', 'search_all_users', 'true')
if not re.search(r'(?m)^retention:\s*$', text):
    text += (
        '\nretention:\n'
        '  enabled: true\n'
        '  default_policy:\n'
        '    min_lifetime: 1d\n'
        '    max_lifetime: 30d\n'
    )
if not re.search(r'(?m)^media_retention:\s*$', text):
    text += (
        '\nmedia_retention:\n'
        '  local_media_lifetime: 30d\n'
        '  remote_media_lifetime: 30d\n'
    )
path.write_text(text, encoding='utf-8')
PY

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
import urllib.error
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
try:
    with urllib.request.urlopen(request, timeout=15) as response:
        result = json.load(response)
except urllib.error.HTTPError as error:
    if error.code in (401, 403, 404):
        sys.exit(1)
    raise
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
