/* ==========================================================================
 * iommu_lite_test.c   (REVISION 2)
 *
 * Baremetal test application for the IOMMU-Lite demo on the Digilent
 * Zybo Z7-20 (Zynq-7000). Build in Vitis as a standalone application on
 * ps7_cortexa9_0 against the platform generated from your .xsa.
 *
 * ---- WHAT CHANGED FROM REVISION 1 ------------------------------------
 * 1) ADDRESSES NOW LIVE IN REAL DDR.
 *    Rev 1 used the paper's illustrative table (0x8000_0000 ->
 *    0x9000_0000). The Zybo Z7-20 has 1 GB of DDR mapped at roughly
 *    0x0000_0000-0x3FFF_FFFF, so 0x8xxx/0x9xxx decode to NOTHING. Every
 *    "allowed" transaction was forwarded correctly by IOMMU-Lite and then
 *    rejected by the interconnect with DECERR, which this test could not
 *    distinguish from an IOMMU-Lite fault. All regions now sit inside DDR.
 *
 * 2) REGISTER READBACK IS ACTUALLY CALLED.
 *    dump_region() / dump_globals() run before any traffic, so if a
 *    result looks wrong you can see immediately whether the region table
 *    and the enable bit really landed in hardware.
 *
 * 3) END-TO-END TRANSLATION PROOF.
 *    After writing through IOMMU-Lite to A_in, the CPU reads the
 *    TRANSLATED address directly and confirms the data physically landed
 *    there. That is the real demonstration that A_out = T_i + (A_in - B_i)
 *    is happening in hardware, not just that a transaction was allowed.
 * ==========================================================================
 */

#include <stdio.h>
#include "xil_io.h"
#include "xil_cache.h"
#include "sleep.h"

/* ---- Address map: MUST match the Vivado Address Editor ------------------ */
#define TG_BASE     0x40000000u  /* iommu_lite_traffic_gen  (tg_axi/reg0) */
#define IOMMU_BASE  0x40001000u  /* iommu_lite_top config   (il_axi/reg0)
                                  * MUST be 4KB-aligned: il_axi_*addr is a
                                  * 12-bit port, so a non-4KB-aligned segment
                                  * leaves high address bits set and silently
                                  * aliases global regs onto the region table. */

/* ---- traffic_gen register offsets --------------------------------------- */
#define TG_CTRL     0x00  /* [0]=start [1]=is_write */
#define TG_ADDR     0x04  /* A_in */
#define TG_CHAN     0x08  /* C (channel ID -> AWID/ARID) */
#define TG_WDATA    0x0C
#define TG_STATUS   0x10  /* [0]=busy [1]=done [3:2]=last resp */
#define TG_RDATA    0x14

/* ---- iommu_lite_top config offsets, per iommu_lite_pkg.vh --------------- */
#define IL_REG_CTRL        0x00
#define IL_REG_STATUS      0x04
#define IL_REG_FAULT_ADDR  0x08
#define IL_REG_FAULT_CHAN  0x0C
#define IL_REG_IRQ_EN      0x10
#define IL_REG_IRQ_CLR     0x14

#define IL_REGION_BASE     0x40
#define IL_REGION_STRIDE   0x20
#define IL_R_CTRL          0x00  /* {CID_i[3:0], P_i[1:0], V_i} */
#define IL_R_BASE          0x04  /* B_i */
#define IL_R_LIMIT         0x08  /* L_i */
#define IL_R_XLATE         0x0C  /* T_i */

#define PERM_R   0x1
#define PERM_W   0x2
#define PERM_RW  0x3

/* ---- Region layout, entirely inside the Zybo Z7-20's 1 GB DDR ----------
 * Same STRUCTURE as the paper's example table (one R/W region, one
 * read-only, one write-only, one disabled), just relocated into memory
 * that physically exists on this board.
 *
 *  Region  C   Input range                Translated base   Perms  Valid
 *   0      0   0x1000_0000-0x1000_FFFF    0x1800_0000       R/W    1
 *   1      1   0x1010_0000-0x1010_7FFF    0x1810_0000       R      1
 *   2      2   0x1020_0000-0x1020_FFFF    0x1820_0000       W      1
 *   3      0   0x1030_0000-0x1030_3FFF    0x1830_0000       R/W    0
 */
#define R0_BASE 0x10000000u
#define R0_LIM  0x1000FFFFu
#define R0_XLT  0x18000000u
#define R1_BASE 0x10100000u
#define R1_LIM  0x10107FFFu
#define R1_XLT  0x18100000u
#define R2_BASE 0x10200000u
#define R2_LIM  0x1020FFFFu
#define R2_XLT  0x18200000u
#define R3_BASE 0x10300000u
#define R3_LIM  0x10303FFFu
#define R3_XLT  0x18300000u

