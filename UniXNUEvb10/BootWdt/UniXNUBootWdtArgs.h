/** @file
  Word search in a kernel-style command line, kept free of firmware services so
  that the host test (tests/bootwdt-args) compiles this very file.

  Copyright (c) 2026, UniXNU contributors. All rights reserved.
  SPDX-License-Identifier: BSD-2-Clause-Patent
**/

#ifndef UNIXNU_BOOT_WDT_ARGS_H_
#define UNIXNU_BOOT_WDT_ARGS_H_

/**
  Is Word one of the words of Args?

  Words are separated by space, tab or newline. Args is what an FDT property
  hands out: Length bytes, normally ending in a NUL. Like a C string, it ends at
  the first NUL, whatever follows is not part of the command line. A word has to
  match completely: "unixnu.wdt=0" is neither found in "unixnu.wdt=00" nor in
  "x.unixnu.wdt=0".

  @param[in] Args        Command line bytes (may be NULL when Length is 0).
  @param[in] Length      Number of valid bytes in Args.
  @param[in] Word        Word to look for.
  @param[in] WordLength  Length of Word, without a terminating NUL.

  @retval TRUE   Word is one of the words of Args.
  @retval FALSE  It is not.
**/
STATIC
BOOLEAN
BootArgsHasWord (
  IN CONST CHAR8  *Args,
  IN UINTN        Length,
  IN CONST CHAR8  *Word,
  IN UINTN        WordLength
  )
{
  UINTN  Start;
  UINTN  Index;

  if ((WordLength == 0) || (Args == NULL)) {
    return FALSE;
  }

  Start = 0;
  for (Index = 0; Index <= Length; Index++) {
    if ((Index == Length) ||
        (Args[Index] == '\0') || (Args[Index] == ' ') || (Args[Index] == '\t') || (Args[Index] == '\n'))
    {
      if (((Index - Start) == WordLength) && (CompareMem (&Args[Start], Word, WordLength) == 0)) {
        return TRUE;
      }

      if ((Index < Length) && (Args[Index] == '\0')) {
        return FALSE;
      }

      Start = Index + 1;
    }
  }

  return FALSE;
}

#endif
