#include "SandboxCheck.h"

// libSystem's sandbox_check has no public header and takes variable arguments, which Swift
// can't call (spec 004 research.md, "Finding a command's processes by their fence").
extern int sandbox_check(pid_t pid, const char *operation, int type, ...);

enum { filter_none = 0, filter_path = 1, check_no_report = 0x40000000 };

int latchkey_is_sandboxed(pid_t pid) { return sandbox_check(pid, 0, filter_none) == 1; }

int latchkey_sandbox_denies_read(pid_t pid, const char *path) {
    return sandbox_check(pid, "file-read-data", filter_path | check_no_report, path) == 1;
}
