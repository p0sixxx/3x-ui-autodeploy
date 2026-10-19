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
#   SUB_TITLE="Мой VPN"        — название подписки в клиентах (по умолчанию VPN)
#   SUB_ANNOUNCE="текст"       — описание под подпиской ({{EMAIL}} — имя пользователя, \n — перенос)
#   SUPPORT_URL=@username      — кнопка «Поддержка» (ссылка или @username в Telegram)
#   ACME_EMAIL                 — e-mail для Let's Encrypt
#   PROTOCOLS=vless,hy2,xhttp  — какие серверы создать: vless (VLESS TCP + Reality, 443/tcp), hy2 (Hysteria2, 443/udp),
#                                xhttp (VLESS XHTTP + Reality, 8443/tcp), http3 (VLESS XHTTP по HTTP/3, 4443/udp; нужен SELF_DOMAIN
#                                и vless или xhttp). Не задано: спросит в терминале (Enter — vless, hy2, xhttp)
#   SELF_DOMAIN=cdn.example.com — свой домен (A-запись → сервер): Reality получает SNI = домен и сайт-заглушку
#                                с сертификатом Let's Encrypt (как vpn reality self); обязателен для http3
#   XHTTP_PORT=8443            — порт сервера VLESS + XHTTP + Reality (0 — не создавать)
#   HOP_PORTS=20000-50000      — включить port hopping для Hysteria2 (по умолчанию выключен)
#   FASTEST=0                  — не создавать сервер «Лучший сервер» (по умолчанию создаётся)
#   NODE=1                     — поставить как ноду для главной панели: без своих пользователей,
#                                в конце печатает команду «vpn node add …» для главного сервера
#   NO_FIREWALL=1              — не трогать ufw
#   SKIP_EXTERNAL_CHECK=1      — не проверять порты снаружи (check-host.net)
#   ASSUME_YES=1               — на все вопросы отвечать «да» (без интерактива)
#   XUI_VERSION=v3.9.0         — версия 3x-ui

set -Eeuo pipefail
trap 'echo -e "\n\033[0;31m[ОШИБКА] строка $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

XUI_VERSION="${XUI_VERSION:-v3.9.0}"
# запасной список, если в сети хостера ничего не нашлось; Cloudflare/Google/Amazon/Microsoft не берём —
# их SNI на чужом IP ТСПУ режет
REALITY_CANDIDATES="www.samsung.com:443,www.nvidia.com:443,www.amd.com:443,www.intel.com:443,www.sony.com:443"
VPN_DIR=/etc/vpn
XUI_BIN=/usr/local/x-ui/x-ui
TMP_LISTENERS=()

c_g='\033[0;32m'; c_y='\033[0;33m'; c_r='\033[0;31m'; c_b='\033[1m'; c_0='\033[0m'
log()  { echo -e "${c_g}==>${c_0} $*"; }
ok()   { echo -e "    ${c_g}[OK]${c_0} $*"; }
warn() { echo -e "    ${c_y}[!!]${c_0} $*"; }
die()  { echo -e "\n${c_r}[СТОП]${c_0} $*" >&2; exit 1; }
rnd()  { openssl rand -hex 32 | tr -dc 'a-z0-9' | head -c "$1"; }
norm_support() { local v=$1; [[ "$v" == @* ]] && v="https://t.me/${v#@}"; echo "$v"; }

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
    # os-release читаем в подоболочке: в нём есть SUPPORT_URL (help.ubuntu.com), который перетёр бы наш параметр
    local ID VERSION_ID
    read -r ID VERSION_ID < <(. /etc/os-release; echo "${ID:-?} ${VERSION_ID:-?}")
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

choose_protocols() { # → P_VLESS, P_HY2, P_XHTTP (0/1); PROTOCOLS=vless,hy2,xhttp или меню в терминале
    local sel=${PROTOCOLS:-} t a
    if [[ -z "$sel" ]]; then
        sel="vless,hy2,xhttp"
        if [[ "${ASSUME_YES:-0}" != 1 && "${NODE:-0}" != 1 && -t 0 ]]; then
            echo
            echo "    Какие серверы (протоколы) создать? Можно один или несколько:"
            echo "      1) VLESS TCP + Reality         443/tcp   основной, работает почти везде"
            echo "      2) Hysteria2                   443/udp   быстрый, по UDP (если оператор режет TCP)"
            echo "      3) VLESS XHTTP + Reality       ${XHTTP_PORT:-8443}/tcp   лучше переносит «заморозку» TCP"
            echo "      4) VLESS XHTTP по HTTP/3       4443/udp  QUIC, когда глушат TCP (нужен свой домен и пункт 1 или 3)"
            read -r -p "    Номера через пробел или запятую [1 2 3]: " a || true
            [[ -n "$a" ]] && sel=$a
            if [[ " ${a//,/ } " == *" 4 "* && -z "${SELF_DOMAIN:-}" ]]; then
                read -r -p "    Домен для HTTP/3 и Reality (A-запись должна указывать на ${SERVER_IP}), например cdn.example.com: " SELF_DOMAIN || true
            fi
        fi
    fi
    P_VLESS=0; P_HY2=0; P_XHTTP=0; P_H3=0
    for t in $(tr ',;' '  ' <<<"${sel,,}"); do
        case "$t" in
            1|vless|tcp|reality) P_VLESS=1;;
            2|hy2|hysteria|hysteria2) P_HY2=1;;
            3|xhttp) P_XHTTP=1;;
            4|http3|h3) P_H3=1;;
            all|все) P_VLESS=1; P_HY2=1; P_XHTTP=1;;
            *) die "Неизвестный протокол «$t». Допустимо: vless, hy2, xhttp, http3 (через запятую) или номера 1 2 3 4";;
        esac
    done
    [[ "${XHTTP_PORT:-}" == 0 ]] && P_XHTTP=0
    (( P_VLESS + P_HY2 + P_XHTTP + P_H3 > 0 )) || die "Не выбран ни один протокол"
    (( P_XHTTP )) || XHTTP_PORT=0
    if (( P_H3 )); then
        (( P_VLESS || P_XHTTP )) || die "HTTP/3 строится на Reality-сервере: выбери ещё vless или xhttp"
        [[ -n "${SELF_DOMAIN:-}" ]] || die "Для HTTP/3 нужен свой домен: SELF_DOMAIN=cdn.example.com (A-запись → ${SERVER_IP})"
    fi
    if [[ -n "${SELF_DOMAIN:-}" ]]; then
        SELF_DOMAIN=${SELF_DOMAIN,,}
        [[ "$SELF_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "SELF_DOMAIN='$SELF_DOMAIN' не похож на домен"
        (( P_VLESS || P_XHTTP )) || { warn "SELF_DOMAIN нужен Reality-серверу (vless или xhttp), а их нет: домен пропускаю"; SELF_DOMAIN=""; }
    fi
    if [[ -n "${SELF_DOMAIN:-}" ]]; then
        local dips; dips=$( { getent ahostsv4 "$SELF_DOMAIN" 2>/dev/null || true; } | awk '{print $1}' | sort -u | xargs)
        [[ " $dips " == *" ${SERVER_IP} "* ]] \
            || die "A-запись $SELF_DOMAIN указывает на «${dips:-ничего}», а не на ${SERVER_IP}. Исправь её у регистратора, подожди 5–15 минут и запусти снова."
        ok "Домен $SELF_DOMAIN → ${SERVER_IP}"
    fi
    ok "Серверы: $( ((P_VLESS)) && echo -n 'VLESS TCP ' )$( ((P_HY2)) && echo -n 'Hysteria2 ' )$( ((P_XHTTP)) && echo -n 'VLESS XHTTP ' )$( ((P_H3)) && echo -n 'VLESS XHTTP HTTP3' )"
}

choose_params() {
    choose_protocols
    PUBLIC_HOST="${DOMAIN:-$SERVER_IP}"
    PANEL_PORT="${PANEL_PORT:-$(free_port)}"
    SUB_PORT="${SUB_PORT:-$(free_port)}"
    [[ "$SUB_PORT" == "$PANEL_PORT" ]] && SUB_PORT=$(free_port)
    XHTTP_PORT="${XHTTP_PORT:-8443}"
    if [[ "$XHTTP_PORT" != 0 ]] && { [[ "$XHTTP_PORT" == "$PANEL_PORT" || "$XHTTP_PORT" == "$SUB_PORT" ]] || port_busy "$XHTTP_PORT" tcp; }; then
        warn "Порт ${XHTTP_PORT} для XHTTP занят — XHTTP не создаю (можно позже: vpn xhttp on <порт>)"; XHTTP_PORT=0
    fi
    if [[ -n "${HOP_PORTS:-}" && ! "$HOP_PORTS" =~ ^[0-9]+-[0-9]+$ ]]; then die "HOP_PORTS='$HOP_PORTS': нужен диапазон вида 20000-50000"; fi
    local p
    for p in "$PANEL_PORT" "$SUB_PORT"; do
        [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1024 && p < 65536 )) || die "Порт $p некорректен (нужен 1025–65535)"
        port_busy "$p" tcp && die "Порт $p уже занят"
    done
    WEB_PATH=$(rnd 16); ADMIN_USER="admin$(rnd 4)"; ADMIN_PASS=$(rnd 20)
    ok "Панель: порт $PANEL_PORT, подписки: порт $SUB_PORT$( [[ $XHTTP_PORT != 0 ]] && echo ", XHTTP: порт $XHTTP_PORT")"
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
    if (( P_VLESS )); then ufw allow 443/tcp comment vless-reality >/dev/null; fi
    if (( P_HY2 )); then ufw allow 443/udp comment hysteria2 >/dev/null; fi
    ufw allow "${PANEL_PORT}/tcp" comment 3x-ui-panel >/dev/null
    ufw allow "${SUB_PORT}/tcp" comment 3x-ui-sub >/dev/null
    if [[ "$XHTTP_PORT" != 0 ]]; then ufw allow "${XHTTP_PORT}/tcp" comment vless-xhttp >/dev/null; fi
    ufw --force enable >/dev/null
    ufw status | grep -q "Status: active" || die "ufw не включился"
    ok "ufw включён: ssh(${ssh_ports//$'\n'/,}), 80, $( ((P_VLESS)) && echo -n '443/tcp, ' )$( ((P_HY2)) && echo -n '443/udp, ' )${PANEL_PORT}, ${SUB_PORT}"
}

