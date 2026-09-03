# IOMMU-Lite — RTL Implementation for Zybo Z7-20 (Zynq-7000)

Verilog implementation of the **IOMMU-Lite** region-based DMA protection
architecture described in *"Securing DMA at Line Rate: A Lightweight
IOMMU-Lite Architecture for AI Edge SoCs"* (R. P. Upadhye, MIT-WPU),
targeting the Digilent **Zybo Z7-20** (XC7Z020-1CLG400C).

All symbol names in the RTL match the document's **Formal Model** exactly:
`A_in`, `A_out`, `B_i`, `L_i`, `T_i`, `C`, `CID_i`, `V_i`, `P_i`, `Match_i`,
`i*` (`i_star`), `Permitted`, `Allow`, `Fault` — see `rtl/iommu_lite_core.v`.

## 1. Architecture

```
                         AXI-Lite (Programming Model)
                                    |
                                    v
   DMA master --A_in, C--> [ iommu_lite_core ] --A_out, Allow/Fault--> DDR
                              region table:
                              B_i, L_i, T_i, CID_i, P_i, V_i  (x8 regions)
```

* **`iommu_lite_core.v`** — combinational engine implementing the formal
  model verbatim: `Match_i`, region-selection `i*` (first-match priority,
  as the document allows), `Permitted`, `A_out = T_i* + (A_in − B_i*)`,
  `Allow`, `Fault`.
* **`iommu_lite_regs.v`** — AXI4-Lite slave implementing the
  **Programming Model** / **Programming Flow**: per-region Input
  Base/Limit, Translated Base, Channel ID, Permissions, Valid bit; plus
  global enable, sticky fault status, fault-address/channel capture, and
  interrupt enable/clear.
* **`iommu_lite_axi_wrapper.v`** — in-line AXI4 (full) data-path block.
  Intercepts `AWADDR`/`ARADDR`, runs them through the core (using
  `AWID`/`ARID` as the DMA **Channel ID `C`**), forwards the translated
  address on `Allow`, and on `Fault` blocks the transaction and returns
  `SLVERR` instead of ever touching memory.
* **`iommu_lite_top.v`** — combines the above into one IP with an
  AXI4-Lite config port, an AXI4 data port, and an `irq` output.
* **`iommu_lite_traffic_gen.v`** — a small software-controlled AXI4
  master used purely as demo stimulus, because the PS7's own GP master
  ports don't let bare-metal code choose the AXI ID (`C`) per transaction.
  It lets you set `A_in`, `C`, and read/write data from software.
* **`iommu_lite_led_ctrl.v`** / **`iommu_lite_demo_top.v`** — wires it
  all together for a live, visual Zybo demo (LEDs + RGB LED5).

## 2. Region table (document's example, reproduced exactly)

| Region ID | Channel ID | Input Base   | Input Limit  | Translated Base | Permissions | Valid |
|-----------|-----------|--------------|--------------|------------------|-------------|-------|
| 0 | 0 | 0x8000_0000 | 0x8000_FFFF | 0x9000_0000 | R/W | 1 |
| 1 | 1 | 0x8100_0000 | 0x8100_7FFF | 0x9100_0000 | R   | 1 |
| 2 | 2 | 0x8200_0000 | 0x8200_FFFF | 0x9200_0000 | W   | 1 |
| 3 | 0 | 0x8300_0000 | 0x8300_3FFF | 0x9300_0000 | R/W | 0 |

This exact table is programmed by both testbenches and by
`sw/iommu_lite_test.c`.

## 3. Register map

### `iommu_lite_top` config port (AXI-Lite, base `IOMMU_BASE`)
| Offset | Name | Description |
|---|---|---|
| 0x00 | CTRL | [0] = global enable |
| 0x04 | STATUS | [0] = sticky Fault, [1] = IRQ enable (readback) |
| 0x08 | FAULT_ADDR | last `A_in` that caused `Fault` |
| 0x0C | FAULT_CHAN | last `C` that caused `Fault` |
| 0x10 | IRQ_EN | [0] = enable fault interrupt |
| 0x14 | IRQ_CLR | write 1 to clear sticky Fault / IRQ |
| 0x40 + i·0x20 + 0x00 | Region *i* CTRL | `{CID_i[3:0], P_i[1:0], V_i}` |
| 0x40 + i·0x20 + 0x04 | Region *i* BASE  | `B_i` |
| 0x40 + i·0x20 + 0x08 | Region *i* LIMIT | `L_i` |
| 0x40 + i·0x20 + 0x0C | Region *i* XLATE | `T_i` |

`P_i` encoding: bit1 = W, bit0 = R (`01`=R, `10`=W, `11`=R/W), matching the
document's "R/W" / "R" / "W" table entries.

### `iommu_lite_traffic_gen` config port (AXI-Lite, base `TG_BASE`)
| Offset | Name | Description |
|---|---|---|
| 0x00 | CTRL | [0]=start, [1]=is_write |
| 0x04 | ADDR | `A_in` to issue |
| 0x08 | CHAN | `C` (drives AWID/ARID) |
| 0x0C | WDATA | write data |
| 0x10 | STATUS | [0]=busy, [1]=done, [3:2]=last resp (00=OKAY, 10=SLVERR/Fault) |
| 0x14 | RDATA | last read data |

## 4. Verified in simulation (Icarus Verilog)

