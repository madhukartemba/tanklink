idf_component_register(
    SRCS
        "main.c"
        "tank_board.c"
        "tank_battery.c"
        "tank_link.c"
    INCLUDE_DIRS "."
    REQUIRES
        nvs_flash
        driver
        esp_adc
        esp_timer
        tanklink_lora
)
