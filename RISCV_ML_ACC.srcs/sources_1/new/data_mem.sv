`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/22/2026 06:40:29 PM
// Design Name: 
// Module Name: data_mem
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


module data_mem #(
    parameter int DEPTH     = 1024,
    parameter     INIT_FILE = "",
    parameter bit SYNC_READ = 0
) (
    input  logic        clk,
    input  logic        en,       // read enable, used only when SYNC_READ = 1
    input  logic        we,       // write enable (mem_write from the decoder)
    input  logic [31:0] addr,     // byte address (from the ALU)
    input  logic [31:0] wdata,    // data to store (value of rs2)
    input  logic [2:0]  funct3,   // size and signed/unsigned
    output logic [31:0] rdata     // loaded value, extended to 32 bits
);

    localparam int AW = $clog2(DEPTH);

    logic [31:0] mem [DEPTH];

    logic [AW-1:0] index;         // which word
    logic [1:0]    offset;        // which byte inside the word
    assign index  = addr[AW+1:2];
    assign offset = addr[1:0];

    initial begin
        for (int i = 0; i < DEPTH; i++)
            mem[i] = 32'h0000_0000;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // ------------------------------------------------------------------
    // STORE: decide which bytes to write (byte enables) and move the data
    // into the right byte positions ("lanes").
    // ------------------------------------------------------------------
    logic [3:0]  byte_en;         // bit i = 1: write byte i of the word
    logic [31:0] wdata_lanes;     // store data placed in the right lanes

    always_comb begin
        byte_en     = 4'b0000;
        wdata_lanes = wdata;
        case (funct3[1:0])
            2'b00: begin                              // sb: one byte
                byte_en     = 4'b0001 << offset;       // 0001, 0010, 0100 or 1000
                wdata_lanes = {4{wdata[7:0]}};         // the byte copied to all 4 lanes
            end
            2'b01: begin                              // sh: two bytes
                byte_en     = offset[1] ? 4'b1100 : 4'b0011;
                wdata_lanes = {2{wdata[15:0]}};        // the half copied to both halves
            end
            default: begin                            // sw: all four bytes
                byte_en     = 4'b1111;
                wdata_lanes = wdata;
            end
        endcase
    end

    // Write only the enabled bytes; the other bytes of the word keep their value.
    // (This byte-enable style is what lets Vivado use block RAM byte-writes.)
    always_ff @(posedge clk) begin
        if (we) begin
            for (int i = 0; i < 4; i++) begin
                if (byte_en[i])
                    mem[index][8*i +: 8] <= wdata_lanes[8*i +: 8];
            end
        end
    end

    // ------------------------------------------------------------------
    // LOAD: read the whole word, then pick the byte/half and extend it.
    // ------------------------------------------------------------------
    logic [31:0] word;            // the raw 32-bit word read from memory
    logic [2:0]  ld_funct3;       // funct3 and offset that belong to that word
    logic [1:0]  ld_offset;

    generate
        if (SYNC_READ) begin : g_sync_read
            // Data arrives one clock later, so funct3 and offset are delayed
            // by one clock too, to stay matched with their word.
            always_ff @(posedge clk) begin
                if (en) begin
                    word      <= mem[index];
                    ld_funct3 <= funct3;
                    ld_offset <= offset;
                end
            end
        end else begin : g_async_read
            assign word      = mem[index];
            assign ld_funct3 = funct3;
            assign ld_offset = offset;
        end
    endgenerate

    logic [7:0]  ld_byte;
    logic [15:0] ld_half;
    assign ld_byte = word[8*ld_offset +: 8];          // byte 0..3
    assign ld_half = word[16*ld_offset[1] +: 16];     // low or high half

    always_comb begin
        case (ld_funct3)
            3'b000:  rdata = {{24{ld_byte[7]}},  ld_byte};   // lb:  sign-extend
            3'b001:  rdata = {{16{ld_half[15]}}, ld_half};   // lh:  sign-extend
            3'b010:  rdata = word;                           // lw
            3'b100:  rdata = {24'b0, ld_byte};               // lbu: zero-fill
            3'b101:  rdata = {16'b0, ld_half};               // lhu: zero-fill
            default: rdata = word;
        endcase
    end

endmodule