#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stdio.h>

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "usage: rename-exclusive SOURCE TARGET\n");
        return 64;
    }

    const unsigned int flags = RENAME_EXCL | RENAME_NOFOLLOW_ANY;
    if (renamex_np(argv[1], argv[2], flags) == 0) {
        return 0;
    }

    const int error = errno;
    fprintf(stderr, "rename-exclusive: %s -> %s: %s\n",
            argv[1], argv[2], strerror(error));
    return error == EEXIST ? 2 : 1;
}
