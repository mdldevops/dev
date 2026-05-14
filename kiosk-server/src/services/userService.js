const crypto = require('crypto');

const db = require('../config/database');
const { getIO } = require('../utils/socketManager');

let activeSession = null;
const clients = {};
const esp32Clients = {};
const rawEsp32Sockets = new Set();
const chargerClients = {};
const rawChargerSockets = new Set();
const launcherDeviceNames = {};
let coinInterval = null;
const runtimeDeviceStates = {};
let coinSettingsCache = {
  p1: 6,
  p5: 30,
  p10: 60,
  p20: 120,
};
let chargingSettingsCache = {
  startBelowPercent: 30,
  stopAtPercent: 80,
};
const chargingRelayStates = {};
const chargingCommandPendingStates = {};
const launcherRelayPins = {};
const SIMULATION_ENABLED = String(
  process.env.ENABLE_COIN_SIMULATION || '',
).toLowerCase() === 'true';
const ACTIVE_ACCOUNT_STATUS = 'active';
const DEACTIVATED_ACCOUNT_STATUS = 'deactivated';
const BANNED_ACCOUNT_STATUS = 'banned';
const ALLOWED_ACCOUNT_STATUSES = new Set([
  ACTIVE_ACCOUNT_STATUS,
  DEACTIVATED_ACCOUNT_STATUS,
  BANNED_ACCOUNT_STATUS,
]);

function titleCaseWord(value) {
  if (!value) {
    return '';
  }

  return value.charAt(0).toUpperCase() + value.slice(1);
}

function deriveDeviceName(deviceId) {
  const rawValue = String(deviceId || '').trim();
  if (!rawValue) {
    return 'Unknown Device';
  }

  const namePart = rawValue.includes('__')
    ? rawValue.split('__')[0]
    : rawValue.startsWith('device_')
      ? ''
      : rawValue;

  if (!namePart) {
    return rawValue;
  }

  return namePart
    .split('_')
    .filter(Boolean)
    .map(titleCaseWord)
    .join(' ');
}

function normalizeDeviceName(deviceName) {
  return String(deviceName || '')
    .trim()
    .toLowerCase();
}

function hashPassword(password) {
  return crypto.createHash('sha256').update(password).digest('hex');
}

function normalizeUsername(username) {
  return String(username || '').trim().toLowerCase();
}

function normalizeAccountStatus(status) {
  return String(status || '').trim().toLowerCase();
}

function validateCredentials(username, password) {
  const normalizedUsername = normalizeUsername(username);
  const normalizedPassword = String(password || '').trim();

  if (!normalizedUsername || !normalizedPassword) {
    return null;
  }

  return {
    username: normalizedUsername,
    password: normalizedPassword,
  };
}

function runQuery(sql, params = []) {
  return new Promise((resolve, reject) => {
    db.run(sql, params, function onRun(error) {
      if (error) {
        reject(error);
        return;
      }

      resolve(this);
    });
  });
}

function getQuery(sql, params = []) {
  return new Promise((resolve, reject) => {
    db.get(sql, params, (error, row) => {
      if (error) {
        reject(error);
        return;
      }

      resolve(row);
    });
  });
}

function allQuery(sql, params = []) {
  return new Promise((resolve, reject) => {
    db.all(sql, params, (error, rows) => {
      if (error) {
        reject(error);
        return;
      }

      resolve(rows);
    });
  });
}

async function getCoinSettings() {
  const row = await getQuery(
    `
      SELECT
        p1_minutes AS p1,
        p5_minutes AS p5,
        p10_minutes AS p10,
        p20_minutes AS p20
      FROM coin_settings
      WHERE id = 1
    `,
  );

  const settings = {
    p1: Math.max(0, Number(row?.p1) || 6),
    p5: Math.max(0, Number(row?.p5) || 30),
    p10: Math.max(0, Number(row?.p10) || 60),
    p20: Math.max(0, Number(row?.p20) || 120),
  };

  coinSettingsCache = settings;
  return {
    success: true,
    ratios: settings,
  };
}

async function updateCoinSettings(ratios = {}) {
  const nextSettings = {
    p1: Math.max(0, Number(ratios.p1) || 0),
    p5: Math.max(0, Number(ratios.p5) || 0),
    p10: Math.max(0, Number(ratios.p10) || 0),
    p20: Math.max(0, Number(ratios.p20) || 0),
  };

  await runQuery(
    `
      UPDATE coin_settings
      SET
        p1_minutes = ?,
        p5_minutes = ?,
        p10_minutes = ?,
        p20_minutes = ?,
        updated_at = CURRENT_TIMESTAMP
      WHERE id = 1
    `,
    [nextSettings.p1, nextSettings.p5, nextSettings.p10, nextSettings.p20],
  );

  coinSettingsCache = nextSettings;

  return {
    success: true,
    ratios: nextSettings,
  };
}

async function getChargingSettings() {
  const row = await getQuery(
    `
      SELECT
        start_below_percent AS startBelowPercent,
        stop_at_percent AS stopAtPercent
      FROM charging_settings
      WHERE id = 1
    `,
  );

  const settings = {
    startBelowPercent: Math.max(0, Math.min(100, Number(row?.startBelowPercent) || 30)),
    stopAtPercent: Math.max(0, Math.min(100, Number(row?.stopAtPercent) || 80)),
  };

  chargingSettingsCache = settings;
  return {
    success: true,
    settings,
  };
}

async function updateChargingSettings(settings = {}) {
  const nextSettings = {
    startBelowPercent: Math.max(
      0,
      Math.min(100, Number(settings.startBelowPercent) || 30),
    ),
    stopAtPercent: Math.max(
      0,
      Math.min(100, Number(settings.stopAtPercent) || 80),
    ),
  };

  if (nextSettings.startBelowPercent >= nextSettings.stopAtPercent) {
    const error = new Error('Start threshold must be below stop threshold.');
    error.statusCode = 400;
    throw error;
  }

  const settingsChanged =
    nextSettings.startBelowPercent !== chargingSettingsCache.startBelowPercent ||
    nextSettings.stopAtPercent !== chargingSettingsCache.stopAtPercent;

  await runQuery(
    `
      UPDATE charging_settings
      SET
        start_below_percent = ?,
        stop_at_percent = ?,
        updated_at = CURRENT_TIMESTAMP
      WHERE id = 1
    `,
    [nextSettings.startBelowPercent, nextSettings.stopAtPercent],
  );

  chargingSettingsCache = nextSettings;
  if (settingsChanged) {
    Object.keys(runtimeDeviceStates).forEach((deviceId) => {
      evaluateChargingForDevice(deviceId, { forceReevaluate: true });
    });
  }

  return {
    success: true,
    settings: nextSettings,
  };
}

function getConfiguredMinutesForCoin(coinValue) {
  switch (Number(coinValue) || 0) {
    case 1:
      return coinSettingsCache.p1;
    case 5:
      return coinSettingsCache.p5;
    case 10:
      return coinSettingsCache.p10;
    case 20:
      return coinSettingsCache.p20;
    default:
      return 0;
  }
}

