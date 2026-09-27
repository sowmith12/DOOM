# =============================================================================
# Builds the official riscv-tests (rv32ui + rv32um) for our core.
# Run inside WSL:   make -C sw/isa_tests
# Output: build/isa/<suite>-<test>.hex  (+ .elf and .dump for debugging)
# =============================================================================
CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump

ROOT    := ../..
TESTS   := $(ROOT)/third_party/riscv-tests/isa
OUT     := $(ROOT)/build/isa

CFLAGS  := -march=rv32im_zicsr_zifencei -mabi=ilp32 -static -nostdlib -nostartfiles \
           -mcmodel=medany -Wl,--no-warn-rwx-segments -Ienv -I$(TESTS)/macros/scalar -Tenv/link.ld

# ma_data (misaligned accesses) is left out on purpose: our core traps on
# misaligned loads/stores instead of handling them in hardware.
RV32UI  := simple add addi and andi auipc beq bge bgeu blt bltu bne fence_i jal jalr \
           lb lbu ld_st lh lhu lui lw or ori sb sh sll slli slt slti sltiu sltu \
           sra srai srl srli st_ld sub sw xor xori
RV32UM  := mul mulh mulhsu mulhu div divu rem remu

HEX := $(addprefix $(OUT)/rv32ui-,$(addsuffix .hex,$(RV32UI))) \
       $(addprefix $(OUT)/rv32um-,$(addsuffix .hex,$(RV32UM)))

all: $(HEX)

$(OUT)/rv32ui-%.elf: $(TESTS)/rv32ui/%.S env/riscv_test.h env/link.ld | $(OUT)
	$(CC) $(CFLAGS) $< -o $@

$(OUT)/rv32um-%.elf: $(TESTS)/rv32um/%.S env/riscv_test.h env/link.ld | $(OUT)
	$(CC) $(CFLAGS) $< -o $@

$(OUT)/%.hex: $(OUT)/%.elf
	$(OBJCOPY) -O binary $< $(OUT)/$*.bin
	python3 $(ROOT)/tools/bin2hex.py $(OUT)/$*.bin $@
	$(OBJDUMP) -d $< > $(OUT)/$*.dump

$(OUT):
	mkdir -p $@

clean:
	rm -rf $(OUT)

.PHONY: all clean
.PRECIOUS: $(OUT)/%.elf
