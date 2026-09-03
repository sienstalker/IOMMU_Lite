`include "iommu_lite_pkg.vh"
`timescale 1ns/1ps
//==========================================================================
// iommu_lite_axi_wrapper  (REVISION 2)
//
// Sits in-line on the DMA data path: S_AXI (from DMA master / traffic
// generator) -> [IOMMU-Lite address check + translation] -> M_AXI
// (to the AXI interconnect / HP port -> DDR).
//
// The AXI ID (AWID/ARID) of the incoming transaction is used as the DMA
// Channel ID "C" from the document's formal model; AWADDR/ARADDR is A_in.
//
// ---- WHY THIS WAS REWRITTEN (rev 1 -> rev 2) ------------------------------
// Rev 1 drove the M_AXI address and the pass/block decision *combinationally*
// from S_AXI's AWVALID/ARVALID. That had two hardware bugs:
//
//   BUG 1: m_axi_awaddr was ALWAYS A_out, even in bypass (iommu_enable=0).
//          When no region matched, iommu_lite_core drives A_out = 0, so a
//          bypassed transaction went to address 0 instead of its own address.
//
//   BUG 2: the decision (wr_pass) depended on Allow_wr, which depends on
//          req_valid = s_axi_awvalid. The instant the AW handshake completed,
//          AWVALID dropped, Allow_wr fell to 0, and the W data beats were
//          silently swallowed instead of being forwarded to M_AXI. Any master
//          that does not hold AWVALID high across its W beats would hang or
//          lose write data.
//
// Rev 2 LATCHES the decision (and the translated address) at the moment the
// AW/AR handshake is accepted, and holds it for the whole transaction. One
// outstanding read and one outstanding write at a time, which is correct and
// sufficient here; the decision is still made in a single cycle, so the
// paper's single-cycle-check property is preserved.
//==========================================================================
module iommu_lite_axi_wrapper #(
    parameter NUM_REGIONS = `IOMMU_LITE_NUM_REGIONS,
    parameter RIDX_W      = `IOMMU_LITE_RIDX_W,
    parameter ADDR_W      = `IOMMU_LITE_ADDR_W,
    parameter CHAN_W      = `IOMMU_LITE_CHAN_W,
    parameter C_AXI_ID_WIDTH   = 4,
    parameter C_AXI_DATA_WIDTH = 32
)(
    input  wire                          aclk,
    input  wire                          aresetn,

    input  wire                          iommu_enable,

    // ---- Region table (from iommu_lite_regs) ------------------------------
    input  wire [NUM_REGIONS*ADDR_W-1:0] B_i_flat,
    input  wire [NUM_REGIONS*ADDR_W-1:0] L_i_flat,
    input  wire [NUM_REGIONS*ADDR_W-1:0] T_i_flat,
    input  wire [NUM_REGIONS*CHAN_W-1:0] CID_i_flat,
    input  wire [NUM_REGIONS*2-1:0]      P_i_flat,
    input  wire [NUM_REGIONS-1:0]        V_i,

    // ---- Fault / allow report --------------------------------------------
    output reg                           fault_pulse,
    output reg  [ADDR_W-1:0]             fault_addr,
    output reg  [CHAN_W-1:0]             fault_chan,
    output reg                           allow_pulse,

    // ================= S_AXI (slave: DMA master connects here) ============
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

    // ================= M_AXI (master: towards interconnect / HP port) =====
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
    output wire                          m_axi_rready
);

    localparam [1:0] RESP_OKAY   = 2'b00;
    localparam [1:0] RESP_SLVERR = 2'b10;

    //======================================================================
    // Combinational checks (valid while the corresponding S_AXI *VALID is up)
    //======================================================================
    wire [CHAN_W-1:0] C_wr = s_axi_awid[CHAN_W-1:0];
    wire [CHAN_W-1:0] C_rd = s_axi_arid[CHAN_W-1:0];

    wire [ADDR_W-1:0] A_out_wr, A_out_rd;
    wire              Allow_wr, Allow_rd, Fault_wr, Fault_rd;
    wire [RIDX_W-1:0] istar_wr, istar_rd;
    wire              istar_wr_v, istar_rd_v;

    iommu_lite_core #(
        .NUM_REGIONS(NUM_REGIONS), .RIDX_W(RIDX_W), .ADDR_W(ADDR_W), .CHAN_W(CHAN_W)
    ) u_core_wr (
        .B_i_flat(B_i_flat), .L_i_flat(L_i_flat), .T_i_flat(T_i_flat),
        .CID_i_flat(CID_i_flat), .P_i_flat(P_i_flat), .V_i(V_i),
        .A_in(s_axi_awaddr), .C(C_wr),
        .req_valid(s_axi_awvalid), .req_is_write(1'b1),
        .A_out(A_out_wr), .Allow(Allow_wr), .Fault(Fault_wr),
        .i_star(istar_wr), .i_star_valid(istar_wr_v)
    );

    iommu_lite_core #(
        .NUM_REGIONS(NUM_REGIONS), .RIDX_W(RIDX_W), .ADDR_W(ADDR_W), .CHAN_W(CHAN_W)
    ) u_core_rd (
        .B_i_flat(B_i_flat), .L_i_flat(L_i_flat), .T_i_flat(T_i_flat),
        .CID_i_flat(CID_i_flat), .P_i_flat(P_i_flat), .V_i(V_i),
        .A_in(s_axi_araddr), .C(C_rd),
        .req_valid(s_axi_arvalid), .req_is_write(1'b0),
        .A_out(A_out_rd), .Allow(Allow_rd), .Fault(Fault_rd),
        .i_star(istar_rd), .i_star_valid(istar_rd_v)
    );

    // Decision + outgoing address, evaluated at AW/AR acceptance time.
    // In bypass (iommu_enable=0) the transaction passes through UNTRANSLATED.
    wire              wr_dec_allow = iommu_enable ? Allow_wr : 1'b1;
    wire [ADDR_W-1:0] wr_dec_addr  = (iommu_enable && Allow_wr) ? A_out_wr : s_axi_awaddr;
    wire              rd_dec_allow = iommu_enable ? Allow_rd : 1'b1;
    wire [ADDR_W-1:0] rd_dec_addr  = (iommu_enable && Allow_rd) ? A_out_rd : s_axi_araddr;

    //======================================================================
    // WRITE path : latch decision at AW, hold for the whole transaction
    //======================================================================
    reg                        wr_busy;
    reg                        wr_allowed;
    reg                        wr_aw_sent;
    reg                        wr_err_resp;
    reg [C_AXI_ID_WIDTH-1:0]   wr_id_q;
    reg [ADDR_W-1:0]           wr_addr_q;
    reg [7:0]                  wr_len_q;
    reg [2:0]                  wr_size_q;
    reg [1:0]                  wr_burst_q;

    wire aw_accept = ~wr_busy & s_axi_awvalid;   // s_axi_awready = ~wr_busy

    always @(posedge aclk) begin
        if (!aresetn) begin
            wr_busy     <= 1'b0;
            wr_allowed  <= 1'b0;
            wr_aw_sent  <= 1'b0;
            wr_err_resp <= 1'b0;
            wr_id_q     <= {C_AXI_ID_WIDTH{1'b0}};
            wr_addr_q   <= {ADDR_W{1'b0}};
            wr_len_q    <= 8'd0;
            wr_size_q   <= 3'd0;
            wr_burst_q  <= 2'd0;
        end else begin
            if (aw_accept) begin
                wr_busy    <= 1'b1;
                wr_allowed <= wr_dec_allow;
                wr_id_q    <= s_axi_awid;
                wr_addr_q  <= wr_dec_addr;
                wr_len_q   <= s_axi_awlen;
                wr_size_q  <= s_axi_awsize;
                wr_burst_q <= s_axi_awburst;
                wr_aw_sent <= 1'b0;
            end

            if (m_axi_awvalid && m_axi_awready)
                wr_aw_sent <= 1'b1;

            // Blocked write: absorb all W beats, then answer SLVERR
            if (wr_busy && !wr_allowed && s_axi_wvalid && s_axi_wready && s_axi_wlast)
                wr_err_resp <= 1'b1;

            if (s_axi_bvalid && s_axi_bready) begin
                wr_busy     <= 1'b0;
                wr_err_resp <= 1'b0;
                wr_aw_sent  <= 1'b0;
            end
        end
    end

    assign s_axi_awready = ~wr_busy;

    assign m_axi_awid    = wr_id_q;
    assign m_axi_awaddr  = wr_addr_q;
    assign m_axi_awlen   = wr_len_q;
    assign m_axi_awsize  = wr_size_q;
    assign m_axi_awburst = wr_burst_q;
    assign m_axi_awvalid = wr_busy & wr_allowed & ~wr_aw_sent;

    assign m_axi_wdata  = s_axi_wdata;
    assign m_axi_wstrb  = s_axi_wstrb;
    assign m_axi_wlast  = s_axi_wlast;
    assign m_axi_wvalid = wr_busy & wr_allowed & s_axi_wvalid;
    assign s_axi_wready = wr_busy & (wr_allowed ? m_axi_wready : 1'b1);

    assign s_axi_bvalid = wr_err_resp | (wr_busy & wr_allowed & m_axi_bvalid);
    assign s_axi_bresp  = wr_err_resp ? RESP_SLVERR : m_axi_bresp;
    assign s_axi_bid    = wr_err_resp ? wr_id_q     : m_axi_bid;
    assign m_axi_bready = s_axi_bready & wr_busy & wr_allowed;

    //======================================================================
    // READ path : latch decision at AR; synthesize SLVERR beats when blocked
    //======================================================================
    reg                        rd_busy;
    reg                        rd_allowed;
    reg                        rd_ar_sent;
    reg                        rd_err_active;
    reg [8:0]                  rd_err_cnt;      // beats still owed on a blocked read
    reg [C_AXI_ID_WIDTH-1:0]   rd_id_q;
    reg [ADDR_W-1:0]           rd_addr_q;
    reg [7:0]                  rd_len_q;
    reg [2:0]                  rd_size_q;
    reg [1:0]                  rd_burst_q;

    wire ar_accept = ~rd_busy & s_axi_arvalid;   // s_axi_arready = ~rd_busy

    always @(posedge aclk) begin
        if (!aresetn) begin
            rd_busy       <= 1'b0;
            rd_allowed    <= 1'b0;
            rd_ar_sent    <= 1'b0;
            rd_err_active <= 1'b0;
            rd_err_cnt    <= 9'd0;
            rd_id_q       <= {C_AXI_ID_WIDTH{1'b0}};
            rd_addr_q     <= {ADDR_W{1'b0}};
            rd_len_q      <= 8'd0;
            rd_size_q     <= 3'd0;
            rd_burst_q    <= 2'd0;
        end else begin
            if (ar_accept) begin
                rd_busy    <= 1'b1;
                rd_allowed <= rd_dec_allow;
                rd_id_q    <= s_axi_arid;
                rd_addr_q  <= rd_dec_addr;
                rd_len_q   <= s_axi_arlen;
                rd_size_q  <= s_axi_arsize;
                rd_burst_q <= s_axi_arburst;
                rd_ar_sent <= 1'b0;
                if (!rd_dec_allow) begin
                    rd_err_active <= 1'b1;
                    rd_err_cnt    <= {1'b0, s_axi_arlen} + 9'd1;
                end
            end

            if (m_axi_arvalid && m_axi_arready)
                rd_ar_sent <= 1'b1;

            // Blocked read: emit arlen+1 SLVERR beats, RLAST on the final one
            if (rd_err_active && s_axi_rvalid && s_axi_rready) begin
                rd_err_cnt <= rd_err_cnt - 9'd1;
                if (rd_err_cnt == 9'd1) begin
                    rd_err_active <= 1'b0;
                    rd_busy       <= 1'b0;
                    rd_ar_sent    <= 1'b0;
                end
            end

            // Normal completion
            if (rd_busy && rd_allowed && s_axi_rvalid && s_axi_rready && s_axi_rlast) begin
                rd_busy    <= 1'b0;
                rd_ar_sent <= 1'b0;
            end
        end
    end

    assign s_axi_arready = ~rd_busy;

    assign m_axi_arid    = rd_id_q;
    assign m_axi_araddr  = rd_addr_q;
    assign m_axi_arlen   = rd_len_q;
    assign m_axi_arsize  = rd_size_q;
    assign m_axi_arburst = rd_burst_q;
    assign m_axi_arvalid = rd_busy & rd_allowed & ~rd_ar_sent;

    assign s_axi_rid    = rd_err_active ? rd_id_q : m_axi_rid;
    assign s_axi_rdata  = rd_err_active ? {C_AXI_DATA_WIDTH{1'b0}} : m_axi_rdata;
    assign s_axi_rresp  = rd_err_active ? RESP_SLVERR : m_axi_rresp;
    assign s_axi_rlast  = rd_err_active ? (rd_err_cnt == 9'd1) : m_axi_rlast;
    assign s_axi_rvalid = rd_err_active | (rd_busy & rd_allowed & m_axi_rvalid);
    assign m_axi_rready = s_axi_rready & rd_busy & rd_allowed;

    //======================================================================
    // Fault / allow reporting (one-cycle pulses, at AW/AR acceptance)
    //======================================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            fault_pulse <= 1'b0;
            allow_pulse <= 1'b0;
            fault_addr  <= {ADDR_W{1'b0}};
            fault_chan  <= {CHAN_W{1'b0}};
        end else begin
            fault_pulse <= 1'b0;
            allow_pulse <= 1'b0;
            if (iommu_enable && aw_accept) begin
                if (!Allow_wr) begin
                    fault_pulse <= 1'b1;
                    fault_addr  <= s_axi_awaddr;
                    fault_chan  <= C_wr;
                end else begin
                    allow_pulse <= 1'b1;
                end
            end else if (iommu_enable && ar_accept) begin
                if (!Allow_rd) begin
                    fault_pulse <= 1'b1;
                    fault_addr  <= s_axi_araddr;
                    fault_chan  <= C_rd;
                end else begin
                    allow_pulse <= 1'b1;
                end
            end
        end
    end

endmodule
