idf_component_register(
    SRCS "sx1278.c" "tanklink_crypto.c"
    INCLUDE_DIRS "include"
    REQUIRES driver esp_driver_gpio esp_driver_spi esp_timer bt
)
