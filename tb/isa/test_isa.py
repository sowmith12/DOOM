"""
test_isa.py - runs the official riscv-tests programs on our core.

Two parts in one file:
  1. `run_program`  : a cocotb test. cocotb runs it INSIDE the simulator:
                      it drives the clock and reset and waits for the program
                      to write its result to TOHOST.
  2. `test_riscv_tests` : a pytest function. pytest runs it OUTSIDE the
                      simulator: it compiles the RTL with Verilator once and
                      launches one simulation per test program.

Run (inside WSL, from the repo root):
    make -C sw/isa_tests            # build the test programs first
    pytest -v tb/isa/test_isa.py    # or: make test-isa

Useful environment variables:
    TRACE=1   print every retired instruction (pc, instruction, rd, value)
    WAVES=1   dump waveforms to build/sim_isa/dump.vcd (open with GTKWave)
"""
import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

ROOT = Path(__file__).resolve().parents[2]
HEX_DIR = ROOT / "build" / "isa"
MAX_CYCLES = 200_000


# -----------------------------------------------------------------------------
# 1. cocotb test (runs inside the simulator)
# -----------------------------------------------------------------------------
@cocotb.test()
async def run_program(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    dut.rst.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0

    for cycle in range(MAX_CYCLES):
        await RisingEdge(dut.clk)
        if dut.tohost_valid.value == 1:
            break
    else:
        raise AssertionError(f"timeout: no result after {MAX_CYCLES} cycles")

    value = int(dut.tohost_value.value)
    retired = int(dut.retired_count.value)
    dut._log.info(f"finished after {cycle} cycles, {retired} instructions retired")

    if value == 1:
        return
    if value >> 28 == 0xE:
        mcause = (value & 0x0FFF_FFFF) >> 1
        raise AssertionError(f"unexpected trap, mcause = {mcause}")
    raise AssertionError(f"FAILED in sub-test #{value >> 1}")


# -----------------------------------------------------------------------------
# 2. pytest runner (runs outside the simulator)
# -----------------------------------------------------------------------------
def _sources():
    return [
        ROOT / "rtl/pkg/core_pkg.sv",
        *sorted((ROOT / "rtl/core").glob("*.sv")),
        ROOT / "tb/common/sim_mem.sv",
        ROOT / "tb/common/tb_core.sv",
    ]


_runner_obj = None


def _runner():
    """Compile the design once per pytest session and reuse the same runner."""
    global _runner_obj
    from cocotb_tools.runner import get_runner

    if _runner_obj is None:
        runner = get_runner("verilator")
        runner.build(
            sources=_sources(),
            hdl_toplevel="tb_core",
            build_dir=ROOT / "build" / "sim_isa",
            build_args=["-Wno-fatal", "-Wno-UNUSEDSIGNAL", "-Wno-UNUSEDPARAM",
                        "-Wno-PINCONNECTEMPTY", "--x-assign", "unique", "--x-initial", "unique"],
            waves=bool(os.environ.get("WAVES")),
            always=True,
        )
        _runner_obj = runner
    return _runner_obj


def _tests():
    return sorted(p.stem for p in HEX_DIR.glob("*.hex")) if HEX_DIR.exists() else []


try:
    import pytest

    @pytest.mark.parametrize("stall_pct", [0, 30], ids=["ideal-mem", "random-stalls"])
    @pytest.mark.parametrize("name", _tests())
    def test_riscv_tests(name, stall_pct):
        plusargs = [f"+hex={HEX_DIR / (name + '.hex')}", f"+stall_pct={stall_pct}"]
        if os.environ.get("TRACE"):
            plusargs.append("+trace")
        (ROOT / "build" / "results").mkdir(parents=True, exist_ok=True)
        results = _runner().test(
            hdl_toplevel="tb_core",
            test_module="test_isa",
            test_dir=ROOT / "build" / "sim_isa",          # waves (dump.vcd) land here
            extra_env={"PYTHONPATH": str(Path(__file__).parent)},
            build_dir=ROOT / "build" / "sim_isa",
            plusargs=plusargs,
            waves=bool(os.environ.get("WAVES")),
            results_xml=str(ROOT / "build" / "results" / f"{name}-{stall_pct}.xml"),
        )
        from cocotb_tools.runner import get_results
        total, failed = get_results(results)
        assert failed == 0, f"{name} failed (see log above)"

except ImportError:  # pytest not installed: the cocotb part still works
    pass
