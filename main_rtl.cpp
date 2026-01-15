#include "Vocaml4142_vm_rtl.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
typedef enum
#include "state_rtl_complete.h"

#include <fstream>
#include <iostream>

// ------------------------------------------------------------
// Bytecode ROM (owned by C++)
// ------------------------------------------------------------
uint32_t code_rom[1 << 20];

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

extern "C"
{
  int caml_bytecode(char *byte_name);
  char *opname(int ix);
  };

const char *statenam(int state)
{
  switch(state)
    {
    case S_FETCH: return "S_FETCH";
    case S_DECIDE_IMM: return "S_DECIDE_IMM";
    case S_FETCH_IMM: return "S_FETCH_IMM";
    case S_EXEC: return "S_EXEC";
    case S_DONE: return "S_DONE";

    // Single memory operation states
    case S_STACK_READ: return "S_STACK_READ";           // Single stack read (2 cycles: req + wait)
    case S_HEAP_READ: return "S_HEAP_READ";            // Single heap read (2 cycles: req + wait)
    case S_GLOBALS_READ: return "S_GLOBALS_READ";         // Single globals read (2 cycles: req + wait)

    // PUSH/ACC combined operations
    case S_PUSHACC_WRITE: return "S_PUSHACC_WRITE";        // Write old accu to stack
    case S_PUSHACC_READ: return "S_PUSHACC_READ";         // Read new accu from stack
    
    // Helper completion states
    case S_ENVACC_DONE: return "S_ENVACC_DONE";          // Complete ENVACC operations
    case S_GETFIELD_DONE: return "S_GETFIELD_DONE";        // Complete GETFIELD operations
    case S_OFFSETREF_ADD: return "S_OFFSETREF_ADD";        // Complete OFFSETREF calculation
    case S_OFFSETCLOSURE_CALC: return "S_OFFSETCLOSURE_CALC";   // Complete OFFSETCLOSURE calculation
    
    // MAKEBLOCK3 states
    case S_MAKEBLOCK_READ_STACK: return "S_MAKEBLOCK_READ_STACK"; // Read values from stack
    case S_MAKEBLOCK_WRITE_HDR: return "S_MAKEBLOCK_WRITE_HDR";       // Write header
    case S_MAKEBLOCK_WRITE_FIELD: return "S_MAKEBLOCK_WRITE_FIELD";    // Write fields (loop)
    
    // MAKEBLOCK1 states
    case S_MAKEBLOCK1_FIELD: return "S_MAKEBLOCK1_FIELD";     // Write single field
    
    // MAKEBLOCK2 states
    case S_MAKEBLOCK2_HDR: return "S_MAKEBLOCK2_HDR";       // Write header
    case S_MAKEBLOCK2_FIELDS: return "S_MAKEBLOCK2_FIELDS";    // Write fields (loop)
    
    // MAKEBLOCK3 states
    case S_MAKEBLOCK3_READ_STACK: return "S_MAKEBLOCK3_READ_STACK"; // Read values from stack
    case S_MAKEBLOCK3_HDR: return "S_MAKEBLOCK3_HDR";       // Write header
    case S_MAKEBLOCK3_FIELDS: return "S_MAKEBLOCK3_FIELDS";    // Write fields (loop)
    
    // APPTERM states
    case S_APPTERM_READ_CODE: return "S_APPTERM_READ_CODE";    // Read arguments
    case S_APPTERM_READ_ARGS: return "S_APPTERM_READ_ARGS";    // Read arguments
    case S_APPTERM_WRITE_ARGS: return "S_APPTERM_WRITE_ARGS";   // Write arguments
    case S_APPTERM_SET_PC: return "S_APPTERM_SET_PC";       // Set PC from closure
    
    // APPTERM1 states
    case S_APPTERM1_ADJUST: return "S_APPTERM1_ADJUST";      // Adjust stack pointer
    case S_APPTERM1_WRITE: return "S_APPTERM1_WRITE";       // Write argument
    case S_APPTERM1_SETPC: return "S_APPTERM1_SETPC";       // Set PC from closure
    
    // APPTERM2 states
    case S_APPTERM2_READ_ARGS: return "S_APPTERM2_READ_ARGS";   // Read arguments
    case S_APPTERM2_WRITE_ARGS: return "S_APPTERM2_WRITE_ARGS";  // Write arguments
    case S_APPTERM2_SETPC: return "S_APPTERM2_SETPC";       // Set PC from closure
    
    // APPTERM3 states
    case S_APPTERM3_READ_ARGS: return "S_APPTERM3_READ_ARGS";   // Read arguments
    case S_APPTERM3_WRITE_ARGS: return "S_APPTERM3_WRITE_ARGS";  // Write arguments
    case S_APPTERM3_SETPC: return "S_APPTERM3_SETPC";       // Set PC from closure
    
    // APPLY states
    case S_APPLY_READ_CODE: return "S_APPLY_READ_CODE";      // Read arguments
    case S_APPLY_WRITE_FRAME: return "S_APPLY_WRITE_FRAME";    // Write return frame
    case S_APPLY_SET_PC: return "S_APPLY_SET_PC";         // Set PC from closure
    
    // APPLY1 states
    case S_APPLY1_WRITE_FRAME: return "S_APPLY1_WRITE_FRAME";   // Write return frame
    case S_APPLY1_SETPC: return "S_APPLY1_SETPC";         // Set PC from closure
    
    // APPLY2 states
    case S_APPLY2_WRITE_FRAME: return "S_APPLY2_WRITE_FRAME";   // Write return frame
    case S_APPLY2_SETPC: return "S_APPLY2_SETPC";         // Set PC from closure
    
    // APPLY3 states
    case S_APPLY3_WRITE_FRAME: return "S_APPLY3_WRITE_FRAME";   // Write return frame
    case S_APPLY3_SETPC: return "S_APPLY3_SETPC";         // Set PC from closure
    
    // RETURN states
    case S_RETURN_READ_FRAME: return "S_RETURN_READ_FRAME";    // Read return frame
    case S_RETURN_RESTORE: return "S_RETURN_RESTORE";       // Restore state
    case S_RETURN_READ_PC: return "S_RETURN_READ_PC";       // Restore state
    case S_RETURN_READ_ENV: return "S_RETURN_READ_ENV";      // Restore state
    case S_RETURN_READ_EXTRA: return "S_RETURN_READ_EXTRA";      // Restore state
    case S_RETURN_SET_STATE: return "S_RETURN_SET_STATE";     // Restore state
    
    // Heap allocation micro-ops (for CLOSURE/MAKEBLOCK via S_EXEC)
    case S_HEAP_ALLOC_HDR: return "S_HEAP_ALLOC_HDR";       // Write header to heap
    case S_HEAP_ALLOC_FIELDS: return "S_HEAP_ALLOC_FIELDS";    // Write fields one per cycle
    
    // CLOSURE-specific states (kept from original)
    case S_CLOSURE_ALLOC_HDR: return "S_CLOSURE_ALLOC_HDR";
    case S_CLOSURE_WRITE_CODE: return "S_CLOSURE_WRITE_CODE";
    case S_CLOSURE_WRITE_CLOSINFO: return "S_CLOSURE_WRITE_CLOSINFO";
    case S_CLOSURE_WRITE_ENV: return "S_CLOSURE_WRITE_ENV";
    case S_CLOSURE_DONE: return "S_CLOSURE_DONE";
    case S_CLOSUREREC_CALC: return "S_CLOSUREREC_CALC";

    // Trap / ccall
    case S_TRAP_WAIT: return "S_TRAP_WAIT";

    // obsolete states
    case S_HEAP_DONE: return "S_HEAP_DONE";
    case S_OFFSETCLOSURE_READ: return "S_OFFSETCLOSURE_READ";
    case S_OFFSETCLOSURE_ADD: return "S_OFFSETCLOSURE_ADD";
    // Unknown state for debugging
    case S_UNKNOWN: return "S_UNKNOWN";
    default: return "S_NOT_SUPPORTED";
    }
}

