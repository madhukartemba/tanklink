#pragma once

#include "sdkconfig.h"

/** Tank node firmware version (LoRa packet, logs, BLE Info). */
#define TANK_FW_MAJOR 0
#define TANK_FW_MINOR 3
#define TANK_FW_PATCH 2
#define TANK_STR_(x) #x
#define TANK_STR(x) TANK_STR_(x)
#define TANK_FW_VERSION_STR \
    TANK_STR(TANK_FW_MAJOR) "." TANK_STR(TANK_FW_MINOR) "." TANK_STR(TANK_FW_PATCH)

/** Board revision of this build (Kconfig TANK_HW_REV). */
#define TANK_HW_REV CONFIG_TANK_HW_REV
