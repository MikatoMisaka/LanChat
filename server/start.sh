#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
MODE="domain"

case "${1:-}" in
  "") ;;
  --direct) MODE="direct" ;;
  -h|--help)
    printf 'Usage: bash start.sh [--direct]\n'
    exit 0
    ;;
  *)
    printf 'Unknown option: %s\n' "$1" >&2
    printf 'Usage: bash start.sh [--direct]\n' >&2
    exit 2
    ;;
esac

cd "$ROOT_DIR"

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT_DIR/.env.example" "$ENV_FILE"
  printf '已创建 %s，请编辑其中的域名和服务器名称后重新运行：\n' "$ENV_FILE"
  printf '  bash start.sh\n'
  exit 0
fi

command -v docker >/dev/null 2>&1 || die '未找到 Docker，请先安装 Docker。'
docker compose version >/dev/null 2>&1 ||
  die '当前 Docker 不支持 Compose V2，请安装 docker compose 插件。'

read_env() {
  awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; exit}' "$ENV_FILE"
}

CHAT_DOMAIN="$(read_env CHAT_DOMAIN)"
ADMIN_DOMAIN="$(read_env ADMIN_DOMAIN)"
SYNAPSE_SERVER_NAME="$(read_env SYNAPSE_SERVER_NAME)"
LANCHAT_PUBLIC_BASEURL="$(read_env LANCHAT_PUBLIC_BASEURL)"

[[ -n "$SYNAPSE_SERVER_NAME" ]] || die '.env 缺少 SYNAPSE_SERVER_NAME。'
[[ "$SYNAPSE_SERVER_NAME" != *'://' && "$SYNAPSE_SERVER_NAME" != */* ]] ||
  die 'SYNAPSE_SERVER_NAME 只能填写域名或域名:端口，不能包含 http://、https:// 或路径。'
[[ "$SYNAPSE_SERVER_NAME" != *[[:space:]]* ]] ||
  die 'SYNAPSE_SERVER_NAME 不能包含空格。'

if [[ "$MODE" == "domain" ]]; then
  [[ -n "$CHAT_DOMAIN" ]] || die '.env 缺少 CHAT_DOMAIN。'
  [[ -n "$ADMIN_DOMAIN" ]] || die '.env 缺少 ADMIN_DOMAIN。'
  [[ "$CHAT_DOMAIN" != "chat.example.com" ]] || die '请先在 .env 中修改 CHAT_DOMAIN。'
  [[ "$ADMIN_DOMAIN" != "admin.chat.example.com" ]] || die '请先在 .env 中修改 ADMIN_DOMAIN。'
  [[ "$SYNAPSE_SERVER_NAME" != "chat.example.com" ]] ||
    die '请先在 .env 中修改 SYNAPSE_SERVER_NAME。'
fi
if [[ "$MODE" == "direct" && -z "$LANCHAT_PUBLIC_BASEURL" ]]; then
  die '--direct 模式需要在 .env 中设置 LANCHAT_PUBLIC_BASEURL，例如 http://192.168.1.10:8080/。'
fi

if [[ ! -f "$ROOT_DIR/Caddyfile" ]]; then
  cp "$ROOT_DIR/Caddyfile.example" "$ROOT_DIR/Caddyfile"
  printf '已从 Caddyfile.example 创建 Caddyfile。\n'
fi

mkdir -p "$ROOT_DIR/synapse/data" \
  "$ROOT_DIR/data/control" \
  "$ROOT_DIR/data/caddy" \
  "$ROOT_DIR/data/caddy-config"

if command -v sudo >/dev/null 2>&1; then
  sudo chown -R 991:991 "$ROOT_DIR/synapse/data"
else
  chown -R 991:991 "$ROOT_DIR/synapse/data" 2>/dev/null ||
    die '无法设置 synapse/data 权限，请使用 root 或安装 sudo。'
fi

compose=(docker compose --env-file "$ENV_FILE" -f "$ROOT_DIR/docker-compose.yml")
if [[ "$MODE" == "direct" ]]; then
  compose+=( -f "$ROOT_DIR/docker-compose.direct.yml" )
fi

if [[ ! -f "$ROOT_DIR/synapse/data/homeserver.yaml" ]]; then
  printf '首次运行：生成 Synapse 配置。\n'
  "${compose[@]}" run --rm synapse generate
  if command -v sudo >/dev/null 2>&1; then
    sudo chown -R 991:991 "$ROOT_DIR/synapse/data"
  else
    chown -R 991:991 "$ROOT_DIR/synapse/data"
  fi
fi

"${compose[@]}" config >/dev/null
"${compose[@]}" up -d --build
"${compose[@]}" ps

printf '\nLanChat 服务已启动。\n'
if [[ "$MODE" == "direct" ]]; then
  printf '客户端地址：当前服务器 IP 加 .env 中的 LANCHAT_CONTROL_PORT（默认 8080）。\n'
else
  printf '聊天地址：https://%s\n' "$CHAT_DOMAIN"
  printf '控制室：https://%s\n' "$ADMIN_DOMAIN"
fi
printf '查看首次设置口令：\n'
printf '  %s logs control\n' "${compose[*]}"
printf '首次登录控制室后设置管理员密码，并生成新的群组邀请码。\n'
