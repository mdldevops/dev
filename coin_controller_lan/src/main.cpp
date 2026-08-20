#include <Arduino.h>
#include <ArduinoJson.h>
#include <Ethernet.h>
#include <Preferences.h>
#include <SPI.h>

// ============================================================
// CONFIGURATION
// ============================================================

const uint16_t HTTP_PORT = 80;

// Coin acceptor
const int COIN_PIN = 14;
const int ACCEPTOR_ENABLE_PIN = 26;
const bool ACCEPTOR_ENABLED_LEVEL = HIGH;

// W5500 Ethernet
// Default ESP32 VSPI wiring:
// SCK=18, MISO=19, MOSI=23, CS=5
const int W5500_CS_PIN = 5;
const int W5500_SCK_PIN = 18;
const int W5500_MISO_PIN = 19;
const int W5500_MOSI_PIN = 23;
const int W5500_RESET_PIN = -1;

// Network reset button
// Button: GPIO 32 ---- BUTTON ---- GND
const int NETWORK_RESET_PIN = 32;
const unsigned long NETWORK_RESET_HOLD_MS = 3000;
const unsigned long NETWORK_RESET_DEBOUNCE_MS = 50;

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

// Ethernet
const unsigned long ETHERNET_RECONNECT_INTERVAL_MS = 15000;
const unsigned long NETWORK_STATUS_INTERVAL_MS = 5000;

// ============================================================
// PREFERENCES
// ============================================================

const char* PREF_NAMESPACE = "coinctrl_lan";

Preferences prefs;

// ============================================================
// ETHERNET / HTTP
// ============================================================

byte ethernetMac[6];
EthernetServer ethernetServer(HTTP_PORT);

bool ethernetServerStarted = false;

unsigned long lastEthernetReconnectAt = 0;
unsigned long lastNetworkStatusAt = 0;

// ============================================================
// CONTROLLER ID
// ============================================================

String controllerId;
String controllerHostname;

// ============================================================
// STATIC IP / API NETWORK CONFIGURATION
// ============================================================

String configuredIp = "";
String configuredGateway = "";
String configuredSubnet = "255.255.255.0";
String configuredDns = "";

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
// NETWORK RESET BUTTON
// ============================================================

bool networkResetButtonPressed = false;
unsigned long networkResetButtonStartedAt = 0;
unsigned long networkResetLastChangeAt = 0;
bool networkResetAlreadyTriggered = false;

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
// ETHERNET STATUS
// ============================================================

void buildEthernetMac() {
    uint64_t chipId = ESP.getEfuseMac();

    ethernetMac[0] = 0x02;
    ethernetMac[1] = 0x50;
    ethernetMac[2] = 0x53;
    ethernetMac[3] = static_cast<byte>((chipId >> 16) & 0xFF);
    ethernetMac[4] = static_cast<byte>((chipId >> 8) & 0xFF);
    ethernetMac[5] = static_cast<byte>(chipId & 0xFF);
}

String ethernetMacString() {
    char buffer[18];
    snprintf(
        buffer,
        sizeof(buffer),
        "%02X:%02X:%02X:%02X:%02X:%02X",
        ethernetMac[0],
        ethernetMac[1],
        ethernetMac[2],
        ethernetMac[3],
        ethernetMac[4],
        ethernetMac[5]
    );
    return String(buffer);
}

