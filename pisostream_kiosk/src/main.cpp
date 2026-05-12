#include <Arduino.h>
#include <WiFi.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <esp_system.h>

// --- CONFIGURATION ---
const char* ssid = "Loading...";         // Replace with your WiFi SSID
const char* password = "MdlJcrZfrlZvrl11@2.4G"; // Replace with your WiFi Password
const char* ws_host = "192.168.1.18";      // Replace with your Node.js Server IP
const int ws_port = 3000;
const char* ws_path = "/esp32";
const char* bootstrapLauncherDeviceName = "";  // Optional only for dedicated pairing; leave blank for shared-acceptor mode
String launcherDeviceId = ""; // Launcher device ID is assigned dynamically from the server payload
String launcherDeviceName = bootstrapLauncherDeviceName;  // Bootstrap name used until server assigns/persists values
const int acceptorEnablePin = 26;           // Set your acceptor control GPIO here, or leave -1 for software-only gating
const bool acceptorEnabledLevel = HIGH;      // Change if your acceptor enable line is active HIGH
const unsigned long acceptorOpenDelayMs = 100;

// --- PERSISTENCE & SYNC ---
Preferences prefs;

void loadLauncherDeviceConfig() {
  const String savedId = prefs.getString("launcher_device_id", "");
  if (savedId.length() > 0) {
    launcherDeviceId = savedId;
  }

  const String savedName = prefs.getString("launcher_device_name", "");
  if (savedName.length() > 0) {
    launcherDeviceName = savedName;
  } else if (launcherDeviceName.length() == 0 && strlen(bootstrapLauncherDeviceName) > 0) {
    launcherDeviceName = String(bootstrapLauncherDeviceName);
  }
}

// --- HARDWARE MAPPING ---
const int coinPin = 14; 
volatile int pulses = 0;
unsigned long lastPulseTime = 0;
bool acceptorOpen = false;
bool acceptorOpenPending = false;
unsigned long acceptorOpenAt = 0;

// --- PERSISTENCE & SYNC ---
 
int pendingAmount = 0;
long lastTxId = 0;
bool waitingForAck = false;
unsigned long lastRetryTime = 0;
const int retryInterval = 5000; // Retry every 5 seconds

WebSocketsClient webSocket;
String deviceId;

String buildEsp32DeviceId() {
  uint64_t chipId = ESP.getEfuseMac();
  char buffer[32];
  snprintf(
    buffer,
    sizeof(buffer),
    "esp32_%04X%08X",
    (uint16_t)(chipId >> 32),
    (uint32_t)chipId
  );
  return String(buffer);
}

void setAcceptorOutput(bool enabled) {
  acceptorOpen = enabled;

  if (acceptorEnablePin >= 0) {
    digitalWrite(
      acceptorEnablePin,
      enabled ? acceptorEnabledLevel : !acceptorEnabledLevel
    );
  }

  if (!enabled) {
    pulses = 0;
  }

  Serial.println(
    String("[PisoStream] Coin acceptor ") + (enabled ? "OPEN" : "CLOSED")
  );
}

void applyAcceptorState(bool enabled) {
  if (enabled) {
    acceptorOpenPending = true;
    acceptorOpenAt = millis() + acceptorOpenDelayMs;
    pulses = 0;
    Serial.println(
      String("[PisoStream] Coin acceptor OPEN requested. Delaying for ") +
      String(acceptorOpenDelayMs) +
      "ms"
    );
    return;
  }

  acceptorOpenPending = false;
  setAcceptorOutput(false);
}

void registerToServer() {
  JsonDocument doc;
  doc["type"] = "register_esp32";
  doc["device_id"] = deviceId;
  if (launcherDeviceId.length() > 0) {
    doc["launcher_device_id"] = launcherDeviceId;
  }
  if (launcherDeviceName.length() > 0) {
    doc["launcher_device_name"] = launcherDeviceName;
  }

  String output;
  serializeJson(doc, output);
  webSocket.sendTXT(output);
  Serial.println("[PisoStream] Registering: " + output);
}

// Interrupt function for coin pulses
void IRAM_ATTR countPulse() {
  if (!acceptorOpen) return;
  pulses++;
  lastPulseTime = millis();
}

// Function to send the data packet to the server
void syncCreditToServer() {
  if (WiFi.status() != WL_CONNECTED) return;

  JsonDocument doc;
  doc["type"] = "coin_inserted";
  doc["amount"] = pendingAmount;
  doc["tx_id"] = lastTxId;
  doc["device_id"] = deviceId;
  if (launcherDeviceId.length() > 0) {
    doc["launcher_device_id"] = launcherDeviceId;
  }
  if (launcherDeviceName.length() > 0) {
    doc["launcher_device_name"] = launcherDeviceName;
  }

  String output;
  serializeJson(doc, output);
  webSocket.sendTXT(output);
  
  Serial.println("[PisoStream] Syncing: " + output);
  lastRetryTime = millis();
}

