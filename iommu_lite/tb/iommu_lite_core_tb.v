`include "iommu_lite_pkg.vh"
`timescale 1ns/1ps
//==========================================================================
// iommu_lite_core_tb
//
// Programs the exact "example four-entry table" from the document:
//
//  RegionID Channel  InputBase    InputLimit   TranslatedBase  Perms  Valid
//   0        0       0x8000_0000  0x8000_FFFF  0x9000_0000     R/W    1
//   1        1       0x8100_0000  0x8100_7FFF  0x9100_0000     R      1
//   2        2       0x8200_0000  0x8200_FFFF  0x9200_0000     W      1
//   3        0       0x8300_0000  0x8300_3FFF  0x9300_0000     R/W    0
//
// and checks Match_i / Permitted / Allow / A_out / Fault against the
// formal model for a set of legal and illegal requests.
//==========================================================================
module iommu_lite_core_tb;

    localparam NUM_REGIONS = `IOMMU_LITE_NUM_REGIONS;
    localparam RIDX_W      = `IOMMU_LITE_RIDX_W;
    localparam ADDR_W      = `IOMMU_LITE_ADDR_W;
    localparam CHAN_W      = `IOMMU_LITE_CHAN_W;

    reg [NUM_REGIONS*ADDR_W-1:0] B_i_flat, L_i_flat, T_i_flat;
    reg [NUM_REGIONS*CHAN_W-1:0] CID_i_flat;
    reg [NUM_REGIONS*2-1:0]      P_i_flat;
    reg [NUM_REGIONS-1:0]        V_i;

    reg  [ADDR_W-1:0] A_in;
    reg  [CHAN_W-1:0] C;
    reg               req_valid;
    reg               req_is_write;

    wire [ADDR_W-1:0] A_out;
    wire               Allow;
    wire               Fault;
    wire [RIDX_W-1:0]  i_star;
    wire               i_star_valid;

    integer errors = 0;
    integer tests  = 0;

    iommu_lite_core #(
        .NUM_REGIONS(NUM_REGIONS), .RIDX_W(RIDX_W), .ADDR_W(ADDR_W), .CHAN_W(CHAN_W)
    ) dut (
        .B_i_flat(B_i_flat), .L_i_flat(L_i_flat), .T_i_flat(T_i_flat),
        .CID_i_flat(CID_i_flat), .P_i_flat(P_i_flat), .V_i(V_i),
        .A_in(A_in), .C(C), .req_valid(req_valid), .req_is_write(req_is_write),
        .A_out(A_out), .Allow(Allow), .Fault(Fault),
        .i_star(i_star), .i_star_valid(i_star_valid)
    );

    task set_region(input integer idx, input [ADDR_W-1:0] b, input [ADDR_W-1:0] l,
                     input [ADDR_W-1:0] t, input [CHAN_W-1:0] cid, input [1:0] p, input v);
        begin
            B_i_flat  [idx*ADDR_W +: ADDR_W] = b;
            L_i_flat  [idx*ADDR_W +: ADDR_W] = l;
            T_i_flat  [idx*ADDR_W +: ADDR_W] = t;
            CID_i_flat[idx*CHAN_W +: CHAN_W] = cid;
            P_i_flat  [idx*2      +: 2]      = p;
            V_i[idx] = v;
        end
    endtask

    task check(input [255:0] name, input exp_allow, input exp_fault, input [ADDR_W-1:0] exp_aout);
        begin
            tests = tests + 1;
            #1;
            if (Allow !== exp_allow || Fault !== exp_fault ||
                (exp_allow && A_out !== exp_aout)) begin
                errors = errors + 1;
                $display("FAIL [%0s]: A_in=%h C=%0d wr=%0d -> Allow=%b(exp %b) Fault=%b(exp %b) A_out=%h(exp %h)",
                          name, A_in, C, req_is_write, Allow, exp_allow, Fault, exp_fault, A_out, exp_aout);
            end else begin
                $display("PASS [%0s]: A_in=%h C=%0d wr=%0d -> Allow=%b Fault=%b A_out=%h",
                          name, A_in, C, req_is_write, Allow, Fault, A_out);
            end
        end
    endtask

    integer k;

    initial begin
        // clear all regions first
        for (k = 0; k < NUM_REGIONS; k = k + 1)
            set_region(k, 0, 0, 0, 0, 2'b00, 1'b0);

        // Program the document's example table
        set_region(0, 32'h8000_0000, 32'h8000_FFFF, 32'h9000_0000, 0, `IOMMU_LITE_PERM_RW, 1'b1);
        set_region(1, 32'h8100_0000, 32'h8100_7FFF, 32'h9100_0000, 1, `IOMMU_LITE_PERM_R,  1'b1);
        set_region(2, 32'h8200_0000, 32'h8200_FFFF, 32'h9200_0000, 2, `IOMMU_LITE_PERM_W,  1'b1);
        set_region(3, 32'h8300_0000, 32'h8300_3FFF, 32'h9300_0000, 0, `IOMMU_LITE_PERM_RW, 1'b0); // invalid

        req_valid = 1'b1;

        // 1) Region 0: legal read within range, channel 0, R/W allowed
        A_in = 32'h8000_1000; C = 0; req_is_write = 1'b0;
        check("R0_read_ok", 1'b1, 1'b0, 32'h9000_1000);

        // 2) Region 0: legal write within range, channel 0
        A_in = 32'h8000_0004; C = 0; req_is_write = 1'b1;
        check("R0_write_ok", 1'b1, 1'b0, 32'h9000_0004);

        // 3) Region 1: read-only region, read should succeed
        A_in = 32'h8100_0010; C = 1; req_is_write = 1'b0;
        check("R1_read_ok", 1'b1, 1'b0, 32'h9100_0010);

        // 4) Region 1: read-only region, write should FAULT (Permitted=0)
        A_in = 32'h8100_0010; C = 1; req_is_write = 1'b1;
        check("R1_write_fault", 1'b0, 1'b1, 32'h0);

        // 5) Region 2: write-only region, write should succeed
        A_in = 32'h8200_0020; C = 2; req_is_write = 1'b1;
        check("R2_write_ok", 1'b1, 1'b0, 32'h9200_0020);

        // 6) Region 2: write-only region, read should FAULT
        A_in = 32'h8200_0020; C = 2; req_is_write = 1'b0;
        check("R2_read_fault", 1'b0, 1'b1, 32'h0);

        // 7) Wrong channel ID for region 0's address range -> no Match_i -> Fault
        A_in = 32'h8000_1000; C = 5; req_is_write = 1'b0;
        check("wrong_channel_fault", 1'b0, 1'b1, 32'h0);

        // 8) Address outside all ranges -> Fault
        A_in = 32'h7FFF_FFFF; C = 0; req_is_write = 1'b0;
        check("out_of_range_fault", 1'b0, 1'b1, 32'h0);

        // 9) Region 3 is Valid=0 -> even in-range/right-channel access FAULTs
        A_in = 32'h8300_0010; C = 0; req_is_write = 1'b0;
        check("invalid_region_fault", 1'b0, 1'b1, 32'h0);

        // 10) Upper edge of region 0 (A_in == L_i) still legal (inclusive limit)
        A_in = 32'h8000_FFFF; C = 0; req_is_write = 1'b0;
        check("upper_edge_ok", 1'b1, 1'b0, 32'h9000_FFFF);

        $display("---------------------------------------------------");
        $display("iommu_lite_core_tb: %0d/%0d tests passed", tests-errors, tests);
        if (errors == 0) $display("RESULT: ALL TESTS PASSED");
        else $display("RESULT: %0d TESTS FAILED", errors);
        $finish;
    end

endmodule
