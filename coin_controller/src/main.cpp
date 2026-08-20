#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <ESPmDNS.h>
#ifndef WEBSOCKETS_SERVER_CLIENT_MAX
#define WEBSOCKETS_SERVER_CLIENT_MAX (20)
#endif
#include <WebSocketsServer.h>
#include <esp_system.h>

const int websocketPort = 81;
const int coinPin = 14;
const int acceptorEnablePin = 26;
const int wifiResetPin = 32;
const bool acceptorEnabledLevel = HIGH;
const unsigned long acceptorOpenDelayMs = 100;
const unsigned long sessionLeaseTimeoutMs = 60000;
const unsigned long wifiReconnectIntervalMs = 10000;
const unsigned long coinAckRetryIntervalMs = 800;
const unsigned long savedWifiConnectTimeoutMs = 10000;
const unsigned long defaultWifiConnectTimeoutMs = 20000;
const unsigned long wifiResetHoldMs = 3000;
const unsigned long wifiResetDebounceMs = 50;

const char* defaultWifiSsid = "IT - CONNECT";
const char* defaultWifiPassword = "NagaAtongGarbo2025";

const char* prefStaticIpKey = "wifi_ip";
const char* prefGatewayKey = "wifi_gw";
const char* prefSubnetKey = "wifi_sn";
const char* prefDnsKey = "wifi_dns";

const char* defaultStaticIp = "";
const char* defaultGateway = "";
const char* defaultSubnet = "";
const char* defaultDns = "";

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
bool wifiConfigured = false;
bool shouldSaveWifiConfig = false;
bool mdnsStarted = false;

String controllerId;
String controllerHostname;
String activeLauncherDeviceId = "";
String activeLauncherDeviceName = "";
String pendingCoinEventId = "";

void closeCurrentSession(const String& message);

void stopWebSocketServer() {
  if (!websocketReady) {
    return;
  }

  Serial.println("[CoinController WS] WebSocket server stopped.");
  webSocket.disconnect();
  webSocket.close();
  websocketReady = false;
  activeLauncherClientNum = -1;
}

String mdnsHostname() {
  return controllerHostname + ".local";
}

void startMDNS() {
  if (mdnsStarted || WiFi.status() != WL_CONNECTED) {
    return;
  }

  if (MDNS.begin(controllerHostname.c_str())) {
    mdnsStarted = true;
    MDNS.addService("ws", "tcp", websocketPort);
    Serial.println("[CoinController WS] mDNS started: " + mdnsHostname());
  } else {
    Serial.println("[CoinController WS] mDNS failed.");
  }
}

void stopMDNS() {
  if (!mdnsStarted) {
    return;
  }

  MDNS.end();
  mdnsStarted = false;
  Serial.println("[CoinController WS] mDNS stopped.");
}

void printWifiConnectionDetails() {
  Serial.println("[CoinController WS] WiFi connected");
  Serial.println("[CoinController WS] Device ID: " + controllerId);
  Serial.println("[CoinController WS] Hostname: " + controllerHostname);
  Serial.println("[CoinController WS] mDNS: " + mdnsHostname());
  Serial.println("[CoinController WS] WiFi SSID: " + WiFi.SSID());
  Serial.println("[CoinController WS] IP: " + WiFi.localIP().toString());
  Serial.println("[CoinController WS] Gateway: " + WiFi.gatewayIP().toString());
  Serial.println("[CoinController WS] Subnet: " + WiFi.subnetMask().toString());
  Serial.println("[CoinController WS] DNS: " + WiFi.dnsIP().toString());
  Serial.println(
    "[CoinController WS] WebSocket: ws://" + mdnsHostname() +
    ":" + String(websocketPort)
  );
}

String readWifiPref(const char* key, const char* fallback) {
  const String value = prefs.getString(key, fallback);
  return value.length() == 0 ? String(fallback) : value;
}

bool parseIpAddress(const String& value, IPAddress& ip) {
  String trimmed = value;
  trimmed.trim();
  if (trimmed.length() == 0) {
    return false;
  }
  return ip.fromString(trimmed);
}

void saveWifiManagerConfigCallback() {
  shouldSaveWifiConfig = true;
}

