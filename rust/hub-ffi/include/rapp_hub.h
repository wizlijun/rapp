// The hub in-process (spec 2026-11-17-rapp-ipad-duo-design §6.1). JSON lines, same as rapp-hub's stdin/stdout.
#pragma once
#include <stdint.h>

// Starts the hub on its own tokio runtime. on_line is called on a hub thread, once per line (no newline);
// the line is the callee's: it may read it after returning (Dart's NativeCallable.listener does) and must
// free it with rapp_hub_free_line.
// name is the device name B introduces itself with. When the hub ends (normally or on error; the error is
// in hub.log first) on_line is called once more with NULL, and rapp_hub_send then returns -3.
// After the hub ended on its own, start keeps returning -1 until the caller calls rapp_hub_stop (call it on
// seeing NULL, but from another thread: never call rapp_hub_stop from inside on_line, and on_line must not
// block waiting on the thread that calls rapp_hub_stop).
// 0 ok; -1 already running; -2 bad args (NULL / not UTF-8); -3 the runtime could not start.
int32_t rapp_hub_start(const char *home, const char *log_dir, const char *name, void (*on_line)(const char *line));
// Frees a line on_line handed over. NULL is ignored.
void    rapp_hub_free_line(char *line);
// Sends one command line (a trailing newline is optional). Any thread.
// 0 ok; -1 not started; -2 bad text; -3 the hub has exited.
int32_t rapp_hub_send(const char *line);
// Like closing stdin: the hub closes all sessions and ends (waits at most 2 s; afterwards no on_line call is pending). Nothing when not running.
void rapp_hub_stop(void);
