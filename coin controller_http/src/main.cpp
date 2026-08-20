#include <Arduino.h>
#include <ArduinoJson.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiManager.h>

// ============================================================
// CONFIGURATION
// ============================================================

const uint16_t HTTP_PORT = 80;

// Coin acceptor
const int COIN_PIN = 14;
const int ACCEPTOR_ENABLE_PIN = 26;
const bool ACCEPTOR_ENABLED_LEVEL = HIGH;

// WiFiManager reset button
// Button: GPIO 32 ---- BUTTON ---- GND
const int WIFI_RESET_PIN = 32;
const unsigned long WIFI_RESET_HOLD_MS = 3000;
const unsigned long WIFI_RESET_DEBOUNCE_MS = 50;

// Session
const unsigned long ACCEPTOR_OPEN_DELAY_MS = 100;
const unsigned long SESSION_LEASE_TIMEOUT_MS = 60000;

// HTTP
const unsigned long HTTP_REQUEST_TIMEOUT_MS = 500;
const size_t MAX_HTTP_LINE_LENGTH = 192;
const size_t MAX_HTTP_HEADER_BYTES = 1024;
const size_t MAX_HTTP_BODY_BYTES = 512;

// Coin event queue
const size_t COIN_EVENT_QUEUE_SIZE = 8;
const unsigned long UNACKED_EVENT_RECOVERY_MS = 300000;

// WiFi
const unsigned long WIFI_RECONNECT_INTERVAL_MS = 15000;
const unsigned long NETWORK_STATUS_INTERVAL_MS = 5000;

// WiFi credentials
// Replace these with your actual WiFi network credentials.
const char* WIFI_SSID = "Noah Tyler Tab Zone";
const char* WIFI_PASSWORD = "Viking@2026";

// ============================================================
// PREFERENCES
// ============================================================

const char* PREF_NAMESPACE = "coinctrl_http";

Preferences prefs;

// ============================================================
// WIFI / HTTP
// ============================================================

WiFiServer wifiServer(HTTP_PORT);

bool wifiServerStarted = false;
bool mdnsStarted = false;

unsigned long lastWifiReconnectAt = 0;
unsigned long lastNetworkStatusAt = 0;

// ============================================================
// CONTROLLER ID
// ============================================================

String controllerId;
String controllerHostname;

// ============================================================
// STATIC IP / API NETWORK CONFIGURATION
// ============================================================

String configuredIp = "192.168.1.100";
String configuredGateway = "192.168.1.1";
String configuredSubnet = "255.255.255.0";
String configuredDns = "192.168.1.1";

bool staticIpEnabled = false;

// ============================================================
// COIN ACCEPTOR
// ============================================================

bool acceptorOpen = false;
bool acceptorOpenPending = false;

unsigned long acceptorOpenRequestedAt = 0;

volatile int pulses = 0;
volatile unsigned long lastPulseTime = 0;

portMUX_TYPE coinPulseMux = portMUX_INITIALIZER_UNLOCKED;

// ============================================================
// SESSION
// ============================================================

String activeLauncherDeviceId = "";
String activeLauncherDeviceName = "";

unsigned long lastOwnerHeartbeatAt = 0;

// ============================================================
// COIN EVENTS
// ============================================================

unsigned long lastCoinEventId = 0;

struct CoinEvent {
    String eventId;
    int amount = 0;

    String launcherDeviceId;
    String launcherDeviceName;

    unsigned long timestamp = 0;

    bool inUse = false;
    bool acknowledged = false;
};

CoinEvent coinEvents[COIN_EVENT_QUEUE_SIZE];

size_t nextCoinEventSlot = 0;

// ============================================================
// WIFI RESET BUTTON
// ============================================================

bool wifiResetButtonPressed = false;
unsigned long wifiResetButtonStartedAt = 0;
unsigned long wifiResetLastChangeAt = 0;
bool wifiResetAlreadyTriggered = false;

// ============================================================
// CONTROLLER ID
// ============================================================

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

// ============================================================
// HOSTNAME
// ============================================================

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

// ============================================================
// WIFI STATUS
// ============================================================

bool wifiConnected() {

    return WiFi.status() == WL_CONNECTED;
}

// ============================================================
// STATIC IP / API NETWORK HELPERS
// ============================================================

void loadStaticIpSettings() {

    configuredIp =
        prefs.getString("static_ip", "");

    configuredGateway =
        prefs.getString("gateway", "");

    configuredSubnet =
        prefs.getString(
            "subnet",
            "255.255.255.0"
        );

    configuredDns =
        prefs.getString("dns", "");

    staticIpEnabled =
        configuredIp.length() > 0 &&
        configuredGateway.length() > 0;
}

bool parseIPAddress(
    const String& value,
    IPAddress& address
) {
    return address.fromString(value);
}

bool validateStaticIpSettings(
    const String& ipValue,
    const String& gatewayValue,
    const String& subnetValue,
    const String& dnsValue
) {

    if (ipValue.length() == 0) {
        return true;
    }

    IPAddress ip;
    IPAddress gateway;
    IPAddress subnet;
    IPAddress dns;

    if (!parseIPAddress(ipValue, ip)) {
        return false;
    }

    if (!parseIPAddress(gatewayValue, gateway)) {
        return false;
    }

    if (!parseIPAddress(subnetValue, subnet)) {
        return false;
    }

    if (dnsValue.length() > 0 &&
        !parseIPAddress(dnsValue, dns)) {
        return false;
    }

    return true;
}

void applySavedStaticIp(
    WiFiManager& wifiManager
) {

    if (!staticIpEnabled) {
        Serial.println(
            "[NET] Static IP disabled. Using DHCP."
        );
        return;
    }

    IPAddress ip;
    IPAddress gateway;
    IPAddress subnet;
    IPAddress dns;

    if (!parseIPAddress(configuredIp, ip) ||
        !parseIPAddress(configuredGateway, gateway) ||
        !parseIPAddress(configuredSubnet, subnet)) {

        Serial.println(
            "[NET] Saved static IP configuration is invalid. Using DHCP."
        );

        staticIpEnabled = false;
        return;
    }

    if (configuredDns.length() > 0 &&
        parseIPAddress(configuredDns, dns)) {

        wifiManager.setSTAStaticIPConfig(
            ip,
            gateway,
            subnet,
            dns
        );

    } else {

        wifiManager.setSTAStaticIPConfig(
            ip,
            gateway,
            subnet
        );
    }

    Serial.println(
        "[NET] Static IP configured before WiFiManager connection."
    );

    Serial.println(
        "[NET] IP: " + configuredIp
    );

    Serial.println(
        "[NET] Gateway: " + configuredGateway
    );

    Serial.println(
        "[NET] Subnet: " + configuredSubnet
    );

    if (configuredDns.length() > 0) {
        Serial.println(
            "[NET] DNS: " + configuredDns
        );
    }
}