bool ethernetConnected() {
    return Ethernet.hardwareStatus() != EthernetNoHardware &&
           Ethernet.linkStatus() == LinkON &&
           Ethernet.localIP() != IPAddress(0, 0, 0, 0);
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

bool beginEthernetWithSavedConfig() {
    Ethernet.init(W5500_CS_PIN);

    if (!staticIpEnabled) {
        Serial.println(
            "[NET] Static IP disabled. Starting DHCP."
        );
        return Ethernet.begin(ethernetMac) == 1;
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
        return Ethernet.begin(ethernetMac) == 1;
    }

    if (configuredDns.length() == 0 ||
        !parseIPAddress(configuredDns, dns)) {
        dns = gateway;
    }

    Ethernet.begin(
        ethernetMac,
        ip,
        dns,
        gateway,
        subnet
    );

    Serial.println(
        "[NET] Ethernet static IP configured."
    );

    Serial.println(
        "[NET] IP: " + Ethernet.localIP().toString()
    );

    Serial.println(
        "[NET] Gateway: " + Ethernet.gatewayIP().toString()
    );

    Serial.println(
        "[NET] Subnet: " + Ethernet.subnetMask().toString()
    );

    Serial.println(
        "[NET] DNS: " + Ethernet.dnsServerIP().toString()
    );

    return true;
}

void printEthernetAddress() {
    Serial.println(
        "[NET] MAC: " + ethernetMacString()
    );

    Serial.println(
        "[NET] IP: " + Ethernet.localIP().toString()
    );

    Serial.println(
        "[NET] Gateway: " + Ethernet.gatewayIP().toString()
    );

    Serial.println(
        "[NET] Subnet: " + Ethernet.subnetMask().toString()
    );

    Serial.println(
        "[NET] DNS: " + Ethernet.dnsServerIP().toString()
    );
}

void resetW5500IfConfigured() {
    if (W5500_RESET_PIN < 0) {
        return;
    }

    pinMode(W5500_RESET_PIN, OUTPUT);
    digitalWrite(W5500_RESET_PIN, LOW);
    delay(100);
    digitalWrite(W5500_RESET_PIN, HIGH);
    delay(250);
}

void setupEthernetHardware() {
    if (W5500_RESET_PIN >= 0) {
        pinMode(W5500_RESET_PIN, OUTPUT);
        digitalWrite(W5500_RESET_PIN, HIGH);
    }

    SPI.begin(
        W5500_SCK_PIN,
        W5500_MISO_PIN,
        W5500_MOSI_PIN,
        W5500_CS_PIN
    );

    resetW5500IfConfigured();
}

void setupEthernet() {
    loadStaticIpSettings();
    buildEthernetMac();
    setupEthernetHardware();

    Serial.println(
        "[ETH] Starting W5500 Ethernet."
    );

    Serial.println(
        "[ETH] CS=" + String(W5500_CS_PIN) +
        " SCK=" + String(W5500_SCK_PIN) +
        " MISO=" + String(W5500_MISO_PIN) +
        " MOSI=" + String(W5500_MOSI_PIN)
    );

    const bool started =
        beginEthernetWithSavedConfig();

    if (Ethernet.hardwareStatus() == EthernetNoHardware) {
        Serial.println(
            "[ETH] W5500 hardware was not found."
        );
        return;
    }

    if (Ethernet.linkStatus() == LinkOFF) {
        Serial.println(
            "[ETH] Ethernet cable is not connected."
        );
    }

    if (!started && !staticIpEnabled) {
        Serial.println(
            "[ETH] DHCP failed. Waiting for link/retry."
        );
        return;
    }

    if (ethernetConnected() || staticIpEnabled) {
        Serial.println(
            "[ETH] Ethernet ready."
        );
        printEthernetAddress();
    }
}

void maintainEthernet() {
    const unsigned long now = millis();

    Ethernet.maintain();

    if (
        !staticIpEnabled &&
        !ethernetConnected() &&
        now - lastEthernetReconnectAt >= ETHERNET_RECONNECT_INTERVAL_MS
    ) {
        lastEthernetReconnectAt = now;

        Serial.println(
            "[ETH] Not connected. Retrying DHCP..."
        );

        Ethernet.begin(ethernetMac);
    }

    if (
        now - lastNetworkStatusAt >=
        NETWORK_STATUS_INTERVAL_MS
    ) {
        lastNetworkStatusAt = now;

        static bool previousConnected = false;
        const bool connected = ethernetConnected();

        if (connected != previousConnected) {
            if (connected) {
                Serial.println("[NET] Ethernet CONNECTED");
                printEthernetAddress();
            } else {
                Serial.println("[NET] Ethernet DISCONNECTED");
            }

            previousConnected = connected;
        }
    }
}

String mdnsHostname() {
    return "";
}

void startMDNS() {
}

void stopMDNS() {
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
    EthernetClient& client,
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
        ethernetConnected();

    network["ip"] =
        Ethernet.localIP().toString();

    network["type"] =
        "ethernet";

    network["mac"] =
        ethernetMacString();

    network["mdns"] =
        "";

    network["httpPort"] =
        HTTP_PORT;

    network["staticIpEnabled"] =
        staticIpEnabled;

    network["configuredIp"] =
        staticIpEnabled
            ? configuredIp
            : "";

    network["gateway"] =
        Ethernet.gatewayIP().toString();

    network["subnet"] =
        Ethernet.subnetMask().toString();

    network["dns"] =
        Ethernet.dnsServerIP().toString();

    network["link"] =
        Ethernet.linkStatus() == LinkON
            ? "up"
            : "down";

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
    EthernetClient& client
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
    EthernetClient& client,
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
    EthernetClient& client,
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
    EthernetClient& client,
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
    EthernetClient& client,
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
    EthernetClient& client,
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
    EthernetClient& client,
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
    EthernetClient& client,
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
    EthernetClient& client
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

    if (ethernetServerStarted) {
        return;
    }

    ethernetServer.begin();

    ethernetServerStarted = true;

    Serial.println(
        "[HTTP] LAN REST server listening on port 80."
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

        EthernetClient client =
            ethernetServer.available();

        if (!client) {
            break;
        }

        handleHttpClient(client);
    }
}

// ============================================================
// NETWORK RESET
// ============================================================

void resetNetworkConfiguration() {

    Serial.println(
        "[NET] Reset button held. Clearing saved LAN configuration..."
    );

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
        "[NET] LAN configuration cleared. Restarting..."
    );

    delay(100);

    ESP.restart();
}