bool applyStaticIpConfig(
  WiFiManager& wifiManager,
  const String& staticIpValue,
  const String& gatewayValue,
  const String& subnetValue,
  const String& dnsValue
) {
  IPAddress staticIp;
  IPAddress gatewayIp;
  IPAddress subnetIp;
  IPAddress dnsIp;

  if (!parseIpAddress(staticIpValue, staticIp)) {
    Serial.println("[CoinController WS] Static IP not configured. WiFiManager will use DHCP.");
    return false;
  }
  if (!parseIpAddress(gatewayValue, gatewayIp)) {
    gatewayIp = IPAddress(staticIp[0], staticIp[1], staticIp[2], 1);
  }
  if (!parseIpAddress(subnetValue, subnetIp)) {
    subnetIp.fromString("255.255.255.0");
  }
  if (!parseIpAddress(dnsValue, dnsIp)) {
    dnsIp = gatewayIp;
  }

  wifiManager.setSTAStaticIPConfig(staticIp, gatewayIp, subnetIp, dnsIp);
  Serial.println(
    "[CoinController WS] WiFiManager static IP config ip=" +
    staticIp.toString() +
    " gateway=" + gatewayIp.toString() +
    " subnet=" + subnetIp.toString() +
    " dns=" + dnsIp.toString()
  );
  return true;
}

bool applyStaticIpToWiFi(
  const String& staticIpValue,
  const String& gatewayValue,
  const String& subnetValue,
  const String& dnsValue
) {
  IPAddress staticIp;
  IPAddress gatewayIp;
  IPAddress subnetIp;
  IPAddress dnsIp;

  if (!parseIpAddress(staticIpValue, staticIp)) {
    Serial.println("[CoinController WS] Static IP empty or invalid. Using DHCP.");
    return false;
  }
  if (!parseIpAddress(gatewayValue, gatewayIp)) {
    gatewayIp = IPAddress(staticIp[0], staticIp[1], staticIp[2], 1);
  }
  if (!parseIpAddress(subnetValue, subnetIp)) {
    subnetIp.fromString("255.255.255.0");
  }
  if (!parseIpAddress(dnsValue, dnsIp)) {
    dnsIp = gatewayIp;
  }

  const bool configured = WiFi.config(staticIp, gatewayIp, subnetIp, dnsIp);
  Serial.println(
    String("[CoinController WS] Direct WiFi static config ") +
    (configured ? "applied" : "failed") +
    " ip=" + staticIp.toString() +
    " gateway=" + gatewayIp.toString() +
    " subnet=" + subnetIp.toString() +
    " dns=" + dnsIp.toString()
  );
  return configured;
}

void clearLegacyDefaultStaticIpIfNeeded(
  String& staticIpValue,
  String& gatewayValue,
  String& subnetValue,
  String& dnsValue
) {
  if (staticIpValue == "192.168.1.100") {
    Serial.println(
      "[CoinController WS] Legacy default static IP found. Clearing it so DHCP is used."
    );
    staticIpValue = "";
    gatewayValue = "";
    subnetValue = "";
    dnsValue = "";
    prefs.putString(prefStaticIpKey, staticIpValue);
    prefs.putString(prefGatewayKey, gatewayValue);
    prefs.putString(prefSubnetKey, subnetValue);
    prefs.putString(prefDnsKey, dnsValue);
  }
}

bool waitForWifiConnection(unsigned long timeoutMs) {
  const unsigned long startedAt = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - startedAt < timeoutMs) {
    delay(250);
    Serial.print(".");
  }
  Serial.println();
  return WiFi.status() == WL_CONNECTED;
}

bool connectWithSavedWifi(unsigned long timeoutMs) {
  Serial.println("[CoinController WS] Trying saved WiFi credentials.");
  WiFi.begin();
  return waitForWifiConnection(timeoutMs);
}

bool connectWithDefaultWifi(unsigned long timeoutMs) {
  if (String(defaultWifiSsid).length() == 0) {
    return false;
  }

  Serial.println("[CoinController WS] Trying default WiFi SSID: " + String(defaultWifiSsid));
  WiFi.disconnect(false, false);
  delay(250);
  WiFi.begin(defaultWifiSsid, defaultWifiPassword);
  return waitForWifiConnection(timeoutMs);
}

