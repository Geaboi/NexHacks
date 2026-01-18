#include "i2c_helper.h"
#include "driver/i2c.h"

/**
 * @brief Initialize the ESP32-C6 I2C Master Interface
 */
esp_err_t i2c_master_init() {
  i2c_config_t conf = {
    .mode = I2C_MODE_MASTER,
    .sda_io_num = I2C_MASTER_SDA_IO,
    .scl_io_num = I2C_MASTER_SCL_IO,
    .sda_pullup_en = GPIO_PULLUP_ENABLE, // Internal pullups (Use external 2.2k if possible)
    .scl_pullup_en = GPIO_PULLUP_ENABLE,
    .master.clk_speed = I2C_MASTER_FREQ_HZ,
  };
  i2c_param_config(I2C_MASTER_NUM, &conf);
  return i2c_driver_install(I2C_MASTER_NUM, conf.mode, 0, 0, 0);
}

/**
 * @brief Write a single byte to a register (Used for waking up MPU)
 */
esp_err_t mpu6050_write_byte(uint8_t addr, uint8_t reg, uint8_t data) {
  i2c_cmd_handle_t cmd = i2c_cmd_link_create();
  i2c_master_start(cmd);
  i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_WRITE, true);
  i2c_master_write_byte(cmd, reg, true);
  i2c_master_write_byte(cmd, data, true);
  i2c_master_stop(cmd);
  esp_err_t ret = i2c_master_cmd_begin(I2C_MASTER_NUM, cmd, pdMS_TO_TICKS(I2C_MASTER_TIMEOUT_MS));
  i2c_cmd_link_delete(cmd);
  return ret;
}

/**
 * @brief Read multiple bytes in one go (Burst Read)
 * This is the critical function for speed.
 */
esp_err_t mpu6050_read_burst(uint8_t addr, uint8_t start_reg, uint8_t *buffer, size_t len) {
  i2c_cmd_handle_t cmd = i2c_cmd_link_create();
  
  // 1. Write the register address we want to start reading from
  i2c_master_start(cmd);
  i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_WRITE, true);
  i2c_master_write_byte(cmd, start_reg, true);
  
  // 2. Restart and Read N bytes
  i2c_master_start(cmd);
  i2c_master_write_byte(cmd, (addr << 1) | I2C_MASTER_READ, true);
  if (len > 1) {
    i2c_master_read(cmd, buffer, len - 1, I2C_MASTER_ACK);
  }
  i2c_master_read_byte(cmd, buffer + len - 1, I2C_MASTER_NACK); // Last byte gets NACK
  i2c_master_stop(cmd);
  
  // 3. Execute the transaction
  esp_err_t ret = i2c_master_cmd_begin(I2C_MASTER_NUM, cmd, pdMS_TO_TICKS(I2C_MASTER_TIMEOUT_MS));
  i2c_cmd_link_delete(cmd);
  return ret;
}