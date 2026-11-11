# Sourced by mihomo-router. Device inventory is private, standard Mihomo YAML.
SSH_GATEWAY_ENABLED=${SSH_GATEWAY_ENABLED:-0}
SSH_GATEWAY_FILE=${SSH_GATEWAY_FILE:-$DATA_DIR/gateways/proxies.yaml}
SSH_GATEWAY_PRIVATE_KEY=${SSH_GATEWAY_PRIVATE_KEY:-$DATA_DIR/ssh/gateway_ed25519}
SSH_GATEWAY_CIDRS=${SSH_GATEWAY_CIDRS:-}
SSH_GATEWAY_DOMAINS=${SSH_GATEWAY_DOMAINS:-}
SSH_GATEWAY_DNS=${SSH_GATEWAY_DNS:-}
SSH_GATEWAY_DNS_PROXY=${SSH_GATEWAY_DNS_PROXY:-SSH-Gateway}
SSH_GATEWAY_API_SECRET=${SSH_GATEWAY_API_SECRET:-$CONTROLLER_SECRET}
JSONFILTER=${JSONFILTER:-jsonfilter}

gateway_settings() {
    [ "$SSH_GATEWAY_ENABLED" = 1 ] || { log 'SSH_GATEWAY_ENABLED must be 0 or 1'; return 1; }
    [ -r "$SSH_GATEWAY_FILE" ] || { log 'missing gateway inventory; run gateway init'; return 1; }
    case "$SSH_GATEWAY_FILE" in /*) ;; *) log 'gateway inventory path must be absolute'; return 1 ;; esac
    case "$SSH_GATEWAY_FILE$SSH_GATEWAY_DNS$SSH_GATEWAY_API_SECRET" in
        *"'"*|*'"'*|*\\*|*'
'*|*"$(printf '\r')"*) log 'unsupported quoting/control character in gateway settings'; return 1 ;;
    esac
    printf '%s\n' "$SSH_GATEWAY_CIDRS" | awk '
        { for (i=1;i<=NF;i++) {
            if (split($i, p, "/")!=2 || p[2]!~/^[0-9]+$/ || p[2]>32 ||
                split(p[1], a, ".")!=4) exit 1
            for (j=1;j<=4;j++) if (a[j]!~/^[0-9]+$/ || a[j]>255) exit 1
        }}' || { log 'gateway CIDRs must be IPv4 prefixes'; return 1; }
    case "$SSH_GATEWAY_DOMAINS" in *[!a-zA-Z0-9.\ -]*) log 'invalid gateway domain suffix'; return 1 ;; esac
    case "$SSH_GATEWAY_DNS_PROXY" in SSH-Gateway|DIRECT) ;; *) log 'SSH_GATEWAY_DNS_PROXY must be SSH-Gateway or DIRECT'; return 1 ;; esac
    for gateway_domain in $SSH_GATEWAY_DOMAINS; do
        case "$gateway_domain" in .*|*.|*..*|-*) log 'invalid gateway domain suffix'; return 1 ;; esac
    done
    [ -n "$SSH_GATEWAY_CIDRS$SSH_GATEWAY_DOMAINS" ] || { log 'configure explicit gateway CIDRs or domain suffixes'; return 1; }
    if [ -n "$SSH_GATEWAY_DOMAINS" ]; then
        case "$SSH_GATEWAY_DNS" in tcp://*|tls://*|https://*) ;; *) log 'domain routes require TCP/TLS/HTTPS SSH_GATEWAY_DNS'; return 1 ;; esac
        case "$SSH_GATEWAY_DNS" in *'#'*|*' '*|*'	'*) log 'gateway DNS must have no fragment or whitespace'; return 1 ;; esac
    fi
}

gateway_inventory_source_cidrs() {
    gateway_source_status=$(gateway_api 2>/dev/null || :)
    gateway_source_selected=$($JSONFILTER -s "$gateway_source_status" -e '@.now' 2>/dev/null || :)
    [ -n "$gateway_source_selected" ] || gateway_source_selected=$(gateway_inventory_first_name)
    awk -v target="$gateway_source_selected" '
        function clean(v) {
            sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v)
            if (v ~ /^\047.*\047$/) { sub(/^\047/, "", v); sub(/\047$/, "", v) }
            if (v ~ /^\042.*\042$/) { sub(/^\042/, "", v); sub(/\042$/, "", v) }
            return v
        }
        function ipv4(v, a, n, i) {
            n=split(v,a,"."); if (n!=4) return 0
            for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/ || a[i]>255) return 0
            return 1
        }
        /^  - name:/ { name=clean(substr($0,index($0,":")+1)); in_proxy=1; next }
        in_proxy && /^    server:/ {
            v=$0; sub(/^    server:[[:space:]]*/,"",v); v=clean(v)
            if(name==target && ipv4(v)) found=v "/32"
        }
        END { if(found!="") print found }
    ' "$SSH_GATEWAY_FILE"
}

