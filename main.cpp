#include "Vocaml4142_vm.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
typedef enum
#include "state.h"

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
    case S_FETCH      : return "S_FETCH      ";
    case S_DECIDE_IMM: return "S_DECIDE_IMM";
    case S_FETCH_IMM : return "S_FETCH_IMM ";
    case S_EXEC      : return "S_EXEC      ";

    // heap write micro-ops
    case S_HEAP_ALLOC_HDR: return "S_HEAP_ALLOC_HDR";
    case S_HEAP_ALLOC_FIELDS: return "S_HEAP_ALLOC_FIELDS";
    case S_CLOSURE_ALLOC_HDR: return "S_CLOSURE_ALLOC_HDR";
    case S_CLOSURE_WRITE_CODE: return "S_CLOSURE_WRITE_CODE";
    case S_CLOSURE_WRITE_CLOSINFO: return "S_CLOSURE_WRITE_CLOSINFO";
    case S_CLOSURE_WRITE_ENV: return "S_CLOSURE_WRITE_ENV";
    case S_CLOSURE_DONE: return "S_CLOSURE_DONE";			   
    case S_CLOSUREREC_CALC: return "S_CLOSUREREC_CALC";
    // trap / ccall
    case S_TRAP_WAIT: return "S_TRAP_WAIT";
    case S_DONE: return "S_DONE";
    default: return "S_UNKNOWN";
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
    auto* top = new Vocaml4142_vm;
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
