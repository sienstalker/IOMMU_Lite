/* ==========================================================================
 * iommu_lite_test_2.c
 *
 * Baremetal test application for the IOMMU-Lite demo on the Digilent
 * Zybo Z7-20 (Zynq-7000). Build as a "Hello World" / standalone
 * application in Xilinx Vitis targeting the PS7 Cortex-A9, against the
 * platform generated from iommu_lite_bd_wrapper.bit / .xsa.
 *
 * It reproduces the document's exact example four-entry region table,
 * programs it over AXI-Lite, then drives the on-chip traffic generator
 * to issue legal and illegal DMA-style accesses and prints the results
 * (Allow / Fault, translated address) to the UART console.
 * ==========================================================================
 */

#include <stdio.h>
#include "xil_io.h"
#include "sleep.h"

/* ---- Address map: must match the Vivado Address Editor assignment ------- */
#define TG_BASE     0x40000000u  /* iommu_lite_traffic_gen AXI-Lite (tg_axi/reg0) */
#define IOMMU_BASE  0x40000800u  /* iommu_lite_top S_AXI_LITE config (il_axi/reg0) */

/* ---- traffic_gen register offsets ----------------------------------------- */
#define TG_CTRL     0x00  /* [0]=start [1]=is_write */
#define TG_ADDR     0x04  /* A_in */
#define TG_CHAN     0x08  /* C (channel ID) */
#define TG_WDATA    0x0C
#define TG_STATUS   0x10  /* [0]=busy [1]=done [3:2]=last resp */
#define TG_RDATA    0x14

/* ---- iommu_lite_top (config) register offsets, per iommu_lite_pkg.vh ----- */
#define IL_REG_CTRL        0x00
#define IL_REG_STATUS      0x04
#define IL_REG_FAULT_ADDR  0x08
#define IL_REG_FAULT_CHAN  0x0C
#define IL_REG_IRQ_EN      0x10
#define IL_REG_IRQ_CLR     0x14

#define IL_REGION_BASE     0x40
#define IL_REGION_STRIDE   0x20
#define IL_R_CTRL          0x00  /* {..., CID_i[3:0], P_i[1:0], V_i} */
#define IL_R_BASE          0x04  /* B_i */
#define IL_R_LIMIT         0x08  /* L_i */
#define IL_R_XLATE         0x0C  /* T_i */

#define PERM_R   0x1
#define PERM_W   0x2
#define PERM_RW  0x3

static inline void reg_w(u32 base, u32 off, u32 val) { Xil_Out32(base + off, val); }
static inline u32  reg_r(u32 base, u32 off)           { return Xil_In32(base + off); }

static void program_region(int idx, u32 base_addr, u32 limit_addr, u32 xlate_addr,
                            u8 chan_id, u8 perms, u8 valid)
{
    u32 off = IL_REGION_BASE + idx * IL_REGION_STRIDE;
    reg_w(IOMMU_BASE, off + IL_R_BASE,  base_addr);
    reg_w(IOMMU_BASE, off + IL_R_LIMIT, limit_addr);
    reg_w(IOMMU_BASE, off + IL_R_XLATE, xlate_addr);
    reg_w(IOMMU_BASE, off + IL_R_CTRL,
          ((u32)(chan_id & 0xF) << 3) | ((u32)(perms & 0x3) << 1) | (valid & 0x1));
}

/* DIAGNOSTIC: read back exactly what landed in the region table over AXI-Lite,
 * so we can tell a programming/address-decode problem apart from a translation
 * logic problem before looking at any live traffic results. */
static void dump_region(int idx)
{
    u32 off   = IL_REGION_BASE + idx * IL_REGION_STRIDE;
    u32 ctrl  = reg_r(IOMMU_BASE, off + IL_R_CTRL);
    u32 base  = reg_r(IOMMU_BASE, off + IL_R_BASE);
    u32 limit = reg_r(IOMMU_BASE, off + IL_R_LIMIT);
    u32 xlate = reg_r(IOMMU_BASE, off + IL_R_XLATE);
    printf("  Region %d: CTRL=0x%02lx (V=%lu P=%lu CID=%lu)  BASE=0x%08lx  LIMIT=0x%08lx  XLATE=0x%08lx\r\n",
           idx, (unsigned long)ctrl,
           (unsigned long)(ctrl & 0x1), (unsigned long)((ctrl >> 1) & 0x3), (unsigned long)((ctrl >> 3) & 0xF),
           (unsigned long)base, (unsigned long)limit, (unsigned long)xlate);
}

/* Issue one transaction through the traffic generator and wait for completion.
 * Returns 1 on OKAY, 0 on SLVERR (i.e. IOMMU-Lite Fault). */
