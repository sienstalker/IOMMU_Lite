`include "iommu_lite_pkg.vh"
`timescale 1ns/1ps
//==========================================================================
// iommu_lite_top
//
// Top-level integration wrapper, meant to be packaged as a Vivado IP and
// dropped into a Zynq-7000 block design on the Zybo Z7-20:
//
//   PS7 M_AXI_GP0 (or a PL traffic generator) --S_AXI(full)--> [this IP] --M_AXI(full)--> AXI SmartConnect --> PS7 S_AXI_HP0 (DDR)
//   PS7 M_AXI_GP1 (config)                    --S_AXI_LITE--> [this IP]   (region table programming, status, IRQ)
//   IRQ ----------------------------------------------------> PS7 IRQ_F2P
//==========================================================================
module iommu_lite_top #(
    parameter NUM_REGIONS = `IOMMU_LITE_NUM_REGIONS,
    parameter RIDX_W      = `IOMMU_LITE_RIDX_W,
    parameter ADDR_W      = `IOMMU_LITE_ADDR_W,
    parameter CHAN_W      = `IOMMU_LITE_CHAN_W,
    parameter C_S_AXI_LITE_ADDR_WIDTH = 12,
    parameter C_S_AXI_LITE_DATA_WIDTH = 32,
    parameter C_AXI_ID_WIDTH   = 4,
    parameter C_AXI_DATA_WIDTH = 32
)(
    input  wire  aclk,
    input  wire  aresetn,

    // -------- AXI4-Lite configuration port ---------------------------------
    input  wire [C_S_AXI_LITE_ADDR_WIDTH-1:0]  s_axi_lite_awaddr,
    input  wire                                s_axi_lite_awvalid,
    output wire                                s_axi_lite_awready,
    input  wire [C_S_AXI_LITE_DATA_WIDTH-1:0]  s_axi_lite_wdata,
    input  wire [(C_S_AXI_LITE_DATA_WIDTH/8)-1:0] s_axi_lite_wstrb,
    input  wire                                s_axi_lite_wvalid,
    output wire                                s_axi_lite_wready,
    output wire [1:0]                          s_axi_lite_bresp,
    output wire                                s_axi_lite_bvalid,
    input  wire                                s_axi_lite_bready,
    input  wire [C_S_AXI_LITE_ADDR_WIDTH-1:0]  s_axi_lite_araddr,
    input  wire                                s_axi_lite_arvalid,
    output wire                                s_axi_lite_arready,
    output wire [C_S_AXI_LITE_DATA_WIDTH-1:0]  s_axi_lite_rdata,
    output wire [1:0]                          s_axi_lite_rresp,
    output wire                                s_axi_lite_rvalid,
    input  wire                                s_axi_lite_rready,

    // -------- AXI4 slave (DMA data-in) --------------------------------------
    input  wire [C_AXI_ID_WIDTH-1:0]     s_axi_awid,
    input  wire [ADDR_W-1:0]             s_axi_awaddr,
    input  wire [7:0]                    s_axi_awlen,
    input  wire [2:0]                    s_axi_awsize,
    input  wire [1:0]                    s_axi_awburst,
    input  wire                          s_axi_awvalid,
    output wire                          s_axi_awready,
    input  wire [C_AXI_DATA_WIDTH-1:0]   s_axi_wdata,
    input  wire [(C_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                          s_axi_wlast,
    input  wire                          s_axi_wvalid,
    output wire                          s_axi_wready,
    output wire [C_AXI_ID_WIDTH-1:0]     s_axi_bid,
    output wire [1:0]                    s_axi_bresp,
    output wire                          s_axi_bvalid,
    input  wire                          s_axi_bready,
    input  wire [C_AXI_ID_WIDTH-1:0]     s_axi_arid,
    input  wire [ADDR_W-1:0]             s_axi_araddr,
    input  wire [7:0]                    s_axi_arlen,
    input  wire [2:0]                    s_axi_arsize,
    input  wire [1:0]                    s_axi_arburst,
    input  wire                          s_axi_arvalid,
    output wire                          s_axi_arready,
    output wire [C_AXI_ID_WIDTH-1:0]     s_axi_rid,
    output wire [C_AXI_DATA_WIDTH-1:0]   s_axi_rdata,
    output wire [1:0]                    s_axi_rresp,
    output wire                          s_axi_rlast,
    output wire                          s_axi_rvalid,
    input  wire                          s_axi_rready,

    // -------- AXI4 master (DMA data-out, towards DDR / HP port) ------------
    output wire [C_AXI_ID_WIDTH-1:0]     m_axi_awid,
    output wire [ADDR_W-1:0]             m_axi_awaddr,
    output wire [7:0]                    m_axi_awlen,
    output wire [2:0]                    m_axi_awsize,
    output wire [1:0]                    m_axi_awburst,
    output wire                          m_axi_awvalid,
    input  wire                          m_axi_awready,
    output wire [C_AXI_DATA_WIDTH-1:0]   m_axi_wdata,
    output wire [(C_AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output wire                          m_axi_wlast,
    output wire                          m_axi_wvalid,
    input  wire                          m_axi_wready,
    input  wire [C_AXI_ID_WIDTH-1:0]     m_axi_bid,
    input  wire [1:0]                    m_axi_bresp,
    input  wire                          m_axi_bvalid,
    output wire                          m_axi_bready,
    output wire [C_AXI_ID_WIDTH-1:0]     m_axi_arid,
    output wire [ADDR_W-1:0]             m_axi_araddr,
    output wire [7:0]                    m_axi_arlen,
    output wire [2:0]                    m_axi_arsize,
    output wire [1:0]                    m_axi_arburst,
    output wire                          m_axi_arvalid,
    input  wire                          m_axi_arready,
    input  wire [C_AXI_ID_WIDTH-1:0]     m_axi_rid,
    input  wire [C_AXI_DATA_WIDTH-1:0]   m_axi_rdata,
    input  wire [1:0]                    m_axi_rresp,
    input  wire                          m_axi_rlast,
    input  wire                          m_axi_rvalid,
    output wire                          m_axi_rready,

    output wire                          irq,
    output wire                          allow_pulse   // for demo LED use only
);

    wire [NUM_REGIONS*ADDR_W-1:0]  B_i_flat, L_i_flat, T_i_flat;
    wire [NUM_REGIONS*CHAN_W-1:0]  CID_i_flat;
    wire [NUM_REGIONS*2-1:0]       P_i_flat;
    wire [NUM_REGIONS-1:0]         V_i;
    wire                           iommu_enable;

    wire                           fault_pulse;
    wire [ADDR_W-1:0]              fault_addr;
    wire [CHAN_W-1:0]              fault_chan;

    iommu_lite_regs #(
        .NUM_REGIONS(NUM_REGIONS), .RIDX_W(RIDX_W), .ADDR_W(ADDR_W), .CHAN_W(CHAN_W),
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_LITE_ADDR_WIDTH),
        .C_S_AXI_DATA_WIDTH(C_S_AXI_LITE_DATA_WIDTH)
    ) u_regs (
        .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(s_axi_lite_awaddr), .s_axi_awvalid(s_axi_lite_awvalid), .s_axi_awready(s_axi_lite_awready),
        .s_axi_wdata(s_axi_lite_wdata), .s_axi_wstrb(s_axi_lite_wstrb), .s_axi_wvalid(s_axi_lite_wvalid), .s_axi_wready(s_axi_lite_wready),
        .s_axi_bresp(s_axi_lite_bresp), .s_axi_bvalid(s_axi_lite_bvalid), .s_axi_bready(s_axi_lite_bready),
        .s_axi_araddr(s_axi_lite_araddr), .s_axi_arvalid(s_axi_lite_arvalid), .s_axi_arready(s_axi_lite_arready),
        .s_axi_rdata(s_axi_lite_rdata), .s_axi_rresp(s_axi_lite_rresp), .s_axi_rvalid(s_axi_lite_rvalid), .s_axi_rready(s_axi_lite_rready),
        .B_i_flat(B_i_flat), .L_i_flat(L_i_flat), .T_i_flat(T_i_flat),
        .CID_i_flat(CID_i_flat), .P_i_flat(P_i_flat), .V_i(V_i),
        .iommu_enable(iommu_enable),
        .fault_pulse(fault_pulse), .fault_addr(fault_addr), .fault_chan(fault_chan),
        .irq(irq)
    );

    iommu_lite_axi_wrapper #(
        .NUM_REGIONS(NUM_REGIONS), .RIDX_W(RIDX_W), .ADDR_W(ADDR_W), .CHAN_W(CHAN_W),
        .C_AXI_ID_WIDTH(C_AXI_ID_WIDTH), .C_AXI_DATA_WIDTH(C_AXI_DATA_WIDTH)
    ) u_wrapper (
        .aclk(aclk), .aresetn(aresetn),
        .iommu_enable(iommu_enable),
        .B_i_flat(B_i_flat), .L_i_flat(L_i_flat), .T_i_flat(T_i_flat),
        .CID_i_flat(CID_i_flat), .P_i_flat(P_i_flat), .V_i(V_i),
        .fault_pulse(fault_pulse), .fault_addr(fault_addr), .fault_chan(fault_chan),
        .allow_pulse(allow_pulse),
        .s_axi_awid(s_axi_awid), .s_axi_awaddr(s_axi_awaddr), .s_axi_awlen(s_axi_awlen),
        .s_axi_awsize(s_axi_awsize), .s_axi_awburst(s_axi_awburst), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wlast(s_axi_wlast), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid), .s_axi_araddr(s_axi_araddr), .s_axi_arlen(s_axi_arlen),
        .s_axi_arsize(s_axi_arsize), .s_axi_arburst(s_axi_arburst), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rid(s_axi_rid), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rlast(s_axi_rlast), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

endmodule
