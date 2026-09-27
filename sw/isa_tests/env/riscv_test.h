// =============================================================================
// riscv_test.h - OUR minimal test environment for the official riscv-tests
//
// The riscv-tests (third_party/riscv-tests/isa/rv32ui/*.S etc.) are written
// against a small set of macros (RVTEST_CODE_BEGIN, RVTEST_PASS, ...). Every
// CPU project provides its own version of these. Ours:
//   * starts at address 0 (our reset PC),
//   * installs a trap handler that reports "unexpected trap",
//   * reports pass/fail by writing to TOHOST (0xF000_0000), which the
//     simulation memory (tb/common/sim_mem.sv) watches.
//
// Result value written to TOHOST:
//   1                     -> PASS
//   (test_number << 1)|1  -> FAIL in sub-test number test_number
//   0xE000_0000|(mcause<<1)|1 -> unexpected trap with that mcause
// =============================================================================
#ifndef _ENV_OUR_CORE_H
#define _ENV_OUR_CORE_H

#define TOHOST_ADDR 0xF0000000
#define EPC_ADDR    0xF0000008

// "init" is a hook each test calls; nothing to set up for us.
#define RVTEST_RV64U  .macro init; .endm
#define RVTEST_RV32U  .macro init; .endm
#define RVTEST_RV64UM .macro init; .endm
#define RVTEST_RV32UM .macro init; .endm

#define TESTNUM gp

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .globl _start;                                                  \
_start:                                                                 \
        la      t0, trap_vector;                                        \
        csrw    mtvec, t0;                                              \
        li      TESTNUM, 0;                                             \
        j       test_start;                                             \
        .align  2;                                                      \
trap_vector:                                                            \
        csrr    t5, mepc;                                               \
        li      t6, EPC_ADDR;                                           \
        sw      t5, 0(t6);                                              \
        csrr    t5, mcause;                                             \
        slli    t5, t5, 1;                                              \
        ori     t5, t5, 1;                                              \
        li      t6, 0xE0000000;                                         \
        or      t5, t5, t6;                                             \
        li      t6, TOHOST_ADDR;                                        \
        sw      t5, 0(t6);                                              \
        j       .;                                                      \
test_start:                                                             \
        init;

#define RVTEST_CODE_END                                                 \
        unimp

#define RVTEST_PASS                                                     \
        fence;                                                          \
        li      TESTNUM, 1;                                             \
        li      t6, TOHOST_ADDR;                                        \
        sw      TESTNUM, 0(t6);                                         \
        j       .;

// If TESTNUM is still 0 we must not report "1" (= pass), so use 0x7ff.
#define RVTEST_FAIL                                                     \
        fence;                                                          \
        bnez    TESTNUM, 1f;                                            \
        li      TESTNUM, 0x7ff;                                         \
1:      slli    TESTNUM, TESTNUM, 1;                                    \
        ori     TESTNUM, TESTNUM, 1;                                    \
        li      t6, TOHOST_ADDR;                                        \
        sw      TESTNUM, 0(t6);                                         \
        j       .;

#define RVTEST_DATA_BEGIN                                               \
        .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END                                                 \
        .align 4; .global end_signature; end_signature:

#endif
