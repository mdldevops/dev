#include <Arduino.h>
#include <WiFi.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <esp_system.h>

const char* ssid = "Loading...";
const char* password = "MdlJcrZfrlZvrl11@2.4G";
const char* wsHost = "portal.pisostream.online";
const int wsPort = 443;
const char* wsPath = "/charger";
const bool wsSecure = true;

const char* bootstrapLauncherDeviceName = "";
String launcherDeviceId = "";
String launcherDeviceName = bootstrapLauncherDeviceName;

const int RELAY_1_PIN = 26;
const int RELAY_2_PIN = 27;
const int RELAY_3_PIN = 32;
const int RELAY_4_PIN = 33;
const bool relayOnLevel = HIGH;
const unsigned long wifiReconnectIntervalMs = 10000;
const unsigned long registerRefreshIntervalMs = 30000;
const unsigned long websocketHeartbeatIntervalMs = 15000;
const unsigned long websocketHeartbeatTimeoutMs = 3000;
const uint8_t websocketHeartbeatDisconnectCount = 2;

Preferences prefs;
WebSocketsClient webSocket;
String chargerDeviceId;
bool relayEnabled = false;
unsigned long lastWifiReconnectAttemptMs = 0;
unsigned long lastRegisterSentMs = 0;
int lastRelayPin = RELAY_1_PIN;

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

bool isKnownRelayPin(int relayPin) {
  return relayPin == RELAY_1_PIN ||
      relayPin == RELAY_2_PIN ||
      relayPin == RELAY_3_PIN ||
      relayPin == RELAY_4_PIN;
}

void setRelayState(int relayPin, bool enabled) {
  if (!isKnownRelayPin(relayPin)) {
    Serial.println(String("[Charger] Unknown relay pin: ") + relayPin);
    return;
  }

  relayEnabled = enabled;
  lastRelayPin = relayPin;
  digitalWrite(relayPin, enabled ? relayOnLevel : !relayOnLevel);
  Serial.println(
    String("[Charger] Relay pin ") + relayPin + " " + (enabled ? "ON" : "OFF")
  );
}

void setAllRelaysOff() {
  setRelayState(RELAY_1_PIN, false);
  setRelayState(RELAY_2_PIN, false);
  setRelayState(RELAY_3_PIN, false);
  setRelayState(RELAY_4_PIN, false);
}

void sendChargerAck(bool enabled, int relayPin) {
  JsonDocument doc;
  doc["type"] = "charger_ack";
  doc["device_id"] = chargerDeviceId;
  doc["enabled"] = enabled;
  doc["relay_pin"] = relayPin;
  if (launcherDeviceId.length() > 0) {
    doc["launcher_device_id"] = launcherDeviceId;
  }
  if (launcherDeviceName.length() > 0) {
    doc["launcher_device_name"] = launcherDeviceName;
  }

  String output;
  serializeJson(doc, output);
  webSocket.sendTXT(output);
  Serial.println("[Charger] Ack sent: " + output);
}

void loadBinding() {
  const String savedLauncherId = prefs.getString("launcher_device_id", "");
  if (savedLauncherId.length() > 0) {
    launcherDeviceId = savedLauncherId;
  }

  const String savedLauncherName = prefs.getString("launcher_device_name", "");
  if (savedLauncherName.length() > 0) {
    launcherDeviceName = savedLauncherName;
  }
}

void registerToServer() {
  JsonDocument doc;
  doc["type"] = "register_charger";
  doc["device_id"] = chargerDeviceId;
  if (launcherDeviceId.length() > 0) {
    doc["launcher_device_id"] = launcherDeviceId;
  }
  if (launcherDeviceName.length() > 0) {
    doc["launcher_device_name"] = launcherDeviceName;
  }

  String output;
  serializeJson(doc, output);
  webSocket.sendTXT(output);
  lastRegisterSentMs = millis();
  Serial.println("[Charger] Registering: " + output);
}

void ensureWifiConnected() {
  if (WiFi.status() == WL_CONNECTED) {
    return;
  }

  const unsigned long now = millis();
  if (now - lastWifiReconnectAttemptMs < wifiReconnectIntervalMs) {
    return;
  }

  lastWifiReconnectAttemptMs = now;
  Serial.println("[Charger] Wi-Fi disconnected. Reconnecting...");
  WiFi.disconnect();
  WiFi.begin(ssid, password);
}

