# Block-style top-level YAML, with block or flow-style named proxy entries.
# Reject unsupported/ambiguous shapes instead of silently dropping AI routing.
function fail(s) { print "mihomo-router: AI overlay: " s > "/dev/stderr"; bad=1; exit 1 }
function quote(s) { gsub(/\047/, "\047\047", s); return "\047" s "\047" }
function item_pad(pos, j,s) {
    for(j=pos+1;j<=n;j++) {
        s=line[j]
        if(s~/^[^[:space:]#]/) break
        if(s~/^[ ]*-/) {sub(/-.*/, "", s); return s}
    }
    return "  "
}
function name_of(s, q) {
    sub(/^.*[{,[:space:]]name:[[:space:]]*/, "", s)
    q=substr(s,1,1)
    if(q=="\047" || q=="\"") {
        s=substr(s,2); if(index(s,q)==0) fail("unsupported quoted name")
        s=substr(s,1,index(s,q)-1)
    } else { sub(/[,}].*$/, "", s); sub(/[[:space:]]+$/, "", s) }
    return s
}
{ line[++n]=$0 }
END {
    if(bad) exit 1
    if(enabled==1) {
        if(group=="" || domains=="") fail("AI_GROUP and AI_DOMAINS are required")
        if(group ~ /[\r\n\\]/) fail("unsupported group name")
        nd=split(domains,ds,/[[:space:]]+/)
        for(i=1;i<=nd;i++) if(ds[i]!~/^[a-zA-Z0-9][a-zA-Z0-9.-]*$/) fail("invalid domain suffix")
        section=""
        for(i=1;i<=n;i++) {
            s=line[i]
            if(s~/^[^[:space:]#]/) {
                section=s; sub(/:.*/,"",section)
                if(section=="proxies" || section=="proxy-groups" || section=="rules") {
                    if(s !~ /^[a-z-]+:[[:space:]]*(#.*)?$/) fail("expected block-style " section)
                    seen[section]++
                }
            }
            if((section=="proxies" || section=="proxy-groups") && s~/[ {,-]name:/) {
                name=name_of(s)
                if(name==group) fail("AI group already exists; use an unmodified subscription")
                if(section=="proxies" && name~include && (exclude=="" || name!~exclude)) nodes[++nn]=name
            }
        }
        if(seen["proxies"]!=1 || seen["proxy-groups"]!=1 || seen["rules"]!=1) fail("missing or repeated subscription sections")
        if(nn==0) fail("no matching subscription nodes")
    }
    skip=0
    for(i=1;i<=n;i++) {
        s=line[i]
        if(s~/^[^[:space:]#]/) skip=0
        if(sniff!="preserve" && s~/^sniffer:/) {skip=1; continue}
        if(enabled==1 && s~/^profile:/) {
            if(s !~ /^profile:[[:space:]]*(#.*)?$/) fail("expected block-style profile")
            p="  "; for(k=i+1;k<=n;k++) { if(line[k]~/^[^[:space:]#]/) break; if(line[k]~/^[ ]+[a-zA-Z]/) {p=line[k]; sub(/[^ ].*$/, "", p); break} }
            print s; print p "store-selected: true"; profile=1
            while(i<n && line[i+1]!~/^[^[:space:]#]/) {i++; if(line[i]!~/^[[:space:]]+store-selected:/) print line[i]}
            continue
        }
        if(skip) continue
        print s
        if(enabled==1 && s~/^proxy-groups:/) {
            p=item_pad(i); print p "- name: " quote(group); print p "  type: select"; print p "  proxies:"
            for(j=1;j<=nn;j++) print p "    - " quote(nodes[j])
        }
        if(enabled==1 && s~/^rules:/) {p=item_pad(i); for(j=1;j<=nd;j++) print p "- " quote("DOMAIN-SUFFIX," ds[j] "," group)}
    }
    if(enabled==1 && !profile) {print "profile:"; print "  store-selected: true"}
    if(sniff!="preserve") {
        print "sniffer:"
        print "  enable: " (sniff==1 ? "true" : "false")
        if(sniff==1) {
            print "  force-dns-mapping: true"; print "  parse-pure-ip: true"; print "  override-destination: true"
            print "  sniff:"; print "    HTTP: {ports: [80, 8080, 8443]}"
            print "    TLS: {ports: [443, 8443]}"; print "    QUIC: {ports: [443, 8443]}"
        }
    }
}
