#!/bin/sh
# tb_top_model.sv: sd_top against lowRISC's sdModel.v (from the sd-card-controller bench; path below)
M=${SDMODEL:-$HOME/xc7-bitstream-tools/rtl-deps/sd-card-controller/bench/verilog/sdModel.v}
cd "$(dirname "$0")" || exit 1
# iverilog does not take the model's "tri" ports without a direction
sed -e 's/^  tri cmd,/  inout cmd,/' -e 's/^  tri \[3:0\] dat/  inout [3:0] dat/' "$M" > /tmp/sdModel_iv.v
iverilog -g2012 -I.. -o /tmp/tb_top_model tb_top_model.sv ../sd_top.sv ../sd_cmd_serial_host.v ../sd_data_serial_host.sv ../sd_crc_7.v ../sd_crc_16.v /tmp/sdModel_iv.v -I"$(dirname "$M")" 2>&1 | grep -v "warning" | head -20
vvp /tmp/tb_top_model | tail -${TAIL:-30}
