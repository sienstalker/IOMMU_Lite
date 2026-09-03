`include "iommu_lite_pkg.vh"
`timescale 1ns/1ps
//==========================================================================
// iommu_lite_regs
//
// AXI4-Lite slave implementing the "Programming Model" from the document:
// software programs, per region, the Input Base/Limit Address, Translated
// Base Address, Channel ID and Permissions, plus a Valid bit to enable or
// disable the entry. Also exposes fault status/interrupt registers.
//==========================================================================
module iommu_lite_regs #(
    parameter NUM_REGIONS = `IOMMU_LITE_NUM_REGIONS,
    parameter RIDX_W      = `IOMMU_LITE_RIDX_W,
    parameter ADDR_W      = `IOMMU_LITE_ADDR_W,
    parameter CHAN_W      = `IOMMU_LITE_CHAN_W,
    parameter C_S_AXI_ADDR_WIDTH = 12,
    parameter C_S_AXI_DATA_WIDTH = 32
)(
    input  wire                             s_axi_aclk,
    input  wire                             s_axi_aresetn,

    // AXI4-Lite slave interface (config port)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  wire                             s_axi_awvalid,
    output reg                              s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]    s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                             s_axi_wvalid,
    output reg                              s_axi_wready,
    output reg  [1:0]                       s_axi_bresp,
    output reg                              s_axi_bvalid,
    input  wire                             s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]    s_axi_araddr,
    input  wire                             s_axi_arvalid,
    output reg                              s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]    s_axi_rdata,
    output reg  [1:0]                       s_axi_rresp,
    output reg                              s_axi_rvalid,
    input  wire                             s_axi_rready,

    // ---- Region table outputs, flattened, to iommu_lite_core -------------
    output wire [NUM_REGIONS*ADDR_W-1:0]  B_i_flat,
    output wire [NUM_REGIONS*ADDR_W-1:0]  L_i_flat,
    output wire [NUM_REGIONS*ADDR_W-1:0]  T_i_flat,
    output wire [NUM_REGIONS*CHAN_W-1:0]  CID_i_flat,
    output wire [NUM_REGIONS*2-1:0]       P_i_flat,
    output wire [NUM_REGIONS-1:0]         V_i,

    output wire                           iommu_enable,

    // ---- Fault reporting from core / wrapper -------------------------------
    input  wire                           fault_pulse,     // 1-cycle pulse on Fault
    input  wire [ADDR_W-1:0]              fault_addr,      // A_in that faulted
    input  wire [CHAN_W-1:0]              fault_chan,      // C that faulted
    output wire                           irq              // interrupt to PS
);

    localparam integer NREG = NUM_REGIONS;

    // ---- Region table storage --------------------------------------------
    reg [ADDR_W-1:0] B_reg   [0:NREG-1];
    reg [ADDR_W-1:0] L_reg   [0:NREG-1];
    reg [ADDR_W-1:0] T_reg   [0:NREG-1];
    reg [CHAN_W-1:0] CID_reg [0:NREG-1];
    reg [1:0]        P_reg   [0:NREG-1];
    reg              V_reg   [0:NREG-1];

    reg              r_enable;
    reg              r_fault_sticky;
    reg              r_irq_en;
    reg [ADDR_W-1:0] r_fault_addr;
    reg [CHAN_W-1:0] r_fault_chan;

    integer k;

    genvar g;
    generate
        for (g = 0; g < NREG; g = g + 1) begin : PACK
            assign B_i_flat  [g*ADDR_W +: ADDR_W] = B_reg[g];
            assign L_i_flat  [g*ADDR_W +: ADDR_W] = L_reg[g];
            assign T_i_flat  [g*ADDR_W +: ADDR_W] = T_reg[g];
            assign CID_i_flat[g*CHAN_W +: CHAN_W] = CID_reg[g];
            assign P_i_flat  [g*2      +: 2]      = P_reg[g];
            assign V_i[g]                         = V_reg[g];
        end
    endgenerate

    assign iommu_enable = r_enable;
    assign irq = r_fault_sticky & r_irq_en;

    // ---- Address decode bounds -------------------------------------------
    // The region table occupies REGION_BASE .. REGION_BASE + NREG*STRIDE - 1.
    // Bounding the UPPER end matters: without it, any address at or above
    // REGION_BASE is treated as a region access, the index is truncated to
    // RIDX_W bits, and a stray high address bit silently ALIASES the global
    // registers onto region entries. (That is exactly what happens if this
    // slave is given an AXI segment that is not aligned to its address-port
    // width -- e.g. a 12-bit *addr port handed a segment based at 0x...800,
    // which leaves bit[11] set on every access.) With the bound in place such
    // an access decodes as an unmapped global register and is ignored/reads
    // DEADBEEF, which is visible instead of quietly corrupting the table.
    localparam [11:0] REGION_TOP =
        `IOMMU_LITE_REGION_BASE + (NREG * `IOMMU_LITE_REGION_STRIDE);

    // ---- Write channel (simple, non-pipelined AXI-Lite FSM) --------------
    reg aw_hs, w_hs;

    wire [C_S_AXI_ADDR_WIDTH-1:0] wr_addr = s_axi_awaddr;
    wire [7:0] wr_off   = wr_addr[7:0];
    wire is_region_wr   = (wr_addr >= `IOMMU_LITE_REGION_BASE) && (wr_addr < REGION_TOP);
    wire [RIDX_W-1:0] wr_ridx = (wr_addr - `IOMMU_LITE_REGION_BASE) / `IOMMU_LITE_REGION_STRIDE;
    wire [7:0] wr_reg_off = (wr_addr - `IOMMU_LITE_REGION_BASE) % `IOMMU_LITE_REGION_STRIDE;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready  <= 1'b0;
            s_axi_wready   <= 1'b0;
            s_axi_bvalid   <= 1'b0;
            s_axi_bresp    <= 2'b00;
            r_enable       <= 1'b0;
            r_irq_en       <= 1'b0;
            for (k = 0; k < NREG; k = k + 1) begin
                B_reg[k]   <= {ADDR_W{1'b0}};
                L_reg[k]   <= {ADDR_W{1'b0}};
                T_reg[k]   <= {ADDR_W{1'b0}};
                CID_reg[k] <= {CHAN_W{1'b0}};
                P_reg[k]   <= 2'b00;
                V_reg[k]   <= 1'b0;
            end
        end else begin
            // handshake
            s_axi_awready <= ~s_axi_awready && s_axi_awvalid && s_axi_wvalid;
            s_axi_wready  <= ~s_axi_wready  && s_axi_awvalid && s_axi_wvalid;

            if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid) begin
                if (is_region_wr && wr_ridx < NREG) begin
                    case (wr_reg_off)
                        `IOMMU_LITE_R_CTRL: begin
                            V_reg[wr_ridx]   <= s_axi_wdata[0];
                            P_reg[wr_ridx]   <= s_axi_wdata[2:1];
                            CID_reg[wr_ridx] <= s_axi_wdata[6:3];
                        end
                        `IOMMU_LITE_R_BASE:  B_reg[wr_ridx] <= s_axi_wdata;
                        `IOMMU_LITE_R_LIMIT: L_reg[wr_ridx] <= s_axi_wdata;
                        `IOMMU_LITE_R_XLATE: T_reg[wr_ridx] <= s_axi_wdata;
                        default: ;
                    endcase
                end else begin
                    case (wr_off)
                        `IOMMU_LITE_REG_CTRL:   r_enable <= s_axi_wdata[0];
                        `IOMMU_LITE_REG_IRQ_EN: r_irq_en <= s_axi_wdata[0];
                        // NOTE: IRQ_CLR (clearing r_fault_sticky) is handled
                        // exclusively in the "Fault status capture" always
                        // block below -- do NOT also drive r_fault_sticky
                        // here, or you get DRC MDRV-1 (multiple drivers).
                        default: ;
                    endcase
                end
            end

            // B response
            if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid)
                s_axi_bvalid <= 1'b1;
            else if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // ---- Fault status capture (independent of AXI write FSM) -------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            r_fault_sticky <= 1'b0;
            r_fault_addr   <= {ADDR_W{1'b0}};
            r_fault_chan   <= {CHAN_W{1'b0}};
        end else begin
            if (fault_pulse) begin
                r_fault_sticky <= 1'b1;
                r_fault_addr   <= fault_addr;
                r_fault_chan   <= fault_chan;
            end else if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid &&
                         !is_region_wr && wr_off == `IOMMU_LITE_REG_IRQ_CLR && s_axi_wdata[0]) begin
                r_fault_sticky <= 1'b0;
            end
        end
    end

    // ---- Read channel -------------------------------------------------------
    wire [C_S_AXI_ADDR_WIDTH-1:0] rd_addr = s_axi_araddr;
    wire [7:0] rd_off       = rd_addr[7:0];
    wire is_region_rd       = (rd_addr >= `IOMMU_LITE_REGION_BASE) && (rd_addr < REGION_TOP);
    wire [RIDX_W-1:0] rd_ridx = (rd_addr - `IOMMU_LITE_REGION_BASE) / `IOMMU_LITE_REGION_STRIDE;
    wire [7:0] rd_reg_off   = (rd_addr - `IOMMU_LITE_REGION_BASE) % `IOMMU_LITE_REGION_STRIDE;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= {C_S_AXI_DATA_WIDTH{1'b0}};
        end else begin
            s_axi_arready <= ~s_axi_arready && s_axi_arvalid;

            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                if (is_region_rd && rd_ridx < NREG) begin
                    case (rd_reg_off)
                        `IOMMU_LITE_R_CTRL:
                            s_axi_rdata <= {25'b0, CID_reg[rd_ridx], P_reg[rd_ridx], V_reg[rd_ridx]};
                        `IOMMU_LITE_R_BASE:  s_axi_rdata <= B_reg[rd_ridx];
                        `IOMMU_LITE_R_LIMIT: s_axi_rdata <= L_reg[rd_ridx];
                        `IOMMU_LITE_R_XLATE: s_axi_rdata <= T_reg[rd_ridx];
                        default: s_axi_rdata <= 32'hDEAD_BEEF;
                    endcase
                end else begin
                    case (rd_off)
                        `IOMMU_LITE_REG_CTRL:       s_axi_rdata <= {31'b0, r_enable};
                        `IOMMU_LITE_REG_STATUS:     s_axi_rdata <= {30'b0, r_irq_en, r_fault_sticky};
                        `IOMMU_LITE_REG_FAULT_ADDR: s_axi_rdata <= r_fault_addr;
                        `IOMMU_LITE_REG_FAULT_CHAN: s_axi_rdata <= {28'b0, r_fault_chan};
                        `IOMMU_LITE_REG_IRQ_EN:     s_axi_rdata <= {31'b0, r_irq_en};
                        default:                    s_axi_rdata <= 32'hDEAD_BEEF;
                    endcase
                end
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
