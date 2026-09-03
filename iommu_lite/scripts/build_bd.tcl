## ============================================================================
## build_bd.tcl
## Scripted skeleton for the IOMMU-Lite demo Block Design on the
## Digilent Zybo Z7-20 (xc7z020clg400-1).
##
## USAGE (from Vivado Tcl console, after creating a project targeting
## the Zybo Z7-20 board and adding all files under rtl/ as design sources):
##
##   source scripts/build_bd.tcl
##
## This script assumes:
##   1) iommu_lite_top, iommu_lite_traffic_gen, iommu_lite_led_ctrl and
##      iommu_lite_demo_top RTL sources are already added to the project
##      (Add Sources -> rtl/*.v, rtl/*.vh).
##   2) The Zybo Z7-20 board files are installed so the ZYNQ7 PS board
##      preset can be auto-applied.
##
## Manual step still required in the GUI (fastest / most reliable path):
##   Package iommu_lite_demo_top as a Vivado IP-Integrator-compatible
##   module: Tools -> Create and Package New IP -> Package your current
##   project -> point at rtl/iommu_lite_demo_top.v (Vivado will infer the
##   AXI4 / AXI4-Lite interfaces automatically from the *_awvalid/*_arready
##   naming convention used throughout this RTL -- use "Merge changes from
##   File groups" then "Infer interfaces" in the IP packager to bind:
##     tg_axi_*  -> AXI4-Lite slave  "S_AXI_TG"
##     il_axi_*  -> AXI4-Lite slave  "S_AXI_IOMMU"
##     m_axi_*   -> AXI4 master      "M_AXI"
##     irq       -> interrupt output
##   Add the packaged IP repo via Settings -> IP -> Repository, then it
##   will appear in the IP catalog as "IOMMU-Lite Demo Top".
## ============================================================================

set proj_dir   [get_property DIRECTORY [current_project]]
set bd_name    "iommu_lite_bd"

create_bd_design $bd_name

# ---- Zynq7 Processing System, with Zybo Z7-20 board preset -----------------
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" \
              Master "Disable" Slave "Disable"} $ps7

# Enable one GP master (config: traffic_gen + iommu_lite AXI-Lite), one HP slave (data: DDR)
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_FCLK0_FREQ_MHZ {100} \
] $ps7

# ---- IOMMU-Lite demo IP (packaged per instructions above) ------------------
# Replace with the actual VLNV printed by the IP packager if it differs.
set il [create_bd_cell -type ip -vlnv user.org:user:iommu_lite_demo_top:1.0 iommu_lite_demo_top_0]

# ---- AXI Interconnect: PS GP0 -> two AXI-Lite slaves on the IOMMU-Lite IP --
set axi_ic_lite [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_gp0]
set_property -dict [list CONFIG.NUM_MI {2}] $axi_ic_lite

connect_bd_intf_net [get_bd_intf_pins $ps7/M_AXI_GP0] [get_bd_intf_pins $axi_ic_lite/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $axi_ic_lite/M00_AXI] [get_bd_intf_pins $il/S_AXI_TG]
connect_bd_intf_net [get_bd_intf_pins $axi_ic_lite/M01_AXI] [get_bd_intf_pins $il/S_AXI_IOMMU]

# ---- AXI Interconnect / SmartConnect: IOMMU-Lite M_AXI -> PS HP0 (DDR) -----
set axi_ic_hp [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_hp0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $axi_ic_hp
connect_bd_intf_net [get_bd_intf_pins $il/M_AXI] [get_bd_intf_pins $axi_ic_hp/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $axi_ic_hp/M00_AXI] [get_bd_intf_pins $ps7/S_AXI_HP0]

# ---- Clocks / resets --------------------------------------------------------
apply_bd_automation -rule xilinx.com:bd_rule:clkrst \
    -config { Clk "/processing_system7_0/FCLK_CLK0 (100 MHz)" } [get_bd_pins $il/aclk]
apply_bd_automation -rule xilinx.com:bd_rule:clkrst \
    -config { Clk "/processing_system7_0/FCLK_CLK0 (100 MHz)" } [get_bd_pins $axi_ic_lite/ACLK]
apply_bd_automation -rule xilinx.com:bd_rule:clkrst \
    -config { Clk "/processing_system7_0/FCLK_CLK0 (100 MHz)" } [get_bd_pins $axi_ic_hp/ACLK]

# ---- Interrupt: IOMMU-Lite fault IRQ -> PS7 IRQ_F2P[0] ----------------------
connect_bd_net [get_bd_pins $il/irq] [get_bd_pins $ps7/IRQ_F2P]

# ---- LEDs / RGB LED5 / switches / buttons -> top-level ports --------------
make_bd_pins_external  [get_bd_pins $il/led]
make_bd_pins_external  [get_bd_pins $il/led5_r]
make_bd_pins_external  [get_bd_pins $il/led5_g]
make_bd_pins_external  [get_bd_pins $il/led5_b]

# ---- Address map (must match sw/iommu_lite_test.c) --------------------------
# S_AXI_TG     (traffic-gen config)  : 0x4000_0000 .. 0x4000_00FF
# S_AXI_IOMMU  (region-table config) : 0x4001_0000 .. 0x4001_0FFF
assign_bd_address
set_property offset 0x40000000 [get_bd_addr_segs {processing_system7_0/Data/SEG_iommu_lite_demo_top_0_S_AXI_TG_reg}]
set_property range  4K         [get_bd_addr_segs {processing_system7_0/Data/SEG_iommu_lite_demo_top_0_S_AXI_TG_reg}]
set_property offset 0x40010000 [get_bd_addr_segs {processing_system7_0/Data/SEG_iommu_lite_demo_top_0_S_AXI_IOMMU_reg}]
set_property range  4K         [get_bd_addr_segs {processing_system7_0/Data/SEG_iommu_lite_demo_top_0_S_AXI_IOMMU_reg}]

# ---- Wrap up ----------------------------------------------------------------
regenerate_bd_layout
validate_bd_design
save_bd_design

make_wrapper -files [get_files $proj_dir/$bd_name.srcs/sources_1/bd/$bd_name/$bd_name.bd] -top
add_files -norecurse $proj_dir/$bd_name.srcs/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.v
set_property top ${bd_name}_wrapper [current_fileset]

puts "Block design '$bd_name' created. Add constraints/zybo_z7_20.xdc, then run:"
puts "  launch_runs impl_1 -to_step write_bitstream -jobs 4"
