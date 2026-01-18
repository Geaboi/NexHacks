#ifndef IMU_PACKET_H
#define IMU_PACKET_H

#include <stdint.h>

// Packed to ensure byte-perfect alignment for BLE
typedef struct __attribute__((packed)) {
    uint16_t time_offset; // ms from start of packet
    int16_t acc_A[3];       // X, Y, Z
    int16_t gyro_A[3];      // X, Y, Z
    int16_t acc_B[3];       // X, Y, Z
    int16_t gyro_B[3];      // X, Y, Z
} imu_sample_t;

// Total size: 4 + (3 * 14) = 46 bytes. 
// Fits easily in one BLE packet if MTU > 50.
typedef struct __attribute__((packed)) {
    uint32_t seq_id;      // Packet sequence number (to detect dropped packets)
    imu_sample_t samples[3];
} ble_packet_t;

#endif