gateway_effective_source_cidrs() {
    {
        printf '%s\n' "$BYPASS_SOURCE_CIDRS"
        [ "$SSH_GATEWAY_ENABLED" = 1 ] || return 0
        gateway_inventory_source_cidrs
    } | awk '{ for(i=1;i<=NF;i++) if(!seen[$i]++) print $i }'
}

gateway_inventory_name_exists() {
    awk -v target="$1" '
        function value(s) {
            sub(/^  - name:[[:space:]]*/, "", s); sub(/[[:space:]]+#.*$/, "", s)
            if(s ~ /^\047.*\047$/) { sub(/^\047/,"",s); sub(/\047$/,"",s) }
            if(s ~ /^\042.*\042$/) { sub(/^\042/,"",s); sub(/\042$/,"",s) }
            return s
        }
        /^  - name:/ && value($0)==target { found=1 }
        END { exit !found }
    ' "$SSH_GATEWAY_FILE"
}

gateway_inventory_count() {
    awk '/^  - name:/ { n++ } END { print n+0 }' "$SSH_GATEWAY_FILE"
}

gateway_inventory_first_name() {
    awk '
        /^  - name:/ {
            s=$0; sub(/^  - name:[[:space:]]*/, "", s); sub(/[[:space:]]+#.*$/, "", s)
            if(s ~ /^\047.*\047$/) { sub(/^\047/,"",s); sub(/\047$/,"",s) }
            if(s ~ /^\042.*\042$/) { sub(/^\042/,"",s); sub(/\042$/,"",s) }
            print s; exit
        }
    ' "$SSH_GATEWAY_FILE"
}

gateway_inventory_json() {
    awk '
        function clean(v) {
            sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+#.*$/, "", v); sub(/[[:space:]]+$/, "", v)
            if (v ~ /^\047.*\047$/) { sub(/^\047/, "", v); sub(/\047$/, "", v) }
            if (v ~ /^\042.*\042$/) { sub(/^\042/, "", v); sub(/\042$/, "", v) }
            return v
        }
        function esc(v) { gsub(/\\/, "\\\\", v); gsub(/\042/, "\\\042", v); return v }
        function emit() {
            if(!have) return
            if(count++) printf ","
            printf "{\042name\042:\042%s\042,\042server\042:\042%s\042,\042port\042:%s,\042username\042:\042%s\042}", esc(name), esc(server), port, esc(username)
        }
        /^  - name:/ { emit(); have=1; name=clean(substr($0,index($0,":")+1)); server=""; port="0"; username=""; next }
        have && /^    server:/ { server=clean(substr($0,index($0,":")+1)); next }
        have && /^    port:/ { port=clean(substr($0,index($0,":")+1)); next }
        have && /^    username:/ { username=clean(substr($0,index($0,":")+1)); next }
        END { emit(); print "" }
    ' "$SSH_GATEWAY_FILE" | awk 'BEGIN { printf "{\042devices\042:[" } { if(NR>1) printf "\n"; printf "%s", $0 } END { printf "]}\n" }'
}

gateway_validate_name() {
    awk -v value="$1" 'BEGIN { exit !(length(value)>0 && length(value)<=48 && value ~ /^[A-Za-z0-9]([A-Za-z0-9_. -]*[A-Za-z0-9])?$/) }'
}

gateway_validate_ipv4() {
    awk -v value="$1" 'BEGIN { n=split(value,a,"."); if(n!=4) exit 1; for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/ || a[i]>255) exit 1 }'
}

gateway_mutation_cleanup() {
    gateway_mutation_rc=$?
    trap - 0
    if [ "$gateway_mutation_changed" = 1 ]; then
        if [ -n "$gateway_mutation_backup" ] && [ -r "$gateway_mutation_backup" ]; then
            cp "$gateway_mutation_backup" "$SSH_GATEWAY_FILE" 2>/dev/null || :
            chmod 600 "$SSH_GATEWAY_FILE" 2>/dev/null || :
            /data/mihomo-router/bin/mihomo-router-boot restart >/dev/null 2>&1 || :
            if [ -n "$gateway_mutation_old_selected" ]; then
                gateway_api -X PUT -H 'Content-Type: application/json' --data '{"name":"'"$gateway_mutation_old_selected"'"}' >/dev/null 2>&1 || :
                firewall_up >/dev/null 2>&1 || :
            fi
        fi
    fi
    [ -z "$gateway_mutation_candidate" ] || rm -f "$gateway_mutation_candidate"
    [ -z "$gateway_mutation_check" ] || rm -f "$gateway_mutation_check"
    [ -z "$gateway_mutation_backup" ] || rm -f "$gateway_mutation_backup"
    [ -z "$gateway_mutation_key_check" ] || rm -f "$gateway_mutation_key_check"
    [ -z "$gateway_mutation_lock" ] || rmdir "$gateway_mutation_lock" 2>/dev/null || :
    exit "$gateway_mutation_rc"
}

gateway_mutate() (
    gateway_mutation_action=$1
    gateway_mutation_name=$2
    gateway_mutation_selected=
    gateway_mutation_old_selected=
    gateway_mutation_changed=0
    gateway_mutation_candidate=
    gateway_mutation_check=
    gateway_mutation_backup=
    gateway_mutation_key_check=
    gateway_mutation_lock=
    trap 'gateway_mutation_cleanup' 0
    [ "$SSH_GATEWAY_ENABLED" = 1 ] || die 'SSH gateway is disabled'
    gateway_settings || die 'invalid SSH gateway settings'
    ensure_dirs
    gateway_mutation_lock=$RUN_DIR/gateway-inventory.lock
    if ! mkdir "$gateway_mutation_lock" 2>/dev/null; then
        gateway_mutation_lock=
        die 'another gateway inventory change is in progress'
    fi
    gateway_mutation_status=$(gateway_api) || die 'gateway API unavailable; cannot preserve current selection'
    gateway_mutation_selected=$($JSONFILTER -s "$gateway_mutation_status" -e '@.now' 2>/dev/null || :)
    [ -n "$gateway_mutation_selected" ] || gateway_mutation_selected=$(gateway_inventory_first_name)
    gateway_mutation_old_selected=$gateway_mutation_selected
    gateway_mutation_candidate=$(mktemp "$SSH_GATEWAY_FILE.candidate.XXXXXX") || die 'cannot stage gateway inventory'
    gateway_mutation_backup=$(mktemp "$SSH_GATEWAY_FILE.rollback.XXXXXX") || die 'cannot save gateway inventory rollback copy'
    cp "$SSH_GATEWAY_FILE" "$gateway_mutation_backup" || die 'cannot copy gateway inventory'
    chmod 600 "$gateway_mutation_backup"
    if [ "$gateway_mutation_action" = add ]; then
        gateway_mutation_server=$3
        gateway_mutation_port=$4
        gateway_mutation_username=$5
        gateway_mutation_host_key=$6
        gateway_inventory_name_exists "$gateway_mutation_name" && die 'a device with this alias already exists'
        gateway_validate_name "$gateway_mutation_name" || die 'alias must be 1-48 letters, numbers, spaces, dot, underscore or dash; start and end with a letter or number'
        gateway_validate_ipv4 "$gateway_mutation_server" || die 'device server must be a static IPv4 address'
        case "$gateway_mutation_port" in ''|*[!0-9]*) die 'SSH port must be a number from 1 to 65535' ;; esac
        [ "$gateway_mutation_port" -ge 1 ] && [ "$gateway_mutation_port" -le 65535 ] || die 'SSH port must be a number from 1 to 65535'
        case "$gateway_mutation_username" in ''|*[!a-zA-Z0-9_.@-]*) die 'invalid SSH username' ;; esac
        [ "${#gateway_mutation_username}" -le 64 ] || die 'SSH username is too long'
        case "$gateway_mutation_host_key" in ssh-ed25519\ *) ;; *) die 'host key must be an ssh-ed25519 public key' ;; esac
        gateway_mutation_key_data=${gateway_mutation_host_key#* }
        gateway_mutation_key_data=${gateway_mutation_key_data%% *}
        case "$gateway_mutation_key_data" in ''|*[!A-Za-z0-9+/=]*) die 'invalid Ed25519 host key data' ;; esac
        gateway_mutation_key_check=$(mktemp "$RUN_DIR/gateway-host-key.XXXXXX") || die 'cannot validate host key'
        if command -v ssh-keygen >/dev/null 2>&1; then
            printf 'ssh-ed25519 %s\n' "$gateway_mutation_key_data" >"$gateway_mutation_key_check"
            ssh-keygen -lf "$gateway_mutation_key_check" 2>/dev/null | grep -q 'ED25519' || die 'host key is not a valid Ed25519 public key'
        elif command -v base64 >/dev/null 2>&1 && command -v od >/dev/null 2>&1; then
            printf '%s' "$gateway_mutation_key_data" | base64 -d >"$gateway_mutation_key_check" 2>/dev/null || die 'invalid Ed25519 host key encoding'
            [ "$(wc -c <"$gateway_mutation_key_check" | tr -d ' ')" -eq 51 ] || die 'host key has an invalid Ed25519 length'
            gateway_mutation_key_header=$(od -An -tx1 -N15 "$gateway_mutation_key_check" | tr -d '[:space:]')
            [ "$gateway_mutation_key_header" = 0000000b7373682d65643235353139 ] || die 'host key is not an Ed25519 key'
        else
            die 'router needs ssh-keygen or base64 and od to validate an Ed25519 host key'
        fi
        gateway_mutation_private_key=$(awk '
            /^  - name:/ { in_proxy=1; next }
            in_proxy && /^    private-key:/ {
                s=$0; sub(/^    private-key:[[:space:]]*/,"",s); sub(/[[:space:]]+#.*$/, "", s)
                if(s ~ /^\047.*\047$/) { sub(/^\047/,"",s); sub(/\047$/,"",s) }
                if(s ~ /^\042.*\042$/) { sub(/^\042/,"",s); sub(/\042$/,"",s) }
                print s; exit
            }
        ' "$SSH_GATEWAY_FILE")
        [ -n "$gateway_mutation_private_key" ] || gateway_mutation_private_key=$SSH_GATEWAY_PRIVATE_KEY
        case "$gateway_mutation_private_key" in /*) ;; *) die 'gateway private key path must be absolute' ;; esac
        case "$gateway_mutation_private_key" in *\\*|*"'"*) die 'unsupported characters in gateway private key path' ;; esac
        [ -r "$gateway_mutation_private_key" ] || die 'router SSH private key is missing or unreadable'
        [ -r "$gateway_mutation_private_key" ] || die 'router SSH private key is missing or unreadable'
        awk '/^proxies:[[:space:]]*\[\][[:space:]]*(#.*)?$/ { print "proxies:"; next } { print }' "$SSH_GATEWAY_FILE" >"$gateway_mutation_candidate" || die 'cannot stage gateway inventory'
        printf "  - name: '%s'\n    type: ssh\n    server: %s\n    port: %s\n    username: %s\n    private-key: '%s'\n    host-key-algorithms:\n      - ssh-ed25519\n    host-key:\n      - 'ssh-ed25519 %s'\n" \
            "$gateway_mutation_name" "$gateway_mutation_server" "$gateway_mutation_port" \
            "$gateway_mutation_username" "$gateway_mutation_private_key" "$gateway_mutation_key_data" >>"$gateway_mutation_candidate" || die 'cannot append gateway inventory'
    else
        gateway_validate_name "$gateway_mutation_name" || die 'invalid device alias'
        gateway_inventory_name_exists "$gateway_mutation_name" || die 'device alias not found'
        [ "$(gateway_inventory_count)" -gt 1 ] || die 'cannot remove the last gateway device'
        awk -v target="$gateway_mutation_name" '
            function name(s) {
                sub(/^  - name:[[:space:]]*/, "", s); sub(/[[:space:]]+#.*$/, "", s)
                if(s ~ /^\047.*\047$/) { sub(/^\047/,"",s); sub(/\047$/,"",s) }
                if(s ~ /^\042.*\042$/) { sub(/^\042/,"",s); sub(/\042$/,"",s) }
                return s
            }
            /^  - name:/ { removing=(name($0)==target); if(removing) { removed++; next } }
            removing && /^    / { next }
            removing && /^[[:space:]]*$/ { next }
            { removing=0; print }
            END { if(removed!=1) exit 1 }
        ' "$SSH_GATEWAY_FILE" >"$gateway_mutation_candidate" || die 'could not remove exactly one device from inventory'
    fi
    chmod 600 "$gateway_mutation_candidate"
    gateway_mutation_check=$(mktemp "$RUN_DIR/gateway-mutation-check.XXXXXX") || die 'cannot validate staged gateway config'
    gateway_mutation_old_file=$SSH_GATEWAY_FILE
    SSH_GATEWAY_FILE=$gateway_mutation_candidate
    if ! normalize_config "$ACTIVE_CONFIG" "$gateway_mutation_check" || ! validate_config "$gateway_mutation_check"; then
        SSH_GATEWAY_FILE=$gateway_mutation_old_file
        die 'gateway inventory change failed configuration validation'
    fi
    SSH_GATEWAY_FILE=$gateway_mutation_old_file
    mv "$gateway_mutation_candidate" "$SSH_GATEWAY_FILE" || die 'cannot activate gateway inventory'
    gateway_mutation_candidate=
    gateway_mutation_changed=1
    /data/mihomo-router/bin/mihomo-router-boot restart || die 'router restart failed; restoring the previous gateway inventory'
    if [ "$gateway_mutation_action" = remove ] && [ "$gateway_mutation_name" = "$gateway_mutation_selected" ]; then
        gateway_mutation_selected=$(gateway_inventory_first_name)
    fi
    gateway_api -X PUT -H 'Content-Type: application/json' --data '{"name":"'"$gateway_mutation_selected"'"}' >/dev/null || die 'could not restore a valid current gateway selection'
    firewall_up || die 'could not synchronize loop-prevention rules after gateway inventory update'
    gateway_mutation_status=$(gateway_api) || die 'gateway API unavailable after inventory update'
    gateway_mutation_all=$($JSONFILTER -s "$gateway_mutation_status" -e '@.all[*]' 2>/dev/null || :)
    printf '%s\n' "$gateway_mutation_all" | grep -Fx "$gateway_mutation_selected" >/dev/null || die 'selected gateway is missing from the running selector'
    if [ "$gateway_mutation_action" = add ]; then
        printf '%s\n' "$gateway_mutation_all" | grep -Fx "$gateway_mutation_name" >/dev/null || die 'new gateway is missing from the running selector'
        printf 'Added SSH gateway device: %s (connectivity was not probed)\n' "$gateway_mutation_name"
    else
        if printf '%s\n' "$gateway_mutation_all" | grep -Fx "$gateway_mutation_name" >/dev/null; then
            die 'removed gateway is still present in the running selector'
        fi
        printf 'Removed SSH gateway device: %s\n' "$gateway_mutation_name"
    fi
    gateway_mutation_changed=0
)

