#!/usr/bin/env python3
"""bin2hex.py - turn a raw binary (from `objcopy -O binary`) into a hex file
that Verilog's $readmemh can load: one 32-bit word per line, little-endian.

    python3 tools/bin2hex.py program.bin program.hex

🔗 Same format HOLY_CORE_DOOM's Makefile makes with
   hexdump -v -e '1/4 "%08X\\n"'
"""
import sys


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("usage: bin2hex.py <in.bin> <out.hex>")
    data = open(sys.argv[1], "rb").read()
    data += b"\x00" * (-len(data) % 4)            # pad to whole words
    with open(sys.argv[2], "w") as out:
        for i in range(0, len(data), 4):
            out.write(f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n")


if __name__ == "__main__":
    main()
