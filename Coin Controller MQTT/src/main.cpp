#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <esp_system.h>

const int coinPin = 14;
const int acceptorEnablePin = 26;
const bool acceptorEnabledLevel = HIGH;
const unsigned long acceptorOpenDelayMs = 100;
const unsigned long sessionLeaseTimeoutMs = 15000;

const char* bleBaseName = "PisoCoin";
const char* serviceUuid = "91f05e10-0000-4f9c-bb88-5a9f6d770001";
const char* commandCharacteristicUuid = "91f05e10-0000-4f9c-bb88-5a9f6d770002";
const char* statusCharacteristicUuid = "91f05e10-0000-4f9c-bb88-5a9f6d770003";

Preferences prefs;
BLEServer* bleServer = nullptr;
BLECharacteristic* statusCharacteristic = nullptr;
bool clientConnected = false;
int connectedClientCount = 0;
bool acceptorOpen = false;
bool acceptorOpenPending = false;
unsigned long acceptorOpenRequestedAt = 0;
unsigned long lastOwnerHeartbeatAt = 0;
volatile int pulses = 0;
volatile unsigned long lastPulseTime = 0;
String controllerId;
String bluetoothName;
String activeLauncherDeviceId = "";
String activeLauncherDeviceName = "";

void restartAdvertising(const char* reason) {
  BLEAdvertising* advertising = bleServer != nullptr
      ? bleServer->getAdvertising()
      : BLEDevice::getAdvertising();

  if (advertising == nullptr) {
    Serial.println(
      String("[CoinController BLE] Advertising restart skipped: ") + reason +
      " (advertising unavailable)"
    );
    return;
  }

  advertising->start();
  Serial.println(
    String("[CoinController BLE] Advertising active: ") + reason
  );
}

String buildControllerId() {
  uint64_t chipId = ESP.getEfuseMac();
  char buffer[32];
  snprintf(
    buffer,
    sizeof(buffer),
    "coinctrl_%04X%08X",
    static_cast<uint16_t>(chipId >> 32),
    static_cast<uint32_t>(chipId)
  );
  return String(buffer);
}

String buildBluetoothName() {
  uint64_t chipId = ESP.getEfuseMac();
  char suffix[16];
  snprintf(suffix, sizeof(suffix), "%06X", static_cast<uint32_t>(chipId & 0xFFFFFF));
  return String(bleBaseName) + "-" + String(suffix);
}

void notifyJson(JsonDocument& doc) {
  if (statusCharacteristic == nullptr) {
    return;
  }

  String payload;
  serializeJson(doc, payload);
  statusCharacteristic->setValue(payload.c_str());
  statusCharacteristic->notify();
  Serial.println("[CoinController BLE] Notify: " + payload);
}

void notifyStatus(const char* type, const String& message) {
  JsonDocument doc;
  doc["type"] = type;
  doc["message"] = message;
  doc["controllerId"] = controllerId;
  doc["bluetoothName"] = bluetoothName;
  doc["acceptorOpen"] = acceptorOpen;
  doc["acceptorOpenPending"] = acceptorOpenPending;
  doc["activeLauncherDeviceId"] = activeLauncherDeviceId;
  doc["activeLauncherDeviceName"] = activeLauncherDeviceName;
  notifyJson(doc);
}

void refreshOwnerLease() {
  lastOwnerHeartbeatAt = millis();
}

void setAcceptorOutput(bool enabled) {
  acceptorOpen = enabled;
  digitalWrite(
    acceptorEnablePin,
    enabled ? acceptorEnabledLevel : !acceptorEnabledLevel
  );

  if (!enabled) {
    pulses = 0;
  }

  Serial.println(
    String("[CoinController BLE] Coin acceptor ") + (enabled ? "OPEN" : "CLOSED")
  );
}

void openSessionForLauncher(const String& launcherId, const String& launcherName) {
  Serial.println(
    "[CoinController BLE] Opening session for launcherId=" + launcherId +
    " launcherName=" + launcherName
  );
  activeLauncherDeviceId = launcherId;
  activeLauncherDeviceName = launcherName;
  prefs.putString("active_launcher_id", activeLauncherDeviceId);
  prefs.putString("active_launcher_name", activeLauncherDeviceName);
  acceptorOpenPending = true;
  acceptorOpenRequestedAt = millis();
  refreshOwnerLease();
  pulses = 0;
  notifyStatus("open_session_ack", "Coin controller is ready.");
}

