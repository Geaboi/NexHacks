#ifndef SENSOR_H
#define SENSOR_H

#include <atomic>

void sensor_task(void *pvParameters);
extern uint64_t session_start;

#endif