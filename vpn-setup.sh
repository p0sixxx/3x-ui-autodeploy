#!/usr/bin/env bash
# vpn-setup.sh — VPN-сервис на 3x-ui: VLESS+Reality (TCP/443) и Hysteria2 (UDP/443),
# подписки, лимиты трафика и сроки на пользователя, утилита `vpn` (управление и диагностика).
# Проверено с 3x-ui v3.9.0 (Xray 26.9.30). Целевая ОС: Ubuntu 24.04 (Debian 12 тоже должен работать).
#
# Запуск:  bash <(curl -fsSL https://raw.githubusercontent.com/p0sixxx/3x-ui-autodeploy/main/vpn-setup.sh)
#      или: bash vpn-setup.sh
#
# Опции (переменные окружения, все необязательные):
#   PANEL_PORT, SUB_PORT       — порты панели и подписок (иначе случайные 20000–60000)
#   REALITY_TARGET=host:443    — свой сайт-маскировка для Reality (иначе подбирается автоматически)
#   DOMAIN=vpn.example.com     — домен с A-записью на сервер (иначе сертификат на IP)
#   TG_BOT_TOKEN, TG_ADMIN_ID  — включить Telegram-бота 3x-ui
#   ACME_EMAIL                 — e-mail для Let's Encrypt
#   NO_FIREWALL=1              — не трогать ufw
#   SKIP_EXTERNAL_CHECK=1      — не проверять порты снаружи (check-host.net)
#   ASSUME_YES=1               — на все вопросы отвечать «да» (без интерактива)
#   XUI_VERSION=v3.9.0         — версия 3x-ui

set -Eeuo pipefail
trap 'echo -e "\n\033[0;31m[ОШИБКА] строка $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

XUI_VERSION="${XUI_VERSION:-v3.9.0}"
REALITY_CANDIDATES="www.samsung.com:443,www.nvidia.com:443,www.amd.com:443,www.intel.com:443,www.sony.com:443,dl.google.com:443,aws.amazon.com:443,www.cloudflare.com:443"
VPN_DIR=/etc/vpn
XUI_BIN=/usr/local/x-ui/x-ui
TMP_LISTENERS=()

c_g='\033[0;32m'; c_y='\033[0;33m'; c_r='\033[0;31m'; c_b='\033[1m'; c_0='\033[0m'
log()  { echo -e "${c_g}==>${c_0} $*"; }
ok()   { echo -e "    ${c_g}[OK]${c_0} $*"; }
warn() { echo -e "    ${c_y}[!!]${c_0} $*"; }
die()  { echo -e "\n${c_r}[СТОП]${c_0} $*" >&2; exit 1; }
rnd()  { openssl rand -hex 32 | tr -dc 'a-z0-9' | head -c "$1"; }

ask() { # ask "вопрос" — да/нет, по умолчанию «нет»; без терминала — «нет» (или «да» при ASSUME_YES=1)
    [[ "${ASSUME_YES:-0}" == 1 ]] && { echo "    $1 → да (ASSUME_YES)"; return 0; }
    if [[ -t 0 ]]; then
        local a; read -r -p "    $1 [y/N] " a
        [[ "$a" =~ ^[YyДд] ]]
    else
        echo "    $1 → нет (нет терминала)"; return 1
    fi
}

cleanup() {
    local p
    for p in "${TMP_LISTENERS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

port_busy() { # port_busy <port> <tcp|udp>
    local flag=-ltn; [[ "$2" == udp ]] && flag=-lun
    [[ -n "$(ss -H "$flag" "sport = :$1" 2>/dev/null)" ]]
}
free_port() {
    local p
    while :; do p=$(shuf -i 20000-60000 -n 1); port_busy "$p" tcp || { echo "$p"; return; }; done
}

# =========================================================================== 1. локальные проверки
preflight() {
    log "Проверка сервера"
    [[ $EUID -eq 0 ]] || die "Запусти от root (sudo -i)"
    . /etc/os-release
    case "$ID" in
        ubuntu) [[ "$VERSION_ID" == "24.04" ]] && ok "ОС: Ubuntu $VERSION_ID" || warn "ОС: Ubuntu $VERSION_ID (проверено на 24.04)";;
        debian) warn "ОС: Debian $VERSION_ID (проверено на Ubuntu 24.04)";;
        *) die "Скрипт рассчитан на Ubuntu/Debian (у тебя: $ID)";;
    esac
    case "$(uname -m)" in x86_64|aarch64) ok "Архитектура: $(uname -m)";; *) die "Неподдерживаемая архитектура $(uname -m)";; esac
    command -v systemctl >/dev/null || die "Нет systemd"

    local virt; virt=$(systemd-detect-virt 2>/dev/null || echo none)
    case "$virt" in
        openvz|lxc|lxc-libvirt) warn "Виртуализация $virt: swap и BBR могут не включиться (это решает хостер)";;
        *) ok "Виртуализация: $virt";;
    esac

    local ram disk
    ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    disk=$(df -Pm / | awk 'NR==2{print $4}')
    (( ram >= 900 )) || die "Мало памяти: ${ram} МБ (нужно от 1 ГБ)"
    (( ram >= 1500 )) && ok "RAM: ${ram} МБ" || warn "RAM: ${ram} МБ — хватит на несколько пользователей"
    (( disk >= 2048 )) || die "Мало места на диске: ${disk} МБ свободно (нужно от 2 ГБ)"
    ok "Свободно на диске: ${disk} МБ"
    grep -qwm1 aes /proc/cpuinfo && ok "Процессор поддерживает AES-NI" \
        || warn "Процессор без AES-NI (часто это эмулированный CPU QEMU) — шифрование будет медленнее; можно попросить хостера включить host-passthrough"

    if [[ -e /usr/local/x-ui || -e /etc/x-ui/x-ui.db ]]; then
        warn "На сервере уже установлен 3x-ui."
        if ask "Сделать бэкап, удалить его и поставить заново? Все пользователи будут удалены."; then
            reinstall_cleanup
        else
            die "Оставляю существующую установку как есть."
        fi
    fi

    local busy=""
    port_busy 443 tcp && busy+=" 443/tcp"
    port_busy 443 udp && busy+=" 443/udp"
    port_busy 80 tcp  && busy+=" 80/tcp"
    if [[ -n "$busy" ]]; then
        ss -ltnup 2>/dev/null | grep -E ':(80|443)\s' >&2 || true
        die "Заняты порты:${busy} (процессы выше). Они нужны для Reality, Hysteria2 и сертификата — освободи их и запусти снова."
    fi
    ok "Порты 80/tcp, 443/tcp, 443/udp свободны"
    if [[ -n "${DOMAIN:-}" && ! "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; then
        die "DOMAIN='$DOMAIN' не похож на домен"
    fi
}

reinstall_cleanup() {
    local bk
    bk="/root/x-ui-before-reinstall-$(date +%F-%H%M%S).tgz"
    tar czf "$bk" /etc/x-ui /etc/vpn /root/cert 2>/dev/null || true
    ok "Бэкап старой установки: $bk"
    systemctl disable --now x-ui >/dev/null 2>&1 || true
    rm -rf /usr/local/x-ui /etc/x-ui /etc/systemd/system/x-ui.service /usr/bin/x-ui "$VPN_DIR" /usr/local/bin/vpn
    systemctl daemon-reload
    sleep 1
    ok "Старая установка удалена"
}

# =========================================================================== 2. система
prepare_system() {
    log "Пакеты и настройка системы"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || die "apt-get update не работает — проверь интернет/DNS на сервере"
    apt-get install -y -qq curl jq openssl ca-certificates cron socat ufw qrencode iproute2 \
        bsdextrautils python3 >/dev/null || die "Не удалось установить пакеты"
    ok "Пакеты установлены"

    if ! swapon --show | grep -q .; then
        if fallocate -l 1G /swapfile 2>/dev/null && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile 2>/dev/null; then
            grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            ok "Swap 1 ГБ создан"
        else
            rm -f /swapfile; warn "Swap создать не удалось (ограничение виртуализации) — продолжаю без него"
        fi
    else
        ok "Swap уже есть"
    fi

    cat > /etc/sysctl.d/99-vpn.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
vm.swappiness = 10
EOF
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -q --system >/dev/null 2>&1 || true
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr ]] && ok "BBR включён" \
        || warn "BBR не включился (ядро/виртуализация) — работать будет, но медленнее на плохих каналах"

    time_sync
}