// ============================================================
// MDNS
// ============================================================

String mdnsHostname() {

    return controllerHostname + ".local";
}

void startMDNS() {
    if (mdnsStarted || WiFi.status() != WL_CONNECTED) {
        return;
    }

    if (MDNS.begin(controllerHostname.c_str())) {
        mdnsStarted = true;

        MDNS.addService("http", "tcp", HTTP_PORT);

        Serial.println("[mDNS] Started");
        Serial.print("[mDNS] http://");
        Serial.print(controllerHostname);
        Serial.println(".local");
    } else {
        Serial.println("[mDNS] Failed to start");
    }
}

void stopMDNS() {
    if (!mdnsStarted) {
        return;
    }

    MDNS.end();
    mdnsStarted = false;

    Serial.println("[mDNS] Stopped");
}

// ============================================================
// ACCEPTOR
// ============================================================

void setAcceptorOutput(bool enabled) {

    acceptorOpen = enabled;

    digitalWrite(
        ACCEPTOR_ENABLE_PIN,
        enabled
            ? ACCEPTOR_ENABLED_LEVEL
            : !ACCEPTOR_ENABLED_LEVEL
    );

    if (!enabled) {

        portENTER_CRITICAL(&coinPulseMux);

        pulses = 0;
        lastPulseTime = 0;

        portEXIT_CRITICAL(&coinPulseMux);
    }

    Serial.println(
        String("[COIN] Acceptor ") +
        (enabled ? "OPEN" : "CLOSED")
    );
}

// ============================================================
// SESSION
// ============================================================

void refreshOwnerLease() {

    lastOwnerHeartbeatAt = millis();
}

void closeCurrentSession(const String& message) {

    Serial.println(
        "[SESSION] Closed owner=" +
        activeLauncherDeviceId +
        " message=" +
        message
    );

    acceptorOpenPending = false;

    setAcceptorOutput(false);

    activeLauncherDeviceId = "";
    activeLauncherDeviceName = "";

    lastOwnerHeartbeatAt = 0;
}

// ============================================================
// COIN EVENT ID
// ============================================================

String nextCoinEventId() {

    lastCoinEventId++;

    return controllerId +
           "_" +
           String(lastCoinEventId);
}

// ============================================================
// FIND COIN EVENT
// ============================================================

int findCoinEventById(
    const String& eventId
) {

    if (eventId.length() == 0) {
        return -1;
    }

    for (size_t i = 0;
         i < COIN_EVENT_QUEUE_SIZE;
         i++) {

        if (
            coinEvents[i].inUse &&
            coinEvents[i].eventId == eventId
        ) {
            return static_cast<int>(i);
        }
    }

    return -1;
}

// ============================================================
// FIND PENDING EVENT FOR LAUNCHER
// ============================================================

int findPendingCoinEventForLauncher(
    const String& launcherId
) {

    for (size_t i = 0;
         i < COIN_EVENT_QUEUE_SIZE;
         i++) {

        const CoinEvent& event = coinEvents[i];

        if (
            event.inUse &&
            !event.acknowledged &&
            event.launcherDeviceId == launcherId
        ) {
            return static_cast<int>(i);
        }
    }

    return -1;
}

// ============================================================
// FIND FIRST UNACKNOWLEDGED EVENT
// ============================================================

int findFirstUnackedCoinEvent() {

    for (size_t i = 0;
         i < COIN_EVENT_QUEUE_SIZE;
         i++) {

        if (
            coinEvents[i].inUse &&
            !coinEvents[i].acknowledged
        ) {
            return static_cast<int>(i);
        }
    }

    return -1;
}

// ============================================================
// EXPIRE OLD EVENTS
// ============================================================

void expireStaleCoinEvents() {

    const unsigned long now = millis();

    for (size_t i = 0;
         i < COIN_EVENT_QUEUE_SIZE;
         i++) {

        CoinEvent& event = coinEvents[i];

        if (
            !event.inUse ||
            event.acknowledged
        ) {
            continue;
        }

        if (
            now - event.timestamp >=
            UNACKED_EVENT_RECOVERY_MS
        ) {

            Serial.println(
                "[COIN] Expiring stale eventId=" +
                event.eventId
            );

            event.inUse = false;
            event.acknowledged = true;
        }
    }
}

// ============================================================
// RESERVE EVENT SLOT
// ============================================================

size_t reserveCoinEventSlot() {

    for (
        size_t i = 0;
        i < COIN_EVENT_QUEUE_SIZE;
        i++
    ) {

        const size_t slot =
            (nextCoinEventSlot + i) %
            COIN_EVENT_QUEUE_SIZE;

        if (
            !coinEvents[slot].inUse ||
            coinEvents[slot].acknowledged
        ) {

            nextCoinEventSlot =
                (slot + 1) %
                COIN_EVENT_QUEUE_SIZE;

            return slot;
        }
    }

    size_t oldestSlot = 0;

    unsigned long oldestTimestamp =
        coinEvents[0].timestamp;

    for (
        size_t i = 1;
        i < COIN_EVENT_QUEUE_SIZE;
        i++
    ) {

        if (
            coinEvents[i].timestamp <
            oldestTimestamp
        ) {

            oldestTimestamp =
                coinEvents[i].timestamp;

            oldestSlot = i;
        }
    }

    Serial.println(
        "[COIN] Event queue full. " \
        "Dropping oldest event."
    );

    nextCoinEventSlot =
        (oldestSlot + 1) %
        COIN_EVENT_QUEUE_SIZE;

    return oldestSlot;
}

// ============================================================
// QUEUE COIN
// ============================================================

