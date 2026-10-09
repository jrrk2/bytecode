// INTCODE monitor: runs from the flash at reset and after any program run from the file system halts.
// DIR  lists the files; CAT n  shows one; PUT n  stores what is typed up to ^D; COPY a b; LINK a b (a is another name for b); RUN n args  starts the program in file n.
GET "LIBHDR"

GLOBAL $( EXEC:88 $)

LET UPPER(C) = 'a' <= C <= 'z' -> C - 32, C

AND READLINE(V) = VALOF
$( LET N = 0
   LET C = 0
   $( C := RDCH()
      IF C = ENDSTREAMCH DO $( WRCH('*N'); RESULTIS FALSE $)
      IF C = '*N' \/ C = 13 DO BREAK
      TEST (C = 8 \/ C = 127) THEN
      $( IF N > 0 DO $( N := N - 1; WRCH(8); WRCH(' '); WRCH(8) $) $)
      OR IF N < 79 DO $( N := N + 1; PUTBYTE(V, N, UPPER(C)); WRCH(C) $)
   $) REPEAT
   PUTBYTE(V, 0, N)
   WRCH('*N')
   RESULTIS TRUE
$)

// the next word of the line V, starting after position P, into W (a BCPL string); the position after it
AND WORD(V, P, W) = VALOF
$( LET N = 0
   WHILE P < GETBYTE(V, 0) & GETBYTE(V, P + 1) = ' ' DO P := P + 1
   WHILE P < GETBYTE(V, 0) & GETBYTE(V, P + 1) \= ' ' DO
   $( IF N < 23 DO $( N := N + 1; PUTBYTE(W, N, GETBYTE(V, P + 1)) $)
      P := P + 1  $)
   PUTBYTE(W, 0, N)
   RESULTIS P
$)

AND SAME(A, B) = VALOF
$( IF GETBYTE(A, 0) \= GETBYTE(B, 0) RESULTIS FALSE
   FOR I = 1 TO GETBYTE(A, 0) DO IF GETBYTE(A, I) \= GETBYTE(B, I) RESULTIS FALSE
   RESULTIS TRUE
$)

AND OPEN(NAME) = VALOF
$( LET S = FINDINPUT(NAME)
   IF S = 0 DO $( WRITES("NO SUCH FILE*N"); RESULTIS 0 $)
   RESULTIS S
$)

AND DODIR() BE
$( LET S = FINDINPUT("$FLASH")
   LET H = VEC 8
   LET NM = VEC 8
   LET MORE = TRUE
   IF S = 0 DO $( WRITES("NO FILE SYSTEM*N"); RETURN $)
   SELECTINPUT(S)
   WHILE MORE DO
   $( LET C = RDCH()
      TEST C = ENDSTREAMCH THEN MORE := FALSE ELSE
      $( LET LEN = 0
         PUTBYTE(H, 0, C)
         FOR I = 1 TO 31 DO PUTBYTE(H, I, RDCH())
         FOR J = 0 TO 23 DO PUTBYTE(NM, J, GETBYTE(H, (J/4)*4 + 3 - J REM 4))
         LEN := GETBYTE(H, 24) + 256*GETBYTE(H, 25) + 65536*GETBYTE(H, 26)
         WRITES(NM); WRITES("   "); WRITEN(LEN); NEWLINE()
         FOR I = 1 TO LEN + ((4 - LEN REM 4) REM 4) DO RDCH()
      $)
   $)
   ENDREAD()
$)

AND DOCAT(NAME) BE
$( LET S = OPEN(NAME)
   IF S = 0 RETURN
   SELECTINPUT(S)
   $( LET C = RDCH()
      IF C = ENDSTREAMCH BREAK
      WRCH(C)
   $) REPEAT
   ENDREAD()
$)

AND DOPUT(NAME) BE
$( LET O = FINDOUTPUT(NAME)
   IF O = 0 DO $( WRITES("CANNOT CREATE*N"); RETURN $)
   WRITES("TYPE THE TEXT, THEN ^D*N")
   SELECTOUTPUT(O)
   $( LET C = RDCH()
      IF C = ENDSTREAMCH BREAK
      WRCH(C)
   $) REPEAT
   ENDWRITE()
   WRITES("OK*N")
$)

// LINK name target: the file name now stands for the file target (a record whose text is LNK: and the target's name), at no cost in copying
AND DOLINK(NAME, TARGET) BE
$( LET O = FINDOUTPUT(NAME)
   IF O = 0 DO $( WRITES("CANNOT CREATE*N"); RETURN $)
   SELECTOUTPUT(O)
   WRITES("LNK:"); WRITES(TARGET); WRCH('*N')
   ENDWRITE()
$)

// RUN name args: the arguments (the rest of the line) go into the file ARGS, the first one also becomes the standard input (STDIN is a link to it), and then
// the program is started
AND DORUN(NAME, W3, LINE, P) BE
$( LET O = FINDOUTPUT("ARGS")
   IF O \= 0 DO
   $( SELECTOUTPUT(O)
      FOR I = P + 1 TO GETBYTE(LINE, 0) DO WRCH(GETBYTE(LINE, I))
      WRCH('*N')
      ENDWRITE()  $)
   IF GETBYTE(W3, 0) > 0 DO DOLINK("STDIN", W3)
   IF EXEC(NAME) = 0 DO WRITES("NO SUCH PROGRAM*N")
$)

AND DOCOPY(A, B) BE
$( LET S = OPEN(A)
   LET O = 0
   IF S = 0 RETURN
   O := FINDOUTPUT(B)
   IF O = 0 DO $( WRITES("CANNOT CREATE*N"); RETURN $)
   SELECTINPUT(S)
   SELECTOUTPUT(O)
   $( LET C = RDCH()
      IF C = ENDSTREAMCH BREAK
      WRCH(C)
   $) REPEAT
   ENDREAD()
   ENDWRITE()
   WRITES("OK*N")
$)

LET START() BE
$( LET LINE = VEC 21
   LET W1 = VEC 7
   LET W2 = VEC 7
   LET W3 = VEC 7
   WRITES("*NINTCODE MONITOR  DIR CAT PUT COPY LINK RUN HELP*N")
   $( LET P = 0
      LET Q = 0
      WRCH('>')
      UNLESS READLINE(LINE) DO LOOP
      P := WORD(LINE, 0, W1)
      P := WORD(LINE, P, W2)
      Q := P
      P := WORD(LINE, P, W3)
      TEST GETBYTE(W1, 0) = 0 THEN LOOP
      OR TEST SAME(W1, "DIR") THEN DODIR()
      OR TEST SAME(W1, "CAT") THEN DOCAT(W2)
      OR TEST SAME(W1, "PUT") THEN DOPUT(W2)
      OR TEST SAME(W1, "COPY") THEN DOCOPY(W2, W3)
      OR TEST SAME(W1, "LINK") THEN DOLINK(W2, W3)
      OR TEST SAME(W1, "RUN") THEN DORUN(W2, W3, LINE, Q)
      OR WRITES("DIR  CAT n  PUT n  COPY a b  LINK a b  RUN n args*N")
   $) REPEAT
$)