function sendToDevice(deviceId, data) {
  const socket = clients[deviceId];
  const eventName = String(data?.event || 'unknown');
  if (socket) {
    console.log('SEND TO DEVICE (direct):', {
      deviceId,
      event: eventName,
      socketId: socket.id,
      connected: socket.connected === true,
    });
    socket.emit('event', data);
    return;
  }

  const io = getIO();
  if (io) {
    console.log('SEND TO DEVICE (room):', {
      deviceId,
      event: eventName,
      hasDirectSocket: false,
    });
    io.to(deviceId).emit('event', data);
    return;
  }

  console.warn('SEND TO DEVICE FAILED:', {
    deviceId,
    event: eventName,
    reason: 'socket_server_not_ready',
  });
}

function normalizeLauncherLookupKey(launcherDeviceId, launcherDeviceName) {
  const normalizedLauncherDeviceId = String(launcherDeviceId || '').trim();
  if (normalizedLauncherDeviceId) {
    return `id:${normalizedLauncherDeviceId}`;
  }

  const normalizedLauncherDeviceName = normalizeDeviceName(launcherDeviceName);
  if (normalizedLauncherDeviceName) {
    return `name:${normalizedLauncherDeviceName}`;
  }

  return '';
}

function findEsp32SocketForLauncher({
  launcherDeviceId,
  launcherDeviceName,
}) {
  const byIdKey = normalizeLauncherLookupKey(launcherDeviceId, null);
  if (byIdKey && esp32Clients[byIdKey]?.socket) {
    return esp32Clients[byIdKey].socket;
  }

  const byNameKey = normalizeLauncherLookupKey(null, launcherDeviceName);
  if (byNameKey && esp32Clients[byNameKey]?.socket) {
    return esp32Clients[byNameKey].socket;
  }

  const normalizedLauncherDeviceId = String(launcherDeviceId || '').trim().toLowerCase();
  const normalizedLauncherDeviceName = normalizeDeviceName(launcherDeviceName);

  for (const client of Object.values(esp32Clients)) {
    const clientLauncherDeviceId = String(client.launcherDeviceId || '').trim().toLowerCase();
    const clientLauncherDeviceName = normalizeDeviceName(client.launcherDeviceName);

    if (
      (normalizedLauncherDeviceId && clientLauncherDeviceId === normalizedLauncherDeviceId) ||
      (normalizedLauncherDeviceName && clientLauncherDeviceName === normalizedLauncherDeviceName)
    ) {
      return client.socket;
    }
  }

  return null;
}

function getUniqueReadyEsp32Sockets() {
  const uniqueSockets = [];
  const seenSockets = new Set();

  for (const socket of rawEsp32Sockets) {
    if (!socket || socket.readyState !== 1 || seenSockets.has(socket)) {
      continue;
    }

    seenSockets.add(socket);
    uniqueSockets.push(socket);
  }

  for (const client of Object.values(esp32Clients)) {
    const socket = client?.socket;
    if (!socket || socket.readyState !== 1 || seenSockets.has(socket)) {
      continue;
    }

    seenSockets.add(socket);
    uniqueSockets.push(socket);
  }

  return uniqueSockets;
}

function trackEsp32Socket(socket) {
  if (!socket) {
    return;
  }

  rawEsp32Sockets.add(socket);
}

function getUniqueReadyChargerSockets() {
  const uniqueSockets = [];
  const seenSockets = new Set();

  for (const socket of rawChargerSockets) {
    if (!socket || socket.readyState !== 1 || seenSockets.has(socket)) {
      continue;
    }

    seenSockets.add(socket);
    uniqueSockets.push(socket);
  }

  for (const client of Object.values(chargerClients)) {
    const socket = client?.socket;
    if (!socket || socket.readyState !== 1 || seenSockets.has(socket)) {
      continue;
    }

    seenSockets.add(socket);
    uniqueSockets.push(socket);
  }

  return uniqueSockets;
}

function trackChargerSocket(socket) {
  if (!socket) {
    return;
  }

  rawChargerSockets.add(socket);
}

function findChargerSocketForLauncher({
  launcherDeviceId,
  launcherDeviceName,
}) {
  const byIdKey = normalizeLauncherLookupKey(launcherDeviceId, null);
  if (byIdKey && chargerClients[byIdKey]?.socket) {
    return chargerClients[byIdKey].socket;
  }

  const byNameKey = normalizeLauncherLookupKey(null, launcherDeviceName);
  if (byNameKey && chargerClients[byNameKey]?.socket) {
    return chargerClients[byNameKey].socket;
  }

  const normalizedLauncherDeviceId = String(launcherDeviceId || '').trim().toLowerCase();
  const normalizedLauncherDeviceName = normalizeDeviceName(launcherDeviceName);

  for (const client of Object.values(chargerClients)) {
    const clientLauncherDeviceId = String(client.launcherDeviceId || '').trim().toLowerCase();
    const clientLauncherDeviceName = normalizeDeviceName(client.launcherDeviceName);

    if (
      (normalizedLauncherDeviceId && clientLauncherDeviceId === normalizedLauncherDeviceId) ||
      (normalizedLauncherDeviceName && clientLauncherDeviceName === normalizedLauncherDeviceName)
    ) {
      return client.socket;
    }
  }

  return null;
}

function sendChargerCommand({
  launcherDeviceId,
  launcherDeviceName,
  enabled,
  reason,
  batteryLevel = null,
  relayPin = null,
}) {
  let socket = findChargerSocketForLauncher({
    launcherDeviceId,
    launcherDeviceName,
  });
  let mode = 'mapped';

  if (!socket || socket.readyState !== 1) {
    const sharedSockets = getUniqueReadyChargerSockets();
    if (sharedSockets.length === 1) {
      [socket] = sharedSockets;
      mode = 'shared-single-charger';
    }
  }

  if (!socket || socket.readyState !== 1) {
    console.warn('CHARGER COMMAND SKIPPED:', {
      launcherDeviceId,
      launcherDeviceName,
      enabled,
      reason,
      batteryLevel,
      relayPin,
      connectedChargerCount: getUniqueReadyChargerSockets().length,
    });
    return false;
  }

  const payload = {
    type: 'charger_command',
    enabled: Boolean(enabled),
    launcher_device_id: launcherDeviceId,
    reason: String(reason || '').trim() || null,
    created_at: new Date().toISOString(),
  };

  if (String(launcherDeviceName || '').trim().length > 0) {
    payload.launcher_device_name = launcherDeviceName;
  }

  if (batteryLevel != null) {
    payload.battery_level = Math.max(0, Math.min(100, Number(batteryLevel) || 0));
  }

  if (relayPin != null) {
    payload.relay_pin = Number(relayPin) || 0;
  }

  socket.send(JSON.stringify(payload));
  console.log('CHARGER COMMAND:', {
    launcherDeviceId,
    launcherDeviceName,
    enabled: Boolean(enabled),
    reason,
    batteryLevel,
    relayPin,
    mode,
  });
  if (launcherDeviceId) {
    chargingCommandPendingStates[launcherDeviceId] = {
      enabled: Boolean(enabled),
      relayPin: relayPin == null ? null : Number(relayPin) || 0,
      requestedAt: Date.now(),
    };
  }
  return true;
}

