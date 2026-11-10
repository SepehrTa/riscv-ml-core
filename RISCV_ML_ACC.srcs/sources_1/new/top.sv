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
    input  logic [3:0] btn,        // BTN0..BTN3
    output logic [3:0] led,        // LD0..LD3

    // CHANGED: sysclk removed (the core now runs on the PS clock, FCLK_CLK0).
    // ADDED: the Zynq PS pins (DDR memory and fixed I/O). They go straight to
    // the block design and need no constraints in the XDC.
    inout  wire [14:0] DDR_addr,
    inout  wire [2:0]  DDR_ba,
    inout  wire        DDR_cas_n,
    inout  wire        DDR_ck_n,
    inout  wire        DDR_ck_p,
    inout  wire        DDR_cke,
    inout  wire        DDR_cs_n,
    inout  wire [3:0]  DDR_dm,
    inout  wire [31:0] DDR_dq,
    inout  wire [3:0]  DDR_dqs_n,
    inout  wire [3:0]  DDR_dqs_p,
    inout  wire        DDR_odt,
    inout  wire        DDR_ras_n,
    inout  wire        DDR_reset_n,
    inout  wire        DDR_we_n,
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,
    inout  wire [53:0] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_porb,
    inout  wire        FIXED_IO_ps_srstb
);

    logic clk;                     // CHANGED: 50 MHz core clock, FCLK_CLK0 from the PS
    logic pl_reset;                // ADDED: reset from the PS reset block (active high)
    logic run;                     // ADDED: GPIO channel 1, bit 0: 1 = let the core run

    // ADDED: the two BRAM ports from the ARM side (AXI BRAM Controllers).
    // Note the names: din is the data the controller WRITES into the memory,
    // dout is the data it READS back from the memory.
    logic [11:0] imem_addr;        // byte address inside the 4 KB instruction memory
    logic [31:0] imem_din, imem_dout;
    logic        imem_en;
    logic [3:0]  imem_we;
    logic [15:0] dmem_addr;        // byte address inside the 64 KB data memory
    logic [31:0] dmem_din, dmem_dout;
    logic        dmem_en;
    logic [3:0]  dmem_we;

    // 1) CHANGED: the Zynq block design replaces the Clocking Wizard. It gives
    //    the clock, the reset, the GPIO, and the ARM's port into both memories.
    ps_sys_wrapper u_ps (
        .DDR_addr          (DDR_addr),
        .DDR_ba            (DDR_ba),
        .DDR_cas_n         (DDR_cas_n),
        .DDR_ck_n          (DDR_ck_n),
        .DDR_ck_p          (DDR_ck_p),
        .DDR_cke           (DDR_cke),
        .DDR_cs_n          (DDR_cs_n),
        .DDR_dm            (DDR_dm),
        .DDR_dq            (DDR_dq),
        .DDR_dqs_n         (DDR_dqs_n),
        .DDR_dqs_p         (DDR_dqs_p),
        .DDR_odt           (DDR_odt),
        .DDR_ras_n         (DDR_ras_n),
        .DDR_reset_n       (DDR_reset_n),
        .DDR_we_n          (DDR_we_n),
        .FIXED_IO_ddr_vrn  (FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp  (FIXED_IO_ddr_vrp),
        .FIXED_IO_mio      (FIXED_IO_mio),
        .FIXED_IO_ps_clk   (FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb  (FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb (FIXED_IO_ps_srstb),

        .IMEM_addr         (imem_addr),
        .IMEM_clk          (),                 // same clock as fclk, not needed
        .IMEM_din          (imem_din),
        .IMEM_dout         (imem_dout),
        .IMEM_en           (imem_en),
        .IMEM_rst          (),                 // not needed
        .IMEM_we           (imem_we),

        .DMEM_addr         (dmem_addr),
        .DMEM_clk          (),
        .DMEM_din          (dmem_din),
        .DMEM_dout         (dmem_dout),
        .DMEM_en           (dmem_en),
        .DMEM_rst          (),
        .DMEM_we           (dmem_we),

        .fclk              (clk),
        .pl_reset          (pl_reset),
        .gpio_run_tri_o    (run),
        .gpio_status_tri_i (led)               // the ARM can read the LEDs
    );

    // 2) Reset: active while BTN0 is pressed, while the PS holds the fabric in
    //    reset, or while the ARM has not set "run". Two-flop synchronizer (as in
    //    blinky). Starts at 1 so the core is in reset from the moment the FPGA
    //    is configured.
    //    CHANGED: pl_reset and ~run replace ~locked.
    logic [1:0] rst_sync = 2'b11;
    logic       rst;

    always_ff @(posedge clk) begin
        rst_sync <= {rst_sync[0], btn[0] | pl_reset | ~run};
    end
    assign rst = rst_sync[1];

    // 3) Buttons: two-flop synchronizer for all four
    logic [3:0] btn_meta, btn_sync;

    always_ff @(posedge clk) begin
        btn_meta <= btn;
        btn_sync <= btn_meta;
    end

    // 4) The core. The .mem files are only its starting contents; the ARM can
    //    load any other program and data through port B while run = 0.
    core_pipe #(
    .IMEM_FILE("mnist_board_imem.mem"),
    .DMEM_FILE("mnist_board_dmem.mem"),
    .IMEM_DEPTH(1024),
    .DMEM_DEPTH(16384)
    ) 
    u_core (
        .clk    (clk),
        .rst    (rst),
        .btn    (btn_sync),
        .pc_out (),
        .led    (led),
        // CHANGED: port B of both memories now goes to the ARM's BRAM controllers
        .imem_b_en(imem_en), .imem_b_we(imem_we), .imem_b_addr({20'b0, imem_addr}),
        .imem_b_wdata(imem_din), .imem_b_rdata(imem_dout),
        .dmem_b_en(dmem_en), .dmem_b_we(dmem_we), .dmem_b_addr({16'b0, dmem_addr}),
        .dmem_b_wdata(dmem_din), .dmem_b_rdata(dmem_dout)
    );

endmodule