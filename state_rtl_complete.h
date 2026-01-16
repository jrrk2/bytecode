{
    // Basic fetch/execute states
    S_FETCH,
    S_DECIDE_IMM,
    S_FETCH_IMM,
    S_EXEC,
    S_DONE,

    // Single memory operation states
    S_STACK_READ,           // Single stack read (2 cycles: req + wait)
    S_HEAP_READ,            // Single heap read (2 cycles: req + wait)
    S_GLOBALS_READ,         // Single globals read (2 cycles: req + wait)

    // PUSH/ACC combined operations
    S_PUSHACC_WRITE,        // Write old accu to stack
    S_PUSHACC_READ,         // Read new accu from stack
    
    // Helper completion states
    S_ENVACC_DONE,          // Complete ENVACC operations
    S_GETFIELD_DONE,        // Complete GETFIELD operations
    S_OFFSETREF_ADD,        // Complete OFFSETREF calculation
    S_OFFSETCLOSURE_CALC,   // Complete OFFSETCLOSURE calculation
    
    // MAKEBLOCK3 states
    S_MAKEBLOCK_READ_STACK, // Read values from stack
    S_MAKEBLOCK_WRITE_HDR,       // Write header
    S_MAKEBLOCK_WRITE_FIELD,    // Write fields (loop)
    
    // MAKEBLOCK1 states
    S_MAKEBLOCK1_FIELD,     // Write single field
    
    // MAKEBLOCK2 states
    S_MAKEBLOCK2_HDR,       // Write header
    S_MAKEBLOCK2_FIELDS,    // Write fields (loop)
    
    // MAKEBLOCK3 states
    S_MAKEBLOCK3_READ_STACK, // Read values from stack
    S_MAKEBLOCK3_HDR,       // Write header
    S_MAKEBLOCK3_FIELDS,    // Write fields (loop)
    
    // APPTERM states
    S_APPTERM_READ_CODE,    // Read arguments
    S_APPTERM_READ_ARGS,    // Read arguments
    S_APPTERM_WRITE_ARGS,   // Write arguments
    S_APPTERM_SET_PC,       // Set PC from closure
    
    // APPTERM1 states
    S_APPTERM1_ADJUST,      // Adjust stack pointer
    S_APPTERM1_WRITE,       // Write argument
    S_APPTERM1_SETPC,       // Set PC from closure
    
    // APPTERM2 states
    S_APPTERM2_READ_ARGS,   // Read arguments
    S_APPTERM2_WRITE_ARGS,  // Write arguments
    S_APPTERM2_SETPC,       // Set PC from closure
    
    // APPTERM3 states
    S_APPTERM3_READ_ARGS,   // Read arguments
    S_APPTERM3_WRITE_ARGS,  // Write arguments
    S_APPTERM3_SETPC,       // Set PC from closure
    
    // APPLY states
    S_APPLY_READ_CODE,      // Read arguments
    S_APPLY_WRITE_FRAME,    // Write return frame
    S_APPLY_SET_PC,         // Set PC from closure
    
    // APPLY1 states
    S_APPLY1_WRITE_FRAME,   // Write return frame
    S_APPLY1_SETPC,         // Set PC from closure
    
    // APPLY2 states
    S_APPLY2_WRITE_FRAME,   // Write return frame
    S_APPLY2_SETPC,         // Set PC from closure
    
    // APPLY3 states
    S_APPLY3_WRITE_FRAME,   // Write return frame
    S_APPLY3_SETPC,         // Set PC from closure
    
    // RETURN states
    S_RETURN_READ_FRAME,    // Read return frame
    S_RETURN_RESTORE,       // Restore state
    S_RETURN_READ_PC,       // Restore state
    S_RETURN_READ_ENV,      // Restore state
    S_RETURN_READ_EXTRA,      // Restore state
    S_RETURN_SET_STATE,     // Restore state
    
    // Heap allocation micro-ops (for CLOSURE/MAKEBLOCK via S_EXEC)
    S_HEAP_ALLOC_HDR,       // Write header to heap
    S_HEAP_ALLOC_FIELDS,    // Write fields one per cycle
    
    // CLOSURE-specific states (kept from original)
    S_CLOSURE_ALLOC_HDR,
    S_CLOSURE_WRITE_CODE,
    S_CLOSURE_WRITE_CLOSINFO,
    S_CLOSURE_WRITE_ENV,
    S_CLOSURE_DONE,
    S_CLOSUREREC_CALC,

    S_PUSH_RETADDR_WRITE_FRAME,
    // Trap / ccall
    S_TRAP_WAIT,

    // obsolete states
    S_HEAP_DONE,
    S_OFFSETCLOSURE_READ,
    S_OFFSETCLOSURE_ADD,
    // Unknown state for debugging
    S_UNKNOWN
} state_t;
