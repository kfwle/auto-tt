#!/bin/bash
# TrustTunnel авто-деплой на сервер
# Использование:
#   1) Локально / прямо на сервере:
#      ./trusttunnel-auto.sh
#      ./trusttunnel-auto.sh --port 443 --user myuser --pass mypass --hostname vpn.example.com
#   2) С локальной машины через SSH:
#      ./trusttunnel-auto.sh --ssh root@1.2.3.4
#      ./trusttunnel-auto.sh --ssh root@1.2.3.4 --port 45231 --user vpn --pass xxx --hostname 1.2.3.4
#   3) Через curl (залить этот файл на gist/github raw и выполнить на сервере):
#      curl -fsSL https://твой-домен/trusttunnel-auto.sh | bash
#      curl -fsSL https://твой-домен/trusttunnel-auto.sh | bash -s -- --port 443 --user u --pass p --hostname 1.2.3.4
#
set -e

INSTALL_DIR="${INSTALL_DIR:-/opt/trusttunnel}"
ENDPOINT_REPO_INSTALL="https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh"

SSH_HOST="${SSH_HOST:-}"
LOCAL_MODE=0
ARG_PORT=""
ARG_USER=""
ARG_PASS=""
ARG_HOSTNAME=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*" >&2; }

usage() {
  cat <<EOF
TrustTunnel auto-deploy

  --ssh user@host        деплой через SSH на удалённый сервер
  --local               принудительно локальная установка (для SSH-вложенного вызова)
  --port PORT           порт endpoint (по умолчанию: рандом 10000-60000, спросит)
  --user USER           vpn-логин (по умолчанию: спросит, дефолт vpnXXXX)
  --pass PASS           vpn-пароль (по умолчанию: спросит, дефолт рандом)
  --hostname HOST       внешний IP/домен сервера (по умолчанию: автоопределение, спросит)
  -h, --help            помощь

Env (для curl | bash без интерактива):
  TT_PORT, TT_USER, TT_PASS, TT_HOSTNAME, SSH_HOST

Примеры:
  ./trusttunnel-auto.sh
  ./trusttunnel-auto.sh --ssh root@5.5.5.5
  curl -fsSL http://твой-сервер/trusttunnel-auto.sh | bash
  TT_PORT=443 TT_USER=u1 TT_PASS=p1 TT_HOSTNAME=1.2.3.4 bash trusttunnel-auto.sh
EOF
}

rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || awk 'BEGIN{srand(); print int(10000+rand()*50000)}'; }
rand_str() { tr -dc 'a-z0-9' < /dev/urandom | head -c "${1:-8}"; echo; }
rand_pass() { openssl rand -hex 12 2>/dev/null || tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; echo; }

# чтение с поддержкой curl | bash (stdin занят пайпом) -> читаем с /dev/tty
ask() {
  local prompt="$1" def="$2" var
  if [ -t 0 ]; then
    read -r -p "$prompt" var || true
  elif [ -r /dev/tty ]; then
    read -r -p "$prompt" var < /dev/tty || true
  else
    var=""
  fi
  if [ -z "$var" ]; then var="$def"; fi
  printf '%s' "$var"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh) SSH_HOST="${2:-}"; shift 2 ;;
    --local) LOCAL_MODE=1; shift ;;
    --port) ARG_PORT="${2:-}"; shift 2 ;;
    --user) ARG_USER="${2:-}"; shift 2 ;;
    --pass) ARG_PASS="${2:-}"; shift 2 ;;
    --hostname|--host) ARG_HOSTNAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) error "Неизвестный аргумент: $1"; usage; exit 1 ;;
  esac
done
# env перекрывают только если arg пустой
[ -z "$ARG_PORT" ] && ARG_PORT="${TT_PORT:-}"
[ -z "$ARG_USER" ] && ARG_USER="${TT_USER:-}"
[ -z "$ARG_PASS" ] && ARG_PASS="${TT_PASS:-}"
[ -z "$ARG_HOSTNAME" ] && ARG_HOSTNAME="${TT_HOSTNAME:-}"
[ -z "$SSH_HOST" ] && SSH_HOST="${TT_SSH:-}"

