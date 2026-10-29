#include <sys/types.h>

/// True when the process runs in a sandbox (macOS's sandbox_check, spec 004 plan D6).
int latchkey_is_sandboxed(pid_t pid);

/// True when the process's sandbox refuses reading `path`. Nothing is logged for the check.
int latchkey_sandbox_denies_read(pid_t pid, const char *path);
