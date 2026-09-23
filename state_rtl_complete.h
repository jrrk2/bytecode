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
    S_OFFSETCLOSURE_CALC,   // Complete OFFSETCLOSURE calculation
    
    // MAKEBLOCK3 states
    S_MAKEBLOCK_READ_STACK, // Read values from stack
    S_MAKEBLOCK_WRITE_HDR,       // Write header
    S_MAKEBLOCK_WRITE_FIELD,    // Write fields (loop)
    
    // MAKEBLOCK1 states
    
    // MAKEBLOCK2 states
    
    // MAKEBLOCK3 states
    
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
    
    // CLOSURE-specific states (kept from original)

    S_PUSH_RETADDR_WRITE_FRAME,
    // arrays
    S_VECTLENGTH_CALC,
    S_GETVECTITEM_DONE,
    S_SETVECTITEM_WRITE,

    // Trap / ccall
    S_TRAP_WAIT,

    // The allocator: header, fields, done (MAKEBLOCK*, CLOSURE, CLOSUREREC)
    S_ALLOC_HDR,
    S_ALLOC_FIELD,
    S_ALLOC_DONE,
    S_ALLOC_PUSH,
    S_APPTERM_COPY,

    // Garbage collection (Cheney)
    S_GC_START,
    S_GC_ROOT,
    S_GC_ROOT_WB,
    S_GC_FWD,
    S_GC_COPY,
    S_GC_MARK,
    S_GC_SCAN,
    S_GC_SCAN_FIELD,
    S_GC_SCAN_WB,
    S_GC_DONE,

    // SWITCH: a block's tag, then the jump
    S_SWITCH_TAG,
    S_SWITCH_JUMP,

    // caml_obj_dup: header, then fields
    S_DUP_HDR,
    S_DUP_FIELD,

    // RESTART: unpack a partial application's closure
    S_RESTART_HDR,
    S_RESTART_ARG,
    S_RESTART_ENV,

    // DIVINT / MODINT: one quotient bit per cycle
    S_DIV_ITER,

    // MULINT: operands registered, then the product, so the multiplier is
    // pipelined and off the critical path
    S_MUL_MUL,
    S_MUL_DONE,

    // Bytes: a byte store, caml_create_bytes, caml_string_equal
    S_BYTESET_RMW,
    S_CREATE_BYTES,
    S_STREQ_HDR,
    S_STREQ_WORD,

    // String primitives (caml_ml_string_length, caml_string_get)
    S_STRLEN_HDR,
    S_STRLEN_LAST,
    S_STRGET_READ,

    // vm_io_read / vm_io_write: waiting on the trap port
    S_IO_WAIT,

    // exceptions: the trap frame, the raise and the zero-divide raise
    S_PUSHTRAP_WRITE_FRAME,
    S_POPTRAP,
    S_RAISE_ENTER,
    S_RAISE_READ,
    S_RAISE_FRAME,
    S_ZERO_DIVIDE,
    // obsolete states
    S_OFFSETCLOSURE_READ,
    S_OFFSETCLOSURE_ADD,
    // Unknown state for debugging
    S_UNKNOWN
} state_t;
