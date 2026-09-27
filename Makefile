# =============================================================================
# Top-level Makefile - run these INSIDE WSL (Ubuntu), from the repo root:
#
#   make deps       download the official riscv-tests (once)
#   make test       compile the official riscv-tests + run them on the core
#   make lint       Verilator lint of the core RTL (strict)
#   make clean      delete build/
#
# Handy extras:
#   TRACE=1 make test   print every retired instruction
#   WAVES=1 make test   dump waveforms to build/sim_isa/dump.vcd
#   python3 -m pytest -v -k "rv32ui-add-" tb/isa/test_isa.py   run one program
# =============================================================================
PY := python3

.PHONY: all deps test test-isa isa-programs lint clean

all: test

deps: third_party/riscv-tests

third_party/riscv-tests:
	git clone --depth 1 https://github.com/riscv-software-src/riscv-tests.git $@

isa-programs: deps
	$(MAKE) -C sw/isa_tests

test: test-isa

test-isa: isa-programs
	$(PY) -m pytest -q tb/isa/test_isa.py

lint:
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
	  rtl/pkg/core_pkg.sv rtl/core/*.sv --top-module core

clean:
	rm -rf build