void setupWifiManager() {
  String staticIpValue = readWifiPref(prefStaticIpKey, defaultStaticIp);
  String gatewayValue = readWifiPref(prefGatewayKey, defaultGateway);
  String subnetValue = readWifiPref(prefSubnetKey, defaultSubnet);
  String dnsValue = readWifiPref(prefDnsKey, defaultDns);
  clearLegacyDefaultStaticIpIfNeeded(
    staticIpValue,
    gatewayValue,
    subnetValue,
    dnsValue
  );

  char staticIpBuffer[16];
  char gatewayBuffer[16];
  char subnetBuffer[16];
  char dnsBuffer[16];
  staticIpValue.toCharArray(staticIpBuffer, sizeof(staticIpBuffer));
  gatewayValue.toCharArray(gatewayBuffer, sizeof(gatewayBuffer));
  subnetValue.toCharArray(subnetBuffer, sizeof(subnetBuffer));
  dnsValue.toCharArray(dnsBuffer, sizeof(dnsBuffer));

  WiFiManager wifiManager;
  wifiManager.setSaveConfigCallback(saveWifiManagerConfigCallback);
  wifiManager.setHostname(controllerHostname.c_str());
  wifiManager.setConfigPortalTimeout(180);
  wifiManager.setConnectTimeout(20);
  wifiManager.setConnectRetries(3);

  WiFiManagerParameter staticIpParam(
    "static_ip",
    "Static IP",
    staticIpBuffer,
    sizeof(staticIpBuffer)
  );
  WiFiManagerParameter gatewayParam(
    "gateway",
    "Gateway",
    gatewayBuffer,
    sizeof(gatewayBuffer)
  );
  WiFiManagerParameter subnetParam(
    "subnet",
    "Subnet",
    subnetBuffer,
    sizeof(subnetBuffer)
  );
  WiFiManagerParameter dnsParam(
    "dns",
    "DNS",
    dnsBuffer,
    sizeof(dnsBuffer)
  );

  wifiManager.addParameter(&staticIpParam);
  wifiManager.addParameter(&gatewayParam);
  wifiManager.addParameter(&subnetParam);
  wifiManager.addParameter(&dnsParam);

  applyStaticIpConfig(wifiManager, staticIpValue, gatewayValue, subnetValue, dnsValue);

  WiFi.mode(WIFI_STA);
  WiFi.setHostname(controllerHostname.c_str());
  applyStaticIpToWiFi(staticIpValue, gatewayValue, subnetValue, dnsValue);

  wifiConfigured = connectWithSavedWifi(savedWifiConnectTimeoutMs);
  if (!wifiConfigured) {
    wifiConfigured = connectWithDefaultWifi(defaultWifiConnectTimeoutMs);
  }

  const String portalName = "PisoCoin-Setup-" + controllerHostname.substring(controllerHostname.length() - 6);
  if (!wifiConfigured) {
    Serial.println("[CoinController WS] Starting WiFiManager portal: " + portalName);
    wifiConfigured = wifiManager.autoConnect(portalName.c_str());
    if (!wifiConfigured) {
      Serial.println("[CoinController WS] WiFiManager failed or timed out. Restarting.");
      delay(1000);
      ESP.restart();
    }
  }

  const String nextStaticIp = String(staticIpParam.getValue());
  const String nextGateway = String(gatewayParam.getValue());
  const String nextSubnet = String(subnetParam.getValue());
  const String nextDns = String(dnsParam.getValue());

  const bool staticConfigChanged =
    nextStaticIp != staticIpValue ||
    nextGateway != gatewayValue ||
    nextSubnet != subnetValue ||
    nextDns != dnsValue;

  if (shouldSaveWifiConfig || staticConfigChanged) {
    prefs.putString(prefStaticIpKey, nextStaticIp);
    prefs.putString(prefGatewayKey, nextGateway);
    prefs.putString(prefSubnetKey, nextSubnet);
    prefs.putString(prefDnsKey, nextDns);
    Serial.println("[CoinController WS] Saved WiFiManager static IP fields.");
  }

  if (staticConfigChanged) {
    Serial.println("[CoinController WS] Static IP fields changed. Restarting to apply network config.");
    delay(1000);
    ESP.restart();
  }

  startMDNS();
  printWifiConnectionDetails();
}

