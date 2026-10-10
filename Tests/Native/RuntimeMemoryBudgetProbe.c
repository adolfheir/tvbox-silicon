#include "../../Runtime/AppleRuntime/Native/RuntimeMemoryBudget.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    const uint64_t availableMB[] = {0, 32, 128, 256, 512, 1408, 4096, 65536};
    for (unsigned i = 0; i < sizeof(availableMB) / sizeof(availableMB[0]); i++) {
        TVRuntimeMemoryBudget budget = TVMemoryBudgetForAvailable(availableMB[i] * TV_MIB);
        assert(budget.heapMB <= availableMB[i] / 4);
        assert(budget.heapMB <= 1024 && budget.classSpaceMB <= 64 && budget.translatorMB <= 32);
        if (availableMB[i] >= 256) {
            // Leave half the allowance for UI, images, metadata, video and guest memory,
            // even if eight emulators are open at once.
            assert(budget.heapMB + budget.classSpaceMB + 8 * budget.translatorMB <= availableMB[i] / 2);
        }
    }
    assert(TVMemoryBudgetForAvailable(0).availableBytes == 0);
    puts("Runtime memory budgets preserve headroom at low and high allowances");
    return 0;
}
