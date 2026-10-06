#!/bin/bash
# Поднимает туннель AmneziaWG и запускает HTTP-прокси.
set -euo pipefail

SRC="${AWG_CONFIG:-/config/awg0.conf}"
IFACE=awg0
DST="/etc/amnezia/amneziawg/${IFACE}.conf"

if [[ ! -f "$SRC" ]]; then
    echo "[amnezia] Нет файла конфигурации $SRC"
    echo "[amnezia] Экспортируйте конфиг из приложения Amnezia в формате AmneziaWG и положите его в deploy/amnezia/config/awg0.conf"
    exit 1
fi

mkdir -p "$(dirname "$DST")"
# Готовим конфиг для контейнера:
#  - DNS = ... требует resolvconf, внутри Docker он не нужен — убираем;
#  - IPv6 в контейнере обычно выключен, поэтому IPv6-адреса из Address/AllowedIPs убираем (AWG_KEEP_IPV6=1 — оставить).
awk -v keep6="${AWG_KEEP_IPV6:-0}" '
    BEGIN { IGNORECASE = 1 }
    /^[[:space:]]*DNS[[:space:]]*=/ { next }
    keep6 != "1" && /^[[:space:]]*(Address|AllowedIPs)[[:space:]]*=/ {
        split($0, kv, "=");  key = kv[1];  val = substr($0, index($0, "=") + 1)
        n = split(val, parts, ","); out = ""
        for (i = 1; i <= n; i++) {
            p = parts[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
            if (p == "" || p ~ /:/) continue
            out = (out == "" ? p : out ", " p)
        }
        if (out == "") next
        print key "= " out; next
    }
    { print }
' "$SRC" > "$DST"
chmod 600 "$DST"

cleanup() {
    echo "[amnezia] Останавливаюсь..."
    kill "${PROXY_PID:-0}" 2>/dev/null || true
    awg-quick down "$DST" 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

awg-quick up "$DST"
awg show "$IFACE" | sed -E 's/(private key: ).*/\1(скрыт)/'

echo "[amnezia] Внешний IP через туннель: $(curl -s -m 10 https://ifconfig.me || echo 'не удалось определить')"

tinyproxy -d -c /etc/tinyproxy/tinyproxy.conf &
PROXY_PID=$!
echo "[amnezia] HTTP-прокси слушает :8888"

wait "$PROXY_PID"
echo "[amnezia] tinyproxy завершился"
awg-quick down "$DST" || true
exit 1
