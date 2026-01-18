#include "BLE.hpp"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "imu_packet.hpp"
#include "esp_log.h"

static const char* TAG = "IMU_SYSTEM";

QueueHandle_t ble_queue;
TaskHandle_t BLE_manager_task_handle;
SemaphoreHandle_t sensor_run_semaphore;

NimBLECharacteristic* statusChar;
NimBLECharacteristic* dataChar;

NimBLEAdvertising* initBLE() {
  // 2. Create Queue (Hold up to 10 packets)
  ble_queue = xQueueCreate(10, sizeof(ble_packet_t));
  sensor_run_semaphore = xSemaphoreCreateBinary();
  
  NimBLEDevice::init("SmartPT_Device");
  
  // Optional: Boost power for better range (ESP32-C6 supports up to +20dBm)
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);

  // Set security
  NimBLEDevice::setSecurityAuth(false, false, true); // bonding=false, mitm=false, sc=true (Secure Connections)
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT); // No input/output capability

  NimBLEServer *pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  pServer->advertiseOnDisconnect(true); // Automatically restart advertising on disconnect

  NimBLEService *pService = pServer->createService("181C");

  // Create all characteristics with callbacks
  MyCharCallbacks* charCallbacks = new MyCharCallbacks();
  
  // 0x0000 - status characteristic (app writes to this to trigger timer starts and stops)
  statusChar = pService->createCharacteristic(
                    "0000",
                    NIMBLE_PROPERTY::WRITE
                  );
  statusChar->setCallbacks(charCallbacks);

  // 0x0003 - Auth Confirmation (READ + NOTIFY)
  dataChar = pService->createCharacteristic(
                          "0003",
                          NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
                        );
  dataChar->createDescriptor("2902"); // Add BLE2902 descriptor for notifications

  xTaskCreate(ble_task, "BLE", 8192, NULL, 5, &BLE_manager_task_handle);
  // Start
  pService->start();
  
  NimBLEAdvertising *pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->addServiceUUID("181C");
  pAdvertising->setName("SmartPT_Device");
  pAdvertising->enableScanResponse(true);
  pAdvertising->setPreferredParams(0x06, 0x12);  // Connection interval preferences
  pAdvertising->start();

  printf("BLE Started. Waiting...\n");

  return pAdvertising;
}

void MyServerCallbacks::onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) {
  printf("Client connected\n");
};

void MyServerCallbacks::onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) {
  printf("Client disconnected - reason: %d\n", reason);
  deInitialize();
}

void MyCharCallbacks::onRead(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo) {
  printf("Characteristic Read\n");
}

void MyCharCallbacks::onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo) {
  std::string val = pChar->getValue();
  std::string uuidStr = pChar->getUUID().toString();

  printf("onWrite called! UUID: %s, Value length: %d\n", uuidStr.c_str(), val.length());
  
  if (pChar == statusChar) {
    if (val == "Start") {
      printf("Starting sensor task\n");
      xSemaphoreGive(sensor_run_semaphore);
    } else if (val == "Stop") {
      printf("Stopping sensor task\n");
      xSemaphoreTake(sensor_run_semaphore, pdMS_TO_TICKS(50));
    }
  }
}

void ble_task(void *pvParameters) {
  ble_packet_t received_packet;
  
  while (1) {
    // Event driven infinite wait, doesn't block other tasks.
    if (xQueueReceive(ble_queue, &received_packet, portMAX_DELAY) == pdTRUE) {
      if (NimBLEDevice::getServer()->getConnectedCount() > 0) {
        // 3. Set the raw bytes of the struct as the characteristic value
        // (uint8_t*) cast treats the struct memory as a raw byte array
        dataChar->setValue((uint8_t*)&received_packet, sizeof(ble_packet_t));

        // 4. Push the notification
        dataChar->notify();

        // Debug: Only log occasionally or on specific sequence numbers to avoid spamming Serial
        if (received_packet.seq_id % 100 == 0) {
            ESP_LOGI(TAG, "Sent Packet Seq #%lu", received_packet.seq_id);
        }
      }
    }
  }
}