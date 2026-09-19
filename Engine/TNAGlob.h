#ifndef TNAGLOB_H
#define TNAGLOB_H

#include <stdbool.h>
#include <stddef.h>

// 大小写敏感的 glob：'*' 任意串、'?' 单字符，顶层 '|' 分隔多个候选。
bool TNAMatchGlob(const char *name, const char *pattern);

#endif
