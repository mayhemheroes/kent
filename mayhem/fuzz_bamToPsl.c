/* In-process libFuzzer harness for the bamToPsl code path.
 *
 * bamToPsl is a raw file-input CLI (`bamToPsl in.bam out.psl`); driving it as a
 * subprocess yields essentially no coverage feedback.  This harness exercises the
 * exact same code path in-process: it hands the fuzzer bytes to htslib as a
 * BAM/SAM stream and runs the header-read + per-alignment bamToPslUnscored2()
 * conversion loop that bamToPsl.c's main() drives.
 *
 * kent's errAbort() exits the process on malformed input, which would look like a
 * crash to libFuzzer, so every call is wrapped in an errCatch (kent's setjmp-based
 * exception mechanism) exactly as the library expects.
 *
 * The upstream tool is an allocate-and-exit batch converter that intentionally
 * leaks (see the "memory leak" comments in bamToPsl.c); LeakSanitizer is therefore
 * disabled for this target, matching batch-tool semantics.
 */
#include "common.h"
#include "bamFile.h"
#include "psl.h"
#include "errCatch.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

const char *__asan_default_options(void)
{
return "detect_leaks=0";
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
char tmpl[] = "/tmp/bamfuzzXXXXXX";
int fd = mkstemp(tmpl);
if (fd < 0)
    return 0;
if (size > 0)
    {
    ssize_t w = write(fd, data, size);
    (void)w;
    }
close(fd);

struct errCatch *errCatch = errCatchNew();
if (errCatchStart(errCatch))
    {
    samfile_t *in = bamMustOpenLocal(tmpl, "rb", NULL);
    bam_header_t *head = sam_hdr_read(in);
    if (head != NULL)
        {
        bam1_t one;
        ZeroVar(&one);
        for (;;)
            {
            if (sam_read1(in, head, &one) < 0)
                break;
            if (one.core.n_cigar != 0)
                {
                struct psl *psl = bamToPslUnscored2(&one, head, TRUE);
                pslFree(&psl);
                }
            }
        if (one.data != NULL)
            free(one.data);
        bam_hdr_destroy(head);
        }
    samclose(in);
    }
errCatchEnd(errCatch);
errCatchFree(&errCatch);

unlink(tmpl);
return 0;
}
