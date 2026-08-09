#!/bin/bash
# Zentra: полная настройка VPS с нуля.
# Ставит 3x-ui + Xray, создаёт VLESS-Reality, настраивает firewall,
# fail2ban и автообновления, затем печатает готовую ссылку для клиента.
#
# Скрипт идемпотентный: повторный запуск не ломает уже настроенный сервер.
# Итог печатается между маркерами ZENTRA_RESULT_BEGIN / ZENTRA_RESULT_END.

set -uo pipefail

PANEL_PORT="${PANEL_PORT:-2053}"
VPN_PORT="${VPN_PORT:-443}"
REALITY_DEST="${REALITY_DEST:-www.microsoft.com}"
CLIENT_NAME="${CLIENT_NAME:-zentra-1}"

log() { echo "[zentra] $*"; }
fail() { echo "[zentra][ОШИБКА] $*" >&2; exit 1; }

# --- 1. Проверки окружения -------------------------------------------------

[ "$(id -u)" -eq 0 ] || fail "нужны права root"

if [ ! -f /etc/os-release ]; then
    fail "неизвестная ОС: нет /etc/os-release"
fi
. /etc/os-release
case "${ID:-}" in
    debian|ubuntu) log "ОС: ${PRETTY_NAME}" ;;
    *) fail "поддерживаются только Debian и Ubuntu, найдено: ${PRETTY_NAME:-неизвестно}" ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64|aarch64|arm64) : ;;
    *) fail "неподдерживаемая архитектура: $ARCH" ;;
esac

export DEBIAN_FRONTEND=noninteractive

# --- 2. Базовые пакеты -----------------------------------------------------

log "обновляю списки пакетов"
apt-get update -qq || fail "apt-get update не выполнился"

log "ставлю базовые пакеты"
apt-get install -y -qq curl wget tar jq sqlite3 ufw fail2ban unattended-upgrades \
    ca-certificates openssl >/dev/null || fail "не удалось поставить базовые пакеты"

# --- 3. Автообновления безопасности ----------------------------------------

log "включаю автообновления"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CFG'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CFG
systemctl enable --now unattended-upgrades >/dev/null 2>&1

# --- 4. Firewall -----------------------------------------------------------

log "настраиваю firewall"
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow "${VPN_PORT}"/tcp >/dev/null
ufw allow "${PANEL_PORT}"/tcp >/dev/null
ufw --force enable >/dev/null || fail "ufw не включился"

# --- 5. Fail2Ban -----------------------------------------------------------

log "настраиваю fail2ban"
cat > /etc/fail2ban/jail.d/zentra-sshd.conf <<'CFG'
[sshd]
enabled = true
port = ssh
maxretry = 4
findtime = 600
bantime = 3600
CFG
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban >/dev/null 2>&1

# --- 6. Установка 3x-ui ----------------------------------------------------

if systemctl is-active --quiet x-ui; then
    log "3x-ui уже установлен, установку пропускаю"
else
    log "ставлю 3x-ui (это занимает 1-2 минуты)"
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) >/tmp/zentra-xui-install.log 2>&1 \
        || fail "установка 3x-ui не удалась, лог: /tmp/zentra-xui-install.log"
fi

systemctl is-active --quiet x-ui || fail "служба x-ui не запустилась"

XUI_BIN="/usr/local/x-ui/x-ui"
XRAY_BIN="$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -1)"
[ -x "$XRAY_BIN" ] || fail "не найден бинарник xray"

# --- 7. Учётные данные панели ----------------------------------------------

PANEL_USER="zentra-$(openssl rand -hex 3)"
PANEL_PASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
PANEL_PATH="/$(openssl rand -hex 8)/"

log "задаю доступ к панели"
"$XUI_BIN" setting -username "$PANEL_USER" -password "$PANEL_PASS" >/dev/null 2>&1 \
    || fail "не удалось задать логин и пароль панели"
"$XUI_BIN" setting -port "$PANEL_PORT" -webBasePath "$PANEL_PATH" >/dev/null 2>&1 \
    || fail "не удалось задать порт и путь панели"

systemctl restart x-ui
sleep 5
systemctl is-active --quiet x-ui || fail "x-ui не поднялся после смены настроек"

# --- 8. Параметры VLESS-Reality --------------------------------------------

