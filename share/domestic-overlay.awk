# Narrow, conservative overlay for Clash block-style YAML. Unrelated content is
# copied verbatim. Reject unsupported managed structures instead of losing rules.
function indent(s, t) { t=s; sub(/[^ ].*$/, "", t); return length(t) }
function blank(s) { return s ~ /^[[:space:]]*(#.*)?$/ }
function pad(n, s) { s=""; while(n-->0) s=s " "; return s }
function fail(s) { print "mihomo-router: domestic overlay: " s > "/dev/stderr"; bad=1; exit 1 }
function child_indent(i, stop, fallback, j) {
    for(j=i+1;j<stop;j++) if(!blank(line[j])) return indent(line[j])
    return fallback
}
function provider_fields(n) {
    print pad(n) "mr-cn:"
    print pad(n+2) "type: http"
    print pad(n+2) "behavior: domain"
    print pad(n+2) "format: mrs"
    print pad(n+2) "url: \047" url "\047"
    print pad(n+2) "path: \047" cache "\047"
    print pad(n+2) "interval: " interval
    print pad(n+2) "proxy: \047" proxy "\047"
    print pad(n) "mr-direct-local:"
    print pad(n+2) "type: file"
    print pad(n+2) "behavior: domain"
    print pad(n+2) "format: yaml"
    print pad(n+2) "path: \047" local_file "\047"
}
function filters(n, mode) {
    if(mode=="rule") {
        print pad(n) "- RULE-SET,mr-direct-local,real-ip"
        print pad(n) "- RULE-SET,mr-cn,real-ip"
    } else {
        print pad(n) "- \047rule-set:mr-direct-local\047"
        print pad(n) "- \047rule-set:mr-cn\047"
    }
}
function policy(n) {
    print pad(n) "\047rule-set:mr-direct-local,mr-cn\047:"
    for(d=1;d<=dns_count;d++) print pad(n+2) "- \047" dns[d] "\047"
}
function render_dns(start, stop, base, mode, have_filter, have_policy, j, end, value, key, ci) {
    base=child_indent(start,stop,2); mode="blacklist"
    for(j=start+1;j<stop;j++) if(line[j] ~ /^[ ]+fake-ip-filter-mode:/) {
        value=line[j]; sub(/^[^:]*:[ ]*/,"",value); sub(/[ ]+#.*$/,"",value)
        gsub(/[\047\042 ]/,"",value); mode=value
    }
    if(mode!="blacklist" && mode!="rule") fail("fake-ip-filter-mode must be blacklist or rule; whitelist cannot be extended safely")
    print line[start]
    for(j=start+1;j<stop;j++) {
        if(indent(line[j])==base && line[j] ~ /^[ ]+(fake-ip-filter|nameserver-policy):/) {
            key=line[j]; sub(/^[ ]*/,"",key); sub(/:.*/,"",key)
            value=line[j]; sub(/^[^:]*:[ ]*/,"",value); sub(/[ ]*#.*$/,"",value)
            if(value!="" && value!="[]" && value!="{}") fail(key " must use block YAML (expand inline lists/maps first)")
            end=j+1
            while(end<stop && (blank(line[end]) || indent(line[end])>base || (indent(line[end])==base && line[end] ~ /^[ ]*-/))) end++
            ci=child_indent(j,end,base+2)
            print pad(base) key ":"
            if(key=="fake-ip-filter") { filters(ci,mode); have_filter=1 }
            else { policy(ci); have_policy=1 }
        } else print line[j]
    }
    if(!have_filter) {
        if(mode=="rule") fail("rule-mode filter requires an explicit existing fallback")
        print pad(base) "fake-ip-filter:"
        filters(base+2,mode)
    }
    if(!have_policy) { print pad(base) "nameserver-policy:"; policy(base+2) }
}
{ line[NR]=$0 }
END {
    if(bad) exit 1
    dns_count=split(resolvers,dns," ")
    # Inspect before writing, so malformed subscription sections never silently
    # turn into a different routing policy.
    for(i=1;i<=NR;i++) {
        if(line[i] ~ /^[ ]*[\047\042]?mr-(cn|direct-local)[\047\042]?:/) fail("reserved provider name already exists")
        if(line[i] ~ /^(dns|rules|rule-providers):/ && line[i] !~ /^(dns|rules|rule-providers):[ ]*(#.*)?$/) fail("dns/rules/rule-providers must use block YAML")
    }
    for(i=1;i<=NR;i++) {
        if(line[i] ~ /^(dns|rules|rule-providers):/) {
            stop=i+1
            while(stop<=NR && (blank(line[stop]) || line[stop] ~ /^[ ]/ || line[stop] ~ /^-/)) stop++
            if(line[i] ~ /^dns:/) { render_dns(i,stop); seen_dns=1; i=stop-1; continue }
            print line[i]
            n=child_indent(i,stop,2)
            if(line[i] ~ /^rules:/) {
                print pad(n) "- RULE-SET,mr-direct-local,DIRECT"
                print pad(n) "- RULE-SET,mr-cn,DIRECT"
                seen_rules=1
            } else { provider_fields(n); seen_providers=1 }
        } else print line[i]
    }
    if(!seen_dns || !seen_rules) fail("subscription must contain dns and rules sections")
    if(!seen_providers) { print "rule-providers:"; provider_fields(2) }
}
