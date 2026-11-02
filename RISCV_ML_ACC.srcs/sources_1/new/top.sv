`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/29/2026 12:41:36 PM
// Design Name: 
// Module Name: top
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module top (
    input  logic       sysclk,     // 125 MHz board clock (pin H16)
    input  logic [3:0] btn,        // BTN0..BTN3
    output logic [3:0] led         // LD0..LD3
);

    logic clk;                     // 10 MHz core clock
    logic locked;                  // 1 = clk is stable

    // 1) Clock: 125 MHz -> 10 MHz (Clocking Wizard IP, reset input disabled)
    clk_wiz_0 u_clk_wiz (
        .clk_in1  (sysclk),
        .clk_out1 (clk),
        .locked   (locked)
    );

    // 2) Reset: active while BTN0 is pressed or the clock is not yet stable.
    //    Two-flop synchronizer (as in blinky). Starts at 1 so the core is in
    //    reset from the moment the FPGA is configured.
    logic [1:0] rst_sync = 2'b11;
    logic       rst;

    always_ff @(posedge clk) begin
        rst_sync <= {rst_sync[0], btn[0] | ~locked};
    end
    assign rst = rst_sync[1];

    // 3) Buttons: two-flop synchronizer for all four
    logic [3:0] btn_meta, btn_sync;

    always_ff @(posedge clk) begin
        btn_meta <= btn;
        btn_sync <= btn_meta;
    end

    // 4) The core, loaded with the LED program
    core #(.IMEM_FILE("led_demo.mem")) u_core (
        .clk    (clk),
        .rst    (rst),
        .btn    (btn_sync),
        .pc_out (),
        .led    (led)
    );

endmodule