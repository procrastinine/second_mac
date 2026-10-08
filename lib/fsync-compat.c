#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Some mounted filesystems implement fsync but reject F_FULLFSYNC. Preserve
// the flush and its errors instead of treating an unsupported ioctl as success.
__attribute__((visibility("hidden"))) int project_fullsync(int fd) {
    int result = fcntl(fd, F_FULLFSYNC);
    if (result == -1 && (errno == ENOTTY || errno == ENOTSUP || errno == EINVAL))
        return fsync(fd);
    return result;
}

// Tail forwarding preserves every variadic argument, including future fcntl
// commands. Reading an unspecified third argument in C would be undefined.
extern int project_fcntl(int, int, ...);
#if defined(__aarch64__)
__asm__(".text\n.p2align 2\n_project_fcntl:\n"
        "cmp w1, #51\nb.ne 1f\nb _project_fullsync\n1: b _fcntl\n");
#elif defined(__x86_64__)
__asm__(".text\n_project_fcntl:\n"
        "cmpl $51, %esi\nje _project_fullsync\njmp _fcntl\n");
#else
#error Unsupported architecture
#endif
_Static_assert(F_FULLFSYNC == 51, "Update the forwarding trampoline");
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } hooks[] = {
    {(const void *)project_fcntl, (const void *)fcntl}
};

// Keep the compatibility library in this process only. Child applications keep
// any other libraries the caller requested, without inheriting this one.
__attribute__((constructor)) static void local_scope(void) {
    Dl_info info;
    const char *value = getenv("DYLD_INSERT_LIBRARIES");
    if (!value || !dladdr((const void *)local_scope, &info)) return;
    char *copy = strdup(value), *kept = calloc(strlen(value) + 1, 1), *state = NULL;
    if (!copy || !kept) { free(copy); free(kept); return; }
    for (char *item = strtok_r(copy, ":", &state); item; item = strtok_r(NULL, ":", &state)) {
        if (strcmp(item, info.dli_fname) == 0) continue;
        if (*kept) strcat(kept, ":");
        strcat(kept, item);
    }
    if (*kept) setenv("DYLD_INSERT_LIBRARIES", kept, 1);
    else unsetenv("DYLD_INSERT_LIBRARIES");
    free(copy); free(kept);
}