# =========================================================================== 4. внешняя проверка портов
external_precheck() {
    [[ "${SKIP_EXTERNAL_CHECK:-0}" == 1 ]] && { warn "Внешняя проверка портов пропущена (SKIP_EXTERNAL_CHECK=1)"; return; }
    log "Проверка портов снаружи (check-host.net: узлы в России и Европе)"
    local p
    local xp=(); [[ "$XHTTP_PORT" != 0 ]] && xp=("$XHTTP_PORT")
    local tp=(); (( P_VLESS )) && tp=(443)
    for p in 80 "${tp[@]+"${tp[@]}"}" "$PANEL_PORT" "$SUB_PORT" "${xp[@]+"${xp[@]}"}"; do
        socat "TCP-LISTEN:${p},reuseaddr,fork" SYSTEM:true >/dev/null 2>&1 &
        TMP_LISTENERS+=($!)
    done
    sleep 1
    local out
    if ! out=$(vpn _probe "$SERVER_IP" 80 "${tp[@]+"${tp[@]}"}" "$PANEL_PORT" "$SUB_PORT" "${xp[@]+"${xp[@]}"}"); then
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
            "$XHTTP_PORT") name="$port/tcp (VLESS XHTTP)";;
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
                "$XHTTP_PORT") warn "$name закрыт снаружи — XHTTP не создаю (открой порт у хостера и включи позже: vpn xhttp on ${XHTTP_PORT})"
                     XHTTP_PORT=0;;
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
    if (( P_HY2 )); then warn "443/udp (Hysteria2) снаружи проверить нельзя — проверю сквозным тестом после установки; не забудь открыть его у хостера"; fi
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
    echo "    Ищу сайт в сети хостера (соседние IP), до 2 минут…"
    local found t h l
    found=$(API="$API" TOKEN="$TOKEN" SERVER_IP="$SERVER_IP" vpn _scan || true)
    if [[ -n "$found" ]]; then
        read -r t h l <<<"$(head -1 <<<"$found")"
        REALITY_TARGET=$t; R_HOST=$h
        ok "Выбран соседний сайт ${R_HOST} (${REALITY_TARGET}, ${l} мс)"
        return
    fi
    warn "В сети хостера подходящих сайтов не нашлось — беру из запасного списка (может хуже работать из РФ)"
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
    IB_VLESS=""; IB_HY2=""

    if (( P_VLESS )); then
    res=$(api_json POST /inbounds/add "$(jq -n \
        --arg priv "$priv" --arg pub "$pub" --arg s1 "$sid1" --arg s2 "$sid2" \
        --arg target "$REALITY_TARGET" --arg sni "$R_HOST" --arg host "$PUBLIC_HOST" --arg lbl "$SERVER_LABEL" '{
        remark: ($lbl + " · VLESS"), enable: true, listen: "", port: 443, protocol: "vless",
        expiryTime: 0, total: 0, shareAddrStrategy: "custom", shareAddr: $host,
        settings: { clients: [], decryption: "none", encryption: "none", fallbacks: [] },
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
    fi

    if (( P_HY2 )); then

    local pins='[]' sni=""
    [[ -n "${DOMAIN:-}" ]] && sni="$DOMAIN"
    if [[ "$CERT_MODE" == selfsigned ]]; then
        pins=$(jq -nc --arg p "$(openssl x509 -in "$CERT" -outform der | openssl dgst -sha256 -hex | awk '{print $NF}')" '[$p]')
    fi
    res=$(api_json POST /inbounds/add "$(jq -n \
        --arg crt "$CERT" --arg key "$KEY" --arg sni "$sni" --argjson pins "$pins" \
        --arg host "$PUBLIC_HOST" --arg mq "https://${R_HOST}" --arg lbl "$SERVER_LABEL" '{
        remark: ($lbl + " · Hysteria2"), enable: true, listen: "", port: 443, protocol: "hysteria",
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
    fi
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
             --arg crt "$CERT" --arg key "$KEY" --arg title "${SUB_TITLE:-VPN}" \
             --arg sup "$(norm_support "${SUPPORT_URL:-}")" --arg ann "${SUB_ANNOUNCE:-}" '.obj
        | .subEnable = true | .subPort = $port | .subURI = $uri
        | .subTitle = $title | .subSupportUrl = $sup | .subAnnounce = ($ann | gsub("\\\\n"; "\n"))
        | .subProfileMode = "builtin" | .subProfileUrl = "" | .remarkTemplate = "{{INBOUND}}"
        | .subUpdates = 6 | .timeLocation = "Europe/Moscow"
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
INBOUNDS='$(jq -nc --arg a "${IB_VLESS:-}" --arg b "${IB_HY2:-}" '[$a, $b] | map(select(. != "") | tonumber)')'
VLESS_ID='${IB_VLESS:-}'
HY2_ID='${IB_HY2:-}'
RT_TARGET='${REALITY_TARGET:-}'
RT_SNI='${R_HOST:-}'
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
ENV_FILE=${VPN_ENV_FILE:-/etc/vpn/vpn.env}
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

add_client() { # add_client <имя> <ГБ> <дней> [комментарий] [устройств] [IP] [ID подписки]
    local exp=0
    [[ "$3" != 0 ]] && exp=$(( $(now_ms) + ${3%.*} * 86400000 ))
    ok "$(api_json POST /clients/add "$(jq -n --arg e "$1" --arg sub "${7:-$(openssl rand -hex 8)}" --arg gb "$2" \
        --argjson exp "$exp" --arg cm "${4:-}" --argjson ib "$INBOUNDS" --argjson G $GiB \
        --argjson dev "${5:-0}" --argjson ips "${6:-0}" \
        '{client: {email: $e, subId: $sub, flow: "xtls-rprx-vision", totalGB: (($gb|tonumber) * $G | floor),
          expiryTime: $exp, limitIp: $ips, limitHwid: $dev, tgId: 0, comment: $cm, enable: true}, inboundIds: $ib}')")"
}

# ---------------------------------------------------------------- лимиты устройств и IP
parse_limits() { # вынимает --devices N и --ips N, остальные аргументы → REST
    DEV=""; IPS=""; SUBID=""; REST=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sub-id)
                [[ $# -ge 2 && "$2" =~ ^[A-Za-z0-9_-]{3,64}$ ]] || { echo "--sub-id: нужен ID подписки (последняя часть старой ссылки, латиница, цифры, _ -)"; exit 1; }
                SUBID=$2; shift 2 ;;
            --devices|--ips)
                [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "$1: нужно число (0 — без ограничения)"; exit 1; }
                if [[ "$1" == --devices ]]; then DEV=$2; else IPS=$2; fi
                shift 2 ;;
            *) REST+=("$1"); shift ;;
        esac
    done
}
limits_text() { # <устройств> <IP>
    local d="без лимита" i="без лимита"
    (( ${1:-0} > 0 )) && d="$1"
    (( ${2:-0} > 0 )) && i="$2"
    echo "устройств: ${d}, одновременных IP: ${i}"
}
hwid_note() {
    echo "Подписку на новом устройстве выдаст только клиент, передающий ID устройства (Happ, INCY, v2RayTun)."
    echo "Клиенты без этого (sing-box, роутеры с Podkop/Tachyon) при лимите устройств подписку не получат."
}
fail2ban_note() {
    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "Внимание: fail2ban не запущен — лимит IP не сработает. Включить: x-ui → IP Limit Management → Install."
    fi
}
set_limits() { # <имя> — применяет DEV/IPS
    local c; c=$(get_client "$1")
    if [[ -n "$DEV" ]]; then c=$(jq --argjson d "$DEV" '.limitHwid = $d' <<<"$c"); fi
    if [[ -n "$IPS" ]]; then c=$(jq --argjson i "$IPS" '.limitIp = $i' <<<"$c"); fi
    save_client "$c"
}
do_limit() {
    parse_limits "$@"; set -- "${REST[@]+"${REST[@]}"}"
    local who=${1:-} c e n=0
    [[ -n "$who" ]] || { usage; exit 1; }
    if [[ -z "$DEV" && -z "$IPS" ]]; then
        if [[ "$who" == default ]]; then echo "Для новых пользователей: $(limits_text "${DEF_DEVICES:-0}" "${DEF_IPS:-0}")"
        else check_name "$who"; c=$(get_client "$who"); echo "$who: $(limits_text "$(jq -r '.limitHwid // 0' <<<"$c")" "$(jq -r '.limitIp // 0' <<<"$c")")"; fi
        return
    fi
    case "$who" in
        default)
            if [[ -n "$DEV" ]]; then env_set DEF_DEVICES "$DEV"; fi
            if [[ -n "$IPS" ]]; then env_set DEF_IPS "$IPS"; fi
            echo "Для новых пользователей: $(limits_text "${DEF_DEVICES:-0}" "${DEF_IPS:-0}")" ;;
        all)
            for e in $(all_emails | jq -r '.[]'); do
                [[ "$e" == "$HC_USER" || "$e" == me ]] && continue
                set_limits "$e"; n=$((n + 1))
            done
            echo "Применено к ${n} пользователям (кроме me)." ;;
        *)
            check_name "$who"; set_limits "$who"
            c=$(get_client "$who")
            echo "$who: $(limits_text "$(jq -r '.limitHwid // 0' <<<"$c")" "$(jq -r '.limitIp // 0' <<<"$c")")" ;;
    esac
    if [[ -n "$DEV" ]] && (( DEV > 0 )); then hwid_note; fi
    if [[ -n "$IPS" ]] && (( IPS > 0 )); then fail2ban_note; fi
}
do_devices() {
    local name=${1:-} r lim
    check_name "$name"
    case "${2:-}" in
        reset) ok "$(api DELETE "/clients/hwids/$name")"; echo "Устройства $name сброшены — можно подключать заново." ;;
        "")
            r=$(api POST "/clients/hwids/$name"); ok "$r"
            lim=$(get_client "$name" | jq -r '.limitHwid // 0')
            echo "$name: устройств $(jq '.obj | length' <<<"$r") из $( (( lim > 0 )) && echo "$lim" || echo "∞")"
            jq -r '.obj[]? | "  #\(.id)  \([.deviceModel, .deviceOs, .osVersion] | map(select(. != "" and . != null)) | join(" "))  \(.userAgent)  последний раз: \(.lastSeen / 1000 | strflocaltime("%d.%m %H:%M"))"' <<<"$r"
            echo "Удалить одно: vpn devices $name <номер>; все: vpn devices $name reset" ;;
        *)
            [[ "$2" =~ ^[0-9]+$ ]] || { echo "Номер устройства — число из списка vpn devices $name"; exit 1; }
            ok "$(api DELETE "/clients/hwids/$name/$2")"; echo "Устройство #$2 удалено у $name." ;;
    esac
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
              ok: ((.value // [])[0] | if type == "object" then (has("time") or ((.error // "") | test("refused"; "i"))) else false end)}] as $a
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
    net = q.get("type", "tcp")
    if q.get("security") == "tls":
        ss = {"network": net, "security": "tls",
              "tlsSettings": {"serverName": q.get("sni") or host, "fingerprint": q.get("fp") or "chrome",
                              "alpn": [a for a in q.get("alpn", "").split(",") if a] or ["h2", "http/1.1"]}}
    else:
        ss = {"network": net, "security": "reality",
              "realitySettings": {"serverName": q.get("sni", ""), "fingerprint": q.get("fp") or "chrome",
                                  "publicKey": q["pbk"], "shortId": q.get("sid", ""), "spiderX": "/"}}
    if net == "xhttp":
        ss["xhttpSettings"] = {"path": q.get("path", "/"), "host": q.get("host", ""), "mode": q.get("mode", "auto")}
    ob = {"protocol": "vless",
          "settings": {"vnext": [{"address": host, "port": port, "users": [{"id": user, "encryption": "none", "flow": q.get("flow", "")}]}]},
          "streamSettings": ss}
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

# ---------------------------------------------------------------- маскировка Reality
vless_id() { if [[ -v VLESS_ID ]]; then echo "$VLESS_ID"; else jq -r '.[0] // empty' <<<"$INBOUNDS"; fi; }   # у старых установок — первый в INBOUNDS
reality_id() { local i; i=$(vless_id); [[ -n "$i" ]] && echo "$i" || xhttp_id; }   # сервер, чьи настройки Reality общие
ref_id() { local i; for i in "$(vless_id)" "$(hy2_id)" "$(xhttp_id)"; do [[ -n "$i" ]] && { echo "$i"; return; }; done; }
reality_inbound() {
    local r id; id=$(reality_id)
    [[ -n "$id" ]] || { echo "На этом сервере нет серверов с Reality (создан только Hysteria2). Добавить: vpn xhttp on" >&2; return 1; }
    r=$(api GET "/inbounds/get/$id"); ok "$r"; jq -c .obj <<<"$r"
}
reality_settings() { reality_inbound | jq -c '.streamSettings | (if type == "string" then fromjson else . end) | .realitySettings'; }
reality_probe() { # <target host:port> <sni>
    api POST /server/scanRealityTarget --data-urlencode "target=$1" --data-urlencode "sni=$2"
}
risky_sni() { [[ "${1:-}" =~ (^|\.)(cloudflare|google|googleapis|gstatic|youtube|amazon|amazonaws|microsoft|apple|icloud|akamai|fastly)\.[a-z]+$ ]]; }
inbound_patch() { # <id> <jq-фильтр> [аргументы jq] — правит inbound целиком, клиенты остаются
    local id=$1 f=$2 r body; shift 2
    r=$(api GET "/inbounds/get/$id"); ok "$r"
    body=$(jq -c "$@" ".obj
        | .streamSettings |= (if type == \"string\" then fromjson else . end)
        | .settings |= (if type == \"string\" then fromjson else . end)
        | .sniffing |= (if type == \"string\" then fromjson else . end)
        | del(.clientStats) | ${f}" <<<"$r")
    ok "$(api_json POST "/inbounds/update/$id" "$body")"
}
reality_apply() { # <target host:port> <sni> — меняет target и serverNames (и у XHTTP), ключи и shortId остаются
    local id
    for id in "$(vless_id)" "$(xhttp_id)"; do
        [[ -n "$id" ]] || continue
        inbound_patch "$id" '.streamSettings.realitySettings.target = $t | del(.streamSettings.realitySettings.dest)
            | .streamSettings.realitySettings.serverNames = [$s]' --arg t "$1" --arg s "$2"
    done
}
reality_scan() { # строки «<ip>:443 <домен> <мс>» — подходящие сайты в сети сервера, лучшие первыми
    local a b c net res out
    IFS=. read -r a b c _ <<<"$SERVER_IP"
    [[ -n "$c" ]] || return 1
    for net in "$a.$b.$c.0/24" "$a.$b.$(( c > 0 ? c - 1 : 1 )).0/24" "$a.$b.$(( c < 255 ? c + 1 : 254 )).0/24"; do
        res=$(api POST /server/scanRealityTargets --max-time 300 --data-urlencode "targets=$net" 2>/dev/null || true)
        out=$(jq -r --arg me "$SERVER_IP" '.obj[]? | select(.feasible == true and .ip != $me and (.host // "") != "")
                 | "\(.ip):\(.port) \(.host) \(.latencyMs)"' <<<"$res" 2>/dev/null | while read -r t h l; do
                 risky_sni "$h" || echo "$t $h $l"; done)
        [[ -n "$out" ]] && { echo "$out"; return 0; }
    done
    return 1
}

do_reality() {
    local force=no args=() a
    for a in "$@"; do [[ "$a" == --force ]] && force=yes || args+=("$a"); done
    set -- "${args[@]+"${args[@]}"}"
    local rs t sni found l res
    [[ -n "$(reality_id)" ]] || { echo "Нет серверов с Reality (создан только Hysteria2). Добавить: vpn xhttp on"; exit 1; }
    if [[ $# -eq 0 ]]; then
        rs=$(reality_settings)
        echo "Сейчас: SNI $(jq -r '.serverNames | join(",")' <<<"$rs"), target $(jq -r '.target // .dest' <<<"$rs")"
        echo "Сменить: vpn reality self <свой домен> | vpn reality auto | vpn reality <домен> | vpn reality <ip:443> <домен>"
        return
    fi
    if [[ "$1" == self ]]; then do_reality_self "${2:-}"; return; fi
    if [[ "$1" == auto ]]; then
        echo "Ищу сайты с TLS 1.3 + h2 + X25519 в сети сервера (${SERVER_IP%.*}.0/24 и соседние), до 2–3 минут…"
        found=$(reality_scan || true)
        [[ -n "$found" ]] || { echo "Подходящих сайтов в сети хостера не нашлось. Укажи домен вручную: vpn reality <домен>"; exit 1; }
        echo "Найдено (лучшие):"
        head -5 <<<"$found" | while read -r t sni l; do echo "  ${sni}  (${t}, ${l} мс)"; done
        read -r t sni l <<<"$(head -1 <<<"$found")"
    else
        t=$1; [[ "$t" == *:* ]] || t="$t:443"
        sni=${2:-${t%:*}}
        if [[ "$sni" =~ ^[0-9.]+$ ]]; then echo "Для IP укажи домен (SNI) вторым аргументом: vpn reality $t <домен>"; exit 1; fi
        res=$(reality_probe "$t" "$sni")
        if ! jq -e '.obj.feasible == true' >/dev/null 2>&1 <<<"$res"; then
            echo "${sni} (${t}) не подходит для Reality: $(jq -r '.obj.reason // .msg // "?"' <<<"$res" 2>/dev/null)"
            [[ $force == yes ]] || { echo "Применить всё равно: добавь --force"; exit 1; }
        fi
        risky_sni "$sni" && echo "Внимание: ${sni} — крупный CDN, на чужом IP его часто блокируют в РФ."
    fi
    reality_apply "$t" "$sni"
    [[ -n "${SELF_DOMAIN:-}" ]] && env_set SELF_DOMAIN ""
    echo "Маскировка сменена: SNI ${sni}, target ${t}."
    echo "Клиентам нужно обновить подписку (SNI в ссылке поменялся). Проверка: vpn check --local"
}

# ---------------------------------------------------------------- Reality на свой домен (self-steal)
# SNI = свой домен, A-запись которого указывает на этот сервер; маскировка — свой сайт на localhost
# с настоящим сертификатом Let's Encrypt. SNI совпадает с IP — DPI не за что зацепиться.
SELF_DIR=/etc/vpn/self
SELF_WWW=/var/www/vpn-self
SELF_NGINX=/etc/nginx/conf.d/vpn-self.conf
ACME_SH=${ACME_SH:-/root/.acme.sh/acme.sh}
self_ipv4() { { getent ahostsv4 "$1" 2>/dev/null || true; } | awk '{print $1}' | sort -u | xargs; }
self_ipv6() { { getent ahostsv6 "$1" 2>/dev/null || true; } | awk '$1 !~ /^::ffff:/ {print $1}' | sort -u | xargs; }
self_https_ok() { # <домен> <порт> — сайт отвечает по TLS с проверкой сертификата и по HTTP/2
    [[ "$(curl -s --noproxy '*' -o /dev/null --max-time 8 --http2 -w '%{http_version}' --resolve "$1:$2:127.0.0.1" "https://$1:$2/" 2>/dev/null)" == 2 ]]
}
self_free_port() { # порт из прошлого запуска (наш nginx уже на нём) или первый свободный
    local p
    p=$(grep -so 'listen 127.0.0.1:[0-9]*' "$SELF_NGINX" | head -1 | cut -d: -f2)
    [[ -n "$p" ]] && { echo "$p"; return; }
    for p in 8444 8445 8446 9444 10443; do
        [[ -z "$(ss -Hltn "sport = :$p" 2>/dev/null)" ]] && { echo "$p"; return; }
    done
    return 1
}
self_site() { # <домен> — нейтральная страница-заглушка
    mkdir -p "$SELF_WWW"
    cat > "$SELF_WWW/index.html" <<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$1</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;font:16px/1.5 system-ui,sans-serif;background:#f6f7f9;color:#222}
main{max-width:34rem;padding:2rem;text-align:center}h1{font-weight:600;font-size:1.6rem;margin:0 0 .5rem}p{color:#666;margin:0}</style>
</head><body><main><h1>$1</h1><p>The site is under maintenance. Please check back later.</p></main></body></html>
HTML
    printf 'User-agent: *\nDisallow: /\n' > "$SELF_WWW/robots.txt"
}
self_nginx_install() { # до выпуска сертификата: acme.sh вызывает «systemctl reload nginx»
    if ! command -v nginx >/dev/null; then
        echo "  Ставлю nginx…"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null 2>&1 \
            || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null 2>&1; } \
            || { echo "Не удалось установить nginx"; exit 1; }
    fi
    # стандартный сайт nginx занимает 80/tcp, а он нужен Let's Encrypt для выпуска и продления
    if [[ -e /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
        systemctl restart nginx >/dev/null 2>&1 || true
    fi
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl is-active --quiet nginx 2>/dev/null || systemctl start nginx >/dev/null 2>&1 || true
}
self_nginx() { # <домен> <порт>
    local h2="listen 127.0.0.1:$2 ssl http2;" v
    v=$(nginx -v 2>&1 | grep -Eo '[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$v" ]] && (( ${v%.*} > 1 || ${v#*.} >= 25 )); then h2="listen 127.0.0.1:$2 ssl;
    http2 on;"; fi
    local sub_loc=""
    if [[ -n "${SUB_SHORT:-}" && -n "${SUB_PATH:-}" ]]; then   # короткая ссылка подписки: https://домен/<ID>
        sub_loc="
    # подписка: https://$1/<ID> -> сервер подписок панели (ID: буквы, цифры, _ и -)
    location ~ \"^/[A-Za-z0-9_-]{6,64}\$\" {
        rewrite ^/(.*)\$ ${SUB_PATH%/}/\$1 break;
        proxy_pass https://127.0.0.1:${SUB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 60s;
    }
    # страница подписки (html=1) и ссылки со старым путём
    location ^~ ${SUB_PATH%/}/ {
        proxy_pass https://127.0.0.1:${SUB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
    }"
    fi
    cat > "$SELF_NGINX" <<NGX
# vpn reality self — сайт-маскировка Reality, доступен только через Xray (порт 443)
server {
    $h2
    server_name $1;
    server_tokens off;
    ssl_certificate     $SELF_DIR/fullchain.pem;
    ssl_certificate_key $SELF_DIR/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve X25519:prime256v1:secp384r1;
    ssl_session_timeout 1d;
    ssl_session_cache shared:VPNSELF:10m;
    root $SELF_WWW;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }${sub_loc}
}
NGX
    nginx -t >/dev/null 2>&1 || { nginx -t; echo "Конфиг nginx с ошибкой: $SELF_NGINX"; exit 1; }
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx >/dev/null 2>&1 || { echo "nginx не запустился: journalctl -u nginx -n 30"; exit 1; }
}
self_reload() { # команда после выпуска/продления сертификата Reality-домена
    local c="systemctl reload nginx"
    # серверу подписок нужен рестарт, он читает сертификат только при старте
    if [[ "${SUB_CERT:-}" == "$SELF_DIR/fullchain.pem" ]]; then c="$c; systemctl restart x-ui"; fi
    echo "$c"
}
self_cert() { # <домен> [каталог] [команда-после] — выпуск через 80/tcp (standalone), автопродление через cron acme.sh
    local dir=${2:-$SELF_DIR} reload=${3:-}
    [[ -n "$reload" ]] || reload=$(self_reload)
    if [[ ! -x "$ACME_SH" ]]; then
        echo "  Ставлю acme.sh…"
        curl -fsSL https://get.acme.sh | sh -s email="admin@$1" >/dev/null 2>&1 || true
        [[ -x "$ACME_SH" ]] || { echo "Не удалось установить acme.sh"; exit 1; }
    fi
    if [[ -n "$(ss -Hltn 'sport = :80' 2>/dev/null)" ]]; then
        echo "Порт 80/tcp занят ($(ss -Hltnp 'sport = :80' 2>/dev/null | grep -o 'users:(("[^"]*' | cut -d'"' -f2 | head -1)) — Let's Encrypt не сможет проверить домен. Освободи его и повтори."
        exit 1
    fi
    mkdir -p "$dir"; chmod 700 "$dir"
    echo "  Получаю сертификат Let's Encrypt для $1 (через 80/tcp)…"
    local rc=0 log=/var/log/vpn-self-acme.log
    "$ACME_SH" --issue -d "$1" --standalone --httpport 80 --server letsencrypt --keylength ec-256 >"$log" 2>&1 || rc=$?
    # 2 — сертификат уже есть и продлевать рано
    if (( rc != 0 && rc != 2 )); then
        tail -15 "$log"
        echo "Let's Encrypt не выдал сертификат (лог: $log). Проверь A-запись домена и что 80/tcp открыт у хостера."
        exit 1
    fi
    "$ACME_SH" --install-cert -d "$1" --ecc --key-file "$dir/key.pem" --fullchain-file "$dir/fullchain.pem" \
        --reloadcmd "$reload" >>"$log" 2>&1 || { tail -5 "$log"; echo "Не удалось установить сертификат (лог: $log)"; exit 1; }
    chmod 600 "$dir/key.pem"
}
do_reality_self() { # <домен>
    local d=${1,,} ips v6 port
    [[ "$d" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || { echo "Использование: vpn reality self <домен>, например fi.example.xyz"; exit 1; }
    echo "Reality на свой домен: $d"
    ips=$(self_ipv4 "$d")
    if [[ -z "$ips" ]]; then
        echo "У $d нет A-записи. Создай у регистратора A-запись $d → ${SERVER_IP} и подожди 5–15 минут."; exit 1
    fi
    if [[ " $ips " != *" ${SERVER_IP} "* ]]; then
        echo "A-запись $d указывает на ${ips}, а не на этот сервер (${SERVER_IP}). Исправь её у регистратора и подожди 5–15 минут."; exit 1
    fi
    [[ "$ips" == "${SERVER_IP}" ]] || echo "  Внимание: у $d несколько A-записей ($ips) — оставь только ${SERVER_IP}."
    v6=$(self_ipv6 "$d")
    if [[ -n "$v6" ]] && ! ip -6 addr show 2>/dev/null | grep -qw "${v6%% *}"; then
        echo "  Внимание: у $d есть AAAA-запись ($v6), не принадлежащая серверу — удали её у регистратора."
    fi
    echo "  DNS: $d → ${SERVER_IP}"
    port=$(self_free_port) || { echo "Не нашёл свободный локальный порт для сайта-маскировки"; exit 1; }
    self_site "$d"
    self_nginx_install
    self_cert "$d"
    self_nginx "$d" "$port"
    local i
    for i in 1 2 3 4 5; do self_https_ok "$d" "$port" && break; sleep 1; done
    self_https_ok "$d" "$port" || { echo "Сайт-маскировка на 127.0.0.1:$port не отвечает по TLS 1.3 + HTTP/2 с проверкой сертификата (journalctl -u nginx)"; exit 1; }
    echo "  Сайт-маскировка: https://$d (127.0.0.1:$port), сертификат до $(openssl x509 -in "$SELF_DIR/fullchain.pem" -noout -enddate | cut -d= -f2)"
    reality_apply "127.0.0.1:$port" "$d"
    if [[ -n "$(h3_id)" ]]; then inbound_patch "$(h3_id)" '.streamSettings.tlsSettings.serverName = $d' --arg d "$d"; fi
    env_set SELF_DOMAIN "$d"; env_set SELF_PORT "$port"
    echo "Готово: SNI $d, маскировка — свой сайт (127.0.0.1:$port). Сертификат продлевается сам (cron acme.sh)."
    echo "Клиентам нужно обновить подписку. Проверка: vpn check --local"
}

# ---------------------------------------------------------------- ссылка подписки на своём домене
SUB_DIR=/etc/vpn/sub
wait_panel() { # ждать, пока панель ответит (после рестарта)
    local i
    for i in $(seq 1 40); do
        if api GET /server/status 2>/dev/null | jq -e '.success == true' >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo "Панель не поднялась за 40 секунд: systemctl status x-ui; journalctl -u x-ui -n 30" >&2; return 1
}
sub_apply() { # <subURI> <cert> <key> — записать в панель и перезапустить
    local all upd
    wait_panel
    all=$(api POST /setting/all); ok "$all"
    upd=$(jq --arg uri "$1" --arg crt "$2" --arg key "$3" '.obj | .subURI = $uri | .subCertFile = $crt | .subKeyFile = $key' <<<"$all")
    ok "$(api_json POST /setting/update "$upd")"
    restart_panel
}
sub_tls_ok() { # <домен> — сервер подписок отвечает по HTTPS с проверкой сертификата
    local i
    for i in 1 2 3 4 5; do
        curl -s --noproxy '*' -o /dev/null --max-time 8 "https://$1:${SUB_PORT}/" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}
sub_short_possible() { # <домен> — домен Reality на 443: через него можно отдавать подписку без порта
    local ib
    [[ "$1" == "${SELF_DOMAIN:-}" && -n "${SELF_PORT:-}" && -f "$SELF_NGINX" ]] || return 1
    ib=$(reality_inbound) || return 1
    [[ "$(jq -r .port <<<"$ib")" == 443 ]] || return 1
    [[ "$(jq -r '.streamSettings | (if type == "string" then fromjson else . end) | .realitySettings | (.target // .dest)' <<<"$ib")" == "127.0.0.1:${SELF_PORT}" ]]
}
sub_first_id() { api GET /clients/list | jq -r '[.obj[]? | select(.subId != null and .subId != "")][0].subId // empty'; }
do_subdomain() { # <домен> [--port] | off | status
    node_guard
    local act=${1:-status} all path
    all=$(api POST /setting/all); ok "$all"; path=$(jq -r .obj.subPath <<<"$all")
    case "$act" in
    status)
        echo "Ссылка подписки: ${SUB_BASE}<ID>"
        if [[ -n "${SUB_DOMAIN:-}" ]]; then
            echo "Домен подписки: ${SUB_DOMAIN}$([[ -n "${SUB_SHORT:-}" ]] && echo ", короткая ссылка через 443 (nginx → сервер подписок)"), сертификат до $(openssl x509 -in "$SUB_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)"
        else
            echo "Домен подписки не задан — ссылки идут на ${PUBLIC_HOST}. Включить: vpn sub-domain <домен>"
        fi
        ;;
    off)
        [[ -n "${SUB_DOMAIN:-}" ]] || { echo "Домен подписки и так не задан"; return; }
        local sch=http crt="" key=""
        if [[ "$CERT_MODE" == letsencrypt ]]; then sch=https; crt=${SUB_CERT_ORIG:-$CERT}; key=${SUB_KEY_ORIG:-$(dirname "$CERT")/privkey.pem}; fi
        sub_apply "${sch}://${PUBLIC_HOST}:${SUB_PORT}${path}" "$crt" "$key"
        env_set SUB_BASE "${sch}://${PUBLIC_HOST}:${SUB_PORT}${path}"
        env_set SUB_DOMAIN ""; env_set SUB_CERT ""; env_set SUB_KEY ""
        if [[ -n "${SUB_SHORT:-}" ]]; then env_set SUB_SHORT ""; self_nginx "${SELF_DOMAIN}" "${SELF_PORT}"; fi
        echo "Подписки снова на ${PUBLIC_HOST}. В клиентах добавь подписку заново: vpn link <имя>"
        ;;
    *)
        local d=${act,,} ips crt key old_uri old_crt old_key short="" force_port=0 base sid code was_short=${SUB_SHORT:-}
        [[ "${2:-}" == --port ]] && force_port=1
        [[ "$d" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || { echo "Использование: vpn sub-domain <домен> [--port] | off | status"; exit 1; }
        ips=$(self_ipv4 "$d")
        [[ -n "$ips" ]] || { echo "У $d нет A-записи. Создай A-запись $d → ${SERVER_IP} и подожди 5–15 минут."; exit 1; }
        [[ " $ips " == *" ${SERVER_IP} "* ]] || { echo "A-запись $d указывает на ${ips}, а не на этот сервер (${SERVER_IP})."; exit 1; }
        echo "Подписка на домене: $d"
        echo "  DNS: $d → ${SERVER_IP}"
        if [[ "$d" == "${SELF_DOMAIN:-}" && -r "$SELF_DIR/fullchain.pem" && -r "$SELF_DIR/key.pem" ]]; then
            crt=$SELF_DIR/fullchain.pem; key=$SELF_DIR/key.pem
            echo "  Сертификат: тот же, что у Reality ($SELF_DIR)"
        else
            crt=$SUB_DIR/fullchain.pem; key=$SUB_DIR/key.pem
            self_cert "$d" "$SUB_DIR" "systemctl restart x-ui"
        fi
        openssl x509 -in "$crt" -noout -checkhost "$d" 2>/dev/null | grep -q 'does match' \
            || { echo "Сертификат $crt не выпущен на $d"; exit 1; }
        if (( ! force_port )) && sub_short_possible "$d"; then
            short=1; echo "  Ссылка без порта: через 443 (Reality отдаёт чужие запросы в nginx, он передаёт их серверу подписок)"
        else
            echo "  Ссылка с портом ${SUB_PORT}$( (( force_port )) && echo ' (--port)' || echo ': домен не Reality на 443, см. vpn reality self')"
        fi
        old_uri=$(jq -r .obj.subURI <<<"$all"); old_crt=$(jq -r .obj.subCertFile <<<"$all"); old_key=$(jq -r .obj.subKeyFile <<<"$all")
        if [[ -z "${SUB_DOMAIN:-}" ]]; then env_set SUB_CERT_ORIG "$old_crt"; env_set SUB_KEY_ORIG "$old_key"; fi
        # сертификат Reality-домена продлевается с рестартом панели — обновим команду в acme.sh
        env_set SUB_CERT "$crt"; env_set SUB_KEY "$key"
        if [[ "$crt" == "$SELF_DIR/fullchain.pem" && -x "$ACME_SH" ]]; then
            "$ACME_SH" --install-cert -d "$d" --ecc --key-file "$key" --fullchain-file "$crt" --reloadcmd "$(self_reload)" >/dev/null 2>&1 || true
            wait_panel   # reloadcmd уже перезапустил панель
        fi
        if [[ -n "$short" ]]; then base="https://${d}/"; else base="https://${d}:${SUB_PORT}${path}"; fi
        echo "  Перезапускаю панель (VPN моргнёт на пару секунд)…"
        sub_apply "$base" "$crt" "$key"
        env_set SUB_PATH "$path"; env_set SUB_SHORT "$short"
        if [[ -n "$short" ]] || [[ -n "$was_short" ]]; then self_nginx "$SELF_DOMAIN" "$SELF_PORT"; fi
        if ! sub_tls_ok "$d"; then code=1
        elif [[ -n "$short" ]]; then
            sid=$(sub_first_id); code=1
            if [[ -z "$sid" ]]; then code=0   # пользователей нет — проверить нечем
            else
                local i
                for i in 1 2 3 4 5; do
                    [[ "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 "https://${d}/${sid}" 2>/dev/null)" == 200 ]] && { code=0; break; }
                    sleep 1
                done
            fi
        else code=0; fi
        if (( code != 0 )); then
            echo "Подписка не отдаётся по ${base} — возвращаю прежние настройки."
            sub_apply "$old_uri" "$old_crt" "$old_key"
            env_set SUB_CERT ""; env_set SUB_KEY ""; env_set SUB_SHORT ""
            if [[ -n "$short" ]]; then self_nginx "$SELF_DOMAIN" "$SELF_PORT"; fi
            echo "Проверь: vpn check --local; journalctl -u x-ui -n 30; nginx -t"
            exit 1
        fi
        env_set SUB_DOMAIN "$d"
        env_set SUB_BASE "$base"
        echo "Готово: подписки теперь ${base}<ID>"
        echo "Ссылки на старый адрес работать не будут — у каждого пользователя новую покажет vpn link <имя>."
        echo "В клиентах подписку нужно добавить заново (ID пользователя тот же)."
        ;;
    esac
}

# ---------------------------------------------------------------- доступ к панели
panel_local_url() { sed -E 's|//[^:/]+:|//127.0.0.1:|' <<<"$PANEL_URL"; }
do_panel() { # [hide|show|status]
    case "${1:-}" in
    "") cat /etc/vpn/panel.txt
        if [[ -n "${PANEL_HIDDEN:-}" ]]; then
            echo
            echo "Панель закрыта снаружи. Открыть с компьютера:"
            echo "  ssh -N -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@${SERVER_IP}"
            echo "  и в браузере: $(panel_local_url)   (предупреждение о сертификате — нормально)"
        fi ;;
    status)
        if [[ -n "${PANEL_HIDDEN:-}" ]]; then echo "Панель закрыта снаружи (слушает только 127.0.0.1:${PANEL_PORT})"
        else echo "Панель открыта снаружи: порт ${PANEL_PORT}/tcp"; fi ;;
    hide)
        if is_node; then echo "Это нода: главный сервер ходит в её панель по сети, закрывать нельзя."; exit 1; fi
        [[ -z "${PANEL_HIDDEN:-}" ]] || { echo "Панель уже закрыта снаружи"; return; }
        local all upd
        all=$(api POST /setting/all); ok "$all"
        upd=$(jq '.obj | .webListen = "127.0.0.1"' <<<"$all")
        ok "$(api_json POST /setting/update "$upd")"
        if command -v ufw >/dev/null; then ufw delete allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true; fi
        env_set PANEL_HIDDEN 1
        echo "  Перезапускаю панель (VPN моргнёт на пару секунд)…"
        restart_panel
        wait_panel
        echo "Панель закрыта снаружи: слушает только 127.0.0.1, порт ${PANEL_PORT} закрыт в ufw. Утилита vpn работает как раньше."
        echo "Если у хостера есть свой фаервол, порт ${PANEL_PORT} там тоже можно закрыть."
        echo "Открыть панель: ssh -N -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@${SERVER_IP}, затем $(panel_local_url)"
        echo "Вернуть как было: vpn panel show" ;;
    show)
        [[ -n "${PANEL_HIDDEN:-}" ]] || { echo "Панель и так открыта снаружи"; return; }
        local all upd
        all=$(api POST /setting/all); ok "$all"
        upd=$(jq '.obj | .webListen = ""' <<<"$all")
        ok "$(api_json POST /setting/update "$upd")"
        if command -v ufw >/dev/null; then ufw allow "${PANEL_PORT}/tcp" comment 3x-ui-panel >/dev/null 2>&1 || true; fi
        env_set PANEL_HIDDEN ""
        restart_panel
        wait_panel
        echo "Панель снова открыта: ${PANEL_URL}" ;;
    *) echo "Использование: vpn panel [hide|show|status]"; exit 1 ;;
    esac
}

# ---------------------------------------------------------------- XHTTP и port hopping
xhttp_id() { # XHTTP_ID; у старых установок — третий элемент INBOUNDS
    if [[ -n "${XHTTP_ID:-}" ]]; then echo "$XHTTP_ID"
    elif [[ -n "${XHTTP_PORT:-}" ]]; then jq -r '.[2] // empty' <<<"$INBOUNDS"; fi
}
h3_id() { echo "${H3_ID:-}"; }
inbounds_add() { env_set INBOUNDS "$(jq -c --argjson id "$1" 'if any(.[]; . == $id) then . else . + [$id] end' <<<"$INBOUNDS")"; }
inbounds_del() { env_set INBOUNDS "$(jq -c --argjson id "$1" 'map(select(. != $id))' <<<"$INBOUNDS")"; }
env_set() { # env_set KEY VALUE — записать в /etc/vpn/vpn.env
    if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1='$2'|" "$ENV_FILE"; else echo "$1='$2'" >> "$ENV_FILE"; fi
    printf -v "$1" '%s' "$2"
}
all_emails() { api GET /clients/list | jq -c '[.obj[]?.email]'; }

do_xhttp() {
    case "${1:-}" in
    on)
        if [[ -n "$(xhttp_id)" ]]; then echo "XHTTP уже включён (порт ${XHTTP_PORT})"; return; fi
        local port=${2:-8443} rs keys res id emails name
        [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || { echo "Порт — число 1–65535"; exit 1; }
        if listening "$port" tcp; then echo "Порт ${port}/tcp уже занят"; exit 1; fi
        if [[ -n "$(reality_id)" ]]; then rs=$(reality_settings)
        else rs=$(jq -nc --arg t "${RT_TARGET:-www.samsung.com:443}" --arg s "${RT_SNI:-www.samsung.com}" '{target: $t, serverNames: [$s]}'); fi
        keys=$(api GET /server/getNewX25519Cert); ok "$keys"
        name="$(name_base "$(inbound_remark "$(ref_id)")") · VLESS XHTTP"
        res=$(api_json POST /inbounds/add "$(jq -n --argjson port "$port" --argjson rs "$rs" --argjson k "$keys" \
            --arg sid "$(openssl rand -hex 8)" --arg path "/$(openssl rand -hex 6)" --arg host "$PUBLIC_HOST" --arg name "$name" '{
            remark: $name, enable: true, listen: "", port: $port, protocol: "vless", expiryTime: 0, total: 0,
            shareAddrStrategy: "custom", shareAddr: $host,
            settings: { clients: [], decryption: "none", encryption: "none", fallbacks: [] },
            streamSettings: { network: "xhttp", security: "reality",
              xhttpSettings: { path: $path, host: "", mode: "auto", xPaddingBytes: "100-1000" },
              realitySettings: { show: false, xver: 0, target: ($rs.target // $rs.dest), serverNames: $rs.serverNames,
                privateKey: $k.obj.privateKey, minClientVer: "", maxClientVer: "", maxTimediff: 0, shortIds: [$sid], mldsa65Seed: "",
                settings: { publicKey: $k.obj.publicKey, fingerprint: "chrome", serverName: "", spiderX: "/", mldsa65Verify: "" } } },
            sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false, routeOnly: true } }')")
        ok "$res"; id=$(jq -r .obj.id <<<"$res")
        emails=$(all_emails)
        if [[ "$emails" != "[]" ]]; then
            ok "$(api_json POST /clients/bulkAttach "$(jq -nc --argjson e "$emails" --argjson i "[$id]" '{emails: $e, inboundIds: $i}')")"
        fi
        inbounds_add "$id"
        env_set XHTTP_ID "$id"; env_set XHTTP_PORT "$port"
        if command -v ufw >/dev/null; then ufw allow "${port}/tcp" comment vless-xhttp >/dev/null 2>&1 || true; fi
        if [[ -n "${FASTEST_ID:-}" ]]; then fastest_sync; fi
        echo "XHTTP включён: «${name}», порт ${port}/tcp, все пользователи добавлены."
        echo "Если у хостера свой фаервол — открой там ${port}/tcp. В клиентах обнови подписку."
        ;;
    off)
        local id emails; id=$(xhttp_id)
        [[ -n "$id" ]] || { echo "XHTTP не включён"; return; }
        emails=$(all_emails)
        if [[ "$emails" != "[]" ]]; then
            api_json POST /clients/bulkDetach "$(jq -nc --argjson e "$emails" --argjson i "[$id]" '{emails: $e, inboundIds: $i}')" >/dev/null || true
        fi
        ok "$(api POST "/inbounds/del/$id")"
        if [[ -n "${XHTTP_PORT:-}" ]] && command -v ufw >/dev/null; then ufw delete allow "${XHTTP_PORT}/tcp" >/dev/null 2>&1 || true; fi
        inbounds_del "$id"
        env_set XHTTP_ID ""; env_set XHTTP_PORT ""
        if [[ -n "${FASTEST_ID:-}" ]]; then fastest_sync; fi
        echo "XHTTP выключен. В клиентах обнови подписку."
        ;;
    *)
        if [[ -n "$(xhttp_id)" ]]; then echo "XHTTP включён: порт ${XHTTP_PORT}/tcp. Выключить: vpn xhttp off"
        else echo "XHTTP выключен. Включить: vpn xhttp on [порт, по умолчанию 8443]"; fi ;;
    esac
}

# ---------------------------------------------------------------- XHTTP поверх HTTP/3 (QUIC, UDP)
# VLESS + XHTTP + TLS (alpn h3) на своём домене: QUIC/UDP с настоящим сертификатом Let's Encrypt.
# Нужен свой домен (vpn reality self). Xray сам перечитывает сертификат после продления (ocspStapling).
h3_inbound_json() { # <порт> <домен> <путь> <название>
    jq -n --argjson port "$1" --arg d "$2" --arg path "$3" --arg name "$4" --arg host "$PUBLIC_HOST" \
        --arg cf "$SELF_DIR/fullchain.pem" --arg kf "$SELF_DIR/key.pem" '{
        remark: $name, enable: true, listen: "", port: $port, protocol: "vless", expiryTime: 0, total: 0,
        shareAddrStrategy: "custom", shareAddr: $host,
        settings: { clients: [], decryption: "none", encryption: "none", fallbacks: [] },
        streamSettings: { network: "xhttp", security: "tls",
          xhttpSettings: { path: $path, host: "", mode: "auto", xPaddingBytes: "100-1000" },
          tlsSettings: { serverName: $d, minVersion: "1.3", maxVersion: "1.3", cipherSuites: "", rejectUnknownSni: false,
            disableSystemRoot: false, enableSessionResumption: false, alpn: ["h3"],
            certificates: [{ certificateFile: $cf, keyFile: $kf, ocspStapling: 3600, oneTimeLoading: false,
                             usage: "encipherment", buildChain: false }],
            echServerKeys: "", echForceQuery: "none",
            settings: { allowInsecure: false, fingerprint: "chrome", echConfigList: "" } } },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false, routeOnly: true } }'
}
name_base() { # «🇫🇮 VLESS TCP», «NL · VLESS», «🇫🇮 Hysteria2» → «🇫🇮», «NL»: имя сервера без названия протокола
    sed -E 's/[[:space:]·-]*(VLESS( TCP| XHTTP( HTTP3)?)?|Hysteria2|XHTTP)$//' <<<"$1"
}
h3_default_name() {
    local x
    if [[ -n "$(xhttp_id)" ]]; then x=$(inbound_remark "$(xhttp_id)"); echo "${x} HTTP3"; return; fi
    x=$(inbound_remark "$(ref_id)"); echo "$(name_base "$x") · VLESS XHTTP HTTP3"
}
do_http3() {
    local action=${1:-status}; [[ $# -gt 0 ]] && shift
    case "$action" in
    on)
        if [[ -n "$(h3_id)" ]]; then echo "HTTP3 уже включён (порт ${H3_PORT}/udp)"; return; fi
        local port=4443 name="" a
        while [[ $# -gt 0 ]]; do
            a=$1; shift
            case "$a" in
                --name) name=${1:-}; shift ;;
                *) port=$a ;;
            esac
        done
        [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )) || { echo "Порт — число 1–65535"; exit 1; }
        if [[ -z "${SELF_DOMAIN:-}" || ! -s "$SELF_DIR/fullchain.pem" || ! -s "$SELF_DIR/key.pem" ]]; then
            echo "HTTP3 работает на своём домене с настоящим сертификатом. Сначала: vpn reality self <домен>"; exit 1
        fi
        if ! openssl x509 -in "$SELF_DIR/fullchain.pem" -noout -checkend 86400 >/dev/null 2>&1; then
            echo "Сертификат ${SELF_DOMAIN} истёк или истекает — обнови: vpn reality self ${SELF_DOMAIN}"; exit 1
        fi
        # 3x-ui считает XHTTP «tcp»-инбаундом и не даёт два инбаунда на одном номере порта
        local busy
        busy=$(api GET /inbounds/list | jq -r --argjson p "$port" '.obj[]? | select(.port == $p and .nodeId == null) | .remark' | head -1)
        if [[ -n "$busy" || "$port" == "${PANEL_PORT:-}" || "$port" == "${SUB_PORT:-}" ]]; then
            echo "Порт ${port} уже занят${busy:+ сервером «$busy»} (панель 3x-ui не даёт два сервера на одном номере порта). Укажи другой: vpn http3 on <порт>"; exit 1
        fi
        if listening "$port" udp; then echo "Порт ${port}/udp уже занят ($(ss -Hlunp "sport = :$port" | grep -o 'users:(("[^"]*' | cut -d'"' -f2 | head -1))"; exit 1; fi
        if [[ -n "${HOP_PORTS:-}" ]]; then
            local lo=${HOP_PORTS%-*} hi=${HOP_PORTS#*-}
            (( port < lo || port > hi )) || { echo "Порт ${port} внутри диапазона port hopping (${HOP_PORTS}) — выбери другой"; exit 1; }
        fi
        [[ -n "$name" ]] || name=$(h3_default_name)
        local res id emails
        res=$(api_json POST /inbounds/add "$(h3_inbound_json "$port" "$SELF_DOMAIN" "/$(openssl rand -hex 6)" "$name")")
        ok "$res"; id=$(jq -r .obj.id <<<"$res")
        emails=$(all_emails)
        if [[ "$emails" != "[]" ]]; then
            ok "$(api_json POST /clients/bulkAttach "$(jq -nc --argjson e "$emails" --argjson i "[$id]" '{emails: $e, inboundIds: $i}')")"
        fi
        inbounds_add "$id"
        env_set H3_ID "$id"; env_set H3_PORT "$port"
        if command -v ufw >/dev/null; then ufw allow "${port}/udp" comment vless-xhttp-h3 >/dev/null 2>&1 || true; fi
        if [[ -n "${FASTEST_ID:-}" ]]; then fastest_sync; fi
        local i
        for i in $(seq 1 10); do listening "$port" udp && break; sleep 1; done
        listening "$port" udp || echo "Внимание: ${port}/udp пока никто не слушает — проверь: vpn check --local"
        echo "HTTP3 включён: «${name}», ${SELF_DOMAIN}:${port}/udp (QUIC), все пользователи добавлены."
        echo "Если у хостера свой фаервол — открой там ${port}/udp. В клиентах обнови подписку."
        echo "Переименовать: vpn brand --http3-name \"…\". Проверка: vpn check --local"
        ;;
    off)
        local id emails; id=$(h3_id)
        [[ -n "$id" ]] || { echo "HTTP3 не включён"; return; }
        emails=$(all_emails)
        if [[ "$emails" != "[]" ]]; then
            api_json POST /clients/bulkDetach "$(jq -nc --argjson e "$emails" --argjson i "[$id]" '{emails: $e, inboundIds: $i}')" >/dev/null || true
        fi
        ok "$(api POST "/inbounds/del/$id")"
        if [[ -n "${H3_PORT:-}" ]] && command -v ufw >/dev/null; then ufw delete allow "${H3_PORT}/udp" >/dev/null 2>&1 || true; fi
        inbounds_del "$id"
        env_set H3_ID ""; env_set H3_PORT ""
        if [[ -n "${FASTEST_ID:-}" ]]; then fastest_sync; fi
        echo "HTTP3 выключен. В клиентах обнови подписку."
        ;;
    status|"")
        if [[ -n "$(h3_id)" ]]; then echo "HTTP3 включён: «$(inbound_remark "$(h3_id)")», ${SELF_DOMAIN:-?}:${H3_PORT}/udp. Выключить: vpn http3 off"
        else echo "HTTP3 выключен. Включить: vpn http3 on [порт, по умолчанию 4443] [--name «название»] (нужен vpn reality self)"; fi ;;
    *) echo "Использование: vpn http3 on [порт] [--name Т] | off | status"; exit 1 ;;
    esac
}

hop_rules() { # hop_rules up|down <от-до>
    local act=$1 r=${2/-/:} t
    for t in iptables ip6tables; do
        command -v "$t" >/dev/null || continue
        if [[ $act == up ]]; then
            "$t" -t nat -C PREROUTING -p udp --dport "$r" -j REDIRECT --to-ports 443 2>/dev/null \
                || "$t" -t nat -A PREROUTING -p udp --dport "$r" -j REDIRECT --to-ports 443 2>/dev/null || [[ $t == ip6tables ]]
        else
            while "$t" -t nat -D PREROUTING -p udp --dport "$r" -j REDIRECT --to-ports 443 2>/dev/null; do :; done
        fi
    done
}

do_hop() {
    local unit=/etc/systemd/system/vpn-hop.service
    case "${1:-}" in
    on)
        [[ -n "$(hy2_id)" ]] || { echo "Port hopping работает только для Hysteria2, а его на этом сервере нет."; exit 1; }
        local range=${2:-20000-50000} a b
        [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || { echo "Диапазон в виде 20000-50000"; exit 1; }
        a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
        (( a > 1024 && b < 65536 && a < b )) || { echo "Диапазон должен быть внутри 1025–65535"; exit 1; }
        if [[ -n "${HOP_PORTS:-}" && "$HOP_PORTS" != "$range" ]]; then hop_rules down "$HOP_PORTS"; fi
        cat > "$unit" <<UNIT
[Unit]
Description=VPN: Hysteria2 UDP port hopping ${range} -> 443
After=network-online.target ufw.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/vpn _hop up ${range}
ExecStop=/usr/local/bin/vpn _hop down ${range}

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable vpn-hop >/dev/null 2>&1
        systemctl restart vpn-hop
        inbound_patch "$(hy2_id)" '.streamSettings.finalmask.quicParams.udpHop = {ports: $p, interval: "5-10"}' --arg p "$range"
        env_set HOP_PORTS "$range"
        echo "Port hopping включён: UDP ${range} → 443."
        echo "Если у хостера свой фаервол — открой там UDP ${range}. В клиентах обнови подписку."
        echo "Клиенты без поддержки hopping просто продолжат ходить на 443."
        ;;
    off)
        [[ -n "${HOP_PORTS:-}" ]] || { echo "Port hopping не включён"; return; }
        systemctl disable --now vpn-hop >/dev/null 2>&1 || true
        rm -f "$unit"; systemctl daemon-reload
        hop_rules down "$HOP_PORTS"
        inbound_patch "$(hy2_id)" 'del(.streamSettings.finalmask.quicParams.udpHop)'
        env_set HOP_PORTS ""
        echo "Port hopping выключен. В клиентах обнови подписку."
        ;;
    *)
        if [[ -n "${HOP_PORTS:-}" ]]; then echo "Port hopping включён: UDP ${HOP_PORTS} → 443. Выключить: vpn hop off"
        else echo "Port hopping выключен. Включить: vpn hop on [диапазон, по умолчанию 20000-50000]"; fi ;;
    esac
}

# ---------------------------------------------------------------- «Лучший сервер» (балансировщик в JSON-подписке)
FASTEST_DEFAULT_NAME="⚡ Лучший сервер"
FASTEST_DEFAULT_CLIENTS="happ,v2raytun,incy"
# Проверка серверов клиентом (burstObservatory): цикл = interval × sampling; сервер считается упавшим после 1–2 циклов
# подряд неудачных проверок, то есть переключение занимает от одного до двух циклов. Минимум interval — 10s.
FASTEST_DEF_INTERVAL=10s; FASTEST_DEF_SAMPLING=2; FASTEST_DEF_TIMEOUT=4s
FASTEST_UA_PROBE="Happ/3.1.2"
clients_regex() { # happ,v2raytun → (?i)\b(happ|v2raytun)\b
    echo "(?i)\\b($(tr ',' '|' <<<"$1"))\\b"
}
restart_panel() {
    systemctl restart x-ui
    local i
    for i in $(seq 1 30); do
        if api GET /server/status 2>/dev/null | jq -e '.success == true' >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo "Панель долго поднимается — проверь: vpn check --local"
}
vless_encryption_fix() { # inbound'ы без encryption ломают JSON-подписку («VLESS users: please add encryption none»)
    local id enc
    for id in "$(vless_id)" "$(xhttp_id)"; do
        [[ -n "$id" ]] || continue
        enc=$(api GET "/inbounds/get/$id" | jq -r '.obj.settings | (if type == "string" then fromjson else . end) | .encryption // ""')
        if [[ -z "$enc" ]]; then inbound_patch "$id" '.settings.encryption = "none"'; fi
    done
}
balancer_form() { # <name> → аргументы curl для create/update балансировщика
    local id
    printf '%s\0' --data-urlencode "remark=$1" -d strategy=leastPing -d sortOrder=1 -d enabled=true
    for id in $(jq -r '.[]' <<<"$INBOUNDS"); do printf '%s\0' -d "inboundIds=$id"; done
}
fastest_sync() { # балансировщик = все текущие серверы, он первым в списке
    local name args=() r i id
    name=$(api GET /sub-balancers | jq -r --argjson id "$FASTEST_ID" '.obj[]? | select(.id == $id) | .remark')
    [[ -n "$name" ]] || name=$FASTEST_DEFAULT_NAME
    mapfile -d '' args < <(balancer_form "$name")
    r=$(api POST "/sub-balancers/$FASTEST_ID" "${args[@]}"); ok "$r"
    i=2
    for id in $(jq -r '.[]' <<<"$INBOUNDS"); do
        api_json POST "/inbounds/$id/subSortIndex" "{\"subSortIndex\": $i}" >/dev/null; i=$((i + 1))
    done
}
fastest_settings() { # <on|off> <clients>
    local all upd
    all=$(api POST /setting/all); ok "$all"
    if [[ $1 == on ]]; then
        upd=$(jq --arg re "$(clients_regex "$2")" '.obj | .subJsonEnable = true | .subJsonAutoDetect = true
            | .subJsonUserAgentRegex = $re | .subJsonAlwaysArray = true
            | .subJsonObservatory = $obs' --arg obs "$(jq -nc --arg i "${FASTEST_INTERVAL:-$FASTEST_DEF_INTERVAL}" \
                --argjson n "${FASTEST_SAMPLING:-$FASTEST_DEF_SAMPLING}" --arg t "${FASTEST_TIMEOUT:-$FASTEST_DEF_TIMEOUT}" \
                '{interval: $i, sampling: $n, timeout: $t}')" <<<"$all")
    else
        upd=$(jq '.obj | .subJsonAutoDetect = false' <<<"$all")
    fi
    ok "$(api_json POST /setting/update "$upd")"
}
do_fastest() {
    local action=${1:-} name="" clients="" a args=() r obs_i="" obs_n="" obs_t=""
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        a=$1; shift
        case "$a" in
            --name) name=${1:-}; shift ;;
            --clients) clients=$(tr 'A-Z' 'a-z' <<<"${1:-}" | tr -d ' '); shift ;;
            --interval) obs_i=${1:-}; shift ;;
            --sampling) obs_n=${1:-}; shift ;;
            --timeout) obs_t=${1:-}; shift ;;
            *) echo "Неизвестный параметр: $a"; exit 1 ;;
        esac
    done
    if [[ -n "$clients" && ! "$clients" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]]; then
        echo "--clients: список через запятую, например happ,v2raytun,incy"; exit 1
    fi
    if [[ -n "$obs_i" ]]; then [[ "$obs_i" =~ ^([0-9]+)s$ ]] && (( ${BASH_REMATCH[1]} >= 10 )) || { echo "--interval: секунды не меньше 10, например 10s"; exit 1; }; fi
    if [[ -n "$obs_n" ]]; then [[ "$obs_n" =~ ^[0-9]+$ ]] && (( obs_n >= 1 && obs_n <= 10 )) || { echo "--sampling: число от 1 до 10"; exit 1; }; fi
    if [[ -n "$obs_t" ]]; then [[ "$obs_t" =~ ^([0-9]+)s$ ]] && (( ${BASH_REMATCH[1]} >= 1 && ${BASH_REMATCH[1]} <= 30 )) || { echo "--timeout: секунды от 1 до 30, например 4s"; exit 1; }; fi
    if [[ -n "$obs_i$obs_n$obs_t" && "$action" != on ]]; then echo "--interval, --sampling и --timeout задаются вместе с on: vpn fastest on --interval 10s"; exit 1; fi
    case "$action" in
    on)
        (( $(jq length <<<"$INBOUNDS") >= 2 )) || { echo "«Лучший сервер» выбирает из нескольких серверов, а сейчас он один. Добавь ещё: vpn xhttp on (или Hysteria2/нода)"; exit 1; }
        vless_encryption_fix
        clients=${clients:-${FASTEST_CLIENTS:-$FASTEST_DEFAULT_CLIENTS}}
        if [[ -z "${FASTEST_ID:-}" ]] || ! api GET /sub-balancers | jq -e --argjson id "$FASTEST_ID" '.obj[]? | select(.id == $id)' >/dev/null; then
            mapfile -d '' args < <(balancer_form "${name:-$FASTEST_DEFAULT_NAME}")
            r=$(api POST /sub-balancers "${args[@]}"); ok "$r"
            env_set FASTEST_ID "$(jq -r .obj.id <<<"$r")"
        elif [[ -n "$name" ]]; then
            mapfile -d '' args < <(balancer_form "$name")
            ok "$(api POST "/sub-balancers/$FASTEST_ID" "${args[@]}")"
        fi
        fastest_sync
        env_set FASTEST_CLIENTS "$clients"
        [[ -z "$obs_i" ]] || env_set FASTEST_INTERVAL "$obs_i"
        [[ -z "$obs_n" ]] || env_set FASTEST_SAMPLING "$obs_n"
        [[ -z "$obs_t" ]] || env_set FASTEST_TIMEOUT "$obs_t"
        env_set FASTEST_INTERVAL "${FASTEST_INTERVAL:-$FASTEST_DEF_INTERVAL}"
        env_set FASTEST_SAMPLING "${FASTEST_SAMPLING:-$FASTEST_DEF_SAMPLING}"
        env_set FASTEST_TIMEOUT "${FASTEST_TIMEOUT:-$FASTEST_DEF_TIMEOUT}"
        fastest_settings on "$clients"
        echo "Перезапускаю панель (VPN моргнёт на пару секунд)…"
        restart_panel
        do_fastest status
        echo "В клиентах обнови подписку: сервер появится первым в списке."
        ;;
    off)
        [[ -n "${FASTEST_ID:-}" ]] || { echo "«Лучший сервер» не включён"; return; }
        api DELETE "/sub-balancers/$FASTEST_ID" >/dev/null || true
        fastest_settings off ""
        env_set FASTEST_ID ""
        restart_panel
        echo "«Лучший сервер» выключен, все клиенты снова получают обычные ссылки. Обнови подписку в клиентах."
        ;;
    status|"")
        if [[ -z "${FASTEST_ID:-}" ]]; then echo "«Лучший сервер» выключен. Включить: vpn fastest on"; return; fi
        r=$(api GET /sub-balancers | jq -c --argjson id "$FASTEST_ID" '.obj[]? | select(.id == $id)')
        echo "«$(jq -r .remark <<<"$r")» включён: выбирает самый быстрый из серверов ($(jq -r '.inboundIds | length' <<<"$r") шт.)"
        echo "Получают его клиенты: ${FASTEST_CLIENTS:-$FASTEST_DEFAULT_CLIENTS} (остальные — обычные ссылки)"
        local oi=${FASTEST_INTERVAL:-30s} on_=${FASTEST_SAMPLING:-2} ot=${FASTEST_TIMEOUT:-5s}
        echo "Проверка серверов: interval ${oi}, sampling ${on_}, timeout ${ot}; упавший сервер снимается через $(( ${oi%s} * on_ ))–$(( ${oi%s} * on_ * 2 )) с"
        ;;
    *) echo "vpn fastest [on|off|status] [--name Т] [--clients happ,v2raytun,incy] [--interval 10s] [--sampling 2] [--timeout 4s]"; exit 1 ;;
    esac
}

