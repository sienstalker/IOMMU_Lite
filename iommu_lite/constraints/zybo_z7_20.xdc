## ============================================================================
## zybo_z7_20.xdc
## Constraints for the IOMMU-Lite demo top wrapper (iommu_lite_demo_top)
## on the Digilent Zybo Z7-20 (Zynq-7000, XC7Z020-1CLG400C).
##
## All pin numbers below are taken verbatim from Digilent's official
## Zybo-Z7-Master.xdc (Digilent/digilent-xdc repo) and cross-checked
## against the board schematic (Buttons/Switches/LEDs section). Only the
## LEDs/switches/buttons used by the demo are constrained; the PS7 side
## (DDR/fixed IO) is configured entirely inside the Vivado Block Design
## and needs no XDC entries.
## ============================================================================

## Clock: not required here. aclk for this design comes from the PS7's
## FCLK_CLK0 inside the block design, not from an external PL pin, so no
## sysclk constraint is needed. Left here for reference only, in case you
## later add a PL design that free-runs off the onboard 125 MHz oscillator:
# set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports { sysclk }]; #IO_L12P_T1_MRCC_35 Sch=sysclk
# create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }];

## ---- LEDs: LD0..LD3 -------------------------------------------------------
## led[0] = heartbeat (aclk toggling, divided)
## led[1] = iommu_enable (region table active)
## led[2] = fault indicator (sticky, mirrors STATUS[0])
## led[3] = irq (pulses / stays high while IRQ asserted and unmasked)
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]; #IO_L23P_T3_35 Sch=led[0]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]; #IO_L23N_T3_35 Sch=led[1]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]; #IO_0_35 Sch=led[2]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]; #IO_L3N_T0_DQS_AD1N_35 Sch=led[3]

## ---- RGB LED5 (LD5, Zybo Z7-20 only): shows last-access verdict -----------
## Green = last access Allowed, Red = last access Faulted
set_property -dict { PACKAGE_PIN Y11 IOSTANDARD LVCMOS33 } [get_ports { led5_r }]; #IO_L18N_T2_13 Sch=led5_r
set_property -dict { PACKAGE_PIN T5  IOSTANDARD LVCMOS33 } [get_ports { led5_g }]; #IO_L19P_T3_13 Sch=led5_g
set_property -dict { PACKAGE_PIN Y12 IOSTANDARD LVCMOS33 } [get_ports { led5_b }]; #IO_L20P_T3_13 Sch=led5_b

## ---- Slide switches SW0..SW3: manual demo mode (optional, PL-driven test) --
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]; #IO_L19N_T3_VREF_35 Sch=sw[0]
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]; #IO_L24P_T3_34 Sch=sw[1]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]; #IO_L4N_T0_34 Sch=sw[2]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]; #IO_L9P_T1_DQS_34 Sch=sw[3]

## ---- Push buttons BTN0..BTN3 (PL-connected; BTN4/BTN5 are PS7 MIO, not PL) -
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]; #IO_L12N_T1_MRCC_35 Sch=btn[0]
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]; #IO_L24N_T3_34 Sch=btn[1]
set_property -dict { PACKAGE_PIN K19 IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]; #IO_L10P_T1_AD11P_35 Sch=btn[2]
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]; #IO_L7P_T1_34 Sch=btn[3]

## Note: The Zynq-7020 PS7 (MIO/DDR/clocks) is configured through the
## "ZYNQ7 Processing System" IP in the Block Design (Vivado auto-applies the
## Zybo Z7-20 board preset), so no PS pins are constrained here. BTN4/BTN5
## and LD4 in the board schematic are wired to PS7 MIO50/MIO51/MIO7 directly
## and are likewise handled by the PS7 IP block, not by this PL-side XDC.