void queueCoinCredit(int amount) {

    if (
        activeLauncherDeviceId.length() == 0 ||
        !acceptorOpen ||
        amount <= 0
    ) {

        Serial.println(
            "[COIN] Ignored pulse without active owner."
        );

        return;
    }

    const size_t slot =
        reserveCoinEventSlot();

    CoinEvent& event =
        coinEvents[slot];

    event.eventId =
        nextCoinEventId();

    event.amount = amount;

    event.launcherDeviceId =
        activeLauncherDeviceId;

    event.launcherDeviceName =
        activeLauncherDeviceName;

    event.timestamp =
        millis();

    event.inUse = true;
    event.acknowledged = false;

    Serial.println(
        "[COIN] Queued eventId=" +
        event.eventId +
        " amount=" +
        String(amount) +
        " owner=" +
        activeLauncherDeviceId
    );
}

// ============================================================
// JSON RESPONSE
// ============================================================

void writeJsonResponse(
    WiFiClient& client,
    int statusCode,
    const String& body
) {

    const char* statusText =
        statusCode == 200 ? "OK" :
        statusCode == 400 ? "Bad Request" :
        statusCode == 403 ? "Forbidden" :
        statusCode == 404 ? "Not Found" :
        statusCode == 408 ? "Request Timeout" :
        statusCode == 409 ? "Conflict" :
        statusCode == 413 ? "Payload Too Large" :
        statusCode == 414 ? "URI Too Long" :
        "Internal Server Error";

    client.print("HTTP/1.1 ");
    client.print(statusCode);
    client.print(" ");
    client.println(statusText);

    client.println(
        "Content-Type: application/json"
    );

    client.println(
        "Cache-Control: no-store"
    );

    client.println(
        "Connection: close"
    );

    client.print(
        "Content-Length: "
    );

    client.println(
        body.length()
    );

    client.println();

    client.print(body);
}

// ============================================================
// STATUS JSON
// ============================================================

String statusPayload(
    const char* type = "controller_status",
    const String& message =
        "Coin controller status ready."
) {

    JsonDocument doc;

    doc["type"] = type;
    doc["message"] = message;

    doc["controllerId"] =
        controllerId;

    doc["hostname"] =
        controllerHostname;

    doc["mdnsHostname"] =
        mdnsHostname();

    doc["acceptorOpen"] =
        acceptorOpen;

    doc["acceptorOpenPending"] =
        acceptorOpenPending;

    doc["activeLauncherDeviceId"] =
        activeLauncherDeviceId;

    doc["activeLauncherDeviceName"] =
        activeLauncherDeviceName;

    JsonObject network =
        doc["network"].to<JsonObject>();

    network["connected"] =
        wifiConnected();

    network["ip"] =
        WiFi.localIP().toString();

    network["ssid"] =
        WiFi.SSID();

    network["rssi"] =
        wifiConnected()
            ? WiFi.RSSI()
            : 0;

    network["mdns"] =
        mdnsStarted
            ? mdnsHostname()
            : "";

    network["httpPort"] =
        HTTP_PORT;

    network["staticIpEnabled"] =
        staticIpEnabled;

    network["configuredIp"] =
        staticIpEnabled
            ? configuredIp
            : "";

    network["gateway"] =
        WiFi.gatewayIP().toString();

    network["subnet"] =
        WiFi.subnetMask().toString();

    String payload;

    serializeJson(
        doc,
        payload
    );

    return payload;
}

// ============================================================
// COIN EVENT JSON
// ============================================================

String coinEventPayload(
    const String& launcherId
) {

    JsonDocument doc;

    const int eventIndex =
        findPendingCoinEventForLauncher(
            launcherId
        );

    if (eventIndex < 0) {

        doc["type"] =
            "no_event";

    } else {

        const CoinEvent& event =
            coinEvents[eventIndex];

        doc["type"] =
            "coin_inserted";

        doc["eventId"] =
            event.eventId;

        doc["amount"] =
            event.amount;

        doc["controllerId"] =
            controllerId;

        doc["activeLauncherDeviceId"] =
            event.launcherDeviceId;

        doc["activeLauncherDeviceName"] =
            event.launcherDeviceName;

        doc["timestamp"] =
            event.timestamp;
    }

    String payload;

    serializeJson(
        doc,
        payload
    );

    return payload;
}

// ============================================================
// QUERY PARAMETER
// ============================================================

String queryValue(
    const String& path,
    const String& key
) {

    const int queryStart =
        path.indexOf('?');

    if (queryStart < 0) {
        return "";
    }

    String query =
        path.substring(
            queryStart + 1
        );

    const String needle =
        key + "=";

    int start =
        query.indexOf(needle);

    if (start < 0) {
        return "";
    }

    start += needle.length();

    int end =
        query.indexOf(
            '&',
            start
        );

    if (end < 0) {
        end = query.length();
    }

    return query.substring(
        start,
        end
    );
}

// ============================================================
// ROUTE ONLY
// ============================================================

String routeOnly(
    const String& path
) {

    const int queryStart =
        path.indexOf('?');

    return queryStart < 0
        ? path
        : path.substring(
            0,
            queryStart
        );
}

// ============================================================
// JSON BODY
// ============================================================

bool parseJsonBody(
    const String& body,
    JsonDocument& doc,
    WiFiClient& client
) {

    const DeserializationError error =
        deserializeJson(
            doc,
            body
        );

    if (!error) {
        return true;
    }

    writeJsonResponse(
        client,
        400,
        "{\"type\":\"error\","
        "\"message\":\"Invalid JSON body.\"}"
    );

    return false;
}

// ============================================================
// OPEN SESSION
// ============================================================