# ---------------------------------------------------------------- подпись подписки и названия серверов
hy2_id() { if [[ -v HY2_ID ]]; then echo "$HY2_ID"; else jq -r '.[1] // empty' <<<"$INBOUNDS"; fi; }
inbound_remark() { api GET "/inbounds/get/$1" | jq -r '.obj.remark // ""'; }
country_label() { # [<код страны>] → «🇳🇱 Нидерланды» (без аргумента — по IP сервера)
    local cc=${1:-}
    if [[ -z "$cc" ]]; then
        cc=$(curl -fsS --max-time 8 "https://ipinfo.io/${SERVER_IP}/country" 2>/dev/null | tr -dc 'A-Z' | head -c 2 || true)
        [[ ${#cc} == 2 ]] || cc=$(curl -fsS --max-time 8 "https://ipapi.co/${SERVER_IP}/country/" 2>/dev/null | tr -dc 'A-Z' | head -c 2 || true)
    fi
    [[ ${#cc} == 2 ]] || { echo "Сервер"; return; }
    python3 - "$cc" <<'PY'
import sys
cc = sys.argv[1].upper()
names = {"NL": "Нидерланды", "DE": "Германия", "FI": "Финляндия", "SE": "Швеция", "FR": "Франция", "GB": "Великобритания",
         "PL": "Польша", "LV": "Латвия", "LT": "Литва", "EE": "Эстония", "CH": "Швейцария", "AT": "Австрия", "CZ": "Чехия",
         "IT": "Италия", "ES": "Испания", "PT": "Португалия", "BG": "Болгария", "RO": "Румыния", "MD": "Молдова",
         "TR": "Турция", "KZ": "Казахстан", "AM": "Армения", "GE": "Грузия", "RS": "Сербия", "HU": "Венгрия",
         "NO": "Норвегия", "DK": "Дания", "IE": "Ирландия", "BE": "Бельгия", "LU": "Люксембург", "IS": "Исландия",
         "US": "США", "CA": "Канада", "JP": "Япония", "SG": "Сингапур", "HK": "Гонконг", "AE": "ОАЭ", "IL": "Израиль",
         "RU": "Россия", "UA": "Украина", "BY": "Беларусь", "CY": "Кипр", "GR": "Греция", "SK": "Словакия", "SI": "Словения"}
print("".join(chr(0x1F1E6 + ord(c) - 65) for c in cc) + " " + names.get(cc, cc))
PY
}
norm_support() { # @user → https://t.me/user
    local v=$1
    [[ "$v" == @* ]] && v="https://t.me/${v#@}"
    echo "$v"
}
prompt_keep() { # prompt_keep "вопрос" "текущее" → введённое или текущее
    local a
    read -r -p "$1 [${2:-пусто}]: " a </dev/tty || true
    echo "${a:-$2}"
}

do_brand() {
    local all title ann sup site vname hname auto=no a
    all=$(api POST /setting/all); ok "$all"
    title=$(jq -r '.obj.subTitle // ""' <<<"$all")
    ann=$(jq -r '.obj.subAnnounce // ""' <<<"$all")
    sup=$(jq -r '.obj.subSupportUrl // ""' <<<"$all")
    site=$(jq -r 'if .obj.subProfileMode == "custom" then .obj.subProfileUrl // ""
                  elif .obj.subProfileMode == "builtin" then "подписка" else "-" end' <<<"$all")
    vname=""; hname=""
    [[ -n "$(vless_id)" ]] && vname=$(inbound_remark "$(vless_id)")
    [[ -n "$(hy2_id)" ]] && hname=$(inbound_remark "$(hy2_id)")
    local xname=""; [[ -n "$(xhttp_id)" ]] && xname=$(inbound_remark "$(xhttp_id)")
    local h3name=""; [[ -n "$(h3_id)" ]] && h3name=$(inbound_remark "$(h3_id)")
    # баннер со своей кнопкой: INCY (Banner-*); Happ (Sub-Info-*) — только если в панели включено управление Happ,
    # оно заодно шлёт Happ свои Routing-Enable/Hide-Settings, поэтому само не включается
    local btext bbtn burl bset=0
    btext=$(jq -r '.obj.subIncyBannerText // ""' <<<"$all")
    bbtn=$(jq -r '.obj.subIncyBannerButtonText // ""' <<<"$all")
    burl=$(jq -r '.obj.subIncyBannerButtonUrl // ""' <<<"$all")
    local nflags=$#
    while [[ $# -gt 0 ]]; do
        a=$1; shift
        case "$a" in
            --title) title=${1:-}; shift ;;
            --announce) ann=${1:-}; shift ;;
            --support) sup=${1:-}; shift ;;
            --site) site=${1:-}; shift ;;
            --vless-name) vname=${1:-}; shift ;;
            --hy2-name) hname=${1:-}; shift ;;
            --xhttp-name) xname=${1:-}; shift ;;
            --http3-name) h3name=${1:-}; shift ;;
            --auto-names) auto=yes ;;
            --banner) btext=${1:-}; shift; bset=1 ;;
            --banner-button) bbtn=${1:-}; shift; bset=1 ;;
            --banner-url) burl=${1:-}; shift; bset=1 ;;
            --show) echo "Название:   ${title}"; echo "Описание:   ${ann//$'\n'/ ⏎ }"; echo "Поддержка:  ${sup:--}"
                    echo "Сайт:       ${site}"
                    if [[ -n "$btext" ]]; then echo "Баннер:     ${btext//$'\n'/ ⏎ }${bbtn:+ [кнопка «${bbtn}» → ${burl}]} (INCY)"; else echo "Баннер:     -"; fi
                    local names; names=$(printf '%s\n' "$vname" "$hname" "$xname" "$h3name" | awk 'NF' | paste -sd'|' | sed 's/|/ | /g')
                    echo "Серверы:    ${names}"; return ;;
            *) echo "Неизвестный параметр: $a (см. vpn help)"; exit 1 ;;
        esac
    done
    if [[ $auto == yes ]]; then
        local lbl; lbl=$(country_label)
        [[ -n "$(vless_id)" ]] && vname="${lbl} · VLESS"
        [[ -n "$(hy2_id)" ]] && hname="${lbl} · Hysteria2"
        [[ -n "$xname" ]] && xname="${lbl} · VLESS XHTTP"
        [[ -n "$h3name" ]] && h3name="${lbl} · VLESS XHTTP HTTP3"
    fi
    if (( nflags == 0 )); then
        [[ -r /dev/tty ]] || { echo "Нет терминала — задай параметры флагами (vpn help)"; exit 1; }
        echo "Подпись подписки и названия серверов. Enter — оставить как есть."
        echo "В описании можно писать {{EMAIL}} (имя пользователя), перенос строки — \\n."
        title=$(prompt_keep "Название подписки" "$title")
        ann=$(prompt_keep "Описание (announce)" "${ann//$'\n'/\\n}")
        sup=$(prompt_keep "Поддержка (@username или ссылка, - = без кнопки)" "${sup:--}")
        site=$(prompt_keep "Сайт (ссылка; «подписка» = страница подписки пользователя; - = без кнопки)" "$site")
        local lbl; lbl=$(country_label)
        if [[ -n "$(vless_id)" ]]; then
            [[ "$vname" == VLESS || -z "$vname" ]] && vname="${lbl} · VLESS"
            vname=$(prompt_keep "Название сервера VLESS" "$vname")
        fi
        if [[ -n "$(hy2_id)" ]]; then
            [[ "$hname" == Hysteria2 || -z "$hname" ]] && hname="${lbl} · Hysteria2"
            hname=$(prompt_keep "Название сервера Hysteria2" "$hname")
        fi
        if [[ -n "$(xhttp_id)" ]]; then xname=$(prompt_keep "Название сервера XHTTP" "${xname:-$(name_base "${vname:-$hname}") · VLESS XHTTP}"); fi
        if [[ -n "$(h3_id)" ]]; then h3name=$(prompt_keep "Название сервера HTTP3" "${h3name:-$(name_base "${vname:-$hname}") · VLESS XHTTP HTTP3}"); fi
    fi
    ann=${ann//\\n/$'\n'}
    if (( bset )); then
        if [[ "$btext" == "-" ]]; then btext=""; bbtn=""; burl=""; fi
        [[ "$bbtn" == "-" ]] && bbtn=""
        [[ "$burl" == "-" ]] && burl=""
        btext=${btext//\\n/$'\n'}
        [[ -z "$burl" ]] || burl=$(norm_support "$burl")
        if [[ -z "$btext" && ( -n "$bbtn" || -n "$burl" ) ]]; then echo "У баннера нет текста: задай --banner \"текст\""; exit 1; fi
        if [[ -n "$bbtn" && -z "$burl" ]]; then echo "Для кнопки баннера нужна ссылка: --banner-url https://… или @username"; exit 1; fi
        if [[ -n "$burl" && ! "$burl" =~ ^https?:// ]]; then echo "Ссылка кнопки баннера должна начинаться с https:// (или @username для Telegram)"; exit 1; fi
        if [[ -n "$burl" && -z "$bbtn" ]]; then bbtn="Открыть"; fi
    fi
    [[ "$sup" == "-" ]] && sup=""
    sup=$(norm_support "$sup")
    (( ${#ann} <= 200 )) || echo "Внимание: описание длиннее 200 символов — некоторые клиенты его обрежут."
    local mode url
    case "$site" in
        -|"") mode=none; url="" ;;
        подписка|sub|builtin) mode=builtin; url="" ;;
        *) mode=custom; url=$site ;;
    esac
    local upd
    upd=$(jq --arg t "$title" --arg a "$ann" --arg s "$sup" --arg m "$mode" --arg u "$url" '.obj
        | .subTitle = $t | .subAnnounce = $a | .subSupportUrl = $s | .subProfileMode = $m | .subProfileUrl = $u
        | .remarkTemplate = "{{INBOUND}}"' <<<"$all")
    if (( bset )); then
        upd=$(jq --arg t "$btext" --arg b "$bbtn" --arg u "$burl" '
            .subIncyBannerText = $t | .subIncyBannerButtonText = $b | .subIncyBannerButtonUrl = $u
            | .subHappSubInfoText = $t | .subHappSubInfoButtonText = $b | .subHappSubInfoButtonLink = $u
            | if $t != "" then .subIncyAppAutoDetect = true else . end' <<<"$upd")
    fi
    ok "$(api_json POST /setting/update "$upd")"
    if [[ -n "$(vless_id)" && -n "$vname" ]]; then inbound_patch "$(vless_id)" '.remark = $n' --arg n "$vname"; fi
    if [[ -n "$(hy2_id)" && -n "$hname" ]]; then inbound_patch "$(hy2_id)" '.remark = $n' --arg n "$hname"; fi
    if [[ -n "$(xhttp_id)" && -n "$xname" ]]; then inbound_patch "$(xhttp_id)" '.remark = $n' --arg n "$xname"; fi
    if [[ -n "$(h3_id)" && -n "$h3name" ]]; then inbound_patch "$(h3_id)" '.remark = $n' --arg n "$h3name"; fi
    echo "Сохранено. Перезапускаю панель (VPN моргнёт на пару секунд)…"
    systemctl restart x-ui
    local i
    for i in $(seq 1 20); do api GET /server/status 2>/dev/null | jq -e '.success == true' >/dev/null 2>&1 && break; sleep 1; done
    (( i < 20 )) || echo "Панель долго поднимается — проверь: vpn check --local"
    echo "Готово. В клиентах нажми «Обновить подписку»."
}

e2e_json() { # e2e_json <готовый JSON-конфиг клиента> <socks-порт> → IP выхода или пусто
    local xray cfg logf pid out=""
    xray=$(compgen -G '/usr/local/x-ui/bin/xray-linux-*' | head -1) || true
    [[ -x "$xray" ]] || return 0
    cfg=$(mktemp --suffix=.json); logf=$(mktemp)
    jq --argjson p "$2" '.inbounds = [{"listen": "127.0.0.1", "port": $p, "protocol": "socks", "settings": {"udp": false}}]
        | .log = {"loglevel": "warning"}' <<<"$1" > "$cfg" || { rm -f "$cfg" "$logf"; return 0; }
    "$xray" run -c "$cfg" >"$logf" 2>&1 &
    pid=$!
    sleep 3
    out=$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:$2" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
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
    local pp=$PANEL_PORT; [[ -z "${PANEL_HIDDEN:-}" ]] || pp=""   # закрытую снаружи панель не проверяем извне
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
    if [[ -n "$(vless_id)" ]]; then listening 443 tcp && r_ok "443/tcp слушается (VLESS)" || r_fail "443/tcp никто не слушает"; fi
    if [[ -n "$(hy2_id)" ]]; then listening 443 udp && r_ok "443/udp слушается (Hysteria2)" || r_fail "443/udp никто не слушает"; fi
    if [[ -n "${PANEL_HIDDEN:-}" ]]; then
        listening "$PANEL_PORT" tcp && r_ok "Панель закрыта снаружи (127.0.0.1:${PANEL_PORT})" || r_fail "${PANEL_PORT}/tcp (панель) никто не слушает"
    else listening "$PANEL_PORT" tcp && r_ok "${PANEL_PORT}/tcp слушается (панель)" || r_fail "${PANEL_PORT}/tcp (панель) никто не слушает"; fi
    listening "$SUB_PORT" tcp && r_ok "${SUB_PORT}/tcp слушается (подписки)" || r_fail "${SUB_PORT}/tcp (подписки) никто не слушает"
    if [[ -n "$(xhttp_id)" ]]; then
        listening "$XHTTP_PORT" tcp && r_ok "${XHTTP_PORT}/tcp слушается (VLESS XHTTP)" || r_fail "${XHTTP_PORT}/tcp (VLESS XHTTP) никто не слушает"
    fi
    if [[ -n "$(h3_id)" && -n "${H3_PORT:-}" ]]; then
        listening "$H3_PORT" udp && r_ok "${H3_PORT}/udp слушается (VLESS XHTTP HTTP3)" || r_fail "${H3_PORT}/udp (VLESS XHTTP HTTP3) никто не слушает"
    fi
    if [[ -n "${HOP_PORTS:-}" ]]; then
        if iptables -t nat -C PREROUTING -p udp --dport "${HOP_PORTS/-/:}" -j REDIRECT --to-ports 443 2>/dev/null; then
            r_ok "Port hopping: UDP ${HOP_PORTS} → 443 (правило iptables на месте)"
        else
            r_fail "Port hopping включён, но правила iptables нет: systemctl restart vpn-hop"
        fi
    fi
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        local miss="" p s; s=$(ufw status)
        for p in 80/tcp 443/tcp 443/udp ${pp:+"${pp}/tcp"} "${SUB_PORT}/tcp" ${XHTTP_PORT:+"${XHTTP_PORT}/tcp"} ${H3_PORT:+"${H3_PORT}/udp"}; do grep -q "^${p} " <<<"$s" || miss+=" $p"; done
        [[ -z "$miss" ]] && r_ok "ufw: нужные порты открыты" || r_fail "ufw: не открыты:${miss} (ufw allow <порт>)"
    else
        r_warn "ufw выключен (работать будет, но сервер без фаервола)"
    fi

    if api GET /clients/list 2>/dev/null | jq -e '[.obj[]? | select((.limitIp // 0) > 0)] | length > 0' >/dev/null 2>&1; then
        systemctl is-active --quiet fail2ban 2>/dev/null && r_ok "fail2ban работает (нужен для лимита IP)" \
            || r_fail "fail2ban не запущен — лимит IP не работает: x-ui → IP Limit Management → Install"
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
        if [[ -n "${SUB_DOMAIN:-}" ]]; then
            local sleft
            sleft=$(( ( $(date -d "$(openssl x509 -in "$SUB_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
            (( sleft > 7 )) && r_ok "Сертификат домена подписки ${SUB_DOMAIN}: ещё ${sleft} дн." \
                || r_warn "Сертификат домена подписки ${SUB_DOMAIN}: осталось ${sleft} дн. — проверь продление (~/.acme.sh/acme.sh --cron --force)"
        fi
        if curl -s -o /dev/null --max-time 10 "https://${SUB_DOMAIN:-$PUBLIC_HOST}:${SUB_PORT}/" 2>/dev/null; then
            r_ok "TLS подписок проходит проверку сертификата (${SUB_DOMAIN:-$PUBLIC_HOST})"
        else
            r_fail "TLS-проверка сертификата на ${SUB_DOMAIN:-$PUBLIC_HOST}:${SUB_PORT} не прошла"
        fi
    else
        r_warn "Самоподписанный сертификат: панель с предупреждением браузера, подписки по http"
    fi

    echo "— Подписка и маскировка"
    local hc sub links vl hy h3=""
    hc=$(api GET "/clients/get/${HC_USER}" 2>/dev/null || true)
    if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$hc" && ! is_node; then
        add_client "$HC_USER" 0 0 "служебный, для vpn check" >/dev/null 2>&1 || true
        hc=$(api GET "/clients/get/${HC_USER}" 2>/dev/null || true)
    fi
    local nlinks=""
    if jq -e '.success == true' >/dev/null 2>&1 <<<"$hc"; then
        sub="${SUB_BASE}$(jq -r .obj.client.subId <<<"$hc")"
        links=$(curl -sk --max-time 15 "$sub" | base64 -d 2>/dev/null || true)
        nlinks=$(grep -v "@${PUBLIC_HOST}:" <<<"$links" || true)     # серверы нод
        links=$(grep "@${PUBLIC_HOST}:" <<<"$links" || true)
        vl=$(grep -m1 '^vless://.*type=tcp' <<<"$links" || true); hy=$(grep -m1 '^hysteria2://' <<<"$links" || true)
        xh=$(grep '^vless://.*type=xhttp' <<<"$links" | grep -m1 'security=reality' || true)
        h3=$(grep '^vless://.*type=xhttp' <<<"$links" | grep -m1 'security=tls' || true)
        local want_vl="" want_hy="" okm=""
        [[ -n "$(vless_id)" ]] && want_vl=1; [[ -n "$(hy2_id)" ]] && want_hy=1
        if { [[ -z "$want_vl" || -n "$vl" ]]; } && { [[ -z "$want_hy" || -n "$hy" ]]; }; then
            [[ -n "$want_vl" ]] && okm="VLESS"; [[ -n "$want_hy" ]] && okm="${okm:+$okm и }Hysteria2"
            r_ok "Подписка отдаётся${okm:+ и содержит $okm}"
        else
            r_fail "Подписка ${SUB_BASE}… не отдаёт нужные ссылки (VLESS: ${vl:+есть}${vl:-нет}, Hysteria2: ${hy:+есть}${hy:-нет})"
        fi
        if [[ -n "$(xhttp_id)" ]]; then
            [[ -n "$xh" ]] && r_ok "Подписка содержит VLESS XHTTP" || r_fail "В подписке нет ссылки VLESS XHTTP"
        fi
        if [[ -n "$(h3_id)" ]]; then
            if [[ -n "$h3" ]] && grep -q 'alpn=h3' <<<"$h3"; then r_ok "Подписка содержит VLESS XHTTP HTTP3 (alpn h3)"
            else r_fail "В подписке нет ссылки VLESS XHTTP HTTP3 с alpn=h3"; fi
        fi
        if [[ -n "${HOP_PORTS:-}" ]]; then
            grep -q "mport=" <<<"$hy" && r_ok "В ссылке Hysteria2 есть диапазон портов (mport)" || r_fail "В ссылке Hysteria2 нет mport"
        fi
    elif is_node; then
        r_warn "Нода ещё не подключена к главной панели (нет пользователя ${HC_USER}) — подписку и сквозной тест проверю после vpn node add на главном"
    else
        r_fail "Не удалось получить служебного пользователя ${HC_USER}"
    fi
    local rs target sni res
    rs=""; [[ -z "$(reality_id)" ]] || rs=$(reality_settings 2>/dev/null || true)
    target=$(jq -r '.target // .dest // empty' <<<"$rs" 2>/dev/null || true)
    sni=$(jq -r '.serverNames[0] // empty' <<<"$rs" 2>/dev/null || true)
    if [[ "$target" == 127.0.0.1:* ]]; then
        local sp=${target##*:} sips send sleft
        sips=$(self_ipv4 "$sni")
        if [[ " $sips " == *" ${SERVER_IP} "* ]]; then r_ok "Свой домен ${sni} указывает на сервер (${SERVER_IP})"
        else r_fail "A-запись ${sni} указывает на ${sips:-ничего}, а не на ${SERVER_IP} — исправь у регистратора"; fi
        if self_https_ok "$sni" "$sp"; then r_ok "Сайт-маскировка ${sni} (${target}): TLS с действительным сертификатом и HTTP/2"
        else r_fail "Сайт-маскировка ${sni} на ${target} не отвечает (systemctl status nginx) — повторить: vpn reality self ${sni}"; fi
        if [[ -s "$SELF_DIR/fullchain.pem" ]]; then
            send=$(openssl x509 -in "$SELF_DIR/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
            sleft=$(( ( $(date -d "$send" +%s) - $(date +%s) ) / 86400 ))
            (( sleft > 7 )) && r_ok "Сертификат ${sni} действует ещё ${sleft} дн." \
                || r_warn "Сертификат ${sni} истекает через ${sleft} дн. — проверь продление: ${ACME_SH} --cron --force"
        fi
    elif [[ -n "$target" ]]; then
        res=$(reality_probe "$target" "${sni:-${target%:*}}" 2>/dev/null || true)
        if jq -e '.obj.feasible == true' >/dev/null 2>&1 <<<"$res"; then
            r_ok "Маскировка Reality ${sni} (${target}) в порядке"
        else
            r_fail "Маскировка Reality ${sni} (${target}) не проходит проверку: $(jq -r '.obj.reason // "?"' <<<"$res" 2>/dev/null) — исправить: vpn reality auto"
        fi
        if risky_sni "$sni"; then
            r_warn "SNI ${sni} принадлежит крупному CDN — на чужом IP его часто блокируют в РФ. Лучше сайт из сети хостера: vpn reality auto"
        fi
    fi

    local fj=""
    if [[ -n "${FASTEST_ID:-}" && -n "${sub:-}" ]]; then
        fj=$(curl -sk --max-time 15 -A "$FASTEST_UA_PROBE" "$sub" 2>/dev/null || true)
        if jq -e 'type == "array" and (.[0].routing.balancers | length > 0)' >/dev/null 2>&1 <<<"$fj"; then
            r_ok "JSON-подписка отдаёт «$(jq -r '.[0].remarks' <<<"$fj")» первым (серверов внутри: $(jq '[.[0].outbounds[] | select(.tag | startswith("bal-"))] | length' <<<"$fj"))"
            if jq -e '[.[] | .outbounds[] | select(.protocol == "vless") | .settings.encryption] | all(. == "none")' >/dev/null 2>&1 <<<"$fj"; then :; else
                r_fail "В JSON-подписке у VLESS пустой encryption — клиенты не подключатся: vpn fastest on"; fi
        else
            r_fail "JSON-подписка не отдаёт «Лучший сервер» (клиенты ${FASTEST_CLIENTS:-?}): vpn fastest on"
            fj=""
        fi
    fi

    local nodes=""
    if ! is_node; then nodes=$(node_list_json 2>/dev/null || true); fi
    if [[ -n "$nodes" && "$nodes" != "[]" ]]; then
        echo "— Ноды"
        local nl nname naddr nst nids nmiss
        while IFS=$'\t' read -r nname naddr nst nl; do
            [[ "$nst" == online ]] && r_ok "Нода ${nname} (${naddr}) в сети, ${nl} мс" || r_fail "Нода ${nname} (${naddr}): ${nst} — проверь сервер и его панель"
        done < <(jq -r '.[] | [.name, .address, (.status // "?"), (.latencyMs // 0 | tostring)] | @tsv' <<<"$nodes")
        nids=$(node_inbound_ids 2>/dev/null || echo '[]')
        nmiss=$(jq -c --argjson ib "$INBOUNDS" '[.[] | select(. as $x | $ib | index($x) | not)]' <<<"$nids")
        [[ "$nmiss" == "[]" ]] && r_ok "Все серверы нод ($(jq length <<<"$nids") шт.) в подписке у всех пользователей" \
            || r_fail "Серверы нод не подключены к пользователям: id ${nmiss} — выполни: vpn node sync"
    fi
    echo "— Сквозной тест (локальный клиент → сервер → интернет)"
    local ip_out
    if [[ -n "$fj" ]]; then
        ip_out=$(e2e_json "$(jq -c '.[0]' <<<"$fj")" 10874)
        [[ -n "$ip_out" ]] && r_ok "«Лучший сервер» работает, выход в интернет с IP ${ip_out}" \
            || r_fail "«Лучший сервер»: клиент не смог выйти в интернет через балансировщик"
    fi
    if [[ -n "${xh:-}" ]]; then
        ip_out=$(e2e "$xh" 10873)
        [[ -n "$ip_out" ]] && r_ok "VLESS XHTTP работает, выход в интернет с IP ${ip_out}" \
            || r_fail "VLESS XHTTP: клиент не смог выйти в интернет через сервер"
    fi
    if [[ -n "${h3:-}" ]]; then
        ip_out=$(e2e "$h3" 10875)
        [[ -n "$ip_out" ]] && r_ok "VLESS XHTTP HTTP3 (QUIC) работает, выход в интернет с IP ${ip_out}" \
            || r_fail "VLESS XHTTP HTTP3: клиент не смог выйти в интернет через сервер (открыт ли ${H3_PORT:-?}/udp у хостера?)"
    fi
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
    if [[ -n "${nlinks:-}" ]]; then
        local nlink nname2 sp=10880
        while IFS= read -r nlink; do
            [[ "$nlink" =~ ^(vless|hysteria2):// ]] || continue
            nname2=$(python3 -c 'import sys,urllib.parse as u; print(u.unquote(sys.argv[1].split("#",1)[1]) if "#" in sys.argv[1] else "?")' "$nlink" 2>/dev/null || echo "?")
            sp=$((sp + 1))
            ip_out=$(e2e "$nlink" "$sp")
            [[ -n "$ip_out" ]] && r_ok "Нода: ${nname2} работает, выход в интернет с IP ${ip_out}" \
                || r_fail "Нода: ${nname2} — клиент не смог выйти в интернет через неё"
        done <<<"$nlinks"
    fi

    if [[ "$external" == yes ]]; then
        echo "— Доступность снаружи (check-host.net)"
        local out port ru w ru_ok ru_all w_ok w_all name
        if out=$(probe "$SERVER_IP" 443 ${XHTTP_PORT:+"$XHTTP_PORT"} "$SUB_PORT" ${pp:+"$pp"} 80); then
            while read -r port ru w; do
                case "$port" in 443) name="443/tcp (VLESS)";; 80) name="80/tcp (продление сертификата)";;
                    "${XHTTP_PORT:-x}") name="${port}/tcp (VLESS XHTTP)";;
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
        echo "  (UDP снаружи не проверяется; работу Hysteria2 подтверждает сквозной тест, а с телефона — клиент)"
    fi

    echo
    echo -e "Итог: ${c_g}${N_OK} OK${c_0}, ${c_y}${N_WARN} предупреждений${c_0}, ${c_r}${N_FAIL} ошибок${c_0}"
    (( N_FAIL == 0 ))
}

# ---------------------------------------------------------------- ноды: несколько серверов в одной подписке
# Главная панель (этот сервер) управляет другими 3x-ui (нодами) через их API: пользователи, лимиты,
# трафик и подписка — здесь, серверы нод попадают в ту же подписку и в «Лучший сервер».
XUI_CLI=${XUI_CLI:-/usr/local/x-ui/x-ui}
is_node() { [[ "${ROLE:-}" == node ]]; }
node_guard() {
    if is_node; then
        echo "Это нода: пользователями управляет главная панель. Выполни команду на главном сервере."; exit 1
    fi
}
node_list_json() { local r; r=$(api GET /nodes/list); ok "$r"; jq -c '[.obj[]?]' <<<"$r"; }
node_inbound_ids() { # [id ноды] → JSON-массив id серверов нод на главной панели
    local r; r=$(api GET /inbounds/list); ok "$r"
    jq -c --arg n "${1:-}" '[.obj[]? | select(.nodeId != null and ($n == "" or (.nodeId | tostring) == $n)) | .id]' <<<"$r"
}
node_find() { # <имя|id> → id ноды
    node_list_json | jq -r --arg k "$1" '.[] | select(.name == $k or (.id | tostring) == $k) | .id' | head -1
}
node_parse_url() { # <https://адрес:порт/путь/> → NU_SCHEME NU_HOST NU_PORT NU_PATH
    [[ "$1" =~ ^(https?)://([^/:]+):([0-9]+)(/.*)?$ ]] || return 1
    NU_SCHEME=${BASH_REMATCH[1]}; NU_HOST=${BASH_REMATCH[2]}; NU_PORT=${BASH_REMATCH[3]}; NU_PATH=${BASH_REMATCH[4]:-/}
    [[ "$NU_PATH" == */ ]] || NU_PATH="$NU_PATH/"
}
node_sync() { # все пользователи → на все серверы нод; INBOUNDS и «Лучший сервер» — по факту. Печатает число новых серверов
    local ids all emails id cur miss new=0
    all=$(api GET /inbounds/list | jq -c '[.obj[]?.id]')
    env_set INBOUNDS "$(jq -c --argjson a "$all" '[.[] | select(. as $x | $a | index($x))]' <<<"$INBOUNDS")"
    ids=$(node_inbound_ids)
    emails=$(all_emails)
    for id in $(jq -r '.[]' <<<"$ids"); do
        if ! jq -e --argjson id "$id" 'index($id)' <<<"$INBOUNDS" >/dev/null; then inbounds_add "$id"; new=$((new + 1)); fi
        cur=$(api GET "/inbounds/get/$id" | jq -c '[.obj.settings | (if type == "string" then fromjson else . end) | .clients[]?.email]')
        miss=$(jq -c --argjson c "$cur" '[.[] | select(. as $e | $c | index($e) | not)]' <<<"$emails")
        if [[ "$miss" != "[]" ]]; then
            ok "$(api_json POST /clients/bulkAttach "$(jq -nc --argjson e "$miss" --argjson i "[$id]" '{emails: $e, inboundIds: $i}')")"
        fi
    done
    if [[ -n "${FASTEST_ID:-}" ]]; then fastest_sync; fi
    echo "$new"
}
node_token() { # новый API-токен «master» на этой ноде (старый перестаёт работать)
    local t
    t=$("$XUI_CLI" setting -getApiToken -tokenName master 2>/dev/null | grep -Eo 'apiToken: .+' | awk '{print $2}' || true)
    [[ -n "$t" ]] || { echo "Не удалось получить API-токен 3x-ui"; exit 1; }
    echo "$t"
}
do_node() {
    local action=${1:-list}; [[ $# -gt 0 ]] && shift
    case "$action" in
    list)
        if is_node; then echo "Этот сервер — нода. Пользователи и подписка — на главной панели."; return; fi
        local nodes ids
        nodes=$(node_list_json)
        if [[ "$nodes" == "[]" ]]; then echo "Нод нет. Добавить: vpn node add <адрес панели ноды> <токен> (см. vpn help)"; return; fi
        ids=$(api GET /inbounds/list)
        jq -r --argjson ib "$ids" '.[] | . as $n |
            "\(.name)  \(.address)  \(if .status == "online" then "в сети, \(.latencyMs) мс" else (.status // "?") end)  Xray \(.xrayVersion // "?")",
            ($ib.obj[]? | select(.nodeId == $n.id) | "    \(.remark)  (\(.protocol), порт \(.port))")' <<<"$nodes"
        ;;
    add)
        node_guard
        local url=${1:-} tok=${2:-} name="" a; shift 2 2>/dev/null || true
        while [[ $# -gt 0 ]]; do a=$1; shift; case "$a" in --name) name=${1:-}; shift ;; *) echo "Неизвестный параметр: $a"; exit 1 ;; esac; done
        [[ -n "$url" && -n "$tok" ]] || { echo "Использование: vpn node add <https://адрес:порт/путь/> <токен> [--name имя]"; echo "Адрес и токен печатает на ноде: vpn node prepare"; exit 1; }
        node_parse_url "$url" || { echo "Адрес панели ноды — вида https://1.2.3.4:12345/путь/"; exit 1; }
        [[ -n "$name" ]] || name="node-${NU_HOST}"
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Имя ноды — латиница, цифры, . _ -"; exit 1; }
        local napi="${NU_SCHEME}://${NU_HOST}:${NU_PORT}${NU_PATH}panel/api" cl tls=verify had
        had=$(node_list_json | jq -r --arg h "$NU_HOST" --arg n "$name" '.[] | select(.address == $h or .name == $n) | .name' | head -1)
        [[ -z "$had" ]] || { echo "Нода с таким адресом или именем уже подключена: «${had}» (vpn node). Новые серверы на ней: vpn node sync"; exit 1; }
        echo "Проверяю ноду ${NU_HOST}…"
        if ! cl=$(curl -s --max-time 15 -H "Authorization: Bearer $tok" "$napi/clients/list" 2>/dev/null) || [[ -z "$cl" ]]; then
            if [[ $NU_SCHEME == https ]] && cl=$(curl -sk --max-time 15 -H "Authorization: Bearer $tok" "$napi/clients/list" 2>/dev/null) && [[ -n "$cl" ]]; then
                tls=skip; echo "  Внимание: сертификат панели ноды не прошёл проверку — подключаю без неё (tls: skip)"
            fi
        fi
        jq -e '.success == true' >/dev/null 2>&1 <<<"$cl" || { echo "API ноды не ответило (адрес, порт, токен, фаервол?): ${cl:0:200}"; exit 1; }
        if [[ "$(jq '[.obj[]?] | length' <<<"$cl")" != 0 ]]; then
            echo "На ноде уже есть пользователи: $(jq -r '[.obj[]?.email] | join(", ")' <<<"$cl")."
            echo "Их имена совпадут с пользователями главной панели и испортят им подписки. На ноде выполни: vpn node prepare"
            exit 1
        fi
        local body r nid i ids n priv=false
        [[ "$NU_HOST" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.) ]] && priv=true   # адрес во внутренней сети
        body=$(jq -n --arg name "$name" --arg sch "$NU_SCHEME" --arg h "$NU_HOST" --argjson p "$NU_PORT" --arg bp "$NU_PATH" \
            --arg t "$tok" --arg tls "$tls" --argjson priv "$priv" '{name: $name, remark: $name, scheme: $sch, address: $h, port: $p, basePath: $bp,
            apiToken: $t, enable: true, allowPrivateAddress: $priv, tlsVerifyMode: $tls, inboundSyncMode: "all"}')
        r=$(api_json POST /nodes/test "$body")
        jq -e '.success == true and .obj.status == "online"' >/dev/null 2>&1 <<<"$r" \
            || { echo "Главная панель не достучалась до ноды: $(jq -r '.obj.error // .msg // "?"' <<<"$r" 2>/dev/null)"; exit 1; }
        r=$(api_json POST /nodes/add "$body"); ok "$r"; nid=$(jq -r .obj.id <<<"$r")
        echo "  Нода «${name}» добавлена, жду её серверы…"
        for i in $(seq 1 40); do ids=$(node_inbound_ids "$nid"); [[ "$ids" != "[]" ]] && break; sleep 1; done
        [[ "$ids" != "[]" ]] || { echo "Серверы ноды не появились за 40 с. Проверь: vpn node, затем vpn node sync"; exit 1; }
        sleep 3
        n=$(node_sync)
        sleep 5; node_sync >/dev/null   # второй проход: сразу после подключения панель видит старый список пользователей ноды
        echo "Готово: нода «${name}» (${NU_HOST}), серверов: $(jq length <<<"$(node_inbound_ids "$nid")"). Все пользователи добавлены на её серверы."
        echo "В клиентах обнови подписку — серверы ноды появятся в ней и в «Лучшем сервере». Проверка: vpn check --local"
        ;;
    sync)
        node_guard
        local n; n=$(node_sync)
        echo "Синхронизировано: новых серверов нод — ${n}; все пользователи есть на всех серверах. В клиентах обнови подписку."
        ;;
    del)
        node_guard
        local key=${1:-} nid ids emails id
        [[ -n "$key" ]] || { echo "Использование: vpn node del <имя>"; exit 1; }
        nid=$(node_find "$key"); [[ -n "$nid" ]] || { echo "Нода «$key» не найдена (vpn node)"; exit 1; }
        ids=$(node_inbound_ids "$nid"); emails=$(all_emails)
        for id in $(jq -r '.[]' <<<"$ids"); do
            if [[ "$emails" != "[]" ]]; then
                api_json POST /clients/bulkDetach "$(jq -nc --argjson e "$emails" --argjson i "[$id]" '{emails: $e, inboundIds: $i}')" >/dev/null || true
            fi
        done
        # выключенная нода: панель удаляет свои копии её серверов, не трогая саму ноду; потом — саму ноду
        ok "$(api_json POST "/nodes/setEnable/$nid" '{"enable": false}')"
        for id in $(jq -r '.[]' <<<"$ids"); do ok "$(api POST "/inbounds/del/$id")"; inbounds_del "$id"; done
        ok "$(api POST "/nodes/del/$nid")"
        if [[ -n "${FASTEST_ID:-}" ]]; then fastest_sync; fi
        echo "Нода «$key» отключена: пользователи сняты с её серверов, серверы убраны из подписки."
        echo "Сама нода не тронута (её 3x-ui и серверы остались). В клиентах обнови подписку."
        ;;
    rename)
        node_guard
        local key=${1:-} new=${2:-} nid r body taken
        [[ -n "$key" && -n "$new" ]] || { echo "Использование: vpn node rename <имя> <новое имя>"; exit 1; }
        [[ "$new" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Имя ноды — латиница, цифры, . _ -"; exit 1; }
        nid=$(node_find "$key"); [[ -n "$nid" ]] || { echo "Нода «$key» не найдена (vpn node)"; exit 1; }
        taken=$(node_list_json | jq -r --arg n "$new" --argjson id "$nid" '.[] | select(.name == $n and .id != $id) | .name' | head -1)
        [[ -z "$taken" ]] || { echo "Имя «$new» уже занято другой нодой"; exit 1; }
        r=$(api GET "/nodes/get/$nid"); ok "$r"
        # все поля как есть, меняется только имя (и remark, если он совпадал с именем); токен не передаём — панель его сохранит
        body=$(jq -c --arg n "$new" '.obj | {id, name: $n, remark: (if (.remark // "") == "" or .remark == .name then $n else .remark end),
            scheme, address, port, basePath, enable, allowPrivateAddress, tlsVerifyMode, pinnedCertSha256: (.pinnedCertSha256 // ""),
            inboundSyncMode, inboundTags: (.inboundTags // []), outboundTag: (.outboundTag // "")}' <<<"$r")
        r=$(api_json POST "/nodes/update/$nid" "$body")
        jq -e '.success == true' >/dev/null 2>&1 <<<"$r" || { echo "Панель не приняла новое имя: $(jq -r '.msg // .' <<<"$r" 2>/dev/null) (нода должна быть в сети: vpn node)"; exit 1; }
        echo "Нода «$key» теперь называется «$new». Серверы, пользователи и подписка не меняются."
        ;;
    prepare)
        [[ -n "${PANEL_URL:-}" ]] || { echo "Нет PANEL_URL в $ENV_FILE"; exit 1; }
        if ! is_node; then
            local cl n e
            cl=$(api GET /clients/list); ok "$cl"; n=$(jq '[.obj[]?] | length' <<<"$cl")
            echo "Готовлю этот сервер как ноду для главной панели."
            if (( n > 0 )); then
                echo "На нём будут удалены пользователи: $(jq -r '[.obj[]?.email] | join(", ")' <<<"$cl")."
                echo "Пользователями будет управлять главная панель."
                if [[ "${1:-}" != --yes ]]; then
                    local a=""
                    if ! read -r -p "Продолжить? [y/N] " a </dev/tty 2>/dev/null; then echo; echo "Нет терминала — подтверди так: vpn node prepare --yes"; exit 1; fi
                    [[ "$a" =~ ^[yYдД] ]] || { echo "Отменено"; exit 1; }
                fi
                for e in $(jq -r '.obj[]?.email' <<<"$cl"); do ok "$(api POST "/clients/del/$e")"; done
            fi
            if [[ -n "${FASTEST_ID:-}" ]]; then do_fastest off >/dev/null 2>&1 || true; fi
            env_set ROLE node
        else
            # уже нода: пользователи здесь — копии от прежнего основного. Новый основной пришлёт свои,
            # а с копиями vpn node add откажется подключать сервер
            local cl em
            cl=$(api GET /clients/list); ok "$cl"; em=$(jq -c '[.obj[]?.email]' <<<"$cl")
            if [[ "$em" != "[]" ]]; then
                echo "Убираю копии пользователей от прежнего основного: $(jq -r 'join(", ")' <<<"$em")"
                ok "$(api_json POST /clients/bulkDel "$(jq -nc --argjson e "$em" '{emails: $e}')")"
            fi
        fi
        local t cc nm
        t=$(node_token)
        cc=$(curl -fsS --max-time 6 "https://ipinfo.io/${SERVER_IP}/country" 2>/dev/null | tr -dc 'A-Za-z' | tr 'A-Z' 'a-z' | head -c 2 || true)
        nm="${cc:-node}-$(hostname -s 2>/dev/null | tr -c 'A-Za-z0-9._\n-' '-' | cut -c1-20)"
        echo
        echo "Сервер готов как нода. На ГЛАВНОМ сервере выполни:"
        echo
        echo "  vpn node add ${PANEL_URL} ${t} --name ${nm%-}"
        echo
        echo "Токен даёт полный доступ к панели этой ноды — не публикуй его. Новый токен: vpn node prepare (старый перестанет работать)."
        ;;
    *) echo "Использование: vpn node [list] | add <адрес> <токен> [--name имя] | sync | rename <имя> <новое> | del <имя> | prepare"; exit 1 ;;
    esac
}

# ---------------------------------------------------------------- смена основного сервера: vpn promote
VPN_REPO_RAW=https://raw.githubusercontent.com/p0sixxx/3x-ui-autodeploy/main/vpn-setup.sh
ssh_target() { # <[user@]host[:port]> → SSH_T (user@host), SSH_P (порт)
    SSH_T=${1%%:*}; SSH_P=22; [[ "$1" == *:* ]] && SSH_P=${1##*:}
    [[ "$SSH_T" == *@* ]] || SSH_T="root@${SSH_T}"
    [[ "$SSH_P" =~ ^[0-9]+$ ]] || { echo "Порт ssh — число: $1" >&2; return 1; }
}
rsh() { # <[user@]host[:port]> <команда…> — выполнить на другом сервере; одно соединение на сервер (пароль спросит один раз)
    ssh_target "$1" || return 1; shift
    ssh -n -p "$SSH_P" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
        -o ControlMaster=auto -o ControlPath=/tmp/vpn-ssh-%r@%h:%p -o ControlPersist=300 "$SSH_T" "$@"
}
rvpn_ready() { # <цель> — на сервере есть vpn с нужными командами, иначе обновить из репозитория
    if ! rsh "$1" '/usr/local/bin/vpn help 2>/dev/null | grep -q "vpn promote"'; then
        echo "  Обновляю vpn на $1 (пользователи не затрагиваются)…"
        rsh "$1" "bash -c 'bash <(curl -fsSL ${VPN_REPO_RAW}) --cli'" >/dev/null 2>&1 \
            && rsh "$1" '/usr/local/bin/vpn help 2>/dev/null | grep -q "vpn promote"' \
            || { echo "Не удалось обновить vpn на $1 (есть ли там интернет и vpn?)"; return 1; }
    fi
}
node_add_from() { # <вывод vpn node prepare> — подключить эту ноду к здешней панели; печатает имя
    local cmdline url tok nm
    cmdline=$(grep -o 'vpn node add [^ ]* [^ ]* --name [^ ]*' <<<"$1" | head -1)
    [[ -n "$cmdline" ]] || return 1
    read -r _ _ _ url tok _ nm <<<"$cmdline"
    /usr/local/bin/vpn node add "$url" "$tok" --name "$nm" | sed 's/^/    /' >&2 || return 1
    echo "$nm"
}
do_promote() { # [--from цель] [--nodes цель,цель] [--sub-link ссылка] [--yes]
    local from="" nodes="" sublink="" yes=0 a
    while [[ $# -gt 0 ]]; do
        a=$1; shift
        case "$a" in
            --from) from=${1:-}; shift ;;
            --nodes) nodes=${1:-}; shift ;;
            --sub-link) sublink=${1:-}; shift ;;
            --yes|-y) yes=1 ;;
            *) echo "Неизвестный параметр: $a (см. vpn help)"; exit 1 ;;
        esac
    done
    is_node || { echo "Этот сервер уже основной. vpn promote запускают на ноде, которая должна стать основной."; exit 1; }
    local bundle oldnodes='[]' me="" t targets=() n i
    if [[ -n "$from" ]]; then
        echo "Плановая смена: старый основной ${from} станет нодой, этот сервер (${SERVER_IP}) — основным."
        rvpn_ready "$from" || exit 1
        [[ "$(rsh "$from" '/usr/local/bin/vpn _role')" == main ]] || { echo "${from} — не основной сервер (или vpn там не отвечает)."; exit 1; }
        bundle=$(rsh "$from" '/usr/local/bin/vpn export') || { echo "Не удалось выгрузить пользователей с ${from}"; exit 1; }
        oldnodes=$(rsh "$from" '/usr/local/bin/vpn _nodes') || oldnodes='[]'
        me=$(jq -r --arg ip "$SERVER_IP" --arg h "${PUBLIC_HOST:-}" --argjson p "$PANEL_PORT" \
            '[.[] | select((.address == $ip or .address == $h) and .port == $p)][0].name // empty' <<<"$oldnodes")
        if [[ -z "$nodes" ]]; then
            while IFS= read -r t; do [[ -n "$t" ]] && targets+=("root@$t"); done \
                < <(jq -r --arg me "$me" '.[] | select(.name != $me) | .address' <<<"$oldnodes")
        fi
    else
        echo "Аварийный режим: старый основной недоступен. Пользователи берутся из копии на этой ноде:"
        echo "UUID, ID подписок, лимит трафика, срок и лимит IP — те же. Чего в копии нет: счётчики трафика (начнутся с нуля),"
        echo "лимиты устройств (станут «без лимита» — потом vpn limit <имя> --devices N) и отключённые пользователи."
        local cl; cl=$(api GET /clients/export); ok "$cl"
        bundle=$(jq --arg hc "$HC_USER" '{format: "vpn-export", version: 1, created: 0, source: {host: "копия на ноде", ip: ""},
            domains: {self: "", sub: "", short: false}, features: {xhttp: false, http3: false, hop: "", fastest: true},
            sub: {port: 0, path: ""}, brand: {}, defaults: {},
            clients: [.obj[]? | select(.client.email != $hc) | del(.inboundIds) | del(.traffic)]}' <<<"$cl")
        if [[ -n "$sublink" ]]; then
            [[ "$sublink" =~ ^https?://([^/:]+)(:([0-9]+))?(/.*)?/([A-Za-z0-9_-]{3,64})/?$ ]] \
                || { echo "--sub-link: нужна любая старая ссылка подписки (https://домен[:порт]/путь/ID)"; exit 1; }
            local h=${BASH_REMATCH[1]} p=${BASH_REMATCH[3]} pa=${BASH_REMATCH[4]}
            [[ -z "$pa" ]] || pa="${pa%/}/"
            bundle=$(jq --arg h "$h" --arg p "${p:-0}" --arg pa "$pa" '.sub = {port: ($p | tonumber), path: $pa}
                | if ($h | test("^[0-9.]+$")) then . else .domains = {self: (if $p == "0" then $h else "" end), sub: $h, short: ($p == "0")} end' <<<"$bundle")
        fi
    fi
    if [[ -n "$nodes" ]]; then IFS=',' read -r -a targets <<<"$nodes"; fi
    jq -e '.format == "vpn-export"' >/dev/null 2>&1 <<<"$bundle" || { echo "Не получилось собрать данные пользователей."; exit 1; }
    n=$(jq '.clients | length' <<<"$bundle")
    echo
    echo "Будет так:"
    echo "  • этот сервер (${SERVER_IP}) — основной, пользователей: ${n}"
    [[ -z "$from" ]] || echo "  • ${from} — нода этого сервера"
    if (( ${#targets[@]} )); then echo "  • перепривязать к этому серверу ноды: ${targets[*]}"; else echo "  • других нод для перепривязки нет"; fi
    echo "  Пользователи на время переключения (пара минут) могут терять соединение."
    if (( ! yes )); then
        { : </dev/tty; } 2>/dev/null || { echo "Нет терминала — добавь --yes"; exit 1; }
        read -r -p "Продолжить? [y/N]: " a </dev/tty || true
        [[ "${a,,}" =~ ^(y|yes|д|да)$ ]] || { echo "Отменено."; exit 1; }
    fi
    local save; save="/root/vpn-promote-$(date +%F-%H%M%S).json"
    ( umask 077; printf '%s\n' "$bundle" > "$save" )
    echo "Копия пользователей: ${save} (если что-то пойдёт не так: vpn import ${save} --yes)"

    # 1. старый основной отпускает все ноды: пользователи снимаются с них, ноды свободны для нового основного
    if [[ -n "$from" ]]; then
        for t in $(jq -r '.[].name' <<<"$oldnodes"); do
            echo "  ${from}: отключаю ноду ${t}"
            rsh "$from" "/usr/local/bin/vpn node del '${t}'" >/dev/null || echo "    не получилось — продолжаю"
        done
    fi
    # 2. этот сервер — основной: копии пользователей от старого основного убираем и заводим их заново как свои
    local emails; emails=$(all_emails)
    if [[ "$emails" != "[]" ]]; then ok "$(api_json POST /clients/bulkDel "$(jq -nc --argjson e "$emails" '{emails: $e}')")"; fi
    env_set ROLE ""
    echo "Переношу пользователей…"
    if ! printf '%s' "$bundle" | IMPORT_NO_HINTS=1 /usr/local/bin/vpn import - --yes | sed 's/^/    /'; then
        echo "Импорт не прошёл. Повтори: vpn import ${save} --yes"; exit 1
    fi
    load_env
    if ! api GET "/clients/get/${HC_USER}" 2>/dev/null | jq -e '.success == true' >/dev/null 2>&1; then
        add_client "$HC_USER" 0 0 "служебный, для vpn check" >/dev/null 2>&1 || true
    fi
    # 3. старый основной → нода этого сервера
    local added=() out nm
    if [[ -n "$from" ]]; then
        echo "  ${from}: делаю нодой…"
        out=$(rsh "$from" '/usr/local/bin/vpn panel show >/dev/null 2>&1; /usr/local/bin/vpn node prepare --yes') || out=""
        if nm=$(node_add_from "$out"); then added+=("$nm"); else echo "    не получилось подключить ${from} — на нём: vpn node prepare, здесь: vpn node add …"; fi
    fi
    # 4. остальные ноды
    for t in "${targets[@]}"; do
        echo "  ${t}: перепривязываю…"
        if ! rvpn_ready "$t"; then echo "    пропускаю ${t}"; continue; fi
        out=$(rsh "$t" '/usr/local/bin/vpn node prepare --yes') || out=""
        if nm=$(node_add_from "$out"); then added+=("$nm"); else echo "    не получилось — на ${t}: vpn node prepare, здесь: vpn node add …"; fi
    done
    if (( ${#added[@]} )); then sleep 3; /usr/local/bin/vpn node sync >/dev/null 2>&1 || true; fi
    # 5. «Лучший сервер»
    if [[ "$(jq -r '.features.fastest' <<<"$bundle")" == true && -z "${FASTEST_ID:-}" ]]; then
        /usr/local/bin/vpn fastest on 2>&1 | sed 's/^/    /' || true
    fi
    local dom sd
    dom=$(jq -r '.domains.sub // empty | select(. != "")' <<<"$bundle"); [[ -n "$dom" ]] || dom=$(jq -r '.domains.self // empty' <<<"$bundle")
    sd=${SELF_DOMAIN:-}
    echo
    echo "Готово: этот сервер основной. Пользователей: ${n}; нод подключено: ${#added[@]}${added[*]:+ (${added[*]})}."
    echo
    echo "Осталось вручную:"
    if [[ -n "$dom" ]]; then
        echo "  1. DNS: A-запись ${dom} → ${SERVER_IP}$( [[ -n "$sd" && -n "$from" ]] && echo "; ${sd} → IP старого основного (${from#*@})")"
        echo "  2. Когда DNS обновится, здесь: vpn reality self ${dom} && vpn sub-domain ${dom}"
        [[ -z "$(h3_id)" ]] || echo "     и пересоздать HTTP3 на новом домене: vpn http3 off && vpn http3 on --name \"…\""
        [[ -z "$sd" || -z "$from" ]] || echo "  3. На ${from#*@}: vpn reality self ${sd} (и так же HTTP3, если он там есть)"
    else
        echo "  • Ссылки подписок были на IP старого основного — пользователям нужны новые: vpn link <имя>"
    fi
    [[ -n "$from" ]] || echo "  • Подпись подписки (название, поддержка) задай заново: vpn brand"
    echo "  • Панель основного можно закрыть снаружи: vpn panel hide (у нод она должна оставаться открытой)"
    echo "  • Проверка: vpn node; vpn check --local"
}

# ---------------------------------------------------------------- vpn trace
# Запись соединений клиентов на порты VPN и разбор: дошло ли до сервера, ответил ли он,
# не теряются ли ответы (ретрансмиты), кто оборвал соединение.
trace_summary() { # trace_summary <pcap> "<адреса сервера>"
    tcpdump -nn -tttt -r "$1" 2>/dev/null | awk -v srvs="$2" '
    BEGIN { n = split(srvs, a, " "); for (i = 1; i <= n; i++) srv[a[i]] = 1 }
    {
        s = ""; d = ""
        for (i = 1; i <= NF; i++) if ($i == ">") { s = $(i-1); d = $(i+1); break }
        if (s == "") next
        sub(/:$/, "", d)
        sp = s; sub(/.*\./, "", sp); sa = s; sub(/\.[0-9]+$/, "", sa)
        dp = d; sub(/.*\./, "", dp); da = d; sub(/\.[0-9]+$/, "", da)
        proto = ($0 ~ / UDP,/ || $0 ~ / udp /) ? "udp" : "tcp"
        if (srv[da]) { dir = "in"; c = sa ":" sp; lp = dp } else if (srv[sa]) { dir = "out"; c = da ":" dp; lp = sp } else next
        split($2, t, ":"); ts = t[1] * 3600 + t[2] * 60 + t[3]
        len = 0; for (i = 1; i <= NF; i++) if ($i == "length") len = $(i+1) + 0
        f = proto " " c " " lp
        if (!(f in first)) { first[f] = ts; hms[f] = substr($2, 1, 8); order[++nf] = f; cli[f] = c; port[f] = lp; pr[f] = proto }
        last[f] = ts
        if (dir == "in") { inp[f]++; inb[f] += len } else { outp[f]++; outb[f] += len }
        if (proto == "tcp") {
            fl = ""; if (match($0, /Flags \[[^]]*\]/)) fl = substr($0, RSTART + 7, RLENGTH - 8)
            if (fl ~ /R/ && !(f in rst)) rst[f] = dir
            if (fl ~ /F/ && !(f in fin)) fin[f] = dir
            if (fl == "S" && dir == "in") syn[f]++
            if (fl == "S." && dir == "out") synack[f]++
            if (match($0, /seq [0-9]+:[0-9]+/)) {
                split(substr($0, RSTART + 4, RLENGTH - 4), q, ":"); e = q[2] + 0
                if (dir == "out") { if (e <= maxo[f]) ro[f]++; else maxo[f] = e }
                else { if (e <= maxi[f]) ri[f]++; else maxi[f] = e }
            }
        }
    }
    function kb(x) { x += 0; return x < 1024 ? x "B" : sprintf("%.1fK", x / 1024) }
    END {
        if (!nf) { print "  Ни одного пакета от клиентов на порты VPN — до сервера ничего не дошло."; exit }
        printf "  %-8s %-4s %-5s %-23s %5s %15s %15s %5s  %s\n", "время", "прот", "порт", "клиент", "сек", "к серверу", "от сервера", "повт", "итог"
        bad = 0
        for (k = 1; k <= nf; k++) {
            f = order[k]; v = ""
            if (pr[f] == "udp") {
                v = outp[f] ? "ok" : "СЕРВЕР НЕ ОТВЕТИЛ"
            } else if (!outp[f]) {
                v = "СЕРВЕР НЕ ОТВЕТИЛ (SYN x" syn[f] + 0 ")"
            } else if (syn[f] && !synack[f] && rst[f] == "out") {
                v = "порт закрыт (сервер ответил RST)"
            } else if (!inb[f] && !outb[f]) {
                v = (rst[f] == "in") ? "клиент сбросил сразу после TCP-рукопожатия" : "TCP-рукопожатие есть, данных нет"
            } else if (inb[f] && !outb[f]) {
                v = "СЕРВЕР МОЛЧИТ на данные клиента"
            } else if (ro[f] >= 3) {
                v = "ОТВЕТЫ НЕ ДОХОДЯТ ДО КЛИЕНТА (повторы сервера)"
            } else if (outb[f] < 2000 && rst[f] == "in") {
                v = "клиент оборвал на рукопожатии TLS"
            } else v = "ok"
            if (v ~ /^порт закрыт/) {}
            else if (fin[f] == "out" || rst[f] == "out") v = v ", закрыл сервер"
            else if (rst[f] == "in") v = v ", RST от клиента"
            if (v !~ /^ok/) bad++
            printf "  %-8s %-4s %-5s %-23s %5.1f %6dп %7s %6dп %7s %5s  %s\n", hms[f], pr[f], port[f], cli[f], last[f] - first[f], inp[f], kb(inb[f]), outp[f], kb(outb[f]), (ro[f] + 0) "/" (ri[f] + 0), v
        }
        printf "\n  Соединений: %d, проблемных: %d\n", nf, bad
    }'
}

do_trace() {
    local ip="" sec=120 a
    for a in "$@"; do
        if [[ $a =~ ^[0-9]+$ ]]; then sec=$a
        elif [[ $a =~ ^[0-9a-fA-F.:]+$ ]]; then ip=$a
        else echo "Использование: vpn trace [IP клиента] [секунд, по умолчанию 120]"; exit 1; fi
    done
    command -v tcpdump >/dev/null || { echo "Ставлю tcpdump…"; apt-get install -y tcpdump >/dev/null 2>&1 || { apt-get update >/dev/null 2>&1; apt-get install -y tcpdump >/dev/null 2>&1; }; }
    command -v tcpdump >/dev/null || { echo "Не удалось установить tcpdump"; exit 1; }
    local addrs h tin tout uin uout filt f cap live
    addrs=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^fe80' | xargs)
    [[ -n "$addrs" ]] || addrs=${SERVER_IP:-}
    tin="tcp dst port 443${XHTTP_PORT:+ or tcp dst port $XHTTP_PORT}"
    tout="tcp src port 443${XHTTP_PORT:+ or tcp src port $XHTTP_PORT}"
    uin="udp dst port 443${HOP_PORTS:+ or udp dst portrange $HOP_PORTS}"
    uout="udp src port 443${HOP_PORTS:+ or udp src portrange $HOP_PORTS}"
    filt=""
    for h in $addrs; do
        filt+="${filt:+ or }(dst host $h and ($tin or $uin)) or (src host $h and ($tout or $uout))"
    done
    filt="($filt)"
    [[ -n "$ip" ]] && filt+=" and host $ip"
    f=$(mktemp /tmp/vpn-trace.XXXXXX.pcap)
    local awki=(awk)   # mawk (по умолчанию в Ubuntu) буферизует ввод — без -W interactive строки придут только в конце
    awk -W interactive 'BEGIN{}' >/dev/null 2>&1 && awki=(awk -W interactive)
    echo "Записываю соединения ${ip:-всех клиентов} на порты VPN ${sec} с (Ctrl+C — закончить раньше)."
    echo "Сейчас жми проверку пинга в клиенте и запомни время, когда серверы были n/a."
    echo "Новые подключения (время сервера $(date +%H:%M:%S)):"
    tcpdump --immediate-mode -nni any -U -s 128 -c 500000 -w "$f" "$filt" 2>/dev/null & cap=$!
    tcpdump --immediate-mode -lnni any "$filt and inbound and ((tcp[tcpflags] & (tcp-syn|tcp-ack)) == tcp-syn or udp)" 2>/dev/null \
      > >("${awki[@]}" 'NF<5{next} {for(i=1;i<=NF;i++) if($i==">"){s=$(i-1);d=$(i+1)}; ip=s; sub(/\.[0-9]+$/,"",ip); p=d; sub(/:$/,"",p); sub(/.*\./,"",p); pr=($0~/Flags/)?"tcp":"udp"; k=ip" "pr"/"p; t=substr($1,1,7); if(last[k]!=t){last[k]=t; print "  " substr($1,1,8), ip, pr"/"p; fflush()}}') & live=$!
    trap ':' INT
    sleep "$sec" || true
    trap - INT
    kill "$cap" "$live" 2>/dev/null || true
    wait "$cap" "$live" 2>/dev/null || true
    sleep 0.3
    echo
    echo "Разбор по соединениям (повт = повторы пакетов сервер/клиент):"
    trace_summary "$f" "$addrs"
    echo
    echo "Запись сохранена: $f (удалить: rm $f)"
}

# ---------------------------------------------------------------- перенос на другой сервер
do_export() { # [файл] — все пользователи (UUID, ключи, ID подписки, лимиты, срок, трафик) и настройки подписки → JSON
    node_guard
    local out=${1:-} all cl bundle n
    if [[ -z "$out" && -t 1 ]]; then
        echo "Файл содержит ключи пользователей. Укажи файл: vpn export /root/vpn-clients.json" >&2
        echo "(или на новом сервере: vpn import --from root@<IP этого сервера>)" >&2
        exit 1
    fi
    all=$(api POST /setting/all); ok "$all"
    cl=$(api GET /clients/export); ok "$cl"
    bundle=$(jq --argjson st "$all" --arg hc "$HC_USER" \
        --arg host "${PUBLIC_HOST:-}" --arg ip "${SERVER_IP:-}" --arg sd "${SELF_DOMAIN:-}" --arg bd "${SUB_DOMAIN:-}" \
        --arg short "${SUB_SHORT:-}" --arg dev "${DEF_DEVICES:-}" --arg ips "${DEF_IPS:-}" --arg hop "${HOP_PORTS:-}" \
        --arg xh "$(xhttp_id)" --arg h3 "$(h3_id)" --arg fa "${FASTEST_ID:-}" --arg ts "$(date +%s)" '. as $cl | {
        format: "vpn-export", version: 1, created: ($ts | tonumber),
        source: {host: $host, ip: $ip},
        domains: {self: $sd, sub: $bd, short: ($short != "")},
        features: {xhttp: ($xh != ""), http3: ($h3 != ""), hop: $hop, fastest: ($fa != "")},
        sub: {port: $st.obj.subPort, path: $st.obj.subPath},
        brand: {title: ($st.obj.subTitle // ""), announce: ($st.obj.subAnnounce // ""), support: ($st.obj.subSupportUrl // ""),
                profileMode: ($st.obj.subProfileMode // ""), profileUrl: ($st.obj.subProfileUrl // "")},
        defaults: {devices: $dev, ips: $ips},
        clients: [$cl.obj[]? | select(.client.email != $hc) | del(.inboundIds)]
    }' <<<"$cl") || { echo "Не удалось собрать экспорт" >&2; exit 1; }
    n=$(jq '.clients | length' <<<"$bundle")
    if [[ -n "$out" ]]; then
        ( umask 077; printf '%s\n' "$bundle" > "$out" )
        echo "Экспортировано пользователей: ${n} → ${out} (файл с ключами, после переноса удали: rm ${out})" >&2
    else
        printf '%s\n' "$bundle"
        echo "Экспортировано пользователей: ${n}" >&2
    fi
}

# --- перенос: порт и путь подписки как на старом сервере
sub_plan() { # <старые настройки> <новые настройки> <порт> <путь> → PLAN_UPD (настройки с новым портом/путём), PLAN_LK=1, если что-то меняется
    local old_all=$1 new_port=$3 new_path=$4 cur_uri cur_path sch host new_uri
    PLAN_UPD=$2; PLAN_LK=0
    [[ "$new_port" =~ ^[0-9]+$ && -n "$new_path" ]] && (( new_port > 0 )) || return 0
    cur_uri=$(jq -r '.obj.subURI' <<<"$old_all"); cur_path=$(jq -r '.obj.subPath' <<<"$old_all")
    if [[ "$new_port" == "$SUB_PORT" && "$new_path" == "$cur_path" ]]; then
        echo "Порт и путь подписки уже совпадают со старым сервером."
    elif [[ "$new_port" != "$SUB_PORT" ]] && listening "$new_port" tcp; then
        echo "Порт подписки ${new_port} со старого сервера занят здесь — ссылки со старым портом не заработают. Освободи порт и повтори vpn import (перенесённые пользователи будут пропущены)."
    else
        sch=$(sed -E 's|^(https?)://.*|\1|' <<<"$cur_uri"); host=$(sed -E 's|^https?://([^/:]+).*|\1|' <<<"$cur_uri")
        if [[ -n "${SUB_SHORT:-}" ]]; then new_uri=$cur_uri; else new_uri="${sch}://${host}:${new_port}${new_path}"; fi
        PLAN_UPD=$(jq --argjson p "$new_port" --arg path "$new_path" --arg uri "$new_uri" '.subPort = $p | .subPath = $path | .subURI = $uri' <<<"$2")
        PLAN_LK=1
    fi
}
sub_commit() { # <старые настройки> <новые настройки> <порт> <путь> <1 — порт/путь меняются> — записать, перезапустить панель, проверить подписку; не отдаётся — откат (return 1)
    local old_all=$1 upd=$2 new_port=$3 new_path=$4 lk=$5 hc_sid code=200 sch i
    echo "Применяю настройки подписки (панель перезапустится, VPN моргнёт на пару секунд)…"
    ok "$(api_json POST /setting/update "$upd")"
    restart_panel
    wait_panel || true
    (( lk )) || return 0
    local old_port=$SUB_PORT old_base=$SUB_BASE old_spath=${SUB_PATH:-}
    env_set SUB_PORT "$new_port"; env_set SUB_PATH "$new_path"
    [[ -n "${SUB_SHORT:-}" ]] || env_set SUB_BASE "$(jq -r .subURI <<<"$upd")"
    if [[ "$new_port" != "$old_port" ]] && command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${new_port}/tcp" comment 3x-ui-sub >/dev/null 2>&1 || true
    fi
    if [[ -n "${SUB_SHORT:-}" && -n "${SELF_DOMAIN:-}" ]]; then self_nginx "$SELF_DOMAIN" "$SELF_PORT"; fi
    hc_sid=$(api GET /clients/list | jq -r --arg hc "$HC_USER" '[.obj[]? | select(.email == $hc)][0].subId // empty')
    if [[ -n "$hc_sid" ]]; then
        code=000; sch=$(sed -E 's|^(https?)://.*|\1|' <<<"$(jq -r .subURI <<<"$upd")")
        for i in 1 2 3 4 5 6; do
            code=$(curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 8 "${sch}://127.0.0.1:${new_port}${new_path}${hc_sid}" 2>/dev/null || true)
            [[ "$code" == 200 ]] && break; sleep 1
        done
    fi
    if [[ "$code" != 200 ]]; then
        echo "Подписка не отдаётся на порту ${new_port} (HTTP ${code}) — возвращаю прежние настройки. Пользователи при этом перенесены."
        ok "$(api_json POST /setting/update "$(jq '.obj' <<<"$old_all")")"
        restart_panel
        env_set SUB_PORT "$old_port"; env_set SUB_BASE "$old_base"; env_set SUB_PATH "$old_spath"
        if [[ "$new_port" != "$old_port" ]] && command -v ufw >/dev/null; then ufw delete allow "${new_port}/tcp" >/dev/null 2>&1 || true; fi
        if [[ -n "${SUB_SHORT:-}" && -n "${SELF_DOMAIN:-}" ]]; then self_nginx "$SELF_DOMAIN" "$SELF_PORT"; fi
        return 1
    fi
    if [[ "$new_port" != "$old_port" ]] && command -v ufw >/dev/null; then ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true; fi
    echo "Порт и путь подписки как на старом сервере: ${new_port}${new_path}"
}

# --- перенос из файла базы 3x-ui (x-ui.db): со снапшота, из rescue-режима, из бэкапа Telegram-бота
db_bundle() { # <x-ui.db> → тот же экспорт, что делает vpn export (JSON в stdout)
    python3 -I - "$1" <<'PY'
import json, os, re, shutil, sqlite3, sys, tempfile, time
src = sys.argv[1]
tmp = tempfile.mkdtemp()
try:
    for suf in ("", "-wal", "-shm"):   # рядом с базой может лежать журнал с последними записями
        if os.path.exists(src + suf):
            shutil.copy2(src + suf, os.path.join(tmp, "x-ui.db" + suf))
    c = sqlite3.connect(os.path.join(tmp, "x-ui.db"))
    c.row_factory = sqlite3.Row
    tables = {r[0] for r in c.execute("select name from sqlite_master where type='table'")}
    if "clients" not in tables:
        sys.exit(3)
    st = {r["key"]: r["value"] for r in c.execute("select key, value from settings")}
    flow_ov = {}
    if "client_inbounds" in tables:
        for r in c.execute("select client_id, flow_override from client_inbounds order by inbound_id"):
            if r["flow_override"]:
                flow_ov.setdefault(r["client_id"], r["flow_override"])
    traffic = {}
    if "client_traffics" in tables:
        for r in c.execute("select email, up, down, reset_count from client_traffics"):
            traffic[r["email"]] = {"up": r["up"] or 0, "down": r["down"] or 0, "resetCount": r["reset_count"] or 0}
    clients = []
    for r in c.execute("select * from clients order by id"):
        if r["email"] == "healthcheck":
            continue
        cl = {"id": r["uuid"] or "", "security": r["security"] or "", "flow": flow_ov.get(r["id"]) or r["flow"] or "",
              "auth": r["auth"] or "", "email": r["email"], "limitIp": r["limit_ip"] or 0, "totalGB": r["total_gb"] or 0,
              "expiryTime": r["expiry_time"] or 0, "enable": True if r["enable"] is None else bool(r["enable"]),
              "tgId": r["tg_id"] or 0, "subId": r["sub_id"] or "", "comment": r["comment"] or "",
              "reset": r["reset"] or 0, "resetDay": r["reset_day"] or 0, "resetWeekday": r["reset_weekday"] or 0,
              "resetMax": r["reset_max"] or 0, "trafficReset": r["traffic_reset"] or "never",
              "trafficResetDay": r["traffic_reset_day"] or 1, "created_at": r["created_at"] or 0,
              "updated_at": r["updated_at"] or 0, "limitHwid": r["limit_hwid"] or 0}
        item = {"client": cl}
        if r["email"] in traffic:
            item["traffic"] = traffic[r["email"]]
        clients.append(item)
    m = re.match(r"^https?://([^/:]+)(:(\d+))?(/.*)?$", st.get("subURI", "") or "")
    host = m.group(1) if m else ""
    is_ip = bool(re.match(r"^\d+\.\d+\.\d+\.\d+$", host)) or ":" in host
    dom_sub = "" if is_ip else host
    short = bool(m and not m.group(3) and dom_sub)
    dom_self, xhttp, h3 = "", False, False
    for r in c.execute("select stream_settings from inbounds"):
        try:
            ss = json.loads(r["stream_settings"] or "{}")
        except ValueError:
            continue
        if ss.get("security") == "reality":
            rs = ss.get("realitySettings") or {}
            if str(rs.get("target") or rs.get("dest") or "").startswith("127.0.0.1:") and rs.get("serverNames"):
                dom_self = rs["serverNames"][0]
            if ss.get("network") == "xhttp":
                xhttp = True
        elif ss.get("network") == "xhttp" and ss.get("security") == "tls":
            h3 = True
    fastest = "sub_balancers" in tables and c.execute("select count(*) from sub_balancers").fetchone()[0] > 0
    try:
        port = int(st.get("subPort") or 0)
    except ValueError:
        port = 0
    out = {"format": "vpn-export", "version": 1, "created": int(time.time()), "source": {"host": host, "ip": "", "db": True},
           "domains": {"self": dom_self, "sub": dom_sub, "short": short},
           "features": {"xhttp": xhttp, "http3": h3, "hop": "", "fastest": fastest},
           "sub": {"port": port, "path": st.get("subPath", "")},
           "brand": {"title": st.get("subTitle", ""), "announce": st.get("subAnnounce", ""), "support": st.get("subSupportUrl", ""),
                     "profileMode": st.get("subProfileMode", ""), "profileUrl": st.get("subProfileUrl", "")},
           "defaults": {"devices": "", "ips": ""}, "clients": clients}
    print(json.dumps(out, ensure_ascii=False))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PY
}

# --- перенос по сохранённым ссылкам: файл со строками «имя ссылка [ГБ] [дней]» → тот же экспорт
links_bundle() { # <файл> → JSON в stdout
    local f=$1 line name link gb days rest sid host port path n=0 now i
    local first_port="" first_path="" first_host="" arr='[]'
    [[ -r "$f" ]] || { echo "Нет файла $f" >&2; return 1; }
    now=$(now_ms)
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        read -r name link gb days rest <<<"$line" || true
        [[ -n "$name" ]] || continue
        gb=${gb:-0}; days=${days:-0}
        [[ "$name" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || { echo "Строка «${line}»: имя — латиница, цифры и . _ - @ (до 64 символов)" >&2; return 1; }
        is_num "$gb" && is_num "$days" || { echo "Строка «${line}»: ГБ и дни — числа" >&2; return 1; }
        [[ "$link" =~ ^https?://([^/:]+)(:([0-9]+))?(/.*)?/([A-Za-z0-9_-]{3,64})/?$ ]] \
            || { echo "Строка «${line}»: не похоже на ссылку подписки (https://хост[:порт]/путь/ID)" >&2; return 1; }
        host=${BASH_REMATCH[1]}; port=${BASH_REMATCH[3]}; path=${BASH_REMATCH[4]}; sid=${BASH_REMATCH[5]}
        [[ -z "$path" ]] || path="${path%/}/"
        if [[ -n "$port" && -n "$path" ]]; then
            if [[ -z "$first_port" ]]; then first_port=$port; first_path=$path; first_host=$host
            elif [[ "$first_port$first_path" != "$port$path" ]]; then echo "Предупреждение: у «${name}» другой порт или путь (${port}${path}), беру из первой ссылки (${first_port}${first_path})" >&2; fi
        fi
        [[ -n "$first_host" ]] || first_host=$host
        local exp=0; [[ "$days" != 0 ]] && exp=$(( now + ${days%.*} * 86400000 ))
        arr=$(jq -c --arg e "$name" --arg sid "$sid" --arg id "$(cat /proc/sys/kernel/random/uuid)" --arg auth "$(openssl rand -hex 16)" \
            --arg gb "$gb" --argjson exp "$exp" --argjson G $GiB --argjson dev "${DEF_DEVICES:-0}" --argjson ips "${DEF_IPS:-0}" \
            '. + [{client: {id: $id, flow: "xtls-rprx-vision", auth: $auth, email: $e, limitIp: $ips, totalGB: (($gb|tonumber) * $G | floor),
              expiryTime: $exp, enable: true, tgId: 0, subId: $sid, comment: "", reset: 0, resetDay: 0, resetWeekday: 0, resetMax: 0,
              trafficReset: "never", trafficResetDay: 1, limitHwid: $dev}, traffic: {up: 0, down: 0, resetCount: 0}}]' <<<"$arr")
        n=$((n + 1))
    done < "$f"
    (( n > 0 )) || { echo "В файле нет ни одной строки «имя ссылка»" >&2; return 1; }
    local dsub="" dself="" short=false
    if [[ -n "$first_host" && ! "$first_host" =~ ^[0-9.]+$ ]]; then dsub=$first_host; [[ -n "$first_port" ]] || { short=true; dself=$first_host; }; fi
    jq -n --argjson cl "$arr" --arg port "${first_port:-0}" --arg path "$first_path" --arg h "$first_host" --arg ds "$dsub" --arg dself "$dself" --argjson short "$short" '{
        format: "vpn-export", version: 1, created: 0, source: {host: $h, ip: "", links: true},
        domains: {self: $dself, sub: $ds, short: $short}, features: {xhttp: false, http3: false, hop: "", fastest: false},
        sub: {port: ($port | tonumber), path: $path}, brand: {}, defaults: {}, clients: $cl}'
}

do_import() { # <файл|x-ui.db|-> | --from [user@]хост[:порт] | --links <файл со ссылками>  [--update] [--no-links] [--no-brand] [--yes]
    node_guard
    local src="" from="" lfile="" links=1 brand=1 yes=0 sync=0 a bundle n tb cur skipped created tty=0
    while [[ $# -gt 0 ]]; do
        a=$1; shift
        case "$a" in
            --from) from=${1:-}; [[ -n "$from" ]] || { echo "--from: укажи [user@]хост[:порт]"; exit 1; }; shift ;;
            --links) lfile=${1:-}; [[ -n "$lfile" ]] || { echo "--links: укажи файл со строками «имя ссылка [ГБ] [дней]»"; exit 1; }; shift ;;
            --update) sync=1 ;;
            --no-links) links=0 ;;
            --no-brand) brand=0 ;;
            --yes|-y) yes=1 ;;
            -) src=- ;;
            -*) echo "Неизвестный параметр: $a (см. vpn help)"; exit 1 ;;
            *) src=$a ;;
        esac
    done
    [[ -n "$from" || -n "$src" || -n "$lfile" ]] || { echo "Использование: vpn import <файл экспорта или x-ui.db> | --from [user@]хост[:порт] | --links <файл> [--update] [--no-links] [--no-brand] [--yes]"; exit 1; }
    if [[ -n "$lfile" ]]; then
        bundle=$(links_bundle "$lfile") || exit 1
    elif [[ -n "$from" ]]; then
        local target port=22 sshopt=()
        target=${from%%:*}; [[ "$from" == *:* ]] && port=${from##*:}
        [[ "$target" == *@* ]] || target="root@${target}"
        [[ "$port" =~ ^[0-9]+$ ]] || { echo "--from: порт — число"; exit 1; }
        sshopt=(-n -p "$port" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
        echo "Подключаюсь к ${target} (порт ${port}); если спросит пароль — это пароль root старого сервера…" >&2
        bundle=$(ssh "${sshopt[@]}" "$target" /usr/local/bin/vpn export) \
            || { echo "Не удалось получить данные по ssh. Проверь адрес и доступ; на старом сервере должен быть свежий vpn: bash <(curl -fsSL https://raw.githubusercontent.com/p0sixxx/3x-ui-autodeploy/main/vpn-setup.sh) --cli"; exit 1; }
    elif [[ "$src" == - ]]; then
        bundle=$(cat)
    else
        [[ -r "$src" ]] || { echo "Нет файла $src"; exit 1; }
        if [[ "$(head -c 15 "$src" 2>/dev/null)" == "SQLite format 3" ]]; then
            echo "Это база 3x-ui (x-ui.db): читаю пользователей из неё…" >&2
            bundle=$(db_bundle "$src") || { echo "В этой базе нет таблицы клиентов. Если рядом с x-ui.db лежат x-ui.db-wal и x-ui.db-shm, скопируй их вместе с ней в одну папку (в них свежие записи). Либо база не от 3x-ui версии 3.9." >&2; exit 1; }
        else
            bundle=$(cat "$src")
        fi
    fi
    jq -e '.format == "vpn-export" and (.clients | type == "array")' >/dev/null 2>&1 <<<"$bundle" || {
        echo "Это не экспорт vpn."
        echo "Скорее всего, на старом сервере старая версия vpn без команды export. Обнови её там (пользователи не затрагиваются):"
        echo "  bash <(curl -fsSL https://raw.githubusercontent.com/p0sixxx/3x-ui-autodeploy/main/vpn-setup.sh) --cli"
        exit 1; }
    n=$(jq '.clients | length' <<<"$bundle")
    tb=$(jq '[.clients[].traffic // {} | (.up // 0) + (.down // 0)] | add // 0' <<<"$bundle")
    cur=$(all_emails)
    # кого создавать, а кого обновлять. me делает установщик, поэтому «свежий» me заменяется старым (иначе ссылка владельца изменится);
    # с --update данными старого сервера перезаписываются все, кто уже есть здесь (срок, лимиты, трафик, новые ключи)
    local mesub new_list upd_list n_new n_upd n_skip
    mesub=$(api GET /clients/list | jq -r '[.obj[]? | select(.email == "me")][0].subId // empty')
    new_list=$(jq -c --argjson cur "$cur" --argjson ib "$INBOUNDS" \
        '[.clients[] | select(.client.email as $e | $cur | index($e) | not) | .inboundIds = $ib]' <<<"$bundle")
    upd_list=$(jq -c --argjson cur "$cur" --argjson all "$sync" --arg ms "$mesub" \
        '[.clients[] | select((.client.email as $e | $cur | index($e)) and ($all == 1 or (.client.email == "me" and $ms != "" and .client.subId != $ms)))]' <<<"$bundle")
    n_new=$(jq 'length' <<<"$new_list"); n_upd=$(jq 'length' <<<"$upd_list"); n_skip=$(( n - n_new - n_upd ))
    echo "В экспорте: пользователей ${n}, трафик уже израсходован $(awk -v b="$tb" -v G=$GiB 'BEGIN{printf "%.1f", b/G}') ГБ, источник: $(jq -r '.source.host // "?"' <<<"$bundle")"
    echo "  Создам новых: ${n_new}; обновлю: ${n_upd}; пропущу (уже есть здесь): ${n_skip}"
    if (( n_upd > 0 )); then echo "  Обновлю: $(jq -r '[.[].client.email] | join(", ")' <<<"$upd_list")"; fi
    if (( n_skip > 0 )); then
        echo "  Пропущу: $(jq -r --argjson cur "$cur" --argjson u "$upd_list" '[.clients[].client.email | select((. as $e | $cur | index($e)) and (. as $e | ($u | map(.client.email) | index($e)) | not))] | join(", ")' <<<"$bundle")"
        echo "  (чтобы обновить их данными со старого сервера — срок, лимиты, трафик — добавь --update)"
    fi
    (( n_new + n_upd > 0 )) || { echo "Переносить нечего: все пользователи уже здесь."; }
    if (( ! yes )) && (( n_new + n_upd > 0 )); then
        { : </dev/tty; } 2>/dev/null && tty=1
        (( tty )) || { echo "Нет терминала — добавь --yes"; exit 1; }
        read -r -p "Перенести? [y/N]: " a </dev/tty || true
        [[ "${a,,}" == y || "${a,,}" == yes || "${a,,}" == д || "${a,,}" == да ]] || { echo "Отменено."; exit 1; }
    fi

    local res e
    if (( n_new > 0 )); then
        echo "Переношу пользователей…"
        # тело через stdin: список пользователей может не поместиться в аргумент командной строки
        res=$(jq -c '{data: (. | tostring)}' <<<"$new_list" \
            | api POST /clients/import -H 'Content-Type: application/json' --data-binary @- --max-time 600); ok "$res"
        created=$(jq -r '.obj.created // 0' <<<"$res")
        skipped=$(jq -r '[.obj.skipped[]? | "    - \(.email): \(.reason)"] | join("\n")' <<<"$res")
        echo "Создано: ${created} из ${n_new}"
        if [[ -n "$skipped" ]]; then echo "  Пропущено:"; echo "$skipped"; fi
    fi
    local pu pt
    while IFS=$'\x1f' read -r e pu pt; do
        [[ -n "$e" ]] || continue
        ok "$(api_json POST "/clients/update/${e}" "$pu")"
        ok "$(api_json POST "/clients/updateTraffic/${e}" "$pt")"
    done < <(jq -r '.[] | [.client.email,
        (.client | {email, id, auth, subId, flow, limitIp, limitHwid, tgId, comment, reset, enable, totalGB, expiryTime} | tojson),
        ({upload: (.traffic.up // 0), download: (.traffic.down // 0)} | tojson)] | join("\u001f")' <<<"$upd_list")
    (( n_upd == 0 )) || echo "Обновлено: ${n_upd}"

    # порт и путь подписки, подпись подписки — как на старом сервере, чтобы прежние ссылки заработали после переключения DNS
    local old_all new_port new_path upd changed=0 lk=0
    old_all=$(api POST /setting/all); ok "$old_all"
    upd=$(jq '.obj' <<<"$old_all")
    new_port=$(jq -r '.sub.port // empty' <<<"$bundle"); new_path=$(jq -r '.sub.path // empty' <<<"$bundle")
    if (( links )); then
        sub_plan "$old_all" "$upd" "$new_port" "$new_path"
        upd=$PLAN_UPD; lk=$PLAN_LK; (( lk )) && changed=1
    fi
    if (( brand )); then
        upd=$(jq --argjson b "$(jq -c '.brand // {}' <<<"$bundle")" '
            (if ($b.title // "") != "" then .subTitle = $b.title else . end)
            | (if ($b.announce // "") != "" then .subAnnounce = $b.announce else . end)
            | (if ($b.support // "") != "" then .subSupportUrl = $b.support else . end)
            | (if ($b.profileMode // "") != "" then .subProfileMode = $b.profileMode | .subProfileUrl = ($b.profileUrl // "") else . end)' <<<"$upd")
        [[ "$upd" == "$(jq '.obj' <<<"$old_all")" ]] || changed=1
    fi
    if (( changed )); then sub_commit "$old_all" "$upd" "$new_port" "$new_path" "$lk" || exit 1; fi
    local d_dev d_ips
    d_dev=$(jq -r '.defaults.devices // empty' <<<"$bundle"); d_ips=$(jq -r '.defaults.ips // empty' <<<"$bundle")
    if [[ -n "$d_dev" ]]; then env_set DEF_DEVICES "$d_dev"; fi
    if [[ -n "$d_ips" ]]; then env_set DEF_IPS "$d_ips"; fi

    local sd sb step=1 hp
    if [[ -n "${IMPORT_NO_HINTS:-}" ]]; then echo "Импорт завершён: создано ${created:-0}, обновлено ${n_upd}."; return 0; fi
    sd=$(jq -r '.domains.self // empty' <<<"$bundle"); sb=$(jq -r '.domains.sub // empty' <<<"$bundle")
    echo
    if (( n_new + n_upd > 0 )); then echo "Готово. Пользователи, ключи, ID подписок, лимиты, сроки и трафик перенесены."; else echo "Готово."; fi
    if jq -e 'any(.clients[]; .client.email == "me")' >/dev/null <<<"$bundle"; then echo "Проверка по IP этого сервера: vpn link me   (ID у me тот же, что был на старом)"
    else echo "Проверка по IP этого сервера: vpn link <имя>"; fi
    echo
    if [[ -n "$sd" || -n "$sb" ]]; then
        echo "Что дальше (когда проверишь работу по IP):"
        echo "  ${step}. Переключи DNS: A-запись ${sb:-$sd} → ${SERVER_IP} и подожди TTL (5–15 минут)."; step=$((step + 1))
        echo "  ${step}. vpn reality self ${sd:-$sb}"; step=$((step + 1))
        echo "  ${step}. vpn sub-domain ${sb:-$sd}"; step=$((step + 1))
        if [[ "$(jq -r '.features.http3' <<<"$bundle")" == true && -z "$(h3_id)" ]]; then echo "  ${step}. vpn http3 on   (на старом сервере был включён)"; step=$((step + 1)); fi
        echo "  Клиенты подхватят новый сервер при следующем обновлении подписки (раз в 6 часов). Если старый сервер ещё работает, не выключай его до тех пор."
    else
        echo "Ссылки на старом сервере привязаны к его IP: пользователям нужно добавить новые (vpn link <имя>)."
        echo "Чтобы в будущем переезды были незаметными, заведи домен: vpn reality self <домен>, затем vpn sub-domain <домен>."
    fi
    if [[ "$(jq -r '.features.xhttp' <<<"$bundle")" == true && -z "$(xhttp_id)" ]]; then echo "  •  vpn xhttp on   (на старом сервере был включён)"; fi
    hp=$(jq -r '.features.hop // empty' <<<"$bundle")
    if [[ -n "$hp" && -z "${HOP_PORTS:-}" ]]; then echo "  •  vpn hop on ${hp}   (port hopping был включён)"; fi
    if [[ "$(jq -r '.features.fastest' <<<"$bundle")" == true && -z "${FASTEST_ID:-}" ]]; then echo "  •  vpn fastest on   («Лучший сервер» был включён)"; fi
}

usage() {
    cat <<EOF
vpn add <имя> <ГБ> <дней> [комментарий] [--devices N] [--ips N] [--sub-id ID]
                                         — новый пользователь (0 = без лимита / бессрочно); --sub-id — вернуть
                                           пользователю прежний ID подписки (последняя часть старой ссылки)
vpn limit <имя|all|default> [--devices N] [--ips N]
                                         — лимит устройств (по ID устройства) и одновременных IP;
                                           all — всем, кроме me; default — для новых пользователей
vpn devices <имя> [reset|<номер>]        — устройства пользователя: список / сбросить все / удалить одно
vpn list                                 — все пользователи, трафик, сроки
vpn link <имя>                           — ссылка подписки + QR
vpn renew <имя> <дней> [ГБ]              — продлить и обнулить трафик (ГБ — новый лимит)
vpn expire <имя> <дней>                  — задать срок «N дней от сегодня» (0 — бессрочно), трафик не трогает
vpn reset <имя>                          — обнулить трафик
vpn off|on <имя>                         — отключить / включить
vpn del <имя>                            — удалить
vpn panel [hide|show|status]             — адрес и логин панели; hide — закрыть панель снаружи (доступ через ssh-туннель)
vpn check [--local]                      — полная диагностика (--local: без проверки снаружи)
vpn export [файл]                        — выгрузить всех пользователей (ключи, ID подписок, лимиты, сроки, трафик) в файл
vpn import <файл экспорта | x-ui.db> | --from [user@]хост[:порт] | --links <файл> [--update] [--no-links] [--no-brand] [--yes]
                                         — перенос со старого сервера на этот (новый, главный): пользователи с теми же
                                           ссылками подписки. Источник: файл vpn export, ssh (--from), база x-ui.db
                                           (со снапшота, из rescue или бэкапа Telegram-бота) или файл ссылок
                                           «имя ссылка [ГБ] [дней]». Порт и путь подписки становятся как на старом
                                           (--no-links — не менять), подпись подписки тоже (--no-brand);
                                           --update — перезаписать уже существующих данными источника
vpn node                                 — ноды (другие серверы в этой же подписке): список
vpn node add <адрес панели> <токен> [--name имя] — подключить сервер-ноду (адрес и токен: vpn node prepare на ноде)
vpn node sync | del <имя>                — дотянуть новые серверы нод и всех пользователей / отключить ноду
vpn node rename <имя> <новое имя>        — переименовать ноду (видно только в vpn node; подписку не трогает)
vpn promote [--from root@IP] [--nodes root@IP,…] [--sub-link ссылка] [--yes]
                                         — (на ноде) сделать этот сервер основным. --from: плановая смена, старый
                                           основной по ssh отдаёт пользователей и становится нодой. Без --from: авария,
                                           пользователи из копии на ноде. Остальные ноды перепривязываются по ssh
vpn node prepare                         — (на новом сервере) сделать его нодой и показать команду для главного
vpn trace [IP] [секунд]                  — запись подключений клиентов и разбор: дошло ли, ответил ли сервер
vpn reality [auto|<домен>|<ip:443> <домен>] — маскировка Reality: показать / подобрать в сети хостера / задать
vpn reality self <свой домен>            — Reality на свой домен (A-запись → этот сервер): сертификат, сайт-заглушка,
                                           SNI = домен. Лучшая защита от блокировок по SNI
vpn sub-domain <домен> [--port] | off | status
                                         — ссылка подписки на своём домене: https://домен/<ID> (без порта, через 443,
                                           если это домен vpn reality self) или с портом (--port / другой домен)
vpn brand                                — подпись подписки и названия серверов (мастер с вопросами)
vpn brand --show                         — показать текущие
vpn brand [--title Т] [--announce Т] [--support @user|URL|-] [--site URL|подписка|-]
          [--vless-name Т] [--hy2-name Т] [--xhttp-name Т] [--http3-name Т] [--auto-names] — то же флагами
                                           (@user → https://t.me/user; «-» — убрать кнопку; подписи кнопок
                                           «Поддержка» и «Сайт» рисует клиент, их не поменять)
vpn brand --banner "текст" [--banner-button "Текст кнопки"] [--banner-url https://…|@user] | --banner -
                                         — баннер со своей кнопкой в INCY (ссылка одна на всех; - — убрать)
vpn xhttp on [порт] | off                — доп. сервер VLESS + XHTTP + Reality (по умолчанию порт 8443)
vpn http3 on [порт] [--name Т] | off     — доп. сервер VLESS + XHTTP по HTTP/3 (QUIC, UDP) на своём домене
                                           (нужен vpn reality self; по умолчанию порт 4443/udp)
vpn hop on [от-до] | off                 — port hopping для Hysteria2 (по умолчанию UDP 20000-50000)
vpn fastest on|off|status [--name Т] [--clients happ,v2raytun,incy] [--interval 10s] [--sampling 2] [--timeout 4s]
                                         — сервер «Лучший сервер»: сам выбирает лучший протокол
                                           (только в клиентах из списка, остальные получают обычные ссылки)
vpn help                                 — эта справка
Подробный гайд: https://github.com/p0sixxx/3x-ui-autodeploy/blob/main/docs/vpn-commands.md
EOF
}

cmd=${1:-help}; shift || true
case "$cmd" in
_probe) probe "$@" ;;
_scan) reality_scan ;;
reality) load_env; do_reality "$@" ;;
sub-domain|subdomain) load_env; do_subdomain "$@" ;;
brand) load_env; do_brand "$@" ;;
xhttp) load_env; do_xhttp "$@" ;;
hop) load_env; do_hop "$@" ;;
fastest) load_env; node_guard; do_fastest "$@" ;;
trace) load_env; do_trace "$@" ;;
http3) load_env; do_http3 "$@" ;;
node) load_env; do_node "$@" ;;
promote) load_env; do_promote "$@" ;;
_role) load_env; if is_node; then echo node; else echo main; fi ;;
_nodes) load_env; if is_node; then echo "[]"; else node_list_json | jq -c '[.[] | {name, address, port}]'; fi ;;
export) load_env; do_export "$@" ;;
import) load_env; do_import "$@" ;;
_hop) hop_rules "${1:-up}" "${2:-20000-50000}" ;;
_country) country_label "${1:-}" ;;
add)
    load_env; node_guard
    parse_limits "$@"; set -- "${REST[@]+"${REST[@]}"}"
    [[ $# -ge 3 ]] || { usage; exit 1; }
    check_name "$1"; is_num "$2" && is_num "$3" || { echo "ГБ и дни — числа"; exit 1; }
    dev=${DEV:-${DEF_DEVICES:-0}}; ips=${IPS:-${DEF_IPS:-0}}
    add_client "$1" "$2" "$3" "${4:-}" "$dev" "$ips" "${SUBID:-}"
    echo "Создан: $1 (трафик: $([[ $2 == 0 ]] && echo без лимита || echo "$2 ГБ"), срок: $([[ $3 == 0 ]] && echo бессрочно || echo "$3 дн."), $(limits_text "$dev" "$ips"))"
    if (( dev > 0 )); then hwid_note; fi
    if (( ips > 0 )); then fail2ban_note; fi
    show_link "$1"
    ;;
limit) load_env; node_guard; do_limit "$@" ;;
devices) load_env; node_guard; do_devices "$@" ;;
list)
    load_env
    r=$(api GET /clients/list); ok "$r"
    tab() { if command -v column >/dev/null; then column -t -s $'\t'; else cat; fi; }
    {
    printf 'ИМЯ\tВКЛ\tИСПОЛЬЗ.\tЛИМИТ\tДО\tУСТР./IP\tКОММЕНТАРИЙ\n'
    jq -r --argjson G $GiB --arg hc "$HC_USER" '.obj[] | select(.email != $hc) | [ .email,
        (if .enable and (.traffic.enable // true) then "да" else "нет" end),
        ((((.traffic.up // 0) + (.traffic.down // 0)) / $G * 100 | floor) / 100 | tostring) + " ГБ",
        (if .totalGB > 0 then ((.totalGB / $G * 100 | floor) / 100 | tostring) + " ГБ" else "∞" end),
        (.expiryTime // 0 | tostring),
        ((if (.limitHwid // 0) > 0 then (.limitHwid | tostring) else "∞" end) + "/" + (if (.limitIp // 0) > 0 then (.limitIp | tostring) else "∞" end)),
        (if (.comment // "") == "" then "-" else .comment end) ] | @tsv' <<<"$r" |
    while IFS=$'\t' read -r n e u t x lm cm; do
        if [[ "$x" == 0 ]]; then d="бессрочно"; elif (( x < 0 )); then d="с_1-го_подкл."; else d=$(date -d "@$((x/1000))" '+%d.%m.%Y_%H:%M'); fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$e" "$u" "$t" "$d" "$lm" "$cm"
    done
    } | tab
    ;;
link) load_env; check_name "${1:-}"; show_link "$1" ;;
renew)
    load_env; node_guard
    [[ $# -ge 2 ]] || { usage; exit 1; }
    check_name "$1"; is_num "$2" || { echo "Дни — число"; exit 1; }
    c=$(get_client "$1"); cur=$(jq -r '.expiryTime // 0' <<<"$c"); base=$(now_ms)
    (( cur > base )) && base=$cur
    if (( ${2%.*} == 0 )); then exp=$cur; else exp=$(( base + ${2%.*} * 86400000 )); fi
    c=$(jq --argjson exp "$exp" '.expiryTime = $exp | .enable = true' <<<"$c")
    if [[ -n "${3:-}" ]]; then is_num "$3" || { echo "ГБ — число"; exit 1; }
        c=$(jq --arg gb "$3" --argjson G $GiB '.totalGB = (($gb|tonumber) * $G | floor)' <<<"$c"); fi
    save_client "$c"
    ok "$(api POST "/clients/resetTraffic/$1")"
    if [[ "$exp" == 0 ]]; then until_s="бессрочно"; else until_s="до $(date -d "@$(( exp / 1000 ))" '+%d.%m.%Y %H:%M')"; fi
    echo "Продлён: $1, ${until_s}, трафик обнулён"
    if (( exp > 0 && exp < $(now_ms) )); then echo "Внимание: срок уже истёк — пользователь не подключится. Продли на N дней: vpn renew $1 30"; fi
    ;;
expire)
    load_env; node_guard
    [[ $# -ge 2 ]] || { usage; exit 1; }
    check_name "$1"; is_num "$2" || { echo "Дни — число (0 — бессрочно)"; exit 1; }
    c=$(get_client "$1")
    if (( ${2%.*} == 0 )); then exp=0; else exp=$(( $(now_ms) + ${2%.*} * 86400000 )); fi
    save_client "$(jq --argjson exp "$exp" '.expiryTime = $exp | .enable = true' <<<"$c")"
    if [[ "$exp" == 0 ]]; then echo "$1: бессрочно (трафик не тронут)"
    else echo "$1: срок до $(date -d "@$(( exp / 1000 ))" '+%d.%m.%Y %H:%M') (трафик не тронут). Клиенты покажут дату после обновления подписки"; fi
    ;;
reset) load_env; node_guard; check_name "${1:-}"; ok "$(api POST "/clients/resetTraffic/$1")"; echo "Трафик $1 обнулён" ;;
off|on)
    load_env; node_guard; check_name "${1:-}"; en=true; [[ $cmd == off ]] && en=false
    save_client "$(jq --argjson en $en '.enable = $en' <<<"$(get_client "$1")")"
    echo "$1: $([[ $en == true ]] && echo включён || echo отключён)"
    ;;
del) load_env; node_guard; check_name "${1:-}"; ok "$(api POST "/clients/del/$1")"; echo "Удалён: $1" ;;
panel) load_env; do_panel "$@" ;;
check) load_env; if [[ "${1:-}" == --local ]]; then do_check no; else do_check yes; fi ;;
*) usage ;;
esac
VPNCLI
    chmod 755 /usr/local/bin/vpn
}

# =========================================================================== итог
setup_self_domain() { # SELF_DOMAIN: Reality на свой домен, при выборе http3 — ещё и сервер HTTP3
    [[ -n "${SELF_DOMAIN:-}" ]] || return 0
    local bad=0
    vpn reality self "$SELF_DOMAIN" 2>&1 | sed 's/^/    /' || bad=1
    if (( bad )); then
        warn "Reality на домен $SELF_DOMAIN не настроился (подробности выше). Повтори позже: vpn reality self $SELF_DOMAIN"
        return 0
    fi
    if (( ${P_H3:-0} )); then
        vpn http3 on 2>&1 | sed 's/^/    /' || warn "HTTP3 не включился. Повтори позже: vpn http3 on"
    fi
}

finish_node() {
    log "Готовлю сервер как ноду и проверяю"
    if [[ "$XHTTP_PORT" != 0 ]]; then vpn xhttp on "$XHTTP_PORT" | sed 's/^/    /'; fi
    if [[ -n "${HOP_PORTS:-}" ]]; then vpn hop on "$HOP_PORTS" | sed 's/^/    /'; fi
    setup_self_domain
    local rc=0
    ( umask 077; vpn node prepare --yes > "$VPN_DIR/node-add.txt" )
    vpn check | tee "$VPN_DIR/check-install.txt" || rc=$?
    echo
    echo -e "${c_b}================ НОДА ГОТОВА ================${c_0}"
    cat "$VPN_DIR/panel.txt"
    cat "$VPN_DIR/node-add.txt"
    echo "Команда сохранена в ${VPN_DIR}/node-add.txt. Свой домен для маскировки: vpn reality self <поддомен>"
    if (( rc != 0 )); then
        echo -e "\n${c_y}Проверка нашла ошибки (см. [FAIL] выше). Исправь и перепроверь: vpn check${c_0}"
    fi
}

finish() {
    if [[ "${NODE:-0}" == 1 ]]; then finish_node; return; fi
    log "Создаю твоего пользователя и проверяю всё целиком"
    if [[ "$XHTTP_PORT" != 0 ]]; then vpn xhttp on "$XHTTP_PORT" | sed 's/^/    /'; fi
    if [[ -n "${HOP_PORTS:-}" ]]; then vpn hop on "$HOP_PORTS" | sed 's/^/    /'; fi
    setup_self_domain
    if [[ "${FASTEST:-1}" != 0 ]]; then
        if (( $(sed -n "s/^INBOUNDS='\(.*\)'/\1/p" "$VPN_DIR/vpn.env" | jq length) >= 2 )); then vpn fastest on | sed 's/^/    /'
        else echo "    «Лучший сервер» не создаю: сервер один (добавится, когда появится второй: vpn fastest on)"; fi
    fi
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
    SERVER_LABEL=$(SERVER_IP="$SERVER_IP" vpn _country 2>/dev/null || echo "Сервер")
    [[ -n "$SERVER_LABEL" ]] || SERVER_LABEL="Сервер"
    ok "Сервер: ${SERVER_LABEL}"
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

if [[ "${VPN_SETUP_LIB:-0}" != 1 ]]; then
    if [[ "${1:-}" == --cli ]]; then   # только обновить утилиту vpn, сервер не трогать
        [[ $EUID -eq 0 ]] || die "Запусти от root"
        install_cli; ok "Утилита vpn обновлена"; exit 0
    fi
    main "$@"
fi