// Handles WebSocket events and the Server ACK
void webSocketEvent(WStype_t type, uint8_t * payload, size_t length) {
  switch(type) {
    case WStype_DISCONNECTED:
      Serial.println("[WS] Disconnected from Server");
      break;
    case WStype_CONNECTED:
      Serial.println("[WS] Connected! Ready to sync.");
      registerToServer();
      // If we have unsent money from a previous session, send it now
      if (waitingForAck) syncCreditToServer();
      break;
    case WStype_TEXT:
      JsonDocument res;
      deserializeJson(res, payload);

      if (res["type"] == "acceptor_command") {
        String incomingLauncherDeviceId = res["launcher_device_id"].as<String>();
        incomingLauncherDeviceId.trim();
        String incomingLauncherDeviceName = res["launcher_device_name"].as<String>();
        incomingLauncherDeviceName.trim();

        if (incomingLauncherDeviceId.length() > 0) {
          launcherDeviceId = incomingLauncherDeviceId;
          prefs.putString("launcher_device_id", launcherDeviceId);
        }

        if (incomingLauncherDeviceName.length() > 0) {
          launcherDeviceName = incomingLauncherDeviceName;
          prefs.putString("launcher_device_name", launcherDeviceName);
        }

        const bool enabled = res["enabled"] | false;
        applyAcceptorState(enabled);
        Serial.println(
          String("[WS] Acceptor command received. reason=") +
          String((const char*)(res["reason"] | "")) +
          String(", launcher_device_id=") + launcherDeviceId +
          String(", launcher_device_name=") + launcherDeviceName
        );
        break;
      }
      
      // Match the transaction ID to confirm the server saved it
      if (res["type"] == "ack" && res["tx_id"] == lastTxId) {
        Serial.println("[WS] ACK Received. Clearing NVS memory.");
        
        prefs.putInt("amount", 0);  // Clear NVS
        prefs.putLong("tx_id", 0);
        
        waitingForAck = false;
        pendingAmount = 0;
      }
      break;
  }
}

void setup() {
  Serial.begin(115200);
  deviceId = buildEsp32DeviceId();

  // 1. Initialize NVS before logging launcher config and connecting.
  prefs.begin("piso", false);
  loadLauncherDeviceConfig();

  Serial.println("[PisoStream] ESP32 Device ID: " + deviceId);
  Serial.println("[PisoStream] Launcher Device ID: " + launcherDeviceId);
  Serial.println("[PisoStream] Launcher Device Name: " + launcherDeviceName);
  
  // 2. Initialize Hardware
  pinMode(coinPin, INPUT_PULLUP);
  if (acceptorEnablePin >= 0) {
    pinMode(acceptorEnablePin, OUTPUT);
  }
  applyAcceptorState(false);
  attachInterrupt(digitalPinToInterrupt(coinPin), countPulse, FALLING);

  // 3. Initialize NVS (Check for existing credits after reboot/crash)
  pendingAmount = prefs.getInt("amount", 0);
  lastTxId = prefs.getLong("tx_id", 0);

  if (pendingAmount > 0) {
    Serial.printf("[RECOVERY] Found %d pesos in memory. Waiting for sync...\n", pendingAmount);
    waitingForAck = true;
  }

  // 3. Connect to WiFi
  Serial.printf("Connecting to %s", ssid);
  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nWiFi Connected!");

  // 4. Start WebSocket
  webSocket.begin(ws_host, ws_port, ws_path);
  webSocket.onEvent(webSocketEvent);
  webSocket.setReconnectInterval(5000);
}

void loop() {
  webSocket.loop();

  if (acceptorOpenPending && static_cast<long>(millis() - acceptorOpenAt) >= 0) {
    acceptorOpenPending = false;
    setAcceptorOutput(true);
  }

  // Step 1: Check if a coin insertion is finished (200ms of silence)
  if (pulses > 0 && (millis() - lastPulseTime > 200) && !waitingForAck) {
    pendingAmount = pulses;
    lastTxId = millis(); // Generate unique ID
    pulses = 0;

    // Save to NVS IMMEDIATELY before doing anything else
    prefs.putInt("amount", pendingAmount);
    prefs.putLong("tx_id", lastTxId);
    
    waitingForAck = true;
    syncCreditToServer();
  }

  // Step 2: Retry logic if the server hasn't acknowledged
  if (waitingForAck && (millis() - lastRetryTime > retryInterval)) {
    syncCreditToServer();
  }
}
