`include "iommu_lite_pkg.vh"
`timescale 1ns/1ps
//==========================================================================
// iommu_lite_axi_rev2_tb
//
// Regression test for the rev-2 wrapper. Specifically targets the two bugs
// that rev 1 had and that the original testbench could not catch:
//
//   BUG 1 (bypass address): with iommu_enable=0 a transaction must reach
//         M_AXI at its ORIGINAL address, not at A_out (which is 0 when no
//         region matches).
//
//   BUG 2 (W after AW): the master deliberately drops AWVALID and only
//         raises WVALID several cycles LATER. Rev 1 lost the write data
//         here because its pass decision collapsed as soon as AWVALID fell.
//         The memory model checks the data actually arrived.
//
// Also re-checks translation, permission faults, channel isolation and the
// sticky-fault/IRQ path end to end.
//==========================================================================
module iommu_lite_axi_rev2_tb;

    localparam ADDR_W = 32;
    localparam ID_W   = 4;
    localparam DATA_W = 32;

    reg aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // AXI-Lite config
    reg  [11:0] al_awaddr; reg al_awvalid; wire al_awready;
    reg  [31:0] al_wdata;  reg [3:0] al_wstrb; reg al_wvalid; wire al_wready;
    wire [1:0] al_bresp; wire al_bvalid; reg al_bready;
    reg  [11:0] al_araddr; reg al_arvalid; wire al_arready;
    wire [31:0] al_rdata; wire [1:0] al_rresp; wire al_rvalid; reg al_rready;

    // AXI4 data, S side
    reg  [ID_W-1:0] s_awid; reg [ADDR_W-1:0] s_awaddr; reg [7:0] s_awlen;
    reg  [2:0] s_awsize; reg [1:0] s_awburst; reg s_awvalid; wire s_awready;
    reg  [DATA_W-1:0] s_wdata; reg [3:0] s_wstrb; reg s_wlast; reg s_wvalid; wire s_wready;
    wire [ID_W-1:0] s_bid; wire [1:0] s_bresp; wire s_bvalid; reg s_bready;
    reg  [ID_W-1:0] s_arid; reg [ADDR_W-1:0] s_araddr; reg [7:0] s_arlen;
    reg  [2:0] s_arsize; reg [1:0] s_arburst; reg s_arvalid; wire s_arready;
    wire [ID_W-1:0] s_rid; wire [DATA_W-1:0] s_rdata; wire [1:0] s_rresp;
    wire s_rlast; wire s_rvalid; reg s_rready;

    // AXI4 data, M side
    wire [ID_W-1:0] m_awid; wire [ADDR_W-1:0] m_awaddr; wire [7:0] m_awlen;
    wire [2:0] m_awsize; wire [1:0] m_awburst; wire m_awvalid; reg m_awready;
    wire [DATA_W-1:0] m_wdata; wire [3:0] m_wstrb; wire m_wlast; wire m_wvalid; reg m_wready;
    reg  [ID_W-1:0] m_bid; reg [1:0] m_bresp; reg m_bvalid; wire m_bready;
    wire [ID_W-1:0] m_arid; wire [ADDR_W-1:0] m_araddr; wire [7:0] m_arlen;
    wire [2:0] m_arsize; wire [1:0] m_arburst; wire m_arvalid; reg m_arready;
    reg  [ID_W-1:0] m_rid; reg [DATA_W-1:0] m_rdata; reg [1:0] m_rresp;
    reg m_rlast; reg m_rvalid; wire m_rready;

    wire irq, allow_pulse;

    reg [ADDR_W-1:0] last_m_awaddr, last_m_araddr;
    reg [DATA_W-1:0] last_m_wdata;
    reg              saw_m_w;

    integer errors = 0, tests = 0;
    reg [1:0] last_bresp, last_rresp;   // sampled AT the handshake, not after

    iommu_lite_top #(.C_AXI_ID_WIDTH(ID_W), .C_AXI_DATA_WIDTH(DATA_W)) dut (
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
        .s_axi_rid(s_rid), .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rlast(s_rlast),
        .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
        .irq(irq), .allow_pulse(allow_pulse)
    );

    always @(posedge aclk) begin
        if (m_awvalid && m_awready) last_m_awaddr <= m_awaddr;
        if (m_arvalid && m_arready) last_m_araddr <= m_araddr;
        if (m_wvalid  && m_wready)  begin last_m_wdata <= m_wdata; saw_m_w <= 1'b1; end
    end

    // Memory model
    initial begin
        m_awready=1; m_wready=1; m_arready=1;
        m_bvalid=0; m_bid=0; m_bresp=0;
        m_rvalid=0; m_rid=0; m_rdata=0; m_rresp=0; m_rlast=0;
    end
    always @(posedge aclk) begin
        if (!aresetn) begin m_bvalid<=0; m_rvalid<=0; end
        else begin
            if (m_wvalid && m_wready && m_wlast) begin m_bid<=m_awid; m_bresp<=2'b00; m_bvalid<=1; end
            else if (m_bvalid && m_bready) m_bvalid<=0;
            if (m_arvalid && m_arready) begin
                m_rid<=m_arid; m_rdata<=32'hCAFE_0000 | m_araddr[15:0];
                m_rresp<=2'b00; m_rlast<=1; m_rvalid<=1;
            end else if (m_rvalid && m_rready) m_rvalid<=0;
        end
    end

    task axil_write(input [11:0] addr, input [31:0] data);
        begin
            @(posedge aclk);
            al_awaddr<=addr; al_awvalid<=1; al_wdata<=data; al_wstrb<=4'hF; al_wvalid<=1; al_bready<=1;
            @(posedge aclk);
            while (!(al_awready && al_wready)) @(posedge aclk);
            al_awvalid<=0; al_wvalid<=0;
            while (!al_bvalid) @(posedge aclk);
            @(posedge aclk); al_bready<=0;
        end
    endtask

    task axil_read(input [11:0] addr, output [31:0] data);
        begin
            @(posedge aclk);
            al_araddr<=addr; al_arvalid<=1; al_rready<=1;
            @(posedge aclk);
            while (!al_arready) @(posedge aclk);
            al_arvalid<=0;
            while (!al_rvalid) @(posedge aclk);
            data = al_rdata;
            @(posedge aclk); al_rready<=0;
        end
    endtask

    // Write with a deliberate gap between AW and W  -> exercises BUG 2
    task axi_write_delayed(input [ID_W-1:0] id, input [ADDR_W-1:0] addr,
                            input [31:0] data, input integer gap);
        integer g;
        begin
            saw_m_w <= 1'b0;
            @(posedge aclk);
            s_awid<=id; s_awaddr<=addr; s_awlen<=0; s_awsize<=3'b010; s_awburst<=2'b01; s_awvalid<=1;
            s_bready<=1;
            @(posedge aclk);
            while (!s_awready) @(posedge aclk);
            s_awvalid<=0;                      // AW done, AWVALID now LOW
            for (g = 0; g < gap; g = g + 1) @(posedge aclk);   // ... stall ...
            s_wdata<=data; s_wstrb<=4'hF; s_wlast<=1; s_wvalid<=1;   // W arrives late
            @(posedge aclk);
            while (!s_wready) @(posedge aclk);
            s_wvalid<=0;
            while (!s_bvalid) @(posedge aclk);
            last_bresp = s_bresp;          // sample while BVALID is still high
            @(posedge aclk); s_bready<=0;
        end
    endtask

    task axi_read(input [ID_W-1:0] id, input [ADDR_W-1:0] addr);
        begin
            @(posedge aclk);
            s_arid<=id; s_araddr<=addr; s_arlen<=0; s_arsize<=3'b010; s_arburst<=2'b01; s_arvalid<=1;
            s_rready<=1;
            @(posedge aclk);
            while (!s_arready) @(posedge aclk);
            s_arvalid<=0;
            while (!s_rvalid) @(posedge aclk);
            last_rresp = s_rresp;          // sample while RVALID is still high
            @(posedge aclk); s_rready<=0;
        end
    endtask

    task chk(input [511:0] name, input cond);
        begin
            tests = tests + 1;
            if (!cond) begin errors = errors + 1; $display("  FAIL: %0s", name); end
            else $display("  pass: %0s", name);
        end
    endtask

    integer k;
    reg [31:0] rv;

    initial begin
        al_awaddr=0; al_awvalid=0; al_wdata=0; al_wstrb=0; al_wvalid=0; al_bready=0;
        al_araddr=0; al_arvalid=0; al_rready=0;
        s_awid=0; s_awaddr=0; s_awlen=0; s_awsize=0; s_awburst=0; s_awvalid=0;
        s_wdata=0; s_wstrb=0; s_wlast=0; s_wvalid=0; s_bready=0;
        s_arid=0; s_araddr=0; s_arlen=0; s_arsize=0; s_arburst=0; s_arvalid=0; s_rready=0;
        saw_m_w=0;

        repeat (5) @(posedge aclk); aresetn=1; repeat (5) @(posedge aclk);

        //================================================================
        $display("\n== TEST GROUP 1: BYPASS MODE (iommu_enable = 0) ==");
        // Region table is still all zeros / invalid, IOMMU disabled.
        axi_write_delayed(4'd0, 32'h1234_5678, 32'hFEED_BEEF, 4);
        chk("bypass write: M_AXI sees ORIGINAL addr 0x12345678 (not 0)",
             last_m_awaddr === 32'h1234_5678);
        chk("bypass write: response is OKAY", last_bresp === 2'b00);
        chk("bypass write: W data actually reached M_AXI", saw_m_w === 1'b1);
        chk("bypass write: W data value correct", last_m_wdata === 32'hFEED_BEEF);

        axi_read(4'd0, 32'h0BAD_C0DE);
        chk("bypass read: M_AXI sees ORIGINAL addr 0x0BADC0DE",
             last_m_araddr === 32'h0BAD_C0DE);
        chk("bypass read: response is OKAY", last_rresp === 2'b00);

        //================================================================
        $display("\n== TEST GROUP 2: program region table, enable ==");
        // Region 0: C=0, 0x1000_0000-0x1000_FFFF -> 0x1800_0000, R/W, V=1
        axil_write(`IOMMU_LITE_REGION_BASE + 0*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_BASE,  32'h1000_0000);
        axil_write(`IOMMU_LITE_REGION_BASE + 0*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_LIMIT, 32'h1000_FFFF);
        axil_write(`IOMMU_LITE_REGION_BASE + 0*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_XLATE, 32'h1800_0000);
        axil_write(`IOMMU_LITE_REGION_BASE + 0*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_CTRL,
                    {25'b0, 4'd0, `IOMMU_LITE_PERM_RW, 1'b1});
        // Region 1: C=1, 0x1010_0000-0x1010_7FFF -> 0x1810_0000, R only, V=1
        axil_write(`IOMMU_LITE_REGION_BASE + 1*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_BASE,  32'h1010_0000);
        axil_write(`IOMMU_LITE_REGION_BASE + 1*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_LIMIT, 32'h1010_7FFF);
        axil_write(`IOMMU_LITE_REGION_BASE + 1*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_XLATE, 32'h1810_0000);
        axil_write(`IOMMU_LITE_REGION_BASE + 1*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_CTRL,
                    {25'b0, 4'd1, `IOMMU_LITE_PERM_R, 1'b1});

        // read back to prove programming landed
        axil_read(`IOMMU_LITE_REGION_BASE + 0*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_BASE, rv);
        chk("regtable readback B_0 == 0x10000000", rv === 32'h1000_0000);
        axil_read(`IOMMU_LITE_REGION_BASE + 1*`IOMMU_LITE_REGION_STRIDE + `IOMMU_LITE_R_CTRL, rv);
        chk("regtable readback R1 CTRL == {CID=1,P=R,V=1}", rv === 32'h0000_000B);

        axil_write(`IOMMU_LITE_REG_IRQ_EN, 32'h1);
        axil_write(`IOMMU_LITE_REG_CTRL,   32'h1);
        axil_read(`IOMMU_LITE_REG_CTRL, rv);
        chk("CTRL readback == 1 (iommu_enable took effect)", rv[0] === 1'b1);

        //================================================================
        $display("\n== TEST GROUP 3: ENABLED, legal accesses (delayed W) ==");
        axi_write_delayed(4'd0, 32'h1000_0010, 32'hA5A5_1234, 6);
        chk("R0 write: translated addr 0x18000010", last_m_awaddr === 32'h1800_0010);
        chk("R0 write: OKAY", last_bresp === 2'b00);
        chk("R0 write: W data survived the AW/W gap", saw_m_w === 1'b1);
        chk("R0 write: W data value correct", last_m_wdata === 32'hA5A5_1234);

        axi_read(4'd0, 32'h1000_0020);
        chk("R0 read: translated addr 0x18000020", last_m_araddr === 32'h1800_0020);
        chk("R0 read: OKAY", last_rresp === 2'b00);

        axi_read(4'd1, 32'h1010_0004);
        chk("R1 read: translated addr 0x18100004", last_m_araddr === 32'h1810_0004);
        chk("R1 read: OKAY", last_rresp === 2'b00);

        //================================================================
        $display("\n== TEST GROUP 4: ENABLED, illegal accesses must FAULT ==");
        axi_write_delayed(4'd1, 32'h1010_0004, 32'hDEAD_DEAD, 3);
        chk("R1 write to read-only region -> SLVERR", last_bresp === 2'b10);

        axi_write_delayed(4'd2, 32'h1000_0010, 32'h1111_1111, 2);
        chk("wrong channel (C=2 on a C=0 region) -> SLVERR", last_bresp === 2'b10);

        axi_read(4'd0, 32'h2000_0000);
        chk("out-of-range read -> SLVERR", last_rresp === 2'b10);

        axi_read(4'd7, 32'h1000_0000);
        chk("unmapped channel read -> SLVERR", last_rresp === 2'b10);

        //================================================================
        $display("\n== TEST GROUP 5: sticky fault + IRQ ==");
        axil_read(`IOMMU_LITE_REG_STATUS, rv);
        chk("STATUS bit0 (sticky Fault) is set", rv[0] === 1'b1);
        chk("IRQ asserted (fault && irq_en)", irq === 1'b1);

        axil_read(`IOMMU_LITE_REG_FAULT_ADDR, rv);
        chk("FAULT_ADDR captured last faulting A_in (0x10000000)", rv === 32'h1000_0000);
        axil_read(`IOMMU_LITE_REG_FAULT_CHAN, rv);
        chk("FAULT_CHAN captured last faulting C (7)", rv === 32'd7);

        axil_write(`IOMMU_LITE_REG_IRQ_CLR, 32'h1);
        axil_read(`IOMMU_LITE_REG_STATUS, rv);
        chk("STATUS cleared after IRQ_CLR", rv[0] === 1'b0);
        chk("IRQ deasserted after clear", irq === 1'b0);

        $display("\n==================================================");
        $display("iommu_lite_axi_rev2_tb: %0d/%0d checks passed", tests-errors, tests);
        if (errors == 0) $display("RESULT: ALL TESTS PASSED");
        else             $display("RESULT: %0d CHECKS FAILED", errors);
        $display("==================================================");
        $finish;
    end

    initial begin #200000; $display("TIMEOUT (likely an AXI channel deadlock)"); $finish; end

endmodule
