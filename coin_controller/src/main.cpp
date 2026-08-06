#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WebSocketsServer.h>
#include <esp_system.h>

const char* ssid = "Loading...";
const char* password = "MdlJcrZfrlZvrl11@2.4G";

const IPAddress localIp(192, 168, 1, 6);
const IPAddress gateway(192, 168, 1, 1);
const IPAddress subnet(255, 255, 255, 0);
const IPAddress dnsServer(8, 8, 8, 8);

const int websocketPort = 81;
const int coinPin = 25;
const int acceptorEnablePin = 26;
const bool acceptorEnabledLevel = HIGH;
const unsigned long acceptorOpenDelayMs = 100;
const unsigned long sessionLeaseTimeoutMs = 60000;
const unsigned long wifiReconnectIntervalMs = 10000;
const unsigned long coinAckRetryIntervalMs = 800;

const char* prefActiveLauncherIdKey = "act_l_id";
const char* prefActiveLauncherNameKey = "act_l_name";

Preferences prefs;
WebSocketsServer webSocket(websocketPort);

bool websocketReady = false;
bool acceptorOpen = false;
bool acceptorOpenPending = false;
unsigned long acceptorOpenRequestedAt = 0;
unsigned long lastOwnerHeartbeatAt = 0;
unsigned long lastWifiReconnectAttemptMs = 0;
unsigned long lastCoinEventId = 0;
unsigned long pendingCoinPublishedAt = 0;
volatile int pulses = 0;
volatile unsigned long lastPulseTime = 0;
bool hasPendingCoinAck = false;
int pendingCoinAmount = 0;
unsigned long queuedCoinAmount = 0;
int activeLauncherClientNum = -1;

String controllerId;
String controllerHostname;
String activeLauncherDeviceId = "";
String activeLauncherDeviceName = "";
String pendingCoinEventId = "";

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

String buildControllerHostname() {
  uint64_t chipId = ESP.getEfuseMac();
  char buffer[32];
  snprintf(
    buffer,
    sizeof(buffer),
    "pisocoin-%06X",
    static_cast<uint32_t>(chipId & 0xFFFFFF)
  );
  return String(buffer);
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
    String("[CoinController WS] Coin acceptor ") + (enabled ? "OPEN" : "CLOSED")
  );
}

String buildStatusPayload(const char* type, const String& message) {
  JsonDocument doc;
  doc["type"] = type;
  doc["message"] = message;
  doc["controllerId"] = controllerId;
  doc["acceptorOpen"] = acceptorOpen;
  doc["acceptorOpenPending"] = acceptorOpenPending;
  doc["activeLauncherDeviceId"] = activeLauncherDeviceId;
  doc["activeLauncherDeviceName"] = activeLauncherDeviceName;
  doc["ip"] = WiFi.localIP().toString();
  doc["hostname"] = controllerHostname;

  String payload;
  serializeJson(doc, payload);
  return payload;
}

void sendTextToClient(uint8_t clientNum, const String& payload) {
  if (!websocketReady) {
    return;
  }
  String message = payload;
  webSocket.sendTXT(clientNum, message);
}

void broadcastText(const String& payload) {
  if (!websocketReady) {
    return;
  }
  String message = payload;
  webSocket.broadcastTXT(message);
}

void sendControllerSnapshotToClient(
  uint8_t clientNum,
  const String& message = "Coin controller status ready."
) {
  const String payload = buildStatusPayload("controller_status", message);
  sendTextToClient(clientNum, payload);
  Serial.println("[CoinController WS] Send controller snapshot: " + payload);
}

void broadcastControllerSnapshot(
  const String& message = "Coin controller status ready."
) {
  const String payload = buildStatusPayload("controller_status", message);
  broadcastText(payload);
  Serial.println("[CoinController WS] Broadcast controller snapshot: " + payload);
}

void sendStatusEventToClient(
  uint8_t clientNum,
  const char* type,
  const String& message,
  bool broadcastSnapshot = true
) {
  const String payload = buildStatusPayload(type, message);
  sendTextToClient(clientNum, payload);
  Serial.println("[CoinController WS] Send status event: " + payload);
  if (broadcastSnapshot) {
    broadcastControllerSnapshot(message);
  }
}

void broadcastStatusEvent(
  const char* type,
  const String& message,
  bool broadcastSnapshot = true
) {
  const String payload = buildStatusPayload(type, message);
  broadcastText(payload);
  Serial.println("[CoinController WS] Broadcast status event: " + payload);
  if (broadcastSnapshot) {
    broadcastControllerSnapshot(message);
  }
}

