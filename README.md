# DOOM on Our Own RISC-V CPU: Nexys A7-100T


## Table of contents

1. [Reference projects we learn from](#1-reference-projects-we-learn-from)
2. [The big idea: how can a homemade CPU run DOOM?](#2-the-big-idea-how-can-a-homemade-cpu-run-doom)
3. [What DOOM needs, and how we give it each thing](#3-what-doom-needs-and-how-we-give-it-each-thing)
4. [Our board: Nexys A7-100T](#4-our-board-nexys-a7-100t)
5. [How you will play: physical setup](#5-how-you-will-play-physical-setup)
6. [Shopping list and software list](#6-shopping-list-and-software-list)
7. [System architecture (the whole chip)](#7-system-architecture-the-whole-chip)
8. [The CPU core](#8-the-cpu-core)
9. [The caches](#9-the-caches)
10. [Memory: DDR2 through Xilinx MIG](#10-memory-ddr2-through-xilinx-mig)
11. [Clocks and clock-domain crossings](#11-clocks-and-clock-domain-crossings)
12. [Memory map](#12-memory-map)
13. [Peripherals: UART, timer, VGA, keyboard, LEDs](#13-peripherals)
14. [Loading programs: the UART bootloader](#14-loading-programs-the-uart-bootloader)
15. [Software stack: bare-metal C and the DOOM port](#15-software-stack-bare-metal-c-and-the-doom-port)
16. [Verification strategy (how we find bugs)](#16-verification-strategy-how-we-find-bugs)
17. [Project folder layout](#17-project-folder-layout)
18. [Step-by-step roadmap (Phase 0 → Phase 12)](#18-step-by-step-roadmap)
19. [Lessons already learned by others (read before you start)](#19-lessons-already-learned-by-others)
20. [Performance plan (how to get from 1 FPS to 20+ FPS)](#20-performance-plan)
21. [Credits: exactly what we take from where](#21-credits-exactly-what-we-take-from-where)
22. [Glossary (every jargon word explained)](#22-glossary)


## 1. Reference projects we learn from


**Their setups in one line each:**

- **HOLY CORE:** Arty S7-50 board, 256 MB DDR3, single-cycle core with small caches, Xilinx IP peripherals on an AXI bus, 2.8" SPI LCD screen, program loaded over JTAG with OpenOCD + GDB, keys typed over UART.
- **Armaan:** Urbana board (Spartan-7), DDR3, 5-stage pipelined core in Chisel, 32 KB caches, his own HDMI/VGA controller reading a framebuffer in on-chip RAM, keys over UART, 15–20 FPS after optimisation.

**Our setup (best of both):** Nexys A7-100T, 128 MB DDR2, our own **5-stage pipelined** core in SystemVerilog (Armaan's architecture, HOLY's language and test style), our own caches, a **VGA framebuffer controller with a hardware palette** (Armaan's display idea, improved), a **real USB keyboard** plugged into the board (neither project had one), a UART keyboard from the laptop as a fallback, and a **UART bootloader** (no extra JTAG dongle needed).

---

## 2. The big idea: how can a homemade CPU run DOOM?

### 2.1 What "running DOOM" really means

DOOM is **just a C program**. id Software released its source code. If you compile that C code with a compiler that outputs **RISC-V machine code**, you get a file full of RISC-V instructions (`add`, `lw`, `sw`, `beq`...). Any machine that correctly executes RISC-V instructions can run it. That includes a CPU **we** describe in SystemVerilog and load onto an FPGA.

Nothing is emulated. Our RTL (the hardware description) becomes real logic gates inside the FPGA, and those gates fetch and execute DOOM's instructions one by one. Every wall, monster and pixel is computed by our CPU.



### 2.3 What is RISC-V?

**RISC-V** is a free, open **instruction set architecture (ISA)**: a list of instructions a CPU must understand and exactly what each one does. Because it is open and simple, and because GCC already compiles C to it, it is perfect for homemade CPUs. We implement:

- **RV32I**: the base 32-bit integer instructions (about 40 of them).
- **M**: multiply and divide (DOOM does lots of multiplication).
- **Zicsr**: instructions to read and write "control and status registers" (needed for traps, counters and timers).
- **Zifencei**: the `fence.i` instruction (needed to keep instruction and data caches consistent).

DOOM needs **no floating point**. It uses **fixed-point** math (`m_fixed.c`: numbers stored as integer × 65536), so integer hardware is enough.

### 2.4 There is no operating system

On a PC, Windows or Linux gives a program memory, files, a clock, a screen and a keyboard. We have **no OS**. We run **bare metal**: when the CPU comes out of reset it runs *our* code directly, and we replace every OS service with tiny pieces of our own code and hardware (see §3). That is what "porting DOOM" means here.

---

## 3. What DOOM needs, and how we give it each thing

| # | DOOM needs | On a PC | **Our solution** | Idea from |
|---|---|---|---|---|
| 1 | A CPU that executes its compiled code | Intel/AMD | Our RV32IM pipelined core | Both |
| 2 | ~10 MB+ of RAM (4.2 MB WAD + ~1 MB code + game heap + stack) | DRAM via OS | **128 MB DDR2** chip on the Nexys A7, driven by Xilinx **MIG** | Both (they used DDR3) |
| 3 | Fast memory access | CPU caches | Our own **instruction cache** and **data cache** | Both |
| 4 | Its data file `doom1.wad` (levels, textures, sounds) | Hard disk file | WAD sent into DDR by our **UART bootloader**; a fake `open/read` returns bytes from DDR | HOLY (fake file system) |
| 5 | A clock: game logic runs at **35 tics per second** | OS timer | Our **64-bit microsecond timer** peripheral | Both |
| 6 | A screen | GPU + OS | Our **VGA controller**: framebuffer in on-chip BRAM + hardware palette → 640×480 VGA output | Armaan (VGA BRAM framebuffer) |
| 7 | A keyboard | OS drivers | **USB keyboard** on the board's USB-host port (appears as PS/2) **and/or** laptop keys over UART | HOLY + Armaan (UART keys), ours (PS/2) |
| 8 | `printf` for debug messages | Terminal | **UART** to a serial terminal on the laptop | Both |
| 9 | A way to get the program in | Double-click | **UART bootloader** in on-chip ROM + a Python loader script | Ours (HOLY used JTAG+GDB) |

---

## 4. Our board: Nexys A7-100T

| Feature | Value | What we use it for |
|---|---|---|
| FPGA | Xilinx Artix-7 **XC7A100T-1CSG324C** | Holds our entire system |
| Logic | ~63,400 LUTs, 240 DSP slices | CPU, caches, peripherals. DSPs make fast multipliers |
| On-chip Block RAM | **4,860 Kbit ≈ 607 KB** (135 × 36 Kbit blocks) | Caches, boot ROM, framebuffer |
| External RAM | **128 MB DDR2** (Micron MT47H64M16HR, 16-bit bus) | DOOM code, WAD, heap, stack |
| Clock | 100 MHz oscillator | Source of all our clocks |
| USB-UART + JTAG | One micro-USB (FTDI FT2232HQ) | Program the FPGA (JTAG) and talk to the CPU (UART) over the **same cable** |
| USB HID host | USB-A port (a PIC24 chip converts a USB keyboard to **PS/2** signals) | Plug a real keyboard in |
| VGA | 12-bit colour (4 bits each R, G, B) | Monitor output |
| 16 MB Quad-SPI flash | Stores the bitstream so the board boots by itself | Later: store the WAD permanently |
| microSD slot | | Later: WAD from SD card |
| Mono PWM audio jack | | Stretch goal: DOOM sound |
| 16 switches, 16 LEDs, 5 buttons, 8-digit 7-segment display | | Debug: show PC, status, errors |
| 4 Pmod headers | | Extras (logic analyser, SPI LCD, etc.) |

**Why this board is good for DOOM:** it has **external RAM** (the Basys 3 does not, which is why the Basys 3 can't run DOOM), a **VGA port**, a **USB keyboard port**, and UART plus programming over one cable.

> 💡 The Basys 3 is still useful: the first CPU phases (§18, Phases 1–3) fit on it if you want a second board for experiments.

---

## 5. How you will play: physical setup

### 5.1 Main setup: monitor + USB keyboard (standalone, like a console)

```
                         micro-USB cable (power + JTAG + UART)
   ┌───────────────┐  ──────────────────────────────────────────┐
   │    LAPTOP     │                                            │
   │ Vivado        │  used only to: program FPGA,               │
   │ load.py       │  send DOOM + WAD, see printf logs          │
   │ serial term.  │                                            │
   └───────────────┘                                            │
                                                     ┌──────────┴──────────┐
   ┌────────────────┐        VGA cable               │   NEXYS A7-100T     │
   │  MONITOR       │◄───────────────────────────────┤ VGA                 │
   │  (VGA input,   │  (or VGA→HDMI active adapter)  │                     │
   │   or HDMI via  │                                │ USB-A (HID host)    │
   │   adapter)     │                                └──────────┬──────────┘
   └────────────────┘                                           │
                                               ┌────────────────┴─┐
                                               │  USB keyboard    │
                                               └──────────────────┘
```

- The **monitor** shows the game (640×480, 60 Hz).
  - If your monitor has only HDMI, buy a **VGA-to-HDMI active converter** (a small box, usually powered by USB). A plain passive cable **does not work**, because VGA is analog and HDMI is digital.
- The **USB keyboard** plugs into the Nexys A7's USB-A port. Our PS/2 receiver hardware reads it.
- The **laptop** is only needed to load the game and read logs. After loading, you can unplug nothing and just play.

### 5.2 Playing on the laptop screen

⚠️ A laptop's HDMI port is almost always an **output**, so you **cannot** plug the board into it. Two ways to still use the laptop screen:

| Option | How | Pros / cons |
|---|---|---|
| **A. USB capture dongle** (recommended if you have no monitor) | VGA → VGA-to-HDMI converter → cheap **USB HDMI capture dongle** → laptop. Open it in OBS or the Windows Camera app. | No extra hardware design. Low latency. Costs ~₹1000–2000 for the dongle + converter. |
| **B. Stream frames over UART** (stretch goal, Phase 12) | Our hardware sends each 64,000-byte frame over the USB-UART at 4 Mbaud. A Python/pygame viewer on the laptop draws it, and laptop keys are sent back. | No extra hardware at all, but limited to about 5 FPS by UART speed (compression helps). A fun project on its own. |

### 5.3 Keyboard controls (initial plan)

| Key | DOOM action |
|---|---|
| Arrow keys / W A S D | Move / turn |
| Ctrl or Space | Fire |
| Space / E | Use / open doors |
| Enter | Menu select |
| Esc | Menu |
| Shift | Run |
| 1–7 | Weapons |

---

## 6. Shopping list and software list

### 6.1 Hardware

| Item | Needed? | Why |
|---|---|---|
| Nexys A7-100T + micro-USB cable | ✅ have | Everything |
| Monitor with VGA input, **or** HDMI monitor + VGA→HDMI **active** converter | ✅ for main setup | Display |
| VGA cable | ✅ | |
| USB keyboard (plain wired, not a fancy gaming one with hubs) | ✅ recommended | The PIC24 USB host supports simple HID keyboards. Wireless dongles may not work |
| USB HDMI capture dongle | Optional | Play on the laptop screen (§5.2 A) |
| Cheap 8-channel USB logic analyser (Saleae-clone) | Optional | Debug UART/PS/2 signals on Pmod pins |

### 6.2 Software (all free)

| Tool | Runs on | Used for |
|---|---|---|
| **Vivado ML Standard** (free; 2023.x or newer) | Windows | Synthesis, place & route, bitstream, MIG IP, ILA debugging, programming the board. Install Artix-7 device support and the Digilent board files |
| **WSL2 + Ubuntu** | Windows | A Linux environment for the simulation tools below (they work best on Linux) |
| **Verilator** | WSL | Fast simulator. Needed to simulate the full system running DOOM |
| **Icarus Verilog** | WSL | Simple simulator for small unit tests |
| **Python 3 + cocotb + cocotbext-axi + pytest** | WSL | Write testbenches in Python (HOLY's method). `cocotbext-axi` gives a ready-made AXI memory model |
| **GTKWave** or **Surfer** | WSL/Windows | View waveforms (signals over time) |
| **RISC-V GCC toolchain**: xPack `riscv-none-elf-gcc` (Windows or Linux build) | both | Compile C → RISC-V. Includes **newlib / newlib-nano** (the small C library) with rv32im multilibs |
| **Spike** (RISC-V ISA simulator) | WSL | The "golden reference" our CPU is compared against |
| **riscv-tests** and **RISCOF** | WSL | Official instruction tests and a compliance framework |
| **Python 3 + pyserial (+ pygame later)** | Windows | Our `load.py` bootloader client, keyboard sender, frame viewer |
| Serial terminal: **PuTTY** / **Tera Term** | Windows | See `printf` output |
| **Git** | both | Version control (commit after every working step!) |

> Note on naming: HOLY's Makefiles use the prefix `riscv32-unknown-elf-`. xPack uses `riscv-none-elf-`. They are the same compiler with a different name. We use a `CROSS` variable in our Makefiles, so either works.

---

## 7. System architecture (the whole chip)

### 7.1 Block diagram

```
                                   NEXYS A7-100T
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  FPGA (Artix-7 100T)                                                                 │
│                                                                                      │
│   100 MHz ──► [ MMCM clock generator ] ──► clk_cpu (50 MHz → later 100 MHz+)          │
│                                        ──► clk_pix (25 MHz, VGA)                      │
│                                        ──► clk_200 (200 MHz, for MIG)                 │
│                                                                                      │
│   ┌──────────────────────── CPU CLOCK DOMAIN ───────────────────────────┐            │
│   │                                                                     │            │
│   │   ┌────────────────────────────────────────────┐                    │            │
│   │   │     RV32IM 5-stage pipelined CORE          │                    │            │
│   │   │  IF → ID → EX → MEM → WB   + CSRs + traps  │                    │            │
│   │   └───────┬──────────────────────────┬─────────┘                    │            │
│   │     instr │ port                data │ port                         │            │
│   │   ┌───────▼───────┐          ┌───────▼────────┐                     │            │
│   │   │  I-CACHE      │          │   D-CACHE      │                     │            │
│   │   │  16 KB        │          │   16 KB        │                     │            │
│   │   │  read-only    │          │   write-back   │                     │            │
│   │   └───────┬───────┘          └──┬─────────┬───┘                     │            │
│   │           │ (misses)   (misses) │         │ uncached (MMIO)         │            │
│   │   ┌───────▼─────────────────────▼──┐  ┌───▼────────────────────┐    │            │
│   │   │  AXI ARBITER (D$ has priority) │  │  MMIO BUS + ADDRESS    │    │            │
│   │   │  → one AXI4 master, 32-bit     │  │  DECODER               │    │            │
│   │   └───────────────┬────────────────┘  └─┬───┬───┬───┬───┬───┬──┘    │            │
│   │                   │                     │   │   │   │   │   │       │            │
│   │                   │                  BOOT UART TMR LED PS2 VGA-ctrl │            │
│   │                   │                  ROM                  ▲   │     │            │
│   └───────────────────┼───────────────────────────────────────┼───┼─────┘            │
│                       │                                       │   │                  │
│   ┌───────────────────▼───────────────────┐       ┌───────────┴───▼──────────────┐   │
│   │ Xilinx AXI Interconnect (glue only)   │       │ FRAMEBUFFER BRAM 320×200×8b  │   │
│   │  32-bit @ clk_cpu → 128-bit @ ui_clk  │       │ + PALETTE RAM 256×12b        │   │
│   └───────────────────┬───────────────────┘       │ (dual-port: CPU writes,      │   │
│                       │                           │  VGA reads @ clk_pix)        │   │
│   ┌───────────────────▼───────────────────┐       └───────────────┬──────────────┘   │
│   │ Xilinx MIG 7-series (DDR2 controller) │       ┌───────────────▼──────────────┐   │
│   │ user side: AXI4 slave @ ui_clk        │       │ VGA TIMING 640×480 @ 60 Hz   │   │
│   └───────────────────┬───────────────────┘       │ 2× scale, palette lookup     │   │
└───────────────────────┼───────────────────────────┴───────────────┬──────────────┴───┘
                        │                                           │
                ┌───────▼────────┐                           ┌──────▼──────┐
                │ 128 MB DDR2    │                           │  VGA port   │──► monitor
                └────────────────┘                           └─────────────┘
   USB-UART ◄──► UART      USB-HID (PIC24) ──PS/2──► PS2 receiver      LEDs/7-seg/switches
```

### 7.2 What lives where

| Place | Contents |
|---|---|
| **FPGA logic** | CPU core, caches, arbiter, MMIO bus, UART, timer, PS/2 receiver, VGA controller, LED/7-seg driver, MMCM, MIG controller, AXI interconnect |
| **FPGA Block RAM (on-chip, fast)** | Boot ROM (16 KB), I-cache data + tags, D-cache data + tags, framebuffer (64 KB), palette |
| **DDR2 chip (off-chip, big, slow)** | DOOM program code, the WAD file, DOOM's heap (zone memory), stack |
| **Laptop** | Compilers, Vivado, `load.py` loader, serial terminal. **No game code runs on the laptop.** |
| **Monitor** | Just shows the VGA signal |

### 7.3 Our design decisions and why

| Decision | Choice | Why | Compared to references |
|---|---|---|---|
| HDL language | **SystemVerilog** | Industry standard, Vivado-native, HOLY's course material is in it | HOLY: SV. Armaan: Chisel |
| Core type | **5-stage pipeline** (after a single-cycle warm-up) | Much faster clock and throughput. BRAM-based caches have 1-cycle read latency, which fits a pipeline naturally | HOLY: single-cycle. Armaan: 5-stage |
| ISA | **RV32IM + Zicsr + Zifencei** | Full M (with divide) avoids slow software division | HOLY: RV32I (+M in perf edition). Armaan: RV32I+Zmmul (no divide) |
| Caches | 16 KB I$ + 16 KB D$, 32-byte lines, direct-mapped first, 2-way later | Big enough to matter, lines long enough for good spatial locality | HOLY: ~1 KB 2-way, 64-byte lines. Armaan: 32 KB direct-mapped, 16-byte lines (he said the lines were too short) |
| Memory bus to DDR | **AXI4** (our arbiter) → **Xilinx AXI Interconnect** → MIG | MIG speaks AXI. Letting the Xilinx interconnect do the clock and width conversion avoids hand-written clock-crossing bugs | HOLY: AXI + Xilinx IPs. Armaan: hand-made CDC FIFOs (he found bugs there) |
| Peripheral bus | **Our own simple MMIO bus** (not AXI-Lite) | Very simple: address, write-data, write-enable, byte-strobes, read-data, ready. Easy to understand and test | HOLY: AXI-Lite + Xilinx IPs (UART-lite, QSPI, GPIO) |
| Peripherals | **All written by us** (UART, timer, VGA, PS/2, LEDs) | Each is 50–200 lines, and you learn everything | HOLY: mostly Xilinx IP. Armaan: custom |
| Display | **VGA with BRAM framebuffer + hardware palette** | CPU writes 1 byte per pixel, and hardware converts to colour, so palette effects (red damage flash) are free | HOLY: SPI LCD (slow, no palette updates). Armaan: VGA/HDMI BRAM framebuffer |
| Program loading | **UART bootloader in boot ROM** | No extra hardware needed, same cable as programming | HOLY: JTAG debug module + OpenOCD + GDB (needs an extra JTAG dongle) |
| Input | **PS/2 (USB keyboard) + UART keys** | Real key-press and key-release events | Both: UART only (HOLY fakes key releases) |
| Timer | 64-bit µs counter + `mcycle`/`minstret` CSRs | Game timing + performance measurements | HOLY: RISC-V CLINT `mtime`. Armaan: µs timer |
| DOOM code base | **smunaut `doom_riscv`, as adapted in HOLY_CORE_DOOM** | Proven bare-metal RISC-V port, gives us 8-bit palettised output which matches our hardware palette | HOLY: same. Armaan: doomgeneric |

---

## 8. The CPU core

### 8.1 What a CPU does (beginner view)

Forever:
1. **Fetch**: read the instruction at address `PC` (program counter).
2. **Decode**: figure out what it is (add? load? branch?) and which registers it uses.
3. **Execute**: do the math in the **ALU** (arithmetic logic unit) or compute an address.
4. **Memory**: for loads and stores, read or write data memory.
5. **Write back**: write the result into the destination register.
6. Update `PC` (usually `PC + 4`, or a branch/jump target).

RISC-V has **32 registers** `x0..x31`, each 32 bits (`x0` is always 0).

### 8.2 Warm-up: single-cycle CPU (Phase 1)

All five steps happen in **one** clock cycle. It's simple but slow, because the clock must wait for the longest path. We build this first, **in simulation only**, to learn every block.

🔗 **Borrowed from HOLY CORE:** `0_single_cycle_edition/` is our tutorial. Read its `src/` and `tb/` to see how the blocks are split. We use the same split and the same unit-test idea (one cocotb testbench per block):

| Block | File (ours) | HOLY equivalent | Job |
|---|---|---|---|
| ALU | `rtl/core/alu.sv` | `src/alu.sv` | add, sub, and, or, xor, shifts, compares |
| Register file | `rtl/core/regfile.sv` | `src/regfile.sv` | 32 × 32-bit registers, 2 read ports, 1 write port |
| Immediate generator | `rtl/core/imm_gen.sv` | `src/signext.sv` | Builds the constant from the instruction bits (I/S/B/U/J formats) |
| Decoder / control | `rtl/core/decoder.sv` | `src/control.sv` | Turns the opcode into control signals |
| Load/store unit | `rtl/core/lsu.sv` | `src/load_store_decoder.sv`, `src/reader.sv` | Byte-strobes for `sb/sh/sw`; sign/zero-extend for `lb/lbu/lh/lhu` |
| Top | `rtl/core/core_single.sv` | `src/cpu.sv` | Wires everything |

### 8.3 The real core: 5-stage pipeline (Phase 2)

Split the work into 5 stages with **pipeline registers** between them. Like a factory line, 5 instructions are in flight at once and each stage is short, so the clock can be much faster.

```
 cycle:      1    2    3    4    5    6    7
 instr A:   IF   ID   EX   MEM  WB
 instr B:        IF   ID   EX   MEM  WB
 instr C:             IF   ID   EX   MEM  WB
```

🔗 **Borrowed from Armaan:** the 5-stage architecture, and his lesson to **track register usage explicitly** for hazard detection (he replaced fragile hazard logic with a "Register Usage Map"). We use the classic, well-documented forwarding + hazard unit from Patterson & Hennessy / Harris & Harris.

**Hazards (problems pipelines create) and our fixes:**

| Hazard | Example | Fix |
|---|---|---|
| **Data hazard** | `add x1,x2,x3` then `sub x4,x1,x5` (x1 is not written back yet) | **Forwarding**: send the result from the EX/MEM or MEM/WB stage straight back to the ALU input |
| **Load-use hazard** | `lw x1,0(x2)` then `add x3,x1,x1` | **Stall** 1 cycle (insert a bubble), then forward |
| **Control hazard** | Branch taken: the next 2 instructions were fetched wrongly | **Flush** them (turn them into bubbles). Later: **branch prediction** to reduce the cost |
| **Structural / memory stall** | Cache miss: memory needs 20–60 cycles | **Global stall**: freeze the whole pipeline until the cache is ready |

**Global stall rule (simple and robust):**
`stall_all = icache_busy | dcache_busy | divider_busy`. When `stall_all = 1`, every pipeline register keeps its value.
🔗 **Borrowed from HOLY CORE:** `holy_core.sv` does exactly this (`assign stall = d_cache_stall | i_cache_stall | alu_stall;`).

### 8.4 Multiply and divide (M extension)

- `mul`, `mulh`, `mulhsu`, `mulhu`: use the FPGA's **DSP48** blocks. Pipelined over 2 cycles (stall 1 cycle, or pipeline it into the MEM stage).
- `div`, `divu`, `rem`, `remu`: an **iterative divider**, 1 bit per cycle, about 33 cycles. It asserts `divider_busy` to stall. Rare in DOOM, so slow is fine.

🔗 **Borrowed from HOLY CORE:** `3_perf_edition/src/mul_div_unit.sv` is a reference.
🔗 **From Armaan:** adding multiply took him from ~2.5 to ~3.5 FPS. It matters.

### 8.5 CSRs and traps (minimal machine mode)

We run only in **machine mode** (the highest privilege, no OS). We implement:

| CSR | Why |
|---|---|
| `mstatus`, `mtvec`, `mepc`, `mcause`, `mtval`, `mscratch` | So that a crash (illegal instruction, misaligned access, `ebreak`) jumps to our **trap handler**, which prints PC, cause and registers over UART. This is essential for debugging |
| `mcycle`, `minstret` (+ `cycle`, `instret`, `time` read-only aliases) | Measure performance: CPI, cycles per frame |
| `misa`, `mhartid` | Standard identification (easy) |

Interrupts are **not needed** for DOOM (everything is polled). We can add a timer interrupt later.

🔗 **Borrowed from HOLY CORE:** `2_soc_software_edition/src/csr_file.sv` shows a full CSR file, and its RISCOF setup shows how to prove compliance.

### 8.6 Core ↔ memory interface (the contract with the caches)

Two identical ports, **instruction** and **data**:

```
core → cache :  req      (1 = I want something this cycle)
                addr     [31:0]
                we       (1 = write)
                wdata    [31:0]
                wstrb    [3:0]  (which bytes to write, for sb/sh/sw)
cache → core :  rdata    [31:0]
                ready    (1 = request done this cycle; 0 = stall)
```

This is simple and cycle-accurate. Every cache and memory in the project speaks this interface, so we can swap an **ideal memory** (simulation), a **BRAM** (early FPGA) or **caches + DDR** (final) without touching the core.

---

## 9. The caches

### 9.1 Why caches?

DDR2 is big but **slow**: a single access takes roughly 20–60 CPU cycles once you include the controller. Without caches, every instruction fetch would wait that long, giving less than 1 FPS. A **cache** is a small, fast memory (on-chip BRAM, 1 cycle) that keeps copies of recently used memory. Programs reuse the same code and data a lot, so 95%+ of accesses **hit** in the cache.

### 9.2 Cache vocabulary

- **Line (block):** the chunk copied from DDR at once. Ours is **32 bytes** (8 words).
- **Hit:** the data is in the cache, so we answer in 1 cycle.
- **Miss:** it isn't, so we stall, fetch the whole line from DDR (an AXI **burst**), store it, then answer.
- **Tag:** the high address bits, stored with each line to remember *which* memory line it holds.
- **Valid bit:** the line contains real data.
- **Dirty bit (D$ only):** the line was modified and must be written back to DDR before being replaced.
- **Direct-mapped:** each address can only go into one place in the cache. **2-way set-associative:** each address can go into one of two places (fewer conflicts).
- **Write-back:** stores go into the cache only, and DDR is updated when the line is evicted. **Write-allocate:** on a store miss, first fetch the line.

### 9.3 Our cache parameters (start)

| | I-cache | D-cache |
|---|---|---|
| Size | 16 KB | 16 KB |
| Line | 32 B (8 words) | 32 B |
| Lines | 512 | 512 |
| Associativity | direct-mapped | direct-mapped → 2-way LRU later |
| Writes | none (read-only) | write-back, write-allocate, byte strobes |
| Address split (32-bit) | tag[31:14] · index[13:5] · word[4:2] · byte[1:0] | same |
| Storage | data: BRAM; tags + valid: BRAM or LUT-RAM | + dirty bits |

All sizes are **parameters**, so we can try 32 KB or 64 KB later (we have ~607 KB of BRAM).

### 9.4 Cache state machine (D-cache)

```
          ┌────────────────────────────────────────────────┐
          ▼                                                │
       [IDLE] ── req & hit ──► answer in 1 cycle ──────────┤
          │                                                │
          │ req & miss                                     │
          ▼                                                │
   line dirty? ──yes──► [WRITEBACK] AXI write burst 8 beats│
          │ no                    │                        │
          ▼                       ▼                        │
       [REFILL] AXI read burst 8 beats, fill BRAM          │
          │                                                │
          ▼                                                │
       [RESPOND] do the original load/store ───────────────┘

   Uncached address (not DDR)? → [MMIO] single access on MMIO bus → IDLE
   fence.i? → [FLUSH] write back every dirty line → IDLE  (+ I$ invalidates all)
```

### 9.5 Cacheable vs uncached

- `0x8000_0000–0x87FF_FFFF` (DDR2) → **cached**.
- **Everything else** (UART, timer, VGA, keyboard...) → **uncached**. If the UART status register were cached, the CPU would read a stale copy forever.

🔗 **Borrowed from HOLY CORE:** it chooses the cached range with custom CSRs `0x7C1–0x7C4` (set in `HOLY_CORE_DOOM/src/holy_core/start.S`) and has a separate `holy_no_cache.sv` path for peripherals. We simplify this to a **fixed address decode** (`addr[31:28] == 4'h8` → cached), so there are no CSRs to set.

### 9.6 `fence.i`: keeping instruction and data caches consistent

The bootloader **writes** DOOM's code into DDR using **stores** (so the data goes into the D-cache and may stay there, dirty). Then it **jumps** to DOOM. The I-cache reads DDR, which may still hold old garbage, and the CPU crashes.

Fix: before jumping, the bootloader executes `fence.i`, which makes the **D-cache write back all dirty lines** and the **I-cache invalidate everything**.

🔗 **Lesson from Armaan:** one of his bugs was "DCache overwriting instruction data". 🔗 HOLY's `start.S` has a commented-out write to custom CSR `0x7C0`, which appears to be its cache-control hook. We use the **standard** `fence.i` instruction instead.

### 9.7 The AXI arbiter

The I-cache and D-cache both need DDR but there is only **one** memory port. The arbiter lets one of them use it at a time and **finishes the whole burst** before switching.
🔗 **Borrowed from Armaan (and HOLY's `external_req_arbitrer.sv`):** give the **D-cache priority**. Armaan found that the other way around can **deadlock/starve**.

---

## 10. Memory: DDR2 through Xilinx MIG

### 10.1 What is MIG?

DDR memory needs a very complicated controller (calibration, refresh, precise timing). Xilinx provides one for free: the **Memory Interface Generator (MIG)** IP. We configure it in Vivado and it gives us a simple **AXI4 slave port** on the "user side".

### 10.2 MIG settings for Nexys A7 DDR2

Use **Digilent's Nexys A7 DDR2 MIG guide/project file** (on the Digilent reference site). They provide the correct pinout. The typical settings:

| Setting | Typical value |
|---|---|
| Memory part | MT47H64M16HR-25E (DDR2, 16-bit) |
| Memory clock | 325 MHz (3077 ps) |
| PHY:controller ratio | 4:1 → **ui_clk ≈ 81.25 MHz** |
| Input system clock | 200 MHz (from our MMCM, "no buffer") |
| Reference clock | 200 MHz (same clock) |
| User interface | **AXI4**, data width **128 bits** |

> Always double-check these against Digilent's current documentation. They are the source of truth for the pinout.

### 10.3 How our 32-bit caches talk to the 128-bit MIG

```
our arbiter (AXI4, 32-bit, clk_cpu)
      │
      ▼
Xilinx AXI Interconnect IP ── does clock conversion (clk_cpu → ui_clk)
      │                      and width conversion (32 → 128 bits)
      ▼
MIG (AXI4 slave, 128-bit, ui_clk) ──► DDR2 chip
```

🔗 **Lesson from Armaan:** his hand-written clock-domain crossing to the MIG **dropped write-back requests**. We use Xilinx's proven interconnect for that one boundary. In simulation, the whole Xilinx part is replaced by a Python AXI RAM model (`cocotbext-axi`).

### 10.4 Bring-up rules

- MIG raises **`init_calib_complete`** when DDR is ready. Hold the CPU in reset until then, and show it on an LED.
- DDR contents **survive a CPU reset** (button) as long as the FPGA isn't reprogrammed. That means we can load the WAD once and reload only the program when iterating.
- DDR powers up with **random garbage**. Never assume zeroes (see §19).

---

## 11. Clocks and clock-domain crossings

| Clock | Frequency | Made by | Used by |
|---|---|---|---|
| `clk_100` | 100 MHz | board oscillator | input to MMCM |
| `clk_cpu` | **50 MHz** at first → 75/100 MHz later | MMCM | core, caches, MMIO, peripherals |
| `clk_pix` | 25 MHz (VGA standard is 25.175; 25.0 works on almost all monitors) | MMCM | VGA timing + framebuffer read port |
| `clk_200` | 200 MHz | MMCM | MIG system + reference clock |
| `ui_clk` | ~81.25 MHz | MIG output | MIG AXI port side of the interconnect |

**Clock-domain crossings (CDC):** a signal going from one clock to another can be read "half-changed" (metastability). Where we cross and how we make it safe:

| Crossing | Safe method |
|---|---|
| CPU ↔ MIG | Xilinx AXI Interconnect (built-in async FIFOs) |
| CPU writes framebuffer / palette ↔ VGA reads | **True dual-port BRAM** with a separate clock on each port (BRAMs handle this natively) |
| VGA "vblank" status → CPU | 2-flip-flop synchroniser (1-bit signal) |
| PS/2 clock/data pins, UART RX pin (asynchronous inputs) | 2-flip-flop synchroniser + glitch filter |
| Resets | Asynchronous assert, synchronous de-assert, one reset synchroniser per domain |

---

## 12. Memory map

The CPU sees one 32-bit address space. Each address range belongs to one device.

| Address range | Size | Device | Cached? |
|---|---|---|---|
| `0x0000_0000 – 0x0000_3FFF` | 16 KB | **Boot ROM** (BRAM, bootloader, **reset vector = 0x0000_0000**) | no |
| `0x1000_0000 – 0x1000_00FF` | | **UART** | no |
| `0x1000_1000 – 0x1000_10FF` | | **Timer** (64-bit µs counter) | no |
| `0x1000_2000 – 0x1000_20FF` | | **LEDs, switches, buttons, 7-segment** | no |
| `0x1000_3000 – 0x1000_30FF` | | **PS/2 keyboard** | no |
| `0x1000_4000 – 0x1000_4FFF` | | **VGA control + palette** (256 × 12-bit) | no |
| `0x2000_0000 – 0x2000_F9FF` | 64,000 B | **Framebuffer** (320×200, 1 byte per pixel) | no |
| `0x8000_0000 – 0x85FF_FFFF` | 96 MB | **DDR2: program, data, heap, stack** | **yes** |
| `0x8600_0000 – 0x87FF_FFFF` | 32 MB | **DDR2: WAD file area** (+ spare) | **yes** |
| anything else | | unmapped → access fault trap | |

🔗 **Borrowed from HOLY CORE:** the idea of a single header file describing the memory map (`3_perf_edition/hc_lib/include/holy_core_soc.h`), and RAM at `0x8000_0000` (a common RISC-V convention). Our version is `sw/lib/include/soc.h`.

---

## 13. Peripherals

Every peripheral is a small block of **memory-mapped registers**. The CPU reads and writes them like memory (`*(volatile uint32_t*)0x10000004 = 'A';`). Offsets below are from the device base.

### 13.1 UART (`0x1000_0000`)

Talks to the laptop through the board's USB-UART chip. The format is 8N1 (8 data bits, no parity, 1 stop bit).

| Offset | Name | Meaning |
|---|---|---|
| 0x00 | `DATA` | write: send a byte (into the TX FIFO). read: receive a byte (from the RX FIFO) |
| 0x04 | `STATUS` | bit0 RX has data, bit1 TX FIFO full, bit2 TX idle |
| 0x08 | `BAUDDIV` | clock cycles per bit (`clk_cpu / baud`) |

- **Baud rate:** start at **115,200** (safe). The bootloader switches to **2,000,000** (2 Mbaud) or **4,000,000**. Both divide exactly from 100 MHz and from the FTDI chip's 12 MHz base clock, so there is no rate error.
- **FIFOs** (e.g. 256 bytes TX and RX) so `printf` never blocks for long and incoming bytes are never lost.
  🔗 **From Armaan:** he added a TX FIFO because characters were dropped during rapid `printf`.

### 13.2 Timer (`0x1000_1000`)

| Offset | Name | Meaning |
|---|---|---|
| 0x00 | `TIME_LO` | microseconds since reset, low 32 bits |
| 0x04 | `TIME_HI` | high 32 bits (read LO first; hardware latches HI on LO read) |

DOOM's tic counter: `tics = (time_us * 35) / 1_000_000` (64-bit math, so it never drifts).
🔗 **From HOLY_CORE_DOOM `i_system.c`:** `I_GetTime()` divides the CLINT `mtime` by 714286 (a 25 MHz tick). We do the same thing with microseconds.
🔗 **From Armaan:** a microsecond hardware timer. And the pointer **must** be `volatile` (§19).

### 13.3 LEDs / switches / buttons / 7-segment (`0x1000_2000`)

| Offset | Meaning |
|---|---|
| 0x00 | LEDs (16 bits) |
| 0x04 | switches (read) |
| 0x08 | buttons (read) |
| 0x0C | 7-segment value (32 bits shown as 8 hex digits) |

Very useful for debugging: show the current PC, the trap cause, or FPS on the 7-segment.
🔗 **Borrowed from HOLY CORE:** its boot ROM blinks an LED at `0x1001_0000` as the first proof of life. We do the same.

### 13.4 PS/2 keyboard (`0x1000_3000`)

The Nexys A7's PIC24 chip turns a USB keyboard into **PS/2** signals (a clock line and a data line). Our receiver:
1. Synchronises and filters `PS2_CLK` and `PS2_DATA`.
2. On each falling edge of `PS2_CLK`, shifts in a bit (11-bit frame: start, 8 data, parity, stop).
3. Pushes each received byte into a small FIFO.

| Offset | Meaning |
|---|---|
| 0x00 | `DATA`: next scancode byte (read pops the FIFO) |
| 0x04 | `STATUS`: bit0 = FIFO not empty |

Software decodes **scancode set 2**: a key press sends its code (e.g. `0x1D` = W), a key release sends `0xF0` then the code, and extended keys (arrows) are prefixed with `0xE0`. This gives DOOM **true key-down and key-up events**.

### 13.5 VGA display (`0x1000_4000` control + `0x2000_0000` framebuffer)

**How DOOM draws:** DOOM renders every frame into a **320×200 array of bytes** (`screens[0]`). Each byte is a **palette index** 0–255, not a colour. A separate **palette** (256 entries of R,G,B) says what colour each index is. DOOM changes the palette to create effects: red when hurt, yellow on item pickup, green with the radiation suit.

**Our hardware copies this exactly:**

```
  CPU writes bytes ──► FRAMEBUFFER BRAM (64,000 × 8 bit)
                              │ read @ 25 MHz
                              ▼
  CPU writes colours ─► PALETTE RAM (256 × 12 bit: R4 G4 B4)
                              │
                              ▼
                       VGA TIMING GENERATOR 640×480 @ 60 Hz
                       each DOOM pixel shown as 2×2 real pixels
                       (320×200 → 640×400, 40 black lines top/bottom)
                              │
                              ▼
                       VGA_R[3:0] VGA_G[3:0] VGA_B[3:0] HSYNC VSYNC ──► monitor
```

**VGA 640×480 @ 60 Hz timing** (pixel clock 25 MHz):

| | Visible | Front porch | Sync pulse | Back porch | Total |
|---|---|---|---|---|---|
| Horizontal (pixels) | 640 | 16 | 96 | 48 | 800 |
| Vertical (lines) | 480 | 10 | 2 | 33 | 525 |

Both syncs are active-low. 800 × 525 × 60 ≈ 25.2 MHz.

**Registers:**

| Offset | Meaning |
|---|---|
| 0x000 | `CTRL`: bit0 enable, bit1 aspect-correct mode (optional) |
| 0x004 | `STATUS`: bit0 = in vertical blank (for tear-free updates) |
| 0x400–0x7FC | `PALETTE[0..255]`: write `0x0RGB` (12-bit) |

**Why this is better than both references:**
- vs **HOLY** (SPI LCD): the CPU there sends 128,000 bytes over SPI **every frame**, which is very slow, and its `i_video.c` builds the palette **only once** (`pal_ready`), so damage flashes never show. Ours: palette changes are one 256-word write, and pixels are one byte each.
- vs **Armaan**: 🔗 we borrow his key idea, **"write directly into the VGA BRAM"** (one of his big speed-ups, ~3.5 → ~6.7 FPS together with faster cache hits), and add a hardware palette so the CPU never converts colours.

**Optional "aspect-correct" mode:** DOOM was designed for 320×200 shown on a 4:3 screen (pixels 20% taller than wide). 200 × 2.4 = 480, so repeating rows in the pattern 2,2,3,2,3 fills 480 lines exactly with the original look.

**BRAM budget:** framebuffer 64,000 B ≈ 14 BRAM36 blocks. Out of 135. No problem.

---

## 14. Loading programs: the UART bootloader

### 14.1 Why

DOOM + WAD is about 5.5 MB. It can't be inside the bitstream (on-chip RAM is only 607 KB). It must be **copied into DDR2 after the FPGA is programmed**.

🔗 **What HOLY does:** a debug module (PULP `riscv-dbg`) + an external Digilent HS2 JTAG dongle + OpenOCD + GDB `load`. That's powerful, but it needs extra hardware and a complex setup.
🔗 **Armaan's blog** doesn't say how he loaded it.

**Ours:** a tiny program in the **boot ROM** (on-chip BRAM, baked into the bitstream) that receives data over the **UART** and writes it to DDR2.

### 14.2 Boot flow

```
Power on / program FPGA
   │
   ▼
CPU reset → PC = 0x0000_0000 (boot ROM)
   │
   ▼
Bootloader: wait for DDR calibration → print "BOOT OK" → LED on
   │
   ▼
Wait for commands from load.py on the laptop:
   WRITE addr len data crc  → store bytes into DDR, reply ACK/NAK
   BAUD  new_rate           → switch to 2–4 Mbaud for speed
   JUMP  addr               → fence.i (flush D$, invalidate I$), jump
   │
   ▼
DOOM's _start at 0x8000_0000 runs
```

### 14.3 Timing

- WAD 4.2 MB at 2 Mbaud (~200 KB/s) ≈ **21 s**. At 4 Mbaud ≈ **11 s**.
- Program ~1–1.5 MB ≈ 5 s.
- The WAD survives CPU resets, so while developing you usually reload **only the program**.

### 14.4 Files

- `sw/bootloader/`: bootloader C + assembly, built into `boot_rom.hex` and loaded into the ROM with `$readmemh` at synthesis.
  🔗 **Borrowed from HOLY CORE:** `3_perf_edition/fpga/ROM/` (`rom.S`, `gen_rom.py`, `boot_rom.v`) shows how to turn a program into a ROM hex file.
- `tools/load.py`: laptop side (pyserial). It reads the ELF, sends its segments, sends the WAD, then sends JUMP.

### 14.5 Later upgrade (optional)

Store the WAD in the board's **16 MB QSPI flash** or on a **microSD card**, and copy it to DDR at boot, so the laptop is no longer needed at all.

---

## 15. Software stack: bare-metal C and the DOOM port

### 15.1 Layers

```
┌──────────────────────────────────────────────────────┐
│ DOOM engine (id Software C code, ~60 files)          │  mostly unchanged
├──────────────────────────────────────────────────────┤
│ DOOM platform layer: i_video.c i_system.c i_main.c   │  WE WRITE / ADAPT
│ i_sound.c(stub) i_net.c(stub) d_main.c(simplified)   │
├──────────────────────────────────────────────────────┤
│ libc_backend.c: _sbrk _open _read _lseek _write ...  │  fake OS
├──────────────────────────────────────────────────────┤
│ newlib-nano: malloc, memcpy, printf, strcmp, ...     │  from the toolchain
├──────────────────────────────────────────────────────┤
│ our driver lib (sw/lib): uart, timer, vga, ps2, leds │  WE WRITE
├──────────────────────────────────────────────────────┤
│ crt0.S (startup) + link.ld (memory layout)           │  WE WRITE
╞══════════════════════════════════════════════════════╡ ← hardware
│ our CPU + SoC                                        │
└──────────────────────────────────────────────────────┘
```

### 15.2 Compiler flags explained

```make
CROSS  ?= riscv-none-elf-
CFLAGS  = -march=rv32im_zicsr_zifencei -mabi=ilp32 \
          -O2 -mstrict-align -ffreestanding -nostartfiles \
          --specs=nano.specs -Wl,--gc-sections -Wall
```

| Flag | Meaning |
|---|---|
| `-march=rv32im_zicsr_zifencei` | Only emit instructions our CPU implements |
| `-mabi=ilp32` | 32-bit ints/longs/pointers, no floating-point registers |
| `-O2` | Optimise (Armaan: the biggest single speed-up, ~6.7 → 15–20 FPS). **Start with `-O0`/`-O1` while debugging** |
| `-mstrict-align` | Never generate misaligned loads/stores (our core traps on them) |
| `-ffreestanding -nostartfiles` | No OS, and we provide our own startup code |
| `--specs=nano.specs` | Use newlib-nano (small C library) |
| `-Wl,--gc-sections` | Drop unused code |

🔗 **Borrowed from HOLY_CORE_DOOM `src/holy_core/Makefile`:** the same flag set (they use `-O1 -march=rv32im`).

### 15.3 Linker script (`link.ld`): where things go in memory

```
0x8000_0000 ┌───────────────────────┐
            │ .text   (code)        │  ← _start is first
            │ .rodata (constants)   │
            │ .data   (initialised) │
            │ .bss    (zeroed)      │
            │ heap  ↓ grows up      │  ← _heap_start (malloc via _sbrk)
            │         ...           │
            │ stack ↑ grows down    │
0x8600_0000 ├───────────────────────┤  ← __stacktop
            │ WAD header + WAD file │  ← written by load.py
0x8800_0000 └───────────────────────┘
```

🔗 **Borrowed from HOLY_CORE_DOOM `riscv.lds`:** the section layout and the symbols `_sbss/_ebss`, `_heap_start` and `__stacktop`. Difference: HOLY links the WAD **inside** the program (`objcopy -I binary doom1.wad wad.o`). We keep the WAD at a **fixed separate address**, so re-sending the program doesn't re-send 4.2 MB every time. (Linking it in HOLY's way also works as a fallback.)

### 15.4 Startup code (`crt0.S`)

1. Set the stack pointer `sp = __stacktop`.
2. Set `mtvec` = our trap handler (prints the crash info).
3. **Zero `.bss`**: C requires uninitialised globals to be 0, and DDR is random at power-up.
4. Call `main()`.

🔗 **Borrowed from HOLY_CORE_DOOM `start.S`:** the same steps (they also set cache ranges via CSRs, which we don't need).

### 15.5 The fake OS: `libc_backend.c`

🔗 **Borrowed from HOLY_CORE_DOOM `libc_backend.c`** (originally by smunaut), adapted:

| Function | What newlib needs it for | Our implementation |
|---|---|---|
| `_sbrk(n)` | `malloc` wants more memory | Move a pointer up from `_heap_start` (and error if it reaches the stack) |
| `_open("doom1.wad")` | DOOM opens its data file | Look the name up in a 1-entry table pointing at `0x8600_0000` + header |
| `_read(fd, buf, n)` | Read the file | `memcpy` from DDR + advance the offset |
| `_lseek` | Seek | Change the offset |
| `_write(1/2, ...)` | `printf` | Send bytes to the UART |
| `_close`, `_fstat`, `_isatty`, `access` | Misc | Trivial |

### 15.6 DOOM platform layer

| File | Origin | What we do |
|---|---|---|
| `i_main.c` | 🔗 HOLY_CORE_DOOM (smunaut) | `main()` → `D_DoomMain()`. Unchanged |
| `d_main.c` | 🔗 HOLY_CORE_DOOM simplified version | Keep it (no command line, no config files) |
| `i_system.c` | 🔗 HOLY_CORE_DOOM, **modified** | `I_ZoneBase`: give DOOM **16 MB** (HOLY gives 6 MB). `I_GetTime`: our µs timer. Input: **real key-down/up** from PS/2 or UART instead of HOLY's "release everything every tic" trick |
| `i_video.c` | **rewritten** (HOLY's version drives an SPI LCD) | `I_SetPalette` → write 256 entries to the hardware palette (converted to 12-bit). `I_FinishUpdate` → copy `screens[0]` (64,000 B) to the framebuffer. Later optimisation: point `screens[0]` straight at the framebuffer (🔗 Armaan's idea) |
| `i_sound.c`, `s_sound.c` | 🔗 HOLY_CORE_DOOM stubs | Silent for now (sound is a stretch goal) |
| `i_net.c` | 🔗 HOLY_CORE_DOOM stub | Single player only |
| `config.h` | 🔗 HOLY_CORE_DOOM | Feature switches (`NOMONSTERS`, `NOTRANSLUCENCY`, `NOSMOOTH`). We'll test turning these back on once performance allows |
| `console.c`, `mini-printf.c` | 🔗 HOLY_CORE_DOOM | Tiny `printf` for UART (🔗 Armaan's teammate also ended up writing his own printf) |

**The WAD:** `doom1.wad` is the **shareware** episode (4,196,020 bytes), freely distributable. HOLY_CORE_DOOM includes a copy.

**License:** the DOOM source code is GPL-2.0, so our `sw/doom/` directory is GPL-2.0 too. Check the HOLY CORE repositories' licenses before copying any file verbatim. For RTL we write our own and only *read* theirs as reference.

---

## 16. Verification strategy (how we find bugs)

DOOM runs ~100+ million instructions before the first frame. A single wrong instruction anywhere shows up as a mystery crash hours later. So we test **bottom-up**, with increasingly large programs.

### 16.1 Levels of testing

| Level | Tool | What | 🔗 Source |
|---|---|---|---|
| 1. Unit tests | cocotb + Icarus/Verilator | Each block alone (ALU, regfile, decoder, cache, UART...) with Python-generated random inputs vs a Python model | HOLY's `tb/<block>/` folders |
| 2. Instruction tests | **riscv-tests** (`rv32ui`, `rv32um`) | Small assembly programs, each checking one instruction and reporting pass/fail | Standard |
| 3. Compliance | **RISCOF** vs **Spike** | Official architecture test suite, results compared against the reference simulator | HOLY `2_soc_software_edition/riscof/` |
| 4. Trace comparison | Our sim log vs Spike `--log-commits` | Log `PC, instruction, rd, value` for every retired instruction and diff against Spike. The **first difference is the bug** | Standard technique |
| 5. C programs in simulation | Verilator full-system | hello world, memtest, printf, malloc, coremark | |
| 6. Full-system sim with **realistic memory** | Verilator + DDR model with **random latency** and **random initial contents** | Catches cache/stall bugs and "assumes memory is zero" bugs | 🔗 Armaan's key lesson |
| 7. DOOM in simulation | Verilator; framebuffer dumped to PNG files | See the title screen in sim before touching hardware | 🔗 Armaan ran DOOM in simulation too |
| 8. On hardware | UART logs, LEDs/7-seg, **Vivado ILA** (on-chip logic analyser) | Things that only break on real hardware (timing, DDR, CDC) | Both |

### 16.2 Rules

- **Commit to git after every passing step.**
- Every bug fixed gets a **test** that would have caught it.
- **Never debug DOOM first.** If something fails, reproduce it with the smallest possible program.
- Run all unit tests after every RTL change (a `make test` target).

---

## 17. Project folder layout

```
doom/
├── README.md                ← this file
├── docs/                    ← diagrams, notes, per-phase write-ups
├── rtl/
│   ├── core/                ← alu, regfile, imm_gen, decoder, lsu, csr, muldiv,
│   │                          hazard unit, core_single.sv, core_pipe.sv
│   ├── cache/               ← icache.sv, dcache.sv, axi_arbiter.sv
│   ├── bus/                 ← mmio_decoder.sv, axi_if.sv (interfaces)
│   ├── periph/              ← uart.sv, timer.sv, leds.sv, ps2.sv, vga.sv, boot_rom.sv
│   ├── soc/                 ← soc_top.sv (everything except FPGA-specific IP)
│   └── pkg/                 ← shared packages (opcodes, types)
├── tb/
│   ├── unit/                ← one cocotb folder per block (HOLY style)
│   ├── isa/                 ← riscv-tests / RISCOF runner
│   └── system/              ← Verilator full-system harness (C++), DDR model,
│                              UART-to-console, framebuffer-to-PNG
├── fpga/
│   └── nexys_a7/
│       ├── nexys_a7.xdc     ← pin constraints (from Digilent master XDC)
│       ├── top_nexys.sv     ← board top: MMCM, MIG, AXI interconnect, soc_top
│       ├── ip/              ← MIG .prj, clock wizard, interconnect configs
│       └── build.tcl        ← one-command Vivado build
├── sw/
│   ├── lib/                 ← soc.h, uart.c, timer.c, vga.c, ps2.c, crt0.S, link.ld
│   ├── bootloader/          ← boot ROM program
│   ├── tests/               ← hello, memtest, cachetest, vga_test, kbd_test, coremark
│   └── doom/                ← DOOM engine + our platform layer
└── tools/
    ├── load.py              ← UART loader (ELF + WAD)
    ├── elf2hex.py           ← ROM/sim memory images
    └── viewer.py            ← (stretch) UART frame viewer + keyboard sender
```

---

## 18. Step-by-step roadmap

Each phase has a **goal**, **what to build**, **what we borrow**, and a **"done when"** checklist. Don't start a phase until the previous one's checklist is fully ticked.

### Phase 0: Setup (≈ 1 week)

**Goal:** all tools working, and the board proven alive.

- [ ] Install Vivado (Artix-7 support) and the Digilent board files.
- [ ] Install WSL2 Ubuntu, then Verilator, Icarus, GTKWave, Python 3, cocotb, cocotbext-axi, pytest.
- [ ] Install the RISC-V GCC (xPack) and Spike. Compile a hello-world `.c` to `.elf` and inspect it with `objdump -d`.
- [ ] Vivado: make a tiny "blink LED + switches → LEDs" design for the Nexys A7 and program the board.
- [ ] Open PuTTY on the board's COM port (check Device Manager) to confirm the UART is visible.
- [ ] `git init` this folder and create the directory layout from §17.
- [ ] Read: the RISC-V ISA manual (unprivileged) chapters for RV32I and M; HOLY CORE `0_single_cycle_edition` docs.

**Done when:** an LED blinks from your own Verilog, and `riscv-none-elf-gcc` produces an ELF.

---

### Phase 1: Single-cycle RV32I CPU in simulation (≈ 2–3 weeks)

**Goal:** understand every block by building the simplest correct CPU.

- [ ] Write the ALU, regfile, imm_gen, decoder, LSU and single-cycle top (§8.2).
- [ ] A cocotb unit test per block (random tests vs a Python model).
- [ ] An ideal memory model (a Python dict or SV array) loaded from a `.hex`.
- [ ] Run hand-written assembly: arithmetic, loads/stores of all sizes, branches, `jal/jalr`, `lui/auipc`.
- [ ] Pass **riscv-tests `rv32ui-p-*`**.

🔗 **Borrow:** HOLY `0_single_cycle_edition/` module split and testbench style.

**Done when:** all `rv32ui` tests pass in simulation.

---

### Phase 2: 5-stage pipeline + M + CSRs (≈ 3–5 weeks)

**Goal:** the real core, still in simulation.

- [ ] Pipeline registers IF/ID, ID/EX, EX/MEM, MEM/WB.
- [ ] Forwarding unit, load-use stall, branch flush.
- [ ] Global stall input (for caches later), tested with an ideal memory that **randomly delays** `ready`.
- [ ] M extension: DSP multiplier + iterative divider.
- [ ] CSRs + traps (§8.5): `ecall`, `ebreak`, illegal instruction, misaligned address.
- [ ] `fence.i` handshake signal to the caches (it just completes for now).
- [ ] Retire-trace logger → compare with Spike (§16 level 4).
- [ ] Pass **riscv-tests `rv32ui` + `rv32um`**, then **RISCOF**.

🔗 **Borrow:** 5-stage structure (Armaan); `csr_file.sv`, `mul_div_unit.sv`, RISCOF setup (HOLY editions 2/3); global stall idea (HOLY `holy_core.sv`).

**Done when:** RISCOF passes, and the trace matches Spike on a C program with random memory delays.

---

### Phase 3: First silicon: CPU + BRAM + UART on the Nexys A7 (≈ 2 weeks)

**Goal:** C code running on the real board.

- [ ] `soc_top.sv`: core + 64 KB BRAM (instructions + data) + MMIO decoder + UART + timer + LEDs/7-seg.
- [ ] `sw/lib`: `crt0.S`, `link.ld` (BRAM version), `uart.c`, a minimal `printf`.
- [ ] Test programs: LED counter, "Hello from my CPU!", printf of numbers, timer demo, trap handler demo (deliberate illegal instruction → prints info).
- [ ] Vivado: clock wizard (MMCM) 100 → 50 MHz, constraints, meet timing (**WNS ≥ 0**).
- [ ] Try raising `clk_cpu` to 75 / 100 MHz and see where timing fails (learn to read timing reports).

🔗 **Borrow:** HOLY's "blink an LED first" boot ROM; HOLY `hc_lib` idea of a small driver library + SoC header; HOLY's `hello_world` example program.

**Done when:** the board prints "Hello" over UART, and a CoreMark or Dhrystone score is printed.

---

### Phase 4: Caches (≈ 3–4 weeks)

**Goal:** I-cache and D-cache working against a slow AXI memory.

- [ ] AXI4 interface definitions (`rtl/bus/axi_if.sv`), read/write bursts (INCR, 8 beats × 32 bits).
- [ ] `icache.sv`: direct-mapped, refill FSM, invalidate-all.
- [ ] `dcache.sv`: write-back, write-allocate, byte strobes, dirty eviction, uncached MMIO bypass, flush-all for `fence.i`.
- [ ] `axi_arbiter.sv`: D$ priority, whole-burst locking.
- [ ] cocotb: caches against `cocotbext-axi` `AxiRam` with **random latencies and back-pressure**. Random read/write sequences checked against a Python "golden memory".
- [ ] System sim: whole SoC + caches + AXI RAM model → rerun **all** earlier tests and C programs.
- [ ] On FPGA (**before** DDR): put an AXI BRAM (e.g. 256 KB, with artificial delay) behind the arbiter as "fake DDR". Run the tests on the board.
- [ ] Performance counters: cache hits/misses (memory-mapped or CSRs).

🔗 **Borrow:** HOLY `1_fpga_edition` cache + AXI chapters (`holy_cache`, `holy_data_cache`, `holy_instr_cache`, `external_req_arbitrer`) as reading material; Armaan's cache organisation and "D$ priority" lesson.

**Done when:** a cache stress test (random addresses, all sizes, 100k+ operations) passes in sim **and** on the board, and hit/miss counters look sensible.

---

### Phase 5: DDR2 via MIG (≈ 2–3 weeks)

**Goal:** 128 MB of working memory.

- [ ] Generate the MIG (DDR2, AXI 128-bit) using Digilent's settings and pinout (§10.2).
- [ ] First: MIG **alone** with Xilinx's example traffic generator, or a simple test, to see `init_calib_complete`.
- [ ] Clock wizard: add 200 MHz for MIG and 25 MHz for VGA (for later).
- [ ] `top_nexys.sv`: our arbiter → AXI Interconnect (32→128 bits, clk_cpu→ui_clk) → MIG.
- [ ] Hold the CPU in reset until calibration completes (LED indicator).
- [ ] Move program RAM to DDR (`link.ld` at `0x8000_0000`). Boot ROM code still runs from BRAM.
- [ ] `memtest`: write patterns (address-as-data, walking ones, random) across all 128 MB and verify. Print MB/s.

🔗 **Borrow:** HOLY's use of the Xilinx MIG + AXI (Arty S7 block design `holy_vivado_setup.tcl`, `mig_HC.prj`) as a reference for the Vivado steps; Armaan's warning about CDC dropping write-backs (hence the Xilinx interconnect).

**Done when:** `memtest` passes over the full 128 MB, repeatedly, on the board.

---

### Phase 6: UART bootloader + `load.py` (≈ 1–2 weeks)

**Goal:** send any program (and the WAD) into DDR and run it.

- [ ] Bootloader protocol (§14): WRITE / BAUD / JUMP, CRC32 per packet, ACK/NAK + retry.
- [ ] Boot ROM build flow: `sw/bootloader` → `boot_rom.hex` → `$readmemh`.
- [ ] `tools/load.py`: parse the ELF (e.g. `pyelftools`), send segments, send `doom1.wad` to `0x8600_0000` with a small header (magic + length), then JUMP.
- [ ] Baud switch to 2 Mbaud (then try 4 Mbaud).
- [ ] `fence.i` before the jump (§9.6), tested with a program that is written and then executed.

🔗 **Borrow:** HOLY `fpga/ROM/` hex-generation flow. The loader itself is our design (replaces HOLY's JTAG + GDB flow).

**Done when:** `python tools/load.py hello.elf` runs hello from DDR, and a 4 MB file round-trips with the correct CRC.

---

### Phase 7: VGA display (≈ 2 weeks)

**Goal:** the CPU draws pictures on a monitor.

- [ ] `vga.sv`: 640×480@60 timing, 2× scaling, framebuffer dual-port BRAM, palette RAM, vblank status.
- [ ] Simulation: check the sync pulse widths and counts. Dump one frame to PNG from sim.
- [ ] Test programs: colour bars, palette cycling, a moving square, an image.
- [ ] Pins: `VGA_R/G/B[3:0]`, `VGA_HS`, `VGA_VS` from the Digilent master XDC.

🔗 **Borrow:** Armaan's BRAM framebuffer + 12-bit VGA approach. Palette in hardware is our improvement.

**Done when:** a smooth animation shows on the monitor without flicker.

---

### Phase 8: Keyboard input (≈ 1 week)

**Goal:** key presses and releases reach software.

- [ ] UART keys: `tools/keys.py` sends key-down/key-up bytes from the laptop (e.g. bit7 = release). This is a fallback and useful in simulation.
- [ ] `ps2.sv` receiver + FIFO. Software scancode-set-2 decoder (press, `F0` release, `E0` extended).
- [ ] Test program: print key names on press/release, and show the last scancode on the 7-seg.

🔗 **Borrow:** UART keyboard idea (both projects; HOLY's keymap in `i_system.c`). PS/2 is ours.

**Done when:** pressing and releasing arrows, Ctrl, Space, Enter and Esc on a USB keyboard prints correct events.

---

### Phase 9: DOOM in simulation (≈ 2–3 weeks)

**Goal:** see DOOM's title screen and the first rendered frames **in the Verilator simulation**.

- [ ] Put the DOOM source + our platform layer into `sw/doom/` (§15.6) and build `doom.elf` with `-O1`.
- [ ] Verilator harness: load `doom.elf` and the WAD into the DDR model (**random initial contents!**), print UART to the console, dump the framebuffer to PNG every N frames.
- [ ] Watch the log: `Z_Init`, `W_Init`, `R_Init`... then the title screen PNG.
- [ ] Fix every crash with the trap handler output + the trace compare against Spike.

🔗 **Borrow:** HOLY_CORE_DOOM's platform files, Makefile and `.hex` output for HDL simulation; Armaan's "DOOM running in simulation" step and random-memory trick.

**Done when:** a PNG of DOOM's title screen (and ideally of demo gameplay) comes out of the simulator.

---

### Phase 10: DOOM on the board 🎉 (≈ 1–2 weeks)

**Goal:** play it.

- [ ] Program the FPGA, run `load.py doom.elf --wad doom1.wad`.
- [ ] UART log first, then the picture on the monitor, then the keyboard.
- [ ] Print **cycles per frame** and FPS (🔗 HOLY's `i_video.c` prints "Num cycles to render this frame").
- [ ] Use the ILA for any hardware-only problem.

**Done when:** you can start E1M1 with the USB keyboard and play on the monitor.

---

### Phase 11: Performance (ongoing)

See §20. Target: **≥ 20 FPS** (DOOM's engine caps at 35).

---

### Phase 12: Stretch goals

- [ ] **Laptop-screen viewer:** hardware streams the framebuffer over UART, and `tools/viewer.py` (pygame) shows it and sends keys back.
- [ ] **Sound:** a PWM audio output + a simple mixer for DOOM's 8-bit sound effects (the board has a mono audio jack).
- [ ] **WAD from QSPI flash or microSD**, so the board boots straight into DOOM with no laptop.
- [ ] Turn DOOM's `config.h` features back on (monsters, translucency) once it's fast enough.
- [ ] **RISC-V debug module** for GDB over the onboard JTAG (🔗 HOLY uses PULP `riscv-dbg`).
- [ ] Branch prediction, a deeper pipeline, even out-of-order execution (🔗 Armaan's next plans).
- [ ] Timer interrupts, then a tiny RTOS.

---

## 19. Lessons already learned by others

Read these **before** writing code. Each one cost someone days or weeks.

| # | Lesson | Who learned it | What we do |
|---|---|---|---|
| 1 | **DOOM assumed uninitialised memory was zero.** Real DDR powers up random, causing random crashes that never appeared in simulation | Armaan | `crt0.S` zeroes `.bss`. Our sim DDR model starts with **random** data |
| 2 | **Missing `volatile` on a hardware register pointer:** works at `-O0`, freezes at `-O2` (the compiler read the timer once and kept the value) | Armaan | Every MMIO access goes through `volatile` pointers in `soc.h`, and we test at `-O2` early |
| 3 | **Bugs from the very first single-cycle CPU showed up only when DOOM ran** (e.g. a wrong immediate) | Armaan | Exhaustive unit tests, riscv-tests, RISCOF, trace comparison **before** DOOM |
| 4 | **Clock-crossing to the MIG dropped write-back requests** | Armaan | Xilinx AXI Interconnect for that crossing |
| 5 | **Cache arbiter starvation/deadlock** | Armaan | D-cache priority, whole-burst locking, random-latency tests |
| 6 | **D-cache overwrote instruction data** | Armaan | `fence.i` = D$ flush + I$ invalidate; tests for it |
| 7 | **Fetch stage issued duplicate I-cache requests**, wasting bandwidth (fixing it took 1 → 2.5 FPS) | Armaan | Fetch holds its request steady while stalled. The cache sees each request exactly once |
| 8 | **UART dropped characters during fast printf** | Armaan | TX/RX FIFOs |
| 9 | **Everything was flawless in sim with ideal memory, then broke on hardware** | Armaan | Random-latency memory models + ILA |
| 10 | **printf implementations caused trouble** | Armaan (Liam) | Use the small, known-good `mini-printf.c` (🔗 HOLY_CORE_DOOM) |
| 11 | **Break DOOM into smaller test programs first** | Armaan | Phases 3–8 test every subsystem separately |
| 12 | "You need the exact same setup as me to run this": too many moving parts to copy blindly | HOLY (README of HOLY_CORE_DOOM) | We document **our** setup completely (this file) |
| 13 | GDB `load` doesn't write `.bss`, so it must be zeroed at startup | HOLY (`start.S` comment) | Same, in `crt0.S` |
| 14 | UART can't send key releases, so HOLY fakes them each tic | HOLY (`i_system.c`) | We send real up/down events (PS/2, or our `keys.py` protocol) |
| 15 | Palette built only once means no damage/pickup flashes | HOLY (`i_video.c` `pal_ready`) | Hardware palette, updated on every `I_SetPalette` |

---

## 20. Performance plan

### 20.1 Armaan's measured journey (our benchmark)

| Change | FPS |
|---|---|
| First working version | 0.7 |
| Clock 100 → 125 MHz | ~1 |
| Fetch stage stops duplicate I$ requests | ~2.5 |
| Hardware multiply | ~3.5 |
| Write directly to VGA BRAM + 1-cycle cache hits | ~6.7 |
| Compile with `-O2` | **15–20** |

### 20.2 Our optimisation checklist (in rough order of payoff)

1. `-O2` (after the `volatile` audit).
2. **1-cycle cache hits** (no extra wait state on a hit).
3. Correct fetch behaviour (no duplicate requests).
4. Hardware `mul` (DSP), fast `div`.
5. Render **directly into the framebuffer** (`screens[0]` → `0x2000_0000`), which removes the 64 KB copy per frame.
6. **Bigger caches** (32–64 KB) and **2-way** D-cache. Measure with the hit/miss counters.
7. **Higher clock**: find the critical path in the Vivado timing report, and pipeline or retime it.
8. **Branch prediction** (static "backwards taken", then a small BTB).
9. Longer or critical-word-first cache refills.
10. Profile DOOM with `mcycle` around its big functions (`R_RenderPlayerView`, `R_DrawColumn`, `R_DrawSpan`) to find hot spots.

---

## 21. Credits: exactly what we take from where

### From HOLY CORE (https://github.com/0BAB1/HOLY_CORE_COURSE)

| What | Where in HOLY | How we use it |
|---|---|---|
| CPU block split (ALU, regfile, signext, control, load/store decoder, reader) | `0_single_cycle_edition/src/` | Same split for our single-cycle warm-up (our own code) |
| cocotb unit-test-per-block methodology | `*/tb/<block>/` | Same test organisation |
| AXI + cache tutorials and implementations | `1_fpga_edition/`, `3_perf_edition/src/holy_*_cache.sv`, `holy_no_cache.sv`, `external_req_arbitrer.sv` | Reading material for our caches and arbiter |
| Global stall signal from caches/ALU | `3_perf_edition/src/holy_core.sv` | Same idea in our pipeline |
| CSR file, traps | `2_soc_software_edition/src/csr_file.sv` | Reference for our minimal CSR set |
| Multiply/divide unit | `3_perf_edition/src/mul_div_unit.sv` | Reference |
| RISCOF compliance setup | `2_soc_software_edition/riscof/` | Reuse the flow for our core |
| MIG + AXI Vivado setup | `3_perf_edition/fpga/arty_S7/holy_vivado_setup.tcl`, `mig_HC.prj` | Reference for Vivado IP steps (we target DDR2) |
| Boot ROM generation | `3_perf_edition/fpga/ROM/` (`rom.S`, `gen_rom.py`, `boot_rom.v`) | Same hex-ROM flow for our bootloader |
| SoC header + driver library idea | `3_perf_edition/hc_lib/` (`holy_core_soc.h`, `holycore.c`) | Our `sw/lib/soc.h` + drivers |
| RAM at `0x8000_0000` | `holy_core_soc.h` | Same convention |

### From HOLY_CORE_DOOM (https://github.com/0BAB1/HOLY_CORE_DOOM), based on smunaut's doom_riscv

| What | File | How we use it |
|---|---|---|
| DOOM engine source (bare-metal ready) | `src/*.c` | Base of `sw/doom/` |
| Startup: stack, mtvec, bss zeroing | `src/holy_core/start.S` | Basis of our `crt0.S` |
| Linker script layout | `src/holy_core/riscv.lds` | Basis of our `link.ld` (WAD moved to a fixed address) |
| Fake OS: `_sbrk`, one-file filesystem, `_read/_lseek/_write` | `src/holy_core/libc_backend.c` | Adapted (WAD pointer from header at `0x8600_0000`) |
| Timer-based `I_GetTime`, zone allocation, key mapping | `src/holy_core/i_system.c` | Adapted (µs timer, 16 MB zone, real key up/down) |
| Simplified `d_main.c`, `i_main.c`, stubs for sound/net | `src/holy_core/` | Reused |
| `mini-printf.c`, `console.c` | `src/holy_core/` | Reused, pointed at our UART |
| Compiler flags, WAD-to-object trick, hex output for simulation | `src/holy_core/Makefile` | Adapted |
| Printing cycles per frame | `src/holy_core/i_video.c` | Same idea for our FPS counter |
| Feature switches | `src/holy_core/config.h` | Reused, revisited later |

### From Armaan Gomes (https://armaangomes.com/blogs/doom/)

| What | How we use it |
|---|---|
| 5-stage pipelined RV32 core for DOOM | Our main core architecture |
| Explicit register-usage tracking for hazards | Our hazard unit design principle |
| Separate I-cache and D-cache in BRAM in front of DDR (and "lines too short" lesson) | Our caches, with longer 32 B lines |
| Arbiter with **D-cache priority** | Our arbiter |
| CDC problems between CPU and MIG | Why we use the Xilinx interconnect there |
| VGA controller, 12-bit colour, CPU writes **directly into VGA BRAM** | Our VGA design + framebuffer optimisation |
| UART keyboard from the laptop | Our fallback input |
| Microsecond hardware timer | Our timer |
| UART TX FIFO | Our UART |
| Random-initialised memory in simulation | Our sim DDR model |
| `volatile` bug at `-O2` | Our coding rule |
| Performance steps and FPS numbers | Our optimisation plan and benchmark |
| "Break DOOM into smaller programs first" | Our phase structure |

### Others

- **Digilent**: Nexys A7 reference manual, master XDC, DDR2 MIG settings.
- **id Software**: DOOM source (GPL-2.0) and the shareware `doom1.wad`.
- **smunaut**: the original bare-metal RISC-V DOOM port.
- **ozkl**: doomgeneric (alternative port base).
- **RISC-V International**: ISA specs, riscv-tests, RISCOF, Spike.
- **Harris & Harris**, *Digital Design and Computer Architecture: RISC-V Edition*, and **Patterson & Hennessy**, *Computer Organization and Design: RISC-V Edition*: textbook pipeline designs.

---

## 22. Glossary

| Term | Meaning |
|---|---|
| **ALU** | Arithmetic Logic Unit: the part of the CPU that adds, subtracts, compares, shifts |
| **AXI / AXI4** | ARM's standard on-chip bus protocol. Separate channels for read address, read data, write address, write data and write response. Supports **bursts** (many data words for one address). Xilinx IPs such as MIG use it |
| **AXI-Lite** | A simpler AXI with no bursts, for registers |
| **Bare metal** | Running software directly on hardware with no operating system |
| **Baud** | Bits per second on a UART line |
| **Bitstream** | The file Vivado produces that configures the FPGA |
| **BRAM (Block RAM)** | Fast memory blocks inside the FPGA (36 Kbit each). 1-cycle synchronous read |
| **BSS (.bss)** | Program section for global variables that start at zero. Startup code must clear it |
| **Burst** | Transferring several consecutive words for one address request |
| **Cache** | A small, fast memory keeping copies of recently used main-memory data |
| **CDC (clock-domain crossing)** | Passing signals between parts of the chip running on different clocks. Needs special circuits |
| **cocotb** | A Python framework to write testbenches for Verilog/SystemVerilog |
| **CPI** | Cycles Per Instruction: lower is faster |
| **CSR** | Control and Status Register: special RISC-V registers for traps, counters and settings |
| **DDR2 / DDR3** | Types of external dynamic RAM chips: big and cheap, but slow and complex to drive |
| **Direct-mapped / N-way set-associative** | How many cache slots a given memory address may occupy (1, or N) |
| **Dirty bit** | Marks a cache line modified since it was loaded |
| **DSP48** | Hard multiply-accumulate blocks inside Xilinx FPGAs |
| **ELF** | The standard executable file format produced by GCC |
| **Fixed-point** | Storing fractional numbers as scaled integers (DOOM uses 16.16) |
| **Forwarding / bypassing** | Feeding a result to a later instruction before it's written to the register file |
| **FPGA** | A reconfigurable chip that becomes whatever digital circuit you describe |
| **Framebuffer** | Memory holding the image to display, one entry per pixel |
| **Hazard** | A situation where the pipeline can't proceed normally (data, control, structural) |
| **HID** | Human Interface Device: the USB class for keyboards and mice |
| **ILA** | Integrated Logic Analyzer: a Vivado IP that records internal signals on the running FPGA |
| **ISA** | Instruction Set Architecture: the "language" of a CPU (e.g. RISC-V RV32IM) |
| **Linker script** | Tells the linker at which memory addresses to put code and data |
| **LUT** | Look-Up Table: the basic logic element of an FPGA |
| **Metastability** | An unstable in-between state when a flip-flop samples a changing signal (why CDC needs care) |
| **MIG** | Xilinx Memory Interface Generator: the free DDR controller IP |
| **MMCM** | Mixed-Mode Clock Manager: makes new clock frequencies from the 100 MHz input |
| **MMIO** | Memory-Mapped I/O: controlling devices by reading/writing special addresses |
| **newlib / newlib-nano** | Small C standard libraries for embedded systems |
| **Palette** | Lookup table from a colour index (0–255) to an actual RGB colour |
| **Pipeline** | Splitting instruction execution into stages so several instructions overlap |
| **PS/2** | Old keyboard protocol (clock + data wires). The Nexys A7 converts USB keyboards to it |
| **RISCOF** | RISC-V's official compliance-testing framework |
| **RTL** | Register-Transfer Level: hardware described as registers and the logic between them (Verilog/SV code) |
| **Scancode** | The byte(s) a keyboard sends per key press/release |
| **Spike** | The official RISC-V reference simulator (the "golden model") |
| **Stall** | Freezing (part of) the pipeline for one or more cycles |
| **SystemVerilog (SV)** | The hardware description language we use |
| **Tag** | The high address bits stored in a cache line to identify which memory it holds |
| **Tic** | DOOM's game-logic time step (35 per second) |
| **Trap** | An exception (e.g. illegal instruction) that makes the CPU jump to a handler |
| **UART** | Simple serial port (TX/RX wires). Here it goes over USB to the laptop |
| **Verilator** | A very fast open-source Verilog/SV simulator (compiles the design to C++) |
| **VGA** | Analog video standard. 640×480 @ 60 Hz is the classic mode |
| **Volatile** | C keyword forcing every access to really happen. Mandatory for hardware registers |
| **WAD** | "Where's All the Data": DOOM's data file with levels, textures, sprites, sounds |
| **Write-back / write-allocate** | Cache write policies (§9.2) |
| **WSL2** | Windows Subsystem for Linux: runs Ubuntu inside Windows |

---

### Status

| Phase | Status |
|---|---|
| 0: Setup | ⬜ not started |
| 1: Single-cycle CPU (sim) | ⬜ |
| 2: Pipeline + M + CSRs | ⬜ |
| 3: First silicon (BRAM + UART) | ⬜ |
| 4: Caches | ⬜ |
| 5: DDR2 | ⬜ |
| 6: Bootloader | ⬜ |
| 7: VGA | ⬜ |
| 8: Keyboard | ⬜ |
| 9: DOOM in sim | ⬜ |
| 10: DOOM on board | ⬜ |
| 11: Performance | ⬜ |
| 12: Stretch goals | ⬜ |