// ============================================================
// NETWORK RESET BUTTON
// ============================================================

void handleNetworkResetButton() {

    const bool pressed =
        digitalRead(
            NETWORK_RESET_PIN
        ) == LOW;

    const unsigned long now =
        millis();

    if (pressed) {

        if (!networkResetButtonPressed) {

            if (
                now - networkResetLastChangeAt <
                NETWORK_RESET_DEBOUNCE_MS
            ) {
                return;
            }

            networkResetButtonPressed = true;
            networkResetButtonStartedAt = now;
            networkResetAlreadyTriggered = false;
            networkResetLastChangeAt = now;

            Serial.println(
                "[NET] Reset button pressed. Hold for 3 seconds..."
            );

            return;
        }

        if (
            !networkResetAlreadyTriggered &&
            now - networkResetButtonStartedAt >=
                NETWORK_RESET_HOLD_MS
        ) {

            networkResetAlreadyTriggered = true;
            resetNetworkConfiguration();
            return;
        }
    } else {

        if (networkResetButtonPressed) {

            networkResetButtonPressed = false;
            networkResetLastChangeAt = now;
            networkResetAlreadyTriggered = false;

            Serial.println(
                "[NET] Reset button released."
            );
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
        " PisoCoin ESP32 LAN Controller"
    );
    Serial.println(
        "================================"
    );

    // --------------------------------------------------------
    // Preferences
    // --------------------------------------------------------

    prefs.begin(
        PREF_NAMESPACE,
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
    // Network reset button
    // --------------------------------------------------------

    pinMode(
        NETWORK_RESET_PIN,
        INPUT_PULLUP
    );

    Serial.println(
        "[NET] Reset button: GPIO 32"
    );

    Serial.println(
        "[NET] Hold for 3 seconds to clear saved LAN configuration."
    );

    // --------------------------------------------------------
    // Ethernet
    // --------------------------------------------------------

    setupEthernet();

    // --------------------------------------------------------
    // HTTP
    // --------------------------------------------------------

    if (ethernetConnected()) {

        startHttpServer();
    }

    Serial.println(
        "[SYSTEM] Setup complete."
    );

    if (ethernetConnected()) {

        Serial.println(
            "[SYSTEM] REST API:"
        );

        Serial.println(
            "http://" +
            Ethernet.localIP().toString() +
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

        Serial.println(
            "[SYSTEM] MAC: " +
            ethernetMacString()
        );
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

    handleNetworkResetButton();

    // --------------------------------------------------------
    // Network
    // --------------------------------------------------------

    maintainEthernet();

    // Start HTTP server whenever Ethernet comes back.
    if (
        ethernetConnected() &&
        !ethernetServerStarted
    ) {

        startHttpServer();
    }

    // --------------------------------------------------------
    // HTTP
    // --------------------------------------------------------

    if (ethernetConnected()) {

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