function evaluateChargingForDevice(deviceId, options = {}) {
  const normalizedDeviceId = String(deviceId || '').trim();
  if (!normalizedDeviceId) {
    return;
  }

  const forceReevaluate = options.forceReevaluate === true;

  const runtimeState = runtimeDeviceStates[normalizedDeviceId];
  if (!runtimeState) {
    return;
  }

  const batteryLevel = Number(runtimeState.batteryLevel);
  if (Number.isNaN(batteryLevel) || batteryLevel < 0) {
    return;
  }

  const previousState = chargingRelayStates[normalizedDeviceId];
  let nextShouldCharge = previousState;

  if (forceReevaluate) {
    nextShouldCharge = batteryLevel <= chargingSettingsCache.startBelowPercent;
  } else if (batteryLevel <= chargingSettingsCache.startBelowPercent) {
    nextShouldCharge = true;
  } else if (batteryLevel >= chargingSettingsCache.stopAtPercent) {
    nextShouldCharge = false;
  } else if (typeof previousState !== 'boolean') {
    nextShouldCharge = false;
  }

  if (previousState === nextShouldCharge) {
    return;
  }

  const pendingState = chargingCommandPendingStates[normalizedDeviceId];
  if (
    !forceReevaluate &&
    pendingState &&
    pendingState.enabled === nextShouldCharge &&
    Date.now() - Number(pendingState.requestedAt || 0) <= 15000
  ) {
    return;
  }

  chargingRelayStates[normalizedDeviceId] = nextShouldCharge;
  const launcherDeviceName =
    launcherDeviceNames[normalizedDeviceId] || deriveDeviceName(normalizedDeviceId);
  const relayPin = launcherRelayPins[normalizedDeviceId] ?? null;

  sendChargerCommand({
    launcherDeviceId: normalizedDeviceId,
    launcherDeviceName,
    enabled: nextShouldCharge,
    reason: nextShouldCharge ? 'battery_below_threshold' : 'battery_reached_stop_threshold',
    batteryLevel,
    relayPin,
  });
}

function matchesActiveLauncher(launcherDeviceId, launcherDeviceName) {
  if (!activeSession) {
    return false;
  }

  const normalizedLauncherDeviceId = String(launcherDeviceId || '')
    .trim()
    .toLowerCase();
  const normalizedActiveDeviceId = String(activeSession.deviceId || '')
    .trim()
    .toLowerCase();

  if (normalizedLauncherDeviceId && normalizedLauncherDeviceId === normalizedActiveDeviceId) {
    return true;
  }

  const normalizedLauncherDeviceName = normalizeDeviceName(launcherDeviceName);
  const normalizedActiveDeviceName = normalizeDeviceName(activeSession.deviceName || '');

  return Boolean(
    normalizedLauncherDeviceName &&
      normalizedActiveDeviceName &&
      normalizedLauncherDeviceName === normalizedActiveDeviceName,
  );
}

function sendAcceptorCommand({
  launcherDeviceId,
  launcherDeviceName,
  enabled,
  reason,
  queuePosition = 0,
}) {
  let socket = findEsp32SocketForLauncher({
    launcherDeviceId,
    launcherDeviceName,
  });

  let mode = 'mapped';

  if (!socket || socket.readyState !== 1) {
    const sharedSockets = getUniqueReadyEsp32Sockets();
    if (sharedSockets.length === 1) {
      [socket] = sharedSockets;
      mode = 'shared-single-esp32';
    }
  }

  if (!socket || socket.readyState !== 1) {
    console.warn('ESP32 ACCEPTOR COMMAND SKIPPED:', {
      launcherDeviceId,
      launcherDeviceName,
      enabled,
      reason,
      connectedEsp32Count: getUniqueReadyEsp32Sockets().length,
    });
    return false;
  }

  if (
    mode === 'shared-single-esp32' &&
    !enabled &&
    activeSession &&
    !matchesActiveLauncher(launcherDeviceId, launcherDeviceName)
  ) {
    console.log('ESP32 ACCEPTOR COMMAND IGNORED:', {
      launcherDeviceId,
      launcherDeviceName,
      enabled: Boolean(enabled),
      queuePosition: Math.max(0, Number(queuePosition) || 0),
      reason,
      mode,
      activeLauncherDeviceId: activeSession.deviceId,
      activeLauncherDeviceName: activeSession.deviceName || '',
    });
    return false;
  }

  const payload = {
    type: 'acceptor_command',
    enabled: Boolean(enabled),
    launcher_device_id: launcherDeviceId,
    queue_position: Math.max(0, Number(queuePosition) || 0),
    reason: String(reason || '').trim() || null,
    created_at: new Date().toISOString(),
  };

  if (String(launcherDeviceName || '').trim().length > 0) {
    payload.launcher_device_name = launcherDeviceName;
  }

  socket.send(JSON.stringify(payload));

  console.log('ESP32 ACCEPTOR COMMAND:', {
    launcherDeviceId,
    launcherDeviceName,
    enabled: Boolean(enabled),
    queuePosition: Math.max(0, Number(queuePosition) || 0),
    reason,
    mode,
  });

  return true;
}

function broadcastMessage(message, deviceIds = null) {
  const normalizedMessage = String(message || '').trim();
  if (!normalizedMessage) {
    const error = new Error('message is required');
    error.statusCode = 400;
    throw error;
  }

  const io = getIO();
  if (!io) {
    const error = new Error('socket server is not ready');
    error.statusCode = 503;
    throw error;
  }

  const payload = {
    event: 'broadcast_message',
    message: normalizedMessage,
    createdAt: new Date().toISOString(),
  };

  const normalizedDeviceIds = Array.isArray(deviceIds)
    ? deviceIds
        .map((deviceId) => String(deviceId || '').trim())
        .filter((deviceId) => deviceId.length > 0)
    : [];

  if (normalizedDeviceIds.length > 0) {
    normalizedDeviceIds.forEach((deviceId) => {
      io.to(deviceId).emit('broadcast', payload);
    });
  } else {
    io.emit('broadcast', payload);
  }

  console.log('BROADCAST MESSAGE:', normalizedMessage);

  return {
    success: true,
    message: normalizedMessage,
    target: normalizedDeviceIds.length > 0 ? 'selected' : 'all',
    deviceIds: normalizedDeviceIds,
    recipientCount:
      normalizedDeviceIds.length > 0
        ? normalizedDeviceIds.length
        : Object.keys(clients).length,
  };
}

async function upsertKnownDevice(deviceId, options = {}) {
  const normalizedDeviceId = String(deviceId || '').trim();
  if (!normalizedDeviceId) {
    return;
  }

  const fallbackIpAddress = options.ipAddress || '';
  const deviceName = deriveDeviceName(normalizedDeviceId);

  await runQuery(
    `
      INSERT INTO known_devices (
        device_id,
        device_name,
        is_locked,
        last_seen,
        last_ip_address
      )
      VALUES (?, ?, 0, CURRENT_TIMESTAMP, ?)
      ON CONFLICT(device_id) DO UPDATE SET
        device_name = excluded.device_name,
        last_seen = CURRENT_TIMESTAMP,
        last_ip_address = CASE
          WHEN excluded.last_ip_address = '' THEN known_devices.last_ip_address
          ELSE excluded.last_ip_address
        END
    `,
    [normalizedDeviceId, deviceName, fallbackIpAddress],
  );
}