void resetWifiManagerIfRequested() {
  static bool wifiResetPressed = false;
  static bool wifiResetTriggered = false;
  static unsigned long wifiResetStartedAt = 0;

  const bool pressed = digitalRead(wifiResetPin) == LOW;
  const unsigned long now = millis();

  if (pressed && !wifiResetPressed && !wifiResetTriggered) {
    wifiResetPressed = true;
    wifiResetStartedAt = now;
    Serial.println(
      "[CoinController WS] WiFi reset button pressed. Hold for 3 seconds..."
    );
  }

  if (!pressed) {
    if (wifiResetPressed && !wifiResetTriggered) {
      Serial.println(
        "[CoinController WS] WiFi reset button released before 3 seconds."
      );
    }
    wifiResetPressed = false;
    wifiResetTriggered = false;
    wifiResetStartedAt = 0;
    return;
  }

  if (!wifiResetPressed ||
      wifiResetTriggered ||
      now - wifiResetStartedAt < wifiResetHoldMs ||
      now - wifiResetStartedAt < wifiResetDebounceMs) {
    return;
  }

  wifiResetTriggered = true;
  wifiResetPressed = false;

  Serial.println(
    "[CoinController WS] WiFi reset button held for 3 seconds. Resetting WiFi configuration."
  );

  stopWebSocketServer();
  closeCurrentSession("WiFi configuration reset.");

  WiFi.disconnect(true, true);

  WiFiManager wm;
  wm.resetSettings();

  prefs.remove(prefStaticIpKey);
  prefs.remove(prefGatewayKey);
  prefs.remove(prefSubnetKey);
  prefs.remove(prefDnsKey);

  delay(500);
  ESP.restart();
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

String buildStatusPayload(
  const char* type,
  const String& message,
  int allowed = -1
) {
  JsonDocument doc;
  doc["type"] = type;
  doc["message"] = message;
  if (allowed >= 0) {
    doc["allowed"] = allowed == 1;
  }
  doc["controllerId"] = controllerId;
  doc["acceptorOpen"] = acceptorOpen;
  doc["acceptorOpenPending"] = acceptorOpenPending;
  doc["activeLauncherDeviceId"] = activeLauncherDeviceId;
  doc["activeLauncherDeviceName"] = activeLauncherDeviceName;
  doc["ip"] = WiFi.localIP().toString();
  doc["hostname"] = controllerHostname;
  doc["mdnsHostname"] = mdnsHostname();

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
  bool broadcastSnapshot = true,
  int allowed = -1
) {
  const String payload = buildStatusPayload(type, message, allowed);
  sendTextToClient(clientNum, payload);
  Serial.println("[CoinController WS] Send status event: " + payload);
  if (broadcastSnapshot) {
    broadcastControllerSnapshot(message);
  }
}

void broadcastStatusEvent(
  const char* type,
  const String& message,
  bool broadcastSnapshot = true,
  int allowed = -1
) {
  const String payload = buildStatusPayload(type, message, allowed);
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
    "[WS] SESSION ACQUIRED launcherId=" + launcherId +
    " client=" + String(clientNum) +
    " launcherName=" + launcherName
  );
  activeLauncherDeviceId = launcherId;
  activeLauncherDeviceName = launcherName;
  activeLauncherClientNum = clientNum;
  acceptorOpenPending = true;
  acceptorOpenRequestedAt = millis();
  refreshOwnerLease();
  pulses = 0;
  sendStatusEventToClient(
    clientNum,
    "open_session_ack",
    "Coin controller is ready.",
    false,
    1
  );

  if (hasPendingCoinAck && pendingCoinEventId.length() > 0) {
    Serial.println(
      String("[CoinController WS] Re-sending pending coin credit for launcherId=") +
      launcherId + " eventId=" + pendingCoinEventId
    );
    publishPendingCoinCredit(true);
  }
}

void reconnectSessionOwner(
  uint8_t clientNum,
  const String& launcherId,
  const String& launcherName
) {
  activeLauncherClientNum = clientNum;
  if (launcherName.length() > 0) {
    activeLauncherDeviceName = launcherName;
  }
  refreshOwnerLease();
  Serial.println(
    "[WS] SESSION RECLAIMED launcherId=" + launcherId +
    " client=" + String(clientNum)
  );
  sendStatusEventToClient(
    clientNum,
    "open_session_ack",
    "Coin controller session restored.",
    false,
    1
  );
  if (hasPendingCoinAck && pendingCoinEventId.length() > 0) {
    publishPendingCoinCredit(true);
  }
}

