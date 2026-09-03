`timescale 1ns/1ps
//==========================================================================
// iommu_lite_traffic_gen
//
// A minimal AXI4 master, controlled from the PS over AXI-Lite, used purely
// as a DEMO STIMULUS SOURCE on the Zybo Z7-20. It lets bare-metal software
// pick A_in (address) and C (channel ID, driven out on AWID/ARID) directly,
// which is otherwise not possible from the PS's own GP master ports (their
// AXI ID is fixed by the PS7 and not software-selectable per-transaction).
//
// Register map (AXI-Lite, offsets):
//   0x00 CTRL     : [0]=start, [1]=is_write
//   0x04 ADDR     : A_in (address to issue, pre-translation)
//   0x08 CHAN     : C (channel ID -> AWID/ARID)
//   0x0C WDATA    : data to write (write requests only)
//   0x10 STATUS   : [0]=busy, [1]=done, [3:2]=last resp (bresp/rresp)
//   0x14 RDATA    : last read data
//==========================================================================
module iommu_lite_traffic_gen #(
    parameter C_S_AXI_ADDR_WIDTH = 8,
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_M_AXI_ID_WIDTH   = 4,
    parameter C_M_AXI_ADDR_WIDTH = 32,
    parameter C_M_AXI_DATA_WIDTH = 32
)(
    input  wire aclk,
    input  wire aresetn,

    // ---- AXI-Lite control port (from PS) ----------------------------------
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]  s_axi_awaddr,
    input  wire                           s_axi_awvalid,
    output reg                            s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]  s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                           s_axi_wvalid,
    output reg                            s_axi_wready,
    output reg  [1:0]                     s_axi_bresp,
    output reg                            s_axi_bvalid,
    input  wire                           s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]  s_axi_araddr,
    input  wire                           s_axi_arvalid,
    output reg                            s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]  s_axi_rdata,
    output reg  [1:0]                     s_axi_rresp,
    output reg                            s_axi_rvalid,
    input  wire                           s_axi_rready,

    // ---- AXI4 master (data path towards iommu_lite_top S_AXI) -------------
    output reg  [C_M_AXI_ID_WIDTH-1:0]    m_axi_awid,
    output reg  [C_M_AXI_ADDR_WIDTH-1:0]  m_axi_awaddr,
    output wire [7:0]                     m_axi_awlen,
    output wire [2:0]                     m_axi_awsize,
    output wire [1:0]                     m_axi_awburst,
    output reg                            m_axi_awvalid,
    input  wire                           m_axi_awready,
    output reg  [C_M_AXI_DATA_WIDTH-1:0]  m_axi_wdata,
    output wire [(C_M_AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
    output wire                           m_axi_wlast,
    output reg                            m_axi_wvalid,
    input  wire                           m_axi_wready,
    input  wire [C_M_AXI_ID_WIDTH-1:0]    m_axi_bid,
    input  wire [1:0]                     m_axi_bresp,
    input  wire                           m_axi_bvalid,
    output reg                            m_axi_bready,
    output reg  [C_M_AXI_ID_WIDTH-1:0]    m_axi_arid,
    output reg  [C_M_AXI_ADDR_WIDTH-1:0]  m_axi_araddr,
    output wire [7:0]                     m_axi_arlen,
    output wire [2:0]                     m_axi_arsize,
    output wire [1:0]                     m_axi_arburst,
    output reg                            m_axi_arvalid,
    input  wire                           m_axi_arready,
    input  wire [C_M_AXI_ID_WIDTH-1:0]    m_axi_rid,
    input  wire [C_M_AXI_DATA_WIDTH-1:0]  m_axi_rdata,
    input  wire [1:0]                     m_axi_rresp,
    input  wire                           m_axi_rlast,
    input  wire                           m_axi_rvalid,
    output reg                            m_axi_rready
);

    assign m_axi_awlen = 8'h0; assign m_axi_awsize = 3'b010; assign m_axi_awburst = 2'b01;
    assign m_axi_arlen = 8'h0; assign m_axi_arsize = 3'b010; assign m_axi_arburst = 2'b01;
    assign m_axi_wstrb = {(C_M_AXI_DATA_WIDTH/8){1'b1}};
    assign m_axi_wlast = 1'b1;

    reg [31:0] r_addr, r_chan, r_wdata, r_rdata;
    reg        r_is_write;
    reg        r_busy, r_done;
    reg [1:0]  r_last_resp;

    localparam S_IDLE=0, S_AW_W=1, S_B=2, S_AR=3, S_R=4;
    reg [2:0] state;

    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= S_IDLE; r_busy <= 0; r_done <= 0;
            m_axi_awvalid<=0; m_axi_wvalid<=0; m_axi_bready<=0; m_axi_arvalid<=0; m_axi_rready<=0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (r_busy && !r_is_write) begin
                        m_axi_arid <= r_chan[C_M_AXI_ID_WIDTH-1:0];
                        m_axi_araddr <= r_addr;
                        m_axi_arvalid <= 1'b1;
                        // RREADY is asserted on entry to S_R, not here -- see
                        // the BREADY note below; same race applies.
                        state <= S_AR;
                    end else if (r_busy && r_is_write) begin
                        m_axi_awid <= r_chan[C_M_AXI_ID_WIDTH-1:0];
                        m_axi_awaddr <= r_addr;
                        m_axi_awvalid <= 1'b1;
                        m_axi_wdata <= r_wdata;
                        m_axi_wvalid <= 1'b1;
                        // NOTE: BREADY is deliberately NOT asserted here.
                        // IOMMU-Lite answers a BLOCKED write with SLVERR
                        // almost immediately. If BREADY were already high
                        // during S_AW_W, that B beat would handshake and be
                        // consumed while this FSM is still in S_AW_W, and by
                        // the time S_B is entered BVALID is long gone -- the
                        // FSM then waits forever and r_busy sticks at 1,
                        // wedging every subsequent transaction. BREADY is
                        // raised on entry to S_B instead, so the response is
                        // always captured in the state that looks for it.
                        state <= S_AW_W;
                    end
                end
                S_AW_W: begin
                    if (m_axi_awvalid && m_axi_awready) m_axi_awvalid <= 0;
                    if (m_axi_wvalid  && m_axi_wready)  m_axi_wvalid  <= 0;
                    if (!m_axi_awvalid && !m_axi_wvalid) begin
                        state        <= S_B;
                        m_axi_bready <= 1'b1;
                    end
                end
                S_B: begin
                    if (m_axi_bvalid) begin
                        r_last_resp <= m_axi_bresp;
                        m_axi_bready <= 0;
                        r_busy <= 0; r_done <= 1;
                        state <= S_IDLE;
                    end
                end
                S_AR: begin
                    if (m_axi_arvalid && m_axi_arready) m_axi_arvalid <= 0;
                    state        <= S_R;
                    m_axi_rready <= 1'b1;    // assert in the state that consumes R
                end
                S_R: begin
                    if (m_axi_rvalid) begin
                        r_last_resp <= m_axi_rresp;
                        r_rdata <= m_axi_rdata;
                        m_axi_rready <= 0;
                        r_busy <= 0; r_done <= 1;
                        state <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase

            // AXI-Lite write: start register writes trigger a new transaction
            if (s_axi_awvalid && s_axi_awready && s_axi_wvalid && s_axi_wready) begin
                case (s_axi_awaddr[7:0])
                    8'h00: if (s_axi_wdata[0] && !r_busy) begin
                               r_is_write <= s_axi_wdata[1];
                               r_busy <= 1'b1; r_done <= 1'b0;
                           end
                    8'h04: r_addr  <= s_axi_wdata;
                    8'h08: r_chan  <= s_axi_wdata;
                    8'h0C: r_wdata <= s_axi_wdata;
                    default: ;
                endcase
            end
        end
    end

    // ---- AXI-Lite write handshake (simple) --------------------------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready <= 0; s_axi_wready <= 0; s_axi_bvalid <= 0; s_axi_bresp <= 0;
        end else begin
            s_axi_awready <= ~s_axi_awready && s_axi_awvalid && s_axi_wvalid;
            s_axi_wready  <= ~s_axi_wready  && s_axi_awvalid && s_axi_wvalid;
            if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid) s_axi_bvalid <= 1'b1;
            else if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
        end
    end

    // ---- AXI-Lite read handshake -------------------------------------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_arready <= 0; s_axi_rvalid <= 0; s_axi_rresp <= 0; s_axi_rdata <= 0;
        end else begin
            s_axi_arready <= ~s_axi_arready && s_axi_arvalid;
            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr[7:0])
                    8'h10:   s_axi_rdata <= {28'b0, r_last_resp, r_done, r_busy};
                    8'h14:   s_axi_rdata <= r_rdata;
                    default: s_axi_rdata <= 32'hDEAD_BEEF;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
                // NOTE: r_done is cleared exclusively in the main FSM
                // always block above (on transaction start) -- do NOT
                // also clear it here, or you get DRC MDRV-1 (multiple
                // drivers). Software sees r_done stay high until the
                // next transaction it issues, which is fine: STATUS is
                // polled for busy/done, not edge-triggered.
            end
        end
    end

endmodule
