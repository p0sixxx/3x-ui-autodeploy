#!/bin/sh
# Обратный прокси (bridge) для OpenWrt / GL.iNet: роутер дома сам держит подключение к VPN-серверу,
# и через сервер можно зайти в домашнюю сеть без белого IP.
# Команду с конфигом печатает на сервере: vpn reverse add <имя>  (или vpn reverse router <имя>)
#   sh router-bridge.sh <конфиг в base64>   — поставить / обновить
#   sh router-bridge.sh status              — состояние
#   sh router-bridge.sh remove              — удалить
set -e
XRAY_VER=26.9.30
D=/etc/xray-bridge
B=/usr/bin/xray-bridge
S=/etc/init.d/xray-bridge

case "${1:-}" in
remove)
    [ -x "$S" ] && { "$S" stop || true; "$S" disable || true; }
    rm -rf "$D" "$B" "$S"
    echo "xray-bridge удалён."
    exit 0 ;;
status)
    if [ -x "$S" ] && "$S" running 2>/dev/null; then echo "xray-bridge запущен"; else echo "xray-bridge не запущен"; fi
    logread 2>/dev/null | grep xray-bridge | tail -n 10 || true
    exit 0 ;;
""|-h|--help)
    echo "Использование: sh $0 <конфиг в base64> | status | remove"
    echo "Команду с конфигом печатает на сервере: vpn reverse add <имя>"
    exit 1 ;;
esac

command -v base64 >/dev/null 2>&1 || { echo "Нет base64 (busybox). Поставь: opkg update && opkg install coreutils-base64"; exit 1; }
mkdir -p "$D"
printf '%s' "$1" | base64 -d > "$D/config.json.new" || { echo "Конфиг повреждён — скопируй команду целиком"; exit 1; }

case "$(uname -m)" in
    aarch64|arm64) Z=Xray-linux-arm64-v8a.zip ;;
    armv7*) Z=Xray-linux-arm32-v7a.zip ;;
    x86_64) Z=Xray-linux-64.zip ;;
    mips) Z=Xray-linux-mips32.zip ;;
    mipsel|mipsle) Z=Xray-linux-mips32le.zip ;;
    *) echo "Архитектура $(uname -m) не поддерживается этим скриптом"; exit 1 ;;
esac

if ! "$B" version 2>/dev/null | grep -q "Xray ${XRAY_VER}"; then
    echo "Скачиваю Xray ${XRAY_VER} (${Z}, ~15 МБ)…"
    T=/tmp/xray-bridge-dl; rm -rf "$T"; mkdir -p "$T"
    wget -qO "$T/x.zip" "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/${Z}" \
        || { echo "Не удалось скачать с GitHub. Проверь интернет на роутере."; rm -rf "$T"; exit 1; }
    command -v unzip >/dev/null 2>&1 || { opkg update >/dev/null 2>&1; opkg install unzip >/dev/null 2>&1 || true; }
    unzip -o -q "$T/x.zip" xray -d "$T" || { echo "Нет unzip: opkg update && opkg install unzip"; rm -rf "$T"; exit 1; }
    mv "$T/xray" "$B"; chmod 755 "$B"; rm -rf "$T"
fi

"$B" run -test -c "$D/config.json.new" >/dev/null 2>&1 || { "$B" run -test -c "$D/config.json.new"; echo "Конфиг не принят Xray"; exit 1; }
mv "$D/config.json.new" "$D/config.json"
chmod 600 "$D/config.json"

cat > "$S" <<'EOF'
#!/bin/sh /etc/rc.common
# обратный прокси VPN-сервера: доступ в домашнюю сеть через сервер
START=99
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/xray-bridge run -c /etc/xray-bridge/config.json
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
chmod 755 "$S"
"$S" enable
"$S" restart
sleep 3
if "$S" running 2>/dev/null; then
    echo "Готово: xray-bridge запущен и включён в автозагрузку. На сервере проверь: vpn reverse list"
else
    echo "xray-bridge не запустился — смотри: logread | grep xray-bridge"; exit 1
fi
