#!/bin/bash
###############################################################################
# litespeed-purge-all.sh
# LiteSpeed Cache Purge All — across cPanel accounts
# Version : 2.6.0
# Location: /usr/local/sbin/litespeed-purge-all.sh
# Usage   : bash /usr/local/sbin/litespeed-purge-all.sh
# ─────────────────────────────────────────────────────────────────────────────
# CHANGELOG:
#   v2.6.0 | 2026-04-29 12:00 | Parallel execution via job pool
#           |                  | PARALLEL_JOBS config (default 5)
#           |                  | SCAN → DISPATCH → COLLECT architecture
#           |                  | flock atomic print, result via TMP_DIR files
#           |                  | INT/TERM trap kills all child jobs
#   v2.5.1 | 2026-04-29 11:00 | Fix LAST_RESULT subshell issue
#   v2.5.0 | 2026-04-29 10:00 | Rewrite: wp-bulk-permalink-flush.sh pattern
#   v2.4.0 | 2026-04-29 09:00 | Domain map + 2 paths + Parked/Alias
#   v2.3.0 | 2026-04-29 08:00 | CF detection exact strings
#   v2.0.0 | 2026-04-28 16:00 | Initial wp litespeed-purge all
###############################################################################

VERSION="2.6.0"

# ── Config ─────────────────────────────────────────────────────────────────
# จำนวน concurrent workers — แนะนำ 5-8 สำหรับ EPYC 8-core
# ตั้ง 1 = sequential (ไม่มี parallel)
PARALLEL_JOBS=5

# ── Telegram (แก้ค่าตรงนี้) ────────────────────────────────────────────────
TELEGRAM_ENABLED=false
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# ── Log — fixed filename เขียนทับทุกครั้ง (ไม่บวม) ─────────────────────────
LOG_DIR="/var/log/ls-purge-all"
LOG_FILE="${LOG_DIR}/purge.log"
FAIL_LOG="${LOG_DIR}/purge_fail.log"
mkdir -p "$LOG_DIR"

# ── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   WHITE='\033[1;37m'
BOLD='\033[1m';      DIM='\033[2m';        RESET='\033[0m'

# ── Runtime vars ────────────────────────────────────────────────────────────
WP_CLI=""
PHP_CLI=""
TMP_DIR=""   # สร้างใน process_domains(), ลบเมื่อ EXIT

# ── Global Maps (read-only หลัง build phase — safe ใน parallel) ────────────
declare -A G_MAIN_DOMAINS=()
declare -A G_USER_MAINDOMAIN=()
declare -A G_ADDON_DOMAINS=()
declare -A G_PARKED_PARENT=()
declare -A G_PARKED_USER=()
declare -A G_DOMAIN_DOCROOT=()

# ── Counters (parent process เท่านั้น — ตั้งใน COLLECT phase) ───────────────
CNT_TOTAL=0; CNT_SUCCESS=0; CNT_FAILED=0; CNT_SKIP=0; CNT_CF_ISSUE=0

# ── Cleanup traps ───────────────────────────────────────────────────────────
# EXIT: ลบ TMP_DIR เสมอ
trap '[[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"' EXIT

# INT/TERM: kill background jobs ทั้งหมด แล้ว exit
trap '
    echo ""
    echo -e "${YELLOW}  ยกเลิก — รอ jobs หยุด...${RESET}"
    jobs -p | xargs -r kill 2>/dev/null
    wait 2>/dev/null
    exit 130
' INT TERM

