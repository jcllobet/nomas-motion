#include "CAccelerometer.h"

#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>

static int nomas_unix_fill_path(struct sockaddr_un *address, const char *path) {
    size_t path_length;

    if (address == NULL || path == NULL) {
        return -1;
    }

    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    path_length = strlen(path);
    if (path_length >= sizeof(address->sun_path)) {
        return -1;
    }
    memcpy(address->sun_path, path, path_length);
    return 0;
}

int nomas_unix_socket_connect(int fd, const char *path) {
    struct sockaddr_un address;

    if (fd < 0 || nomas_unix_fill_path(&address, path) != 0) {
        return -1;
    }

    return connect(fd, (struct sockaddr *)&address, (socklen_t)sizeof(address));
}

int nomas_unix_socket_bind(int fd, const char *path) {
    struct sockaddr_un address;

    if (fd < 0 || nomas_unix_fill_path(&address, path) != 0) {
        return -1;
    }

    return bind(fd, (struct sockaddr *)&address, (socklen_t)sizeof(address));
}
