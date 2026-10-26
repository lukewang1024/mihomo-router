# Conservative overlay: private file provider + stable selector + target routes.
function pad(n, s) { s=""; while(n-->0) s=s " "; return s }
function indent(s, t) { t=s; sub(/[^ ].*$/, "", t); return length(t) }
function blank(s) { return s ~ /^[[:space:]]*(#.*)?$/ }
function fail(s) { print "mihomo-router: SSH gateway overlay: " s > "/dev/stderr"; bad=1; exit 1 }
function child_indent(start, stop, j) {
    for(j=start+1;j<stop;j++) if(!blank(line[j])) return indent(line[j])
    return 2
}
function provider(n) {
    print pad(n) "mr-ssh-gateways:"
    print pad(n+2) "type: file"
    print pad(n+2) "path: \047" devices "\047"
}
function group(n) {
    print pad(n) "- name: SSH-Gateway"
    print pad(n+2) "type: select"
    print pad(n+2) "disable-udp: true"
    print pad(n+2) "use:"
    print pad(n+4) "- mr-ssh-gateways"
}
function routes(n, j) {
    for(j=1;j<=domain_count;j++) print pad(n) "- DOMAIN-SUFFIX," domain[j] ",SSH-Gateway"
    for(j=1;j<=cidr_count;j++) print pad(n) "- IP-CIDR," cidr[j] ",SSH-Gateway,no-resolve"
}
function policies(n, j) {
    for(j=1;j<=domain_count;j++) print pad(n) "\047+." domain[j] "\047: \047" resolver "#SSH-Gateway\047"
}
function dns_section(start, stop, base, j, key, value, end, n, have_policy) {
    base=child_indent(start,stop)
    print "dns:"
    for(j=start+1;j<stop;j++) {
        if(indent(line[j])==base && line[j] ~ /^[ ]+nameserver-policy:/ && domain_count) {
            value=line[j]; sub(/^[^:]*:[ ]*/,"",value); sub(/[ ]*#.*$/,"",value)
            if(value!="" && value!="{}") fail("expand inline nameserver-policy first")
            end=j+1
            while(end<stop && (blank(line[end]) || indent(line[end])>base)) end++
            n=child_indent(j,end); if(n<=base) n=base+2
            print pad(base) "nameserver-policy:"
            policies(n); have_policy=1
        } else print line[j]
    }
    if(domain_count && !have_policy) { print pad(base) "nameserver-policy:"; policies(base+2) }
}
{ line[NR]=$0 }
END {
    if(bad) exit 1
    domain_count=split(domains,domain," "); cidr_count=split(cidrs,cidr," ")
    for(i=1;i<=NR;i++) {
        if(line[i] ~ /^[ ]*[\047\042]?mr-ssh-gateways[\047\042]?:/ ||
           line[i] ~ /^[ ]*-[ ]*name:[ ]*[\047\042]?SSH-Gateway[\047\042]?[ ]*(#.*)?$/)
            fail("reserved provider/group already exists")
        if(line[i] ~ /^mode:/ && line[i] !~ /^mode:[ ]*[\047\042]?rule[\047\042]?[ ]*(#.*)?$/)
            fail("SSH target routing requires rule mode")
        if(line[i] ~ /^(dns|proxy-providers|proxy-groups|rules|profile):/) {
            value=line[i]; sub(/^[^:]*:[ ]*/,"",value); sub(/[ ]*#.*$/,"",value)
            if(value!="" && value!="{}" && value!="[]") fail("expand inline managed sections first")
        }
        # Avoid duplicate policy keys silently replacing either configuration.
        for(j=1;j<=domain_count;j++) {
            key=line[i]; sub(/^[ ]*/,"",key); sub(/:.*/,"",key); gsub(/[\047\042]/,"",key)
            if(key=="+." domain[j] || key==domain[j]) fail("domain DNS policy already exists")
        }
    }
    for(i=1;i<=NR;i++) {
        if(line[i] ~ /^secret:/ && api_secret!="") { print "secret: \047" api_secret "\047"; seen_secret=1; continue }
        if(line[i] ~ /^(dns|proxy-providers|proxy-groups|rules|profile):/) {
            key=line[i]; sub(/:.*/,"",key)
            stop=i+1
            while(stop<=NR && (blank(line[stop]) || line[stop] ~ /^[ ]/ || line[stop] ~ /^-/)) stop++
            n=child_indent(i,stop)
            if(key=="dns") { dns_section(i,stop); seen_dns=1; i=stop-1; continue }
            print key ":"
            if(key=="proxy-providers") { provider(n); seen_providers=1 }
            if(key=="proxy-groups") { group(n); seen_groups=1 }
            if(key=="rules") { routes(n); seen_rules=1 }
            if(key=="profile") {
                print pad(n) "store-selected: true"; seen_profile=1
                for(j=i+1;j<stop;j++) if(line[j] !~ /^[ ]+store-selected:/) print line[j]
                i=stop-1
            }
        } else print line[i]
    }
    if(!seen_rules || !seen_dns) fail("subscription must have dns and rules sections")
    if(!seen_providers) { print "proxy-providers:"; provider(2) }
    if(!seen_groups) { print "proxy-groups:"; group(2) }
    if(!seen_profile) { print "profile:"; print "  store-selected: true" }
    if(api_secret!="" && !seen_secret) print "secret: \047" api_secret "\047"
}
