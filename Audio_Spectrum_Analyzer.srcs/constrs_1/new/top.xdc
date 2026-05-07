## Zybo Z7-10 - Audio Spectrum Analyzer
## Pin assignments from Digilent Zybo-Z7-Master.xdc Rev B

## System clock (125 MHz)
set_property -dict { PACKAGE_PIN K17  IOSTANDARD LVCMOS33 } [get_ports { clk_125 }]
create_clock -add -name sys_clk_pin -period 8.000 -waveform {0 4} [get_ports { clk_125 }]

## LEDs
set_property -dict { PACKAGE_PIN M14  IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15  IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14  IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18  IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## SSM2603 audio codec
set_property -dict { PACKAGE_PIN R19  IOSTANDARD LVCMOS33 } [get_ports { ac_bclk }]
set_property -dict { PACKAGE_PIN R17  IOSTANDARD LVCMOS33 } [get_ports { ac_mclk }]
set_property -dict { PACKAGE_PIN R16  IOSTANDARD LVCMOS33 } [get_ports { ac_recdat }]
set_property -dict { PACKAGE_PIN Y18  IOSTANDARD LVCMOS33 } [get_ports { ac_lrclk }]
set_property -dict { PACKAGE_PIN N18  IOSTANDARD LVCMOS33 } [get_ports { ac_scl }]
set_property -dict { PACKAGE_PIN N17  IOSTANDARD LVCMOS33 } [get_ports { ac_sda }]

## UART - Pmod USBUART on JC top row
## Pin 1 (V15): FT232R RTS output  -> FPGA input  (uart_rts)
## Pin 2 (W15): FT232R RXD input   <- FPGA TX     (uart_tx)
## Pin 3 (T11): FT232R TXD output  -> FPGA RX     (uart_rx)
## Pin 4 (T10): FT232R CTS input   <- FPGA output (uart_cts, driven '0')
set_property -dict { PACKAGE_PIN V15  IOSTANDARD LVCMOS33 } [get_ports { uart_rts }]
set_property -dict { PACKAGE_PIN W15  IOSTANDARD LVCMOS33 } [get_ports { uart_tx }]
set_property -dict { PACKAGE_PIN T11  IOSTANDARD LVCMOS33 } [get_ports { uart_rx }]
set_property -dict { PACKAGE_PIN T10  IOSTANDARD LVCMOS33 } [get_ports { uart_cts }]