void handleIncomingText(uint8_t* payload) {
  JsonDocument doc;
  const auto error = deserializeJson(doc, payload);
  if (error) {
    Serial.println(String("[Charger] Invalid JSON: ") + error.c_str());
    return;
  }

  const String messageType = doc["type"] | "";
  if (messageType == "register_ack") {
    const String incomingLauncherId = String((const char*)(doc["launcher_device_id"] | ""));
    const String incomingLauncherName = String((const char*)(doc["launcher_device_name"] | ""));

    if (incomingLauncherId.length() > 0) {
      launcherDeviceId = incomingLauncherId;
      prefs.putString("launcher_device_id", launcherDeviceId);
    }

    if (incomingLauncherName.length() > 0) {
      launcherDeviceName = incomingLauncherName;
      prefs.putString("launcher_device_name", launcherDeviceName);
    }

    Serial.println(
      String("[Charger] Registered. launcher_device_id=") + launcherDeviceId +
      String(", launcher_device_name=") + launcherDeviceName
    );
    return;
  }

  if (messageType != "charger_command") {
    return;
  }

  const String incomingLauncherId = String((const char*)(doc["launcher_device_id"] | ""));
  const String incomingLauncherName = String((const char*)(doc["launcher_device_name"] | ""));

  if (incomingLauncherId.length() > 0) {
    launcherDeviceId = incomingLauncherId;
    prefs.putString("launcher_device_id", launcherDeviceId);
  }

  if (incomingLauncherName.length() > 0) {
    launcherDeviceName = incomingLauncherName;
    prefs.putString("launcher_device_name", launcherDeviceName);
  }

  const bool enabled = doc["enabled"] | false;
  const int batteryLevel = doc["battery_level"] | -1;
  const int relayPin = doc["relay_pin"] | RELAY_1_PIN;
  const String reason = String((const char*)(doc["reason"] | ""));

  setRelayState(relayPin, enabled);
  sendChargerAck(enabled, relayPin);
  Serial.println(
    String("[Charger] Command received. enabled=") + (enabled ? "true" : "false") +
    String(", battery=") + batteryLevel +
    String(", relay_pin=") + relayPin +
    String(", reason=") + reason +
    String(", launcher_device_name=") + launcherDeviceName
  );
}

void webSocketEvent(WStype_t type, uint8_t* payload, size_t length) {
  switch (type) {
    case WStype_DISCONNECTED:
      Serial.println("[Charger] Disconnected from server");
      break;
    case WStype_CONNECTED:
      Serial.println("[Charger] Connected to server");
      registerToServer();
      break;
    case WStype_ERROR:
      Serial.println("[Charger] WebSocket error");
      break;
    case WStype_PING:
      Serial.println("[Charger] Ping received");
      break;
    case WStype_PONG:
      Serial.println("[Charger] Pong received");
      break;
    case WStype_TEXT:
      handleIncomingText(payload);
      break;
    default:
      break;
  }
}

void setup() {
  Serial.begin(115200);
  chargerDeviceId = buildChargerDeviceId();

  prefs.begin("charger", false);
  loadBinding();

  pinMode(RELAY_1_PIN, OUTPUT);
  pinMode(RELAY_2_PIN, OUTPUT);
  pinMode(RELAY_3_PIN, OUTPUT);
  pinMode(RELAY_4_PIN, OUTPUT);
  setAllRelaysOff();

  Serial.println("[Charger] Device ID: " + chargerDeviceId);
  Serial.println("[Charger] Launcher Device ID: " + launcherDeviceId);
  Serial.println("[Charger] Launcher Device Name: " + launcherDeviceName);

  Serial.printf("[Charger] Connecting to Wi-Fi %s", ssid);
  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\n[Charger] Wi-Fi connected");
  Serial.println("[Charger] Local IP: " + WiFi.localIP().toString());
  Serial.println(
    String("[Charger] WebSocket URL: ") +
    (wsSecure ? "wss://" : "ws://") +
    wsHost +
    ":" +
    wsPort +
    wsPath
  );

  if (wsSecure) {
    webSocket.beginSSL(wsHost, wsPort, wsPath);
  } else {
    webSocket.begin(wsHost, wsPort, wsPath);
  }
  webSocket.onEvent(webSocketEvent);
  webSocket.setReconnectInterval(5000);
  webSocket.enableHeartbeat(
    websocketHeartbeatIntervalMs,
    websocketHeartbeatTimeoutMs,
    websocketHeartbeatDisconnectCount
  );
}

void loop() {
  ensureWifiConnected();
  webSocket.loop();

  if (
    WiFi.status() == WL_CONNECTED &&
    webSocket.isConnected() &&
    millis() - lastRegisterSentMs >= registerRefreshIntervalMs
  ) {
    registerToServer();
  }
}
