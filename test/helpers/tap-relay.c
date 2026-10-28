/* Minimal Linux/AArch64 TAP relay for vendor kernels lacking veth.
 * Static, libc-free: build on an Android/AArch64 workstation with clang/lld.
 * Opens one TAP in the current netns and one in an existing test netns.
 * Relays Ethernet frames so ordinary tools in that namespace traverse the
 * router's real LAN ingress/firewall. Both TAPs vanish when this exits.
 */
typedef unsigned long usize;
struct pollfd { int fd; short events, revents; };
struct ifreq { char name[16]; unsigned short flags; char padding[22]; };
static long call(long nr, long a, long b, long c, long d, long e, long f) {
    register long x0 __asm__("x0")=a, x1 __asm__("x1")=b;
    register long x2 __asm__("x2")=c, x3 __asm__("x3")=d;
    register long x4 __asm__("x4")=e, x5 __asm__("x5")=f;
    register long x8 __asm__("x8")=nr;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x1),"r"(x2),"r"(x3),"r"(x4),"r"(x5),"r"(x8) : "memory","cc");
    return x0;
}
void *memset(void *p,int v,usize n) { unsigned char *q=p; for(usize i=0;i<n;i++)q[i]=(unsigned char)v; return p; }
void *memcpy(void *p,const void *s,usize n) { unsigned char *q=p; const unsigned char *r=s; for(usize i=0;i<n;i++)q[i]=r[i]; return p; }
static long open_file(const char *p) { return call(56,-100,(long)p,524288,0,0,0); }
static long make_tap(const char *name) {
    struct ifreq r; memset(&r,0,sizeof r);
    usize i=0; for(;name[i]&&i<15;i++)r.name[i]=name[i];
    if(name[i])return -1;
    r.flags=0x1002; /* IFF_TAP | IFF_NO_PI */
    long fd=call(56,-100,(long)"/dev/net/tun",524290,0,0,0);
    if(fd<0)return fd;
    if(call(29,fd,0x400454ca,(long)&r,0,0,0)<0){call(57,fd,0,0,0,0,0);return -1;}
    return fd;
}
static int error(const char *s,usize n) { call(64,2,(long)s,n,0,0,0); return 1; }
#define FAIL(s) error((s),sizeof(s)-1)
int entry(long argc,char **argv) {
    if(argc!=4)return FAIL("usage: tap-relay NETNS_PATH HOST_TAP CLIENT_TAP\n");
    long root=open_file("/proc/self/ns/net"), ns=open_file(argv[1]);
    if(root<0||ns<0)return FAIL("open namespace failed\n");
    long host=make_tap(argv[2]);
    if(host<0)return FAIL("create host TAP failed\n");
    if(call(268,ns,0x40000000,0,0,0,0)<0)return FAIL("enter namespace failed\n");
    long peer=make_tap(argv[3]);
    if(peer<0)return FAIL("create client TAP failed\n");
    if(call(268,root,0x40000000,0,0,0,0)<0)return FAIL("restore namespace failed\n");
    call(57,root,0,0,0,0,0);call(57,ns,0,0,0,0,0);
    struct pollfd p[2]={{(int)host,1,0},{(int)peer,1,0}};
    char buffer[65536];
    call(64,1,(long)"READY\n",6,0,0,0);
    for(;;) {
        long rc=call(73,(long)p,2,0,0,8,0); /* ppoll */
        if(rc<0)return FAIL("poll failed\n");
        for(int i=0;i<2;i++) {
            if(p[i].revents&24)return FAIL("TAP closed\n");
            if(!(p[i].revents&1))continue;
            long n=call(63,p[i].fd,(long)buffer,sizeof buffer,0,0,0);
            if(n<=0)return FAIL("TAP read failed\n");
            if(call(64,p[1-i].fd,(long)buffer,n,0,0,0)!=n)return FAIL("TAP write failed\n");
        }
    }
}
__asm__(".global _start\n_start:\nldr x0, [sp]\nadd x1, sp, #8\nbl entry\nmov x8, #93\nsvc #0\n");