log "генерирую параметры Reality"
KEYS="$("$XRAY_BIN" x25519)"
PRIVATE_KEY="$(echo "$KEYS" | grep -iE 'private' | awk '{print $NF}')"
PUBLIC_KEY="$(echo "$KEYS" | grep -iE 'public' | awk '{print $NF}')"
[ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || fail "не удалось получить ключи x25519"

CLIENT_UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="$(openssl rand -hex 8)"
SERVER_IP="$(curl -s -4 --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')"
[ -n "$SERVER_IP" ] || fail "не удалось определить внешний IP сервера"

# --- 9. Создание inbound через API панели ----------------------------------

API="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"
COOKIE=/tmp/zentra-cookie.txt
rm -f "$COOKIE"

log "вхожу в панель"
LOGIN_RESP="$(curl -s -c "$COOKIE" -X POST "${API}login" \
    -d "username=${PANEL_USER}&password=${PANEL_PASS}")"
echo "$LOGIN_RESP" | grep -q '"success":true' || fail "вход в панель не удался: $LOGIN_RESP"

SETTINGS="$(jq -c -n --arg id "$CLIENT_UUID" --arg email "$CLIENT_NAME" '{
  clients: [ { id: $id, flow: "xtls-rprx-vision", email: $email, limitIp: 0,
               totalGB: 0, expiryTime: 0, enable: true, tgId: "", subId: "", reset: 0 } ],
  decryption: "none", fallbacks: []
}')"

STREAM="$(jq -c -n --arg dest "${REALITY_DEST}:443" --arg sni "$REALITY_DEST" \
                  --arg priv "$PRIVATE_KEY" --arg pub "$PUBLIC_KEY" --arg sid "$SHORT_ID" '{
  network: "tcp", security: "reality",
  externalProxy: [],
  realitySettings: {
    show: false, xver: 0, dest: $dest, serverNames: [$sni],
    privateKey: $priv, minClient: "", maxClient: "", maxTimediff: 0,
    shortIds: [$sid],
    settings: { publicKey: $pub, fingerprint: "chrome", serverName: "", spiderX: "/" }
  },
  tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } }
}')"

SNIFF="$(jq -c -n '{enabled: true, destOverride: ["http","tls","quic"], metadataOnly: false, routeOnly: false}')"

log "создаю подключение VLESS-Reality"
ADD_RESP="$(curl -s -b "$COOKIE" -X POST "${API}panel/api/inbounds/add" \
    --data-urlencode "up=0" \
    --data-urlencode "down=0" \
    --data-urlencode "total=0" \
    --data-urlencode "remark=Zentra" \
    --data-urlencode "enable=true" \
    --data-urlencode "expiryTime=0" \
    --data-urlencode "listen=" \
    --data-urlencode "port=${VPN_PORT}" \
    --data-urlencode "protocol=vless" \
    --data-urlencode "settings=${SETTINGS}" \
    --data-urlencode "streamSettings=${STREAM}" \
    --data-urlencode "sniffing=${SNIFF}")"

if ! echo "$ADD_RESP" | grep -q '"success":true'; then
    if echo "$ADD_RESP" | grep -qi 'port.*exist\|already'; then
        log "подключение на порту ${VPN_PORT} уже существует, оставляю как есть"
    else
        fail "не удалось создать подключение: $ADD_RESP"
    fi
fi

rm -f "$COOKIE"

# --- 10. Проверки ----------------------------------------------------------

log "проверяю результат"
sleep 3
systemctl is-active --quiet x-ui || fail "x-ui не работает после настройки"
ss -tulpn 2>/dev/null | grep -q ":${VPN_PORT} " || log "предупреждение: порт ${VPN_PORT} не слушается, проверьте панель"

VLESS_URL="vless://${CLIENT_UUID}@${SERVER_IP}:${VPN_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${REALITY_DEST}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#Zentra-${SERVER_IP}"

# --- 11. Результат ---------------------------------------------------------

echo "ZENTRA_RESULT_BEGIN"
jq -n --arg url "$VLESS_URL" --arg ip "$SERVER_IP" --arg pport "$PANEL_PORT" \
      --arg ppath "$PANEL_PATH" --arg puser "$PANEL_USER" --arg ppass "$PANEL_PASS" \
      --arg uuid "$CLIENT_UUID" '{
  vlessUrl: $url,
  serverIp: $ip,
  panelUrl: ("http://" + $ip + ":" + $pport + $ppath),
  panelUser: $puser,
  panelPassword: $ppass,
  clientUuid: $uuid
}'
echo "ZENTRA_RESULT_END"

log "готово"
