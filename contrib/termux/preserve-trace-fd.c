/* Android's linker caches its trace_marker fd. OpenSSH's closefrom() can
 * close it and reuse the number for the SSH transport. Later dlclose()
 * tracing then injects plaintext into that encrypted connection.
 * Preserve only that kernel tracing fd, within the SSH daemon and helpers.
 * Do not disable system tracing or filter network data.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int close(int fd) {
    char path[64], target[512];
    int saved_errno = errno;
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(path, target, sizeof(target) - 1);
    if (n > 0) {
        target[n] = '\0';
        if (strcmp(target, "/sys/kernel/tracing/trace_marker") == 0 ||
            strcmp(target, "/sys/kernel/debug/tracing/trace_marker") == 0) {
            errno = saved_errno;
            return 0;
        }
    }
    errno = saved_errno;
    return (int)syscall(SYS_close, fd);
}
