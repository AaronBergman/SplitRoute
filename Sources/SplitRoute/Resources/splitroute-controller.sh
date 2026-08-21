#!/bin/zsh

# SplitRoute's complete privileged surface. The app may only invoke "enable"
# through macOS authorization or create the unprivileged stop marker. Interface
# names and addresses are always discovered here rather than accepted as input.

set -u

CONTROLLER_VERSION=2

COMMAND="${1:-}"
CALLER_UID="${2:-}"
SCRIPT_PATH="${0:A}"

if [[ ! "$CALLER_UID" =~ '^[0-9]+$' ]]; then
    print -u2 -- "A numeric caller uid is required."
    exit 64
fi

STATE_DIR="/private/tmp/splitroute-${CALLER_UID}"
STATUS_FILE="${STATE_DIR}/status"
INTENT_FILE="${STATE_DIR}/intent"
STOP_FILE="${STATE_DIR}/stop.request"
REPAIR_FILE="${STATE_DIR}/repair.request"
ORDER_FILE="${STATE_DIR}/service-order.previous"
TOKEN_FILE="${STATE_DIR}/pf.token"
SIGNATURE_FILE="${STATE_DIR}/network.signature"
PID_FILE="${STATE_DIR}/watchdog.pid"
VERSION_FILE="${STATE_DIR}/controller.version"
PF_FILE="${STATE_DIR}/splitroute.pf.conf"

function prepare_state_directory() {
    /usr/bin/install -d -o root -g wheel -m 1777 "$STATE_DIR"
}

function archive_file() {
    local file="$1"
    if [[ -e "$file" ]]; then
        /bin/mv -f "$file" "${file}.consumed.$(/bin/date +%s)" 2>/dev/null || true
    fi
}

function write_status() {
    local value="$1"
    local temporary="${STATUS_FILE}.new.$$"
    print -r -- "$value" > "$temporary"
    /usr/sbin/chown root:wheel "$temporary" 2>/dev/null || true
    /bin/chmod 0644 "$temporary"
    /bin/mv -f "$temporary" "$STATUS_FILE"
}

function wifi_device() {
    /usr/sbin/networksetup -listallhardwareports | /usr/bin/awk '
        /^Hardware Port: (Wi-Fi|AirPort)$/ { found = 1; next }
        found && /^Device: / { print $2; exit }
    '
}

function service_for_device() {
    local wanted="$1"
    /usr/sbin/networksetup -listnetworkserviceorder | /usr/bin/awk -v device="$wanted" '
        /^\([0-9]+\) / {
            service = $0
            sub(/^\([0-9]+\) /, "", service)
            sub(/^\*/, "", service)
        }
        $0 ~ "Device: " device "\\)" { print service; exit }
    '
}

function ordered_services() {
    /usr/sbin/networksetup -listnetworkserviceorder | /usr/bin/awk '
        /^\([0-9]+\) / {
            service = $0
            sub(/^\([0-9]+\) /, "", service)
            sub(/^\*/, "", service)
            print service
        }
    '
}

function interface_values() {
    local device="$1"
    /sbin/ifconfig "$device" 2>/dev/null | /usr/bin/awk '
        /inet / { print $2 "|" $4; exit }
    '
}

function interface_is_active() {
    /sbin/ifconfig "$1" 2>/dev/null | /usr/bin/grep -q 'status: active'
}

