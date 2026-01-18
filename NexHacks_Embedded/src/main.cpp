#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "imu_packet.hpp"
#include "i2c_helper.h"
#include "esp_log.h"
#include "sensor.hpp"
#include "BLE.hpp"

static const char* TAG = "IMU_SYSTEM";

void mainfunc() {
  // 1. Init I2C
  ESP_ERROR_CHECK(i2c_master_init());
  ESP_LOGI(TAG, "I2C Initialized");

  // 3. Start Tasks
  // Sensor Task: Priority 10 (High)
  // BLE Task: Priority 5 (Medium)
  xTaskCreate(sensor_task, "SensorTask", 4096, NULL, 10, NULL);
  initBLE();
}

void testGyro() {
    // 1. Initialize I2C (Critical: app_main hasn't called it yet)
    // We use the helper from i2c_handler.c
    ESP_ERROR_CHECK(i2c_master_init());
    ESP_LOGI("TEST", "I2C Initialized successfully");

    // 2. Wake up Sensor A (0x68)
    // Register 0x6B (PWR_MGMT_1) must be 0 to wake it up
    esp_err_t retA = mpu6050_write_byte(MPU_ADDR_A, REG_PWR_MGMT_1, 0x00);
    if (retA == ESP_OK) {
        ESP_LOGI("TEST", "Sensor A (0x68) Woken Up");
    } else {
        ESP_LOGE("TEST", "Failed to wake Sensor A! Check wiring.");
    }

    // 3. Wake up Sensor B (0x69)
    esp_err_t retB = mpu6050_write_byte(MPU_ADDR_B, REG_PWR_MGMT_1, 0x00);
    if (retB == ESP_OK) {
        ESP_LOGI("TEST", "Sensor B (0x69) Woken Up");
    } else {
        ESP_LOGE("TEST", "Failed to wake Sensor B! Check AD0 pin is 3.3V.");
    }

    // 4. Test Loop
    uint8_t data[14]; // Buffer for raw data
    while (1) {
        printf("\n--- Reading Sensors ---\n");

        // --- READ SENSOR A ---
        if (mpu6050_read_burst(MPU_ADDR_A, REG_ACCEL_XOUT_H, data, 14) == ESP_OK) {
            // Convert Big Endian bytes to Signed Int16
            // Gyro X is at index 8 and 9
            int16_t gyroX = (int16_t)((data[8] << 8) | data[9]);
            int16_t gyroY = (int16_t)((data[10] << 8) | data[11]);
            int16_t gyroZ = (int16_t)((data[12] << 8) | data[13]);
            int16_t accX  = (int16_t)((data[0] << 8) | data[1]);

            printf("SENSOR A [0x68] | AccX: %6d | Gyro X:%6d  Y:%6d  Z:%6d\n", accX, gyroX, gyroY, gyroZ);
        } else {
            printf("SENSOR A [0x68] | READ ERROR \n");
        }

        // --- READ SENSOR B ---
        if (mpu6050_read_burst(MPU_ADDR_B, REG_ACCEL_XOUT_H, data, 14) == ESP_OK) {
            int16_t gyroX = (int16_t)((data[8] << 8) | data[9]);
            int16_t gyroY = (int16_t)((data[10] << 8) | data[11]);
            int16_t gyroZ = (int16_t)((data[12] << 8) | data[13]);
            int16_t accX  = (int16_t)((data[0] << 8) | data[1]);

            printf("SENSOR B [0x69] | AccX: %6d | Gyro X:%6d  Y:%6d  Z:%6d\n", accX, gyroX, gyroY, gyroZ);
        } else {
            printf("SENSOR B [0x69] | READ ERROR (Check connection)\n");
        }

        vTaskDelay(pdMS_TO_TICKS(500)); // Slow down for readability
    }
}

extern "C" void app_main(void) {
  // testGyro();
  mainfunc();
}