gateway_api_request() (
    gateway_api_path=$1
    shift
    ensure_dirs
    # Keep API authentication out of process arguments and inherited proxies.
    gateway_curl_config=$(mktemp "$RUN_DIR/gateway-curl.XXXXXX") || return 1
    trap 'rm -f "$gateway_curl_config"' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    chmod 600 "$gateway_curl_config"
    case "$SSH_GATEWAY_API_SECRET" in *'"'*|*\\*|*'
'*|*"$(printf '\r')"*) rm -f "$gateway_curl_config"; die 'invalid API secret' ;; esac
    if [ -n "$SSH_GATEWAY_API_SECRET" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$SSH_GATEWAY_API_SECRET" >"$gateway_curl_config"
    fi
    "$CURL" --config "$gateway_curl_config" --noproxy '*' -fsS --connect-timeout 3 --max-time 10 "$@" \
        "http://$CONTROLLER_ADDRESS$gateway_api_path"
    gateway_api_rc=$?
    rm -f "$gateway_curl_config"
    return "$gateway_api_rc"
)

gateway_api() {
    gateway_api_request /proxies/SSH-Gateway "$@"
}

gateway_select_cleanup() {
    gateway_select_rc=$?
    trap - 0
    if [ "$gateway_select_committed" != 1 ] && [ "$gateway_select_changed" = 1 ]; then
        if [ -n "$gateway_select_old" ]; then
            gateway_api -X PUT -H 'Content-Type: application/json' --data '{"name":"'"$gateway_select_old"'"}' >/dev/null 2>&1 || :
        fi
        if [ "$gateway_select_runtime_installed" = 1 ] && [ -r "$gateway_select_runtime_backup" ]; then
            cp "$gateway_select_runtime_backup" "$RUNTIME_CONFIG" 2>/dev/null || :
            if ! gateway_api_request '/configs?force=true' -X PUT -H 'Content-Type: application/json' --data '{"path":"'"$RUNTIME_CONFIG"'","payload":""}' >/dev/null 2>&1; then
                /data/mihomo-router/bin/mihomo-router-boot restart >/dev/null 2>&1 || :
            fi
        fi
        firewall_up >/dev/null 2>&1 || :
    fi
    [ -z "$gateway_select_runtime_next" ] || rm -f "$gateway_select_runtime_next"
    [ -z "$gateway_select_runtime_backup" ] || rm -f "$gateway_select_runtime_backup"
    exit "$gateway_select_rc"
}

gateway_select_device() (
    gateway_select_name=$1
    gateway_select_old=
    gateway_select_changed=0
    gateway_select_committed=0
    gateway_select_runtime_installed=0
    gateway_select_runtime_next=
    gateway_select_runtime_backup=
    trap 'gateway_select_cleanup' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ "$SSH_GATEWAY_ENABLED" = 1 ] || die 'SSH gateway is disabled'
    gateway_validate_name "$gateway_select_name" || die 'invalid gateway device name'
    gateway_inventory_name_exists "$gateway_select_name" || die 'gateway device not found'
    gateway_select_status=$(gateway_api) || die 'gateway API unavailable; verify running config and API secret'
    gateway_select_old=$($JSONFILTER -s "$gateway_select_status" -e '@.now' 2>/dev/null || :)
    [ -n "$gateway_select_old" ] || gateway_select_old=$(gateway_inventory_first_name)
    gateway_select_changed=1
    gateway_api -X PUT -H 'Content-Type: application/json' --data '{"name":"'"$gateway_select_name"'"}' >/dev/null || die 'gateway selection request failed; inspect gateway status'
    firewall_up || die 'gateway selected, but loop-prevention firewall rules could not be synchronized'

    gateway_select_runtime_next=$(mktemp "$RUNTIME_CONFIG.select.XXXXXX") || die 'cannot stage selected gateway config'
    gateway_select_runtime_backup=$(mktemp "$RUNTIME_CONFIG.rollback.XXXXXX") || die 'cannot save current runtime config'
    cp "$RUNTIME_CONFIG" "$gateway_select_runtime_backup" || die 'cannot back up current runtime config'
    prepare_domestic_rules || die 'cannot prepare managed routing rules'
    normalize_config "$ACTIVE_CONFIG" "$gateway_select_runtime_next" || die 'cannot generate selected gateway config'
    validate_config "$gateway_select_runtime_next" || die 'selected gateway config failed validation'
    gateway_select_runtime_installed=1
    mv "$gateway_select_runtime_next" "$RUNTIME_CONFIG" || die 'cannot activate selected gateway config'
    gateway_api_request '/configs?force=true' -X PUT -H 'Content-Type: application/json' --data '{"path":"'"$RUNTIME_CONFIG"'","payload":""}' >/dev/null || die 'Mihomo rejected the selected gateway config reload'
    gateway_select_status=$(gateway_api) || die 'gateway API unavailable after config reload'
    gateway_select_current=$($JSONFILTER -s "$gateway_select_status" -e '@.now' 2>/dev/null || :)
    [ "$gateway_select_current" = "$gateway_select_name" ] || die 'selected gateway changed during config reload'
    gateway_select_committed=1
    printf 'SSH gateway selected and firewall/config loop-prevention rules synchronized: %s\n' "$gateway_select_name"
)
gateway_command() {
    case ${1:-} in
        init)
            [ "$#" -eq 1 ] || die 'gateway init takes no arguments'
            ensure_dirs
            mkdir -p "$DATA_DIR/gateways" "$DATA_DIR/ssh"
            chmod 700 "$DATA_DIR/gateways" "$DATA_DIR/ssh"
            if [ ! -e "$SSH_GATEWAY_FILE" ] && [ ! -L "$SSH_GATEWAY_FILE" ]; then
                (umask 077; printf '%s\n' '# Private SSH devices; see share/ssh-gateways.yaml.example.' 'proxies: []' >"$SSH_GATEWAY_FILE") || die 'cannot create gateway inventory'
            fi
            printf '%s\n' "$SSH_GATEWAY_FILE"
            ;;
        status)
            [ "$#" -eq 1 ] || die 'gateway status takes no arguments'
            [ "$SSH_GATEWAY_ENABLED" = 1 ] || { printf '%s\n' 'SSH gateway disabled'; return; }
            gateway_api || die 'gateway API unavailable; verify running config and API secret'
            printf '\n'
            ;;
        list-json)
            [ "$#" -eq 1 ] || die 'gateway list-json takes no arguments'
            gateway_settings || die 'invalid SSH gateway settings'
            gateway_inventory_json
            ;;
        add)
            [ "$#" -eq 6 ] || die 'usage: mihomo-router gateway add NAME IPv4 PORT USERNAME SSH_HOST_PUBLIC_KEY'
            gateway_mutate add "$2" "$3" "$4" "$5" "$6"
            ;;
        remove)
            [ "$#" -eq 2 ] || die 'usage: mihomo-router gateway remove NAME'
            gateway_mutate remove "$2"
            ;;
        use)
            [ "$#" -eq 2 ] || die 'gateway use requires a device name'
            gateway_select_device "$2"
            ;;
        check)
            [ "$#" -eq 1 ] || die 'gateway check takes no arguments'
            gateway_settings || die 'invalid gateway settings'
            ensure_dirs
            gateway_check_file=$(mktemp "$RUN_DIR/gateway-check.XXXXXX") || die 'cannot stage gateway config'
            if normalize_config "$ACTIVE_CONFIG" "$gateway_check_file" && validate_config "$gateway_check_file"; then
                rm -f "$gateway_check_file"
                log 'gateway configuration accepted; endpoint connectivity still needs testing'
            else
                rm -f "$gateway_check_file"
                die 'gateway configuration rejected'
            fi
            ;;
        *) die 'usage: mihomo-router gateway init|list-json|status|use NAME|add NAME IPv4 PORT USERNAME SSH_HOST_PUBLIC_KEY|remove NAME|check' ;;
    esac
}
