// logging_impl.hpp — Internal logging macros for C++ code, using the C callback
#pragma once

#include "kht_bridge_logging.h"
#include <cstdio>
#include <cstdarg>
#include <cstring>

// Format and dispatch to the registered log handler.
// If no handler is set, messages are silently dropped.
static inline void kht_log_formatted(const char *level, const char *file,
                                     const char *function, int line,
                                     const char *fmt, ...) {
    KHTLogHandler handler = kht_bridge_get_log_handler();
    if (!handler) return;

    char buf[2048];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    handler(buf, level, file, function, line);
}

#define Log_v(fmt, ...) kht_log_formatted("verbose", __FILE__, __PRETTY_FUNCTION__, __LINE__, fmt, ##__VA_ARGS__)
#define Log_d(fmt, ...) kht_log_formatted("debug",   __FILE__, __PRETTY_FUNCTION__, __LINE__, fmt, ##__VA_ARGS__)
#define Log_i(fmt, ...) kht_log_formatted("info",    __FILE__, __PRETTY_FUNCTION__, __LINE__, fmt, ##__VA_ARGS__)
#define Log_w(fmt, ...) kht_log_formatted("warn",    __FILE__, __PRETTY_FUNCTION__, __LINE__, fmt, ##__VA_ARGS__)
#define Log_e(fmt, ...) kht_log_formatted("error",   __FILE__, __PRETTY_FUNCTION__, __LINE__, fmt, ##__VA_ARGS__)

// Catch blocks for C++ bridge functions.
// cv::Exception inherits from std::exception, so we catch everything.
// Usage: try { ... } KHT_CATCH_LOG("func_name") return default_value;
#define KHT_CATCH_LOG(func) \
    catch (const std::exception& e) { Log_e("%s: C++ exception: %s", func, e.what()); } \
    catch (...) { Log_e("%s: unknown C++ exception", func); }
