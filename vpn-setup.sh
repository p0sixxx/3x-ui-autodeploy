#!/usr/bin/env bash
# vpn-setup.sh — небольшой VPN-сервис на 3x-ui: VLESS+Reality (TCP/443) и Hysteria2 (UDP/443),
# подписки, лимиты трафика и сроки на пользователя, утилита `vpn` для управления.
# Проверено с 3x-ui v3.9.0 (Xray 26.9.30). Целевая ОС: Ubuntu 24.04, чистый сервер.
#
# Запуск:  bash <(curl -fsSL https://raw.githubusercontent.com/p0sixxx/3x-ui-autodeploy/main/vpn-setup.sh)
#      или: bash vpn-setup.sh
# Опции (переменные окружения, все необязательные):
#   DOMAIN=vpn.example.com   — домен, A-запись которого уже смотрит на сервер (иначе сертификат на IP)
#   REALITY_TARGET=host:443  — свой сайт-маскировка для Reality (иначе выбирается автоматически)
#   PANEL_PORT, SUB_PORT     — порты панели и подписок (иначе случайные)
#   TG_BOT_TOKEN, TG_ADMIN_ID — включить Telegram-бота 3x-ui (уведомления, управление)
#   ACME_EMAIL               — e-mail для Let's Encrypt
#   NO_FIREWALL=1            — не трогать ufw
#   XUI_VERSION=v3.9.0       — версия 3x-ui

set -Eeuo pipefail
trap 'echo -e "\n\033[0;31m[ОШИБКА] строка $LINENO: $BASH_COMMAND\033[0m" >&2' ERR

XUI_VERSION="${XUI_VERSION:-v3.9.0}"
REALITY_CANDIDATES="www.samsung.com:443,www.nvidia.com:443,www.amd.com:443,www.intel.com:443,www.sony.com:443,dl.google.com:443,aws.amazon.com:443,www.cloudflare.com:443"
VPN_DIR=/etc/vpn
XUI_BIN=/usr/local/x-ui/x-ui

c_g='\033[0;32m'; c_y='\033[0;33m'; c_r='\033[0;31m'; c_b='\033[1m'; c_0='\033[0m'
log()  { echo -e "${c_g}==>${c_0} $*"; }
warn() { echo -e "${c_y}[!]${c_0} $*"; }
die()  { echo -e "${c_r}[x]${c_0} $*" >&2; exit 1; }
rnd()  { openssl rand -hex 32 | tr -dc 'a-z0-9' | head -c "$1"; }

port_busy() { # port_busy <port> <tcp|udp>
    local flag=-ltn; [[ "$2" == udp ]] && flag=-lun
    [[ -n "$(ss -H "$flag" "sport = :$1" 2>/dev/null)" ]]
}
free_port() {
    local p
    while :; do p=$(shuf -i 20000-60000 -n 1); port_busy "$p" tcp || { echo "$p"; return; }; done
}

