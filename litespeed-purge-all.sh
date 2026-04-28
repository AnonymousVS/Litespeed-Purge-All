#!/bin/bash
###############################################################################
# litespeed-purge-all.sh
# LiteSpeed Cache Purge All — across cPanel accounts
# Version : 2.5.0
# Location: /usr/local/sbin/litespeed-purge-all.sh
# Usage   : bash /usr/local/sbin/litespeed-purge-all.sh
# ─────────────────────────────────────────────────────────────────────────────
# CHANGELOG:
#   v2.5.1 | 2026-04-29 11:00 | Fix: LAST_RESULT ไม่กลับจาก subshell
#           |                  | do_purge echo "PURGE_RESULT:" ออก stdout
#           |                  | run_with_spinner parse กลับมาตั้ง LAST_RESULT
#           |                  | แก้ [FAIL] log แสดงสาเหตุว่างเปล่า
#   v2.5.0 | 2026-04-29 10:00 | เขียนใหม่ตาม wp-bulk-permalink-flush.sh pattern
#           |                  | Menu แบบ read-once (mode 1 / mode 2)
#           |                  | Mode 2 เลือก multiple cPanel (space/comma)
#           |                  | run_with_spinner [N/TOTAL] label ✔/✖/⊘
#           |                  | แยก section Addon + Parked/Alias
#           |                  | Summary box
#   v2.4.0 | 2026-04-29 09:00 | build_domain_map ครบ + 2 path + Parked/Alias
#   v2.3.0 | 2026-04-29 08:00 | CF detection exact strings จาก source
#   v2.0.0 | 2026-04-28 16:00 | Rewrite: wp litespeed-purge all
###############################################################################

VERSION="2.5.1"

# ── Telegram (แก้ค่าตรงนี้) ────────────────────────────────────────────────
TELEGRAM_ENABLED=false
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# ── Log — fixed filename เขียนทับทุกครั้ง (ไม่บวม) ─────────────────────────
LOG_DIR="/var/log/ls-purge-all"
LOG_FILE="${LOG_DIR}/purge.log"
FAIL_LOG="${LOG_DIR}/purge_fail.log"
mkdir -p "$LOG_DIR"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   WHITE='\033[1;37m'
BOLD='\033[1m';      DIM='\033[2m';        RESET='\033[0m'

# ── Runtime vars ──────────────────────────────────────────────────────────────
WP_CLI=""
PHP_CLI=""

# ── Global Maps ───────────────────────────────────────────────────────────────
declare -A G_MAIN_DOMAINS=()       # main_domain  → cpanel_user
declare -A G_USER_MAINDOMAIN=()    # cpanel_user  → main_domain
declare -A G_ADDON_DOMAINS=()      # addon_domain → cpanel_user
declare -A G_PARKED_PARENT=()      # parked_dom   → parent_domain
declare -A G_PARKED_USER=()        # parked_dom   → cpanel_user
declare -A G_DOMAIN_DOCROOT=()     # domain       → docroot (จาก userdatadomains)

# ── Counters ──────────────────────────────────────────────────────────────────
CNT_TOTAL=0; CNT_SUCCESS=0; CNT_FAILED=0; CNT_SKIP=0; CNT_CF_ISSUE=0

# ── Last result (ตั้งโดย do_purge) ────────────────────────────────────────────
LAST_RESULT=""   # SUCCESS | CF_ZONE_MISSING | CF_CONN_FAILED | CF_DISABLED |
                 # CF_PURGE_FAILED | CF_UNCONFIRMED | LS_FAILED | SKIP
LAST_OUTPUT=""

###############################################################################
# Logging — OVERWRITE each run (ป้องกัน log บวม)
###############################################################################
log_init() {
    {
        printf "╔══════════════════════════════════════════════════════════╗\n"
        printf "║  LiteSpeed Purge All  v%-33s║\n" "${VERSION}"
        printf "╠══════════════════════════════════════════════════════════╣\n"
        printf "║  Server  : %-44s║\n" "$(hostname -s)"
        printf "║  Started : %-44s║\n" "$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')"
        printf "╚══════════════════════════════════════════════════════════╝\n"
        echo ""
    } > "$LOG_FILE"
    > "$FAIL_LOG"
}

