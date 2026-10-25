#ifndef ASAHIRO_H
#define ASAHIRO_H

#include <stdbool.h>
#include <stdint.h>

// requests and responses are json strings, see core/src/lib.rs
typedef void (*asahiro_event_cb)(void *ctx, const char *event);

char *asahiro_call(const char *request);
uint64_t asahiro_spawn(const char *request, asahiro_event_cb callback, void *ctx);
void asahiro_cancel(uint64_t task);
void asahiro_pause(uint64_t task, bool paused);
void asahiro_free(char *s);

#endif