static int pass_count = 0, fail_count = 0;

static inline void reg_w(u32 base, u32 off, u32 val) { Xil_Out32(base + off, val); }
static inline u32  reg_r(u32 base, u32 off)          { return Xil_In32(base + off); }

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

/* Read the region table back out of hardware so a wrong result can be traced
 * to "programming never landed" vs "translation logic misbehaved". */
static void dump_region(int idx)
{
    u32 off   = IL_REGION_BASE + idx * IL_REGION_STRIDE;
    u32 ctrl  = reg_r(IOMMU_BASE, off + IL_R_CTRL);
    u32 base  = reg_r(IOMMU_BASE, off + IL_R_BASE);
    u32 limit = reg_r(IOMMU_BASE, off + IL_R_LIMIT);
    u32 xlate = reg_r(IOMMU_BASE, off + IL_R_XLATE);
    printf("  R%d: V=%u P=%u CID=%u  B_i=0x%08X  L_i=0x%08X  T_i=0x%08X\r\n",
           idx,
           (unsigned)(ctrl & 0x1),
           (unsigned)((ctrl >> 1) & 0x3),
           (unsigned)((ctrl >> 3) & 0xF),
           (unsigned)base, (unsigned)limit, (unsigned)xlate);
}

static void dump_globals(const char *when)
{
    printf("  [%s] CTRL=0x%08X  STATUS=0x%08X  IRQ_EN=0x%08X  FAULT_ADDR=0x%08X  FAULT_CHAN=%u\r\n",
           when,
           (unsigned)reg_r(IOMMU_BASE, IL_REG_CTRL),
           (unsigned)reg_r(IOMMU_BASE, IL_REG_STATUS),
           (unsigned)reg_r(IOMMU_BASE, IL_REG_IRQ_EN),
           (unsigned)reg_r(IOMMU_BASE, IL_REG_FAULT_ADDR),
           (unsigned)reg_r(IOMMU_BASE, IL_REG_FAULT_CHAN));
}

/* Issue one transaction through the traffic generator.
 * Returns 1 = OKAY, 0 = SLVERR/DECERR (blocked), -1 = timeout/hang. */
static int tg_issue(u32 a_in, u8 chan, int is_write, u32 wdata, u32 *rdata_out)
{
    u32 status;
    int timeout = 200000;

    reg_w(TG_BASE, TG_ADDR, a_in);
    reg_w(TG_BASE, TG_CHAN, chan);
    if (is_write) reg_w(TG_BASE, TG_WDATA, wdata);
    reg_w(TG_BASE, TG_CTRL, (is_write ? 0x2 : 0x0) | 0x1);

    do {
        status = reg_r(TG_BASE, TG_STATUS);
        timeout--;
    } while (!(status & 0x2) && timeout > 0);

    if (timeout <= 0) return -1;
    if (rdata_out) *rdata_out = reg_r(TG_BASE, TG_RDATA);
    return (((status >> 2) & 0x3) == 0) ? 1 : 0;
}

static void expect(const char *label, u32 a_in, u8 chan, int is_write,
                   u32 wdata, int want_ok)
{
    u32 rd = 0;
    int r = tg_issue(a_in, chan, is_write, wdata, &rd);
    const char *got = (r == 1) ? "ALLOW" : (r == 0) ? "FAULT" : "TIMEOUT";
    const char *exp = want_ok ? "ALLOW" : "FAULT";

    if (r == want_ok) { pass_count++; printf("  [ OK ] "); }
    else              { fail_count++; printf("  [FAIL] "); }

    printf("%-42s A_in=0x%08X C=%u %s -> %s (expected %s)\r\n",
           label, (unsigned)a_in, chan, is_write ? "WR" : "RD", got, exp);
}

