/**************************************************************************/
/*                                                                        */
/*                                 OCaml                                  */
/*                                                                        */
/*          Xavier Leroy and Damien Doligez, INRIA Rocquencourt           */
/*                                                                        */
/*   Copyright 1996 Institut National de Recherche en Informatique et     */
/*     en Automatique.                                                    */
/*                                                                        */
/*   All rights reserved.  This file is distributed under the terms of    */
/*   the GNU Lesser General Public License version 2.1, with the          */
/*   special exception on linking described in the file LICENSE.          */
/*                                                                        */
/**************************************************************************/

#define CAML_INTERNALS

/* Start-up code */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include "caml/config.h"
#ifdef HAS_UNISTD
#include <unistd.h>
#endif
#ifdef _WIN32
#include <process.h>
#endif
#include "caml/alloc.h"
#include "caml/backtrace.h"
#include "caml/callback.h"
#include "caml/custom.h"
#include "caml/debugger.h"
#include "caml/domain.h"
#include "caml/dynlink.h"
#include "caml/eventlog.h"
#include "caml/exec.h"
#include "caml/fail.h"
#include "caml/fix_code.h"
#include "caml/freelist.h"
#include "caml/gc_ctrl.h"
#include "caml/instrtrace.h"
#include "caml/interp.h"
#include "caml/intext.h"
#include "caml/io.h"
#include "caml/memory.h"
#include "caml/minor_gc.h"
#include "caml/misc.h"
#include "caml/mlvalues.h"
#include "caml/osdeps.h"
#include "caml/prims.h"
#include "caml/printexc.h"
#include "caml/reverse.h"
#include "caml/signals.h"
#include "caml/stacks.h"
#include "caml/sys.h"
#include "caml/startup.h"
#include "caml/startup_aux.h"
#include "caml/version.h"
#include "caml/instruct.h"
#include "caml/opnames.h"

char *opname(int ix)
{
  if (ix >= 0 && ix < FIRST_UNIMPLEMENTED_OP)
  return names_of_instructions [ix];
  else
    return "unknown";
}

/* Main entry point when loading code from a file */

static char * read_section(int fd, struct exec_trailer *trail, char *name)
{
  int32_t len;
  char * data;

  len = caml_seek_optional_section(fd, trail, name);
  if (len == -1) return NULL;
  data = (char *)caml_stat_alloc(len + 1);
  if (read(fd, data, len) != len)
    caml_fatal_error("error reading section %s", name);
  data[len] = 0;
  return data;
}

extern uint32_t code_rom[];
static char magicstr[EXEC_MAGIC_LENGTH+1];

static void fixup_endianness_trailer(uint32_t * p)
{
#ifndef ARCH_BIG_ENDIAN
  Reverse_32(p, p);
#endif
}

static int byte_read_trailer(int fd, struct exec_trailer *trail)
{
  if (lseek(fd, (long) -TRAILER_SIZE, SEEK_END) == -1)
    return BAD_BYTECODE;
  if (read(fd, (char *) trail, TRAILER_SIZE) < TRAILER_SIZE)
    return BAD_BYTECODE;
  fixup_endianness_trailer(&trail->num_sections);
  memcpy(magicstr, trail->magic, EXEC_MAGIC_LENGTH);
  magicstr[EXEC_MAGIC_LENGTH] = 0;

  return
    (strncmp(trail->magic, EXEC_MAGIC, sizeof(trail->magic)) == 0)
      ? 0 : WRONG_MAGIC;
}

int byte_caml_attempt_open(char_os **name, struct exec_trailer *trail,
                      int do_open_script)
{
  char_os * truename;
  int fd;
  int err;
  char buf [2], * u8;

  truename = caml_search_exe_in_path(*name);
  u8 = caml_stat_strdup_of_os(truename);
  caml_gc_message(0x100, "Opening bytecode executable %s\n", u8);
  caml_stat_free(u8);
  fd = open_os(truename, O_RDONLY);
  if (fd == -1) {
    caml_stat_free(truename);
    caml_gc_message(0x100, "Cannot open file\n");
    if (errno == EMFILE)
      return NO_FDS;
    else
      return FILE_NOT_FOUND;
  }
  if (!do_open_script) {
    err = read (fd, buf, 2);
    if (err < 2 || (buf [0] == '#' && buf [1] == '!')) {
      close(fd);
      caml_stat_free(truename);
      caml_gc_message(0x100, "Rejected #! script\n");
      return BAD_BYTECODE;
    }
  }
  err = byte_read_trailer(fd, trail);
  if (err != 0) {
    close(fd);
    caml_stat_free(truename);
    caml_gc_message(0x100, "Not a bytecode executable\n");
    return err;
  }
  *name = truename;
  return fd;
}

void byte_caml_load_code(int fd, asize_t len)
{
  caml_code_size = len;
  caml_start_code = (code_t) caml_stat_alloc(caml_code_size);
  if (read(fd, (char *) caml_start_code, caml_code_size) != caml_code_size)
    caml_fatal_error("truncated bytecode file");
  caml_init_code_fragments();
  /* Prepare the code for execution */
#ifdef ARCH_BIG_ENDIAN
  caml_fixup_endianness(caml_start_code, caml_code_size);
#endif
  for (int i = 0; i < caml_code_size; i++)
    {
    if (i < 16) fprintf(stderr, "Dumping caml_start_code[%d] = %d\n", i, caml_start_code[i]);
    code_rom[i] = (uint32_t) caml_start_code[i];
    }
  fprintf(stderr, "Loaded %zu bytes\n", caml_code_size);
}

CAMLexport void caml_bytecode(char *byte_name)
{
  int fd;
  struct exec_trailer trail;
  struct channel * chan;
  value res;
  char * req_prims;
  char_os * shared_lib_path, * shared_libs;
  
  fd = byte_caml_attempt_open(&byte_name, &trail, 1);

  if (fd < 0) {
    switch(fd) {
    case FILE_NOT_FOUND:
      fprintf(stderr, "cannot find file '%s'",
                       caml_stat_strdup_of_os(byte_name));
      break;
    case BAD_BYTECODE:
      fprintf(stderr, 
        "the file '%s' is not a bytecode executable file",
        caml_stat_strdup_of_os(byte_name));
      break;
    case WRONG_MAGIC:
      fprintf(stderr, 
        "the file '%s' has not the right magic number: "\
        "expected %s",
        caml_stat_strdup_of_os(byte_name),
        EXEC_MAGIC);
      break;
    }
  }
  /* Read the table of contents (section descriptors) */
  caml_read_section_descriptors(fd, &trail);
  /* Load the code */
  caml_code_size = caml_seek_section(fd, &trail, "CODE");
  byte_caml_load_code(fd, caml_code_size);
  /* Build the table of primitives */
  shared_lib_path = read_section(fd, &trail, "DLPT");
  shared_libs = read_section(fd, &trail, "DLLS");
  req_prims = read_section(fd, &trail, "PRIM");
  if (req_prims == NULL) caml_fatal_error("no PRIM section");
  caml_stat_free(shared_lib_path);
  caml_stat_free(shared_libs);
  caml_stat_free(req_prims);
    /* Load the globals */
  caml_seek_section(fd, &trail, "DATA");
  chan = caml_open_descriptor_in(fd);
  Lock(chan);
  /*
  caml_global_data = caml_input_val(chan);
  */
  Unlock(chan);
  caml_close_channel(chan); /* this also closes fd */
  caml_stat_free(trail.section);
}