async function resolveLauncherDeviceId({
  launcherDeviceId,
  launcherDeviceName,
  fallbackDeviceId,
}) {
  const normalizedLauncherDeviceId = String(launcherDeviceId || '').trim();
  if (normalizedLauncherDeviceId) {
    return normalizedLauncherDeviceId;
  }

  const normalizedLauncherDeviceName = normalizeDeviceName(launcherDeviceName);
  if (normalizedLauncherDeviceName) {
    const knownDevices = await allQuery(
      `
        SELECT device_id AS deviceId, device_name AS deviceName
        FROM known_devices
      `,
    );

    const matchedDevice = knownDevices.find((device) => {
      return (
        normalizeDeviceName(device.deviceName) === normalizedLauncherDeviceName
      );
    });

    if (matchedDevice?.deviceId) {
      return String(matchedDevice.deviceId).trim();
    }
  }

  return String(fallbackDeviceId || '').trim();
}

async function resolveLauncherDeviceName({
  launcherDeviceId,
  launcherDeviceName,
}) {
  const normalizedLauncherDeviceName = String(launcherDeviceName || '').trim();
  if (normalizedLauncherDeviceName) {
    return normalizedLauncherDeviceName;
  }

  const normalizedLauncherDeviceId = String(launcherDeviceId || '').trim();
  if (!normalizedLauncherDeviceId) {
    return '';
  }

  const row = await getQuery(
    `
      SELECT device_name AS deviceName
      FROM known_devices
      WHERE device_id = ?
    `,
    [normalizedLauncherDeviceId],
  );

  return String(row?.deviceName || '').trim();
}

function registerEsp32Client(socket, payload = {}) {
  trackEsp32Socket(socket);

  const esp32DeviceId = String(payload.deviceId || payload.device_id || '').trim();
  const launcherDeviceId = String(
    payload.launcherDeviceId || payload.launcher_device_id || '',
  ).trim();
  const launcherDeviceName = String(
    payload.launcherDeviceName || payload.launcher_device_name || '',
  ).trim();

  socket.esp32DeviceId = esp32DeviceId;
  socket.launcherDeviceId = launcherDeviceId;
  socket.launcherDeviceName = launcherDeviceName;

  const keys = [
    normalizeLauncherLookupKey(launcherDeviceId, null),
    normalizeLauncherLookupKey(null, launcherDeviceName),
  ].filter(Boolean);

  keys.forEach((key) => {
    esp32Clients[key] = {
      socket,
      esp32DeviceId,
      launcherDeviceId,
      launcherDeviceName,
      connectedAt: new Date().toISOString(),
    };
  });

  console.log('ESP32 REGISTERED:', {
    esp32DeviceId,
    launcherDeviceId,
    launcherDeviceName,
  });

  if (activeSession) {
    const normalizedActiveDeviceId = String(activeSession.deviceId || '').trim().toLowerCase();
    const normalizedLauncherId = String(launcherDeviceId || '').trim().toLowerCase();
    const normalizedLauncherName = normalizeDeviceName(launcherDeviceName);
    const normalizedActiveName = normalizeDeviceName(activeSession.deviceName || '');

    if (
      (normalizedLauncherId && normalizedLauncherId === normalizedActiveDeviceId) ||
      (normalizedLauncherName && normalizedLauncherName === normalizedActiveName)
    ) {
      sendAcceptorCommand({
        launcherDeviceId,
        launcherDeviceName,
        enabled: true,
        reason: 'esp32_registered',
        queuePosition: 0,
      });
    }
  }
}

function registerChargerClient(socket, payload = {}) {
  trackChargerSocket(socket);

  const chargerDeviceId = String(payload.deviceId || payload.device_id || '').trim();
  const launcherDeviceId = String(
    payload.launcherDeviceId || payload.launcher_device_id || '',
  ).trim();
  const launcherDeviceName = String(
    payload.launcherDeviceName || payload.launcher_device_name || '',
  ).trim();

  socket.chargerDeviceId = chargerDeviceId;
  socket.launcherDeviceId = launcherDeviceId;
  socket.launcherDeviceName = launcherDeviceName;

  const keys = [
    normalizeLauncherLookupKey(launcherDeviceId, null),
    normalizeLauncherLookupKey(null, launcherDeviceName),
  ].filter(Boolean);

  keys.forEach((key) => {
    chargerClients[key] = {
      socket,
      chargerDeviceId,
      launcherDeviceId,
      launcherDeviceName,
      connectedAt: new Date().toISOString(),
    };
  });

  console.log('CHARGER REGISTERED:', {
    chargerDeviceId,
    launcherDeviceId,
    launcherDeviceName,
  });

  const targetLauncherDeviceId = launcherDeviceId;
  if (targetLauncherDeviceId) {
    evaluateChargingForDevice(targetLauncherDeviceId);
  }
}

function processChargerAck(payload = {}) {
  const launcherDeviceId = String(
    payload.launcherDeviceId || payload.launcher_device_id || '',
  ).trim();
  if (!launcherDeviceId) {
    return { acknowledged: false, reason: 'missing_launcher_device_id' };
  }

  const enabled = Boolean(payload.enabled);
  const relayPinValue =
    payload.relayPin == null && payload.relay_pin == null
      ? null
      : Number(payload.relayPin ?? payload.relay_pin) || 0;

  delete chargingCommandPendingStates[launcherDeviceId];

  sendToDevice(launcherDeviceId, {
    event: 'charger_ack',
    deviceId: launcherDeviceId,
    enabled,
    relayPin: relayPinValue,
    chargerDeviceId: String(payload.deviceId || payload.device_id || '').trim(),
  });

  console.log('CHARGER ACK:', {
    launcherDeviceId,
    enabled,
    relayPin: relayPinValue,
  });

  return {
    acknowledged: true,
    launcherDeviceId,
    enabled,
    relayPin: relayPinValue,
  };
}

function disconnectEsp32Client(socket) {
  rawEsp32Sockets.delete(socket);

  Object.keys(esp32Clients).forEach((key) => {
    if (esp32Clients[key]?.socket === socket) {
      delete esp32Clients[key];
    }
  });

  console.log('ESP32 DISCONNECTED:', {
    esp32DeviceId: socket.esp32DeviceId || '',
    launcherDeviceId: socket.launcherDeviceId || '',
    launcherDeviceName: socket.launcherDeviceName || '',
  });
}

function disconnectChargerClient(socket) {
  rawChargerSockets.delete(socket);

  Object.keys(chargerClients).forEach((key) => {
    if (chargerClients[key]?.socket === socket) {
      delete chargerClients[key];
    }
  });

  console.log('CHARGER DISCONNECTED:', {
    chargerDeviceId: socket.chargerDeviceId || '',
    launcherDeviceId: socket.launcherDeviceId || '',
    launcherDeviceName: socket.launcherDeviceName || '',
  });
}

async function isDeviceLocked(deviceId) {
  const normalizedDeviceId = String(deviceId || '').trim();
  if (!normalizedDeviceId) {
    return false;
  }

  const row = await getQuery(
    `
      SELECT is_locked AS isLocked
      FROM known_devices
      WHERE device_id = ?
    `,
    [normalizedDeviceId],
  );

  return Number(row?.isLocked || 0) === 1;
}

async function logCoinInserted({
  deviceId,
  coinValue,
  creditedMinutes,
  source = 'system',
}) {
  try {
    await runQuery(
      `
        INSERT INTO coin_insert_logs (
          device_id,
          coin_value,
          credited_minutes,
          source
        )
        VALUES (?, ?, ?, ?)
      `,
      [deviceId, coinValue, creditedMinutes, source],
    );
  } catch (error) {
    console.error('COIN LOG ERROR', error);
  }
}