# --------------------------------------------------------------------------- проверки
preflight() {
    [[ $EUID -eq 0 ]] || die "Запусти от root (sudo -i)"
    . /etc/os-release
    [[ "$ID" == ubuntu || "$ID" == debian ]] || die "Скрипт рассчитан на Ubuntu/Debian (у тебя: $ID)"
    [[ "$ID" == ubuntu && "${VERSION_ID}" != "24.04" ]] && warn "Проверено на Ubuntu 24.04, у тебя ${VERSION_ID} — продолжаю."
    case "$(uname -m)" in x86_64|aarch64) ;; *) die "Неподдерживаемая архитектура $(uname -m)";; esac
    [[ -e /usr/local/x-ui ]] && die "3x-ui уже установлен (/usr/local/x-ui). Скрипт рассчитан на чистый сервер — не буду ломать существующую настройку."

    local busy=""
    port_busy 443 tcp && busy+=" 443/tcp"
    port_busy 443 udp && busy+=" 443/udp"
    port_busy 80 tcp  && busy+=" 80/tcp"
    if [[ -n "$busy" ]]; then
        ss -ltnup 2>/dev/null | grep -E ':(80|443)\s' >&2 || true
        die "Заняты порты:${busy}. Они нужны для Reality, Hysteria2 и выпуска сертификата."
    fi
    if [[ -n "${DOMAIN:-}" && ! "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; then
        die "DOMAIN='$DOMAIN' не похож на домен"
    fi
}

# --------------------------------------------------------------------------- система
prepare_system() {
    log "Пакеты"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl jq openssl ca-certificates cron socat ufw qrencode iproute2 bsdextrautils >/dev/null

    if ! swapon --show | grep -q .; then
        log "Swap 1 ГБ (на 2 ГБ RAM лишним не будет)"
        fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
        grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    log "BBR и буферы UDP для QUIC"
    cat > /etc/sysctl.d/99-vpn.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
vm.swappiness = 10
EOF
    sysctl -q --system >/dev/null || true
}

detect_ip() {
    local u ip
    for u in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me https://check-host.net/ip; do
        ip=$(curl -4 -fs --max-time 5 "$u" | tr -d '[:space:]"') || continue
        [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && { echo "$ip"; return; }
    done
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

# --------------------------------------------------------------------------- 3x-ui
install_xui() {
    log "Устанавливаю 3x-ui ${XUI_VERSION}"
    local inst; inst=$(mktemp)
    curl -fsSL "https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_VERSION}/install.sh" -o "$inst"
    local ssl_mode=ip; [[ -n "${DOMAIN:-}" ]] && ssl_mode=domain
    XUI_NONINTERACTIVE=1 XUI_SSL_MODE="$ssl_mode" XUI_DOMAIN="${DOMAIN:-}" \
    XUI_SERVER_IP="$SERVER_IP" XUI_PANEL_PORT="$PANEL_PORT" XUI_WEB_BASE_PATH="$WEB_PATH" \
    XUI_USERNAME="$ADMIN_USER" XUI_PASSWORD="$ADMIN_PASS" XUI_ACME_EMAIL="${ACME_EMAIL:-}" \
        bash "$inst" "$XUI_VERSION" </dev/null || die "Установщик 3x-ui завершился с ошибкой"
    rm -f "$inst"
    [[ -x "$XUI_BIN" ]] || die "3x-ui не установился"
}

setup_certs() {
    if [[ -n "${DOMAIN:-}" ]]; then
        CERT="/root/cert/${DOMAIN}/fullchain.pem"; KEY="/root/cert/${DOMAIN}/privkey.pem"
    else
        CERT=/root/cert/ip/fullchain.pem; KEY=/root/cert/ip/privkey.pem
    fi
    if [[ -s "$CERT" && -s "$KEY" ]]; then
        CERT_MODE=letsencrypt
        log "Сертификат Let's Encrypt получен (автопродление через acme.sh)"
        return
    fi
    warn "Let's Encrypt не выдал сертификат (порт 80 закрыт у хостера?). Ставлю самоподписанный."
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
    jq -e '.success == true' >/dev/null <<<"$2" || die "$1: $(jq -r '.msg // .' <<<"$2" 2>/dev/null || echo "$2")"
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
    die "Панель 3x-ui не отвечает по API (journalctl -u x-ui)"
}

# --------------------------------------------------------------------------- Reality
pick_reality_target() {
    if [[ -n "${REALITY_TARGET:-}" ]]; then
        [[ "$REALITY_TARGET" == *:* ]] || REALITY_TARGET="${REALITY_TARGET}:443"
        R_HOST="${REALITY_TARGET%%:*}"
        log "Reality: target задан вручную — ${REALITY_TARGET}"
        return
    fi
    log "Reality: подбираю сайт-маскировку (TLS 1.3 + h2 + X25519) с этого сервера"
    local res
    res=$(api POST /server/scanRealityTargets --data-urlencode "targets=${REALITY_CANDIDATES}")
    R_HOST=$(jq -r '[.obj[]? | select(.feasible == true)][0].host // empty' <<<"$res")
    if [[ -z "$R_HOST" ]]; then
        warn "Ни один кандидат не прошёл проверку, беру www.samsung.com"
        R_HOST=www.samsung.com
    fi
    REALITY_TARGET="${R_HOST}:443"
    log "Reality: ${REALITY_TARGET}"
}

# --------------------------------------------------------------------------- inbounds
create_inbounds() {
    local keys priv pub sid1 sid2 res
    keys=$(api GET /server/getNewX25519Cert); must "x25519" "$keys"
    priv=$(jq -r .obj.privateKey <<<"$keys"); pub=$(jq -r .obj.publicKey <<<"$keys")
    sid1=$(openssl rand -hex 8); sid2=$(openssl rand -hex 4)

    log "Inbound VLESS + Reality + Vision на TCP/443"
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

    log "Inbound Hysteria2 на UDP/443"
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
}

configure_panel() {
    log "Подписки и прочие настройки панели"
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

    if [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_ADMIN_ID:-}" ]]; then
        log "Telegram-бот 3x-ui"
        "$XUI_BIN" setting -tgbottoken "$TG_BOT_TOKEN" -tgbotchatid "$TG_ADMIN_ID" -enabletgbot >/dev/null
    fi
    systemctl restart x-ui
    sleep 2
    wait_api
}

# --------------------------------------------------------------------------- утилита vpn
install_cli() {
    install -d -m 700 "$VPN_DIR"
    umask 077
    cat > "$VPN_DIR/vpn.env" <<EOF
API='${API}'
TOKEN='${TOKEN}'
INBOUNDS='[${IB_VLESS},${IB_HY2}]'
SUB_BASE='${SUB_BASE}'
EOF
    umask 022
    cat > /usr/local/bin/vpn <<'VPNCLI'
#!/usr/bin/env bash
# vpn — управление пользователями VPN (3x-ui). Конфиг: /etc/vpn/vpn.env
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Нужен root"; exit 1; }
. /etc/vpn/vpn.env
GiB=1073741824

api() { local m=$1 p=$2; shift 2; curl -sk --max-time 30 -X "$m" -H "Authorization: Bearer $TOKEN" "$API$p" "$@"; }
api_json() { api "$1" "$2" -H 'Content-Type: application/json' --data-binary "$3"; }
ok() {
    local r=$1
    [[ -n "$r" ]] || { echo "Ошибка: панель не ответила или токен в /etc/vpn/vpn.env недействителен" >&2; exit 1; }
    jq -e '.success == true' >/dev/null <<<"$r" 2>/dev/null || { echo "Ошибка: $(jq -r '.msg // .' <<<"$r" 2>/dev/null || echo "$r")" >&2; exit 1; }
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

save_client() { # save_client <client-json> — полное обновление (update заменяет запись целиком)
    local c=$1 name; name=$(jq -r .email <<<"$c")
    ok "$(api_json POST "/clients/update/$name" "$(jq -c '{email, id: .uuid, auth, subId, flow, limitIp, limitHwid,
        tgId, comment, reset, enable, totalGB, expiryTime}' <<<"$c")")"
}

usage() {
    cat <<EOF
vpn add <имя> <ГБ> <дней> [комментарий]  — новый пользователь (0 = без лимита)
vpn list                                 — все пользователи, трафик, сроки
vpn link <имя>                           — ссылка подписки + QR
vpn renew <имя> <дней> [ГБ]              — продлить и обнулить трафик (ГБ — новый лимит)
vpn reset <имя>                          — обнулить трафик
vpn off|on <имя>                         — отключить / включить
vpn del <имя>                            — удалить
vpn panel                                — адрес и логин панели
EOF
}

cmd=${1:-help}; shift || true
case "$cmd" in
add)
    [[ $# -ge 3 ]] || { usage; exit 1; }
    check_name "$1"; is_num "$2" && is_num "$3" || { echo "ГБ и дни — числа"; exit 1; }
    exp=0; [[ "$3" != 0 ]] && exp=$(( $(now_ms) + ${3%.*} * 86400000 ))
    body=$(jq -n --arg e "$1" --arg sub "$(openssl rand -hex 8)" --arg gb "$2" --argjson exp "$exp" \
        --arg cm "${4:-}" --argjson ib "$INBOUNDS" --argjson G $GiB \
        '{client: {email: $e, subId: $sub, flow: "xtls-rprx-vision", totalGB: (($gb|tonumber) * $G | floor),
          expiryTime: $exp, limitIp: 0, limitHwid: 0, tgId: 0, comment: $cm, enable: true}, inboundIds: $ib}')
    ok "$(api_json POST /clients/add "$body")"
    echo "Создан: $1 (лимит: $([[ $2 == 0 ]] && echo без лимита || echo "$2 ГБ"), срок: $([[ $3 == 0 ]] && echo бессрочно || echo "$3 дн."))"
    show_link "$1"
    ;;
list)
    r=$(api GET /clients/list); ok "$r"
    tab() { if command -v column >/dev/null; then column -t -s $'\t'; else cat; fi; }
    {
    printf 'ИМЯ\tВКЛ\tИСПОЛЬЗ.\tЛИМИТ\tДО\tКОММЕНТАРИЙ\n'
    jq -r --argjson G $GiB '.obj[] | [ .email, (if .enable and (.traffic.enable // true) then "да" else "нет" end),
        ((((.traffic.up // 0) + (.traffic.down // 0)) / $G * 100 | floor) / 100 | tostring) + " ГБ",
        (if .totalGB > 0 then ((.totalGB / $G * 100 | floor) / 100 | tostring) + " ГБ" else "∞" end),
        (.expiryTime // 0 | tostring), (if (.comment // "") == "" then "-" else .comment end) ] | @tsv' <<<"$r" |
    while IFS=$'\t' read -r n e u t x cm; do
        if [[ "$x" == 0 ]]; then d="бессрочно"; elif (( x < 0 )); then d="с_1-го_подкл."; else d=$(date -d "@$((x/1000))" '+%d.%m.%Y_%H:%M'); fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$e" "$u" "$t" "$d" "$cm"
    done
    } | tab
    ;;
link) check_name "${1:-}"; show_link "$1" ;;
renew)
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
reset) check_name "${1:-}"; ok "$(api POST "/clients/resetTraffic/$1")"; echo "Трафик $1 обнулён" ;;
off|on)
    check_name "${1:-}"; en=true; [[ $cmd == off ]] && en=false
    save_client "$(jq --argjson en $en '.enable = $en' <<<"$(get_client "$1")")"
    echo "$1: $([[ $en == true ]] && echo включён || echo отключён)"
    ;;
del) check_name "${1:-}"; ok "$(api POST "/clients/del/$1")"; echo "Удалён: $1" ;;
panel) cat /etc/vpn/panel.txt ;;
*) usage ;;
esac
VPNCLI
    chmod 755 /usr/local/bin/vpn
}

# --------------------------------------------------------------------------- фаервол
setup_firewall() {
    [[ "${NO_FIREWALL:-0}" == 1 ]] && { warn "ufw пропущен (NO_FIREWALL=1)"; return; }
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
    log "ufw: открыты ssh(${ssh_ports//$'\n'/,}), 80, 443/tcp, 443/udp, ${PANEL_PORT}, ${SUB_PORT}"
}

# --------------------------------------------------------------------------- итог
finish() {
    local panel_url="${PANEL_SCHEME}://${PUBLIC_HOST}:${PANEL_PORT}/${WEB_PATH}/"
    cat > "$VPN_DIR/panel.txt" <<EOF
Панель:  ${panel_url}
Логин:   ${ADMIN_USER}
Пароль:  ${ADMIN_PASS}
EOF
    chmod 600 "$VPN_DIR/panel.txt"

    vpn add me 0 0 "владелец" >/dev/null
    echo
    echo -e "${c_b}================ ГОТОВО ================${c_0}"
    cat "$VPN_DIR/panel.txt"
    echo "Reality target: ${REALITY_TARGET}"
    echo "Сертификат:     ${CERT_MODE}"
    [[ "$CERT_MODE" == selfsigned ]] && warn "Let's Encrypt не сработал: панель с самоподписанным сертификатом (браузер ругнётся), подписка по http. Hysteria2 использует pinSHA256."
    echo
    echo "Твоя личная подписка (пользователь 'me', без лимитов):"
    vpn link me
    echo "Управление: vpn add vasya 50 30   |   vpn list   |   vpn renew vasya 30   |   vpn help"
    echo "Данные панели сохранены в ${VPN_DIR}/panel.txt (видит только root)."
}

main() {
    preflight
    prepare_system
    SERVER_IP=$(detect_ip); [[ -n "$SERVER_IP" ]] || die "Не удалось определить публичный IPv4"
    PUBLIC_HOST="${DOMAIN:-$SERVER_IP}"
    PANEL_PORT="${PANEL_PORT:-$(free_port)}"
    SUB_PORT="${SUB_PORT:-$(free_port)}"
    [[ "$SUB_PORT" == "$PANEL_PORT" ]] && SUB_PORT=$(free_port)
    WEB_PATH=$(rnd 16); ADMIN_USER="admin$(rnd 4)"; ADMIN_PASS=$(rnd 20)
    log "IP: ${SERVER_IP}${DOMAIN:+, домен: $DOMAIN}; панель :${PANEL_PORT}, подписки :${SUB_PORT}"

    install_xui
    setup_certs
    connect_api
    pick_reality_target
    create_inbounds
    configure_panel
    install_cli
    setup_firewall
    finish
}

[[ "${VPN_SETUP_LIB:-0}" == 1 ]] || main "$@"