# ---------- SSH РЕЖИМ ----------
if [ -n "$SSH_HOST" ] && [ "$LOCAL_MODE" -eq 0 ]; then
  info "Режим SSH -> $SSH_HOST"

  if [ -n "$ARG_PORT" ]; then
    PORT="$ARG_PORT"
  else
    DEF_PORT="$(rand_port)"
    PORT="$(ask "Порт TrustTunnel [рандом по умолчанию $DEF_PORT]: " "$DEF_PORT")"
  fi

  if [ -n "$ARG_USER" ]; then
    VPN_USER="$ARG_USER"
  else
    DEF_USER="vpn$(rand_str 4)"
    VPN_USER="$(ask "VPN логин [по умолчанию $DEF_USER]: " "$DEF_USER")"
  fi

  if [ -n "$ARG_PASS" ]; then
    VPN_PASS="$ARG_PASS"
  else
    DEF_PASS="$(rand_pass)"
    VPN_PASS="$(ask "VPN пароль [рандом по умолчанию, Enter = сгенерировать]: " "$DEF_PASS")"
  fi

  # hostname по умолчанию = IP из SSH_HOST
  if [ -n "$ARG_HOSTNAME" ]; then
    SERVER_HOST="$ARG_HOSTNAME"
  else
    DEF_HOST="$(printf '%s' "$SSH_HOST" | rev | cut -d@ -f1 | rev | cut -d: -f1)"
    SERVER_HOST="$(ask "Внешний адрес сервера (IP/домен) [по умолчанию $DEF_HOST]: " "$DEF_HOST")"
  fi

  # валидация порта
  if ! printf '%s' "$PORT" | grep -Eq '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    error "Некорректный порт: $PORT"; exit 1
  fi

  info "Подключаюсь к $SSH_HOST, порт VPN: $PORT ..."
  SCRIPT_PATH="$0"
  if [ ! -f "$SCRIPT_PATH" ] || [ "$SCRIPT_PATH" = "bash" ]; then
    # запущено через curl | bash без файла -> качаем сами себя? требуем файл
    warn "Локальный файл скрипта не найден (\$0=$SCRIPT_PATH)."
    warn "Скачай скрипт файлом и запускай ./trusttunnel-auto.sh --ssh ... для SSH-режима."
    exit 1
  fi

  # экранируем одинарные кавычки для безопасной передачи через ssh
  esc() { printf "%s" "$1" | sed "s/'/'\\''/g"; }
  _PORT_ESC=$(esc "$PORT"); _USER_ESC=$(esc "$VPN_USER"); _PASS_ESC=$(esc "$VPN_PASS"); _HOST_ESC=$(esc "$SERVER_HOST")
  # shellcheck disable=SC2029
  ssh -t "$SSH_HOST" \
    "TT_PORT='$_PORT_ESC' TT_USER='$_USER_ESC' TT_PASS='$_PASS_ESC' TT_HOSTNAME='$_HOST_ESC' bash -s -- --local" < "$SCRIPT_PATH"
  info "Готово. Сервер: $SERVER_HOST:$PORT, логин: $VPN_USER"
  exit 0
fi

# ---------- LOCAL РЕЖИМ (установка на этом сервере) ----------
info "Локальная установка TrustTunnel endpoint в $INSTALL_DIR"

NEED_ASK=0
# если хоть один параметр не задан через args/env -> будет интерактив
if [ -z "$ARG_PORT" ] || [ -z "$ARG_USER" ] || [ -z "$ARG_PASS" ] || [ -z "$ARG_HOSTNAME" ]; then
  NEED_ASK=1
fi

DEF_PORT="$(rand_port)"
if [ -n "$ARG_PORT" ]; then
  PORT="$ARG_PORT"
else
  PORT="$(ask "Порт TrustTunnel [рандом по умолчанию $DEF_PORT, Enter = $DEF_PORT]: " "$DEF_PORT")"
fi

DEF_USER="vpn$(rand_str 4)"
if [ -n "$ARG_USER" ]; then
  VPN_USER="$ARG_USER"
else
  VPN_USER="$(ask "VPN логин [по умолчанию $DEF_USER]: " "$DEF_USER")"
fi

