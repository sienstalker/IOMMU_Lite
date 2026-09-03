//==========================================================================
// iommu_lite_pkg.vh
// Shared parameters for the IOMMU-Lite region-based DMA protection engine.
// Symbol names follow "Securing DMA at Line Rate: A Lightweight IOMMU-Lite
// Architecture for AI Edge SoCs" (R. P. Upadhye, MIT-WPU) exactly:
//
//   A_in   = input address from DMA
//   A_out  = translated output address
//   B_i    = base address of region i           (Input Base Address)
//   L_i    = limit address of region i           (Input Limit Address)
//   T_i    = translated base address of region i (Translated Base Address)
//   C      = DMA channel ID of the incoming request
//   CID_i  = channel ID of region i              (Channel ID)
//   V_i    = valid bit of region i               (Valid)
//   P_i    = permissions of region i             (Permissions, R/W)
//   Match_i, i*, Permitted, Allow, Fault as defined in the formal model.
//==========================================================================
`ifndef IOMMU_LITE_PKG_VH
`define IOMMU_LITE_PKG_VH

// ---- Region table sizing -------------------------------------------------
`define IOMMU_LITE_NUM_REGIONS   8   // 8..32 per document ("Region Table")
`define IOMMU_LITE_RIDX_W        3   // ceil(log2(NUM_REGIONS))
`define IOMMU_LITE_ADDR_W        32  // A_in / A_out / B_i / L_i / T_i width
`define IOMMU_LITE_CHAN_W        4   // width of C / CID_i (up to 16 channels)

// ---- Permissions encoding P_i / requested access -------------------------
// bit1 = W (write allowed), bit0 = R (read allowed)  -> matches "R/W" table
`define IOMMU_LITE_PERM_R        2'b01
`define IOMMU_LITE_PERM_W        2'b10
`define IOMMU_LITE_PERM_RW       2'b11

// ---- AXI-Lite configuration register map (byte offsets) ------------------
// Global registers
`define IOMMU_LITE_REG_CTRL        8'h00  // [0]=enable
`define IOMMU_LITE_REG_STATUS      8'h04  // [0]=Fault (sticky), [1]=IRQ enable
`define IOMMU_LITE_REG_FAULT_ADDR  8'h08  // last A_in that caused Fault
`define IOMMU_LITE_REG_FAULT_CHAN  8'h0C  // last C that caused Fault
`define IOMMU_LITE_REG_IRQ_EN      8'h10  // [0]=enable fault interrupt
`define IOMMU_LITE_REG_IRQ_CLR     8'h14  // write 1 to clear Fault/IRQ

// Per-region table base + stride (region i occupies REGION_BASE + i*REGION_STRIDE)
`define IOMMU_LITE_REGION_BASE     8'h40
`define IOMMU_LITE_REGION_STRIDE   8'h20
// Offsets within a region block:
`define IOMMU_LITE_R_CTRL   8'h00  // {20'b0, CID_i[3:0], P_i[1:0], V_i}
`define IOMMU_LITE_R_BASE   8'h04  // B_i
`define IOMMU_LITE_R_LIMIT  8'h08  // L_i
`define IOMMU_LITE_R_XLATE  8'h0C  // T_i

`endif
