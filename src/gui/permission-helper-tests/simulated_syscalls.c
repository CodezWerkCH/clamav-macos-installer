/* Test build only: real directory traversal, simulated root metadata/chown.
 * This code is never linked into the app and performs no ownership changes. */
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int repaired[2], inspected[2];

static int leaf_index(int fd) {
    char path[PATH_MAX];
    if (fcntl(fd, F_GETPATH, path) != 0) return -1;
    const char *leaf = strrchr(path, '/');
    if (!leaf) return -1;
    return !strcmp(leaf, "/bin") ? 0 : !strcmp(leaf, "/sbin") ? 1 : -1;
}

static int simulated_fstat(int fd, struct stat *info) {
    int result = fstat(fd, info);
    if (result != 0) return result;
    int i = leaf_index(fd);
    if (i < 0) return 0;
    ++inspected[i];
    const char *root = getenv(i ? "TEST_ROOT_SBIN" : "TEST_ROOT_BIN");
    const char *foreign = getenv(i ? "TEST_FOREIGN_SBIN" : "TEST_FOREIGN_BIN");
    const char *mode = getenv(i ? "TEST_MODE_SBIN" : "TEST_MODE_BIN");
    const char *flags = getenv(i ? "TEST_FLAGS_SBIN" : "TEST_FLAGS_BIN");
    if (root) {
        info->st_uid = repaired[i] ? getuid() : 0;
        info->st_mode = (info->st_mode & ~07777) | 01755;
    }
    if (foreign) info->st_uid = getuid() + 1;
    if (mode) info->st_mode = (info->st_mode & ~07777) | (mode_t)strtol(mode, NULL, 8);
    if (flags) info->st_flags = UF_IMMUTABLE;
    if (getenv("TEST_RACE_BIN") && i == 0 && inspected[i] >= 2)
        info->st_mode = (info->st_mode & ~07777) | 01777;
    if (getenv("TEST_BAD_POSTCHECK") && repaired[i]) ++info->st_gid;
    return 0;
}

static uid_t simulated_geteuid(void) {
    return getenv("TEST_ROOT_EUID") ? 0 : geteuid();
}

static int simulated_fchown(int fd, uid_t uid, gid_t gid) {
    int i = leaf_index(fd);
    if (i < 0 || uid != getuid() || gid != (gid_t)-1) return -1;
    fprintf(stderr, "TEST:FCHOWN:%s\n", i ? "sbin" : "bin");
    if (getenv("TEST_FAIL_SBIN") && i == 1) return -1;
    repaired[i] = 1;
    return 0;
}

#define fstat simulated_fstat
#define fchown simulated_fchown
#define geteuid simulated_geteuid
#define main package_repair_main
#include "../package_repair.c"
#undef main

int main(int argc, char **argv) { return package_repair_main(argc, argv); }