void handleOpenSession(
    WiFiClient& client,
    const String& body
) {

    JsonDocument doc;

    if (!parseJsonBody(
        body,
        doc,
        client
    )) {
        return;
    }

    const String launcherId =
        String(
            (const char*)
            (doc["launcher_device_id"] | "")
        );

    const String launcherName =
        String(
            (const char*)
            (doc["launcher_device_name"] | "")
        );

    if (launcherId.length() == 0) {

        writeJsonResponse(
            client,
            400,
            "{\"type\":\"error\","
            "\"allowed\":false,"
            "\"message\":\"Missing launcher_device_id.\"}"
        );

        return;
    }

    // --------------------------------------------------------
    // No active session
    // --------------------------------------------------------

    if (
        activeLauncherDeviceId.length() == 0
    ) {

        const int reservedEventIndex =
            findFirstUnackedCoinEvent();

        if (
            reservedEventIndex >= 0 &&
            coinEvents[
                reservedEventIndex
            ].launcherDeviceId != launcherId
        ) {

            JsonDocument response;

            response["type"] =
                "session_busy";

            response["allowed"] =
                false;

            response["message"] =
                "Coin credit recovery is reserved for the previous machine.";

            response["activeLauncherDeviceId"] =
                coinEvents[
                    reservedEventIndex
                ].launcherDeviceId;

            response["activeLauncherDeviceName"] =
                coinEvents[
                    reservedEventIndex
                ].launcherDeviceName;

            String payload;

            serializeJson(
                response,
                payload
            );

            writeJsonResponse(
                client,
                409,
                payload
            );

            return;
        }

        activeLauncherDeviceId =
            launcherId;

        activeLauncherDeviceName =
            launcherName;

        acceptorOpenPending =
            true;

        acceptorOpenRequestedAt =
            millis();

        refreshOwnerLease();

        portENTER_CRITICAL(
            &coinPulseMux
        );

        pulses = 0;
        lastPulseTime = 0;

        portEXIT_CRITICAL(
            &coinPulseMux
        );

        Serial.println(
            "[SESSION] Acquired owner=" +
            launcherId
        );

        JsonDocument response;

        response["type"] =
            "open_session_ack";

        response["allowed"] =
            true;

        response["message"] =
            "Coin controller is ready.";

        response["activeLauncherDeviceId"] =
            activeLauncherDeviceId;

        response["activeLauncherDeviceName"] =
            activeLauncherDeviceName;

        String payload;

        serializeJson(
            response,
            payload
        );

        writeJsonResponse(
            client,
            200,
            payload
        );

        return;
    }

    // --------------------------------------------------------
    // Same owner
    // --------------------------------------------------------

    if (
        activeLauncherDeviceId ==
        launcherId
    ) {

        activeLauncherDeviceName =
            launcherName;

        refreshOwnerLease();

        JsonDocument response;

        response["type"] =
            "open_session_ack";

        response["allowed"] =
            true;

        response["message"] =
            "Coin controller session restored.";

        response["activeLauncherDeviceId"] =
            activeLauncherDeviceId;

        response["activeLauncherDeviceName"] =
            activeLauncherDeviceName;

        String payload;

        serializeJson(
            response,
            payload
        );

        writeJsonResponse(
            client,
            200,
            payload
        );

        return;
    }

    // --------------------------------------------------------
    // Another owner
    // --------------------------------------------------------

    JsonDocument response;

    response["type"] =
        "session_busy";

    response["allowed"] =
        false;

    response["message"] =
        "Another machine is currently receiving coins.";

    response["activeLauncherDeviceId"] =
        activeLauncherDeviceId;

    response["activeLauncherDeviceName"] =
        activeLauncherDeviceName;

    String payload;

    serializeJson(
        response,
        payload
    );

    writeJsonResponse(
        client,
        409,
        payload
    );
}

// ============================================================
// CLOSE SESSION
// ============================================================

void handleCloseSession(
    WiFiClient& client,
    const String& body
) {

    JsonDocument doc;

    if (!parseJsonBody(
        body,
        doc,
        client
    )) {
        return;
    }

    const String launcherId =
        String(
            (const char*)
            (doc["launcher_device_id"] | "")
        );

    if (
        activeLauncherDeviceId.length() > 0 &&
        activeLauncherDeviceId == launcherId
    ) {

        closeCurrentSession(
            "Coin controller session closed."
        );

        writeJsonResponse(
            client,
            200,
            statusPayload(
                "close_session_ack",
                "Coin controller session closed."
            )
        );

        return;
    }

    writeJsonResponse(
        client,
        403,
        "{\"type\":\"ignored\","
        "\"message\":\"Close request ignored for non-owner launcher.\"}"
    );
}

// ============================================================
// HEARTBEAT
// ============================================================

void handleHeartbeat(
    WiFiClient& client,
    const String& body
) {

    JsonDocument doc;

    if (!parseJsonBody(
        body,
        doc,
        client
    )) {
        return;
    }

    const String launcherId =
        String(
            (const char*)
            (doc["launcher_device_id"] | "")
        );

    if (
        activeLauncherDeviceId.length() > 0 &&
        activeLauncherDeviceId == launcherId
    ) {

        refreshOwnerLease();

        writeJsonResponse(
            client,
            200,
            statusPayload(
                "controller_status",
                "Heartbeat accepted."
            )
        );

        return;
    }

    writeJsonResponse(
        client,
        403,
        statusPayload(
            "controller_status",
            "Heartbeat rejected."
        )
    );
}

// ============================================================
// EVENTS
// ============================================================

void handleEvents(
    WiFiClient& client,
    const String& path
) {

    const String launcherId =
        queryValue(
            path,
            "launcher_device_id"
        );

    if (
        activeLauncherDeviceId.length() == 0 ||
        activeLauncherDeviceId != launcherId
    ) {

        writeJsonResponse(
            client,
            200,
            "{\"type\":\"no_event\"}"
        );

        return;
    }

    // Polling for events also acts as
    // an owner activity signal.

    refreshOwnerLease();

    writeJsonResponse(
        client,
        200,
        coinEventPayload(
            launcherId
        )
    );
}

// ============================================================
// COIN ACK
// ============================================================

