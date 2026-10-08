#!/usr/bin/env python3
"""SERV + 1 GB DDR3 on the VC707, with a hardware memory tester (ddr_test.py).

    ddr_soc.py --cpu-type serv --with-ddr --with-ddr64 --with-led-chaser --flow vivado --build --output-dir build/serv-ddr3
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.environ.get("VC707_LITEX_DIR", os.path.expanduser("~/xc7-bitstream-tools/examples/vc707-litex"))
sys.path.insert(0, TEMPLATE_DIR)
sys.path.insert(0, HERE)

import vc707_litex as base
from ddr_test import DDRTest
from litex.soc.integration.builder import Builder


class DDRSoC(base.BaseSoC):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        if kwargs.get("with_ddr"):
            self.ddr_test = DDRTest(self.sdram.crossbar.get_port(mode="write"),
                                    self.sdram.crossbar.get_port(mode="read"))


def main():
    from litex.build.parser import LiteXArgumentParser
    from litex_boards.platforms import xilinx_vc707
    parser = LiteXArgumentParser(platform=xilinx_vc707.Platform, description="SERV + DDR3 on the VC707.")
    for opt, kw in [
        ("--sys-clk-freq", dict(default=None, type=float)),
        ("--with-led-chaser", dict(action="store_true")),
        ("--with-ddr", dict(action="store_true")), ("--with-ddr64", dict(action="store_true")),
        ("--flow", dict(default="unknown")),
    ]:
        parser.add_target_argument(opt, **kw)
    args = parser.parse_args()
    sys_clk_freq = args.sys_clk_freq or (base.DDR_SYS_CLK_FREQ if args.with_ddr else base.SYS_CLK_FREQ)
    soc = DDRSoC(sys_clk_freq=sys_clk_freq, with_led_chaser=args.with_led_chaser,
                 with_ddr=args.with_ddr, with_ddr64=args.with_ddr64, flow=args.flow, **parser.soc_argdict)
    builder = Builder(soc, **parser.builder_argdict)
    if args.build:
        builder.build(**parser.toolchain_argdict)


if __name__ == "__main__":
    main()
