/*
 * Host test for BootWdt/UniXNUBootWdtArgs.h: the very header the firmware
 * compiles, with the handful of EDK2 types it uses mapped onto libc.
 *
 * Exits 0 and prints "TEST PASS" only if every check holds.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned long  UINTN;
typedef char           CHAR8;
typedef int            BOOLEAN;
#define TRUE   1
#define FALSE  0
#define STATIC static
#define CONST  const
#define IN
#define CompareMem(a, b, n)  memcmp ((a), (b), (n))

#include "UniXNUBootWdtArgs.h"

#define WORD  "unixnu.wdt=0"
#define WLEN  12

static int  gFail;

static int
IsSep (char c)
{
  return c == ' ' || c == '\t' || c == '\n';
}

/* Independent reference: C-string semantics, split, compare. */
static int
Ref (const char *a, size_t len, const char *word)
{
  size_t  n = 0, i = 0, wl = strlen (word);

  while (n < len && a[n] != '\0') {
    n++;
  }

  while (i < n) {
    size_t  s;
    while (i < n && IsSep (a[i])) {
      i++;
    }

    s = i;
    while (i < n && !IsSep (a[i])) {
      i++;
    }

    if (i > s && (i - s) == wl && memcmp (a + s, word, wl) == 0) {
      return 1;
    }
  }

  return 0;
}

/*
 * The input is copied into a heap block of exactly len bytes, so that built
 * with -fsanitize=address any read of Args[len] or beyond is caught.
 */
static int
Call (const char *a, size_t len)
{
  char  *p = malloc (len != 0 ? len : 1);
  int   r;

  if (a != NULL && len != 0) {
    memcpy (p, a, len);
  }

  r = BootArgsHasWord (a == NULL ? NULL : p, len, WORD, WLEN) ? 1 : 0;
  free (p);
  return r;
}

static void
Expect (const char *what, const char *a, size_t len, int want)
{
  int  got = Call (a, len);

  if (got != want) {
    printf ("FAIL %-34s want %d got %d\n", what, want, got);
    gFail++;
  }
}

#define S(str)  (str), sizeof (str)          /* with the NUL, like an FDT property */
#define N(str)  (str), (sizeof (str) - 1)    /* without it */

int
main (void)
{
  unsigned long  it;
  char           buf[96];

  /* hits */
  Expect ("only the word",               S ("unixnu.wdt=0"), 1);
  Expect ("only the word, no NUL",       N ("unixnu.wdt=0"), 1);
  Expect ("word first",                  S ("unixnu.wdt=0 console=null"), 1);
  Expect ("word last",                   S ("console=null unixnu.wdt=0"), 1);
  Expect ("word in the middle",          S ("a unixnu.wdt=0 b"), 1);
  Expect ("word last, no NUL",           N ("console=null unixnu.wdt=0"), 1);
  Expect ("tab separated",               S ("a\tunixnu.wdt=0\tb"), 1);
  Expect ("newline separated",           S ("a\nunixnu.wdt=0\n"), 1);
  Expect ("repeated separators",         S ("   unixnu.wdt=0   "), 1);
  Expect ("later duplicate",             S ("unixnu.wdt=00 unixnu.wdt=0"), 1);

  /* misses that only a whole-word match gets right */
  Expect ("longer value",                S ("unixnu.wdt=00"), 0);
  Expect ("longer value + more",         S ("a unixnu.wdt=0x b"), 0);
  Expect ("prefixed",                    S ("xunixnu.wdt=0"), 0);
  Expect ("dotted prefix",               S ("my.unixnu.wdt=0"), 0);
  Expect ("other value",                 S ("unixnu.wdt=1"), 0);
  Expect ("no value",                    S ("unixnu.wdt="), 0);
  Expect ("no equals",                   S ("unixnu.wdt"), 0);
  Expect ("one char short",              N ("unixnu.wdt="), 0);
  Expect ("empty",                       S (""), 0);
  Expect ("only blanks",                 S ("   "), 0);
  Expect ("zero length",                 "", 0, 0);
  Expect ("NULL, zero length",           NULL, 0, 0);

  /* an empty word never matches, not even the gap between two blanks */
  if (BootArgsHasWord ("a  b", 5, "", 0)) {
    printf ("FAIL empty word matched\n");
    gFail++;
  }

  /* C-string semantics: nothing after the first NUL counts */
  Expect ("after an embedded NUL",       "a\0unixnu.wdt=0", 15, 0);
  Expect ("word then NUL then junk",     "unixnu.wdt=0\0zzz", 17, 1);
  Expect ("NUL right before the word",   "\0unixnu.wdt=0", 14, 0);

  /* random comparison against the independent reference */
  srand (12345);
  for (it = 0; it < 400000; it++) {
    static const char  alpha[] = { 'u', 'n', 'i', 'x', '.', 'w', 'd', 't', '=', '0', '1', ' ', ' ', '\t', '\n', 0 };
    size_t             len = (size_t)(rand () % 40), i, pos = 0;
    int                want, got;

    memset (buf, 0, sizeof (buf));
    for (i = 0; i < len; i++) {
      buf[i] = alpha[rand () % sizeof (alpha)];
    }

    if (rand () % 3 == 0) {
      /* plant the word, sometimes glued to a neighbour, sometimes clean */
      pos = (size_t)(rand () % (int)(len + 1));
      if (pos + WLEN < sizeof (buf) - 2) {
        memcpy (buf + pos, WORD, WLEN);
        if (len < pos + WLEN) {
          len = pos + WLEN;
        }

        if (rand () % 2) {
          if (pos > 0) {
            buf[pos - 1] = ' ';
          }

          if (len > pos + WLEN) {
            buf[pos + WLEN] = (rand () % 2) ? ' ' : '\0';
          }
        }
      }
    }

    want = Ref (buf, len, WORD);
    got  = Call (buf, len);
    if (want != got) {
      printf ("FAIL random #%lu len %zu want %d got %d: ", it, len, want, got);
      for (i = 0; i < len; i++) {
        printf (buf[i] >= 32 ? "%c" : "\\x%02x", (unsigned char)buf[i]);
      }

      printf ("\n");
      if (++gFail > 10) {
        break;
      }
    }
  }

  if (gFail != 0) {
    printf ("%d failure(s)\n", gFail);
    return 1;
  }

  printf ("TEST PASS\n");
  return 0;
}
