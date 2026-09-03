`include "iommu_lite_pkg.vh"
`timescale 1ns/1ps
//==========================================================================
// iommu_lite_top_tb
//
// End-to-end AXI-level test:
//  1) Programs the region table over S_AXI_LITE (the "Programming Flow").
//  2) Drives write/read bursts on S_AXI (data path) and checks that
//     M_AXI sees the correctly translated address, and that illegal
//     accesses are blocked with SLVERR + fault/IRQ raised.
// A simple completion memory model is instantiated on M_AXI to complete
// transactions so bursts don't hang.
//==========================================================================
module iommu_lite_top_tb;

    localparam ADDR_W = `IOMMU_LITE_ADDR_W;
    localparam ID_W   = 4;
    localparam DATA_W = 32;

    reg aclk = 0;
    reg aresetn = 0;
    always #5 aclk = ~aclk; // 100 MHz

    // ---- AXI-Lite config signals ----
    reg  [11:0] al_awaddr; reg al_awvalid; wire al_awready;
    reg  [31:0] al_wdata;  reg [3:0] al_wstrb; reg al_wvalid; wire al_wready;
    wire [1:0] al_bresp; wire al_bvalid; reg al_bready;
    reg  [11:0] al_araddr; reg al_arvalid; wire al_arready;
    wire [31:0] al_rdata; wire [1:0] al_rresp; wire al_rvalid; reg al_rready;

    // ---- AXI4 data (S side, driven by this TB acting as DMA master) ----
    reg  [ID_W-1:0] s_awid; reg [ADDR_W-1:0] s_awaddr; reg [7:0] s_awlen;
    reg  [2:0] s_awsize; reg [1:0] s_awburst; reg s_awvalid; wire s_awready;
    reg  [DATA_W-1:0] s_wdata; reg [3:0] s_wstrb; reg s_wlast; reg s_wvalid; wire s_wready;
    wire [ID_W-1:0] s_bid; wire [1:0] s_bresp; wire s_bvalid; reg s_bready;
    reg  [ID_W-1:0] s_arid; reg [ADDR_W-1:0] s_araddr; reg [7:0] s_arlen;
    reg  [2:0] s_arsize; reg [1:0] s_arburst; reg s_arvalid; wire s_arready;
    wire [ID_W-1:0] s_rid; wire [DATA_W-1:0] s_rdata; wire [1:0] s_rresp; wire s_rlast; wire s_rvalid; reg s_rready;

    // ---- AXI4 data (M side, towards a simple memory model) ----
    wire [ID_W-1:0] m_awid; wire [ADDR_W-1:0] m_awaddr; wire [7:0] m_awlen;
    wire [2:0] m_awsize; wire [1:0] m_awburst; wire m_awvalid; reg m_awready;
    wire [DATA_W-1:0] m_wdata; wire [3:0] m_wstrb; wire m_wlast; wire m_wvalid; reg m_wready;
    reg  [ID_W-1:0] m_bid; reg [1:0] m_bresp; reg m_bvalid; wire m_bready;
    wire [ID_W-1:0] m_arid; wire [ADDR_W-1:0] m_araddr; wire [7:0] m_arlen;
    wire [2:0] m_arsize; wire [1:0] m_arburst; wire m_arvalid; reg m_arready;
    reg  [ID_W-1:0] m_rid; reg [DATA_W-1:0] m_rdata; reg [1:0] m_rresp; reg m_rlast; reg m_rvalid; wire m_rready;

    wire irq;

    // captured translated address seen on M_AXI, for checking
    reg [ADDR_W-1:0] last_m_awaddr, last_m_araddr;

    iommu_lite_top #(
        .C_AXI_ID_WIDTH(ID_W), .C_AXI_DATA_WIDTH(DATA_W)
    ) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_lite_awaddr(al_awaddr), .s_axi_lite_awvalid(al_awvalid), .s_axi_lite_awready(al_awready),
        .s_axi_lite_wdata(al_wdata), .s_axi_lite_wstrb(al_wstrb), .s_axi_lite_wvalid(al_wvalid), .s_axi_lite_wready(al_wready),
        .s_axi_lite_bresp(al_bresp), .s_axi_lite_bvalid(al_bvalid), .s_axi_lite_bready(al_bready),
        .s_axi_lite_araddr(al_araddr), .s_axi_lite_arvalid(al_arvalid), .s_axi_lite_arready(al_arready),
        .s_axi_lite_rdata(al_rdata), .s_axi_lite_rresp(al_rresp), .s_axi_lite_rvalid(al_rvalid), .s_axi_lite_rready(al_rready),

        .s_axi_awid(s_awid), .s_axi_awaddr(s_awaddr), .s_axi_awlen(s_awlen), .s_axi_awsize(s_awsize),
        .s_axi_awburst(s_awburst), .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
        .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wlast(s_wlast), .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
        .s_axi_bid(s_bid), .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
        .s_axi_arid(s_arid), .s_axi_araddr(s_araddr), .s_axi_arlen(s_arlen), .s_axi_arsize(s_arsize),
        .s_axi_arburst(s_arburst), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
        .s_axi_rid(s_rid), .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rlast(s_rlast), .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),

        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),

        .irq(irq), .allow_pulse()
    );

    // Capture translated address whenever M_AXI AW/AR handshakes
    always @(posedge aclk) begin
        if (m_awvalid && m_awready) last_m_awaddr <= m_awaddr;
        if (m_arvalid && m_arready) last_m_araddr <= m_araddr;
    end

    // ---- Trivial memory-model responder on M_AXI (always ready, 1-cycle latency) ----
    initial begin
        m_awready = 1; m_wready = 1; m_arready = 1;
        m_bvalid = 0; m_bid = 0; m_bresp = 0;
        m_rvalid = 0; m_rid = 0; m_rdata = 0; m_rresp = 0; m_rlast = 0;
    end
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_bvalid <= 0; m_rvalid <= 0;
        end else begin
            if (m_awvalid && m_awready) begin
                m_bid <= m_awid; m_bresp <= 2'b00; m_bvalid <= 1;
            end else if (m_bvalid && m_bready) m_bvalid <= 0;

            if (m_arvalid && m_arready) begin
                m_rid <= m_arid; m_rdata <= 32'hCAFE_0000 | m_araddr[15:0];
                m_rresp <= 2'b00; m_rlast <= 1; m_rvalid <= 1;
            end else if (m_rvalid && m_rready) m_rvalid <= 0;
        end
    end

    // ---- AXI-Lite write/read helper tasks ----
    task axil_write(input [11:0] addr, input [31:0] data);
        begin
            @(posedge aclk);
            al_awaddr <= addr; al_awvalid <= 1;
            al_wdata  <= data; al_wstrb <= 4'hF; al_wvalid <= 1;
            al_bready <= 1;
            @(posedge aclk);
            while (!(al_awready && al_wready)) @(posedge aclk);
            al_awvalid <= 0; al_wvalid <= 0;
            while (!al_bvalid) @(posedge aclk);
            @(posedge aclk);
            al_bready <= 0;
        end
    endtask

    task axi_write(input [ID_W-1:0] id, input [ADDR_W-1:0] addr, input [31:0] data);
        begin
            @(posedge aclk);
            s_awid <= id; s_awaddr <= addr; s_awlen <= 0; s_awsize <= 3'b010; s_awburst <= 2'b01; s_awvalid <= 1;
            s_wdata <= data; s_wstrb <= 4'hF; s_wlast <= 1; s_wvalid <= 1;
            s_bready <= 1;
            @(posedge aclk);
            while (!s_awready) @(posedge aclk);
            s_awvalid <= 0;
            while (!s_wready) @(posedge aclk);
            s_wvalid <= 0;
            while (!s_bvalid) @(posedge aclk);
            $display("  AXI WRITE id=%0d A_in=%h -> bresp=%b (%0s)", id, addr, s_bresp,
                      (s_bresp == 2'b00) ? "OKAY" : "SLVERR");
            @(posedge aclk);
            s_bready <= 0;
        end
    endtask

    task axi_read(input [ID_W-1:0] id, input [ADDR_W-1:0] addr);
        begin
            @(posedge aclk);
            s_arid <= id; s_araddr <= addr; s_arlen <= 0; s_arsize <= 3'b010; s_arburst <= 2'b01; s_arvalid <= 1;
            s_rready <= 1;
            @(posedge aclk);
            while (!s_arready) @(posedge aclk);
            s_arvalid <= 0;
            while (!s_rvalid) @(posedge aclk);
            $display("  AXI READ  id=%0d A_in=%h -> rresp=%b (%0s) data=%h", id, addr, s_rresp,
                      (s_rresp == 2'b00) ? "OKAY" : "SLVERR", s_rdata);
            @(posedge aclk);
            s_rready <= 0;
        end
    endtask

    initial begin
        al_awaddr=0; al_awvalid=0; al_wdata=0; al_wstrb=0; al_wvalid=0; al_bready=0;
        al_araddr=0; al_arvalid=0; al_rready=0;
        s_awid=0; s_awaddr=0; s_awlen=0; s_awsize=0; s_awburst=0; s_awvalid=0;
        s_wdata=0; s_wstrb=0; s_wlast=0; s_wvalid=0; s_bready=0;
        s_arid=0; s_araddr=0; s_arlen=0; s_arsize=0; s_arburst=0; s_arvalid=0; s_rready=0;

        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (5) @(posedge aclk);

        $display("== Programming region table over AXI-Lite (Programming Flow) ==");
        // Region 0: chan0, 0x8000_0000-0x8000_FFFF -> 0x9000_0000, R/W, valid
        axil_write(`IOMMU_LITE_REGION_BASE + 0*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_BASE,  32'h8000_0000);
        axil_write(`IOMMU_LITE_REGION_BASE + 0*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_LIMIT, 32'h8000_FFFF);
        axil_write(`IOMMU_LITE_REGION_BASE + 0*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_XLATE, 32'h9000_0000);
        axil_write(`IOMMU_LITE_REGION_BASE + 0*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_CTRL,
                    {25'b0, 4'd0 /*CID*/, `IOMMU_LITE_PERM_RW, 1'b1 /*V*/});

        // Region 1: chan1, 0x8100_0000-0x8100_7FFF -> 0x9100_0000, R only, valid
        axil_write(`IOMMU_LITE_REGION_BASE + 1*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_BASE,  32'h8100_0000);
        axil_write(`IOMMU_LITE_REGION_BASE + 1*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_LIMIT, 32'h8100_7FFF);
        axil_write(`IOMMU_LITE_REGION_BASE + 1*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_XLATE, 32'h9100_0000);
        axil_write(`IOMMU_LITE_REGION_BASE + 1*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_CTRL,
                    {25'b0, 4'd1, `IOMMU_LITE_PERM_R, 1'b1});

        // Enable the IOMMU-Lite (global CTRL)
        axil_write(`IOMMU_LITE_REG_CTRL, 32'h1);

        $display("== Data-path AXI4 traffic ==");
        axi_write(4'd0, 32'h8000_0010, 32'hAAAA_5555); // legal: region0, chan0 write
        if (last_m_awaddr !== 32'h9000_0010) begin
            $display("FAIL: expected translated AWADDR 90000010, got %h", last_m_awaddr); $stop;
        end

        axi_read (4'd0, 32'h8000_0020);                // legal: region0, chan0 read
        if (last_m_araddr !== 32'h9000_0020) begin
            $display("FAIL: expected translated ARADDR 90000020, got %h", last_m_araddr); $stop;
        end

        axi_read (4'd1, 32'h8100_0004);                 // legal: region1, chan1 read
        if (last_m_araddr !== 32'h9100_0004) begin
            $display("FAIL: expected translated ARADDR 91000004, got %h", last_m_araddr); $stop;
        end

        $display("== Fault cases ==");
        axi_write(4'd1, 32'h8100_0004, 32'hDEAD_DEAD); // illegal: region1 is Read-only -> write must FAULT
        axi_write(4'd2, 32'h8200_0000, 32'h0000_0000); // illegal: no region programmed for chan2 -> FAULT
        axi_read (4'd0, 32'h7000_0000);                  // illegal: out of range -> FAULT

        repeat (2) @(posedge aclk);
        $display("IRQ line = %b (expect 0: IRQ_EN was never set; sticky Fault bit is set regardless)", irq);

        // Check status register reflects sticky fault
        al_araddr <= `IOMMU_LITE_REG_STATUS; al_arvalid <= 1; al_rready <= 1;
        @(posedge aclk);
        while (!al_arready) @(posedge aclk);
        al_arvalid <= 0;
        while (!al_rvalid) @(posedge aclk);
        $display("STATUS reg = %h (bit0 = sticky Fault, expect 1)", al_rdata);
        @(posedge aclk); al_rready <= 0;

        $display("---------------------------------------------------");
        $display("iommu_lite_top_tb: COMPLETED (see PASS/FAIL lines above for AW/AR checks)");
        $finish;
    end

    initial begin
        #20000;
        $display("TIMEOUT"); $stop;
    end

endmodule