DEF_PASS="$(rand_pass)"
if [ -n "$ARG_PASS" ]; then
  VPN_PASS="$ARG_PASS"
else
  # показываем дефолт частично чтобы не светить? показываем полностью - удобно
  VPN_PASS="$(ask "VPN пароль [по умолчанию рандом $DEF_PASS]: " "$DEF_PASS")"
fi

if [ -n "$ARG_HOSTNAME" ]; then
  SERVER_HOST="$ARG_HOSTNAME"
else
  DETECTED_IP="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 ifconfig.io 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  [ -z "$DETECTED_IP" ] && DETECTED_IP="127.0.0.1"
  SERVER_HOST="$(ask "Внешний адрес сервера IP/домен [по умолчанию $DETECTED_IP]: " "$DETECTED_IP")"
fi

if ! printf '%s' "$PORT" | grep -Eq '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  error "Некорректный порт: $PORT"; exit 1
fi
[ -z "$VPN_USER" ] && { error "Пустой логин"; exit 1; }
[ -z "$VPN_PASS" ] && { error "Пустой пароль"; exit 1; }

echo "----------------------------------------"
info "Порт:      $PORT"
info "Логин:     $VPN_USER"
info "Хост:      $SERVER_HOST"
info "Пароль:    [скрыт, покажу в конце]"
echo "----------------------------------------"

# занят ли порт?
if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":$PORT "; then
  warn "Порт $PORT уже слушается! Продолжаю, но endpoint может не стартовать."
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else error "Нужен root или sudo"; exit 1; fi
fi

info "1/6 Ставлю endpoint через curl (официальный install.sh)..."
# shellcheck disable=SC2086
curl -fsSL "$ENDPOINT_REPO_INSTALL" | sh -s -- ${INSTALL_DIR:+ -o "$INSTALL_DIR"} || {
  error "Не удалось установить endpoint"; exit 1
}

if [ ! -x "$INSTALL_DIR/setup_wizard" ]; then
  # install.sh при -o /opt/trusttunnel кладёт в /opt/trusttunnel ?
  # fallback: ищем бинарник
  if [ -x "/opt/trusttunnel/setup_wizard" ]; then INSTALL_DIR="/opt/trusttunnel";
  else error "setup_wizard не найден в $INSTALL_DIR"; ls -la "$INSTALL_DIR" || true; exit 1; fi
fi

info "2/6 Генерирую конфиг (non-interactive, self-signed, 0.0.0.0:$PORT)..."
cd "$INSTALL_DIR"
# останавливаем старый чтобы пересоздать конфиг чисто
$SUDO systemctl stop trusttunnel 2>/dev/null || true

$SUDO ./setup_wizard -m non-interactive \
  -a "0.0.0.0:$PORT" \
  -c "$VPN_USER:$VPN_PASS" \
  -n "$SERVER_HOST" \
  --lib-settings vpn.toml \
  --hosts-settings hosts.toml \
  --cert-type self-signed

info "3/6 Открываю фаервол (TCP+UDP $PORT, QUIC нужен UDP)..."
if command -v ufw >/dev/null 2>&1; then
  $SUDO ufw allow "$PORT/tcp" 2>/dev/null || true
  $SUDO ufw allow "$PORT/udp" 2>/dev/null || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  $SUDO firewall-cmd --permanent --add-port="$PORT/tcp" 2>/dev/null || true
  $SUDO firewall-cmd --permanent --add-port="$PORT/udp" 2>/dev/null || true
  $SUDO firewall-cmd --reload 2>/dev/null || true
elif command -v iptables >/dev/null 2>&1; then
  $SUDO iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || $SUDO iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT || true
  $SUDO iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || $SUDO iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT || true
else
  warn "Фаервол не найден, пропускаю (проверь Security Group у хостера!)."
fi

info "4/6 Включаю systemd-сервис..."
if [ -f "$INSTALL_DIR/trusttunnel.service.template" ]; then
  $SUDO cp "$INSTALL_DIR/trusttunnel.service.template" /etc/systemd/system/trusttunnel.service
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now trusttunnel
  sleep 3
  $SUDO systemctl restart trusttunnel 2>/dev/null || true
  sleep 2