static int tg_issue(u32 a_in, u8 chan, int is_write, u32 wdata, u32 *rdata_out)
{
    reg_w(TG_BASE, TG_ADDR, a_in);
    reg_w(TG_BASE, TG_CHAN, chan);
    if (is_write) reg_w(TG_BASE, TG_WDATA, wdata);
    reg_w(TG_BASE, TG_CTRL, (is_write ? 0x2 : 0x0) | 0x1); /* start (+is_write) */

    u32 status;
    int timeout = 100000;
    do {
        status = reg_r(TG_BASE, TG_STATUS);
        timeout--;
    } while (!(status & 0x2) && timeout > 0); /* wait for done */

    if (timeout <= 0) {
        printf("  [TIMEOUT] A_in=0x%08lx C=%d wr=%d\r\n", (unsigned long)a_in, chan, is_write);
        return -1;
    }

    int resp = (status >> 2) & 0x3;   /* 0b00 = OKAY, 0b10 = SLVERR */
    if (rdata_out) *rdata_out = reg_r(TG_BASE, TG_RDATA);
    return (resp == 0);
}

int main()
{
    printf("\r\n=== IOMMU-Lite Demo (Zybo Z7-20) ===\r\n");
    printf("Programming region table (document example, Section 'Region Table'):\r\n");

    /* Region 0: Channel 0, 0x8000_0000-0x8000_FFFF -> 0x9000_0000, R/W, Valid */
    program_region(0, 0x80000000, 0x8000FFFF, 0x90000000, 0, PERM_RW, 1);
    /* Region 1: Channel 1, 0x8100_0000-0x8100_7FFF -> 0x9100_0000, R,   Valid */
    program_region(1, 0x81000000, 0x81007FFF, 0x91000000, 1, PERM_R,  1);
    /* Region 2: Channel 2, 0x8200_0000-0x8200_FFFF -> 0x9200_0000, W,   Valid */
    program_region(2, 0x82000000, 0x8200FFFF, 0x92000000, 2, PERM_W,  1);
    /* Region 3: Channel 0, 0x8300_0000-0x8300_3FFF -> 0x9300_0000, R/W, INVALID */
    program_region(3, 0x83000000, 0x83003FFF, 0x93000000, 0, PERM_RW, 0);

    /* Enable IOMMU-Lite enforcement + fault interrupt */
    reg_w(IOMMU_BASE, IL_REG_IRQ_EN, 0x1);
    reg_w(IOMMU_BASE, IL_REG_CTRL, 0x1);

    printf("\r\n-- Legal accesses (expect OKAY / Allow) --\r\n");
    u32 rdata;
    printf("R0 write A_in=0x80000010 C=0: %s\r\n",
           tg_issue(0x80000010, 0, 1, 0xAAAA5555, NULL) ? "OKAY" : "FAULT");
    printf("R0 read  A_in=0x80000020 C=0: %s\r\n",
           tg_issue(0x80000020, 0, 0, 0, &rdata) ? "OKAY" : "FAULT");
    printf("R1 read  A_in=0x81000004 C=1: %s\r\n",
           tg_issue(0x81000004, 1, 0, 0, &rdata) ? "OKAY" : "FAULT");
    printf("R2 write A_in=0x82000000 C=2: %s\r\n",
           tg_issue(0x82000000, 2, 1, 0xDEADBEEF, NULL) ? "OKAY" : "FAULT");

    printf("\r\n-- Illegal accesses (expect FAULT / SLVERR) --\r\n");
    printf("R1 write A_in=0x81000004 C=1 (read-only region): %s\r\n",
           tg_issue(0x81000004, 1, 1, 0x11111111, NULL) ? "OKAY" : "FAULT");
    printf("R2 read  A_in=0x82000000 C=2 (write-only region): %s\r\n",
           tg_issue(0x82000000, 2, 0, 0, &rdata) ? "OKAY" : "FAULT");
    printf("Wrong channel A_in=0x80000010 C=5: %s\r\n",
           tg_issue(0x80000010, 5, 0, 0, &rdata) ? "OKAY" : "FAULT");
    printf("Out-of-range A_in=0x70000000 C=0: %s\r\n",
           tg_issue(0x70000000, 0, 0, 0, &rdata) ? "OKAY" : "FAULT");
    printf("Disabled region A_in=0x83000010 C=0 (Valid=0): %s\r\n",
           tg_issue(0x83000010, 0, 0, 0, &rdata) ? "OKAY" : "FAULT");

    u32 status = reg_r(IOMMU_BASE, IL_REG_STATUS);
    u32 fault_addr = reg_r(IOMMU_BASE, IL_REG_FAULT_ADDR);
    u32 fault_chan = reg_r(IOMMU_BASE, IL_REG_FAULT_CHAN);
    printf("\r\nSTATUS=0x%08lx (bit0=sticky Fault) last fault A_in=0x%08lx C=%lu\r\n",
           (unsigned long)status, (unsigned long)fault_addr, (unsigned long)fault_chan);

    reg_w(IOMMU_BASE, IL_REG_IRQ_CLR, 0x1); /* clear sticky fault / IRQ */

    printf("\r\nDone. LD2 (RGB) flashes green on Allow, red on Fault; LED2 shows sticky fault.\r\n");
    return 0;
}
