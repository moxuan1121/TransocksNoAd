#include "ZNAGlob.h"
#include <string.h>

static bool ZNAGlobSegment(const char *name, const char *pattern, size_t length) {
    while (length) {
        if (pattern[0] == '*') {
            pattern++;
            length--;
            if (!length) return true;
            for (;;) {
                if (ZNAGlobSegment(name, pattern, length)) return true;
                if (!*name) return false;
                name++;
            }
        }
        if (!*name) return false;
        if (pattern[0] != '?' && pattern[0] != *name) return false;
        name++;
        pattern++;
        length--;
    }
    return *name == '\0';
}

bool ZNAMatchGlob(const char *name, const char *pattern) {
    if (!name || !pattern) return false;
    for (;;) {
        const char *bar = strchr(pattern, '|');
        size_t length = bar ? (size_t)(bar - pattern) : strlen(pattern);
        if (ZNAGlobSegment(name, pattern, length)) return true;
        if (!bar) return false;
        pattern = bar + 1;
    }
}