else
  warn "Нет trusttunnel.service.template, запускаю вручную (tmux/systemd сам)."
fi

info "5/6 Проверяю (systemd + порт + curl)..."
$SUDO systemctl is-active --quiet trusttunnel && info "systemd: active" || warn "systemd: НЕ active, смотри journalctl -u trusttunnel -e"
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | grep -q ":$PORT " && info "TCP $PORT: слушается" || warn "TCP $PORT: НЕ слушается"
  ss -ulnp 2>/dev/null | grep -q ":$PORT " && info "UDP $PORT: слушается" || warn "UDP $PORT: НЕ слушается (QUIC может не работать)"
fi
# curl-проверка: TLS handshake должен пройти (код 407/404/403 - норм, главное не 000)
CURL_CODE="$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 8 "https://127.0.0.1:$PORT/" 2>/dev/null || echo 000)"
if [ "$CURL_CODE" = "000" ]; then
  warn "curl -k https://127.0.0.1:$PORT/ не соединился (000). Смотри логи: journalctl -u trusttunnel -e"
else
  info "curl -k https://127.0.0.1:$PORT/ -> HTTP $CURL_CODE (TLS работает, это норм для VPN-порта)"
fi

info "6/6 Экспортирую клиентский конфиг..."
DEEPLINK="$($SUDO ./trusttunnel_endpoint vpn.toml hosts.toml -c "$VPN_USER" -a "$SERVER_HOST:$PORT" --format deeplink 2>/dev/null || true)"
if [ -z "$DEEPLINK" ]; then
  DEEPLINK="$($SUDO ./trusttunnel_endpoint vpn.toml hosts.toml -c "$VPN_USER" -a "$SERVER_HOST:$PORT" 2>/dev/null || true)"
fi
$SUDO ./trusttunnel_endpoint vpn.toml hosts.toml -c "$VPN_USER" -a "$SERVER_HOST:$PORT" --format toml > "/tmp/tt-$VPN_USER.toml" 2>/dev/null || true
$SUDO chmod 644 "/tmp/tt-$VPN_USER.toml" 2>/dev/null || true
$SUDO cp "/tmp/tt-$VPN_USER.toml" "./client-$VPN_USER.toml" 2>/dev/null || cp "/tmp/tt-$VPN_USER.toml" "./client-$VPN_USER.toml" || true

INFO_FILE="$HOME/trusttunnel-info.txt"
{
  echo "TrustTunnel $SERVER_HOST:$PORT"
  echo "date: $(date -u)"
  echo "host: $SERVER_HOST"
  echo "port: $PORT"
  echo "user: $VPN_USER"
  echo "pass: $VPN_PASS"
  echo ""
  echo "deeplink:"
  echo "$DEEPLINK"
  echo ""
  echo "curl-check: curl -k -v https://$SERVER_HOST:$PORT/  (жди 407/TLS ok)"
} > "$INFO_FILE" 2>/dev/null || true

echo ""
echo "============================================"
echo -e "${GREEN} ГОТОВО TrustTunnel на $SERVER_HOST:$PORT${NC}"
echo "============================================"
echo "Хост:   $SERVER_HOST"
echo "Порт:   $PORT (TCP+UDP)"
echo "Логин:  $VPN_USER"
echo "Пароль: $VPN_PASS"
echo ""
echo "Deep-link (для Flutter/CLI клиента):"
echo "$DEEPLINK"
echo ""
echo "TOML конфиг: $INSTALL_DIR/client-$VPN_USER.toml + /tmp/tt-$VPN_USER.toml"
[ -f "./client-$VPN_USER.toml" ] && echo "--- client-$VPN_USER.toml ---" && head -n 40 "./client-$VPN_USER.toml"
echo ""
echo "Проверка через curl (должно соединиться по TLS, HTTP 407/404 - ок):"
echo "  curl -k -v https://$SERVER_HOST:$PORT/"
echo "  curl -k -s -o /dev/null -w '%{http_code}' https://$SERVER_HOST:$PORT/"
echo ""
echo "Логи: journalctl -u trusttunnel -f"
echo "Инфо сохранено: $INFO_FILE"
echo "============================================"
