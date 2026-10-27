# Optional IPv4 controller guard. Fixed dispatcher permits changed ports on reload.
panel_down() {
    while "$IPTABLES" -w 5 -t filter -C INPUT -j MR_PANEL_INPUT >/dev/null 2>&1; do
        "$IPTABLES" -w 5 -t filter -D INPUT -j MR_PANEL_INPUT >/dev/null 2>&1 || break
    done
    iptables_delete_all filter MR_PANEL_INPUT
    # Migrate the earlier router-local port-specific hook.
    while "$IPTABLES" -w 5 -t filter -C INPUT -p tcp --dport 19090 -j MR_PANEL >/dev/null 2>&1; do
        "$IPTABLES" -w 5 -t filter -D INPUT -p tcp --dport 19090 -j MR_PANEL >/dev/null 2>&1 || break
    done
    iptables_delete_all filter MR_PANEL
}
panel_up() {
    [ -n "$PANEL_ALLOWED_CIDRS" ] || return 0
    panel_port=${CONTROLLER_ADDRESS##*:}
    case "$panel_port" in ''|*[!0-9]*) die "invalid controller port" ;; esac
    [ "$panel_port" -ge 1 ] && [ "$panel_port" -le 65535 ] || die "invalid controller port"
    case "$PANEL_INTERFACE" in ''|*[!a-zA-Z0-9_.:-]*) die "invalid panel interface" ;; esac
    # This guard is IPv4-only; refuse an IPv6/all-family listener.
    case "$CONTROLLER_ADDRESS" in *:*:*) die "panel guard requires an IPv4 listener" ;; esac
    printf '%s\n' "$PANEL_ALLOWED_CIDRS" | awk '
        { for(i=1;i<=NF;i++) {
            if(split($i,p,"/")!=2 || p[2]!~/^[0-9]+$/ || p[2]>32 || split(p[1],a,".")!=4) exit 1
            for(j=1;j<=4;j++) if(a[j]!~/^[0-9]+$/ || a[j]>255) exit 1
        }}' || die "invalid panel IPv4 CIDRs"
    "$IPTABLES" -w 5 -t filter -N MR_PANEL || die "cannot create panel chain"
    "$IPTABLES" -w 5 -t filter -A MR_PANEL -i lo -j ACCEPT || die "cannot allow local panel"
    for panel_cidr in $PANEL_ALLOWED_CIDRS; do
        "$IPTABLES" -w 5 -t filter -A MR_PANEL -i "$PANEL_INTERFACE" -s "$panel_cidr" -j ACCEPT || die "cannot allow LAN panel"
    done
    "$IPTABLES" -w 5 -t filter -A MR_PANEL -j REJECT || die "cannot protect panel"
    "$IPTABLES" -w 5 -t filter -N MR_PANEL_INPUT || die "cannot create panel dispatcher"
    "$IPTABLES" -w 5 -t filter -A MR_PANEL_INPUT -p tcp --dport "$panel_port" -j MR_PANEL || die "cannot dispatch panel"
    "$IPTABLES" -w 5 -t filter -I INPUT 1 -j MR_PANEL_INPUT || die "cannot attach panel guard"
}