void closeCurrentSession(const String& message) {
  acceptorOpenPending = false;
  setAcceptorOutput(false);
  const bool hadLauncherId = prefs.isKey("active_launcher_id");
  const bool hadLauncherName = prefs.isKey("active_launcher_name");

  Serial.println(
    "[CoinController BLE] Closing session. message=" + message +
    " activeLauncherDeviceId=" + activeLauncherDeviceId +
    " activeLauncherDeviceName=" + activeLauncherDeviceName
  );

  activeLauncherDeviceId = "";
  activeLauncherDeviceName = "";
  lastOwnerHeartbeatAt = 0;
  if (hadLauncherId) {
    prefs.remove("active_launcher_id");
  }
  if (hadLauncherName) {
    prefs.remove("active_launcher_name");
  }
  notifyStatus("close_session_ack", message);
}

void publishCoinInserted(int amount) {
  JsonDocument doc;
  doc["type"] = "coin_inserted";
  doc["amount"] = amount;
  doc["controllerId"] = controllerId;
  doc["bluetoothName"] = bluetoothName;
  doc["activeLauncherDeviceId"] = activeLauncherDeviceId;
  doc["activeLauncherDeviceName"] = activeLauncherDeviceName;
  doc["timestamp"] = millis();
  notifyJson(doc);
}

void IRAM_ATTR countPulse() {
  if (!acceptorOpen) {
    return;
  }
  pulses++;
  lastPulseTime = millis();
}

class CoinServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    clientConnected = true;
    connectedClientCount++;
    Serial.println(
      "[CoinController BLE] Launcher connected. connectedClientCount=" +
      String(connectedClientCount)
    );
    restartAdvertising("client connected");
    notifyStatus("connected", "Coin controller connected.");
  }

  void onDisconnect(BLEServer* pServer) override {
    if (connectedClientCount > 0) {
      connectedClientCount--;
    }
    clientConnected = connectedClientCount > 0;
    Serial.println(
      "[CoinController BLE] Launcher disconnected. connectedClientCount=" +
      String(connectedClientCount)
    );
    restartAdvertising("client disconnected");
  }
};

class CoinCommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    const std::string value = characteristic->getValue();
    if (value.empty()) {
      return;
    }

    JsonDocument doc;
    const DeserializationError error = deserializeJson(doc, value);
    if (error) {
      notifyStatus("error", "Invalid JSON command.");
      return;
    }

    const String type = doc["type"] | "";
    const String launcherId = String((const char*)(doc["launcher_device_id"] | ""));
    const String launcherName = String((const char*)(doc["launcher_device_name"] | ""));

    if (type == "status_request") {
      if (activeLauncherDeviceId.length() > 0 &&
          activeLauncherDeviceId == launcherId) {
        refreshOwnerLease();
        Serial.println(
          "[CoinController BLE] status_request heartbeat accepted for owner launcherId=" +
          launcherId
        );
      } else {
        Serial.println(
          "[CoinController BLE] status_request from launcherId=" + launcherId +
          " currentOwnerId=" + activeLauncherDeviceId
        );
      }
      notifyStatus("controller_status", "Coin controller status ready.");
      return;
    }

    if (type == "open_session") {
      Serial.println(
        "[CoinController BLE] open_session requested by launcherId=" + launcherId +
        " launcherName=" + launcherName +
        " currentOwnerId=" + activeLauncherDeviceId +
        " currentOwnerName=" + activeLauncherDeviceName
      );

      if (activeLauncherDeviceId.length() > 0 &&
          activeLauncherDeviceId != launcherId) {
        Serial.println(
          "[CoinController BLE] open_session denied. Controller busy for launcherId=" +
          activeLauncherDeviceId
        );
        JsonDocument busyDoc;
        busyDoc["type"] = "session_busy";
        busyDoc["message"] = "Another machine is currently receiving coins.";
        busyDoc["controllerId"] = controllerId;
        busyDoc["bluetoothName"] = bluetoothName;
        busyDoc["activeLauncherDeviceId"] = activeLauncherDeviceId;
        busyDoc["activeLauncherDeviceName"] = activeLauncherDeviceName;
        notifyJson(busyDoc);
        return;
      }

      openSessionForLauncher(launcherId, launcherName);
      Serial.println("[CoinController BLE] open_session accepted.");
      return;
    }

    if (type == "close_session") {
      Serial.println(
        "[CoinController BLE] close_session requested by launcherId=" + launcherId +
        " launcherName=" + launcherName +
        " currentOwnerId=" + activeLauncherDeviceId +
        " currentOwnerName=" + activeLauncherDeviceName
      );

      if (activeLauncherDeviceId.isEmpty() ||
          activeLauncherDeviceId == launcherId) {
        closeCurrentSession("Coin controller session closed.");
      } else {
        Serial.println(
          "[CoinController BLE] close_session ignored for non-owner launcherId=" +
          launcherId
        );
        notifyStatus("ignored", "Close request ignored for non-owner launcher.");
      }
      return;
    }
  }
};

