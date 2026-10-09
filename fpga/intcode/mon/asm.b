// ASM: the INTCODE assembler, on the FPGA.  Port of the assembler in icint.c (and of intcode_send.py): INTCODE text in, a program file out.
// Its arguments are in the file ARGS (the monitor's RUN name args writes it): the name of the file to make, then the names of the INTCODE files, which are
// assembled in order as one program (ICLIB.I, BLIB.I, then the program's own .I).  The file has the header the loader wants (INTC, N, C, P, G) and N words.
// An argument -NAME (e.g. -OCODE) names the file the program is to read as its standard input: the header is then INTD, with the name after G (default: STDIN).
GET "LIBHDR"

GLOBAL $( M:150; P:151; CH:152; CP:153; LABV:154 $)

MANIFEST $( FSHIFT=13; IBIT=4096; PBIT=2048; GBIT=1024; DBIT=512; ABITS=511
            LIG1=5121; K2=49154; X22=57366; MPROG=402; MGLOB=1; MAGIC=1229870147; MAGICD=1229870148  $)

LET ASSEMBLE() BE
$(1 LET F = 0
CLEAR: FOR I = 0 TO 500 DO LABV!I := 0
       CP := 0

NEXT: RCH()
SW:   SWITCHON CH INTO

$(S   DEFAULT: IF CH=ENDSTREAMCH RETURN
               WRITEF("*NBAD CH %C AT P = %N*N", CH, P)
               GOTO NEXT

      CASE '0':CASE '1':CASE '2':CASE '3':CASE '4':
      CASE '5':CASE '6':CASE '7':CASE '8':CASE '9':
               SETLAB(RDN())
               CP := 0
               GOTO SW

      CASE '$':CASE '*S':CASE '*N': GOTO NEXT

      CASE 'L': F := 0; ENDCASE
      CASE 'S': F := 1; ENDCASE
      CASE 'A': F := 2; ENDCASE
      CASE 'J': F := 3; ENDCASE
      CASE 'T': F := 4; ENDCASE
      CASE 'F': F := 5; ENDCASE
      CASE 'K': F := 6; ENDCASE
      CASE 'X': F := 7; ENDCASE

      CASE 'C': RCH(); STC(RDN()); GOTO SW

      CASE 'D': RCH()
                TEST CH='L'
                  THEN $( RCH()
                          STW(0)
                          LABREF(RDN(), P-1)  $)
                  OR STW(RDN())
                GOTO SW

      CASE 'G': RCH()
                $( LET A = RDN() + MGLOB
                   TEST CH='L' THEN RCH()
                         OR WRITEF("*NBAD CODE AT P = %N*N", P)
                   M!A := 0
                   LABREF(RDN(), A)  $)
                GOTO SW

      CASE 'Z': FOR I = 0 TO 500 DO
                   IF LABV!I>0 DO WRITEF("L%N UNSET*N", I)
                GOTO CLEAR  $)S

      $( LET W = F<<FSHIFT
         RCH()
         IF CH='I' DO $( W := W+IBIT; RCH() $)
         IF CH='P' DO $( W := W+PBIT; RCH() $)
         IF CH='G' DO $( W := W+GBIT; RCH() $)

         TEST CH='L'

           THEN $( RCH()
                   STW(W+DBIT)
                   STW(0)
                   LABREF(RDN(), P-1)  $)

           OR   $( LET A = RDN()
                   TEST (A&ABITS)=A
                     THEN STW(W+A)
                     OR $( STW(W+DBIT); STW(A)  $)  $)
      $)

      GOTO SW   $)1

AND STW(W) BE $( M!P := W
                 P, CP := P+1, 0  $)

AND STC(C) BE $( IF CP=0 DO $( STW(0); CP := 32  $)
                 CP := CP - 8
                 M!(P-1) := M!(P-1) + (C<<CP)  $)

AND RCH() BE $(1 CH := RDCH()
                 UNLESS CH='/' RETURN
                 UNTIL CH='*N' \/ CH=ENDSTREAMCH DO CH := RDCH()
                 IF CH=ENDSTREAMCH RETURN  $)1 REPEAT

AND RDN() = VALOF
    $( LET A, B = 0, FALSE
       IF CH='-' DO $( B := TRUE; RCH()  $)
       WHILE '0'<=CH<='9' DO $( A := 10*A + CH - '0'; RCH()  $)
       IF B DO A := -A
       RESULTIS A  $)

