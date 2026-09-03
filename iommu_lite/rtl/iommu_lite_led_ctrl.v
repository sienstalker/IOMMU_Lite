`timescale 1ns/1ps
//==========================================================================
// iommu_lite_led_ctrl
// Drives the Zybo Z7-20 LEDs directly from IOMMU-Lite status so the
// board gives immediate visual feedback during the demo:
//   led[0] = heartbeat (aclk divided down, proves PL is alive)
//   led[1] = iommu_enable
//   led[2] = sticky fault (STATUS[0])
//   led[3] = irq
//   led5_g = pulses green on an Allow (translated request accepted)
//   led5_r = pulses red on a Fault (blocked request)
//==========================================================================
module iommu_lite_led_ctrl (
    input  wire aclk,
    input  wire aresetn,
    input  wire iommu_enable,
    input  wire fault_sticky,
    input  wire irq,
    input  wire allow_pulse,   // 1-cycle pulse: last data-path request was Allowed
    input  wire fault_pulse,   // 1-cycle pulse: last data-path request Faulted

    output wire [3:0] led,
    output reg         led5_r,
    output reg         led5_g,
    output wire         led5_b
);

    reg [25:0] heartbeat_cnt;
    always @(posedge aclk) begin
        if (!aresetn) heartbeat_cnt <= 0;
        else heartbeat_cnt <= heartbeat_cnt + 1'b1;
    end

    assign led[0] = heartbeat_cnt[25];
    assign led[1] = iommu_enable;
    assign led[2] = fault_sticky;
    assign led[3] = irq;
    assign led5_b = 1'b0;

    // Stretch the allow/fault pulses so they're visible to the eye (~0.25s @100MHz)
    localparam STRETCH = 24_999_999;
    reg [24:0] g_cnt, r_cnt;

    always @(posedge aclk) begin
        if (!aresetn) begin
            g_cnt <= 0; led5_g <= 0;
        end else if (allow_pulse) begin
            g_cnt <= STRETCH[24:0]; led5_g <= 1'b1;
        end else if (g_cnt != 0) begin
            g_cnt <= g_cnt - 1'b1;
        end else begin
            led5_g <= 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            r_cnt <= 0; led5_r <= 0;
        end else if (fault_pulse) begin
            r_cnt <= STRETCH[24:0]; led5_r <= 1'b1;
        end else if (r_cnt != 0) begin
            r_cnt <= r_cnt - 1'b1;
        end else begin
            led5_r <= 1'b0;
        end
    end

endmodule
