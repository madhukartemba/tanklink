idf_component_register(
    SRCS
        "main.c"
        "board.c"
        "buzzer.c"
        "status_led.cpp"
        "pump_config.c"
        "pump_pair.c"
        "pump_ota.c"
        "gatt_svr.c"
        "lora_link.c"
        "relay_control.c"
    INCLUDE_DIRS "."
    REQUIRES nvs_flash bt led_strip driver esp_timer app_update PixelEngine
)