AND SETLAB(N) BE
     $( LET K = LABV!N
        IF K<0 DO WRITEF("L%N ALREADY SET TO %N AT P = %N*N",N,-K,P)
        WHILE K>0 DO $( LET NX = M!K
                        M!K := P
                        K := NX  $)
        LABV!N := -P  $)

AND LABREF(N, A) BE
    $( LET K = LABV!N
       TEST K<0 THEN K := -K OR LABV!N := A
       M!A := M!A + K  $)

AND PUTWORD(W) BE
    $( WRCH(W & 255); WRCH((W>>8) & 255); WRCH((W>>16) & 255); WRCH((W>>24) & 255)  $)

LET START() BE
$( LET MV = VEC 22000
   LET LBV = VEC 500
   LET AV = VEC 63
   LET NV = VEC 59
   LET N = 0
   LET S = FINDINPUT("ARGS")
   LET LEN = 0
   LET SN = VEC 5
   LET HAVE = FALSE
   M, LABV := MV, LBV
   FOR I = 0 TO 59 DO NV!I := 0
   IF S = 0 DO $( WRITES("NO ARGS: RUN ASM OUT IN...*N"); RETURN $)
   SELECTINPUT(S)
   $( LET C = RDCH()
      IF C = ENDSTREAMCH \/ C = '*N' \/ LEN >= 250 BREAK
      LEN := LEN + 1
      PUTBYTE(AV, LEN, C)
   $) REPEAT
   ENDREAD()
   PUTBYTE(AV, 0, LEN)
   // the words of the line, each a BCPL string 6 words (24 bytes) apart in NV
   $( LET P0 = 1
      WHILE P0 <= LEN DO
      $( LET W = NV + 6*N
         LET K = 0
         WHILE P0 <= LEN & GETBYTE(AV, P0) = ' ' DO P0 := P0 + 1
         IF P0 > LEN BREAK
         WHILE P0 <= LEN & GETBYTE(AV, P0) \= ' ' DO
         $( IF K < 23 DO $( K := K + 1; PUTBYTE(W, K, GETBYTE(AV, P0)) $)
            P0 := P0 + 1  $)
         PUTBYTE(W, 0, K)
         N := N + 1
         IF N >= 9 BREAK
      $)
   $)
   IF N < 2 DO $( WRITES("USAGE: RUN ASM OUT IN...*N"); RETURN $)
   FOR I = 0 TO 5 DO SN!I := 0
   FOR I = 1 TO N - 1 DO
   $( LET W = NV + 6*I
      IF GETBYTE(W, 0) > 1 & GETBYTE(W, 1) = '-' DO
      $( FOR K = 2 TO GETBYTE(W, 0) DO PUTBYTE(SN, K - 1, GETBYTE(W, K))
         PUTBYTE(SN, 0, GETBYTE(W, 0) - 1)
         PUTBYTE(W, 0, 0)
         HAVE := TRUE  $)
   $)
   FOR I = 0 TO 22000 DO M!I := 0
   P, CP := MPROG, 0
   M!P := LIG1; M!(P+1) := K2; M!(P+2) := X22
   P := P + 3
   FOR I = 1 TO N - 1 DO
   $( LET F = 0
      IF GETBYTE(NV + 6*I, 0) = 0 LOOP
      F := FINDINPUT(NV + 6*I)
      TEST F = 0 THEN $( WRITES("NO SUCH FILE: "); WRITES(NV + 6*I); NEWLINE() $)
      OR $( SELECTINPUT(F); ASSEMBLE(); ENDREAD() $)
   $)
   $( LET O = FINDOUTPUT(NV)
      IF O = 0 DO $( WRITES("CANNOT CREATE*N"); RETURN $)
      SELECTOUTPUT(O)
      PUTWORD(HAVE -> MAGICD, MAGIC); PUTWORD(P); PUTWORD(MPROG); PUTWORD(P); PUTWORD(MGLOB)
      IF HAVE DO FOR I = 0 TO 5 DO PUTWORD(SN!I)
      FOR I = 0 TO P - 1 DO PUTWORD(M!I)
      ENDWRITE()
   $)
   WRITEN(P); WRITES(" WORDS*N")
$)
