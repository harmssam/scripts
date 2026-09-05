#include <errno.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    uint32_t executable_size = 0;
    (void)_NSGetExecutablePath(NULL, &executable_size);
    char *executable = calloc(executable_size, sizeof(char));
    if (executable == NULL || _NSGetExecutablePath(executable, &executable_size) != 0) {
        fputs("Burrow could not locate its bundled Mole launcher.\n", stderr);
        return 70;
    }

    char *macos_directory = dirname(executable);
    const char *relative_engine = "/../Resources/ThirdParty/Mole/engine/mole";
    size_t engine_size = strlen(macos_directory) + strlen(relative_engine) + 1;
    char *engine = malloc(engine_size);
    if (engine == NULL) {
        fputs("Burrow could not allocate its Mole launch path.\n", stderr);
        return 70;
    }
    (void)snprintf(engine, engine_size, "%s%s", macos_directory, relative_engine);

    char **engine_argv = calloc((size_t)argc + 1, sizeof(char *));
    if (engine_argv == NULL) {
        fputs("Burrow could not allocate Mole arguments.\n", stderr);
        return 70;
    }
    engine_argv[0] = engine;
    for (int index = 1; index < argc; index++) {
        engine_argv[index] = argv[index];
    }

    execv(engine, engine_argv);
    fprintf(stderr, "Burrow could not launch its bundled Mole engine: %s\n", strerror(errno));
    return 71;
}
