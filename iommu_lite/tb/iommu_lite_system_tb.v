`include "iommu_lite_pkg.vh"
`timescale 1ns/1ps
//==========================================================================
// iommu_lite_system_tb
//
// Drives iommu_lite_demo_top exactly the way the baremetal application does:
// programs the region table over the il_axi AXI-Lite port, enables the IOMMU,
// then issues transactions by poking the traffic generator over tg_axi and
// polling its STATUS register -- i.e. the same software loop, in simulation.
//
// This is the level that catches integration bugs the block-level testbenches
// cannot, notably the traffic generator's B-channel race: IOMMU-Lite answers a
// BLOCKED write with SLVERR so quickly that a master which parks BREADY high
// swallows the response in the wrong state and hangs.
//==========================================================================
module iommu_lite_system_tb;

    reg aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // tg_axi (traffic generator control)
    reg  [7:0]  tg_awaddr; reg tg_awvalid; wire tg_awready;
    reg  [31:0] tg_wdata;  reg tg_wvalid;  wire tg_wready;
    wire [1:0]  tg_bresp;  wire tg_bvalid; reg tg_bready;
    reg  [7:0]  tg_araddr; reg tg_arvalid; wire tg_arready;
    wire [31:0] tg_rdata;  wire [1:0] tg_rresp; wire tg_rvalid; reg tg_rready;

    // il_axi (IOMMU-Lite config)
    reg  [11:0] il_awaddr; reg il_awvalid; wire il_awready;
    reg  [31:0] il_wdata;  reg il_wvalid;  wire il_wready;
    wire [1:0]  il_bresp;  wire il_bvalid; reg il_bready;
    reg  [11:0] il_araddr; reg il_arvalid; wire il_arready;
    wire [31:0] il_rdata;  wire [1:0] il_rresp; wire il_rvalid; reg il_rready;

    // M_AXI out to "DDR"
    wire [3:0]  m_awid; wire [31:0] m_awaddr; wire [7:0] m_awlen;
    wire [2:0]  m_awsize; wire [1:0] m_awburst; wire m_awvalid; reg m_awready;
    wire [31:0] m_wdata; wire [3:0] m_wstrb; wire m_wlast; wire m_wvalid; reg m_wready;
    reg  [3:0]  m_bid; reg [1:0] m_bresp; reg m_bvalid; wire m_bready;
    wire [3:0]  m_arid; wire [31:0] m_araddr; wire [7:0] m_arlen;
    wire [2:0]  m_arsize; wire [1:0] m_arburst; wire m_arvalid; reg m_arready;
    reg  [3:0]  m_rid; reg [31:0] m_rdata; reg [1:0] m_rresp; reg m_rlast; reg m_rvalid;
    wire m_rready;

    wire irq; wire [3:0] led; wire led5_r, led5_g, led5_b;

    integer pass_n = 0, fail_n = 0;

    iommu_lite_demo_top dut (
        .aclk(aclk), .aresetn(aresetn),
        .tg_axi_awaddr(tg_awaddr), .tg_axi_awvalid(tg_awvalid), .tg_axi_awready(tg_awready),
        .tg_axi_wdata(tg_wdata), .tg_axi_wstrb(4'hF), .tg_axi_wvalid(tg_wvalid), .tg_axi_wready(tg_wready),
        .tg_axi_bresp(tg_bresp), .tg_axi_bvalid(tg_bvalid), .tg_axi_bready(tg_bready),
        .tg_axi_araddr(tg_araddr), .tg_axi_arvalid(tg_arvalid), .tg_axi_arready(tg_arready),
        .tg_axi_rdata(tg_rdata), .tg_axi_rresp(tg_rresp), .tg_axi_rvalid(tg_rvalid), .tg_axi_rready(tg_rready),
        .il_axi_awaddr(il_awaddr), .il_axi_awvalid(il_awvalid), .il_axi_awready(il_awready),
        .il_axi_wdata(il_wdata), .il_axi_wstrb(4'hF), .il_axi_wvalid(il_wvalid), .il_axi_wready(il_wready),
        .il_axi_bresp(il_bresp), .il_axi_bvalid(il_bvalid), .il_axi_bready(il_bready),
        .il_axi_araddr(il_araddr), .il_axi_arvalid(il_arvalid), .il_axi_arready(il_arready),
        .il_axi_rdata(il_rdata), .il_axi_rresp(il_rresp), .il_axi_rvalid(il_rvalid), .il_axi_rready(il_rready),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
        .irq(irq), .led(led), .led5_r(led5_r), .led5_g(led5_g), .led5_b(led5_b)
    );

    // ---- tiny DDR model with realistic (non-zero) latency ----------------
    reg [31:0] ddr [0:1023];       // covers 0x18000000-ish via hashed index
    function [9:0] didx(input [31:0] a); didx = a[11:2]; endfunction
    reg [31:0] cap_awaddr;
    integer dly;

    initial begin
        m_awready=1; m_wready=1; m_arready=1;
        m_bvalid=0; m_bid=0; m_bresp=0;
        m_rvalid=0; m_rid=0; m_rdata=0; m_rresp=0; m_rlast=0;
    end

    always @(posedge aclk) begin
        if (!aresetn) begin m_bvalid<=0; m_rvalid<=0; end
        else begin
            if (m_awvalid && m_awready) cap_awaddr <= m_awaddr;
            if (m_wvalid && m_wready) begin
                // AW and W can handshake in the SAME cycle, in which case
                // cap_awaddr has not been updated yet -- use the live address.
                ddr[didx((m_awvalid && m_awready) ? m_awaddr : cap_awaddr)] <= m_wdata;
                m_bid <= m_awid; m_bresp <= 2'b00; m_bvalid <= 1;
            end else if (m_bvalid && m_bready) m_bvalid <= 0;

            if (m_arvalid && m_arready) begin
                m_rid <= m_arid; m_rdata <= ddr[didx(m_araddr)];
                m_rresp <= 2'b00; m_rlast <= 1; m_rvalid <= 1;
            end else if (m_rvalid && m_rready) m_rvalid <= 0;
        end
    end

    // ---- AXI-Lite drivers -------------------------------------------------
    task il_w(input [11:0] a, input [31:0] d);
        begin
            @(posedge aclk); il_awaddr<=a; il_awvalid<=1; il_wdata<=d; il_wvalid<=1; il_bready<=1;
            @(posedge aclk); while(!(il_awready&&il_wready)) @(posedge aclk);
            il_awvalid<=0; il_wvalid<=0;
            while(!il_bvalid) @(posedge aclk); @(posedge aclk); il_bready<=0;
        end
    endtask
    task il_r(input [11:0] a, output [31:0] d);
        begin
            @(posedge aclk); il_araddr<=a; il_arvalid<=1; il_rready<=1;
            @(posedge aclk); while(!il_arready) @(posedge aclk); il_arvalid<=0;
            while(!il_rvalid) @(posedge aclk); d=il_rdata; @(posedge aclk); il_rready<=0;
        end
    endtask
    task tg_w(input [7:0] a, input [31:0] d);
        begin
            @(posedge aclk); tg_awaddr<=a; tg_awvalid<=1; tg_wdata<=d; tg_wvalid<=1; tg_bready<=1;
            @(posedge aclk); while(!(tg_awready&&tg_wready)) @(posedge aclk);
            tg_awvalid<=0; tg_wvalid<=0;
            while(!tg_bvalid) @(posedge aclk); @(posedge aclk); tg_bready<=0;
        end
    endtask
    task tg_r(input [7:0] a, output [31:0] d);
        begin
            @(posedge aclk); tg_araddr<=a; tg_arvalid<=1; tg_rready<=1;
            @(posedge aclk); while(!tg_arready) @(posedge aclk); tg_arvalid<=0;
            while(!tg_rvalid) @(posedge aclk); d=tg_rdata; @(posedge aclk); tg_rready<=0;
        end
    endtask

    // ---- mirror of the C tg_issue(): 1=ALLOW, 0=FAULT, -1=TIMEOUT --------
    task automatic tg_issue(input [31:0] a_in, input [3:0] chan, input is_wr,
                             input [31:0] wdata, output integer result);
        reg [31:0] st; integer guard;
        begin
            tg_w(8'h04, a_in);
            tg_w(8'h08, {28'b0, chan});
            if (is_wr) tg_w(8'h0C, wdata);
            tg_w(8'h00, is_wr ? 32'h3 : 32'h1);
            guard = 0; st = 0;
            while (!(st[1]) && guard < 400) begin
                tg_r(8'h10, st);
                guard = guard + 1;
            end
            if (guard >= 400)              result = -1;
            else if (((st>>2)&2'h3) == 0)  result = 1;
            else                            result = 0;
        end
    endtask

    task expect(input [511:0] label, input [31:0] a_in, input [3:0] chan,
                input is_wr, input [31:0] wd, input integer want);
        integer r;
        begin
            tg_issue(a_in, chan, is_wr, wd, r);
            if (r == want) begin pass_n=pass_n+1; $display("  [ OK ] %0s", label); end
            else begin
                fail_n=fail_n+1;
                $display("  [FAIL] %0s  (got %0s, wanted %0s)", label,
                    (r==1)?"ALLOW":(r==0)?"FAULT":"TIMEOUT",
                    (want==1)?"ALLOW":"FAULT");
            end
        end
    endtask

    reg [31:0] v; integer r;

    initial begin
        tg_awvalid=0; tg_wvalid=0; tg_bready=0; tg_arvalid=0; tg_rready=0;
        il_awvalid=0; il_wvalid=0; il_bready=0; il_arvalid=0; il_rready=0;
        tg_awaddr=0; tg_wdata=0; tg_araddr=0; il_awaddr=0; il_wdata=0; il_araddr=0;
        repeat(5) @(posedge aclk); aresetn=1; repeat(5) @(posedge aclk);

        $display("\n[1] Program region table (same values as the C app)");
        // R0: C=0 0x10000000-0x1000FFFF -> 0x18000000 RW V=1
        il_w(`IOMMU_LITE_REGION_BASE+0*32+`IOMMU_LITE_R_BASE , 32'h1000_0000);
        il_w(`IOMMU_LITE_REGION_BASE+0*32+`IOMMU_LITE_R_LIMIT, 32'h1000_FFFF);
        il_w(`IOMMU_LITE_REGION_BASE+0*32+`IOMMU_LITE_R_XLATE, 32'h1800_0000);
        il_w(`IOMMU_LITE_REGION_BASE+0*32+`IOMMU_LITE_R_CTRL , 32'h0000_0007);
        // R1: C=1 0x10100000-0x10107FFF -> 0x18100000 R  V=1
        il_w(`IOMMU_LITE_REGION_BASE+1*32+`IOMMU_LITE_R_BASE , 32'h1010_0000);
        il_w(`IOMMU_LITE_REGION_BASE+1*32+`IOMMU_LITE_R_LIMIT, 32'h1010_7FFF);
        il_w(`IOMMU_LITE_REGION_BASE+1*32+`IOMMU_LITE_R_XLATE, 32'h1810_0000);
        il_w(`IOMMU_LITE_REGION_BASE+1*32+`IOMMU_LITE_R_CTRL , 32'h0000_000B);
        // R2: C=2 0x10200000-0x1020FFFF -> 0x18200000 W  V=1
        il_w(`IOMMU_LITE_REGION_BASE+2*32+`IOMMU_LITE_R_BASE , 32'h1020_0000);
        il_w(`IOMMU_LITE_REGION_BASE+2*32+`IOMMU_LITE_R_LIMIT, 32'h1020_FFFF);
        il_w(`IOMMU_LITE_REGION_BASE+2*32+`IOMMU_LITE_R_XLATE, 32'h1820_0000);
        il_w(`IOMMU_LITE_REGION_BASE+2*32+`IOMMU_LITE_R_CTRL , 32'h0000_0015);
        // R3: C=0, Valid=0
        il_w(`IOMMU_LITE_REGION_BASE+3*32+`IOMMU_LITE_R_BASE , 32'h1030_0000);
        il_w(`IOMMU_LITE_REGION_BASE+3*32+`IOMMU_LITE_R_LIMIT, 32'h1030_3FFF);
        il_w(`IOMMU_LITE_REGION_BASE+3*32+`IOMMU_LITE_R_XLATE, 32'h1830_0000);
        il_w(`IOMMU_LITE_REGION_BASE+3*32+`IOMMU_LITE_R_CTRL , 32'h0000_0006);

        il_r(`IOMMU_LITE_REGION_BASE+0*32+`IOMMU_LITE_R_BASE, v);
        if (v===32'h1000_0000) begin pass_n=pass_n+1; $display("  [ OK ] region readback"); end
        else begin fail_n=fail_n+1; $display("  [FAIL] region readback = %h", v); end

        $display("\n[2] Enable IOMMU + IRQ");
        il_w(`IOMMU_LITE_REG_IRQ_EN, 32'h1);
        il_w(`IOMMU_LITE_REG_CTRL,   32'h1);
        il_r(`IOMMU_LITE_REG_IRQ_EN, v);
        if (v[0]===1'b1) begin pass_n=pass_n+1; $display("  [ OK ] IRQ_EN reads 1"); end
        else begin fail_n=fail_n+1; $display("  [FAIL] IRQ_EN = %h", v); end

        $display("\n[3] Legal accesses (expect ALLOW)");
        expect("R0 write", 32'h1000_0010, 4'd0, 1'b1, 32'hA5A5_1234, 1);
        expect("R0 read ", 32'h1000_0020, 4'd0, 1'b0, 32'h0,         1);
        expect("R1 read ", 32'h1010_0004, 4'd1, 1'b0, 32'h0,         1);
        expect("R2 write", 32'h1020_0000, 4'd2, 1'b1, 32'hDEAD_BEEF, 1);

        $display("\n[4] Illegal accesses (expect FAULT, and MUST NOT hang)");
        expect("R1 write to read-only region", 32'h1010_0004, 4'd1, 1'b1, 32'h1111_1111, 0);
        expect("R2 read from write-only region",32'h1020_0000, 4'd2, 1'b0, 32'h0,        0);
        expect("wrong channel C=5",            32'h1000_0010, 4'd5, 1'b0, 32'h0,         0);
        expect("address outside all regions",  32'h2000_0000, 4'd0, 1'b0, 32'h0,         0);
        expect("region 3 Valid=0",             32'h1030_0010, 4'd0, 1'b0, 32'h0,         0);

        $display("\n[5] Traffic generator still alive after the faults?");
        expect("R0 write again (proves no wedge)", 32'h1000_0030, 4'd0, 1'b1, 32'h600D_600D, 1);

        $display("\n[6] End-to-end translation");
        tg_issue(32'h1000_0040, 4'd0, 1'b1, 32'hCAFE_F00D, r);
        if (r==1 && ddr[didx(32'h1800_0040)] === 32'hCAFE_F00D) begin
            pass_n=pass_n+1;
            $display("  [ OK ] 0xCAFEF00D landed at translated addr 0x18000040");
        end else begin
            fail_n=fail_n+1;
            $display("  [FAIL] r=%0d  ddr[0x18000040]=%h", r, ddr[didx(32'h1800_0040)]);
        end

        $display("\n[7] Fault status");
        il_r(`IOMMU_LITE_REG_STATUS, v);
        if (v[0]===1'b1) begin pass_n=pass_n+1; $display("  [ OK ] sticky fault set (STATUS=%h)", v); end
        else begin fail_n=fail_n+1; $display("  [FAIL] STATUS=%h", v); end
        if (irq===1'b1) begin pass_n=pass_n+1; $display("  [ OK ] IRQ asserted"); end
        else begin fail_n=fail_n+1; $display("  [FAIL] IRQ not asserted"); end

        $display("\n============================================");
        $display("  iommu_lite_system_tb: %0d passed, %0d failed", pass_n, fail_n);
        if (fail_n==0) $display("  RESULT: ALL TESTS PASSED");
        else           $display("  RESULT: FAILURES PRESENT");
        $display("============================================");
        $finish;
    end

    initial begin #4000000; $display("GLOBAL TIMEOUT"); $finish; end

endmodule
