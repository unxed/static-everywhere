/* report_fixtures.h — six ob_report fixtures shared between t_report.c (the
 * comparison tests) and the one-off golden-file generator. Task 8's real
 * checks do not exist yet, so these are hand-built the way a check WOULD
 * populate a report, to prove the report/reporter machinery itself before
 * anything is wired to real ELF data. 00-AGENT-TASK.md Task 7's gate:
 * "Golden files exist for at least six fixtures and match byte-for-byte."
 */
#ifndef TESTS_REPORT_FIXTURES_H
#define TESTS_REPORT_FIXTURES_H

#include "audit/report.h"

/* Every fixture_* function fills `r` (already ob_report_init'd by the
 * caller) but does NOT call ob_report_finalize — callers differ on whether
 * a baseline is involved. `baseline_out`, if non-NULL, receives a baseline
 * to finalize against (only fixture_baseline_suppressed uses it; every
 * other fixture leaves *baseline_out untouched and the caller passes NULL
 * to ob_report_finalize). */

/* 1. Reproduces 01-SPEC-audit.md §9.1/§9.2's own worked example verbatim —
 * the closest thing to an independently-specified golden case this project
 * has. */
void fixture_hybrid_ok(ob_report *r);

/* 2. Profile S: no interp, no needed, no glibc requirement at all (glibc
 * baseline not even checked, since there's nothing dynamic to check it
 * against) — exercises every "null"/"[]" branch of the schema at once. */
void fixture_static_clean(ob_report *r);

/* 3. Profile M: a plugin with no soname, needing only libc. */
void fixture_module(ob_report *r);

/* 4. Two warnings; a baseline (written by the caller to `baseline_path`,
 * which this function also creates on disk) suppresses one of them,
 * leaving one visible finding and "suppressed": 1. */
void fixture_baseline_suppressed(ob_report *r, const char *baseline_path,
                                  ob_baseline *bl);

/* 5. Five DT_NEEDED entries — length >= 4, so 01-SPEC-audit.md §9.2's array
 * layout rule (this project's documented choice, NOTES.md) renders it one
 * element per line instead of inline. */
void fixture_many_needed(ob_report *r);

/* 6. A DT_NEEDED entry containing bytes outside 0x20..0x7E, so the golden
 * output must show "?" replacement and " [sanitised]" end to end, and the
 * JSON writer's escaping is exercised on real (if synthetic) audit data
 * rather than only on util/json.c's own unit tests. */
void fixture_sanitized(ob_report *r);

#endif /* TESTS_REPORT_FIXTURES_H */