```
cd rtl_project_root/iommu_lite
iverilog -g2005 -I rtl -o core_tb.vvp rtl/iommu_lite_core.v tb/iommu_lite_core_tb.v
vvp core_tb.vvp
# -> 10/10 tests passed (region match, R-only/W-only permission faults,
#    wrong-channel fault, out-of-range fault, disabled-region fault,
#    inclusive upper-limit edge case)

iverilog -g2005 -I rtl -o top_tb.vvp \
    rtl/iommu_lite_core.v rtl/iommu_lite_regs.v rtl/iommu_lite_axi_wrapper.v \
    rtl/iommu_lite_top.v tb/iommu_lite_top_tb.v
vvp top_tb.vvp
# -> Programs the region table over AXI-Lite, drives real AXI4 write/read
#    bursts, confirms translated AWADDR/ARADDR at the memory side, and
#    confirms SLVERR + sticky-fault status on illegal accesses.
```

Both testbenches are included in `tb/` and pass as shown above.

## 5. Building the Zybo Z7-20 bitstream (Vivado 2023.x or later)

1. Create a new RTL project in Vivado targeting board
   **Digilent Zybo Z7-20** (install the Digilent board files if not
   already present).
2. Add all files under `rtl/` (`.v` and `.vh`) as design sources.
3. Add `constraints/zybo_z7_20.xdc` as a constraints source.
4. **Package `iommu_lite_demo_top` as an IP** (Tools → Create and
   Package New IP → Package your current project), so it can be dropped
   into a Block Design. Vivado's IP packager auto-infers the AXI4 /
   AXI4-Lite interfaces from the signal naming convention used
   throughout this RTL (`*_awvalid`, `*_awready`, …) — use "Merge
   changes" then "Infer Interfaces" and name the three interfaces
   `S_AXI_TG`, `S_AXI_IOMMU`, `M_AXI`. Add the IP repo under
   Settings → IP → Repository.
5. Run `source scripts/build_bd.tcl` from the Tcl console. It creates
   the block design: `ZYNQ7 Processing System` (board preset applied) +
   `iommu_lite_demo_top` + two AXI interconnects (GP0 → the two
   AXI-Lite config ports; `M_AXI` → HP0 → DDR) + IRQ wired to
   `IRQ_F2P[0]`, and maps the address ranges used by the software below
   (`0x4000_0000` / `0x4001_0000`).
6. Generate the wrapper, run synthesis/implementation, and generate the
   bitstream (`launch_runs impl_1 -to_step write_bitstream`).
7. Export hardware (**File → Export → Export Hardware**, include
   bitstream) to produce the `.xsa` for Vitis.

## 6. Running the demo

1. In Vitis, create a platform from the exported `.xsa`, then a new
   **Application project** (standalone/"Hello World" template) and
   replace its `main` with `sw/iommu_lite_test.c`.
2. Program the FPGA and run the application over the USB-UART
   (115200 8N1). It:
   - programs the document's example 4-region table over AXI-Lite,
   - enables IOMMU-Lite and the fault interrupt,
   - issues 4 **legal** accesses (matching region, right channel, right
     permission) — expect `OKAY`,
   - issues 5 **illegal** accesses (wrong permission, wrong channel,
     out-of-range address, disabled region) — expect `FAULT`,
   - prints the final sticky `STATUS`, `FAULT_ADDR`, `FAULT_CHAN`.
3. On the board: **LD0** heartbeats, **LD1** shows global enable,
   **LD2** latches on the first fault, **LD3** mirrors the fault
   interrupt, and **RGB LED5** flashes green on each allowed access and
   red on each faulted one — so the region-based enforcement is visible
   live, not just in the UART log.

## 7. File map

```
rtl/iommu_lite_pkg.vh          shared parameters + register-map defines
rtl/iommu_lite_core.v          formal-model translation/permission/fault engine
rtl/iommu_lite_regs.v          AXI-Lite config: region table, status, IRQ
rtl/iommu_lite_axi_wrapper.v   AXI4 in-line address check/translate/block
rtl/iommu_lite_top.v           config + data-path + IRQ, single IP
rtl/iommu_lite_traffic_gen.v   AXI4 master demo stimulus (software-controlled)
rtl/iommu_lite_led_ctrl.v      Zybo LED/RGB status driver
rtl/iommu_lite_demo_top.v      full self-contained PL demo top
tb/iommu_lite_core_tb.v        formal-model unit tests (10/10 passing)
tb/iommu_lite_top_tb.v         AXI-level end-to-end test (passing)
constraints/zybo_z7_20.xdc     LED/switch/button pin constraints
scripts/build_bd.tcl           Vivado block-design scaffolding script
sw/iommu_lite_test.c           baremetal Vitis test application
```

## 8. Notes / scope

* Region count defaults to **8** (`` `IOMMU_LITE_NUM_REGIONS ``, the low
  end of the document's "8 to 32 regions" range) — change one macro in
  `iommu_lite_pkg.vh` to grow it; the core, regfile, and wrapper are all
  parameterized off it.
* Region matching uses **first-match priority** (lowest Region ID wins),
  exactly as the document specifies for the multiple-match case.
* The core is purely combinational (single AXI beat of latency through
  the wrapper's registered handshake), in keeping with the paper's
  "low-latency, RTL-friendly" design goal, as opposed to a multi-cycle
  page-table walk.
* `AWID`/`ARID` is used as the DMA **Channel ID `C`** on the AXI4 data
  path — a standard mapping for per-channel DMA isolation over AXI. The
  bundled `iommu_lite_traffic_gen` exists specifically because the Zynq
  PS7's own GP master ports don't expose per-transaction ID control to
  bare-metal software, so it stands in as a configurable multi-channel
  "DMA" source for the demo. A production system would connect the
  Channel-ID-capable master directly (e.g. Xilinx AXI DMA, which
  supports per-channel AXI ID).
