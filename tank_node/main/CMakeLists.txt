idf_component_register(
    SRCS
        "main.c"
        "tank_board.c"
        "tank_battery.c"
        "tank_led.c"
        "tank_link.c"
    INCLUDE_DIRS "."
    REQUIRES
        nvs_flash
        driver
        esp_driver_ledc
        esp_adc
        esp_timer
        esp_hw_support
        tanklink_lora
)