void publishPendingCoinCredit(bool isRetry = false);

void openSessionForLauncher(
  uint8_t clientNum,
  const String& launcherId,
  const String& launcherName
) {
  Serial.println(
    "[CoinController WS] Opening session for launcherId=" + launcherId +
    " launcherName=" + launcherName
  );
  activeLauncherDeviceId = launcherId;
  activeLauncherDeviceName = launcherName;
  activeLauncherClientNum = clientNum;
  prefs.putString(prefActiveLauncherIdKey, activeLauncherDeviceId);
  prefs.putString(prefActiveLauncherNameKey, activeLauncherDeviceName);
  acceptorOpenPending = true;
  acceptorOpenRequestedAt = millis();
  refreshOwnerLease();
  pulses = 0;
  sendStatusEventToClient(
    clientNum,
    "open_session_ack",
    "Coin controller is ready."
  );

  if (hasPendingCoinAck && pendingCoinEventId.length() > 0) {
    Serial.println(
      String("[CoinController WS] Re-sending pending coin credit for launcherId=") +
      launcherId + " eventId=" + pendingCoinEventId
    );
    publishPendingCoinCredit(true);
  }
}

void closeCurrentSession(const String& message) {
  acceptorOpenPending = false;
  setAcceptorOutput(false);
  const bool hadLauncherId = prefs.isKey(prefActiveLauncherIdKey);
  const bool hadLauncherName = prefs.isKey(prefActiveLauncherNameKey);

  Serial.println(
    "[CoinController WS] Closing session. message=" + message +
    " activeLauncherDeviceId=" + activeLauncherDeviceId +
    " activeLauncherDeviceName=" + activeLauncherDeviceName
  );

  activeLauncherDeviceId = "";
  activeLauncherDeviceName = "";
  activeLauncherClientNum = -1;
  lastOwnerHeartbeatAt = 0;
  hasPendingCoinAck = false;
  pendingCoinAmount = 0;
  queuedCoinAmount = 0;
  pendingCoinEventId = "";
  pendingCoinPublishedAt = 0;

  if (hadLauncherId) {
    prefs.remove(prefActiveLauncherIdKey);
  }
  if (hadLauncherName) {
    prefs.remove(prefActiveLauncherNameKey);
  }

  broadcastStatusEvent("close_session_ack", message);
}

void pauseSessionPreservingPendingCredit(const String& message) {
  acceptorOpenPending = false;
  setAcceptorOutput(false);
  refreshOwnerLease();

  Serial.println(
    "[CoinController WS] Pausing session while preserving pending credit. message=" +
    message +
    " activeLauncherDeviceId=" + activeLauncherDeviceId +
    " pendingCoinEventId=" + pendingCoinEventId
  );

  broadcastStatusEvent("close_session_ack", message);
}

String nextCoinEventId() {
  lastCoinEventId++;
  return controllerId + "_" + String(lastCoinEventId);
}

String buildCoinPayload(int amount, const String& eventId) {
  JsonDocument doc;
  doc["type"] = "coin_inserted";
  doc["eventId"] = eventId;
  doc["amount"] = amount;
  doc["controllerId"] = controllerId;
  doc["activeLauncherDeviceId"] = activeLauncherDeviceId;
  doc["activeLauncherDeviceName"] = activeLauncherDeviceName;
  doc["timestamp"] = millis();

  String payload;
  serializeJson(doc, payload);
  return payload;
}

void publishPendingCoinCredit(bool isRetry) {
  if (pendingCoinAmount <= 0 || pendingCoinEventId.length() == 0) {
    return;
  }

  const String payload = buildCoinPayload(pendingCoinAmount, pendingCoinEventId);
  pendingCoinPublishedAt = millis();
  if (activeLauncherClientNum >= 0) {
    sendTextToClient(activeLauncherClientNum, payload);
  } else {
    broadcastText(payload);
  }
  Serial.println(
    String("[CoinController WS] Coin credit ") +
    (isRetry ? "re-sent" : "sent") +
    " eventId=" + pendingCoinEventId +
    " amount=" + pendingCoinAmount +
    " payload=" + payload
  );
}

