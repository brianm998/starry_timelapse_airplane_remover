// kht_bridge_logging.h — Pure C logging interface replacing ObjC LoggingObjC
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Log levels as C strings: "verbose", "debug", "info", "warn", "error"
typedef void (*KHTLogHandler)(const char *message,
                              const char *level,
                              const char *file,
                              const char *function,
                              int line);

void kht_bridge_set_log_handler(KHTLogHandler handler);
KHTLogHandler kht_bridge_get_log_handler(void);

#ifdef __cplusplus
}
#endif
