{
    S_FETCH      ,
    S_DECIDE_IMM,
    S_FETCH_IMM ,
    S_EXEC      ,

    // heap write micro-ops
    S_HEAP_ALLOC_HDR,
    S_HEAP_ALLOC_FIELDS,
    S_CLOSURE_ALLOC_HDR,
    S_CLOSURE_WRITE_CODE,
    S_CLOSURE_WRITE_CLOSINFO,
    S_CLOSURE_WRITE_ENV,
    S_CLOSURE_DONE,
    S_CLOSUREREC_CALC,
    // trap / ccall
    S_TRAP_WAIT,
    S_DONE
  } state_t;