###############################################################################
# Logging — OVERWRITE each run
###############################################################################
log_init() {
    {
        printf "╔══════════════════════════════════════════════════════════╗\n"
        printf "║  LiteSpeed Purge All  v%-33s║\n" "${VERSION}"
        printf "╠══════════════════════════════════════════════════════════╣\n"
        printf "║  Server   : %-43s║\n" "$(hostname -s)"
        printf "║  Workers  : %-43s║\n" "${PARALLEL_JOBS} parallel"
        printf "║  Started  : %-43s║\n" "$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')"
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
    echo -e "${BLUE}║  ${DIM}Server: $(hostname -s)  |  Workers: ${PARALLEL_JOBS}${RESET}${BLUE}                      ║${RESET}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

###############################################################################
# Find PHP CLI
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
    [[ -z "$cli" ]] && cli=$(command -v php 2>/dev/null || true)
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

    # ตรวจ flock (ต้องใช้สำหรับ parallel)
    command -v flock &>/dev/null || { echo -e "${RED}[ERROR]${RESET} ไม่พบ flock (util-linux)"; exit 1; }

    for f in /etc/userdomains /etc/trueuserdomains; do
        [[ ! -f "$f" ]] && { echo -e "${RED}[ERROR]${RESET} ไม่พบ $f"; exit 1; }
    done
}

###############################################################################
# Build: Main Domains Map
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
# Build: Parked/Alias Map
###############################################################################
build_parked_alias_map() {
    G_PARKED_PARENT=(); G_PARKED_USER=(); G_DOMAIN_DOCROOT=()
    [[ ! -f /etc/userdatadomains ]] && return
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local domain rest cpuser parent dtype docroot
        domain=$(cut -d: -f1  <<< "$line" | tr -d ' \t')
        rest=$(cut   -d: -f2- <<< "$line")
        cpuser=$(awk  -F'==' '{print $1}' <<< "$rest" | tr -d ' \t')
        parent=$(awk  -F'==' '{print $2}' <<< "$rest" | tr -d ' \t')
        dtype=$(awk   -F'==' '{print $3}' <<< "$rest" | tr -d ' \t')
        docroot=$(awk -F'==' '{print $4}' <<< "$rest" | tr -d ' \t')
        [[ -z "$domain" || -z "$cpuser" ]] && continue
        [[ -n "$docroot" ]] && G_DOMAIN_DOCROOT["$domain"]="$docroot"
        if [[ "$dtype" == "parked" || "$dtype" == "alias" ]]; then
            [[ -z "$parent" ]] && continue
            G_PARKED_PARENT["$domain"]="$parent"
            G_PARKED_USER["$domain"]="$cpuser"
            local parent_docroot="${G_DOMAIN_DOCROOT[$parent]:-}"
            [[ -n "$parent_docroot" ]] && G_DOMAIN_DOCROOT["$domain"]="$parent_docroot"
        fi
    done < /etc/userdatadomains
}

###############################################################################
# Get All cPanel Users
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
# Build: Addon Domains Map
###############################################################################
build_addon_domains_map() {
    local filter_users=("$@")
    G_ADDON_DOMAINS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *".cp:"*    ]] && continue
        [[ "$line" == *"nobody"*  ]] && continue
        [[ "$line" == \**         ]] && continue
        local domain cpuser
        domain=$(awk '{print $1}' <<< "$line" | tr -d ':' | tr -d ' \t')
        cpuser=$(awk '{print $2}' <<< "$line" | tr -d ' \t')
        [[ -z "$domain" || -z "$cpuser" ]] && continue
        [[ "$domain" =~ ^(mail|ftp|cpanel|webmail|whm|cpcalendars|cpcontacts|autodiscover|www)\. ]] && continue
        [[ -n "${G_MAIN_DOMAINS[$domain]+x}" ]] && continue
        [[ -n "${G_PARKED_PARENT[$domain]+x}" ]] && continue
        local main_dom="${G_USER_MAINDOMAIN[$cpuser]:-}"
        [[ -n "$main_dom" && "$domain" == *".$main_dom" ]] && continue
        if [[ ${#filter_users[@]} -gt 0 ]]; then
            local match=0
            for u in "${filter_users[@]}"; do [[ "$cpuser" == "$u" ]] && match=1 && break; done
            [[ $match -eq 0 ]] && continue
        fi
        G_ADDON_DOMAINS["$domain"]="$cpuser"
    done < /etc/userdomains
}

###############################################################################
# Find WordPress Path
# Priority: 1) userdatadomains  2) public_html/DOMAIN  3) DOMAIN  4) whmapi1
###############################################################################
find_wp_path() {
    local domain=$1 cpuser=$2
    local -n _ret=$3
    _ret=""
    local home_dir
    home_dir=$(getent passwd "$cpuser" 2>/dev/null | cut -d: -f6)
    [[ -z "$home_dir" ]] && home_dir="/home/${cpuser}"

    local pre="${G_DOMAIN_DOCROOT[$domain]:-}"
    if [[ -n "$pre" && -f "${pre}/wp-config.php" ]]; then
        _ret="$pre"; return
    fi
    if [[ -f "${home_dir}/public_html/${domain}/wp-config.php" ]]; then
        _ret="${home_dir}/public_html/${domain}"; return
    fi
    if [[ -f "${home_dir}/${domain}/wp-config.php" ]]; then
        _ret="${home_dir}/${domain}"; return
    fi
    local docroot
    docroot=$(whmapi1 --output=jsonpretty domainuserdata domain="$domain" 2>/dev/null \
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
# Find WP path for PARENT domain (parked/alias)
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
    [[ -f "${home_dir}/wp-config.php" ]] && _ret2="${home_dir}"
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
# Read LiteSpeed admin notices from DB
###############################################################################
read_ls_notices() {
    local wp_path="$1" cpuser="$2"
    sudo -u "$cpuser" $PHP_CLI "$WP_CLI" --path="$wp_path" eval '
$keys = ["litespeed_messages","litespeed.notices","litespeed_admin_display"];
$all  = [];
foreach ($keys as $k) {
    $val = get_option($k); if (empty($val)) continue;
    if (is_array($val)) {
        foreach ($val as $level => $msgs)
            foreach ((array)$msgs as $m) {
                $c = trim(strip_tags($m));
                if ($c) $all[] = strtoupper($level).": ".$c;
            }
    } elseif (is_string($val) && $val !== "") { $all[] = trim(strip_tags($val)); }
    delete_option($k);
}
if (class_exists("LiteSpeed\Admin_Display")) {
    try {
        $cls = LiteSpeed\Admin_Display::cls();
        if (method_exists($cls,"get_notice_arr"))
            foreach ((array)$cls->get_notice_arr() as $level => $msgs)
                foreach ((array)$msgs as $m) {
                    $c = trim(strip_tags($m));
                    if ($c) $all[] = strtoupper($level).": ".$c;
                }
    } catch (Exception $e) {}
}
echo empty($all) ? "NOTICES_EMPTY\n" : implode("\n",array_unique($all))."\n";
' 2>/dev/null
}

###############################################################################
# do_purge — core purge logic
#
# ⚠️  ถูกเรียกใน background subshell → ห้าม set global variable
#     ส่งผลลัพธ์กลับด้วย: echo "PURGE_RESULT:<value>" ออก stdout
#
# Exit code:  0=SUCCESS  1=CF_ISSUE (LS OK)  2=LS_FAILED
###############################################################################
do_purge() {
    local domain="$1" cpuser="$2" wp_path="$3" wp_url="${4:-$1}"

    # Plugin active check — "Status: active" ไม่ใช่ "active" (Inactive มี substring)
    if ! sudo -u "$cpuser" $PHP_CLI "$WP_CLI" --path="$wp_path" \
        plugin status litespeed-cache 2>&1 | grep -qi "Status: active"; then
        echo "PURGE_RESULT:LS_PLUGIN_INACTIVE"; return 2
    fi

    local cf_configured
    cf_configured=$(check_cf_configured "$wp_path" "$cpuser")

    # wp litespeed-purge all
    local purge_out purge_exit
    purge_out=$(sudo -u "$cpuser" $PHP_CLI "$WP_CLI" \
        --path="$wp_path" --url="https://${wp_url}" \
        litespeed-purge all 2>&1)
    purge_exit=$?

    if ! ([[ $purge_exit -eq 0 ]] && echo "$purge_out" | grep -qi "^Success:"); then
        local err
        err=$(echo "$purge_out" | grep -i "^Error:" | head -1)
        echo "PURGE_RESULT:LS_FAILED:${err:-exit=${purge_exit}}"; return 2
    fi

    if [[ "$cf_configured" == "0" ]]; then
        echo "PURGE_RESULT:SUCCESS"; return 0
    fi

    local notices
    notices=$(read_ls_notices "$wp_path" "$cpuser")

    # Exact strings จาก cloudflare.cls.php (verified บน server จริง)
    local cf_comm_ok=0 cf_purge_ok=0 cf_zone_missing=0 cf_conn_failed=0 cf_api_off=0
    echo "$notices" | grep -qF "Communicated with Cloudflare successfully."     && cf_comm_ok=1
    echo "$notices" | grep -qF "Notified Cloudflare to purge all successfully." && cf_purge_ok=1
    echo "$notices" | grep -qF "No available Cloudflare zone"                   && cf_zone_missing=1
    echo "$notices" | grep -qF "Failed to communicate with Cloudflare"          && cf_conn_failed=1
    echo "$notices" | grep -qF "Cloudflare API is set to off."                  && cf_api_off=1

    if   [[ $cf_comm_ok      -eq 1 && $cf_purge_ok -eq 1 ]]; then echo "PURGE_RESULT:SUCCESS";         return 0
    elif [[ $cf_zone_missing -eq 1 ]]; then echo "PURGE_RESULT:CF_ZONE_MISSING"
    elif [[ $cf_conn_failed  -eq 1 ]]; then echo "PURGE_RESULT:CF_CONN_FAILED"
    elif [[ $cf_api_off      -eq 1 ]]; then echo "PURGE_RESULT:CF_DISABLED"
    elif [[ $cf_comm_ok      -eq 1 && $cf_purge_ok -eq 0 ]]; then echo "PURGE_RESULT:CF_PURGE_FAILED"
    else echo "PURGE_RESULT:CF_UNCONFIRMED"
    fi
    return 1
}

###############################################################################
# _do_purge_job — parallel job wrapper
#
# รันใน background subshell (&)
# - เรียก do_purge() → parse PURGE_RESULT จาก stdout
# - เขียน result ลง $TMP_DIR/JOB_ID/ (แต่ละ field เป็น file แยก)
# - print result line (atomic ด้วย flock บน .print_lock)
#
# Args: job_id  domain  cpuser  wp_path  wp_url  label  section_total
###############################################################################
_do_purge_job() {
    local job_id="$1" domain="$2" cpuser="$3" wp_path="$4"
    local wp_url="$5" label="$6" section_total="$7"

    local job_dir="${TMP_DIR}/${job_id}"
    mkdir -p "$job_dir"

    # Run do_purge — capture ALL stdout (incl. PURGE_RESULT line)
    local raw ec
    raw=$(do_purge "$domain" "$cpuser" "$wp_path" "$wp_url" 2>&1)
    ec=$?

    # Parse PURGE_RESULT from stdout
    local result clean_out
    result=$(printf '%s\n' "$raw" | grep "^PURGE_RESULT:" | tail -1 | cut -c14-)
    clean_out=$(printf '%s\n' "$raw" | grep -v "^PURGE_RESULT:" | head -3 | tr '\n' ' ' | xargs)

    # Write result files (ไม่มี race condition เพราะแต่ละ job มี dir ของตัวเอง)
    printf '%s' "$ec"        > "${job_dir}/ec"
    printf '%s' "$result"    > "${job_dir}/result"
    printf '%s' "$domain"    > "${job_dir}/domain"
    printf '%s' "$cpuser"    > "${job_dir}/cpuser"
    printf '%s' "$wp_path"   > "${job_dir}/wppath"
    printf '%s' "$label"     > "${job_dir}/label"
    printf '%s' "$clean_out" > "${job_dir}/output"

    # Determine display icon
    local icon
    case $ec in
        0) icon="${GREEN}✔ OK${RESET}" ;;
        1) icon="${YELLOW}⚠ ${result}${RESET}" ;;
        *) icon="${RED}✖ ${result}${RESET}" ;;
    esac

    # Atomic print: flock ensures:
    # 1. ไม่มี two jobs print พร้อมกัน (terminal จะ garbled)
    # 2. completion counter อ่าน/เขียน atomically
    (
        flock -x 9
        local n
        n=$(cat "${TMP_DIR}/.completed" 2>/dev/null || echo 0)
        n=$(( n + 1 ))
        printf '%s' "$n" > "${TMP_DIR}/.completed"
        printf "  ${CYAN}[%4d/%-4d]${RESET}  %-52s  %b\n" \
            "$n" "$section_total" "$label" "$icon"
    ) 9>>"${TMP_DIR}/.print_lock"
}

###############################################################################
# _dispatch_section — dispatch job pool สำหรับ 1 section
#
# Args:
#   $1 = section_total (จำนวน jobs ใน section นี้ สำหรับ [N/TOTAL] display)
#   $2..N = job entries รูปแบบ "domain|cpuser|wp_path|label"
#           ถ้า parked/alias: wp_url = domain (alias name), label = "alias → parent"
###############################################################################
_dispatch_section() {
    local section_total="$1"
    shift
    local -a entries=("$@")

    # Reset completion counter สำหรับ section นี้
    printf '0' > "${TMP_DIR}/.completed"

    local -a pids=()
    local job_id=0

    for entry in "${entries[@]}"; do
        IFS='|' read -r domain cpuser wp_path label <<< "$entry"
        (( job_id++ ))

        # Launch job ใน background
        _do_purge_job "$job_id" "$domain" "$cpuser" "$wp_path" \
            "$domain" "$label" "$section_total" &
        pids+=($!)

        # Job pool: ถ้า pids เต็ม PARALLEL_JOBS ให้รอ 1 ตัวก่อน
        while [[ ${#pids[@]} -ge $PARALLEL_JOBS ]]; do
            # wait -n: รอ child ใด ๆ ให้เสร็จ (bash 4.3+ / AlmaLinux 9 bash 5.1 ✓)
            wait -n 2>/dev/null || true
            # Prune finished pids โดย kill -0 ตรวจว่ายัง running อยู่ไหม
            local _np=()
            for _p in "${pids[@]}"; do
                kill -0 "$_p" 2>/dev/null && _np+=("$_p")
            done
            pids=("${_np[@]}")
        done
    done

    # รอ jobs ที่เหลือทั้งหมด
    [[ ${#pids[@]} -gt 0 ]] && wait "${pids[@]}" 2>/dev/null
}

###############################################################################
# _collect_section — อ่าน result files จาก job_id range
#
# Args: $1=start_id  $2=end_id
# อัปเดต counters + เขียน log (sequential, ไม่มี race condition)
###############################################################################
_collect_section() {
    local start_id="$1" end_id="$2"
    local i
    for (( i = start_id; i <= end_id; i++ )); do
        local job_dir="${TMP_DIR}/${i}"
        [[ -d "$job_dir" ]] || continue

        local ec result domain cpuser wp_path label output
        ec=$(      cat "${job_dir}/ec"     2>/dev/null || echo "2")
        result=$(  cat "${job_dir}/result" 2>/dev/null || echo "UNKNOWN")
        domain=$(  cat "${job_dir}/domain" 2>/dev/null || echo "?")
        cpuser=$(  cat "${job_dir}/cpuser" 2>/dev/null || echo "?")
        wp_path=$( cat "${job_dir}/wppath" 2>/dev/null || echo "?")
        output=$(  cat "${job_dir}/output" 2>/dev/null || echo "")

        case "$ec" in
            0)
                log "[OK]       $domain ($cpuser) → $wp_path | $result"
                (( CNT_SUCCESS++ ))
                ;;
            1)
                log_fail "[CF_ISSUE]  $domain ($cpuser) → $wp_path | $result"
                case "$result" in
                    CF_ZONE_MISSING)
                        log_fail "            Zone ID ไม่มีข้อมูล"
                        log_fail "            โปรดรัน Script Cloudflare Zone เพื่อแก้ไขปัญหา"
                        ;;
                    CF_CONN_FAILED)
                        log_fail "            Failed to communicate with Cloudflare"
                        log_fail "            ตรวจ API Token — ต้องมีสิทธิ์ Zone:Cache Purge"
                        ;;
                    CF_DISABLED)
                        log_fail "            Cloudflare API is set to off."
                        log_fail "            LiteSpeed Cache → CDN → Cloudflare API → ON"
                        ;;
                    CF_PURGE_FAILED)
                        log_fail "            Communicated OK แต่ purge_cache ล้มเหลว"
                        log_fail "            ตรวจ Token permission: Cache Purge"
                        ;;
                    CF_UNCONFIRMED)
                        log_fail "            LS purge สำเร็จ แต่ตรวจ CF ไม่ได้ (notices หาย)"
                        ;;
                esac
                (( CNT_CF_ISSUE++ ))
                ;;
            *)
                log_fail "[FAIL]     $domain ($cpuser) → $wp_path | $result"
                [[ -n "$output" ]] && log_fail "           ↳ $output"
                (( CNT_FAILED++ ))
                ;;
        esac
    done
}

