#-- VC707: pins as the LiteX xilinx_vc707 platform uses them

#-- System clock (200 MHz, LVDS)
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVDS } [get_ports {clk200_p}]
set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVDS } [get_ports {clk200_n}]
create_clock -period 5.000 -name clk200 [get_ports {clk200_p}]

#-- CPU_RESET push button (active high)
set_property -dict { PACKAGE_PIN AV40 IOSTANDARD LVCMOS18 } [get_ports {cpu_reset}]

#-- USB UART (CP2103, /dev/ttyUSB4): FPGA transmit
set_property -dict { PACKAGE_PIN AU36 IOSTANDARD LVCMOS18 } [get_ports {serial_tx}]

#-- User LEDs GPIO_LED_0..7
set_property -dict { PACKAGE_PIN AM39 IOSTANDARD LVCMOS18 } [get_ports {leds[0]}]
set_property -dict { PACKAGE_PIN AN39 IOSTANDARD LVCMOS18 } [get_ports {leds[1]}]
set_property -dict { PACKAGE_PIN AR37 IOSTANDARD LVCMOS18 } [get_ports {leds[2]}]
set_property -dict { PACKAGE_PIN AT37 IOSTANDARD LVCMOS18 } [get_ports {leds[3]}]
set_property -dict { PACKAGE_PIN AR35 IOSTANDARD LVCMOS18 } [get_ports {leds[4]}]
set_property -dict { PACKAGE_PIN AP41 IOSTANDARD LVCMOS18 } [get_ports {leds[5]}]
set_property -dict { PACKAGE_PIN AP42 IOSTANDARD LVCMOS18 } [get_ports {leds[6]}]
set_property -dict { PACKAGE_PIN AU39 IOSTANDARD LVCMOS18 } [get_ports {leds[7]}]