function stopCoinSimulation() {
  if (coinInterval) {
    clearInterval(coinInterval);
    coinInterval = null;
    console.log('Coin simulation stopped');
  }
}

function startCoinSimulation() {
  if (!SIMULATION_ENABLED) {
    return;
  }

  if (coinInterval) {
    return;
  }

  coinInterval = setInterval(async () => {
    if (!activeSession) {
      return;
    }

    const coin = 5;
    const creditedMinutes = getConfiguredMinutesForCoin(coin);

    if (creditedMinutes <= 0) {
      return;
    }

    activeSession.total += coin;
    activeSession.time += creditedMinutes;
    const currentRuntimeState = runtimeDeviceStates[activeSession.deviceId];
    if (currentRuntimeState) {
      runtimeDeviceStates[activeSession.deviceId] = {
        ...currentRuntimeState,
        totalSpent: Number(currentRuntimeState.totalSpent || 0) + coin,
        lastHeartbeatAt: Date.now(),
      };
    }

    console.log('COIN INSERTED:', {
      deviceId: activeSession.deviceId,
      coinValue: coin,
      creditedMinutes,
    });

    await logCoinInserted({
      deviceId: activeSession.deviceId,
      coinValue: coin,
      creditedMinutes,
      source: 'simulation',
    });

    sendToDevice(activeSession.deviceId, {
      event: 'coin_inserted',
      total: activeSession.total,
      time: activeSession.time,
      deviceId: activeSession.deviceId,
    });
  }, 5000);
}

async function processEsp32CoinInserted({
  deviceId,
  amount,
  txId,
  launcherDeviceId,
  launcherDeviceName,
}) {
  const normalizedDeviceId = String(deviceId || '').trim();
  const normalizedTxId = String(txId || '').trim();
  const coinValue = Number(amount) || 0;

  if (!normalizedDeviceId || !normalizedTxId || coinValue <= 0) {
    return {
      ack: false,
      reason: 'invalid_payload',
    };
  }

  const targetLauncherDeviceId = await resolveLauncherDeviceId({
    launcherDeviceId,
    launcherDeviceName,
    fallbackDeviceId: normalizedDeviceId,
  });
  const targetLauncherDeviceName = await resolveLauncherDeviceName({
    launcherDeviceId: targetLauncherDeviceId,
    launcherDeviceName,
  });

  const existingTransaction = await getQuery(
    `
      SELECT
        amount,
        credited_minutes AS creditedMinutes
      FROM esp32_coin_transactions
      WHERE device_id = ? AND tx_id = ?
    `,
    [normalizedDeviceId, normalizedTxId],
  );

  if (existingTransaction) {
    return {
      ack: true,
      duplicate: true,
      txId: normalizedTxId,
      deviceId: normalizedDeviceId,
      amount: Number(existingTransaction.amount || coinValue),
      creditedMinutes: Number(existingTransaction.creditedMinutes || 0),
    };
  }

  if (!activeSession || activeSession.deviceId !== targetLauncherDeviceId) {
    console.warn(
      'ESP32 COIN IGNORED: no active launcher session for',
      targetLauncherDeviceId || normalizedDeviceId,
    );
    sendAcceptorCommand({
      launcherDeviceId: targetLauncherDeviceId,
      launcherDeviceName: targetLauncherDeviceName,
      enabled: false,
      reason: 'session_not_active',
      queuePosition: 0,
    });
    return {
      ack: false,
      reason: 'session_not_active',
    };
  }

  const creditedMinutes = getConfiguredMinutesForCoin(coinValue);
  if (creditedMinutes <= 0) {
    return {
      ack: false,
      reason: 'coin_not_configured',
    };
  }

  activeSession.total += coinValue;
  activeSession.time += creditedMinutes;

  const currentRuntimeState = runtimeDeviceStates[targetLauncherDeviceId];
  if (currentRuntimeState) {
    runtimeDeviceStates[targetLauncherDeviceId] = {
      ...currentRuntimeState,
      totalSpent: Number(currentRuntimeState.totalSpent || 0) + coinValue,
      lastHeartbeatAt: Date.now(),
    };
  }

  await runQuery(
    `
      INSERT INTO esp32_coin_transactions (
        device_id,
        tx_id,
        amount,
        credited_minutes,
        source
      )
      VALUES (?, ?, ?, ?, 'esp32')
    `,
    [normalizedDeviceId, normalizedTxId, coinValue, creditedMinutes],
  );

  console.log('ESP32 COIN INSERTED:', {
    deviceId: normalizedDeviceId,
    launcherDeviceId: targetLauncherDeviceId,
    txId: normalizedTxId,
    coinValue,
    creditedMinutes,
  });

  await logCoinInserted({
    deviceId: targetLauncherDeviceId,
    coinValue,
    creditedMinutes,
    source: 'esp32',
  });

  sendToDevice(targetLauncherDeviceId, {
    event: 'coin_inserted',
    total: activeSession.total,
    time: activeSession.time,
    deviceId: targetLauncherDeviceId,
  });

  return {
    ack: true,
    txId: normalizedTxId,
    deviceId: normalizedDeviceId,
    launcherDeviceId: targetLauncherDeviceId,
    coinValue,
    creditedMinutes,
    total: activeSession.total,
    time: activeSession.time,
  };
}

async function updateDeviceState({
  deviceId,
  status,
  remainingSeconds,
  username,
  role,
  isSessionActive,
  batteryLevel,
  chargerRelayPin,
}) {
  const normalizedDeviceId = String(deviceId || '').trim();
  if (!normalizedDeviceId) {
    const error = new Error('deviceId is required');
    error.statusCode = 400;
    throw error;
  }

  const normalizedRemainingSeconds = Math.max(
    0,
    Number(remainingSeconds) || 0,
  );
  const normalizedUsername = String(username || '').trim() || 'Guest';
  const normalizedBatteryLevel =
    batteryLevel == null ? null : Math.max(0, Math.min(100, Number(batteryLevel) || 0));
  const normalizedChargerRelayPin =
    chargerRelayPin == null ? null : Number(chargerRelayPin) || 0;
  const previousState = runtimeDeviceStates[normalizedDeviceId];
  const previousRelayPin = launcherRelayPins[normalizedDeviceId] ?? null;
  const nextIsSessionActive = Boolean(isSessionActive);
  const sessionStartedAt = nextIsSessionActive
    ? previousState?.isSessionActive
      ? previousState.sessionStartedAt
      : new Date().toISOString()
    : null;

  runtimeDeviceStates[normalizedDeviceId] = {
    status: String(status || '').trim().toLowerCase() || 'online',
    remainingSeconds: normalizedRemainingSeconds,
    username: normalizedUsername,
    role: String(role || '').trim().toLowerCase() || 'guest',
    isSessionActive: nextIsSessionActive,
    sessionStartedAt,
    batteryLevel: normalizedBatteryLevel,
    chargerRelayPin: normalizedChargerRelayPin,
    totalSpent:
      activeSession?.deviceId === normalizedDeviceId
        ? Number(activeSession.total || 0)
        : Number(previousState?.totalSpent || 0),
    lastHeartbeatAt: Date.now(),
  };

  await upsertKnownDevice(normalizedDeviceId);
  if (normalizedChargerRelayPin != null && normalizedChargerRelayPin > 0) {
    launcherRelayPins[normalizedDeviceId] = normalizedChargerRelayPin;
  }

  const relayChanged =
    normalizedChargerRelayPin != null &&
    normalizedChargerRelayPin > 0 &&
    previousRelayPin != null &&
    previousRelayPin !== normalizedChargerRelayPin;

  if (relayChanged && chargingRelayStates[normalizedDeviceId] === true) {
    const launcherDeviceName =
      launcherDeviceNames[normalizedDeviceId] || deriveDeviceName(normalizedDeviceId);

    sendChargerCommand({
      launcherDeviceId: normalizedDeviceId,
      launcherDeviceName,
      enabled: false,
      reason: 'relay_reassigned_old_off',
      batteryLevel: normalizedBatteryLevel,
      relayPin: previousRelayPin,
    });

    sendChargerCommand({
      launcherDeviceId: normalizedDeviceId,
      launcherDeviceName,
      enabled: true,
      reason: 'relay_reassigned_new_on',
      batteryLevel: normalizedBatteryLevel,
      relayPin: normalizedChargerRelayPin,
    });
    return {
      success: true,
    };
  }

  evaluateChargingForDevice(normalizedDeviceId);

  return {
    success: true,
  };
}