void queueCoinCredit(int amount) {
  if (amount <= 0) {
    return;
  }

  queuedCoinAmount += amount;
  if (hasPendingCoinAck) {
    Serial.println(
      String("[CoinController WS] Queued coin credit while waiting for ack. queuedCoinAmount=") +
      queuedCoinAmount
    );
    return;
  }

  pendingCoinAmount = queuedCoinAmount;
  queuedCoinAmount = 0;
  pendingCoinEventId = nextCoinEventId();
  hasPendingCoinAck = true;
  publishPendingCoinCredit(false);
}

void acknowledgePendingCoinCredit() {
  if (!hasPendingCoinAck) {
    return;
  }

  Serial.println(
    String("[CoinController WS] Coin credit acknowledged eventId=") +
    pendingCoinEventId + " amount=" + pendingCoinAmount
  );

  hasPendingCoinAck = false;
  pendingCoinAmount = 0;
  pendingCoinEventId = "";
  pendingCoinPublishedAt = 0;

  if (queuedCoinAmount > 0) {
    pendingCoinAmount = queuedCoinAmount;
    queuedCoinAmount = 0;
    pendingCoinEventId = nextCoinEventId();
    hasPendingCoinAck = true;
    publishPendingCoinCredit(false);
  }
}

void handleCommandPayload(uint8_t clientNum, const String& payload) {
  JsonDocument doc;
  const DeserializationError error = deserializeJson(doc, payload);
  if (error) {
    sendStatusEventToClient(clientNum, "error", "Invalid JSON command.", false);
    return;
  }

  const String type = doc["type"] | "";
  const String launcherId = String((const char*)(doc["launcher_device_id"] | ""));
  const String launcherName = String((const char*)(doc["launcher_device_name"] | ""));

  if (type == "status_request") {
    if (activeLauncherDeviceId.length() > 0 &&
        activeLauncherDeviceId == launcherId) {
      refreshOwnerLease();
      activeLauncherClientNum = clientNum;
      Serial.println(
        "[CoinController WS] status_request heartbeat accepted for owner launcherId=" +
        launcherId
      );
    } else {
      Serial.println(
        "[CoinController WS] status_request from launcherId=" + launcherId +
        " currentOwnerId=" + activeLauncherDeviceId
      );
    }
    sendControllerSnapshotToClient(clientNum);
    return;
  }

  if (type == "coin_credit_ack") {
    const String eventId = String((const char*)(doc["event_id"] | ""));
    if (activeLauncherDeviceId == launcherId &&
        hasPendingCoinAck &&
        pendingCoinEventId == eventId) {
      activeLauncherClientNum = clientNum;
      acknowledgePendingCoinCredit();
      sendStatusEventToClient(
        clientNum,
        "coin_credit_ack",
        "Coin credit acknowledged.",
        false
      );
    } else {
      Serial.println(
        String("[CoinController WS] Ignored coin credit ack. launcherId=") +
        launcherId + " eventId=" + eventId +
        " pendingEventId=" + pendingCoinEventId
      );
    }
    return;
  }

  if (type == "open_session") {
    Serial.println(
      "[CoinController WS] open_session requested by launcherId=" + launcherId +
      " launcherName=" + launcherName +
      " currentOwnerId=" + activeLauncherDeviceId +
      " currentOwnerName=" + activeLauncherDeviceName
    );

    if (activeLauncherDeviceId.length() > 0 &&
        activeLauncherDeviceId != launcherId) {
      sendStatusEventToClient(
        clientNum,
        "session_busy",
        "Another machine is currently receiving coins."
      );
      return;
    }

    openSessionForLauncher(clientNum, launcherId, launcherName);
    return;
  }

  if (type == "close_session") {
    Serial.println(
      "[CoinController WS] close_session requested by launcherId=" + launcherId +
      " launcherName=" + launcherName +
      " currentOwnerId=" + activeLauncherDeviceId +
      " currentOwnerName=" + activeLauncherDeviceName
    );

    if (activeLauncherDeviceId.length() == 0 ||
        activeLauncherDeviceId == launcherId) {
      if (hasPendingCoinAck && activeLauncherDeviceId == launcherId) {
        pauseSessionPreservingPendingCredit(
          "Coin controller paused. Pending credit will be restored for this device."
        );
      } else {
        closeCurrentSession("Coin controller session closed.");
      }
    } else {
      sendStatusEventToClient(
        clientNum,
        "ignored",
        "Close request ignored for non-owner launcher.",
        false
      );
    }
    return;
  }
}

