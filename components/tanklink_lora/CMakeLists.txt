idf_component_register(
    SRCS "sx1278.c"
    INCLUDE_DIRS "include"
    REQUIRES driver esp_driver_gpio esp_driver_spi esp_timer
)