function listLiveSessions() {
  return Object.entries(runtimeDeviceStates)
    .filter(([, state]) => {
      return (
        Boolean(state.isSessionActive) &&
        Date.now() - Number(state.lastHeartbeatAt || 0) <= 30000
      );
    })
    .map(([deviceId, state]) => ({
      id: deviceId,
      kioskId: deviceId,
      userName: state.username || 'Guest',
      startTime:
        state.sessionStartedAt ||
        new Date(Number(state.lastHeartbeatAt || Date.now())).toISOString(),
      timeLeft: Math.max(0, Number(state.remainingSeconds) || 0),
      totalSpent:
        activeSession?.deviceId === deviceId
          ? Number(activeSession.total || 0)
          : Number(state.totalSpent || 0),
    }))
    .sort((left, right) => left.kioskId.localeCompare(right.kioskId));
}

function getSessionState(deviceId) {
  const normalizedDeviceId = String(deviceId || '').trim();
  if (!normalizedDeviceId) {
    const error = new Error('deviceId is required');
    error.statusCode = 400;
    throw error;
  }

  if (activeSession?.deviceId === normalizedDeviceId) {
    return {
      success: true,
      status: 'started',
      position: 0,
      total: Number(activeSession.total) || 0,
      time: Number(activeSession.time) || 0,
      deviceId: normalizedDeviceId,
    };
  }

  return {
    success: true,
    status: 'idle',
    position: 0,
    total: 0,
    time: 0,
    deviceId: normalizedDeviceId,
  };
}

function startSessionForDevice(deviceId, logLabel = 'SESSION STARTED') {
  activeSession = {
    deviceId,
    deviceName: launcherDeviceNames[deviceId] || '',
    total: 0,
    time: 0,
    active: true,
  };

  const previousState = runtimeDeviceStates[deviceId];
  runtimeDeviceStates[deviceId] = {
    status: previousState?.status || 'online',
    remainingSeconds: Number(previousState?.remainingSeconds || 0),
    username: previousState?.username || 'Guest',
    role: previousState?.role || 'guest',
    isSessionActive: Boolean(previousState?.isSessionActive),
    sessionStartedAt: previousState?.sessionStartedAt || null,
    totalSpent: 0,
    lastHeartbeatAt: Date.now(),
  };

  console.log(`${logLabel}:`, deviceId);

  sendToDevice(deviceId, {
    event: 'session_started',
    deviceId,
  });

  sendAcceptorCommand({
    launcherDeviceId: deviceId,
    launcherDeviceName: launcherDeviceNames[deviceId] || '',
    enabled: true,
    reason: 'session_started',
    queuePosition: 0,
  });

  startCoinSimulation();
}

function registerClient(socket, deviceId) {
  if (clients[deviceId]) {
    console.log('Replacing old socket for:', deviceId);
    clients[deviceId].disconnect();
    delete clients[deviceId];
  }

  clients[deviceId] = socket;
  socket.deviceId = deviceId;
  socket.connectedAt = new Date().toISOString();
  socket.join(deviceId);

  const address =
    socket.handshake?.address ||
    socket.conn?.remoteAddress ||
    '';

  upsertKnownDevice(deviceId, {
    ipAddress: String(address).replace(/^::ffff:/, ''),
  }).catch((error) => {
    console.error('UPSERT KNOWN DEVICE ERROR', error);
  });

  console.log('Registered:', deviceId);

  if (activeSession && activeSession.deviceId === deviceId) {
    socket.emit('event', {
      event: 'session_started',
      deviceId,
    });

    if ((Number(activeSession.total) || 0) > 0 || (Number(activeSession.time) || 0) > 0) {
      socket.emit('event', {
        event: 'coin_inserted',
        total: Number(activeSession.total) || 0,
        time: Number(activeSession.time) || 0,
        deviceId,
      });
    }
    return;
  }

}

function disconnectClient(socket) {
  if (socket.deviceId && clients[socket.deviceId] === socket) {
    delete clients[socket.deviceId];
    console.log('Disconnected:', socket.deviceId);
  }
}

async function listDevices() {
  const knownDevices = await allQuery(
    `
      SELECT
        device_id AS deviceId,
        device_name AS deviceName,
        is_locked AS isLocked,
        last_seen AS lastSeen,
        last_ip_address AS ipAddress
      FROM known_devices
      ORDER BY device_name COLLATE NOCASE ASC, device_id COLLATE NOCASE ASC
    `,
  );

  return knownDevices.map((device) => {
    const deviceId = device.deviceId;
    const socket = clients[deviceId];
    const isActiveDevice = activeSession?.deviceId === deviceId;
    const runtimeState = runtimeDeviceStates[deviceId];
    const isLocked = Number(device.isLocked || 0) === 1;
    const hasFreshHeartbeat =
      runtimeState != null &&
      Date.now() - Number(runtimeState.lastHeartbeatAt || 0) <= 30000;
    const address =
      socket?.handshake?.address ||
      socket?.conn?.remoteAddress ||
      device.ipAddress ||
      '';

    let status = 'offline';
    if (isLocked) {
      status = 'locked';
    } else if (
      socket?.connected ||
      isActiveDevice ||
      (hasFreshHeartbeat && runtimeState.status === 'online')
    ) {
      status = 'online';
    }

    const isSessionActive =
      (hasFreshHeartbeat && Boolean(runtimeState.isSessionActive)) ||
      isActiveDevice;
    const remainingSeconds = hasFreshHeartbeat
      ? Math.max(0, Number(runtimeState.remainingSeconds) || 0)
      : 0;

    return {
      id: deviceId,
      name: device.deviceName || deriveDeviceName(deviceId),
      status,
      lastSeen: socket?.connectedAt || device.lastSeen || new Date().toISOString(),
      ipAddress: String(address).replace(/^::ffff:/, ''),
      username: hasFreshHeartbeat ? runtimeState.username || 'Guest' : 'Guest',
      isLocked,
      queuePosition: 0,
      isSessionActive,
      totalInserted: isActiveDevice ? activeSession?.total || 0 : 0,
      creditedMinutes: hasFreshHeartbeat
        ? Math.ceil(remainingSeconds / 60)
        : isActiveDevice
          ? activeSession?.time || 0
          : 0,
      remainingSeconds,
      batteryLevel: hasFreshHeartbeat
        ? runtimeState.batteryLevel ?? null
        : null,
      chargerRelayPin: hasFreshHeartbeat
        ? runtimeState.chargerRelayPin ?? launcherRelayPins[deviceId] ?? null
        : launcherRelayPins[deviceId] ?? null,
      isCharging: Boolean(chargingRelayStates[deviceId]),
    };
  });
}

