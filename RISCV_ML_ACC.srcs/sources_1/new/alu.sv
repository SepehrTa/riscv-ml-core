module alu
    import riscv_pkg::*;     
(
    input  alu_op_t     alu_op,
    input  logic [31:0] inp1,
    input  logic [31:0] inp2,
    output logic [31:0] out
);

always_comb begin

    case (alu_op)                
        ALU_ADD     :   out = inp1 + inp2;        
        ALU_SUB     :   out = inp1 - inp2;
        ALU_SLL     :   out = inp1 << inp2[4:0];       
        ALU_SRL     :   out = inp1 >> inp2[4:0]; 
        ALU_SRA     :   out = $signed(inp1) >>> inp2[4:0];      
        ALU_SLT     :   out = ($signed(inp1) < $signed(inp2)) ? 32'd1: 32'd0 ;     
        ALU_SLTU    :   out = inp1 < inp2 ? 32'd1: 32'd0 ;     
        ALU_XOR     :   out = inp1 ^ inp2;
        ALU_OR      :   out = inp1 | inp2;  
        ALU_AND     :   out = inp1 & inp2;
        default     :   out = 32'd0;
    endcase
    end;
endmodule