void ensureWifiConnection() {
  if (WiFi.status() == WL_CONNECTED) {
    return;
  }

  const unsigned long now = millis();
  if (now - lastWifiReconnectAttemptMs < wifiReconnectIntervalMs) {
    return;
  }
  lastWifiReconnectAttemptMs = now;

  Serial.println(
    "[CoinController WS] Connecting to WiFi with static IP and hostname=" +
    controllerHostname
  );
  WiFi.mode(WIFI_STA);
  WiFi.setHostname(controllerHostname.c_str());
  WiFi.config(localIp, gateway, subnet, dnsServer);
  WiFi.begin(ssid, password);
  websocketReady = false;
}

void beginWebSocketServerIfNeeded() {
  if (websocketReady || WiFi.status() != WL_CONNECTED) {
    return;
  }

  webSocket.begin();
  webSocket.onEvent(
    [](uint8_t clientNum, WStype_t type, uint8_t* payload, size_t length) {
      switch (type) {
        case WStype_CONNECTED: {
          IPAddress ip = webSocket.remoteIP(clientNum);
          Serial.println(
            String("[CoinController WS] Client connected #") + clientNum +
            " from " + ip.toString()
          );
          sendControllerSnapshotToClient(clientNum, "Coin controller connected.");
          break;
        }
        case WStype_DISCONNECTED:
          Serial.println(
            String("[CoinController WS] Client disconnected #") + clientNum
          );
          if (activeLauncherClientNum == clientNum) {
            activeLauncherClientNum = -1;
          }
          break;
        case WStype_TEXT: {
          String message;
          message.reserve(length);
          for (size_t i = 0; i < length; i++) {
            message += static_cast<char>(payload[i]);
          }
          handleCommandPayload(clientNum, message);
          break;
        }
        default:
          break;
      }
    }
  );

  websocketReady = true;
  Serial.println(
    String("[CoinController WS] WebSocket server ready at ws://") +
    WiFi.localIP().toString() + ":" + websocketPort
  );
  broadcastControllerSnapshot("Coin controller started.");
}

void IRAM_ATTR countPulse() {
  if (!acceptorOpen) {
    return;
  }
  pulses++;
  lastPulseTime = millis();
}

void setup() {
  Serial.begin(115200);
  prefs.begin("coinctrl_ws", false);

  controllerId = buildControllerId();
  controllerHostname = buildControllerHostname();
  activeLauncherDeviceId = prefs.getString(prefActiveLauncherIdKey, "");
  activeLauncherDeviceName = prefs.getString(prefActiveLauncherNameKey, "");

  pinMode(coinPin, INPUT_PULLUP);
  pinMode(acceptorEnablePin, OUTPUT);
  setAcceptorOutput(false);
  attachInterrupt(digitalPinToInterrupt(coinPin), countPulse, FALLING);

  Serial.println("[CoinController WS] Device ID: " + controllerId);
  Serial.println("[CoinController WS] Hostname: " + controllerHostname);
  if (activeLauncherDeviceId.length() > 0) {
    Serial.println(
      "[CoinController WS] Restored active owner launcherId=" +
      activeLauncherDeviceId + " launcherName=" + activeLauncherDeviceName
    );
    refreshOwnerLease();
  }

  ensureWifiConnection();
}

void loop() {
  ensureWifiConnection();
  beginWebSocketServerIfNeeded();

  if (websocketReady && WiFi.status() == WL_CONNECTED) {
    webSocket.loop();
  }

  if (activeLauncherDeviceId.length() > 0 &&
      (millis() - lastOwnerHeartbeatAt >= sessionLeaseTimeoutMs)) {
    closeCurrentSession("Session expired due to heartbeat timeout.");
  }

  if (acceptorOpenPending &&
      (millis() - acceptorOpenRequestedAt >= acceptorOpenDelayMs)) {
    acceptorOpenPending = false;
    setAcceptorOutput(true);
    broadcastStatusEvent("acceptor_open", "Coin acceptor is open.");
  }

  if (pulses > 0 && (millis() - lastPulseTime > 200)) {
    const int amount = pulses;
    pulses = 0;
    queueCoinCredit(amount);
    Serial.printf("[CoinController WS] Coin inserted amount=%d\n", amount);
  }

  if (hasPendingCoinAck &&
      pendingCoinPublishedAt > 0 &&
      (millis() - pendingCoinPublishedAt >= coinAckRetryIntervalMs)) {
    publishPendingCoinCredit(true);
  }
}
