#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <unistd.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    int fd = open(argv[1], O_CREAT | O_RDWR | O_TRUNC, 0600);
    assert(fd >= 0);
    assert(write(fd, "durable", 7) == 7);
    assert(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0);
    assert(fcntl(fd, F_GETFD) & FD_CLOEXEC);
    char actual[MAXPATHLEN];
    assert(fcntl(fd, F_GETPATH, actual) == 0);
    assert(strstr(actual, "flush-probe") != NULL);
    errno = 0;
    assert(fcntl(-1, F_FULLFSYNC) == -1 && errno == EBADF);
    errno = 0;
    int flushed = fcntl(fd, F_FULLFSYNC);
    int failure = errno;
    assert(getenv("DYLD_INSERT_LIBRARIES") == NULL);
    assert(close(fd) == 0);
    printf("{\"flush\":%d,\"errno\":%d,\"forwarding\":true,\"bad_fd_preserved\":true,\"child_environment_clean\":true}\n", flushed, failure);
    return flushed == 0 ? 0 : 2;
}