void handleCoinAck(
    WiFiClient& client,
    const String& body
) {

    JsonDocument doc;

    if (!parseJsonBody(
        body,
        doc,
        client
    )) {
        return;
    }

    const String launcherId =
        String(
            (const char*)
            (doc["launcher_device_id"] | "")
        );

    String eventId =
        String(
            (const char*)
            (doc["event_id"] | "")
        );

    if (eventId.length() == 0) {

        eventId =
            String(
                (const char*)
                (doc["eventId"] | "")
            );
    }

    const int eventIndex =
        findCoinEventById(
            eventId
        );

    if (
        eventIndex >= 0 &&
        coinEvents[
            eventIndex
        ].launcherDeviceId ==
            launcherId
    ) {

        if (
            !coinEvents[
                eventIndex
            ].acknowledged
        ) {

            coinEvents[
                eventIndex
            ].acknowledged = true;

            Serial.println(
                "[COIN] Acknowledged eventId=" +
                eventId
            );
        }

        refreshOwnerLease();

        writeJsonResponse(
            client,
            200,
            "{\"type\":\"coin_credit_ack\","
            "\"message\":\"Coin credit acknowledged.\"}"
        );

        return;
    }

    writeJsonResponse(
        client,
        403,
        "{\"type\":\"ignored\","
        "\"message\":\"Coin acknowledgement ignored.\"}"
    );
}

// ============================================================
// ROUTER
// ============================================================

void routeApiRequest(
    WiFiClient& client,
    const String& method,
    const String& path,
    const String& body
) {

    const String route =
        routeOnly(path);

    if (
        method == "GET" &&
        route == "/api/status"
    ) {

        writeJsonResponse(
            client,
            200,
            statusPayload()
        );
    }

    else if (
        method == "POST" &&
        route == "/api/session/open"
    ) {

        handleOpenSession(
            client,
            body
        );
    }

    else if (
        method == "POST" &&
        route == "/api/session/close"
    ) {

        handleCloseSession(
            client,
            body
        );
    }

    else if (
        method == "POST" &&
        route == "/api/session/heartbeat"
    ) {

        handleHeartbeat(
            client,
            body
        );
    }

    else if (
        method == "GET" &&
        route == "/api/events"
    ) {

        handleEvents(
            client,
            path
        );
    }

    else if (
        method == "POST" &&
        route == "/api/coin/ack"
    ) {

        handleCoinAck(
            client,
            body
        );
    }

    else {

        writeJsonResponse(
            client,
            404,
            "{\"type\":\"error\","
            "\"message\":\"Endpoint not found.\"}"
        );
    }
}

// ============================================================
// READ HTTP LINE
// ============================================================

String readHttpLine(
    WiFiClient& client,
    bool& tooLong,
    bool& timedOut
) {

    String line;

    line.reserve(96);

    tooLong = false;
    timedOut = false;

    const unsigned long startedAt =
        millis();

    while (
        client.connected() &&
        millis() - startedAt <
            HTTP_REQUEST_TIMEOUT_MS
    ) {

        while (client.available()) {

            const char c =
                static_cast<char>(
                    client.read()
                );

            if (c == '\r') {
                continue;
            }

            if (c == '\n') {
                return line;
            }

            if (
                line.length() >=
                MAX_HTTP_LINE_LENGTH
            ) {

                tooLong = true;

                return line;
            }

            line += c;
        }

        delay(1);
    }

    timedOut = true;

    return line;
}

// ============================================================
// HTTP CLIENT
// ============================================================

void handleHttpClient(
    WiFiClient& client
) {

    if (!client) {
        return;
    }

    client.setTimeout(
        HTTP_REQUEST_TIMEOUT_MS
    );

    bool lineTooLong = false;
    bool timedOut = false;

    const String requestLine =
        readHttpLine(
            client,
            lineTooLong,
            timedOut
        );

    if (lineTooLong) {

        writeJsonResponse(
            client,
            414,
            "{\"type\":\"error\","
            "\"message\":\"HTTP request line is too long.\"}"
        );

        client.stop();

        return;
    }

    if (timedOut || requestLine.length() == 0) {

        client.stop();

        return;
    }

    const int firstSpace =
        requestLine.indexOf(' ');

    const int secondSpace =
        requestLine.indexOf(
            ' ',
            firstSpace + 1
        );

    if (
        firstSpace < 0 ||
        secondSpace < 0
    ) {

        writeJsonResponse(
            client,
            400,
            "{\"type\":\"error\","
            "\"message\":\"Invalid HTTP request.\"}"
        );

        client.stop();

        return;
    }

    const String method =
        requestLine.substring(
            0,
            firstSpace
        );

    const String path =
        requestLine.substring(
            firstSpace + 1,
            secondSpace
        );

    int contentLength = 0;

    size_t headerBytes =
        requestLine.length();

    // --------------------------------------------------------
    // Headers
    // --------------------------------------------------------

    while (client.connected()) {

        lineTooLong = false;
        timedOut = false;

        const String headerLine =
            readHttpLine(
                client,
                lineTooLong,
                timedOut
            );

        if (lineTooLong) {

            writeJsonResponse(
                client,
                414,
                "{\"type\":\"error\","
                "\"message\":\"HTTP header line is too long.\"}"
            );

            client.stop();

            return;
        }

        if (timedOut) {

            client.stop();

            return;
        }

        if (headerLine.length() == 0) {
            break;
        }

        headerBytes +=
            headerLine.length();

        if (
            headerBytes >
            MAX_HTTP_HEADER_BYTES
        ) {

            writeJsonResponse(
                client,
                413,
                "{\"type\":\"error\","
                "\"message\":\"HTTP headers are too large.\"}"
            );

            client.stop();

            return;
        }

        String lowerHeader =
            headerLine;

        lowerHeader.toLowerCase();

        if (
            lowerHeader.startsWith(
                "content-length:"
            )
        ) {

            contentLength =
                lowerHeader
                    .substring(15)
                    .toInt();
        }
    }

    if (
        contentLength < 0 ||
        static_cast<size_t>(
            contentLength
        ) > MAX_HTTP_BODY_BYTES
    ) {

        writeJsonResponse(
            client,
            413,
            "{\"type\":\"error\","
            "\"message\":\"HTTP body is too large.\"}"
        );

        client.stop();

        return;
    }

    // --------------------------------------------------------
    // Body
    // --------------------------------------------------------

    String body;

    if (contentLength > 0) {

        body.reserve(
            contentLength
        );
    }

    const unsigned long bodyStartedAt =
        millis();

    while (
        body.length() <
            static_cast<size_t>(
                contentLength
            ) &&
        millis() - bodyStartedAt <
            HTTP_REQUEST_TIMEOUT_MS
    ) {

        while (
            client.available() &&
            body.length() <
                static_cast<size_t>(
                    contentLength
                )
        ) {

            body += static_cast<char>(
                client.read()
            );
        }

        if (
            body.length() <
            static_cast<size_t>(
                contentLength
            )
        ) {
            delay(1);
        }
    }

    if (
        body.length() <
        static_cast<size_t>(
            contentLength
        )
    ) {

        writeJsonResponse(
            client,
            408,
            "{\"type\":\"error\","
            "\"message\":\"HTTP body timed out.\"}"
        );

        client.stop();

        return;
    }

    // --------------------------------------------------------
    // Route
    // --------------------------------------------------------

    routeApiRequest(
        client,
        method,
        path,
        body
    );

    delay(1);

    client.stop();
}

