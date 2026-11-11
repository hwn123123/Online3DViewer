#pragma once
#include <stddef.h>
// All callbacks return codes; no C++ exception or Rust unwind crosses this API.
// Events 0–3 contain doubles. Event 4 contains a UTF-8 error message.
typedef int (*O3DVCadTextEmit)(void *,int,const void *,size_t);
typedef int (*O3DVCadTextCheck)(void *,size_t);
int O3DVCadLayoutText(const unsigned char *,size_t,void *,O3DVCadTextEmit,void *,O3DVCadTextCheck);
void O3DVCadClearTextCache();