int main(void)
{
    u32 v;

    printf("\r\n=========================================\r\n");
    printf("   IOMMU-Lite Demo  (Zybo Z7-20)  rev2\r\n");
    printf("=========================================\r\n");

    printf("\r\n[1] Programming region table...\r\n");
    program_region(0, R0_BASE, R0_LIM, R0_XLT, 0, PERM_RW, 1);
    program_region(1, R1_BASE, R1_LIM, R1_XLT, 1, PERM_R,  1);
    program_region(2, R2_BASE, R2_LIM, R2_XLT, 2, PERM_W,  1);
    program_region(3, R3_BASE, R3_LIM, R3_XLT, 0, PERM_RW, 0);

    printf("\r\n[2] Region table readback (proves AXI-Lite writes landed):\r\n");
    dump_region(0); dump_region(1); dump_region(2); dump_region(3);

    dump_globals("before enable");

    printf("\r\n[3] Enabling IOMMU-Lite + fault IRQ...\r\n");
    reg_w(IOMMU_BASE, IL_REG_IRQ_EN, 0x1);
    reg_w(IOMMU_BASE, IL_REG_CTRL,   0x1);

    dump_globals("after enable");

    v = reg_r(IOMMU_BASE, IL_REG_CTRL);
    if (v & 0x1) {
        printf("  -> enable bit CONFIRMED set. Enforcement is active.\r\n");
    } else {
        printf("  -> *** WARNING: CTRL reads back 0x%08X, enable did NOT take. ***\r\n",
               (unsigned)v);
        printf("  -> All following results will reflect BYPASS mode, not enforcement.\r\n");
    }

    printf("\r\n[4] Legal accesses (expect ALLOW):\r\n");
    expect("R0 write (R/W region, C=0)",       R0_BASE + 0x10, 0, 1, 0xA5A51234, 1);
    expect("R0 read  (R/W region, C=0)",       R0_BASE + 0x20, 0, 0, 0,          1);
    expect("R1 read  (read-only region, C=1)", R1_BASE + 0x04, 1, 0, 0,          1);
    expect("R2 write (write-only region, C=2)",R2_BASE + 0x00, 2, 1, 0xDEADBEEF, 1);

    printf("\r\n[5] Illegal accesses (expect FAULT):\r\n");
    expect("R1 write -> region is READ-ONLY",  R1_BASE + 0x04, 1, 1, 0x11111111, 0);
    expect("R2 read  -> region is WRITE-ONLY", R2_BASE + 0x00, 2, 0, 0,          0);
    expect("wrong channel ID (C=5)",           R0_BASE + 0x10, 5, 0, 0,          0);
    expect("address outside every region",     0x20000000u,    0, 0, 0,          0);
    expect("region 3 has Valid=0",             R3_BASE + 0x10, 0, 0, 0,          0);

    printf("\r\n[6] End-to-end translation proof:\r\n");
    printf("  Writing 0xCAFEF00D via IOMMU-Lite to A_in=0x%08X (C=0)\r\n",
           (unsigned)(R0_BASE + 0x40));
    if (tg_issue(R0_BASE + 0x40, 0, 1, 0xCAFEF00D, NULL) == 1) {
        /* The PL wrote straight to DDR behind the CPU's back, so drop any
         * stale cache line before the CPU reads that physical location. */
        Xil_DCacheInvalidateRange((INTPTR)(R0_XLT + 0x40), 32);
        v = Xil_In32(R0_XLT + 0x40);
        printf("  CPU reads TRANSLATED addr 0x%08X -> 0x%08X\r\n",
               (unsigned)(R0_XLT + 0x40), (unsigned)v);
        if (v == 0xCAFEF00D) {
            pass_count++;
            printf("  [ OK ] A_out = T_i + (A_in - B_i) verified in hardware.\r\n");
        } else {
            fail_count++;
            printf("  [FAIL] data did not appear at the translated address.\r\n");
        }
    } else {
        fail_count++;
        printf("  [FAIL] the write itself was blocked; cannot check translation.\r\n");
    }

    printf("\r\n[7] Fault status:\r\n");
    dump_globals("final");
    v = reg_r(IOMMU_BASE, IL_REG_STATUS);
    if (v & 0x1) {
        pass_count++;
        printf("  [ OK ] sticky Fault bit set, last fault A_in=0x%08X C=%u\r\n",
               (unsigned)reg_r(IOMMU_BASE, IL_REG_FAULT_ADDR),
               (unsigned)reg_r(IOMMU_BASE, IL_REG_FAULT_CHAN));
    } else {
        fail_count++;
        printf("  [FAIL] sticky Fault bit NOT set despite blocked accesses.\r\n");
    }
    reg_w(IOMMU_BASE, IL_REG_IRQ_CLR, 0x1);
    printf("  after IRQ_CLR: STATUS=0x%08X\r\n",
           (unsigned)reg_r(IOMMU_BASE, IL_REG_STATUS));

    printf("\r\n=========================================\r\n");
    printf("  RESULT: %d passed, %d failed\r\n", pass_count, fail_count);
    printf("=========================================\r\n");
    printf("LD0 blinks (heartbeat). RGB LD5: green=Allow, red=Fault.\r\n");
    return 0;
}