time_sync() {
    if ! command -v timedatectl >/dev/null || ! { systemctl list-unit-files 2>/dev/null | grep -qE '^(systemd-timesyncd|chrony)'; }; then
        apt-get install -y -qq systemd-timesyncd >/dev/null 2>&1 || true
    fi
    timedatectl set-ntp true >/dev/null 2>&1 || true
    local _ synced=no
    for _ in $(seq 1 15); do
        synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo no)
        [[ "$synced" == yes ]] && break
        sleep 2
    done
    local d skew
    d=$(curl -sI --max-time 10 https://www.cloudflare.com | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r' || true)
    if [[ -n "$d" ]]; then
        skew=$(( $(date +%s) - $(date -d "$d" +%s) )); skew=${skew#-}
        (( skew <= 30 )) && ok "Время точное (расхождение ${skew} с, NTP: $synced)" \
            || die "Часы сервера ушли на ${skew} с — Reality и сертификаты не будут работать. Проверь NTP: timedatectl"
    else
        [[ "$synced" == yes ]] && ok "Время синхронизировано по NTP" || warn "Не удалось проверить время"
    fi
}

net_checks() {
    log "Проверка сети сервера"
    getent hosts github.com >/dev/null || die "DNS не работает (не резолвится github.com). Проверь /etc/resolv.conf"
    ok "DNS работает"
    local u
    for u in https://github.com https://raw.githubusercontent.com https://acme-v02.api.letsencrypt.org/directory; do
        curl -fsS -o /dev/null --max-time 15 "$u" 2>/dev/null || curl -sS -o /dev/null --max-time 15 "$u" 2>/dev/null \
            || die "Нет доступа к $u — без него установка невозможна"
    done
    ok "Доступны GitHub и Let's Encrypt"

    SERVER_IP=$(detect_ip)
    [[ -n "$SERVER_IP" ]] || die "Не удалось определить публичный IPv4"
    if ip -4 -o addr show scope global | grep -qw "$SERVER_IP"; then
        ok "Публичный IP: $SERVER_IP (на интерфейсе сервера)"
    else
        warn "Публичный IP $SERVER_IP не висит на интерфейсе — сервер за NAT. Порты должны быть проброшены (проверю снаружи)."
    fi
    if ip -6 -o addr show scope global 2>/dev/null | grep -q .; then ok "Есть IPv6 (клиенты всё равно подключаются по IPv4)"; fi
}

detect_ip() {
    local u ip
    for u in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me https://check-host.net/ip; do
        ip=$(curl -4 -fs --max-time 5 "$u" | tr -d '[:space:]"') || continue
        [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && { echo "$ip"; return; }
    done
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

choose_params() {
    PUBLIC_HOST="${DOMAIN:-$SERVER_IP}"
    PANEL_PORT="${PANEL_PORT:-$(free_port)}"
    SUB_PORT="${SUB_PORT:-$(free_port)}"
    [[ "$SUB_PORT" == "$PANEL_PORT" ]] && SUB_PORT=$(free_port)
    local p
    for p in "$PANEL_PORT" "$SUB_PORT"; do
        [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1024 && p < 65536 )) || die "Порт $p некорректен (нужен 1025–65535)"
        port_busy "$p" tcp && die "Порт $p уже занят"
    done
    WEB_PATH=$(rnd 16); ADMIN_USER="admin$(rnd 4)"; ADMIN_PASS=$(rnd 20)
    ok "Панель: порт $PANEL_PORT, подписки: порт $SUB_PORT"
}

# =========================================================================== 3. фаервол
setup_firewall() {
    [[ "${NO_FIREWALL:-0}" == 1 ]] && { warn "ufw не настраиваю (NO_FIREWALL=1)"; return; }
    log "Фаервол ufw"
    local ssh_ports p
    ssh_ports=$( { sshd -T 2>/dev/null | awk '$1=="port"{print $2}' || true
                   ss -H -ltnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' || true
                   if [[ -n "${SSH_CONNECTION:-}" ]]; then awk '{print $4}' <<<"$SSH_CONNECTION"; fi
                 } | sort -un)
    [[ -z "$ssh_ports" ]] && ssh_ports=22
    for p in $ssh_ports; do ufw allow "${p}/tcp" comment ssh >/dev/null; done
    ufw allow 80/tcp comment acme >/dev/null
    ufw allow 443/tcp comment vless-reality >/dev/null
    ufw allow 443/udp comment hysteria2 >/dev/null
    ufw allow "${PANEL_PORT}/tcp" comment 3x-ui-panel >/dev/null
    ufw allow "${SUB_PORT}/tcp" comment 3x-ui-sub >/dev/null
    ufw --force enable >/dev/null
    ufw status | grep -q "Status: active" || die "ufw не включился"
    ok "ufw включён: ssh(${ssh_ports//$'\n'/,}), 80, 443/tcp, 443/udp, ${PANEL_PORT}, ${SUB_PORT}"
}

# =========================================================================== 4. внешняя проверка портов
external_precheck() {
    [[ "${SKIP_EXTERNAL_CHECK:-0}" == 1 ]] && { warn "Внешняя проверка портов пропущена (SKIP_EXTERNAL_CHECK=1)"; return; }
    log "Проверка портов снаружи (check-host.net: узлы в России и Европе)"
    local p
    for p in 80 443 "$PANEL_PORT" "$SUB_PORT"; do
        socat "TCP-LISTEN:${p},reuseaddr,fork" SYSTEM:true >/dev/null 2>&1 &
        TMP_LISTENERS+=($!)
    done
    sleep 1
    local out
    if ! out=$(vpn _probe "$SERVER_IP" 80 443 "$PANEL_PORT" "$SUB_PORT"); then
        cleanup; TMP_LISTENERS=()
        warn "check-host.net недоступен — внешнюю проверку пропускаю"
        return
    fi
    cleanup; TMP_LISTENERS=(); sleep 1

    local port ru w ru_ok ru_all w_ok
    while read -r port ru w; do
        ru_ok=${ru%/*}; ru_all=${ru#*/}; w_ok=${w%/*}
        local name
        case "$port" in
            80) name="80/tcp (сертификат)";;
            443) name="443/tcp (VLESS)";;
            "$PANEL_PORT") name="$port/tcp (панель)";;
            *) name="$port/tcp (подписки)";;
        esac
        if [[ "$ru" == "?" ]]; then warn "$name: проверка не выполнилась"; continue; fi
        if (( w_ok > 0 && (ru_all == 0 || ru_ok > 0) )); then
            ok "$name доступен снаружи (Европа $w, Россия $ru)"
        elif (( w_ok > 0 )); then
            warn "$name: из Европы доступен ($w), из России НЕТ ($ru) — похоже, IP заблокирован в РФ"
            if [[ "$port" == 443 ]]; then
                ask "Для пользователей из России VPN на этом IP работать не будет. Всё равно продолжить?" \
                    || die "Остановлено. Нужен VPS с другим IP."
            fi
        elif (( ru_ok > 0 )); then
            ok "$name доступен из России ($ru), из Европы нет ($w)"
        else
            case "$port" in
                443) die "443/tcp закрыт снаружи. Открой 443/tcp и 443/udp в фаерволе хостера и запусти скрипт снова.";;
                80)  warn "80/tcp закрыт снаружи — Let's Encrypt не выдаст сертификат, будет самоподписанный (браузер будет ругаться на панель, подписка пойдёт по http)."
                     ask "Продолжить с самоподписанным сертификатом? (лучше: открой 80/tcp у хостера и запусти снова)" \
                         || die "Остановлено. Открой 80/tcp в фаерволе хостера и запусти скрипт снова.";;
                *)   warn "$name закрыт снаружи."
                     ask "Продолжить? (без порта подписок клиенты не получат настройки; можно запустить снова с PANEL_PORT=… SUB_PORT=… из открытого диапазона)" \
                         || die "Остановлено. Открой порты ${PANEL_PORT} и ${SUB_PORT}/tcp у хостера или задай другие через PANEL_PORT/SUB_PORT.";;
            esac
        fi
    done <<<"$out"
    warn "443/udp (Hysteria2) снаружи проверить нельзя — проверю сквозным тестом после установки; не забудь открыть его у хостера"
}

# =========================================================================== 5. 3x-ui
install_xui() {
    log "Устанавливаю 3x-ui ${XUI_VERSION} (2–3 минуты)"
    local inst; inst=$(mktemp)
    curl -fsSL "https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_VERSION}/install.sh" -o "$inst" \
        || die "Не удалось скачать установщик 3x-ui ${XUI_VERSION}"
    local ssl_mode=ip; [[ -n "${DOMAIN:-}" ]] && ssl_mode=domain
    if ! XUI_NONINTERACTIVE=1 XUI_SSL_MODE="$ssl_mode" XUI_DOMAIN="${DOMAIN:-}" \
        XUI_SERVER_IP="$SERVER_IP" XUI_PANEL_PORT="$PANEL_PORT" XUI_WEB_BASE_PATH="$WEB_PATH" \
        XUI_USERNAME="$ADMIN_USER" XUI_PASSWORD="$ADMIN_PASS" XUI_ACME_EMAIL="${ACME_EMAIL:-}" \
        bash "$inst" "$XUI_VERSION" </dev/null > /var/log/vpn-setup-xui.log 2>&1; then
        tail -20 /var/log/vpn-setup-xui.log >&2
        die "Установщик 3x-ui завершился с ошибкой (полный лог: /var/log/vpn-setup-xui.log)"
    fi
    rm -f "$inst"
    [[ -x "$XUI_BIN" ]] || die "3x-ui не установился (лог: /var/log/vpn-setup-xui.log)"
    systemctl is-enabled --quiet x-ui || die "Сервис x-ui не включён"
    ok "3x-ui $("$XUI_BIN" -v 2>/dev/null | head -1) установлен (лог: /var/log/vpn-setup-xui.log)"
}

setup_certs() {
    if [[ -n "${DOMAIN:-}" ]]; then
        CERT="/root/cert/${DOMAIN}/fullchain.pem"; KEY="/root/cert/${DOMAIN}/privkey.pem"
    else
        CERT=/root/cert/ip/fullchain.pem; KEY=/root/cert/ip/privkey.pem
    fi
    if [[ -s "$CERT" && -s "$KEY" ]] && openssl x509 -in "$CERT" -noout -checkend 3600 >/dev/null 2>&1; then
        CERT_MODE=letsencrypt
        ok "Сертификат Let's Encrypt получен, действует до $(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)"
        crontab -l 2>/dev/null | grep -q acme.sh && ok "Автопродление сертификата (cron acme.sh) настроено" \
            || warn "Не нашёл cron acme.sh — сертификат может не продлеваться"
        return
    fi
    warn "Let's Encrypt не выдал сертификат — ставлю самоподписанный (детали: /var/log/vpn-setup-xui.log)"
    CERT_MODE=selfsigned
    mkdir -p /root/cert/selfsigned
    CERT=/root/cert/selfsigned/fullchain.pem; KEY=/root/cert/selfsigned/privkey.pem
    local san="IP:${SERVER_IP}"; [[ -n "${DOMAIN:-}" ]] && san="DNS:${DOMAIN},${san}"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -subj "/CN=${PUBLIC_HOST}" -addext "subjectAltName=${san}" -keyout "$KEY" -out "$CERT" 2>/dev/null
    chmod 600 "$KEY"
    "$XUI_BIN" cert -webCert "$CERT" -webCertKey "$KEY" >/dev/null
    systemctl restart x-ui
}

api() { # api METHOD /path [curl args...]
    local m=$1 p=$2; shift 2
    curl -sk --max-time 120 -X "$m" -H "Authorization: Bearer $TOKEN" "$API$p" "$@"
}
api_json() { local m=$1 p=$2 body=$3; api "$m" "$p" -H 'Content-Type: application/json' --data-binary "$body"; }
must() { # must <описание> <json-ответ>
    jq -e '.success == true' >/dev/null 2>&1 <<<"$2" || die "$1: $(jq -r '.msg // .' <<<"$2" 2>/dev/null || echo "${2:-нет ответа}")"
}

connect_api() { # получить токен (каждый вызов -getApiToken перевыпускает его) и дождаться API
    TOKEN=$("$XUI_BIN" setting -getApiToken -tokenName vpn-cli 2>/dev/null | grep -Eo 'apiToken: .+' | awk '{print $2}' || true)
    [[ -n "$TOKEN" ]] || die "Не удалось получить API-токен 3x-ui"
    wait_api
}

wait_api() {
    local scheme
    for _ in $(seq 1 30); do
        for scheme in https http; do
            API="${scheme}://127.0.0.1:${PANEL_PORT}/${WEB_PATH}/panel/api"
            if api GET /server/status 2>/dev/null | jq -e '.success == true' >/dev/null 2>&1; then
                PANEL_SCHEME=$scheme; return
            fi
        done
        sleep 2
    done
    die "Панель 3x-ui не отвечает по API (journalctl -u x-ui -n 50)"
}

# =========================================================================== 6. Reality
pick_reality_target() {
    log "Маскировка Reality"
    local res
    if [[ -n "${REALITY_TARGET:-}" ]]; then
        [[ "$REALITY_TARGET" == *:* ]] || REALITY_TARGET="${REALITY_TARGET}:443"
        R_HOST="${REALITY_TARGET%%:*}"
        res=$(api POST /server/scanRealityTarget --data-urlencode "target=${REALITY_TARGET}")
        if jq -e '.obj.feasible == true' >/dev/null 2>&1 <<<"$res"; then
            ok "Свой target ${REALITY_TARGET} подходит (TLS 1.3, h2, X25519)"
        else
            warn "${REALITY_TARGET} не подходит для Reality: $(jq -r '.obj.reason // .msg // "?"' <<<"$res")"
            ask "Всё равно использовать его?" || die "Остановлено. Укажи другой REALITY_TARGET или не задавай его."
        fi
        return
    fi
    res=$(api POST /server/scanRealityTargets --data-urlencode "targets=${REALITY_CANDIDATES}")
    R_HOST=$(jq -r '[.obj[]? | select(.feasible == true)][0].host // empty' <<<"$res")
    if [[ -z "$R_HOST" ]]; then
        warn "Ни один кандидат не прошёл проверку TLS 1.3/h2/X25519 — беру www.samsung.com"
        R_HOST=www.samsung.com
    else
        ok "Выбран ${R_HOST} ($(jq -r --arg h "$R_HOST" '[.obj[] | select(.host == $h)][0].latencyMs' <<<"$res") мс от сервера)"
    fi
    REALITY_TARGET="${R_HOST}:443"
}

# =========================================================================== 7. inbounds и настройки
create_inbounds() {
    log "Создаю подключения"
    local keys priv pub sid1 sid2 res
    keys=$(api GET /server/getNewX25519Cert); must "x25519" "$keys"
    priv=$(jq -r .obj.privateKey <<<"$keys"); pub=$(jq -r .obj.publicKey <<<"$keys")
    sid1=$(openssl rand -hex 8); sid2=$(openssl rand -hex 4)

    res=$(api_json POST /inbounds/add "$(jq -n \
        --arg priv "$priv" --arg pub "$pub" --arg s1 "$sid1" --arg s2 "$sid2" \
        --arg target "$REALITY_TARGET" --arg sni "$R_HOST" --arg host "$PUBLIC_HOST" '{
        remark: "VLESS", enable: true, listen: "", port: 443, protocol: "vless",
        expiryTime: 0, total: 0, shareAddrStrategy: "custom", shareAddr: $host,
        settings: { clients: [], decryption: "none", fallbacks: [] },
        streamSettings: {
          network: "tcp", security: "reality",
          tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } },
          realitySettings: {
            show: false, xver: 0, target: $target, serverNames: [$sni],
            privateKey: $priv, minClientVer: "", maxClientVer: "", maxTimediff: 0,
            shortIds: [$s1, $s2], mldsa65Seed: "",
            settings: { publicKey: $pub, fingerprint: "chrome", serverName: "", spiderX: "/", mldsa65Verify: "" }
          }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false, routeOnly: true }
    }')")
    must "VLESS inbound" "$res"; IB_VLESS=$(jq -r .obj.id <<<"$res")
    ok "VLESS + Reality + Vision на 443/tcp"

    local pins='[]' sni=""
    [[ -n "${DOMAIN:-}" ]] && sni="$DOMAIN"
    if [[ "$CERT_MODE" == selfsigned ]]; then
        pins=$(jq -nc --arg p "$(openssl x509 -in "$CERT" -outform der | openssl dgst -sha256 -hex | awk '{print $NF}')" '[$p]')
    fi
    res=$(api_json POST /inbounds/add "$(jq -n \
        --arg crt "$CERT" --arg key "$KEY" --arg sni "$sni" --argjson pins "$pins" \
        --arg host "$PUBLIC_HOST" --arg mq "https://${R_HOST}" '{
        remark: "Hysteria2", enable: true, listen: "", port: 443, protocol: "hysteria",
        expiryTime: 0, total: 0, shareAddrStrategy: "custom", shareAddr: $host,
        settings: { version: 2, clients: [] },
        streamSettings: {
          network: "hysteria", security: "tls",
          tlsSettings: {
            serverName: $sni, minVersion: "1.3", maxVersion: "1.3", alpn: ["h3"], rejectUnknownSni: false,
            certificates: [{ useFile: true, certificateFile: $crt, keyFile: $key, ocspStapling: 0,
                             oneTimeLoading: false, usage: "encipherment", buildChain: false }],
            settings: { fingerprint: "", pinnedPeerCertSha256: $pins }
          },
          hysteriaSettings: {
            version: 2, auth: "", udpIdleTimeout: 60,
            masquerade: { type: "proxy", url: $mq, rewriteHost: true, insecure: false,
                          dir: "", content: "", headers: {}, statusCode: 0 }
          }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false, routeOnly: true }
    }')")
    must "Hysteria2 inbound" "$res"; IB_HY2=$(jq -r .obj.id <<<"$res")
    ok "Hysteria2 на 443/udp"
}

configure_panel() {
    log "Настройки подписок и панели"
    local all sub_scheme=http
    all=$(api POST /setting/all); must "чтение настроек" "$all"
    SUB_PATH=$(jq -r .obj.subPath <<<"$all")
    [[ "$CERT_MODE" == letsencrypt ]] && sub_scheme=https
    SUB_BASE="${sub_scheme}://${PUBLIC_HOST}:${SUB_PORT}${SUB_PATH}"
    local upd
    upd=$(jq --argjson port "$SUB_PORT" --arg uri "$SUB_BASE" --arg mode "$CERT_MODE" \
             --arg crt "$CERT" --arg key "$KEY" '.obj
        | .subEnable = true | .subPort = $port | .subURI = $uri
        | .subTitle = "VPN" | .subUpdates = 6 | .timeLocation = "Europe/Moscow"
        | if $mode == "letsencrypt" then .subCertFile = $crt | .subKeyFile = $key
          else .subCertFile = "" | .subKeyFile = "" end' <<<"$all")
    must "сохранение настроек" "$(api_json POST /setting/update "$upd")"
    ok "Подписки: ${sub_scheme}, порт ${SUB_PORT}, обновление раз в 6 ч"

    if [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_ADMIN_ID:-}" ]]; then
        "$XUI_BIN" setting -tgbottoken "$TG_BOT_TOKEN" -tgbotchatid "$TG_ADMIN_ID" -enabletgbot >/dev/null
        ok "Telegram-бот включён"
    fi
    systemctl restart x-ui
    sleep 2
    wait_api
}

write_env() {
    install -d -m 700 "$VPN_DIR"
    umask 077
    cat > "$VPN_DIR/vpn.env" <<EOF
API='${API}'
TOKEN='${TOKEN}'
INBOUNDS='[${IB_VLESS},${IB_HY2}]'
SUB_BASE='${SUB_BASE}'
SERVER_IP='${SERVER_IP}'
PUBLIC_HOST='${PUBLIC_HOST}'
PANEL_PORT='${PANEL_PORT}'
SUB_PORT='${SUB_PORT}'
PANEL_URL='${PANEL_SCHEME}://${PUBLIC_HOST}:${PANEL_PORT}/${WEB_PATH}/'
CERT_MODE='${CERT_MODE}'
CERT='${CERT}'
EOF
    cat > "$VPN_DIR/panel.txt" <<EOF
Панель:  ${PANEL_SCHEME}://${PUBLIC_HOST}:${PANEL_PORT}/${WEB_PATH}/
Логин:   ${ADMIN_USER}
Пароль:  ${ADMIN_PASS}
EOF
    umask 022
    chmod 600 "$VPN_DIR/vpn.env" "$VPN_DIR/panel.txt"
}

# =========================================================================== утилита vpn
install_cli() {
    cat > /usr/local/bin/vpn <<'VPNCLI'
#!/usr/bin/env bash
# vpn — управление пользователями и диагностика VPN на 3x-ui. Конфиг: /etc/vpn/vpn.env
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Нужен root"; exit 1; }
ENV_FILE=/etc/vpn/vpn.env
GiB=1073741824
HC_USER=healthcheck
CH=https://check-host.net
c_g='\033[0;32m'; c_y='\033[0;33m'; c_r='\033[0;31m'; c_0='\033[0m'

load_env() {
    [[ -r "$ENV_FILE" ]] || { echo "Нет $ENV_FILE — VPN не установлен?" >&2; exit 1; }
    # shellcheck source=/dev/null
    . "$ENV_FILE"
}
api() { local m=$1 p=$2; shift 2; curl -sk --max-time 30 -X "$m" -H "Authorization: Bearer $TOKEN" "$API$p" "$@"; }
api_json() { api "$1" "$2" -H 'Content-Type: application/json' --data-binary "$3"; }
ok() {
    local r=$1
    [[ -n "$r" ]] || { echo "Ошибка: панель не ответила или токен в $ENV_FILE недействителен (см. README: «Починка токена»)" >&2; exit 1; }
    jq -e '.success == true' >/dev/null 2>&1 <<<"$r" || { echo "Ошибка: $(jq -r '.msg // .' <<<"$r" 2>/dev/null || echo "$r")" >&2; exit 1; }
}
check_name() { [[ "${1:-}" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || { echo "Имя: латиница, цифры, . _ - @ (до 64 символов)" >&2; exit 1; }; }
is_num() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
now_ms() { echo $(( $(date +%s) * 1000 )); }
get_client() { local r; r=$(api GET "/clients/get/$1"); ok "$r"; jq -c '.obj.client' <<<"$r"; }

show_link() {
    local name=$1 c sub
    c=$(get_client "$name"); sub="${SUB_BASE}$(jq -r .subId <<<"$c")"
    echo; echo "Подписка ${name}:"; echo "  $sub"; echo
    if command -v qrencode >/dev/null; then qrencode -t ansiutf8 -m 1 "$sub"; fi
}

save_client() { # полное обновление (update заменяет запись целиком)
    local c=$1 name; name=$(jq -r .email <<<"$c")
    ok "$(api_json POST "/clients/update/$name" "$(jq -c '{email, id: .uuid, auth, subId, flow, limitIp, limitHwid,
        tgId, comment, reset, enable, totalGB, expiryTime}' <<<"$c")")"
}

add_client() { # add_client <имя> <ГБ> <дней> [комментарий]
    local exp=0
    [[ "$3" != 0 ]] && exp=$(( $(now_ms) + ${3%.*} * 86400000 ))
    ok "$(api_json POST /clients/add "$(jq -n --arg e "$1" --arg sub "$(openssl rand -hex 8)" --arg gb "$2" \
        --argjson exp "$exp" --arg cm "${4:-}" --argjson ib "$INBOUNDS" --argjson G $GiB \
        '{client: {email: $e, subId: $sub, flow: "xtls-rprx-vision", totalGB: (($gb|tonumber) * $G | floor),
          expiryTime: $exp, limitIp: 0, limitHwid: 0, tgId: 0, comment: $cm, enable: true}, inboundIds: $ib}')")"
}

# ---------------------------------------------------------------- внешние проверки (check-host.net)
ch_get() { curl -fsS --max-time 20 -H 'Accept: application/json' "$CH$1"; }
ch_nodes() { # до 3 узлов из России и до 3 из Европы
    local j; j=$(ch_get /nodes/hosts) || return 1
    jq -r '[.nodes | to_entries[] | select(.value.location[0] == "ru")] | .[:3][] | .key' <<<"$j"
    jq -r '[.nodes | to_entries[] | select(.value.location[0] as $c
            | ["de","nl","fi","fr","pl","se","gb","uk","ch","at","cz","lt","lv","ee"] | index($c))] | .[:3][] | .key' <<<"$j"
}
probe() { # probe <ip> <port...> → строки «<port> <ок_РФ>/<всего_РФ> <ок_Европа>/<всего_Европа>» (или «<port> ?»)
    local ip=$1; shift
    local nodes=() q="" n p id res pairs=()
    mapfile -t nodes < <(ch_nodes 2>/dev/null || true)
    (( ${#nodes[@]} > 0 )) || return 1
    for n in "${nodes[@]}"; do q+="&node=${n}"; done
    for p in "$@"; do
        id=$(ch_get "/check-tcp?host=${ip}:${p}${q}" 2>/dev/null | jq -r '.request_id // empty' 2>/dev/null || true)
        pairs+=("${p}:${id}")
    done
    sleep 4
    for n in "${pairs[@]}"; do
        p=${n%%:*}; id=${n#*:}
        if [[ -z "$id" ]]; then echo "$p ?"; continue; fi
        res=""
        for _ in $(seq 1 12); do
            res=$(ch_get "/check-result/${id}" 2>/dev/null || true)
            [[ -n "$res" ]] && jq -e 'type == "object" and ([.[] | select(. == null)] | length == 0)' >/dev/null 2>&1 <<<"$res" && break
            sleep 2
        done
        [[ -n "$res" ]] || res='{}'
        jq -r --arg p "$p" '[to_entries[] | {ru: (.key | startswith("ru")),
              ok: ((.value // [])[0] | if type == "object" then has("time") else false end)}] as $a
            | "\($p) \([$a[] | select(.ru and .ok)] | length)/\([$a[] | select(.ru)] | length) \([$a[] | select((.ru | not) and .ok)] | length)/\([$a[] | select(.ru | not)] | length)"' \
            <<<"$res" 2>/dev/null || echo "$p ?"
    done
}

# ---------------------------------------------------------------- сквозной тест через локальный xray-клиент
e2e() { # e2e <ссылка> <локальный socks-порт> → IP выхода или пусто
    local link=$1 sp=$2 cfg logf pid xray out=""
    xray=$(compgen -G '/usr/local/x-ui/bin/xray-linux-*' | head -1) || true
    [[ -x "$xray" ]] || return 0
    cfg=$(mktemp --suffix=.json); logf=$(mktemp)
    python3 - "$link" "$sp" > "$cfg" <<'PY' || { rm -f "$cfg" "$logf"; return 0; }
import sys, json, urllib.parse as u
link, sp = sys.argv[1], int(sys.argv[2])
p = u.urlparse(link); q = dict(u.parse_qsl(p.query))
host, port, user = p.hostname, p.port or 443, u.unquote(p.username or "")
if p.scheme == "vless":
    ob = {"protocol": "vless",
          "settings": {"vnext": [{"address": host, "port": port, "users": [{"id": user, "encryption": "none", "flow": q.get("flow", "")}]}]},
          "streamSettings": {"network": "tcp", "security": "reality",
                             "realitySettings": {"serverName": q.get("sni", ""), "fingerprint": q.get("fp") or "chrome",
                                                 "publicKey": q["pbk"], "shortId": q.get("sid", ""), "spiderX": "/"}}}
else:
    tls = {"serverName": q.get("sni") or host, "alpn": ["h3"]}
    if q.get("pinSHA256"):
        tls["pinnedPeerCertSha256"] = q["pinSHA256"]
    ob = {"protocol": "hysteria", "settings": {"version": 2, "address": host, "port": port},
          "streamSettings": {"network": "hysteria", "hysteriaSettings": {"version": 2, "auth": user},
                             "security": "tls", "tlsSettings": tls}}
print(json.dumps({"log": {"loglevel": "warning"},
                  "inbounds": [{"listen": "127.0.0.1", "port": sp, "protocol": "socks", "settings": {"udp": False}}],
                  "outbounds": [ob]}))
PY
    "$xray" run -c "$cfg" >"$logf" 2>&1 &
    pid=$!
    sleep 2
    out=$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:${sp}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
          | awk -F= '/^ip=/{print $2}') || out=""
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    rm -f "$cfg" "$logf"
    echo "$out"
}

# ---------------------------------------------------------------- vpn check
N_OK=0; N_WARN=0; N_FAIL=0
r_ok()   { echo -e "  ${c_g}[OK]${c_0}   $*"; N_OK=$((N_OK + 1)); }
r_warn() { echo -e "  ${c_y}[WARN]${c_0} $*"; N_WARN=$((N_WARN + 1)); }
r_fail() { echo -e "  ${c_r}[FAIL]${c_0} $*"; N_FAIL=$((N_FAIL + 1)); }
listening() { local f=-ltn; [[ $2 == udp ]] && f=-lun; [[ -n "$(ss -H "$f" "sport = :$1" 2>/dev/null)" ]]; }

do_check() {
    local external=${1:-yes} st r
    echo "Диагностика VPN ($(date '+%d.%m.%Y %H:%M'))"

    echo "— Сервисы"
    systemctl is-active --quiet x-ui && r_ok "Сервис x-ui запущен" || r_fail "Сервис x-ui не запущен: systemctl restart x-ui; journalctl -u x-ui -n 50"
    r=$(api GET /server/status 2>/dev/null || true)
    if jq -e '.success == true' >/dev/null 2>&1 <<<"$r"; then
        r_ok "API панели отвечает"
        st=$(jq -r '.obj.xray.state // "?"' <<<"$r")
        [[ "$st" == running ]] && r_ok "Xray $(jq -r '.obj.xray.version // ""' <<<"$r") работает" \
            || r_fail "Xray не работает (state: $st) — смотри журнал: journalctl -u x-ui -n 50"
    else
        r_fail "API панели не отвечает (x-ui упал или токен в $ENV_FILE недействителен)"
    fi

    echo "— Порты на сервере"
    listening 443 tcp && r_ok "443/tcp слушается (VLESS)" || r_fail "443/tcp никто не слушает"
    listening 443 udp && r_ok "443/udp слушается (Hysteria2)" || r_fail "443/udp никто не слушает"
    listening "$PANEL_PORT" tcp && r_ok "${PANEL_PORT}/tcp слушается (панель)" || r_fail "${PANEL_PORT}/tcp (панель) никто не слушает"
    listening "$SUB_PORT" tcp && r_ok "${SUB_PORT}/tcp слушается (подписки)" || r_fail "${SUB_PORT}/tcp (подписки) никто не слушает"
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        local miss="" p s; s=$(ufw status)
        for p in 80/tcp 443/tcp 443/udp "${PANEL_PORT}/tcp" "${SUB_PORT}/tcp"; do grep -q "^${p} " <<<"$s" || miss+=" $p"; done
        [[ -z "$miss" ]] && r_ok "ufw: нужные порты открыты" || r_fail "ufw: не открыты:${miss} (ufw allow <порт>)"
    else
        r_warn "ufw выключен (работать будет, но сервер без фаервола)"
    fi

    echo "— Система"
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]] && r_ok "Время синхронизировано" \
        || r_warn "Время не синхронизировано по NTP: timedatectl set-ntp true"
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr ]] && r_ok "BBR включён" || r_warn "BBR выключен"
    local disk mem
    disk=$(df -Pm / | awk 'NR==2{print $4}'); mem=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    (( disk > 1024 )) && r_ok "Свободно на диске: ${disk} МБ" || r_warn "Мало места на диске: ${disk} МБ"
    (( mem > 200 )) && r_ok "Свободно памяти: ${mem} МБ" || r_warn "Мало свободной памяти: ${mem} МБ"

    echo "— Сертификат"
    if [[ "$CERT_MODE" == letsencrypt ]]; then
        local end left
        end=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
        left=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 3600 ))
        (( left > 24 )) && r_ok "Сертификат Let's Encrypt действует ещё $(( left / 24 )) дн. $(( left % 24 )) ч" \
            || r_warn "Сертификат истекает через ${left} ч — проверь продление: ~/.acme.sh/acme.sh --cron --force"
        crontab -l 2>/dev/null | grep -q acme.sh && r_ok "Автопродление (cron acme.sh) есть" || r_fail "Нет cron acme.sh — сертификат не будет продлеваться"
        if curl -s -o /dev/null --max-time 10 "https://${PUBLIC_HOST}:${SUB_PORT}/" 2>/dev/null; then
            r_ok "TLS подписок проходит проверку сертификата"
        else
            r_fail "TLS-проверка сертификата на ${PUBLIC_HOST}:${SUB_PORT} не прошла"
        fi
    else
        r_warn "Самоподписанный сертификат: панель с предупреждением браузера, подписки по http"
    fi

    echo "— Подписка и маскировка"
    local hc sub links vl hy
    hc=$(api GET "/clients/get/${HC_USER}" 2>/dev/null || true)
    if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$hc"; then
        add_client "$HC_USER" 0 0 "служебный, для vpn check" >/dev/null 2>&1 || true
        hc=$(api GET "/clients/get/${HC_USER}" 2>/dev/null || true)
    fi
    if jq -e '.success == true' >/dev/null 2>&1 <<<"$hc"; then
        sub="${SUB_BASE}$(jq -r .obj.client.subId <<<"$hc")"
        links=$(curl -sk --max-time 15 "$sub" | base64 -d 2>/dev/null || true)
        vl=$(grep -m1 '^vless://' <<<"$links" || true); hy=$(grep -m1 '^hysteria2://' <<<"$links" || true)
        [[ -n "$vl" && -n "$hy" ]] && r_ok "Подписка отдаётся и содержит VLESS и Hysteria2" \
            || r_fail "Подписка ${SUB_BASE}… не отдаёт обе ссылки (VLESS: ${vl:+есть}${vl:-нет}, Hysteria2: ${hy:+есть}${hy:-нет})"
    else
        r_fail "Не удалось получить служебного пользователя ${HC_USER}"
    fi
    local target res
    target=$(api GET /inbounds/list 2>/dev/null | jq -r '.obj[]? | select(.protocol == "vless") | .streamSettings
        | (if type == "string" then fromjson else . end) | .realitySettings | (.target // .dest)' 2>/dev/null | head -1 || true)
    if [[ -n "$target" ]]; then
        res=$(api POST /server/scanRealityTarget --data-urlencode "target=${target}" 2>/dev/null || true)
        jq -e '.obj.feasible == true' >/dev/null 2>&1 <<<"$res" && r_ok "Маскировка Reality ${target} в порядке" \
            || r_fail "Маскировка Reality ${target} не проходит проверку: $(jq -r '.obj.reason // "?"' <<<"$res" 2>/dev/null) — смени Target/SNI в панели"
    fi

    echo "— Сквозной тест (локальный клиент → сервер → интернет)"
    local ip_out
    if [[ -n "${vl:-}" ]]; then
        ip_out=$(e2e "$vl" 10871)
        [[ -n "$ip_out" ]] && r_ok "VLESS+Reality работает, выход в интернет с IP ${ip_out}" \
            || r_fail "VLESS+Reality: клиент не смог выйти в интернет через сервер"
    fi
    if [[ -n "${hy:-}" ]]; then
        ip_out=$(e2e "$hy" 10872)
        [[ -n "$ip_out" ]] && r_ok "Hysteria2 работает, выход в интернет с IP ${ip_out}" \
            || r_fail "Hysteria2: клиент не смог выйти в интернет через сервер"
    fi

    if [[ "$external" == yes ]]; then
        echo "— Доступность снаружи (check-host.net)"
        local out port ru w ru_ok ru_all w_ok w_all name
        if out=$(probe "$SERVER_IP" 443 "$SUB_PORT" "$PANEL_PORT" 80); then
            while read -r port ru w; do
                case "$port" in 443) name="443/tcp (VLESS)";; 80) name="80/tcp (продление сертификата)";;
                    "$SUB_PORT") name="${port}/tcp (подписки)";; *) name="${port}/tcp (панель)";; esac
                if [[ "$ru" == "?" ]]; then r_warn "$name: проверка не выполнилась"; continue; fi
                ru_ok=${ru%/*}; ru_all=${ru#*/}; w_ok=${w%/*}; w_all=${w#*/}
                if (( (w_ok > 0 || w_all == 0) && (ru_ok > 0 || ru_all == 0) )); then r_ok "$name доступен (Россия ${ru}, Европа ${w})"
                elif (( w_ok > 0 )); then r_fail "$name недоступен из России (${ru}), из Европы доступен (${w}) — похоже на блокировку IP в РФ"
                elif (( ru_ok > 0 )); then r_warn "$name доступен из России (${ru}), но не из Европы (${w})"
                else r_fail "$name закрыт снаружи — открой его в фаерволе хостера"; fi
            done <<<"$out"
        else
            r_warn "check-host.net недоступен — внешнюю проверку пропускаю"
        fi
        echo "  (443/udp снаружи не проверяется; работу Hysteria2 подтверждает сквозной тест, а с телефона — клиент)"
    fi

    echo
    echo -e "Итог: ${c_g}${N_OK} OK${c_0}, ${c_y}${N_WARN} предупреждений${c_0}, ${c_r}${N_FAIL} ошибок${c_0}"
    (( N_FAIL == 0 ))
}

usage() {
    cat <<EOF
vpn add <имя> <ГБ> <дней> [комментарий]  — новый пользователь (0 = без лимита / бессрочно)
vpn list                                 — все пользователи, трафик, сроки
vpn link <имя>                           — ссылка подписки + QR
vpn renew <имя> <дней> [ГБ]              — продлить и обнулить трафик (ГБ — новый лимит)
vpn reset <имя>                          — обнулить трафик
vpn off|on <имя>                         — отключить / включить
vpn del <имя>                            — удалить
vpn panel                                — адрес и логин панели
vpn check [--local]                      — полная диагностика (--local: без проверки снаружи)
EOF
}

cmd=${1:-help}; shift || true
case "$cmd" in
_probe) probe "$@" ;;
add)
    load_env
    [[ $# -ge 3 ]] || { usage; exit 1; }
    check_name "$1"; is_num "$2" && is_num "$3" || { echo "ГБ и дни — числа"; exit 1; }
    add_client "$@"
    echo "Создан: $1 (лимит: $([[ $2 == 0 ]] && echo без лимита || echo "$2 ГБ"), срок: $([[ $3 == 0 ]] && echo бессрочно || echo "$3 дн."))"
    show_link "$1"
    ;;
list)
    load_env
    r=$(api GET /clients/list); ok "$r"
    tab() { if command -v column >/dev/null; then column -t -s $'\t'; else cat; fi; }
    {
    printf 'ИМЯ\tВКЛ\tИСПОЛЬЗ.\tЛИМИТ\tДО\tКОММЕНТАРИЙ\n'
    jq -r --argjson G $GiB --arg hc "$HC_USER" '.obj[] | select(.email != $hc) | [ .email,
        (if .enable and (.traffic.enable // true) then "да" else "нет" end),
        ((((.traffic.up // 0) + (.traffic.down // 0)) / $G * 100 | floor) / 100 | tostring) + " ГБ",
        (if .totalGB > 0 then ((.totalGB / $G * 100 | floor) / 100 | tostring) + " ГБ" else "∞" end),
        (.expiryTime // 0 | tostring), (if (.comment // "") == "" then "-" else .comment end) ] | @tsv' <<<"$r" |
    while IFS=$'\t' read -r n e u t x cm; do
        if [[ "$x" == 0 ]]; then d="бессрочно"; elif (( x < 0 )); then d="с_1-го_подкл."; else d=$(date -d "@$((x/1000))" '+%d.%m.%Y_%H:%M'); fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$e" "$u" "$t" "$d" "$cm"
    done
    } | tab
    ;;
link) load_env; check_name "${1:-}"; show_link "$1" ;;
renew)
    load_env
    [[ $# -ge 2 ]] || { usage; exit 1; }
    check_name "$1"; is_num "$2" || { echo "Дни — число"; exit 1; }
    c=$(get_client "$1"); cur=$(jq -r '.expiryTime // 0' <<<"$c"); base=$(now_ms)
    (( cur > base )) && base=$cur
    if (( cur == 0 && ${2%.*} == 0 )); then exp=0; else exp=$(( base + ${2%.*} * 86400000 )); fi
    c=$(jq --argjson exp "$exp" '.expiryTime = $exp | .enable = true' <<<"$c")
    if [[ -n "${3:-}" ]]; then is_num "$3" || { echo "ГБ — число"; exit 1; }
        c=$(jq --arg gb "$3" --argjson G $GiB '.totalGB = (($gb|tonumber) * $G | floor)' <<<"$c"); fi
    save_client "$c"
    ok "$(api POST "/clients/resetTraffic/$1")"
    if [[ "$exp" == 0 ]]; then until_s="бессрочно"; else until_s="до $(date -d "@$(( exp / 1000 ))" '+%d.%m.%Y %H:%M')"; fi
    echo "Продлён: $1, ${until_s}, трафик обнулён"
    ;;
reset) load_env; check_name "${1:-}"; ok "$(api POST "/clients/resetTraffic/$1")"; echo "Трафик $1 обнулён" ;;
off|on)
    load_env; check_name "${1:-}"; en=true; [[ $cmd == off ]] && en=false
    save_client "$(jq --argjson en $en '.enable = $en' <<<"$(get_client "$1")")"
    echo "$1: $([[ $en == true ]] && echo включён || echo отключён)"
    ;;
del) load_env; check_name "${1:-}"; ok "$(api POST "/clients/del/$1")"; echo "Удалён: $1" ;;
panel) cat /etc/vpn/panel.txt ;;
check) load_env; if [[ "${1:-}" == --local ]]; then do_check no; else do_check yes; fi ;;
*) usage ;;
esac
VPNCLI
    chmod 755 /usr/local/bin/vpn
}

# =========================================================================== итог
finish() {
    log "Создаю твоего пользователя и проверяю всё целиком"
    vpn add me 0 0 "владелец" >/dev/null
    echo
    local rc=0
    vpn check | tee "$VPN_DIR/check-install.txt" || rc=$?
    echo
    echo -e "${c_b}================ ГОТОВО ================${c_0}"
    cat "$VPN_DIR/panel.txt"
    echo "Reality target: ${REALITY_TARGET}"
    echo "Сертификат:     ${CERT_MODE}"
    echo
    echo "Твоя подписка (пользователь 'me', без лимитов):"
    vpn link me
    echo "Управление: vpn add vasya 50 30 | vpn list | vpn renew vasya 30 | vpn check | vpn help"
    echo "Данные панели: ${VPN_DIR}/panel.txt (видит только root), отчёт проверки: ${VPN_DIR}/check-install.txt"
    if (( rc != 0 )); then
        echo -e "\n${c_y}Проверка нашла ошибки (см. [FAIL] выше). Исправь и перепроверь: vpn check${c_0}"
    fi
}

main() {
    preflight
    prepare_system
    net_checks
    choose_params
    install_cli
    setup_firewall
    external_precheck
    install_xui
    setup_certs
    connect_api
    pick_reality_target
    create_inbounds
    configure_panel
    write_env
    finish
}

[[ "${VPN_SETUP_LIB:-0}" == 1 ]] || main "$@"
