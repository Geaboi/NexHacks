#ifndef BLE_H
#define BLE_H
#include "NimBLEDevice.h"

#include "freertos/queue.h"
#include "freertos/semphr.h"

extern QueueHandle_t ble_queue;
extern TaskHandle_t BLE_manager_task_handle;
extern SemaphoreHandle_t sensor_run_semaphore;

class MyServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo);
  void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason);
};

class MyCharCallbacks : public NimBLECharacteristicCallbacks {
  void onRead(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo);
  void onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo);
};

NimBLEAdvertising* initBLE();
void ble_task(void *pvParameters);

#endif