void closeCurrentSession(const String& message) {
  acceptorOpenPending = false;
  setAcceptorOutput(false);
  const String closedLauncherId = activeLauncherDeviceId;

  Serial.println(
    "[WS] SESSION CLOSED launcherId=" + closedLauncherId +
    " message=" + message +
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
    Serial.println(
      String("[WS] coin credit waiting for owner reconnect eventId=") +
      pendingCoinEventId + " owner=" + activeLauncherDeviceId
    );
    return;
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
  if (activeLauncherDeviceId.length() == 0 || !acceptorOpen) {
    Serial.println(
      String("[WS] coin ignored because no active owner/open acceptor amount=") +
      amount
    );
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
        "[WS] heartbeat accepted launcherId=" + launcherId +
        " client=" + String(clientNum)
      );
    } else {
      Serial.println(
        "[WS] heartbeat/status rejected requester=" + launcherId +
        " owner=" + activeLauncherDeviceId +
        " client=" + String(clientNum)
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
        String("[WS] coin acknowledgement rejected launcherId=") +
        launcherId + " eventId=" + eventId +
        " owner=" + activeLauncherDeviceId +
        " pendingEventId=" + pendingCoinEventId
      );
    }
    return;
  }

  if (type == "open_session") {
    Serial.println(
      "[WS] open_session request launcherId=" + launcherId +
      " client=" + String(clientNum) +
      " launcherName=" + launcherName +
      " owner=" + activeLauncherDeviceId
    );

    if (launcherId.length() == 0) {
      sendStatusEventToClient(
        clientNum,
        "error",
        "Missing launcher_device_id.",
        false,
        0
      );
      return;
    }

    if (activeLauncherDeviceId.length() > 0 &&
        activeLauncherDeviceId == launcherId) {
      reconnectSessionOwner(clientNum, launcherId, launcherName);
      return;
    }

    if (activeLauncherDeviceId.length() > 0) {
      Serial.println(
        "[WS] open_session BUSY requester=" + launcherId +
        " owner=" + activeLauncherDeviceId +
        " client=" + String(clientNum)
      );
      sendStatusEventToClient(
        clientNum,
        "session_busy",
        "Another machine is currently receiving coins.",
        false,
        0
      );
      return;
    }

    openSessionForLauncher(clientNum, launcherId, launcherName);
    return;
  }

  if (type == "close_session") {
    Serial.println(
      "[WS] close_session request launcherId=" + launcherId +
      " client=" + String(clientNum) +
      " owner=" + activeLauncherDeviceId
    );

    if (activeLauncherDeviceId.length() > 0 &&
        activeLauncherDeviceId == launcherId) {
      closeCurrentSession("Coin controller session closed.");
    } else {
      Serial.println(
        "[WS] close_session ignored requester=" + launcherId +
        " owner=" + activeLauncherDeviceId
      );
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
    "[CoinController WS] WiFi disconnected. Reconnecting with saved WiFiManager credentials."
  );
  stopWebSocketServer();
  stopMDNS();
  WiFi.mode(WIFI_STA);
  WiFi.setHostname(controllerHostname.c_str());
  WiFi.reconnect();
}

void beginWebSocketServerIfNeeded() {
  if (websocketReady || WiFi.status() != WL_CONNECTED) {
    return;
  }

  startMDNS();
  webSocket.begin();
  webSocket.onEvent(
    [](uint8_t clientNum, WStype_t type, uint8_t* payload, size_t length) {
      switch (type) {
        case WStype_CONNECTED: {
          IPAddress ip = webSocket.remoteIP(clientNum);
          Serial.println(
            String("[WS] client connected client=") + clientNum +
            " ip=" + ip.toString() +
            " owner=" + activeLauncherDeviceId
          );
          sendControllerSnapshotToClient(clientNum, "Coin controller connected.");
          break;
        }
        case WStype_DISCONNECTED:
          Serial.println(
            String("[WS] client disconnected client=") + clientNum +
            " owner=" + activeLauncherDeviceId
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
    String("[WS] WebSocket server started at ws://") +
    mdnsHostname() + ":" + String(websocketPort) +
    " ip=" + WiFi.localIP().toString()
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
  activeLauncherDeviceId = "";
  activeLauncherDeviceName = "";
  activeLauncherClientNum = -1;

  pinMode(wifiResetPin, INPUT_PULLUP);
  pinMode(coinPin, INPUT_PULLUP);
  pinMode(acceptorEnablePin, OUTPUT);
  setAcceptorOutput(false);
  attachInterrupt(digitalPinToInterrupt(coinPin), countPulse, FALLING);

  Serial.println("[CoinController WS] Device ID: " + controllerId);
  Serial.println("[CoinController WS] Hostname: " + controllerHostname);

  Serial.println("[WS] No active session owner after boot.");

  setupWifiManager();
}

void loop() {
  ensureWifiConnection();
  beginWebSocketServerIfNeeded();

  resetWifiManagerIfRequested();

  if (websocketReady && WiFi.status() == WL_CONNECTED) {
    webSocket.loop();
  }

  if (activeLauncherDeviceId.length() > 0 &&
      (millis() - lastOwnerHeartbeatAt >= sessionLeaseTimeoutMs)) {
    Serial.println(
      "[WS] SESSION EXPIRED launcherId=" + activeLauncherDeviceId
    );
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
