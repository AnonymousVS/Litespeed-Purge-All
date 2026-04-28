#!/bin/bash
###############################################################################
# litespeed-purge-all.sh
# Version  : 2.2.0
# Location : /usr/local/sbin/litespeed-purge-all.sh
# Usage    : bash /usr/local/sbin/litespeed-purge-all.sh
# ─────────────────────────────────────────────────────────────────────────────
# CHANGELOG:
# v2.2.0 | 2026-04-28 17:30 | ลบ server-config.conf — ตั้งค่า Telegram
#        |                   | ใน script โดยตรง ลบ SERVER_NAME / WP_CLI_PATH
# v2.1.0 | 2026-04-28 17:00 | เพิ่ม interactive menu (All / by cPanel account)
#        |                   | เพิ่ม Telegram notification + spinner
# v2.0.0 | 2026-04-28 16:00 | Rewrite: wp litespeed-purge all + CF notice check
#        |                   | แก้ Bug plugin status / check_cf_configured
# v1.0.0 | 2026-04-28 12:00 | Initial release
###############################################################################

VERSION="2.2.0"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   WHITE='\033[1;37m'
BOLD='\033[1m';      DIM='\033[2m';       RESET='\033[0m'

# ── Telegram (แก้ค่าตรงนี้) ───────────────────────────────────────────────────
TELEGRAM_ENABLED=false
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# ── Log ───────────────────────────────────────────────────────────────────────
LOG_DIR="/var/log/ls-purge-all"
TIMESTAMP=$(TZ='Asia/Bangkok' date '+%Y%m%d_%H%M%S')
LOG_FILE="${LOG_DIR}/purge_${TIMESTAMP}.log"
FAIL_LOG="${LOG_DIR}/purge_FAIL_${TIMESTAMP}.log"

mkdir -p "$LOG_DIR"

# ── Counters ──────────────────────────────────────────────────────────────────
TOTAL=0; SUCCESS=0; CF_FAILED=0; FAILED=0

# ── Global Maps ───────────────────────────────────────────────────────────────
declare -A G_USER_DOMAINS=()   # cpanel_user → comma-separated domain list
declare -A G_DOMAIN_USER=()    # domain → cpanel_user

###############################################################################
# Logging
###############################################################################
log()      { echo -e "$1" | tee -a "$LOG_FILE"; }
log_fail() { echo -e "$1" | tee -a "$LOG_FILE" -a "$FAIL_LOG"; }

log_init() {
    {
        printf "╔══════════════════════════════════════════════════════════╗\n"
        printf "║  LiteSpeed Purge All v%-33s║\n" "${VERSION}"
        printf "╠══════════════════════════════════════════════════════════╣\n"
        printf "║  Server  : %-44s║\n" "$(hostname -s)"
        printf "║  Started : %-44s║\n" "$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')"
        printf "╚══════════════════════════════════════════════════════════╝\n"
        echo ""
    } > "$LOG_FILE"
}

###############################################################################
# Header
###############################################################################
print_header() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BLUE}║  ${WHITE}${BOLD}LiteSpeed Purge All  v${VERSION}${RESET}${BLUE}                              ║${RESET}"
    echo -e "${BLUE}║  ${DIM}Server: $(hostname -s)${RESET}${BLUE}                                         ║${RESET}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

