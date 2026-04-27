// kht_bridge_logging.cpp — C logging callback implementation
#include "kht_bridge_logging.h"

static KHTLogHandler g_logHandler = nullptr;

void kht_bridge_set_log_handler(KHTLogHandler handler) {
    g_logHandler = handler;
}

KHTLogHandler kht_bridge_get_log_handler(void) {
    return g_logHandler;
}
