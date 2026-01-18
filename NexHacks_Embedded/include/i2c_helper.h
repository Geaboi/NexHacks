#ifndef I2C_HELPER_H
#define I2C_HELPER_H
#include "esp_err.h"
#include "stdint.h"

#ifdef __cplusplus
extern "C" {
#endif

#define I2C_MASTER_SCL_IO           23    // XIAO ESP32C6: D5/GPIO23 = SCL
#define I2C_MASTER_SDA_IO           22    // XIAO ESP32C6: D4/GPIO22 = SDA
#define I2C_MASTER_NUM              0     // I2C Port 0
#define I2C_MASTER_FREQ_HZ          400000 // 400kHz (Fast Mode)
#define I2C_MASTER_TX_BUF_DISABLE   0
#define I2C_MASTER_RX_BUF_DISABLE   0
#define I2C_MASTER_TIMEOUT_MS       1000

#define MPU_ADDR_A                  0x68
#define MPU_ADDR_B                  0x69
#define REG_PWR_MGMT_1              0x6B
#define REG_ACCEL_XOUT_H            0x3B

esp_err_t i2c_master_init();
esp_err_t mpu6050_write_byte(uint8_t addr, uint8_t reg, uint8_t data);
esp_err_t mpu6050_read_burst(uint8_t addr, uint8_t start_reg, uint8_t *buffer, size_t len);

#ifdef __cplusplus
}
#endif

#endif