async function getDeviceStatus(deviceId) {
  const normalizedDeviceId = String(deviceId || '').trim();
  if (!normalizedDeviceId) {
    const error = new Error('deviceId is required');
    error.statusCode = 400;
    throw error;
  }

  await upsertKnownDevice(normalizedDeviceId);
  const locked = await isDeviceLocked(normalizedDeviceId);

  return {
    success: true,
    deviceId: normalizedDeviceId,
    isLocked: locked,
    message: locked ? 'Device is locked.' : '',
  };
}

async function setDeviceLock(deviceId, isLocked) {
  const normalizedDeviceId = String(deviceId || '').trim();
  if (!normalizedDeviceId) {
    const error = new Error('deviceId is required');
    error.statusCode = 400;
    throw error;
  }

  await upsertKnownDevice(normalizedDeviceId);
  await runQuery(
    `
      UPDATE known_devices
      SET is_locked = ?, last_seen = CURRENT_TIMESTAMP
      WHERE device_id = ?
    `,
    [isLocked ? 1 : 0, normalizedDeviceId],
  );

  return {
    success: true,
    deviceId: normalizedDeviceId,
    isLocked: Boolean(isLocked),
  };
}

async function registerAccount(username, password) {
  const credentials = validateCredentials(username, password);
  if (!credentials) {
    const error = new Error('username and password are required');
    error.statusCode = 400;
    throw error;
  }

  try {
    await runQuery(
      `
        INSERT INTO customer_accounts (username, password_hash, role)
        VALUES (?, ?, 'customer')
      `,
      [credentials.username, hashPassword(credentials.password)],
    );
  } catch (error) {
    if (String(error.message || '').includes('UNIQUE')) {
      const conflict = new Error('username already exists');
      conflict.statusCode = 409;
      throw conflict;
    }
    throw error;
  }

  return {
    success: true,
    username: credentials.username,
    role: 'customer',
    savedSessionSeconds: 0,
  };
}

async function loginAccount(username, password) {
  const credentials = validateCredentials(username, password);
  if (!credentials) {
    const error = new Error('username and password are required');
    error.statusCode = 400;
    throw error;
  }

  const account = await getQuery(
    `
      SELECT username, password_hash, role, saved_session_seconds
        , account_status
      FROM customer_accounts
      WHERE username = ?
    `,
    [credentials.username],
  );

  if (!account || account.password_hash !== hashPassword(credentials.password)) {
    const error = new Error('invalid username or password');
    error.statusCode = 401;
    throw error;
  }

  const accountStatus = normalizeAccountStatus(account.account_status);
  if (accountStatus === BANNED_ACCOUNT_STATUS) {
    const error = new Error('This account is banned.');
    error.statusCode = 403;
    throw error;
  }

  if (accountStatus === DEACTIVATED_ACCOUNT_STATUS) {
    const error = new Error('This account is deactivated.');
    error.statusCode = 403;
    throw error;
  }

  return {
    success: true,
    username: account.username,
    role: account.role || 'customer',
    accountStatus: accountStatus || ACTIVE_ACCOUNT_STATUS,
    savedSessionSeconds: account.saved_session_seconds || 0,
  };
}

async function listCustomerAccounts() {
  const rows = await allQuery(
    `
      SELECT
        username,
        role,
        account_status AS accountStatus,
        saved_session_seconds AS savedSessionSeconds,
        created_at AS createdAt,
        updated_at AS updatedAt
      FROM customer_accounts
      ORDER BY role DESC, username COLLATE NOCASE ASC
    `,
  );

  return {
    success: true,
    items: rows.map((row) => ({
      username: row.username,
      role: row.role || 'customer',
      accountStatus:
        normalizeAccountStatus(row.accountStatus) || ACTIVE_ACCOUNT_STATUS,
      savedSessionSeconds: Number(row.savedSessionSeconds || 0),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    })),
  };
}

async function updateCustomerAccountStatus(username, status) {
  const normalizedUsername = normalizeUsername(username);
  const normalizedStatus = normalizeAccountStatus(status);

  if (!normalizedUsername) {
    const error = new Error('username is required');
    error.statusCode = 400;
    throw error;
  }

  if (!ALLOWED_ACCOUNT_STATUSES.has(normalizedStatus)) {
    const error = new Error('Invalid account status.');
    error.statusCode = 400;
    throw error;
  }

  const account = await getQuery(
    `
      SELECT username, role
      FROM customer_accounts
      WHERE username = ?
    `,
    [normalizedUsername],
  );

  if (!account) {
    const error = new Error('Account not found.');
    error.statusCode = 404;
    throw error;
  }

  if ((account.role || '').toLowerCase() === 'admin') {
    const error = new Error('Admin accounts cannot be disabled.');
    error.statusCode = 403;
    throw error;
  }

  await runQuery(
    `
      UPDATE customer_accounts
      SET account_status = ?, updated_at = CURRENT_TIMESTAMP
      WHERE username = ?
    `,
    [normalizedStatus, normalizedUsername],
  );

  return {
    success: true,
    username: normalizedUsername,
    accountStatus: normalizedStatus,
  };
}

async function saveSessionForAccount(username, remainingSeconds) {
  const normalizedUsername = normalizeUsername(username);
  const normalizedSeconds = Math.max(0, Number(remainingSeconds) || 0);

  if (!normalizedUsername) {
    const error = new Error('username is required');
    error.statusCode = 400;
    throw error;
  }

  const result = await runQuery(
    `
      UPDATE customer_accounts
      SET saved_session_seconds = ?, updated_at = CURRENT_TIMESTAMP
      WHERE username = ?
    `,
    [normalizedSeconds, normalizedUsername],
  );

  if (result.changes === 0) {
    const error = new Error('account not found');
    error.statusCode = 404;
    throw error;
  }

  return {
    success: true,
    username: normalizedUsername,
    savedSessionSeconds: normalizedSeconds,
  };
}

async function claimSessionForAccount(username) {
  const normalizedUsername = normalizeUsername(username);

  if (!normalizedUsername) {
    const error = new Error('username is required');
    error.statusCode = 400;
    throw error;
  }

  const account = await getQuery(
    `
      SELECT saved_session_seconds
      FROM customer_accounts
      WHERE username = ?
    `,
    [normalizedUsername],
  );

  if (!account) {
    const error = new Error('account not found');
    error.statusCode = 404;
    throw error;
  }

  const savedSessionSeconds = account.saved_session_seconds || 0;

  await runQuery(
    `
      UPDATE customer_accounts
      SET saved_session_seconds = 0, updated_at = CURRENT_TIMESTAMP
      WHERE username = ?
    `,
    [normalizedUsername],
  );

  return {
    success: true,
    username: normalizedUsername,
    savedSessionSeconds,
  };
}