log()      { echo "$1" >> "$LOG_FILE"; }
log_fail() { echo "$1" >> "$LOG_FILE"; echo "$1" >> "$FAIL_LOG"; }

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
# Find PHP CLI (เหมือน wp-bulk-permalink-flush.sh)
###############################################################################
find_php_cli() {
    local cli=""
    local default_php
    default_php=$(whmapi1 php_get_system_default_version 2>/dev/null \
        | grep -o 'ea-php[0-9]*')
    if [[ -n "$default_php" && -f "/opt/cpanel/${default_php}/root/usr/bin/php" ]]; then
        cli="/opt/cpanel/${default_php}/root/usr/bin/php"
    fi
    if [[ -z "$cli" ]]; then
        cli=$(ls -d /opt/cpanel/ea-php*/root/usr/bin/php 2>/dev/null \
            | sort -V | tail -2 | head -1)
    fi
    if [[ -z "$cli" ]]; then
        cli=$(command -v php 2>/dev/null || true)
    fi
    [[ -z "$cli" ]] && return 1
    echo "$cli"
}

###############################################################################
# Requirements
###############################################################################
check_requirements() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}[ERROR]${RESET} กรุณารันด้วย root"; exit 1; }

    for p in /usr/local/bin/wp /usr/bin/wp /root/bin/wp; do
        [[ -x "$p" ]] && WP_CLI="$p" && break
    done
    [[ -z "$WP_CLI" ]] && WP_CLI=$(command -v wp 2>/dev/null || true)
    [[ -z "$WP_CLI" ]] && { echo -e "${RED}[ERROR]${RESET} ไม่พบ wp-cli"; exit 1; }

    local php_bin
    php_bin=$(find_php_cli)
    [[ -z "$php_bin" ]] && { echo -e "${RED}[ERROR]${RESET} ไม่พบ PHP CLI"; exit 1; }
    PHP_CLI="$php_bin -d error_reporting=E_ALL&~E_DEPRECATED"

    for f in /etc/userdomains /etc/trueuserdomains; do
        [[ ! -f "$f" ]] && { echo -e "${RED}[ERROR]${RESET} ไม่พบ $f"; exit 1; }
    done
}

###############################################################################
# Build: Main Domains Map (/etc/trueuserdomains)
###############################################################################
build_main_domains_map() {
    G_MAIN_DOMAINS=(); G_USER_MAINDOMAIN=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local domain cpuser
        domain=$(awk '{print $1}' <<< "$line" | tr -d ':' | tr -d ' \t')
        cpuser=$(awk '{print $2}' <<< "$line" | tr -d ' \t')
        [[ -z "$domain" || -z "$cpuser" ]] && continue
        G_MAIN_DOMAINS["$domain"]="$cpuser"
        G_USER_MAINDOMAIN["$cpuser"]="$domain"
    done < /etc/trueuserdomains
}

###############################################################################
# Build: Parked/Alias Map (/etc/userdatadomains)
###############################################################################
build_parked_alias_map() {
    G_PARKED_PARENT=(); G_PARKED_USER=(); G_DOMAIN_DOCROOT=()
    [[ ! -f /etc/userdatadomains ]] && return
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local domain rest cpuser parent dtype docroot
        domain=$(cut -d: -f1 <<< "$line" | tr -d ' \t')
        rest=$(cut -d: -f2- <<< "$line")
        cpuser=$(awk  -F'==' '{print $1}' <<< "$rest" | tr -d ' \t')
        parent=$(awk  -F'==' '{print $2}' <<< "$rest" | tr -d ' \t')
        dtype=$(awk   -F'==' '{print $3}' <<< "$rest" | tr -d ' \t')
        docroot=$(awk -F'==' '{print $4}' <<< "$rest" | tr -d ' \t')

        [[ -z "$domain" || -z "$cpuser" ]] && continue

        # เก็บ docroot ของทุก domain (ใช้ใน get_wp_path)
        [[ -n "$docroot" ]] && G_DOMAIN_DOCROOT["$domain"]="$docroot"

        # เก็บ parked/alias
        if [[ "$dtype" == "parked" || "$dtype" == "alias" ]]; then
            [[ -z "$parent" ]] && continue
            G_PARKED_PARENT["$domain"]="$parent"
            G_PARKED_USER["$domain"]="$cpuser"
            # เก็บ docroot ของ parent ไว้ให้ parked domain ใช้
            local parent_docroot="${G_DOMAIN_DOCROOT[$parent]:-}"
            [[ -n "$parent_docroot" ]] && G_DOMAIN_DOCROOT["$domain"]="$parent_docroot"
        fi
    done < /etc/userdatadomains
}

###############################################################################
# Get All cPanel Users (จาก trueuserdomains)
###############################################################################
get_all_cpanel_users() {
    local -n _out=$1
    _out=()
    local -A _seen=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        local u
        u=$(awk '{print $2}' <<< "$line" | tr -d ' \t')
        [[ -z "$u" ]] && continue
        [[ -z "${_seen[$u]+x}" ]] && _seen["$u"]=1 && _out+=("$u")
    done < /etc/trueuserdomains
    mapfile -t _out < <(printf '%s\n' "${_out[@]}" | sort)
}

