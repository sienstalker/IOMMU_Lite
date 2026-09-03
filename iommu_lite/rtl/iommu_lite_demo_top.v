`timescale 1ns/1ps
//==========================================================================
// iommu_lite_demo_top
//
// PL-side demo top. Instantiate this alongside the "ZYNQ7 Processing
// System" IP in the Vivado Block Design (or wrap it as one more BD cell).
// It packages the whole self-contained demo path:
//
//   PS7 M_AXI_GP0 --(AXI-Lite)--> iommu_lite_traffic_gen (config: A_in, C, data)
//                                        |
//                                   (AXI4 master, stimulus)
//                                        v
//   PS7 M_AXI_GP0 --(AXI-Lite)--> iommu_lite_top S_AXI_LITE (region table config)
//                                        |
//                             iommu_lite_top S_AXI (data, from traffic_gen)
//                                        |
//                              [translation / permission / fault]
//                                        v
//                             iommu_lite_top M_AXI  --> AXI Interconnect --> PS7 S_AXI_HP0 (DDR)
//
//   iommu_lite_top.irq --> PS7 IRQ_F2P[0]
//   LEDs <- iommu_lite_led_ctrl <- iommu_lite_top status
//
// Two AXI-Lite slaves (traffic_gen config, iommu_lite_top config) should be
// mapped to distinct address ranges via the AXI Interconnect / SmartConnect
// in the block design (see README.md for the exact address map used by the
// baremetal test application).
//==========================================================================
module iommu_lite_demo_top #(
    parameter C_AXI_ID_WIDTH   = 4,
    parameter C_AXI_DATA_WIDTH = 32,
    parameter ADDR_W           = 32
)(
    input  wire aclk,
    input  wire aresetn,

    // ---- AXI-Lite #1: traffic generator control (from PS GP master) -------
    input  wire [7:0]   tg_axi_awaddr,
    input  wire          tg_axi_awvalid,
    output wire          tg_axi_awready,
    input  wire [31:0]   tg_axi_wdata,
    input  wire [3:0]    tg_axi_wstrb,
    input  wire          tg_axi_wvalid,
    output wire          tg_axi_wready,
    output wire [1:0]    tg_axi_bresp,
    output wire          tg_axi_bvalid,
    input  wire          tg_axi_bready,
    input  wire [7:0]    tg_axi_araddr,
    input  wire          tg_axi_arvalid,
    output wire          tg_axi_arready,
    output wire [31:0]   tg_axi_rdata,
    output wire [1:0]    tg_axi_rresp,
    output wire          tg_axi_rvalid,
    input  wire          tg_axi_rready,

    // ---- AXI-Lite #2: IOMMU-Lite region-table config (from PS GP master) --
    input  wire [11:0]   il_axi_awaddr,
    input  wire          il_axi_awvalid,
    output wire          il_axi_awready,
    input  wire [31:0]   il_axi_wdata,
    input  wire [3:0]    il_axi_wstrb,
    input  wire          il_axi_wvalid,
    output wire          il_axi_wready,
    output wire [1:0]    il_axi_bresp,
    output wire          il_axi_bvalid,
    input  wire          il_axi_bready,
    input  wire [11:0]   il_axi_araddr,
    input  wire          il_axi_arvalid,
    output wire          il_axi_arready,
    output wire [31:0]   il_axi_rdata,
    output wire [1:0]    il_axi_rresp,
    output wire          il_axi_rvalid,
    input  wire          il_axi_rready,

    // ---- AXI4 master out (towards AXI Interconnect -> PS7 HP0 -> DDR) -----
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

    output wire          irq,   // -> PS7 IRQ_F2P[0]

    output wire [3:0]    led,
    output wire           led5_r,
    output wire           led5_g,
    output wire           led5_b
);

    // ---- traffic_gen (AXI-Lite control) <-> iommu_lite_top S_AXI (data) ---
    wire [C_AXI_ID_WIDTH-1:0]   tg_m_awid;
    wire [ADDR_W-1:0]           tg_m_awaddr;
    wire [7:0]                  tg_m_awlen;
    wire [2:0]                  tg_m_awsize;
    wire [1:0]                  tg_m_awburst;
    wire                        tg_m_awvalid, tg_m_awready;
    wire [C_AXI_DATA_WIDTH-1:0] tg_m_wdata;
    wire [(C_AXI_DATA_WIDTH/8)-1:0] tg_m_wstrb;
    wire                        tg_m_wlast, tg_m_wvalid, tg_m_wready;
    wire [C_AXI_ID_WIDTH-1:0]   tg_m_bid;
    wire [1:0]                  tg_m_bresp;
    wire                        tg_m_bvalid, tg_m_bready;
    wire [C_AXI_ID_WIDTH-1:0]   tg_m_arid;
    wire [ADDR_W-1:0]           tg_m_araddr;
    wire [7:0]                  tg_m_arlen;
    wire [2:0]                  tg_m_arsize;
    wire [1:0]                  tg_m_arburst;
    wire                        tg_m_arvalid, tg_m_arready;
    wire [C_AXI_ID_WIDTH-1:0]   tg_m_rid;
    wire [C_AXI_DATA_WIDTH-1:0] tg_m_rdata;
    wire [1:0]                  tg_m_rresp;
    wire                        tg_m_rlast, tg_m_rvalid, tg_m_rready;

    iommu_lite_traffic_gen #(
        .C_M_AXI_ID_WIDTH(C_AXI_ID_WIDTH), .C_M_AXI_ADDR_WIDTH(ADDR_W), .C_M_AXI_DATA_WIDTH(C_AXI_DATA_WIDTH)
    ) u_traffic_gen (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(tg_axi_awaddr), .s_axi_awvalid(tg_axi_awvalid), .s_axi_awready(tg_axi_awready),
        .s_axi_wdata(tg_axi_wdata), .s_axi_wstrb(tg_axi_wstrb), .s_axi_wvalid(tg_axi_wvalid), .s_axi_wready(tg_axi_wready),
        .s_axi_bresp(tg_axi_bresp), .s_axi_bvalid(tg_axi_bvalid), .s_axi_bready(tg_axi_bready),
        .s_axi_araddr(tg_axi_araddr), .s_axi_arvalid(tg_axi_arvalid), .s_axi_arready(tg_axi_arready),
        .s_axi_rdata(tg_axi_rdata), .s_axi_rresp(tg_axi_rresp), .s_axi_rvalid(tg_axi_rvalid), .s_axi_rready(tg_axi_rready),

        .m_axi_awid(tg_m_awid), .m_axi_awaddr(tg_m_awaddr), .m_axi_awlen(tg_m_awlen), .m_axi_awsize(tg_m_awsize),
        .m_axi_awburst(tg_m_awburst), .m_axi_awvalid(tg_m_awvalid), .m_axi_awready(tg_m_awready),
        .m_axi_wdata(tg_m_wdata), .m_axi_wstrb(tg_m_wstrb), .m_axi_wlast(tg_m_wlast), .m_axi_wvalid(tg_m_wvalid), .m_axi_wready(tg_m_wready),
        .m_axi_bid(tg_m_bid), .m_axi_bresp(tg_m_bresp), .m_axi_bvalid(tg_m_bvalid), .m_axi_bready(tg_m_bready),
        .m_axi_arid(tg_m_arid), .m_axi_araddr(tg_m_araddr), .m_axi_arlen(tg_m_arlen), .m_axi_arsize(tg_m_arsize),
        .m_axi_arburst(tg_m_arburst), .m_axi_arvalid(tg_m_arvalid), .m_axi_arready(tg_m_arready),
        .m_axi_rid(tg_m_rid), .m_axi_rdata(tg_m_rdata), .m_axi_rresp(tg_m_rresp), .m_axi_rlast(tg_m_rlast), .m_axi_rvalid(tg_m_rvalid), .m_axi_rready(tg_m_rready)
    );

    wire iommu_enable_probe, fault_sticky_probe;
    wire fp, ap;
    wire [ADDR_W-1:0] fa_dummy;
    wire [3:0]        fc_dummy;

    iommu_lite_top #(
        .C_AXI_ID_WIDTH(C_AXI_ID_WIDTH), .C_AXI_DATA_WIDTH(C_AXI_DATA_WIDTH)
    ) u_iommu_lite (
        .aclk(aclk), .aresetn(aresetn),

        .s_axi_lite_awaddr(il_axi_awaddr), .s_axi_lite_awvalid(il_axi_awvalid), .s_axi_lite_awready(il_axi_awready),
        .s_axi_lite_wdata(il_axi_wdata), .s_axi_lite_wstrb(il_axi_wstrb), .s_axi_lite_wvalid(il_axi_wvalid), .s_axi_lite_wready(il_axi_wready),
        .s_axi_lite_bresp(il_axi_bresp), .s_axi_lite_bvalid(il_axi_bvalid), .s_axi_lite_bready(il_axi_bready),
        .s_axi_lite_araddr(il_axi_araddr), .s_axi_lite_arvalid(il_axi_arvalid), .s_axi_lite_arready(il_axi_arready),
        .s_axi_lite_rdata(il_axi_rdata), .s_axi_lite_rresp(il_axi_rresp), .s_axi_lite_rvalid(il_axi_rvalid), .s_axi_lite_rready(il_axi_rready),

        .s_axi_awid(tg_m_awid), .s_axi_awaddr(tg_m_awaddr), .s_axi_awlen(tg_m_awlen), .s_axi_awsize(tg_m_awsize),
        .s_axi_awburst(tg_m_awburst), .s_axi_awvalid(tg_m_awvalid), .s_axi_awready(tg_m_awready),
        .s_axi_wdata(tg_m_wdata), .s_axi_wstrb(tg_m_wstrb), .s_axi_wlast(tg_m_wlast), .s_axi_wvalid(tg_m_wvalid), .s_axi_wready(tg_m_wready),
        .s_axi_bid(tg_m_bid), .s_axi_bresp(tg_m_bresp), .s_axi_bvalid(tg_m_bvalid), .s_axi_bready(tg_m_bready),
        .s_axi_arid(tg_m_arid), .s_axi_araddr(tg_m_araddr), .s_axi_arlen(tg_m_arlen), .s_axi_arsize(tg_m_arsize),
        .s_axi_arburst(tg_m_arburst), .s_axi_arvalid(tg_m_arvalid), .s_axi_arready(tg_m_arready),
        .s_axi_rid(tg_m_rid), .s_axi_rdata(tg_m_rdata), .s_axi_rresp(tg_m_rresp), .s_axi_rlast(tg_m_rlast), .s_axi_rvalid(tg_m_rvalid), .s_axi_rready(tg_m_rready),

        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid), .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),

        .irq(irq),
        .allow_pulse(ap)
    );

    // Tap sticky-fault / enable directly isn't exposed as a port on
    // iommu_lite_top (it lives inside iommu_lite_regs); drive the LED
    // fault indicator from irq OR from re-reading STATUS in software.
    // For a simple, robust hardware indicator we instead latch on the
    // internal fault_pulse via a small local register fed from irq.
    reg fault_sticky_led;
    always @(posedge aclk) begin
        if (!aresetn) fault_sticky_led <= 1'b0;
        else if (irq) fault_sticky_led <= 1'b1;
    end

    iommu_lite_led_ctrl u_led (
        .aclk(aclk), .aresetn(aresetn),
        .iommu_enable(1'b1),          // tie high once software enables CTRL; LED[1] mirrors overall PL-alive state
        .fault_sticky(fault_sticky_led),
        .irq(irq),
        .allow_pulse(ap),
        .fault_pulse(irq),
        .led(led), .led5_r(led5_r), .led5_g(led5_g), .led5_b(led5_b)
    );

endmodule