// ============================================================
// HTTP SERVER
// ============================================================

void startHttpServer() {

    if (wifiServerStarted) {
        return;
    }

    wifiServer.begin();

    wifiServerStarted = true;

    Serial.println(
        "[HTTP] Wi-Fi REST server listening on port 80."
    );
}

// ============================================================
// HANDLE HTTP
// ============================================================

void handleHttpServer() {

    // Process several waiting clients per loop,
    // but never monopolize the ESP32 forever.

    const uint8_t maxClientsPerLoop = 4;

    for (
        uint8_t i = 0;
        i < maxClientsPerLoop;
        i++
    ) {

        WiFiClient client =
            wifiServer.available();

        if (!client) {
            break;
        }

        handleHttpClient(client);
    }
}

// ============================================================
// WIFI RESET
// ============================================================

void resetWiFiCredentials() {

    Serial.println(
        "[WIFI] Reset button detected."
    );

    Serial.println(
        "[WIFI] Clearing saved WiFi credentials..."
    );

    // This clears WiFiManager's stored credentials.
    WiFiManager wifiManager;

    wifiManager.resetSettings();

    // Also clear the optional static API IP configuration.
    prefs.remove("static_ip");
    prefs.remove("gateway");
    prefs.remove("subnet");
    prefs.remove("dns");

    configuredIp = "";
    configuredGateway = "";
    configuredSubnet = "255.255.255.0";
    configuredDns = "";
    staticIpEnabled = false;

    Serial.println(
        "[WIFI] WiFi and static IP credentials cleared."
    );

    Serial.println(
        "[WIFI] Restarting..."
    );

    delay(100);

    ESP.restart();
}

// ============================================================
// WIFI RESET BUTTON
// ============================================================

void handleWifiResetButton() {

    const bool pressed =
        digitalRead(
            WIFI_RESET_PIN
        ) == LOW;

    const unsigned long now =
        millis();

    // --------------------------------------------------------
    // Button pressed
    // --------------------------------------------------------

    if (pressed) {

        if (!wifiResetButtonPressed) {

            // Debounce
            if (
                now -
                wifiResetLastChangeAt <
                WIFI_RESET_DEBOUNCE_MS
            ) {
                return;
            }

            wifiResetButtonPressed = true;

            wifiResetButtonStartedAt =
                now;

            wifiResetAlreadyTriggered =
                false;

            wifiResetLastChangeAt =
                now;

            Serial.println(
                "[WIFI] Reset button pressed. "
                "Hold for 3 seconds..."
            );

            return;
        }

        // ----------------------------------------------------
        // Held for 3 seconds
        // ----------------------------------------------------

        if (
            !wifiResetAlreadyTriggered &&
            now -
                wifiResetButtonStartedAt >=
                WIFI_RESET_HOLD_MS
        ) {

            wifiResetAlreadyTriggered =
                true;

            resetWiFiCredentials();

            return;
        }
    }

    // --------------------------------------------------------
    // Button released
    // --------------------------------------------------------

    else {

        if (wifiResetButtonPressed) {

            wifiResetButtonPressed =
                false;

            wifiResetLastChangeAt =
                now;

            wifiResetAlreadyTriggered =
                false;

            Serial.println(
                "[WIFI] Reset button released."
            );
        }
    }
}

// ============================================================
// WIFI SETUP
// ============================================================

