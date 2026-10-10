#ifndef TV_UNICORN_MEMORY_BUDGET_H
#define TV_UNICORN_MEMORY_BUDGET_H

#include <unicorn/unicorn.h>
#include <stdio.h>
#include "RuntimeMemoryBudget.h"

static inline uc_err TVBudgetedUnicornOpen(uc_arch arch, uc_mode mode, uc_engine **engine) {
    TVRuntimeMemoryBudget budget = TVCurrentRuntimeMemoryBudget();
    // Refuse a new plugin under pressure, allowing the JNI caller to report a source error.
    if (budget.availableBytes < 128 * TV_MIB) return UC_ERR_NOMEM;
    uc_err error = uc_open(arch, mode, engine);
    if (error != UC_ERR_OK) return error;
    // Set this before the first operation initializes TCG. Its upstream 64-bit default
    // reserves 1 GiB per emulator and exits the entire process if mmap fails.
    error = uc_ctl_set_tcg_buffer_size(*engine, (uint32_t)(budget.translatorMB * TV_MIB));
    if (error != UC_ERR_OK) {
        uc_close(*engine);
        *engine = NULL;
        return error;
    }
    fprintf(stderr, "Unicorn memory budget available=%lluMiB translator=%uMiB\n",
            (unsigned long long)(budget.availableBytes / TV_MIB), budget.translatorMB);
    return UC_ERR_OK;
}

// The pinned upstream JNI implementation calls uc_open. Apply the budget without
// modifying the downloaded checkout, so rebuilding from scratch preserves the fix.
#define uc_open TVBudgetedUnicornOpen

#endif