###############################################################################
# Spinner
###############################################################################
spinner_start() {
    local label="$1"
    printf "  ${CYAN}%s${RESET} " "$label"
    (
        local sp='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' si=0
        while true; do
            si=$(( (si+1) % 10 ))
            printf "\r  ${CYAN}%s${RESET} ${YELLOW}%s${RESET}" \
                "$label" "${sp:$si:1}"
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID"
}

spinner_stop() {
    [[ -n "${SPINNER_PID:-}" ]] && kill "$SPINNER_PID" 2>/dev/null
    printf "\r\033[K"  # clear spinner line
    SPINNER_PID=""
}

###############################################################################
# Requirements check
###############################################################################
check_requirements() {
    [[ $EUID -ne 0 ]] && {
        echo -e "${RED}[ERROR]${RESET} กรุณารันด้วย root"; exit 1
    }

    # หา WP-CLI
    WP_CLI=""
    for p in /usr/local/bin/wp /usr/bin/wp /root/bin/wp; do
        [[ -x "$p" ]] && WP_CLI="$p" && break
    done
    [[ -z "$WP_CLI" ]] && WP_CLI=$(command -v wp 2>/dev/null || echo "")
    [[ -z "$WP_CLI" ]] && {
        echo -e "${RED}[ERROR]${RESET} ไม่พบ wp-cli"; exit 1
    }

    for f in /etc/userdomains /etc/trueuserdomains; do
        [[ ! -f "$f" ]] && {
            echo -e "${RED}[ERROR]${RESET} ไม่พบ $f"; exit 1
        }
    done
}

###############################################################################
# Build domain → user map จาก /etc/userdomains
###############################################################################
build_domain_map() {
    G_DOMAIN_USER=()
    G_USER_DOMAINS=()

    while IFS=': ' read -r domain cpuser; do
        [[ -z "$domain" || "$domain" =~ ^# ]] && continue
        [[ "$domain" == "localhost" ]] && continue
        # ข้าม sub-domain ที่ cPanel สร้างเอง
        [[ "$domain" =~ ^(mail|ftp|cpanel|webmail|whm|cpcalendars|cpcontacts)\. ]] \
            && continue

        G_DOMAIN_USER["$domain"]="$cpuser"

        # สร้าง per-user domain list
        if [[ -n "${G_USER_DOMAINS[$cpuser]+x}" ]]; then
            G_USER_DOMAINS["$cpuser"]+=",$domain"
        else
            G_USER_DOMAINS["$cpuser"]="$domain"
        fi
    done < /etc/userdomains
}

###############################################################################
# Get sorted unique cPanel user list
###############################################################################
get_cpanel_users() {
    local -n _out=$1
    _out=()
    local -A _seen=()
    while IFS=': ' read -r domain cpuser; do
        [[ -z "$cpuser" || "$cpuser" =~ ^# ]] && continue
        [[ -z "${_seen[$cpuser]+x}" ]] && _seen["$cpuser"]=1 && _out+=("$cpuser")
    done < /etc/userdomains
    mapfile -t _out < <(printf '%s\n' "${_out[@]}" | sort -u)
}

###############################################################################
# Get WP document root
###############################################################################
get_wp_path() {
    local domain="$1" cpanel_user="$2"
    local docroot home_dir

    docroot=$(whmapi1 --output=jsonpretty domainuserdata \
        domain="$domain" 2>/dev/null \
        | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('data',{}).get('userdata',{}).get('documentroot',''))
" 2>/dev/null)

    if [[ -z "$docroot" || ! -f "${docroot}/wp-config.php" ]]; then
        home_dir=$(getent passwd "$cpanel_user" 2>/dev/null | cut -d: -f6)
        [[ -z "$home_dir" ]] && home_dir="/home/${cpanel_user}"
        [[ -f "${home_dir}/public_html/wp-config.php" ]] \
            && docroot="${home_dir}/public_html"
        [[ -f "${home_dir}/public_html/${domain}/wp-config.php" ]] \
            && docroot="${home_dir}/public_html/${domain}"
    fi
    echo "$docroot"
}

###############################################################################
# Check CF configured in LSCWP
###############################################################################
check_cf_configured() {
    local wp_path="$1" cpanel_user="$2"
    local cf_token=""

    cf_token=$(sudo -u "$cpanel_user" \
        "$WP_CLI" --path="$wp_path" \
        litespeed-option get cdn-cloudflare_token 2>/dev/null \
        | grep -v "^Error:" | grep -v "^Warning:" \
        | tr -d '[:space:]')

    if [[ -z "$cf_token" || "$cf_token" == "0" ]]; then
        cf_token=$(sudo -u "$cpanel_user" \
            "$WP_CLI" --path="$wp_path" eval \
            'echo isset(get_option("litespeed.conf")["cdn-cloudflare_token"])
               ? get_option("litespeed.conf")["cdn-cloudflare_token"]
               : "";' 2>/dev/null \
            | grep -v "^Error:" | grep -v "^Warning:" \
            | tr -d '[:space:]')
    fi

    [[ -n "$cf_token" && "$cf_token" != "0" ]] && echo "1" || echo "0"
}

###############################################################################
# Read LiteSpeed admin notices from DB (หลัง purge)
###############################################################################
read_ls_notices() {
    local wp_path="$1" cpanel_user="$2"

    sudo -u "$cpanel_user" \
        "$WP_CLI" --path="$wp_path" eval '
$keys = [
    "litespeed_messages",
    "litespeed.notices",
    "litespeed_admin_display",
];
$all = [];
foreach ( $keys as $k ) {
    $val = get_option( $k );
    if ( empty($val) ) continue;
    if ( is_array($val) ) {
        foreach ( $val as $level => $msgs ) {
            foreach ( (array)$msgs as $m ) {
                $clean = trim( strip_tags($m) );
                if ( $clean ) $all[] = strtoupper($level) . ": " . $clean;
            }
        }
    } elseif ( is_string($val) && $val !== "" ) {
        $all[] = trim( strip_tags($val) );
    }
    delete_option( $k );
}
if ( class_exists("LiteSpeed\Admin_Display") ) {
    try {
        $cls = LiteSpeed\Admin_Display::cls();
        if ( method_exists($cls, "get_notice_arr") ) {
            foreach ( (array)$cls->get_notice_arr() as $level => $msgs ) {
                foreach ( (array)$msgs as $m ) {
                    $clean = trim( strip_tags($m) );
                    if ( $clean ) $all[] = strtoupper($level) . ": " . $clean;
                }
            }
        }
    } catch ( Exception $e ) {}
}
echo empty($all) ? "NOTICES_EMPTY\n" : implode("\n", array_unique($all)) . "\n";
' 2>/dev/null
}

###############################################################################
# Core: purge one domain
###############################################################################
purge_domain() {
    local domain="$1" cpanel_user="$2"

    ((TOTAL++))
    log ""
    log "${CYAN}────────────────────────────────────────────────${RESET}"
    log "${BOLD}[${TOTAL}] ${domain}${RESET}"
    log "     User : ${cpanel_user}"
    log "     Time : $(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')"

    # ── Validate ──────────────────────────────────
    if [[ -z "$cpanel_user" ]]; then
        log_fail "${RED}  [ERROR] ไม่พบ cPanel user: ${domain}${RESET}"
        ((FAILED++)); return
    fi
    if ! id "$cpanel_user" &>/dev/null; then
        log_fail "${RED}  [ERROR] ไม่พบ system user: ${cpanel_user}${RESET}"
        ((FAILED++)); return
    fi

    local wp_path
    wp_path=$(get_wp_path "$domain" "$cpanel_user")
    if [[ -z "$wp_path" || ! -f "${wp_path}/wp-config.php" ]]; then
        log_fail "${RED}  [ERROR] ไม่พบ wp-config.php: '${wp_path}'${RESET}"
        ((FAILED++)); return
    fi
    log "     Path : ${wp_path}"

    # ── Plugin active check ──────────────────────
    # ใช้ "Status: active" ไม่ใช่ "active" เพราะ "Inactive" ก็มี substring "active"
    if ! sudo -u "$cpanel_user" \
        "$WP_CLI" --path="$wp_path" \
        plugin status litespeed-cache 2>&1 | grep -qi "Status: active"; then
        log_fail "${YELLOW}  [WARN] LiteSpeed Cache plugin ไม่ได้ active${RESET}"
        ((FAILED++)); return
    fi

    # ── CF configured? ───────────────────────────
    local cf_configured
    cf_configured=$(check_cf_configured "$wp_path" "$cpanel_user")
    log "     CF   : $([ "$cf_configured" = "1" ] \
        && echo "Configured" || echo "Not configured")"

    # ════════════════════════════════════════════
    # STEP 1: wp litespeed-purge all
    # exit 0 + "Success:" = OK | exit 1 + "Error:" = FAIL
    # ════════════════════════════════════════════
    local purge_output purge_exit
    purge_output=$(sudo -u "$cpanel_user" \
        "$WP_CLI" --path="$wp_path" --url="https://${domain}" \
        litespeed-purge all 2>&1)
    purge_exit=$?

    log "     Exit   : ${purge_exit}"
    log "     Output : ${purge_output}"

    if [[ $purge_exit -eq 0 ]] && echo "$purge_output" | grep -qi "^Success:"; then
        log "     ${GREEN}[✓] LiteSpeed Purge — SUCCESS${RESET}"
    else
        local err_detail
        err_detail=$(echo "$purge_output" | grep -i "^Error:" | head -1)
        log_fail "     ${RED}[✗] LiteSpeed Purge — FAILED${RESET}"
        log_fail "     ${RED}    exit=${purge_exit} | ${err_detail:-ไม่มี Success: ใน output}${RESET}"
        ((FAILED++))
        return
    fi

    # ════════════════════════════════════════════
    # STEP 2: CF notices from DB (เฉพาะถ้า CF configured)
    # ════════════════════════════════════════════
    if [[ "$cf_configured" == "0" ]]; then
        log "     ${GREEN}${BOLD}→ RESULT: SUCCESS${RESET}"
        ((SUCCESS++))
        return
    fi

    local notices
    notices=$(read_ls_notices "$wp_path" "$cpanel_user")

    local cf_comm_ok=0 cf_purge_ok=0 cf_error_msg=""

    echo "$notices" | grep -qi "Communicated with Cloudflare successfully" \
        && cf_comm_ok=1
    echo "$notices" | grep -qi "Notified Cloudflare to purge all successfully" \
        && cf_purge_ok=1
    cf_error_msg=$(echo "$notices" \
        | grep -i "cloudflare" \
        | grep -i "ERROR:\|fail\|invalid\|unauthorized\|forbidden\|timeout" \
        | head -1)

    if [[ $cf_comm_ok -eq 1 && $cf_purge_ok -eq 1 ]]; then
        log "     ${GREEN}[✓] Communicated with Cloudflare successfully.${RESET}"
        log "     ${GREEN}[✓] Notified Cloudflare to purge all successfully.${RESET}"
        log "     ${GREEN}${BOLD}→ RESULT: SUCCESS (CF confirmed)${RESET}"
        ((SUCCESS++))

    elif [[ $cf_comm_ok -eq 1 && $cf_purge_ok -eq 0 ]]; then
        log_fail "     ${GREEN}[✓] Communicated with Cloudflare successfully.${RESET}"
        log_fail "     ${RED}[✗] Notified Cloudflare to purge all — FAILED${RESET}"
        [[ -n "$cf_error_msg" ]] && log_fail "     ${RED}    ${cf_error_msg}${RESET}"
        log_fail "     ${RED}${BOLD}→ RESULT: CF PURGE FAILED${RESET}"
        ((CF_FAILED++))

    elif [[ $cf_comm_ok -eq 0 && -n "$cf_error_msg" ]]; then
        log_fail "     ${RED}[✗] Communicated with Cloudflare — FAILED${RESET}"
        log_fail "     ${RED}    ${cf_error_msg}${RESET}"
        log_fail "     ${RED}${BOLD}→ RESULT: CF CONNECTION FAILED${RESET}"
        ((CF_FAILED++))

    else
        log_fail "     ${YELLOW}[?] CF configured แต่ไม่มี Cloudflare notices ใน DB${RESET}"
        log_fail "     ${YELLOW}    สาเหตุที่เป็นไปได้:${RESET}"
        log_fail "     ${YELLOW}    - CF API token หมดอายุ / ไม่มีสิทธิ์ Cache Purge${RESET}"
        log_fail "     ${YELLOW}    - LiteSpeed CF integration ปิดอยู่ใน plugin settings${RESET}"
        log_fail "     ${YELLOW}    - Notices ถูก clear ก่อน script อ่านได้${RESET}"
        log_fail "     ${YELLOW}${BOLD}→ RESULT: CF UNCONFIRMED${RESET}"
        ((CF_FAILED++))
    fi
}

###############################################################################
# Process: ทุก domain บน server
###############################################################################
process_all_server() {
    log "Mode : All domains on server"
    local count=0
    for domain in "${!G_DOMAIN_USER[@]}"; do
        count=$(( count + 1 ))
    done

    local i=0
    for domain in $(echo "${!G_DOMAIN_USER[@]}" | tr ' ' '\n' | sort); do
        local cpuser="${G_DOMAIN_USER[$domain]}"
        ((i++))
        spinner_start "[${i}/${count}] ${domain}"
        purge_domain "$domain" "$cpuser" 2>/dev/null
        spinner_stop
        # แสดงผลสรุปของ domain นี้
        local result_line
        result_line=$(grep "→ RESULT:" "$LOG_FILE" 2>/dev/null | tail -1)
        if echo "$result_line" | grep -q "SUCCESS"; then
            echo -e "  ${GREEN}[✓]${RESET} ${domain}"
        elif echo "$result_line" | grep -q "FAILED\|UNCONFIRMED"; then
            echo -e "  ${RED}[✗]${RESET} ${domain}  ${DIM}${result_line##*RESULT: }${RESET}"
        else
            echo -e "  ${YELLOW}[?]${RESET} ${domain}"
        fi
    done
}

###############################################################################
# Process: เฉพาะ cPanel account ที่เลือก
###############################################################################
process_by_account() {
    local selected_user="$1"
    local domains_str="${G_USER_DOMAINS[$selected_user]:-}"

    if [[ -z "$domains_str" ]]; then
        echo -e "${RED}[ERROR] ไม่พบ domain สำหรับ user: ${selected_user}${RESET}"
        return
    fi

    log "Mode : Account → ${selected_user}"
    IFS=',' read -ra domain_list <<< "$domains_str"
    local count="${#domain_list[@]}"
    local i=0

    for domain in $(printf '%s\n' "${domain_list[@]}" | sort); do
        ((i++))
        spinner_start "[${i}/${count}] ${domain}"
        purge_domain "$domain" "$selected_user" 2>/dev/null
        spinner_stop
        local result_line
        result_line=$(grep "→ RESULT:" "$LOG_FILE" 2>/dev/null | tail -1)
        if echo "$result_line" | grep -q "SUCCESS"; then
            echo -e "  ${GREEN}[✓]${RESET} ${domain}"
        elif echo "$result_line" | grep -q "FAILED\|UNCONFIRMED"; then
            echo -e "  ${RED}[✗]${RESET} ${domain}  ${DIM}${result_line##*RESULT: }${RESET}"
        else
            echo -e "  ${YELLOW}[?]${RESET} ${domain}"
        fi
    done
}

###############################################################################
# Telegram Notification
###############################################################################
send_telegram() {
    [[ "$TELEGRAM_ENABLED" != "true" ]] && return
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return

    local end_time
    end_time=$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')
    local status_icon="✅"
    [[ $FAILED -gt 0 || $CF_FAILED -gt 0 ]] && status_icon="⚠️"
    [[ $FAILED -eq $TOTAL ]] && status_icon="❌"

    local msg
    msg=$(cat <<EOF
${status_icon} <b>LiteSpeed Purge All</b>
🖥 Server: <code>$(hostname -s)</code>
🕐 เสร็จ: ${end_time}

📊 ผลลัพธ์:
├ Total   : ${TOTAL}
├ ✅ Success  : ${SUCCESS}
├ ⚠️ CF issue : ${CF_FAILED}
└ ❌ Failed   : ${FAILED}

📄 Log: <code>${LOG_FILE}</code>
EOF
)

    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="${msg}" \
        > /dev/null 2>&1
}

###############################################################################
# Summary
###############################################################################
print_summary() {
    local end_time
    end_time=$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')

    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════${RESET}"
    echo -e "${WHITE}${BOLD}  LiteSpeed Purge All — SUMMARY${RESET}"
    echo -e "${BLUE}────────────────────────────────────────────────${RESET}"
    printf "  %-22s : %s\n" "Total processed"    "${TOTAL}"
    printf "  %-22s : ${GREEN}%s${RESET}\n" "✓ SUCCESS"       "${SUCCESS}"
    printf "  %-22s : ${YELLOW}%s${RESET}\n" "△ CF issue (LS OK)" "${CF_FAILED}"
    printf "  %-22s : ${RED}%s${RESET}\n" "✗ FAILED (LS fail)" "${FAILED}"
    echo -e "${BLUE}────────────────────────────────────────────────${RESET}"
    echo -e "  Log  : ${DIM}${LOG_FILE}${RESET}"
    [[ $CF_FAILED -gt 0 || $FAILED -gt 0 ]] && \
        echo -e "  Fail : ${RED}${FAIL_LOG}${RESET}"
    echo -e "${BLUE}════════════════════════════════════════════════${RESET}"

    # เขียน summary ลง log
    {
        echo ""
        echo "════════════════════════════════════════════════"
        echo "  SUMMARY — Finished: ${end_time}"
        echo "────────────────────────────────────────────────"
        echo "  Total     : ${TOTAL}"
        echo "  SUCCESS   : ${SUCCESS}"
        echo "  CF issue  : ${CF_FAILED}"
        echo "  FAILED    : ${FAILED}"
        echo "════════════════════════════════════════════════"
    } >> "$LOG_FILE"
}

###############################################################################
# Menu: เลือก cPanel account
###############################################################################
menu_select_account() {
    local -a users=()
    get_cpanel_users users

    if [[ ${#users[@]} -eq 0 ]]; then
        echo -e "${RED}[ERROR] ไม่พบ cPanel user ในระบบ${RESET}"
        exit 1
    fi

    echo ""
    echo -e "${WHITE}${BOLD}  เลือก cPanel Account:${RESET}"
    echo -e "${BLUE}  ─────────────────────────────────────────────${RESET}"

    local i=1
    for u in "${users[@]}"; do
        local dom_count=0
        if [[ -n "${G_USER_DOMAINS[$u]+x}" ]]; then
            IFS=',' read -ra _tmp <<< "${G_USER_DOMAINS[$u]}"
            dom_count="${#_tmp[@]}"
        fi
        printf "  ${CYAN}[%2d]${RESET}  %-20s  ${DIM}%d domain(s)${RESET}\n" \
            "$i" "$u" "$dom_count"
        ((i++))
    done

    echo -e "${BLUE}  ─────────────────────────────────────────────${RESET}"
    echo ""
    while true; do
        read -rp "  เลือกหมายเลข [1-${#users[@]}] หรือ [0] กลับ: " choice
        if [[ "$choice" == "0" ]]; then
            return 1   # กลับ menu หลัก
        elif [[ "$choice" =~ ^[0-9]+$ ]] && \
             (( choice >= 1 && choice <= ${#users[@]} )); then
            SELECTED_USER="${users[$((choice-1))]}"
            return 0
        else
            echo -e "  ${RED}ตัวเลือกไม่ถูกต้อง กรุณาลองใหม่${RESET}"
        fi
    done
}

###############################################################################
# Main Menu
###############################################################################
main_menu() {
    while true; do
        print_header

        echo -e "  ${WHITE}${BOLD}เลือกโหมด Purge:${RESET}"
        echo ""
        echo -e "  ${CYAN}[1]${RESET}  Purge ทุก Domain บนเซิร์ฟเวอร์"
        echo -e "  ${CYAN}[2]${RESET}  Purge เฉพาะ cPanel Account ที่เลือก"
        echo ""
        echo -e "  ${DIM}[0]  ออก${RESET}"
        echo ""
        echo -e "${BLUE}  ─────────────────────────────────────────────${RESET}"
        echo ""

        read -rp "  กรุณาเลือก [0-2]: " mode

        case "$mode" in
            1)
                echo ""
                echo -e "  ${YELLOW}${BOLD}[Mode 1] Purge ทุก Domain บนเซิร์ฟเวอร์${RESET}"
                echo -e "  ${DIM}จำนวน domain ที่จะ purge: ${#G_DOMAIN_USER[@]}${RESET}"
                echo ""
                read -rp "  ยืนยัน? [y/N]: " confirm
                [[ ! "$confirm" =~ ^[Yy]$ ]] && continue
                echo ""
                log_init
                process_all_server
                print_summary
                send_telegram
                echo ""
                read -rp "  กด Enter เพื่อกลับ menu..." _
                ;;

            2)
                echo ""
                echo -e "  ${YELLOW}${BOLD}[Mode 2] Purge เฉพาะ cPanel Account${RESET}"
                SELECTED_USER=""
                if menu_select_account; then
                    echo ""
                    echo -e "  ${YELLOW}User: ${BOLD}${SELECTED_USER}${RESET}"
                    local dom_count=0
                    if [[ -n "${G_USER_DOMAINS[$SELECTED_USER]+x}" ]]; then
                        IFS=',' read -ra _tmp <<< "${G_USER_DOMAINS[$SELECTED_USER]}"
                        dom_count="${#_tmp[@]}"
                    fi
                    echo -e "  ${DIM}จำนวน domain: ${dom_count}${RESET}"
                    echo ""
                    read -rp "  ยืนยัน? [y/N]: " confirm2
                    [[ ! "$confirm2" =~ ^[Yy]$ ]] && continue
                    echo ""
                    log_init
                    process_by_account "$SELECTED_USER"
                    print_summary
                    send_telegram
                    echo ""
                    read -rp "  กด Enter เพื่อกลับ menu..." _
                fi
                ;;

            0)
                echo ""
                echo -e "  ${DIM}ออกจากโปรแกรม${RESET}"
                echo ""
                exit 0
                ;;

            *)
                echo -e "  ${RED}ตัวเลือกไม่ถูกต้อง${RESET}"
                sleep 1
                ;;
        esac
    done
}

###############################################################################
# MAIN
###############################################################################
main() {
    check_requirements
    build_domain_map

    main_menu
}

main "$@"