void setupWiFi() {

    WiFi.mode(WIFI_STA);

    WiFi.setAutoReconnect(true);

    WiFi.persistent(true);

    WiFi.setHostname(
        controllerHostname.c_str()
    );

    // --------------------------------------------------------
    // Load saved API/static IP configuration
    // --------------------------------------------------------

    loadStaticIpSettings();

    WiFiManager wifiManager;

    // --------------------------------------------------------
    // Connect using the configured WiFi credentials first.
    // If this fails, keep the existing WiFiManager behavior
    // unchanged as the fallback.
    // --------------------------------------------------------
    Serial.println(
        "[WIFI] Connecting using configured WiFi credentials..."
    );

    WiFi.begin(
        WIFI_SSID,
        WIFI_PASSWORD
    );

    const unsigned long wifiCredentialStart = millis();

    while (
        WiFi.status() != WL_CONNECTED &&
        millis() - wifiCredentialStart < 20000
    ) {
        delay(500);
        Serial.print(".");
    }

    Serial.println();

    if (WiFi.status() == WL_CONNECTED) {
        Serial.println("[WIFI] Connected using configured credentials.");
        Serial.println("[WIFI] SSID: " + WiFi.SSID());
        Serial.println("[WIFI] IP: " + WiFi.localIP().toString());
    } else {
        Serial.println(
            "[WIFI] Configured credentials failed. "
            "Using WiFiManager fallback..."
        );
    }

    wifiManager.setConnectTimeout(20);

    wifiManager.setConfigPortalTimeout(180);

    wifiManager.setBreakAfterConfig(true);

    // --------------------------------------------------------
    // Custom WiFiManager fields
    // --------------------------------------------------------

    char ipBuffer[16] = "";
    char gatewayBuffer[16] = "";
    char subnetBuffer[16] = "255.255.255.0";
    char dnsBuffer[16] = "";

    configuredIp.toCharArray(
        ipBuffer,
        sizeof(ipBuffer)
    );

    configuredGateway.toCharArray(
        gatewayBuffer,
        sizeof(gatewayBuffer)
    );

    configuredSubnet.toCharArray(
        subnetBuffer,
        sizeof(subnetBuffer)
    );

    configuredDns.toCharArray(
        dnsBuffer,
        sizeof(dnsBuffer)
    );

    WiFiManagerParameter apiIpParameter(
        "api_ip",
        "API / Static IP (blank = DHCP)",
        ipBuffer,
        15
    );

    WiFiManagerParameter gatewayParameter(
        "gateway",
        "Gateway",
        gatewayBuffer,
        15
    );

    WiFiManagerParameter subnetParameter(
        "subnet",
        "Subnet",
        subnetBuffer,
        15
    );

    WiFiManagerParameter dnsParameter(
        "dns",
        "DNS (optional)",
        dnsBuffer,
        15
    );

    wifiManager.addParameter(
        &apiIpParameter
    );

    wifiManager.addParameter(
        &gatewayParameter
    );

    wifiManager.addParameter(
        &subnetParameter
    );

    wifiManager.addParameter(
        &dnsParameter
    );

    // --------------------------------------------------------
    // Apply previously saved static IP BEFORE autoConnect()
    // --------------------------------------------------------

    applySavedStaticIp(
        wifiManager
    );

    // Skip WiFiManager autoConnect when the configured credentials
    // already connected successfully. This preserves all existing
    // WiFiManager configuration and fallback behavior.
    if (WiFi.status() == WL_CONNECTED) {
        return;
    }

    Serial.println(
        "[WIFI] Connecting using WiFiManager..."
    );

    String apName =
        "PisoCoin-Setup-" +
        controllerHostname.substring(
            controllerHostname.length() - 6
        );

    bool connected =
        wifiManager.autoConnect(
            apName.c_str()
        );

    if (!connected) {

        Serial.println(
            "[WIFI] WiFiManager connection failed."
        );

        return;
    }

    // --------------------------------------------------------
    // Read values from WiFiManager
    // --------------------------------------------------------

    String newIp =
        String(
            apiIpParameter.getValue()
        );

    String newGateway =
        String(
            gatewayParameter.getValue()
        );

    String newSubnet =
        String(
            subnetParameter.getValue()
        );

    String newDns =
        String(
            dnsParameter.getValue()
        );

    newIp.trim();
    newGateway.trim();
    newSubnet.trim();
    newDns.trim();

    // --------------------------------------------------------
    // Defaults
    // --------------------------------------------------------

    if (newSubnet.length() == 0) {
        newSubnet =
            "255.255.255.0";
    }

    // --------------------------------------------------------
    // Validate submitted network settings
    // --------------------------------------------------------

    if (!validateStaticIpSettings(
            newIp,
            newGateway,
            newSubnet,
            newDns
        )) {

        Serial.println(
            "[NET] Invalid static IP configuration."
        );

        Serial.println(
            "[NET] Keeping previous configuration."
        );

        newIp = configuredIp;
        newGateway = configuredGateway;
        newSubnet = configuredSubnet;
        newDns = configuredDns;
    }

    // --------------------------------------------------------
    // Detect whether the network configuration changed
    // --------------------------------------------------------

    const bool networkConfigChanged =
        newIp != configuredIp ||
        newGateway != configuredGateway ||
        newSubnet != configuredSubnet ||
        newDns != configuredDns;

    // --------------------------------------------------------
    // Save configuration
    // --------------------------------------------------------

    prefs.putString(
        "static_ip",
        newIp
    );

    prefs.putString(
        "gateway",
        newGateway
    );

    prefs.putString(
        "subnet",
        newSubnet
    );

    prefs.putString(
        "dns",
        newDns
    );

    configuredIp =
        newIp;

    configuredGateway =
        newGateway;

    configuredSubnet =
        newSubnet;

    configuredDns =
        newDns;

    staticIpEnabled =
        configuredIp.length() > 0 &&
        configuredGateway.length() > 0;

    // --------------------------------------------------------
    // If the user changed the network settings in the portal,
    // reboot so the new static IP is applied before WiFi connects.
    // --------------------------------------------------------

    if (networkConfigChanged) {

        Serial.println(
            "[NET] Network configuration changed."
        );

        if (staticIpEnabled) {

            Serial.println(
                "[NET] New static IP: " +
                configuredIp
            );

            Serial.println(
                "[NET] New gateway: " +
                configuredGateway
            );

        } else {

            Serial.println(
                "[NET] Static IP disabled. DHCP will be used."
            );
        }

        Serial.println(
            "[NET] Restarting to apply network configuration..."
        );

        delay(500);

        ESP.restart();

        return;
    }

    // --------------------------------------------------------
    // Connected
    // --------------------------------------------------------

    if (wifiConnected()) {

        Serial.println(
            "[WIFI] Connected."
        );

        Serial.println(
            "[WIFI] SSID: " +
            WiFi.SSID()
        );

        Serial.println(
            "[WIFI] IP: " +
            WiFi.localIP().toString()
        );

        Serial.println(
            "[WIFI] Gateway: " +
            WiFi.gatewayIP().toString()
        );

        Serial.println(
            "[WIFI] Subnet: " +
            WiFi.subnetMask().toString()
        );

        Serial.println(
            "[WIFI] RSSI: " +
            String(WiFi.RSSI())
        );

        if (staticIpEnabled) {
            Serial.println(
                "[NET] API mode: STATIC IP"
            );

            Serial.println(
                "[NET] API URL: http://" +
                WiFi.localIP().toString() +
                "/api/status"
            );
        } else {
            Serial.println(
                "[NET] API mode: DHCP"
            );
        }
    }
}

// ============================================================
// NETWORK MAINTENANCE
// ============================================================

void maintainWiFi() {

    const unsigned long now =
        millis();

    if (
        !wifiConnected() &&
        now -
            lastWifiReconnectAt >=
            WIFI_RECONNECT_INTERVAL_MS
    ) {

        lastWifiReconnectAt =
            now;

        Serial.println(
            "[WIFI] Disconnected. "
            "Attempting reconnect..."
        );

        WiFi.reconnect();
    }

    if (
        wifiConnected() &&
        !mdnsStarted
    ) {

        startMDNS();
    }

    if (
        !wifiConnected() &&
        mdnsStarted
    ) {

        stopMDNS();
    }

    if (
        now -
            lastNetworkStatusAt >=
            NETWORK_STATUS_INTERVAL_MS
    ) {

        lastNetworkStatusAt =
            now;

        static bool previousConnected =
            false;

        const bool connected =
            wifiConnected();

        if (
            connected !=
            previousConnected
        ) {

            if (connected) {

                Serial.println(
                    "[NET] Wi-Fi CONNECTED"
                );

                Serial.println(
                    "[NET] IP: " +
                    WiFi.localIP().toString()
                );
            }

            else {

                Serial.println(
                    "[NET] Wi-Fi DISCONNECTED"
                );
            }

            previousConnected =
                connected;
        }
    }
}