function ipv4_to_integer() {
    local ip="$1"
    local a b c d
    IFS='.' read -r a b c d <<< "$ip"
    print -- $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

function integer_to_ipv4() {
    local value="$1"
    print -- "$(( (value >> 24) & 255 )).$(( (value >> 16) & 255 )).$(( (value >> 8) & 255 )).$(( value & 255 ))"
}

function same_subnet() {
    local first_ip="$1"
    local first_mask="$2"
    local second_ip="$3"
    local second_mask="$4"
    [[ "$first_mask" == "$second_mask" ]] || return 1

    local mask_value=$(( first_mask ))
    local first_value="$(ipv4_to_integer "$first_ip")"
    local second_value="$(ipv4_to_integer "$second_ip")"
    (( (first_value & mask_value) == (second_value & mask_value) ))
}

function cidr_for() {
    local ip="$1"
    local mask="$2"
    local ip_value="$(ipv4_to_integer "$ip")"
    local mask_value=$(( mask ))
    local network_value=$(( ip_value & mask_value ))
    local prefix=0
    local bit=31
    while (( bit >= 0 )); do
        if (( (mask_value & (1 << bit)) != 0 )); then
            (( prefix += 1 ))
        else
            break
        fi
        (( bit -= 1 ))
    done
    print -- "$(integer_to_ipv4 "$network_value")/${prefix}"
}

function default_gateway() {
    /sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway: / { print $2; exit }'
}

function ethernet_values() {
    local wifi="$1"
    local wifi_ip="$2"
    local wifi_mask="$3"
    local port device values address mask

    while IFS='|' read -r port device; do
        [[ -n "$device" && "$device" != "$wifi" ]] || continue
        interface_is_active "$device" || continue
        values="$(interface_values "$device")"
        [[ -n "$values" ]] || continue
        address="${values%%|*}"
        mask="${values##*|}"
        [[ "$address" != 169.254.* ]] || continue
        same_subnet "$wifi_ip" "$wifi_mask" "$address" "$mask" || continue
        print -r -- "${port}|${device}|${address}|${mask}"
        return 0
    done < <(
        /usr/sbin/networksetup -listallhardwareports | /usr/bin/awk '
            /^Hardware Port: / {
                port = $0
                sub(/^Hardware Port: /, "", port)
            }
            /^Device: / {
                device = $2
                lower = tolower(port)
                if (lower ~ /ethernet|lan|thunderbolt/) {
                    print port "|" device
                }
            }
        '
    )
    return 1
}

function collect_network() {
    WIFI_DEVICE="$(wifi_device)"
    [[ -n "$WIFI_DEVICE" ]] || return 1
    interface_is_active "$WIFI_DEVICE" || return 1

    local wifi_values="$(interface_values "$WIFI_DEVICE")"
    [[ -n "$wifi_values" ]] || return 1
    WIFI_IP="${wifi_values%%|*}"
    WIFI_MASK="${wifi_values##*|}"
    WIFI_SERVICE="$(service_for_device "$WIFI_DEVICE")"
    [[ -n "$WIFI_SERVICE" ]] || return 1

    local ethernet="$(ethernet_values "$WIFI_DEVICE" "$WIFI_IP" "$WIFI_MASK")"
    [[ -n "$ethernet" ]] || return 1
    ETHERNET_PORT="${ethernet%%|*}"
    local remainder="${ethernet#*|}"
    ETHERNET_DEVICE="${remainder%%|*}"
    remainder="${remainder#*|}"
    ETHERNET_IP="${remainder%%|*}"
    ETHERNET_MASK="${remainder##*|}"

    GATEWAY="$(default_gateway)"
    [[ -n "$GATEWAY" ]] || return 1
    NETWORK_CIDR="$(cidr_for "$WIFI_IP" "$WIFI_MASK")"
    NETWORK_SIGNATURE="${WIFI_DEVICE}|${WIFI_IP}|${WIFI_MASK}|${ETHERNET_DEVICE}|${ETHERNET_IP}|${GATEWAY}|${NETWORK_CIDR}"
    return 0
}

function save_service_order() {
    if [[ ! -s "$ORDER_FILE" ]]; then
        ordered_services > "$ORDER_FILE"
        /usr/sbin/chown root:wheel "$ORDER_FILE" 2>/dev/null || true
        /bin/chmod 0644 "$ORDER_FILE"
    fi
}

function put_wifi_first() {
    local -a current desired
    current=("${(@f)$(ordered_services)}")
    desired=("$WIFI_SERVICE")
    local service
    for service in "${current[@]}"; do
        [[ "$service" == "$WIFI_SERVICE" ]] || desired+=("$service")
    done
    (( ${#desired[@]} > 0 )) || return 1
    /usr/sbin/networksetup -ordernetworkservices "${desired[@]}" >/dev/null
}

function wifi_is_primary() {
    [[ "$(ordered_services | /usr/bin/head -n 1)" == "$WIFI_SERVICE" ]]
}

function restore_service_order() {
    [[ -s "$ORDER_FILE" ]] || return 0
    local -a previous
    previous=("${(@f)$(<"$ORDER_FILE")}")
    (( ${#previous[@]} > 0 )) || return 0
    /usr/sbin/networksetup -ordernetworkservices "${previous[@]}" >/dev/null 2>&1 || return 1
}

function build_pf_configuration() {
    /bin/cp /etc/pf.conf "$PF_FILE"
    {
        print -- ""
        print -- "# SplitRoute: keep LAN, multicast, broadcast, and link-local traffic local."
        print -- "pass out quick on ${WIFI_DEVICE} inet to { ${NETWORK_CIDR}, 224.0.0.0/4, 255.255.255.255/32, 169.254.0.0/16 }"
        print -- "# SplitRoute: retain the Wi-Fi source address while sending IPv4 frames via Ethernet."
        print -- "pass out quick on ${WIFI_DEVICE} route-to (${ETHERNET_DEVICE} ${GATEWAY}) inet from ${WIFI_IP} to any keep state"
    } >> "$PF_FILE"
    /usr/sbin/chown root:wheel "$PF_FILE" 2>/dev/null || true
    /bin/chmod 0600 "$PF_FILE"
    /sbin/pfctl -nf "$PF_FILE" >/dev/null
}

function acquire_pf_token() {
    if [[ -s "$TOKEN_FILE" ]] && pf_is_enabled; then
        return 0
    fi
    [[ ! -e "$TOKEN_FILE" ]] || archive_file "$TOKEN_FILE"
    local output token
    output="$(/sbin/pfctl -E 2>&1)" || return 1
    token="$(print -r -- "$output" | /usr/bin/awk '/Token :/ { print $3; exit }')"
    [[ -n "$token" ]] || return 1
    print -r -- "$token" > "$TOKEN_FILE"
    /usr/sbin/chown root:wheel "$TOKEN_FILE" 2>/dev/null || true
    /bin/chmod 0600 "$TOKEN_FILE"
}

function pf_is_enabled() {
    /sbin/pfctl -s info 2>/dev/null | /usr/bin/grep -q '^Status: Enabled'
}

function split_rule_is_loaded() {
    local rules
    rules="$(/sbin/pfctl -sr 2>/dev/null)" || return 1
    print -r -- "$rules" | /usr/bin/grep -Fq "route-to (${ETHERNET_DEVICE} ${GATEWAY})" || return 1
    print -r -- "$rules" | /usr/bin/grep -Fq "from ${WIFI_IP}" || return 1
}

function runtime_is_healthy() {
    wifi_is_primary && pf_is_enabled && split_rule_is_loaded
}

function release_pf_token() {
    [[ -s "$TOKEN_FILE" ]] || return 0
    local token="$(<"$TOKEN_FILE")"
    /sbin/pfctl -X "$token" >/dev/null 2>&1 || true
    archive_file "$TOKEN_FILE"
}

function load_stock_rules() {
    /sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
}

function apply_split() {
    collect_network || return 1
    save_service_order || return 1
    put_wifi_first || return 1
    # Service-order changes can replace the default route. Re-read every value
    # before rendering rules so the loaded signature describes current reality.
    collect_network || return 1
    build_pf_configuration || return 1
    /sbin/pfctl -f "$PF_FILE" >/dev/null || return 1
    acquire_pf_token || return 1
    print -r -- "$NETWORK_SIGNATURE" > "$SIGNATURE_FILE"
    /usr/sbin/chown root:wheel "$SIGNATURE_FILE" 2>/dev/null || true
    /bin/chmod 0644 "$SIGNATURE_FILE"
    return 0
}

function finish_disable() {
    write_status "disabling"
    load_stock_rules
    restore_service_order || true
    release_pf_token
    archive_file "$INTENT_FILE"
    archive_file "$STOP_FILE"
    archive_file "$REPAIR_FILE"
    archive_file "$ORDER_FILE"
    archive_file "$PID_FILE"
    archive_file "$VERSION_FILE"
    archive_file "$SIGNATURE_FILE"
    write_status "off"
}

function run_watchdog() {
    print -r -- "$CONTROLLER_VERSION" > "$VERSION_FILE"
    /usr/sbin/chown root:wheel "$VERSION_FILE" 2>/dev/null || true
    /bin/chmod 0644 "$VERSION_FILE"

    print -r -- "$$" > "$PID_FILE"
    /usr/sbin/chown root:wheel "$PID_FILE" 2>/dev/null || true
    /bin/chmod 0644 "$PID_FILE"

    local health_tick=0
    while true; do
        if [[ -e "$STOP_FILE" || ! -e "$INTENT_FILE" ]]; then
            finish_disable
            return 0
        fi

        local current_status=""
        [[ -s "$STATUS_FILE" ]] && current_status="$(<"$STATUS_FILE")"

        if ! collect_network; then
            if [[ "$current_status" != "waiting-for-ethernet" ]]; then
                load_stock_rules
                write_status "waiting-for-ethernet"
            fi
            /bin/sleep 1
            continue
        fi

        local loaded_signature=""
        [[ -s "$SIGNATURE_FILE" ]] && loaded_signature="$(<"$SIGNATURE_FILE")"
        local needs_repair=0
        if [[ -e "$REPAIR_FILE" || "$loaded_signature" != "$NETWORK_SIGNATURE" || "$current_status" != "active" ]]; then
            needs_repair=1
        elif (( health_tick >= 5 )); then
            health_tick=0
            runtime_is_healthy || needs_repair=1
        fi

        if (( needs_repair )); then
            load_stock_rules
            if apply_split; then
                write_status "active"
                archive_file "$REPAIR_FILE"
            else
                load_stock_rules
                write_status "waiting-for-ethernet"
            fi
        fi
        (( health_tick += 1 ))
        /bin/sleep 1
    done
}

function start_enable() {
    if (( EUID != 0 )); then
        print -u2 -- "Enable must run with administrator privileges."
        return 77
    fi

    prepare_state_directory
    archive_file "$STOP_FILE"
    archive_file "$REPAIR_FILE"
    write_status "enabling"
    /usr/bin/touch "$INTENT_FILE"
    /usr/sbin/chown root:wheel "$INTENT_FILE"
    /bin/chmod 0644 "$INTENT_FILE"

    if ! apply_split; then
        load_stock_rules
        restore_service_order || true
        release_pf_token
        archive_file "$INTENT_FILE"
        write_status "error: prerequisites changed or pf rejected the generated rules"
        return 1
    fi
    write_status "active"

    /bin/cp "$SCRIPT_PATH" "${STATE_DIR}/controller.sh"
    /usr/sbin/chown root:wheel "${STATE_DIR}/controller.sh"
    /bin/chmod 0700 "${STATE_DIR}/controller.sh"

    /bin/zsh "${STATE_DIR}/controller.sh" watch "$CALLER_UID" \
        </dev/null > "${STATE_DIR}/watchdog.log" 2>&1 &!

    local attempt pid
    for attempt in {1..20}; do
        if [[ -s "$PID_FILE" ]]; then
            pid="$(<"$PID_FILE")"
            if [[ "$pid" =~ '^[0-9]+$' ]] && /bin/kill -0 "$pid" 2>/dev/null; then
                return 0
            fi
        fi
        /bin/sleep 0.1
    done

    load_stock_rules
    restore_service_order || true
    release_pf_token
    archive_file "$INTENT_FILE"
    write_status "error: the safety watchdog did not start; all routing changes were rolled back"
    return 1
}

function force_disable() {
    if (( EUID != 0 )); then
        print -u2 -- "Disable fallback must run with administrator privileges."
        return 77
    fi
    prepare_state_directory
    finish_disable
}

function diagnose() {
    if ! collect_network; then
        print -u2 -- "SplitRoute prerequisites are not currently satisfied."
        return 1
    fi
    print -- "Wi-Fi: ${WIFI_DEVICE} ${WIFI_IP} ${WIFI_MASK} (${WIFI_SERVICE})"
    print -- "Ethernet: ${ETHERNET_DEVICE} ${ETHERNET_IP} ${ETHERNET_MASK} (${ETHERNET_PORT})"
    print -- "Gateway: ${GATEWAY}"
    print -- "Subnet: ${NETWORK_CIDR}"
    print -- "Signature: ${NETWORK_SIGNATURE}"
}

case "$COMMAND" in
    enable)
        start_enable
        ;;
    disable)
        force_disable
        ;;
    watch)
        prepare_state_directory
        run_watchdog
        ;;
    diagnose)
        diagnose
        ;;
    *)
        print -u2 -- "Usage: splitroute-controller.sh {enable|disable|watch|diagnose} uid"
        exit 64
        ;;
esac
