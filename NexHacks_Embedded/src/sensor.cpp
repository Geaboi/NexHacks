#include "sensor.hpp"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "imu_packet.hpp"
#include "i2c_helper.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "BLE.hpp"

#define DUAL_SENSOR 1

static const char* TAG = "IMU_SYSTEM";
uint64_t session_start;

void sensor_task(void *pvParameters) {
  ble_packet_t packet_buffer;

  // Wake up sensors
  mpu6050_write_byte(MPU_ADDR_A, REG_PWR_MGMT_1, 0x00);
  #if DUAL_SENSOR
  mpu6050_write_byte(MPU_ADDR_B, REG_PWR_MGMT_1, 0x00);
  #endif
  
  // Optional: Configure Range (e.g., +/- 2000 deg/s) here if needed

  const TickType_t xFrequency = pdMS_TO_TICKS(10); // 10ms = 100Hz
      
  uint8_t raw_data[14];

  while (1) {
    int sample_index = 0;
    uint32_t sequence_counter = 0;

    // Block until semaphore is given
    xSemaphoreTake(sensor_run_semaphore, portMAX_DELAY);
    
    // Give it back immediately so BLE can take it to stop
    xSemaphoreGive(sensor_run_semaphore);
    
    // Reset timing reference when starting
    TickType_t xLastWakeTime = xTaskGetTickCount();
    
    // Running state - tight loop with precise timing
    while (uxSemaphoreGetCount(sensor_run_semaphore) > 0) {
      vTaskDelayUntil(&xLastWakeTime, xFrequency);
    
      uint64_t now_us = esp_timer_get_time();

      // 1. Read Sensor A and copy to packet buffer
      esp_err_t retA = mpu6050_read_burst(MPU_ADDR_A, REG_ACCEL_XOUT_H, raw_data, 14);

      memcpy(packet_buffer.samples[sample_index].acc_A, &raw_data[0], 6);
      memcpy(packet_buffer.samples[sample_index].gyro_A, &raw_data[8], 6);
                                          
      // 2. Read Sensor B and copy to packet buffer
      #if DUAL_SENSOR
      esp_err_t retB = mpu6050_read_burst(MPU_ADDR_B, REG_ACCEL_XOUT_H, raw_data, 14);
      #else
      esp_err_t retB = mpu6050_read_burst(MPU_ADDR_A, REG_ACCEL_XOUT_H, raw_data, 14);
      #endif

      memcpy(packet_buffer.samples[sample_index].acc_B, &raw_data[0], 6);
      memcpy(packet_buffer.samples[sample_index].gyro_B, &raw_data[8], 6);

      if (retA == ESP_OK && retB == ESP_OK) {
        // Calculate time offset in ms
        packet_buffer.samples[sample_index].time_offset = (uint16_t)((now_us - session_start) / 1000);
        
        sample_index++;

        // 3. Buffer Full? Push to Queue.
        if (sample_index >= 3) {
          packet_buffer.seq_id = sequence_counter++;
          
          // Send copy of packet to BLE task
          // timeout=0 means "don't block if queue is full, just drop it" (real-time preference)
          xQueueSend(ble_queue, &packet_buffer, 0);
          
          sample_index = 0; // Reset
        }
      } else {
        ESP_LOGE(TAG, "I2C Read Failed");
      } // End of running loop
    }
  } // End of outer loop
}