void setupBle() {
  BLEDevice::init(bluetoothName.c_str());
  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new CoinServerCallbacks());

  BLEService* service = bleServer->createService(serviceUuid);

  BLECharacteristic* commandCharacteristic = service->createCharacteristic(
    commandCharacteristicUuid,
    BLECharacteristic::PROPERTY_WRITE
  );
  commandCharacteristic->setCallbacks(new CoinCommandCallbacks());

  statusCharacteristic = service->createCharacteristic(
    statusCharacteristicUuid,
    BLECharacteristic::PROPERTY_READ |
        BLECharacteristic::PROPERTY_NOTIFY
  );
  statusCharacteristic->addDescriptor(new BLE2902());

  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(serviceUuid);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMinPreferred(0x12);
  restartAdvertising("setup complete");
}

void setup() {
  Serial.begin(115200);
  prefs.begin("coinctrl_ble", false);
  controllerId = buildControllerId();
  bluetoothName = prefs.getString("bluetooth_name", buildBluetoothName());
  activeLauncherDeviceId = prefs.getString("active_launcher_id", "");
  activeLauncherDeviceName = prefs.getString("active_launcher_name", "");

  pinMode(coinPin, INPUT_PULLUP);
  pinMode(acceptorEnablePin, OUTPUT);
  setAcceptorOutput(false);
  attachInterrupt(digitalPinToInterrupt(coinPin), countPulse, FALLING);

  Serial.println("[CoinController BLE] Device ID: " + controllerId);
  Serial.println("[CoinController BLE] Bluetooth name: " + bluetoothName);
  if (activeLauncherDeviceId.length() > 0) {
    Serial.println(
      "[CoinController BLE] Restored active owner launcherId=" +
      activeLauncherDeviceId + " launcherName=" + activeLauncherDeviceName
    );
    refreshOwnerLease();
  }

  setupBle();
  notifyStatus("controller_status", "Coin controller started.");
}

void loop() {
  if (activeLauncherDeviceId.length() > 0 &&
      lastOwnerHeartbeatAt > 0 &&
      (millis() - lastOwnerHeartbeatAt > sessionLeaseTimeoutMs)) {
    Serial.println(
      "[CoinController BLE] Session lease expired for launcherId=" +
      activeLauncherDeviceId
    );
    closeCurrentSession("Session lease expired.");
  }

  if (
      acceptorOpenPending &&
      (millis() - acceptorOpenRequestedAt >= acceptorOpenDelayMs)) {
    acceptorOpenPending = false;
    setAcceptorOutput(true);
    notifyStatus("acceptor_open", "Coin acceptor is open.");
  }

  if (pulses > 0 && (millis() - lastPulseTime > 200)) {
    const int amount = pulses;
    pulses = 0;
    publishCoinInserted(amount);
    Serial.printf("[CoinController BLE] Coin inserted amount=%d\n", amount);
  }
}
