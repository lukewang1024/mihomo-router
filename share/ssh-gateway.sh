# Sourced by mihomo-router. Device inventory is private, standard Mihomo YAML.
SSH_GATEWAY_ENABLED=${SSH_GATEWAY_ENABLED:-0}
SSH_GATEWAY_FILE=${SSH_GATEWAY_FILE:-$DATA_DIR/gateways/proxies.yaml}
SSH_GATEWAY_CIDRS=${SSH_GATEWAY_CIDRS:-}
SSH_GATEWAY_DOMAINS=${SSH_GATEWAY_DOMAINS:-}
SSH_GATEWAY_DNS=${SSH_GATEWAY_DNS:-}
SSH_GATEWAY_API_SECRET=${SSH_GATEWAY_API_SECRET:-$CONTROLLER_SECRET}

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
    for gateway_domain in $SSH_GATEWAY_DOMAINS; do
        case "$gateway_domain" in .*|*.|*..*|-*) log 'invalid gateway domain suffix'; return 1 ;; esac
    done
    [ -n "$SSH_GATEWAY_CIDRS$SSH_GATEWAY_DOMAINS" ] || { log 'configure explicit gateway CIDRs or domain suffixes'; return 1; }
    if [ -n "$SSH_GATEWAY_DOMAINS" ]; then
        case "$SSH_GATEWAY_DNS" in tcp://*|tls://*|https://*) ;; *) log 'domain routes require TCP/TLS/HTTPS SSH_GATEWAY_DNS'; return 1 ;; esac
        case "$SSH_GATEWAY_DNS" in *'#'*|*' '*|*'	'*) log 'gateway DNS must have no fragment or whitespace'; return 1 ;; esac
    fi
}

gateway_api() (
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
        "http://$CONTROLLER_ADDRESS/proxies/SSH-Gateway"
    gateway_api_rc=$?
    rm -f "$gateway_curl_config"
    return "$gateway_api_rc"
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
        use)
            [ "$#" -eq 2 ] || die 'gateway use requires a device name'
            [ "$SSH_GATEWAY_ENABLED" = 1 ] || die 'SSH gateway is disabled'
            case $2 in ''|-*|*[!a-zA-Z0-9_.-]*) die 'use simple device names: letters, numbers, dot, underscore, dash' ;; esac
            # Mihomo validates group membership and persists selection in cache.db.
            gateway_api -X PUT -H 'Content-Type: application/json' --data "{\"name\":\"$2\"}" || die 'gateway selection request failed; inspect gateway status'
            printf 'SSH gateway selected: %s\n' "$2"
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
        *) die 'usage: mihomo-router gateway init|status|use NAME|check' ;;
    esac
}
