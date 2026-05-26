#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>

const int RELAY_1_PIN = 26;
const int RELAY_2_PIN = 27;
const int RELAY_3_PIN = 32;
const int RELAY_4_PIN = 33;
const bool relayOnLevel = HIGH;

const char* bleBaseName = "PisoCharger";
const char* serviceUuid = "91f05e01-0000-4f9c-bb88-5a9f6d770001";
const char* commandCharacteristicUuid = "91f05e01-0000-4f9c-bb88-5a9f6d770002";
const char* statusCharacteristicUuid = "91f05e01-0000-4f9c-bb88-5a9f6d770003";

Preferences prefs;
BLEServer* bleServer = nullptr;
BLECharacteristic* statusCharacteristic = nullptr;
bool clientConnected = false;
bool relayEnabled = false;
int lastRelayPin = RELAY_1_PIN;
int startBelowPercent = 30;
int stopAtPercent = 80;
String chargerDeviceId;
String bluetoothName;
String launcherDeviceId = "";
String launcherDeviceName = "";

String buildChargerDeviceId() {
  uint64_t chipId = ESP.getEfuseMac();
  char buffer[32];
  snprintf(
    buffer,
    sizeof(buffer),
    "charger_%04X%08X",
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

bool isKnownRelayPin(int relayPin) {
  return relayPin == RELAY_1_PIN ||
      relayPin == RELAY_2_PIN ||
      relayPin == RELAY_3_PIN ||
      relayPin == RELAY_4_PIN;
}

void setAllRelaysLow() {
  digitalWrite(RELAY_1_PIN, !relayOnLevel);
  digitalWrite(RELAY_2_PIN, !relayOnLevel);
  digitalWrite(RELAY_3_PIN, !relayOnLevel);
  digitalWrite(RELAY_4_PIN, !relayOnLevel);
}

void setRelayState(int relayPin, bool enabled) {
  if (!isKnownRelayPin(relayPin)) {
    Serial.println(String("[Charger BLE] Unknown relay pin: ") + relayPin);
    return;
  }

  setAllRelaysLow();
  relayEnabled = enabled;
  lastRelayPin = relayPin;
  digitalWrite(relayPin, enabled ? relayOnLevel : !relayOnLevel);
  Serial.println(
    String("[Charger BLE] Relay pin ") + relayPin + " " + (enabled ? "ON" : "OFF")
  );
}

void notifyStatus(const String& type, int batteryLevel, const String& reason) {
  if (statusCharacteristic == nullptr) {
    return;
  }

  JsonDocument doc;
  doc["type"] = type;
  doc["device_id"] = chargerDeviceId;
  doc["bluetooth_name"] = bluetoothName;
  doc["enabled"] = relayEnabled;
  doc["relay_pin"] = lastRelayPin;
  doc["start_below_percent"] = startBelowPercent;
  doc["stop_at_percent"] = stopAtPercent;
  doc["battery_level"] = batteryLevel;
  doc["reason"] = reason;
  if (launcherDeviceId.length() > 0) {
    doc["launcher_device_id"] = launcherDeviceId;
  }
  if (launcherDeviceName.length() > 0) {
    doc["launcher_device_name"] = launcherDeviceName;
  }

  String payload;
  serializeJson(doc, payload);
  statusCharacteristic->setValue(payload.c_str());
  statusCharacteristic->notify();
  Serial.println("[Charger BLE] Notify: " + payload);
}

class ChargerServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    clientConnected = true;
    Serial.println("[Charger BLE] Launcher connected");
    notifyStatus("charger_connected", -1, "ble_client_connected");
  }

  void onDisconnect(BLEServer* pServer) override {
    clientConnected = false;
    Serial.println("[Charger BLE] Launcher disconnected");
    BLEDevice::startAdvertising();
  }
};

class ChargerCommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    const std::string value = characteristic->getValue();
    if (value.empty()) {
      return;
    }

    JsonDocument doc;
    const DeserializationError error = deserializeJson(doc, value);
    if (error) {
      Serial.println(String("[Charger BLE] Invalid JSON: ") + error.c_str());
      notifyStatus("charger_error", -1, "invalid_json");
      return;
    }

    const String type = doc["type"] | "";
    launcherDeviceId = String((const char*)(doc["launcher_device_id"] | ""));
    launcherDeviceName = String((const char*)(doc["launcher_device_name"] | ""));

    if (launcherDeviceId.length() > 0) {
      prefs.putString("launcher_device_id", launcherDeviceId);
    }
    if (launcherDeviceName.length() > 0) {
      prefs.putString("launcher_device_name", launcherDeviceName);
    }

    if (type == "charger_config") {
      startBelowPercent = doc["start_below_percent"] | startBelowPercent;
      stopAtPercent = doc["stop_at_percent"] | stopAtPercent;
      const int relayPin = doc["relay_pin"] | lastRelayPin;
      if (isKnownRelayPin(relayPin)) {
        lastRelayPin = relayPin;
      }

      prefs.putInt("start_below_percent", startBelowPercent);
      prefs.putInt("stop_at_percent", stopAtPercent);
      prefs.putInt("relay_pin", lastRelayPin);

      Serial.println(
        String("[Charger BLE] Config updated: start=") + startBelowPercent +
        String(", stop=") + stopAtPercent +
        String(", relay_pin=") + lastRelayPin
      );
      notifyStatus("charger_config_ack", -1, "config_updated");
      return;
    }

    if (type == "charger_command") {
      const bool enabled = doc["enabled"] | false;
      const int batteryLevel = doc["battery_level"] | -1;
      const int relayPin = doc["relay_pin"] | lastRelayPin;
      const String reason = doc["reason"] | "";

      setRelayState(relayPin, enabled);
      notifyStatus("charger_ack", batteryLevel, reason);
      return;
    }

    if (type == "status_request") {
      notifyStatus("charger_status", -1, "status_requested");
      return;
    }
  }
};

void setupBle() {
  BLEDevice::init(bluetoothName.c_str());
  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ChargerServerCallbacks());

  BLEService* service = bleServer->createService(serviceUuid);

  BLECharacteristic* commandCharacteristic = service->createCharacteristic(
    commandCharacteristicUuid,
    BLECharacteristic::PROPERTY_WRITE
  );
  commandCharacteristic->setCallbacks(new ChargerCommandCallbacks());

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
  BLEDevice::startAdvertising();
}

void setup() {
  Serial.begin(115200);
  prefs.begin("charger_ble", false);

  chargerDeviceId = buildChargerDeviceId();
  bluetoothName = prefs.getString("bluetooth_name", buildBluetoothName());
  startBelowPercent = prefs.getInt("start_below_percent", 30);
  stopAtPercent = prefs.getInt("stop_at_percent", 80);
  lastRelayPin = prefs.getInt("relay_pin", RELAY_1_PIN);
  launcherDeviceId = prefs.getString("launcher_device_id", "");
  launcherDeviceName = prefs.getString("launcher_device_name", "");

  pinMode(RELAY_1_PIN, OUTPUT);
  pinMode(RELAY_2_PIN, OUTPUT);
  pinMode(RELAY_3_PIN, OUTPUT);
  pinMode(RELAY_4_PIN, OUTPUT);
  setAllRelaysLow();

  Serial.println("[Charger BLE] Device ID: " + chargerDeviceId);
  Serial.println("[Charger BLE] Bluetooth name: " + bluetoothName);
  Serial.println(
    String("[Charger BLE] Thresholds start=") + startBelowPercent +
    String(", stop=") + stopAtPercent +
    String(", relay_pin=") + lastRelayPin
  );

  setupBle();
}

void loop() {
  delay(50);
}