###############################################################################
# _print_summary
###############################################################################
_print_summary() {
    local end_time
    end_time=$(TZ='Asia/Bangkok' date '+%Y-%m-%d %H:%M:%S')

    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BLUE}║  ${WHITE}${BOLD}SUMMARY${RESET}${BLUE}                                                      ║${RESET}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${RESET}"
    printf "${BLUE}║${RESET}  Total      : ${WHITE}%-4d${RESET}%-36s${BLUE}║${RESET}\n"    "$CNT_TOTAL"    ""
    printf "${BLUE}║${RESET}  ${GREEN}Success${RESET}    : ${GREEN}%-4d${RESET}%-36s${BLUE}║${RESET}\n"  "$CNT_SUCCESS"  ""
    printf "${BLUE}║${RESET}  ${YELLOW}CF issue${RESET}   : ${YELLOW}%-4d${RESET}%-36s${BLUE}║${RESET}\n" "$CNT_CF_ISSUE" ""
    printf "${BLUE}║${RESET}  ${RED}Failed${RESET}     : ${RED}%-4d${RESET}%-36s${BLUE}║${RESET}\n"    "$CNT_FAILED"   ""
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
🖥 Server: <code>$(hostname -s)</code>  Workers: ${PARALLEL_JOBS}
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
# process_domains — SCAN → DISPATCH → COLLECT
###############################################################################
process_domains() {
    local filter_users=("$@")

    # ════════════════════════════════════════════════════════════
    # PHASE 0: Build maps
    # ════════════════════════════════════════════════════════════
    echo ""
    echo -e "${CYAN}  ⟳  กำลังสแกน domain...${RESET}"

    build_parked_alias_map
    build_addon_domains_map "${filter_users[@]}"

    # สร้าง ALIAS_TODO
    declare -A _ALIAS_TODO=()
    for _ad in "${!G_PARKED_PARENT[@]}"; do
        local _acu="${G_PARKED_USER[$_ad]}"
        if [[ ${#filter_users[@]} -gt 0 ]]; then
            local _m=0
            for _u in "${filter_users[@]}"; do [[ "$_acu" == "$_u" ]] && _m=1 && break; done
            [[ $_m -eq 0 ]] && continue
        fi
        _ALIAS_TODO["$_ad"]="${_acu}|${G_PARKED_PARENT[$_ad]}"
    done

    # ════════════════════════════════════════════════════════════
    # PHASE 1: SCAN — หา wp_path, แยก jobs + skips
    # ════════════════════════════════════════════════════════════
    local -a addon_jobs=()   # "domain|cpuser|wp_path|label"
    local -a addon_skips=()  # "domain|cpuser|reason"
    local -a alias_jobs=()
    local -a alias_skips=()

    # Scan addon domains
    for _domain in $(printf '%s\n' "${!G_ADDON_DOMAINS[@]}" | sort); do
        local _cpu="${G_ADDON_DOMAINS[$_domain]}"
        local _wpp=""
        find_wp_path "$_domain" "$_cpu" _wpp
        if [[ -z "$_wpp" ]]; then
            addon_skips+=("${_domain}|${_cpu}|no wp-config.php")
        else
            addon_jobs+=("${_domain}|${_cpu}|${_wpp}|${_domain}")
        fi
    done

    # Scan parked/alias domains
    for _alias in $(printf '%s\n' "${!_ALIAS_TODO[@]}" | sort); do
        IFS='|' read -r _acu _par <<< "${_ALIAS_TODO[$_alias]}"
        local _wpp=""
        find_wp_path_for_parent "$_par" "$_acu" _wpp
        local _label="${_alias}  →  ${_par}"
        if [[ -z "$_wpp" ]]; then
            alias_skips+=("${_alias}|${_acu}|no parent wp-config.php")
        else
            # ส่ง alias domain name เป็น wp_url (ไม่ใช่ parent)
            alias_jobs+=("${_alias}|${_acu}|${_wpp}|${_label}")
        fi
    done

    # คำนวณ totals
    CNT_SKIP=$(( ${#addon_skips[@]} + ${#alias_skips[@]} ))
    local _addon_total=${#addon_jobs[@]}
    local _alias_total=${#alias_jobs[@]}
    CNT_TOTAL=$(( _addon_total + _alias_total + CNT_SKIP ))
    CNT_SUCCESS=0; CNT_FAILED=0; CNT_CF_ISSUE=0

    echo -e "  ${GREEN}✔${RESET}  Addon domains   : ${WHITE}${_addon_total}${RESET}  (${#addon_skips[@]} skip)"
    echo -e "  ${GREEN}✔${RESET}  Parked/Alias    : ${WHITE}${_alias_total}${RESET}  (${#alias_skips[@]} skip)"
    echo -e "  ${GREEN}✔${RESET}  รวมทั้งหมด      : ${WHITE}${CNT_TOTAL}${RESET}  (${PARALLEL_JOBS} workers)"
    echo ""

    # ════════════════════════════════════════════════════════════
    # PHASE 2: Setup TMP_DIR + Log
    # ════════════════════════════════════════════════════════════
    TMP_DIR=$(mktemp -d "/tmp/lspurge_$$_XXXXXX")
    printf '0' > "${TMP_DIR}/.completed"
    touch "${TMP_DIR}/.print_lock"

    log_init
    log "Filter users  : ${filter_users[*]:-ALL}"
    log "Addon jobs    : $_addon_total  (skip: ${#addon_skips[@]})"
    log "Alias jobs    : $_alias_total  (skip: ${#alias_skips[@]})"
    log "Total         : $CNT_TOTAL  |  Workers: $PARALLEL_JOBS"
    log ""

    # ════════════════════════════════════════════════════════════
    # PHASE 3: DISPATCH + COLLECT — Addon Domains
    # ════════════════════════════════════════════════════════════
    if [[ $(( _addon_total + ${#addon_skips[@]} )) -gt 0 ]]; then
        echo -e "${BLUE}━━━  Addon Domains  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        log "=== Addon Domains ==="

        # Print skips ก่อน (synchronous ไม่มี race)
        for _s in "${addon_skips[@]}"; do
            IFS='|' read -r _d _c _r <<< "$_s"
            printf "  %-55s  ${YELLOW}⊘ SKIP${RESET}\n" "$_d"
            log "[SKIP]     $_d ($_c) | $_r"
        done

        # Dispatch addon jobs
        if [[ $_addon_total -gt 0 ]]; then
            _dispatch_section "$_addon_total" "${addon_jobs[@]}"
        fi

        # Collect addon results (job_id 1 ถึง _addon_total)
        _collect_section 1 "$_addon_total"
    fi

    # ════════════════════════════════════════════════════════════
    # PHASE 3: DISPATCH + COLLECT — Parked/Alias Domains
    # ════════════════════════════════════════════════════════════
    if [[ $(( _alias_total + ${#alias_skips[@]} )) -gt 0 ]]; then
        echo ""
        echo -e "${BLUE}━━━  Parked / Alias Domains  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        log ""
        log "=== Parked/Alias Domains ==="

        # Print skips
        for _s in "${alias_skips[@]}"; do
            IFS='|' read -r _d _c _r <<< "$_s"
            printf "  %-55s  ${YELLOW}⊘ SKIP${RESET}\n" "$_d"
            log "[SKIP]     $_d ($_c) | $_r"
        done

        # Dispatch alias jobs (job_id reset ในแต่ละ section, TMP_DIR ใช้ job_id ร่วมกัน)
        # ⚠️ _dispatch_section สร้าง job_id ใหม่เริ่มต้น 1 ทุก section
        #    ต้องเปลี่ยนเป็น offset เพื่อไม่ชนกับ addon job dirs
        if [[ $_alias_total -gt 0 ]]; then
            _dispatch_section_offset "$_addon_total" "$_alias_total" "${alias_jobs[@]}"
        fi

        # Collect alias results (job_id _addon_total+1 ถึง total_jobs)
        local _total_jobs=$(( _addon_total + _alias_total ))
        _collect_section $(( _addon_total + 1 )) "$_total_jobs"
    fi

    _print_summary
    send_telegram
}

###############################################################################
# _dispatch_section_offset — เหมือน _dispatch_section แต่มี job_id offset
# ใช้กับ parked/alias เพื่อไม่ให้ job_id ชนกับ addon section
#
# Args: $1=offset  $2=section_total  $3..N=entries
###############################################################################
_dispatch_section_offset() {
    local offset="$1" section_total="$2"
    shift 2
    local -a entries=("$@")

    # Reset completion counter
    printf '0' > "${TMP_DIR}/.completed"

    local -a pids=()
    local job_id=0

    for entry in "${entries[@]}"; do
        IFS='|' read -r domain cpuser wp_path label <<< "$entry"
        (( job_id++ ))
        local global_id=$(( offset + job_id ))

        _do_purge_job "$global_id" "$domain" "$cpuser" "$wp_path" \
            "$domain" "$label" "$section_total" &
        pids+=($!)

        while [[ ${#pids[@]} -ge $PARALLEL_JOBS ]]; do
            wait -n 2>/dev/null || true
            local _np=()
            for _p in "${pids[@]}"; do
                kill -0 "$_p" 2>/dev/null && _np+=("$_p")
            done
            pids=("${_np[@]}")
        done
    done

    [[ ${#pids[@]} -gt 0 ]] && wait "${pids[@]}" 2>/dev/null
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

build_main_domains_map

declare -a ALL_CPANEL_USERS=()
get_all_cpanel_users ALL_CPANEL_USERS

case "$MODE" in
    1)
        print_header
        echo -e "${WHITE}${BOLD}[ Mode 1 ]  Purge All — ทุก cPanel account${RESET}"
        echo ""
        echo -e "${CYAN}cPanel accounts ที่มีในระบบ (${#ALL_CPANEL_USERS[@]} accounts):${RESET}"
        echo ""
        for u in "${ALL_CPANEL_USERS[@]}"; do echo -e "  ${GREEN}•${RESET}  $u"; done
        echo ""
        printf "${YELLOW}ยืนยันการ Purge ทุก cPanel ข้างบน? [y/N]: ${RESET}"
        read -r CONFIRM
        [[ "${CONFIRM,,}" != "y" ]] && echo -e "${RED}ยกเลิก${RESET}" && exit 0
        process_domains
        ;;

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
                _idx=$(( sel - 1 ))
                if [[ $_idx -ge 0 && $_idx -lt ${#ALL_CPANEL_USERS[@]} ]]; then
                    SELECTED_USERS+=("${ALL_CPANEL_USERS[$_idx]}")
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
        for u in "${SELECTED_USERS[@]}"; do echo -e "  ${GREEN}✔${RESET}  $u"; done
        echo ""
        printf "${YELLOW}ยืนยัน? [y/N]: ${RESET}"
        read -r CONFIRM2
        [[ "${CONFIRM2,,}" != "y" ]] && echo -e "${RED}ยกเลิก${RESET}" && exit 0

        process_domains "${SELECTED_USERS[@]}"
        ;;

    *)
        echo -e "${RED}[ERROR]${RESET} กรุณาเลือก 1 หรือ 2"; exit 1
        ;;
esac
