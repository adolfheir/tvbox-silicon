#ifndef TV_RUNTIME_MEMORY_BUDGET_H
#define TV_RUNTIME_MEMORY_BUDGET_H

#include <stdint.h>
#include <TargetConditionals.h>
#include <os/proc.h>
#include <sys/sysctl.h>

#define TV_MIB (UINT64_C(1024) * 1024)

typedef struct {
    uint64_t availableBytes;
    unsigned heapMB;
    unsigned classSpaceMB;
    unsigned translatorMB;
} TVRuntimeMemoryBudget;

static inline TVRuntimeMemoryBudget TVMemoryBudgetForAvailable(uint64_t available) {
    uint64_t megabytes = available / TV_MIB;
    unsigned heap = (unsigned)(megabytes / 4 > 1024 ? 1024 : megabytes / 4);
    unsigned classes = 8;
    while (classes < 64 && classes * 2 <= heap / 8) classes *= 2;
    unsigned translator = (unsigned)(megabytes / 64 > 32 ? 32 : megabytes / 64);
    if (translator < 1) translator = 1;
    return (TVRuntimeMemoryBudget){available, heap, classes, translator};
}

static inline TVRuntimeMemoryBudget TVCurrentRuntimeMemoryBudget(void) {
#if (TARGET_OS_IOS || TARGET_OS_TV) && !TARGET_OS_SIMULATOR
    // This is the allowance left for this process, rather than system-wide free RAM.
    // A zero allowance must stay zero, not fall back to a larger physical-RAM budget.
    return TVMemoryBudgetForAvailable(os_proc_available_memory());
#else
    uint64_t physical = 0;
    size_t size = sizeof(physical);
    if (sysctlbyname("hw.memsize", &physical, &size, NULL, 0) != 0) physical = 1024 * TV_MIB;
    return TVMemoryBudgetForAvailable(physical / 4);
#endif
}

#endif
