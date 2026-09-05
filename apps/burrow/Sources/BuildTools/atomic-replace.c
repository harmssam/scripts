#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/attr.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fputs("usage: atomic-replace STAGED_PATH DESTINATION_PATH\n", stderr);
        return 64;
    }

    if (access(argv[2], F_OK) == 0) {
        if (renameatx_np(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_SWAP) == 0) {
            return 0;
        }
    } else if (errno == ENOENT && rename(argv[1], argv[2]) == 0) {
        return 0;
    }

    fprintf(stderr, "Could not atomically install %s at %s: %s\n",
            argv[1], argv[2], strerror(errno));
    return 74;
}