###############################################################################
# Build: Addon Domains Map (/etc/userdomains)
# กรองออก: .cp, nobody, *, main domains, cPanel internal subdomains (type=sub)
###############################################################################
build_addon_domains_map() {
    local filter_users=("$@")
    G_ADDON_DOMAINS=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *".cp:"*    ]] && continue   # cPanel proxy
        [[ "$line" == *"nobody"*  ]] && continue   # nobody user
        [[ "$line" == \**         ]] && continue   # wildcard

        local domain cpuser
        domain=$(awk '{print $1}' <<< "$line" | tr -d ':' | tr -d ' \t')
        cpuser=$(awk '{print $2}' <<< "$line" | tr -d ' \t')
        [[ -z "$domain" || -z "$cpuser" ]] && continue

        # ข้าม cPanel internal subdomain prefix
        [[ "$domain" =~ ^(mail|ftp|cpanel|webmail|whm|cpcalendars|cpcontacts|autodiscover|www)\. ]] \
            && continue

        # ข้าม main domain (อยู่ใน trueuserdomains)
        [[ -n "${G_MAIN_DOMAINS[$domain]+x}" ]] && continue

        # ข้าม parked/alias (จัดการแยกอีก section)
        [[ -n "${G_PARKED_PARENT[$domain]+x}" ]] && continue

        # ข้าม cPanel subdomain ที่ลงท้ายด้วย .mainDomain
        local parent_label="${domain#*.}"
        local main_dom="${G_USER_MAINDOMAIN[$cpuser]:-}"
        [[ -n "$main_dom" && "$domain" == *".$main_dom" ]] && continue

        # กรองตาม filter_users (mode 2)
        if [[ ${#filter_users[@]} -gt 0 ]]; then
            local match=0
            for u in "${filter_users[@]}"; do
                [[ "$cpuser" == "$u" ]] && match=1 && break
            done
            [[ $match -eq 0 ]] && continue
        fi

        G_ADDON_DOMAINS["$domain"]="$cpuser"
    done < /etc/userdomains
}

###############################################################################
# Find WordPress Path
# Priority: 1) userdatadomains docroot  2) /home/USER/public_html/DOMAIN/
#           3) /home/USER/DOMAIN/       4) whmapi1
###############################################################################
find_wp_path() {
    local domain=$1 cpuser=$2
    local -n _ret=$3
    _ret=""

    local home_dir
    home_dir=$(getent passwd "$cpuser" 2>/dev/null | cut -d: -f6)
    [[ -z "$home_dir" ]] && home_dir="/home/${cpuser}"

    # Priority 1: docroot จาก userdatadomains (เร็วที่สุด)
    local pre="${G_DOMAIN_DOCROOT[$domain]:-}"
    if [[ -n "$pre" && -f "${pre}/wp-config.php" ]]; then
        _ret="$pre"; return
    fi

    # Priority 2: /home/USER/public_html/DOMAIN/  (แบบที่ 2)
    if [[ -f "${home_dir}/public_html/${domain}/wp-config.php" ]]; then
        _ret="${home_dir}/public_html/${domain}"; return
    fi

    # Priority 3: /home/USER/DOMAIN/  (แบบที่ 1)
    if [[ -f "${home_dir}/${domain}/wp-config.php" ]]; then
        _ret="${home_dir}/${domain}"; return
    fi

    # Priority 4: whmapi1 (ช้า แต่แม่นที่สุดสำหรับ main domain / edge case)
    local docroot
    docroot=$(whmapi1 --output=jsonpretty domainuserdata \
        domain="$domain" 2>/dev/null \
        | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('data',{}).get('userdata',{}).get('documentroot',''))
except: print('')
" 2>/dev/null | tr -d ' ')
    if [[ -n "$docroot" && -f "${docroot}/wp-config.php" ]]; then
        _ret="$docroot"; return
    fi
}

###############################################################################
# Find WP path for PARENT domain (ใช้กับ parked/alias)
###############################################################################
find_wp_path_for_parent() {
    local parent_dom=$1 cpuser=$2
    local -n _ret2=$3
    _ret2=""

    find_wp_path "$parent_dom" "$cpuser" _ret2
    [[ -n "$_ret2" ]] && return

    local home_dir
    home_dir=$(getent passwd "$cpuser" 2>/dev/null | cut -d: -f6)
    [[ -z "$home_dir" ]] && home_dir="/home/${cpuser}"

    [[ -f "${home_dir}/public_html/wp-config.php" ]] \
        && _ret2="${home_dir}/public_html" && return
    [[ -f "${home_dir}/wp-config.php" ]] \
        && _ret2="${home_dir}"
}

###############################################################################
# Check CF configured in LSCWP
###############################################################################
check_cf_configured() {
    local wp_path="$1" cpuser="$2"
    local cf_token=""

    cf_token=$(sudo -u "$cpuser" $PHP_CLI "$WP_CLI" --path="$wp_path" \
        litespeed-option get cdn-cloudflare_token 2>/dev/null \
        | grep -v "^Error:" | grep -v "^Warning:" | tr -d '[:space:]')

    if [[ -z "$cf_token" || "$cf_token" == "0" ]]; then
        cf_token=$(sudo -u "$cpuser" $PHP_CLI "$WP_CLI" --path="$wp_path" eval \
            'echo isset(get_option("litespeed.conf")["cdn-cloudflare_token"])
               ? get_option("litespeed.conf")["cdn-cloudflare_token"]
               : "";' 2>/dev/null \
            | grep -v "^Error:" | grep -v "^Warning:" | tr -d '[:space:]')
    fi

    [[ -n "$cf_token" && "$cf_token" != "0" ]] && echo "1" || echo "0"
}

###############################################################################
# Read LiteSpeed admin notices from DB (หลัง purge)
###############################################################################
read_ls_notices() {
    local wp_path="$1" cpuser="$2"
    sudo -u "$cpuser" $PHP_CLI "$WP_CLI" --path="$wp_path" eval '
$keys = ["litespeed_messages","litespeed.notices","litespeed_admin_display"];
$all  = [];
foreach ($keys as $k) {
    $val = get_option($k);
    if (empty($val)) continue;
    if (is_array($val)) {
        foreach ($val as $level => $msgs) {
            foreach ((array)$msgs as $m) {
                $c = trim(strip_tags($m));
                if ($c) $all[] = strtoupper($level).": ".$c;
            }
        }
    } elseif (is_string($val) && $val !== "") {
        $all[] = trim(strip_tags($val));
    }
    delete_option($k);
}
if (class_exists("LiteSpeed\Admin_Display")) {
    try {
        $cls = LiteSpeed\Admin_Display::cls();
        if (method_exists($cls,"get_notice_arr")) {
            foreach ((array)$cls->get_notice_arr() as $level => $msgs) {
                foreach ((array)$msgs as $m) {
                    $c = trim(strip_tags($m));
                    if ($c) $all[] = strtoupper($level).": ".$c;
                }
            }
        }
    } catch (Exception $e) {}
}
echo empty($all) ? "NOTICES_EMPTY\n" : implode("\n",array_unique($all))."\n";
' 2>/dev/null
}

###############################################################################
# Inline Spinner (เหมือน wp-bulk-permalink-flush.sh)
###############################################################################
run_with_spinner() {
    local label="$1" idx="$2" total="$3"
    shift 3

    local tmp; tmp=$(mktemp)
    "$@" >"$tmp" 2>&1 &
    local bg=$!
    local sp='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' si=0

    while kill -0 "$bg" 2>/dev/null; do
        si=$(( (si+1) % 10 ))
        printf "\r  ${CYAN}[%4d/%-4d]${RESET}  %-52s  ${CYAN}%s${RESET}" \
            "$idx" "$total" "$label" "${sp:$si:1}"
        sleep 0.08
    done
    wait "$bg"; local ec=$?

    local raw_output
    raw_output=$(cat "$tmp"); rm -f "$tmp"

    # ── แยก PURGE_RESULT line ออกจาก output ──────────────────────────────
    # do_purge echo "PURGE_RESULT:<value>" ออก stdout เพื่อส่งกลับ parent
    # เพราะ variable ที่ set ใน subshell (&) ไม่กลับมาถึง parent shell
    LAST_RESULT=$(printf '%s\n' "$raw_output" \
        | grep "^PURGE_RESULT:" | tail -1 | cut -c14-)
    LAST_OUTPUT=$(printf '%s\n' "$raw_output" \
        | grep -v "^PURGE_RESULT:")

    if [[ $ec -eq 0 ]]; then
        printf "\r  ${CYAN}[%4d/%-4d]${RESET}  %-52s  ${GREEN}✔ OK${RESET}\n" \
            "$idx" "$total" "$label"
    else
        printf "\r  ${CYAN}[%4d/%-4d]${RESET}  %-52s  ${RED}✖ FAIL${RESET}\n" \
            "$idx" "$total" "$label"
    fi
    return $ec
}

###############################################################################
# do_purge — core purge logic (รันผ่าน run_with_spinner ใน background subshell)
#
# ⚠️  ห้าม set variable ใน function นี้แล้วหวังว่าจะกลับไป parent shell
#     เพราะ & = subshell — variable ไม่ propagate กลับ parent เด็ดขาด
#
# วิธีส่งผลลัพธ์กลับ:
#   echo "PURGE_RESULT:<value>"  → stdout → $tmp → LAST_RESULT ใน parent
#
# Exit code:
#   0 = SUCCESS
#   1 = CF issue (LS OK แต่ CF มีปัญหา)
#   2 = LS FAILED
###############################################################################
do_purge() {
    local domain="$1" cpuser="$2" wp_path="$3" wp_url="${4:-$1}"

    # ── Plugin active check ──────────────────────────────────────────────
    # ใช้ "Status: active" ไม่ใช่ "active" เพราะ "Inactive" มี substring "active"
    if ! sudo -u "$cpuser" $PHP_CLI "$WP_CLI" --path="$wp_path" \
        plugin status litespeed-cache 2>&1 | grep -qi "Status: active"; then
        echo "PURGE_RESULT:LS_PLUGIN_INACTIVE"
        return 2
    fi

    # ── CF configured? ───────────────────────────────────────────────────
    local cf_configured
    cf_configured=$(check_cf_configured "$wp_path" "$cpuser")

    # ── STEP 1: wp litespeed-purge all ───────────────────────────────────
    local purge_out purge_exit
    purge_out=$(sudo -u "$cpuser" $PHP_CLI "$WP_CLI" \
        --path="$wp_path" --url="https://${wp_url}" \
        litespeed-purge all 2>&1)
    purge_exit=$?

    if ! ([[ $purge_exit -eq 0 ]] && echo "$purge_out" | grep -qi "^Success:"); then
        local err
        err=$(echo "$purge_out" | grep -i "^Error:" | head -1)
        echo "PURGE_RESULT:LS_FAILED:${err:-exit=${purge_exit}}"
        return 2
    fi

    # ── STEP 2: CF notices ───────────────────────────────────────────────
    if [[ "$cf_configured" == "0" ]]; then
        echo "PURGE_RESULT:SUCCESS"
        return 0
    fi

    local notices
    notices=$(read_ls_notices "$wp_path" "$cpuser")

    # Exact strings จาก cloudflare.cls.php (verified บน server จริง)
    local cf_comm_ok=0 cf_purge_ok=0
    local cf_zone_missing=0 cf_conn_failed=0 cf_api_off=0

    echo "$notices" | grep -qF "Communicated with Cloudflare successfully."     && cf_comm_ok=1
    echo "$notices" | grep -qF "Notified Cloudflare to purge all successfully." && cf_purge_ok=1
    echo "$notices" | grep -qF "No available Cloudflare zone"                   && cf_zone_missing=1
    echo "$notices" | grep -qF "Failed to communicate with Cloudflare"          && cf_conn_failed=1
    echo "$notices" | grep -qF "Cloudflare API is set to off."                  && cf_api_off=1

    if [[ $cf_comm_ok -eq 1 && $cf_purge_ok -eq 1 ]]; then
        echo "PURGE_RESULT:SUCCESS"
        return 0
    elif [[ $cf_zone_missing -eq 1 ]]; then
        echo "PURGE_RESULT:CF_ZONE_MISSING"
    elif [[ $cf_conn_failed -eq 1 ]]; then
        echo "PURGE_RESULT:CF_CONN_FAILED"
    elif [[ $cf_api_off -eq 1 ]]; then
        echo "PURGE_RESULT:CF_DISABLED"
    elif [[ $cf_comm_ok -eq 1 && $cf_purge_ok -eq 0 ]]; then
        echo "PURGE_RESULT:CF_PURGE_FAILED"
    else
        echo "PURGE_RESULT:CF_UNCONFIRMED"
    fi
    return 1   # CF issue — LS purge สำเร็จ แต่ CF มีปัญหา
}

###############################################################################
# Process domains — main loop (เหมือน wp-bulk-permalink-flush.sh)
###############################################################################
process_domains() {
    local filter_users=("$@")

    echo ""
    echo -e "${CYAN}  ⟳  กำลังสแกน domain...${RESET}"

    build_parked_alias_map
    build_addon_domains_map "${filter_users[@]}"

    # สร้าง ALIAS_TODO (กรองตาม filter_users)
    declare -A ALIAS_TODO=()
    for alias_dom in "${!G_PARKED_PARENT[@]}"; do
        local acpuser="${G_PARKED_USER[$alias_dom]}"
        if [[ ${#filter_users[@]} -gt 0 ]]; then
            local match=0
            for u in "${filter_users[@]}"; do
                [[ "$acpuser" == "$u" ]] && match=1 && break
            done
            [[ $match -eq 0 ]] && continue
        fi
        ALIAS_TODO["$alias_dom"]="${acpuser}|${G_PARKED_PARENT[$alias_dom]}"
    done

    local total_addon=${#G_ADDON_DOMAINS[@]}
    local total_alias=${#ALIAS_TODO[@]}
    CNT_TOTAL=$(( total_addon + total_alias ))

    echo -e "  ${GREEN}✔${RESET}  Addon domains   : ${WHITE}${total_addon}${RESET}"
    echo -e "  ${GREEN}✔${RESET}  Parked/Alias    : ${WHITE}${total_alias}${RESET}"
    echo -e "  ${GREEN}✔${RESET}  รวมทั้งหมด      : ${WHITE}${CNT_TOTAL}${RESET}"
    echo ""

    log_init
    log "Filter users  : ${filter_users[*]:-ALL}"
    log "Addon domains : $total_addon"
    log "Parked/Alias  : $total_alias"
    log "Total         : $CNT_TOTAL"
    log ""

    local current=0
    CNT_SUCCESS=0; CNT_FAILED=0; CNT_SKIP=0; CNT_CF_ISSUE=0

    # ════════════════════════════════════════════
    # Section 1: Addon Domains
    # ════════════════════════════════════════════
    if [[ $total_addon -gt 0 ]]; then
        echo -e "${BLUE}━━━  Addon Domains  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        log "=== Addon Domains ==="
        for domain in $(printf '%s\n' "${!G_ADDON_DOMAINS[@]}" | sort); do
            local cpuser="${G_ADDON_DOMAINS[$domain]}"
            current=$(( current + 1 ))

            # หา wp_path
            local wp_path=""
            find_wp_path "$domain" "$cpuser" wp_path

            if [[ -z "$wp_path" ]]; then
                printf "  ${CYAN}[%4d/%-4d]${RESET}  %-52s  ${YELLOW}⊘ SKIP${RESET}\n" \
                    "$current" "$CNT_TOTAL" "$domain"
                log "[SKIP] $domain ($cpuser) — ไม่พบ wp-config.php"
                CNT_SKIP=$(( CNT_SKIP + 1 ))
                continue
            fi

            run_with_spinner "$domain" "$current" "$CNT_TOTAL" \
                do_purge "$domain" "$cpuser" "$wp_path" "$domain"
            local rc=$?

            _log_purge_result "$domain" "$cpuser" "$wp_path" "$rc"
        done
    fi

    # ════════════════════════════════════════════
    # Section 2: Parked / Alias Domains
    # ════════════════════════════════════════════
    if [[ $total_alias -gt 0 ]]; then
        echo ""
        echo -e "${BLUE}━━━  Parked / Alias Domains  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        log ""
        log "=== Parked/Alias Domains ==="
        for alias_dom in $(printf '%s\n' "${!ALIAS_TODO[@]}" | sort); do
            IFS='|' read -r acpuser parent_dom <<< "${ALIAS_TODO[$alias_dom]}"
            current=$(( current + 1 ))
            local label="${alias_dom}  →  ${parent_dom}"

            local wp_path=""
            find_wp_path_for_parent "$parent_dom" "$acpuser" wp_path

            if [[ -z "$wp_path" ]]; then
                printf "  ${CYAN}[%4d/%-4d]${RESET}  %-52s  ${YELLOW}⊘ SKIP${RESET}\n" \
                    "$current" "$CNT_TOTAL" "$label"
                log "[SKIP] $alias_dom → $parent_dom ($acpuser) — ไม่พบ parent wp-config.php"
                CNT_SKIP=$(( CNT_SKIP + 1 ))
                continue
            fi

            # --url ใช้ชื่อ alias domain (ไม่ใช่ parent)
            run_with_spinner "$label" "$current" "$CNT_TOTAL" \
                do_purge "$alias_dom" "$acpuser" "$wp_path" "$alias_dom"
            local rc=$?

            _log_purge_result "$alias_dom ($parent_dom)" "$acpuser" "$wp_path" "$rc"
        done
    fi

    _print_summary
    send_telegram
}

###############################################################################
# Log purge result + update counters
###############################################################################
_log_purge_result() {
    local domain="$1" cpuser="$2" wp_path="$3" rc="$4"

    if [[ $rc -eq 0 ]]; then
        log "[OK]      $domain ($cpuser) → $wp_path | $LAST_RESULT"
        CNT_SUCCESS=$(( CNT_SUCCESS + 1 ))

    elif [[ $rc -eq 1 ]]; then
        # LS purge OK แต่ CF มีปัญหา
        log_fail "[CF_ISSUE] $domain ($cpuser) → $wp_path | $LAST_RESULT"
        case "$LAST_RESULT" in
            CF_ZONE_MISSING)
                log_fail "           Zone ID ไม่มีข้อมูล"
                log_fail "           โปรดรัน Script Cloudflare Zone เพื่อแก้ไขปัญหา"
                ;;
            CF_CONN_FAILED)
                log_fail "           Failed to communicate with Cloudflare"
                log_fail "           ตรวจ API Token — ต้องมีสิทธิ์ Zone:Cache Purge"
                ;;
            CF_DISABLED)
                log_fail "           Cloudflare API is set to off."
                log_fail "           LiteSpeed Cache → CDN → Cloudflare API → ON"
                ;;
            CF_PURGE_FAILED)
                log_fail "           Communicated OK แต่ purge_cache ล้มเหลว"
                log_fail "           ตรวจ Token permission: Cache Purge"
                ;;
            CF_UNCONFIRMED)
                log_fail "           LS purge สำเร็จ แต่ตรวจ CF ไม่ได้ (notices หาย)"
                ;;
        esac
        CNT_CF_ISSUE=$(( CNT_CF_ISSUE + 1 ))

    else
        # LS purge FAILED
        log_fail "[FAIL]     $domain ($cpuser) → $wp_path | $LAST_RESULT"
        [[ -n "$LAST_OUTPUT" ]] && log_fail "           ↳ $LAST_OUTPUT"
        CNT_FAILED=$(( CNT_FAILED + 1 ))
    fi
}

###############################################################################
# Summary box (เหมือน wp-bulk-permalink-flush.sh)
###############################################################################
_print_summary() {
    local end_time
    end_time=$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')

    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BLUE}║  ${WHITE}${BOLD}SUMMARY${RESET}${BLUE}                                                      ║${RESET}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
    printf "${BLUE}║${RESET}  Total      : ${WHITE}%-4d${RESET}%-36s${BLUE}║${RESET}\n" "$CNT_TOTAL"    ""
    printf "${BLUE}║${RESET}  ${GREEN}Success${RESET}    : ${GREEN}%-4d${RESET}%-36s${BLUE}║${RESET}\n" "$CNT_SUCCESS"  ""
    printf "${BLUE}║${RESET}  ${YELLOW}CF issue${RESET}   : ${YELLOW}%-4d${RESET}%-36s${BLUE}║${RESET}\n" "$CNT_CF_ISSUE" ""
    printf "${BLUE}║${RESET}  ${RED}Failed${RESET}     : ${RED}%-4d${RESET}%-36s${BLUE}║${RESET}\n" "$CNT_FAILED"   ""
    printf "${BLUE}║${RESET}  ${YELLOW}Skipped${RESET}    : ${YELLOW}%-4d${RESET}%-36s${BLUE}║${RESET}\n" "$CNT_SKIP"    ""
    echo -e "${BLUE}║${RESET}  ${DIM}Log : ${LOG_FILE}${RESET}"
    [[ $CNT_CF_ISSUE -gt 0 || $CNT_FAILED -gt 0 ]] && \
        echo -e "${BLUE}║${RESET}  ${RED}Fail: ${FAIL_LOG}${RESET}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"

    log ""
    log "=== SUMMARY ==="
    log "Total     : $CNT_TOTAL"
    log "Success   : $CNT_SUCCESS"
    log "CF issue  : $CNT_CF_ISSUE"
    log "Failed    : $CNT_FAILED"
    log "Skipped   : $CNT_SKIP"
    log "Finished  : $end_time"
}

###############################################################################
# Telegram Notification
###############################################################################
send_telegram() {
    [[ "$TELEGRAM_ENABLED" != "true" ]] && return
    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return

    local end_time
    end_time=$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')
    local icon="✅"
    [[ $CNT_FAILED -gt 0 || $CNT_CF_ISSUE -gt 0 ]] && icon="⚠️"
    [[ $CNT_FAILED -eq $CNT_TOTAL && $CNT_TOTAL -gt 0 ]] && icon="❌"

    local msg
    msg=$(cat <<EOF
${icon} <b>LiteSpeed Purge All</b>
🖥 Server: <code>$(hostname -s)</code>
🕐 ${end_time}

├ Total    : ${CNT_TOTAL}
├ ✅ Success : ${CNT_SUCCESS}
├ ⚠️ CF issue: ${CNT_CF_ISSUE}
├ ❌ Failed  : ${CNT_FAILED}
└ ⊘ Skipped : ${CNT_SKIP}

📄 <code>${LOG_FILE}</code>
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
# MAIN
###############################################################################
check_requirements

print_header

echo -e "${WHITE}${BOLD}เลือกโหมดการทำงาน:${RESET}"
echo ""
echo -e "  ${CYAN}1.${RESET}  Purge ${WHITE}ทุกเว็บไซต์${RESET} ในเซิร์ฟเวอร์นี้ทั้งหมด"
echo -e "  ${CYAN}2.${RESET}  เลือกรันเฉพาะบาง ${WHITE}cPanel${RESET} ในเซิร์ฟเวอร์นี้"
echo ""
printf "กรุณาเลือก [1-2]: "
read -r MODE

# โหลด main domains (ใช้ทั้ง 2 mode)
build_main_domains_map

declare -a ALL_CPANEL_USERS=()
get_all_cpanel_users ALL_CPANEL_USERS

case "$MODE" in

    # ────────────────────────────────────────────────────────────────────
    1)
        print_header
        echo -e "${WHITE}${BOLD}[ Mode 1 ]  Purge All — ทุก cPanel account${RESET}"
        echo ""
        echo -e "${CYAN}cPanel accounts ที่มีในระบบ (${#ALL_CPANEL_USERS[@]} accounts):${RESET}"
        echo ""
        for u in "${ALL_CPANEL_USERS[@]}"; do
            echo -e "  ${GREEN}•${RESET}  $u"
        done
        echo ""
        printf "${YELLOW}ยืนยันการ Purge ทุก cPanel ข้างบน? [y/N]: ${RESET}"
        read -r CONFIRM
        [[ "${CONFIRM,,}" != "y" ]] && echo -e "${RED}ยกเลิก${RESET}" && exit 0
        process_domains
        ;;

    # ────────────────────────────────────────────────────────────────────
    2)
        print_header
        echo -e "${WHITE}${BOLD}[ Mode 2 ]  เลือก cPanel account${RESET}"
        echo ""
        echo -e "${CYAN}cPanel accounts ที่มีในระบบ:${RESET}"
        echo ""
        for i in "${!ALL_CPANEL_USERS[@]}"; do
            printf "  ${CYAN}%3d.${RESET}  %s\n" "$(( i + 1 ))" "${ALL_CPANEL_USERS[$i]}"
        done
        echo ""
        echo -e "${YELLOW}เลือกหมายเลข (คั่นด้วย space หรือ comma)${RESET}"
        echo -e "${DIM}เช่น:  1 3 5   หรือ   1,3,5${RESET}"
        echo ""
        printf "เลือก: "
        read -r RAW_SEL

        declare -a SELECTED_USERS=()
        for sel in $(echo "$RAW_SEL" | tr ',' ' '); do
            if [[ "$sel" =~ ^[0-9]+$ ]]; then
                local idx=$(( sel - 1 ))
                if [[ $idx -ge 0 && $idx -lt ${#ALL_CPANEL_USERS[@]} ]]; then
                    SELECTED_USERS+=("${ALL_CPANEL_USERS[$idx]}")
                else
                    echo -e "${RED}  [WARN]${RESET} หมายเลข $sel ไม่มีใน list — ข้ามไป"
                fi
            else
                echo -e "${RED}  [WARN]${RESET} '$sel' ไม่ใช่หมายเลข — ข้ามไป"
            fi
        done

        if [[ ${#SELECTED_USERS[@]} -eq 0 ]]; then
            echo -e "${RED}[ERROR]${RESET} ไม่ได้เลือก cPanel ใด"; exit 1
        fi
        mapfile -t SELECTED_USERS < <(printf '%s\n' "${SELECTED_USERS[@]}" | sort -u)

        echo ""
        echo -e "${CYAN}cPanel ที่เลือก:${RESET}"
        for u in "${SELECTED_USERS[@]}"; do
            echo -e "  ${GREEN}✔${RESET}  $u"
        done
        echo ""
        printf "${YELLOW}ยืนยัน? [y/N]: ${RESET}"
        read -r CONFIRM2
        [[ "${CONFIRM2,,}" != "y" ]] && echo -e "${RED}ยกเลิก${RESET}" && exit 0

        process_domains "${SELECTED_USERS[@]}"
        ;;

    # ────────────────────────────────────────────────────────────────────
    *)
        echo -e "${RED}[ERROR]${RESET} กรุณาเลือก 1 หรือ 2"; exit 1
        ;;
esac
