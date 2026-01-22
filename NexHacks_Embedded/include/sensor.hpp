#ifndef SENSOR_H
#define SENSOR_H

#include <atomic>

#define MPU_ADDR_A                  0x68
#define MPU_ADDR_B                  0x69
#define REG_PWR_MGMT_1              0x6B
#define REG_ACCEL_XOUT_H            0x3B

void sensor_task(void *pvParameters);
extern uint64_t session_start;

#endif