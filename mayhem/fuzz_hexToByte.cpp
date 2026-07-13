#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern "C" unsigned char hexToByte(char *hex);

/* hexToByte() reads exactly two hex characters, so feed it a NUL-terminated
 * buffer of at least two bytes (its documented contract — every in-tree caller
 * passes a >=2-char buffer).  Shorter inputs would make it read past the end,
 * which is a harness precondition violation, not a target bug. */
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 2)
        return 0;
    char *cstr = (char *)malloc(size + 1);
    if (cstr == NULL)
        return 0;
    memcpy(cstr, data, size);
    cstr[size] = '\0';
    hexToByte(cstr);
    free(cstr);
    return 0;
}
