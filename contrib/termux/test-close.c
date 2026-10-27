#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    int fd = open("/dev/null", O_RDONLY);
    if (fd < 0 || close(fd) != 0) return 1;
    errno = 0;
    if (fcntl(fd, F_GETFD) != -1 || errno != EBADF) return 2;
    int preserved = 0;
    for (fd = 3; fd < 256; fd++) {
        char path[64], target[512];
        snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
        ssize_t n = readlink(path, target, sizeof(target)-1);
        if (n <= 0) continue;
        target[n] = '\0';
        if (strcmp(target, "/sys/kernel/tracing/trace_marker") != 0 &&
            strcmp(target, "/sys/kernel/debug/tracing/trace_marker") != 0) continue;
        if (close(fd) != 0 || readlink(path, target, sizeof(target)-1) <= 0) return 3;
        preserved++;
    }
    printf("Normal close verified; preserved trace descriptors: %d\n", preserved);
    return 0;
}
