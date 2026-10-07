# SERV + DDR3 (1 GB) on the VC707, built from the template's generator.
TEMPLATE   ?= $(HOME)/xc7-bitstream-tools/examples/vc707-litex
LITEX_PY   ?= $(HOME)/xc7-bitstream-tools/.venv/bin
VIVADO_BIN ?= /opt/Xilinx/Vivado/2020.1/bin
OUT        ?= build/serv-ddr3
BIT        := $(OUT)/gateware/xilinx_vc707.bit

.PHONY: gateware load term clean
gateware:
	PATH=$(LITEX_PY):$(VIVADO_BIN):$$PATH $(LITEX_PY)/python $(TEMPLATE)/vc707_litex.py \
	  --cpu-type serv --with-ddr --with-ddr64 --with-led-chaser --flow vivado --build --output-dir $(OUT)

load: $(BIT)
	openFPGALoader --cable digilent --freq 15000000 $(BIT)

term:
	picocom -b 115200 /dev/ttyUSB0

clean:
	rm -rf build