// ============================================================
// COIN INTERRUPT
// ============================================================

void IRAM_ATTR countPulse() {

    if (!acceptorOpen) {
        return;
    }

    portENTER_CRITICAL_ISR(
        &coinPulseMux
    );

    pulses++;

    lastPulseTime =
        xTaskGetTickCountFromISR() *
        portTICK_PERIOD_MS;

    portEXIT_CRITICAL_ISR(
        &coinPulseMux
    );
}

// ============================================================
// PROCESS COIN PULSES
// ============================================================

void processCoinPulses() {

    int pulseSnapshot = 0;

    unsigned long lastPulseSnapshot = 0;

    portENTER_CRITICAL(
        &coinPulseMux
    );

    pulseSnapshot =
        pulses;

    lastPulseSnapshot =
        lastPulseTime;

    portEXIT_CRITICAL(
        &coinPulseMux
    );

    if (
        pulseSnapshot > 0 &&
        millis() -
            lastPulseSnapshot >
            200
    ) {

        int amount = 0;

        portENTER_CRITICAL(
            &coinPulseMux
        );

        amount =
            pulses;

        pulses = 0;

        lastPulseTime = 0;

        portEXIT_CRITICAL(
            &coinPulseMux
        );

        queueCoinCredit(
            amount
        );

        Serial.printf(
            "[COIN] Inserted amount=%d\n",
            amount
        );
    }
}

// ============================================================
// PROCESS SESSION
// ============================================================

void processSession() {

    if (
        activeLauncherDeviceId.length() > 0 &&
        millis() -
            lastOwnerHeartbeatAt >=
            SESSION_LEASE_TIMEOUT_MS
    ) {

        closeCurrentSession(
            "Session expired due to heartbeat timeout."
        );
    }

    if (
        acceptorOpenPending &&
        millis() -
            acceptorOpenRequestedAt >=
            ACCEPTOR_OPEN_DELAY_MS
    ) {

        acceptorOpenPending =
            false;

        setAcceptorOutput(
            true
        );
    }
}

// ============================================================
// SETUP
// ============================================================

void setup() {

    Serial.begin(115200);

    delay(100);

    Serial.println();
    Serial.println(
        "================================"
    );
    Serial.println(
        " PisoCoin ESP32 Wi-Fi Controller"
    );
    Serial.println(
        "================================"
    );

    // --------------------------------------------------------
    // Preferences
    // --------------------------------------------------------

    prefs.begin(
        "coinctrl_http",
        false
    );

    // --------------------------------------------------------
    // Controller identity
    // --------------------------------------------------------

    controllerId =
        buildControllerId();

    controllerHostname =
        buildControllerHostname();

    Serial.println(
        "[NET] Controller ID: " +
        controllerId
    );

    Serial.println(
        "[NET] Hostname: " +
        controllerHostname
    );

    // --------------------------------------------------------
    // Coin GPIO
    // --------------------------------------------------------

    pinMode(
        COIN_PIN,
        INPUT_PULLUP
    );

    pinMode(
        ACCEPTOR_ENABLE_PIN,
        OUTPUT
    );

    setAcceptorOutput(false);

    attachInterrupt(
        digitalPinToInterrupt(
            COIN_PIN
        ),
        countPulse,
        FALLING
    );

    // --------------------------------------------------------
    // WiFi reset button
    // --------------------------------------------------------

    pinMode(
        WIFI_RESET_PIN,
        INPUT_PULLUP
    );

    Serial.println(
        "[WIFI] Reset button: GPIO 32"
    );

    Serial.println(
        "[WIFI] Hold for 3 seconds to "
        "clear WiFiManager credentials."
    );

    // --------------------------------------------------------
    // Wi-Fi
    // --------------------------------------------------------

    setupWiFi();

    // --------------------------------------------------------
    // HTTP
    // --------------------------------------------------------

    if (wifiConnected()) {

        startHttpServer();

        startMDNS();
    }

    Serial.println(
        "[SYSTEM] Setup complete."
    );

    if (wifiConnected()) {

        Serial.println(
            "[SYSTEM] REST API:"
        );

        Serial.println(
            "http://" +
            WiFi.localIP().toString() +
            "/api/status"
        );

        Serial.println(
            "[SYSTEM] API mode: " +
            String(
                staticIpEnabled
                    ? "STATIC IP"
                    : "DHCP"
            )
        );

        if (staticIpEnabled) {
            Serial.println(
                "[SYSTEM] Configured API IP: " +
                configuredIp
            );
        }

        if (mdnsStarted) {

            Serial.println(
                "http://" +
                mdnsHostname() +
                "/api/status"
            );
        }
    }
}

// ============================================================
// LOOP
// ============================================================

void loop() {

    // --------------------------------------------------------
    // IMPORTANT:
    // Keep the reset button checked continuously.
    // --------------------------------------------------------

    handleWifiResetButton();

    // --------------------------------------------------------
    // Network
    // --------------------------------------------------------

    maintainWiFi();

    // Start HTTP server whenever Wi-Fi comes back.
    if (
        wifiConnected() &&
        !wifiServerStarted
    ) {

        startHttpServer();
    }

    // --------------------------------------------------------
    // HTTP
    // --------------------------------------------------------

    if (wifiConnected()) {

        handleHttpServer();
    }

    // --------------------------------------------------------
    // Coin events
    // --------------------------------------------------------

    expireStaleCoinEvents();

    processCoinPulses();

    // --------------------------------------------------------
    // Session
    // --------------------------------------------------------

    processSession();

    // --------------------------------------------------------
    // Give ESP32 background tasks time.
    // --------------------------------------------------------

    delay(1);
}