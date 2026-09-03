`include "iommu_lite_pkg.vh"
`timescale 1ns/1ps
//==========================================================================
// iommu_lite_core
//
// Implements the "Formal Model of IOMMU-Lite Operation" from the document,
// symbol-for-symbol:
//
//   Match_i     = 1 if (B_i <= A_in <= L_i) AND (C = CID_i) AND (V_i = 1)
//   i*          = index of the region where Match_i = 1 (first-match / priority)
//   Permitted   = 1 if requested access is a subset of P_i*
//   A_out       = T_i* + (A_in - B_i*)
//   Allow       = Match_i* AND Permitted
//   Fault       = NOT (exists i : Match_i = 1 AND Permitted = 1)
//
// This block is purely combinational (single-cycle, deterministic latency)
// per the paper's design goal of "low latency and RTL-friendly implementation".
//==========================================================================
module iommu_lite_core #(
    parameter NUM_REGIONS = `IOMMU_LITE_NUM_REGIONS,
    parameter RIDX_W      = `IOMMU_LITE_RIDX_W,
    parameter ADDR_W      = `IOMMU_LITE_ADDR_W,
    parameter CHAN_W      = `IOMMU_LITE_CHAN_W
)(
    // ---- Region table, flattened (region 0 in low-order slice) ----------
    input  wire [NUM_REGIONS*ADDR_W-1:0] B_i_flat,    // Input Base Address
    input  wire [NUM_REGIONS*ADDR_W-1:0] L_i_flat,    // Input Limit Address
    input  wire [NUM_REGIONS*ADDR_W-1:0] T_i_flat,    // Translated Base Address
    input  wire [NUM_REGIONS*CHAN_W-1:0] CID_i_flat,  // Channel ID
    input  wire [NUM_REGIONS*2-1:0]      P_i_flat,    // Permissions {W,R}
    input  wire [NUM_REGIONS-1:0]        V_i,         // Valid bits

    // ---- Incoming DMA request --------------------------------------------
    input  wire [ADDR_W-1:0]  A_in,      // input address from DMA
    input  wire [CHAN_W-1:0]  C,         // DMA channel ID
    input  wire               req_valid,
    input  wire               req_is_write,  // 1 = write access requested, 0 = read

    // ---- Result ------------------------------------------------------------
    output reg  [ADDR_W-1:0]  A_out,     // translated output address
    output reg                Allow,     // Match_i* AND Permitted
    output reg                Fault,     // NOT(exists i: Match_i AND Permitted)
    output reg  [RIDX_W-1:0]  i_star,    // index of matched region (region ID)
    output reg                i_star_valid
);

    integer i;

    // Per-region unpacked views
    wire [ADDR_W-1:0] B_i [0:NUM_REGIONS-1];
    wire [ADDR_W-1:0] L_i [0:NUM_REGIONS-1];
    wire [ADDR_W-1:0] T_i [0:NUM_REGIONS-1];
    wire [CHAN_W-1:0] CID_i [0:NUM_REGIONS-1];
    wire [1:0]        P_i [0:NUM_REGIONS-1];

    genvar g;
    generate
        for (g = 0; g < NUM_REGIONS; g = g + 1) begin : UNPACK
            assign B_i[g]   = B_i_flat  [g*ADDR_W +: ADDR_W];
            assign L_i[g]   = L_i_flat  [g*ADDR_W +: ADDR_W];
            assign T_i[g]   = T_i_flat  [g*ADDR_W +: ADDR_W];
            assign CID_i[g] = CID_i_flat[g*CHAN_W +: CHAN_W];
            assign P_i[g]   = P_i_flat  [g*2      +: 2];
        end
    endgenerate

    // Match_i for every region (combinational)
    wire [NUM_REGIONS-1:0] Match_i;
    generate
        for (g = 0; g < NUM_REGIONS; g = g + 1) begin : MATCH
            assign Match_i[g] = ((A_in >= B_i[g]) && (A_in <= L_i[g])) &&
                                 (C == CID_i[g]) &&
                                 (V_i[g] == 1'b1);
        end
    endgenerate

    // requested access, expressed in the same {W,R} encoding as P_i
    wire [1:0] req_access = req_is_write ? `IOMMU_LITE_PERM_W : `IOMMU_LITE_PERM_R;

    // i* : first-match priority (lowest region index wins ties), per document note
    // "(If multiple matches exist, use priority or first-match rule)"
    reg [RIDX_W-1:0] r_i_star;
    reg              r_i_star_valid;
    reg              r_Permitted;
    reg              r_Allow;
    reg [ADDR_W-1:0] r_A_out;

    always @(*) begin
        r_i_star       = {RIDX_W{1'b0}};
        r_i_star_valid = 1'b0;
        r_Permitted    = 1'b0;
        r_Allow        = 1'b0;
        r_A_out        = {ADDR_W{1'b0}};

        for (i = 0; i < NUM_REGIONS; i = i + 1) begin
            if (!r_i_star_valid && Match_i[i]) begin
                r_i_star       = i[RIDX_W-1:0];
                r_i_star_valid = 1'b1;
            end
        end

        if (req_valid && r_i_star_valid) begin
            // Permitted = 1, if requested access (a subset of) P_i*
            r_Permitted = ((req_access & P_i[r_i_star]) == req_access);
            // Allow = Match_i* AND Permitted
            r_Allow     = r_i_star_valid & r_Permitted;
            // A_out = T_i* + (A_in - B_i*)
            r_A_out     = T_i[r_i_star] + (A_in - B_i[r_i_star]);
        end
    end

    always @(*) begin
        i_star       = r_i_star;
        i_star_valid = r_i_star_valid;
        Allow        = req_valid & r_Allow;
        A_out        = r_A_out;
        // Fault = NOT (exists i : Match_i=1 AND Permitted=1)
        Fault        = req_valid & ~r_Allow;
    end

endmodule
