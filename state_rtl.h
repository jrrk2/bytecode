{
    // Basic fetch/execute states
    S_FETCH      ,
    S_DECIDE_IMM,
    S_FETCH_IMM ,
    S_EXEC      ,
    S_DONE      ,

    // Single memory operation states
    S_STACK_READ,           // Single stack read (2 cycles: req + wait)
    S_HEAP_READ,            // Single heap read (2 cycles: req + wait)
    S_GLOBALS_READ,         // Single globals read (2 cycles: req + wait)

    // PUSH/ACC combined operations
    S_PUSHACC_WRITE,        // Write old accu to stack
    S_PUSHACC_READ,         // Read new accu from stack
    
    // APPTERM states (read args, adjust stack, write args, read code)
    S_APPTERM_READ_ARGS,    // Reading arguments from old stack position
    S_APPTERM_WRITE_ARGS,   // Writing arguments to new stack position  
    S_APPTERM_READ_CODE,    // Reading code pointer from closure
    
    // APPLY states (write frame, read code)
    S_APPLY_WRITE_FRAME,    // Writing return frame to stack
    S_APPLY_READ_CODE,      // Reading code pointer from closure
    
    // RETURN states (read frame info)
    S_RETURN_READ_PC,       // Read return PC from stack
    S_RETURN_READ_ENV,      // Read saved env from stack  
    S_RETURN_READ_EXTRA,    // Read extra_args from stack
    
    // MAKEBLOCK states (read stack, write header, write fields)
    S_MAKEBLOCK_READ_STACK, // Read values from stack before allocation
    S_MAKEBLOCK_WRITE_HDR,  // Write block header to heap
    S_MAKEBLOCK_WRITE_FIELD,// Write one field to heap (may repeat)
    
    // OFFSETCLOSURE (special heap read with offset)
    S_OFFSETCLOSURE_READ,   // Read from heap with offset calculation

    // Heap allocation micro-ops (CLOSURE/MAKEBLOCK via S_EXEC)
    S_HEAP_ALLOC_HDR,       // Write header to heap
    S_HEAP_ALLOC_FIELDS,    // Write fields one per cycle
    
    // CLOSURE-specific states
    S_CLOSURE_ALLOC_HDR,
    S_CLOSURE_WRITE_CODE,
    S_CLOSURE_WRITE_CLOSINFO,
    S_CLOSURE_WRITE_ENV,
    S_CLOSURE_DONE,
    S_CLOSUREREC_CALC,

    // Trap / ccall
    S_TRAP_WAIT,
    
    // Unknown state for debugging
    S_UNKNOWN
  } state_t;