typedef char linbuf[256];

linbuf trace[4096];

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    if (argc < 3) {
        std::cerr << "usage: " << argv[0] << " program.bc trace_file\n";
        return 1;
    }

    int prog_length = caml_bytecode(argv[1]);
    auto* top = new Vocaml4142_vm_rtl;
    FILE *tracef = fopen(argv[2], "r");
    fgets(trace[0], sizeof(linbuf), tracef);
    
    // Optional waveform
    VerilatedVcdC* tfp = nullptr;
    Verilated::traceEverOn(true);
    tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("trace.vcd");

    // Reset
    top->reset = 1;
    for (int i = 0; i < 10; i++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }
    top->reset = 0;

    uint64_t cycles = 0;
    const char *op;
    linbuf opcode;
    uint32_t addr, op1, cnt, oldpc, vitems, cycle, accu, spaddr, items, oldcycle = 0;
    int matching = 1;
    int windup = 10;
    printf("Program length %d\n", prog_length);

    while (windup && !Verilated::gotFinish()) {
      if (top->pc >= prog_length)
	{
	  printf("Terminating on PC %d out of %d range\n", top->pc, prog_length);
	  matching = 0;
	}
        // Provide instruction byte
        top->code_rdata = top->pc < sizeof(code_rom)/sizeof(*code_rom) ? code_rom[top->pc] : 0xDEADBEEF;
        // Clock tick
        top->clk = 0;
        top->eval();
        vitems = 0xffff - top->sp;
        tfp->dump(cycles);
	
	switch(top->state_out)
	  {
	  case S_FETCH:
	    oldpc = top->pc;
	    op = opname(top->code_rdata);
	    printf("Fetch PC=%d ROM = 0x%x, instruction = %s, SP=@%d\n", top->pc, top->code_rdata, op, vitems);
	    cnt = 0;
	    do {
	      fgets(trace[cnt], sizeof(linbuf), tracef);
	      printf("Trace %s", trace[cnt]);
	      
	    } while (cnt < sizeof(trace)/sizeof(*trace) && ((cnt == 0 && trace[cnt][0] != '#') || strlen(trace[cnt++]) > 1));
	    
	    cnt = sscanf(trace[0], "##%d", &cycle);
	    if (!cnt || cycle != oldcycle+1)
	      {
	      printf("Trace mismatch\n");
	      matching = 0;
	      }
	    oldcycle = cycle;
	    cnt = sscanf(trace[1], " %d %s %d", &addr, opcode, &op1);
	    printf("Trace cnt=%d: %s\n", cnt, trace[1]);
	    if (cnt >= 2 && matching)
	      {
		if (strcmp(op, opcode))
		  matching = 0;
		if (!matching)
		  printf("Stopped due to instruction mismatch %s vs %s\n", op, opcode);
		if (oldpc != addr)
		  {
		    printf("Stopped due to PC mismatch %d vs %d\n", oldpc, addr);
		    matching = 0;
		  }
		    
	      }
	    cnt = sscanf(trace[3], "accu=%x", &accu);
	    if (cnt > 0)
	      {
		if (accu != top->accu && accu&1)
		  {
		    printf("ACCU mismatch %x vs %x\n", accu, top->accu);
		  }
	      }
	    cnt = sscanf(trace[4], " sp=0x%x @%d", &spaddr, &items);
	    if (cnt >= 2)
	      {
		if (items != vitems)
		  {
		    printf("SP mismatch %x vs %x\n", items, vitems);
		  }
	      }
	    else printf("Failed to parse SP: %s\n", trace[4]);
	    break;
	  case S_EXEC: printf(
            "%08llx %s pc=%06d rom=%4x op=%s imm=%x nvars=%08x offset=%08x acc=%08x SP=@%d\n",
            cycles,
	    statenam(top->state_out), 
            top->pc,
	    top->opcode_out,
            opname(top->opcode_out),
	    top->imm,
	    top->nvars,
	    top->offset,
            top->accu,
            vitems);
	    break;
	  case S_DONE:
	    printf("%08llx %s pc=%06d SP=@%d\n", cycles, statenam(top->state_out), top->pc, vitems);
	    break;
	  default:
	    printf("%08llx %s pc=%06d SP=@%d\n", cycles, statenam(top->state_out), top->pc, vitems);
	    break;
	  }
	
        top->clk = 1;
        top->eval();

        if (top->halted) {
            std::cout << "HALT\n";
            break;
        }

        if (++cycles > 50'000'000) {
            std::cerr << "Timeout\n";
            break;
        }

	windup -= !matching;
    }

    tfp->close();
    delete tfp;
    delete top;
    return 0;
}