async function listCoinLogs(limitValue) {
  const limit = Math.min(500, Math.max(1, Number(limitValue) || 100));
  const rows = await allQuery(
    `
      SELECT
        id,
        device_id AS deviceId,
        coin_value AS coinValue,
        credited_minutes AS creditedMinutes,
        source,
        created_at AS createdAt
      FROM coin_insert_logs
      ORDER BY id DESC
      LIMIT ?
    `,
    [limit],
  );

  return {
    success: true,
    count: rows.length,
    totalSales: rows.reduce((sum, row) => sum + Number(row.coinValue || 0), 0),
    items: rows,
  };
}

async function verifyAdminPin(pin) {
  const normalizedPin = String(pin || '').trim();
  if (!normalizedPin) {
    const error = new Error('pin is required');
    error.statusCode = 400;
    throw error;
  }

  const row = await getQuery(
    `
      SELECT pin
      FROM admin_settings
      WHERE id = 1
    `,
  );

  return {
    success: true,
    valid: row?.pin === normalizedPin,
  };
}

async function updateAdminPin(currentPin, newPin) {
  const currentValue = String(currentPin || '').trim();
  const nextValue = String(newPin || '').trim();

  if (!currentValue || !nextValue) {
    const error = new Error('currentPin and newPin are required');
    error.statusCode = 400;
    throw error;
  }

  if (nextValue.length != 6) {
    const error = new Error('new PIN must be 6 digits');
    error.statusCode = 400;
    throw error;
  }

  const row = await getQuery(
    `
      SELECT pin
      FROM admin_settings
      WHERE id = 1
    `,
  );

  if (!row || row.pin !== currentValue) {
    const error = new Error('current PIN is invalid');
    error.statusCode = 401;
    throw error;
  }

  await runQuery(
    `
      UPDATE admin_settings
      SET pin = ?, updated_at = CURRENT_TIMESTAMP
      WHERE id = 1
    `,
    [nextValue],
  );

  return {
    success: true,
  };
}

async function startSession(deviceId, deviceName = '') {
  if (!deviceId) {
    const error = new Error('deviceId required');
    error.statusCode = 400;
    throw error;
  }

  const normalizedDeviceName = String(deviceName || '').trim();
  if (normalizedDeviceName) {
    launcherDeviceNames[deviceId] = normalizedDeviceName;
  }

  await upsertKnownDevice(deviceId);

  if (await isDeviceLocked(deviceId)) {
    return {
      status: 'locked',
      position: 0,
      message: 'Device is locked.',
    };
  }

  if (activeSession && activeSession.deviceId === deviceId) {
    console.log('SESSION ALREADY ACTIVE:', deviceId);

    sendToDevice(deviceId, {
      event: 'session_started',
      deviceId,
    });

    sendAcceptorCommand({
      launcherDeviceId: deviceId,
      launcherDeviceName: launcherDeviceNames[deviceId] || '',
      enabled: true,
      reason: 'session_already_active',
      queuePosition: 0,
    });

    startCoinSimulation();

    return {
      status: 'started',
      position: 0,
    };
  }

  if (!activeSession) {
    startSessionForDevice(deviceId);

    return {
      status: 'started',
      position: 0,
    };
  }
  const activeDeviceName =
    activeSession.deviceName || deriveDeviceName(activeSession.deviceId);
  console.log('SESSION BUSY:', {
    requestedDeviceId: deviceId,
    activeDeviceId: activeSession.deviceId,
    activeDeviceName,
  });

  return {
    status: 'busy',
    position: 0,
    message: `Another customer is currently inserting coins on ${activeDeviceName}. Please try again in a moment.`,
  };
}

function confirmSession(deviceId) {
  if (activeSession && activeSession.deviceId === deviceId) {
    console.log('SESSION ENDED:', deviceId);
    sendAcceptorCommand({
      launcherDeviceId: deviceId,
      launcherDeviceName:
        activeSession.deviceName || launcherDeviceNames[deviceId] || '',
      enabled: false,
      reason: 'session_confirmed',
      queuePosition: 0,
    });
    activeSession = null;
    stopCoinSimulation();
  }

  return { success: true };
}

function releaseSession(deviceId) {
  if (!activeSession) {
    return { success: true, released: 'none' };
  }

  if (activeSession.deviceId !== deviceId) {
    return { success: false, message: 'Not current session owner' };
  }

  console.log('SESSION RELEASED:', deviceId);
  sendAcceptorCommand({
    launcherDeviceId: deviceId,
    launcherDeviceName:
      activeSession.deviceName || launcherDeviceNames[deviceId] || '',
    enabled: false,
    reason: 'session_released',
    queuePosition: 0,
  });
  activeSession = null;
  stopCoinSimulation();

  return { success: true, released: 'active' };
}

async function getAudioSettings() {
  const row = await getQuery(
    `
      SELECT
        audio_enabled,
        audio_url,
        audio_loop,
        audio_volume
      FROM audio_settings
      WHERE id = 1
    `,
  );

  const settings = {
    audioEnabled: Boolean(row?.audio_enabled),
    audioUrl: row?.audio_url || null,
    audioLoop: Boolean(row?.audio_loop !== 0),
    audioVolume: Math.max(0, Math.min(1, Number(row?.audio_volume) || 1.0)),
  };

  return {
    success: true,
    audio: settings,
  };
}

async function updateAudioSettings(audioEnabled, audioUrl, audioLoop, audioVolume) {
  const nextSettings = {
    audioEnabled: Boolean(audioEnabled),
    audioUrl: String(audioUrl || '').trim() || null,
    audioLoop: Boolean(audioLoop),
    audioVolume: Math.max(0, Math.min(1, Number(audioVolume) || 1.0)),
  };

  await runQuery(
    `
      UPDATE audio_settings
      SET
        audio_enabled = ?,
        audio_url = ?,
        audio_loop = ?,
        audio_volume = ?,
        updated_at = CURRENT_TIMESTAMP
      WHERE id = 1
    `,
    [
      nextSettings.audioEnabled ? 1 : 0,
      nextSettings.audioUrl,
      nextSettings.audioLoop ? 1 : 0,
      nextSettings.audioVolume,
    ],
  );

  const io = getIO();
  if (io) {
    io.emit('audioSettingsUpdated', nextSettings);
  }

  return {
    success: true,
    audio: nextSettings,
  };
}

getCoinSettings().catch((error) => {
  console.error('INITIAL COIN SETTINGS LOAD ERROR', error);
});

getChargingSettings().catch((error) => {
  console.error('INITIAL CHARGING SETTINGS LOAD ERROR', error);
});

module.exports = {
  registerClient,
  disconnectClient,
  trackEsp32Socket,
  registerEsp32Client,
  disconnectEsp32Client,
  trackChargerSocket,
  registerChargerClient,
  disconnectChargerClient,
  processChargerAck,
  registerAccount,
  loginAccount,
  listCustomerAccounts,
  updateCustomerAccountStatus,
  saveSessionForAccount,
  claimSessionForAccount,
  getCoinSettings,
  updateCoinSettings,
  getChargingSettings,
  updateChargingSettings,
  listCoinLogs,
  verifyAdminPin,
  updateAdminPin,
  updateDeviceState,
  broadcastMessage,
  listDevices,
  getDeviceStatus,
  setDeviceLock,
  listLiveSessions,
  getSessionState,
  startSession,
  confirmSession,
  releaseSession,
  processEsp32CoinInserted,
  getAudioSettings,
  updateAudioSettings,
};
