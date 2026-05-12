const userService = require('../services/userService');
const { WebSocketServer } = require('ws');

function initializeSockets(io, httpServer) {
  io.on('connection', (socket) => {
    console.log('Client connected:', socket.id);

    socket.on('register', (deviceId) => {
      userService.registerClient(socket, deviceId);
    });

    socket.on('disconnect', () => {
      userService.disconnectClient(socket);
    });
  });

  const esp32SocketServer = new WebSocketServer({
    server: httpServer,
    path: '/esp32',
  });

  const chargerSocketServer = new WebSocketServer({
    server: httpServer,
    path: '/charger',
  });

  esp32SocketServer.on('connection', (socket, request) => {
    console.log('ESP32 connected:', request.socket.remoteAddress);
    userService.trackEsp32Socket(socket);

    socket.on('message', async (rawMessage) => {
      try {
        const payload = JSON.parse(String(rawMessage || '{}'));
        if (payload.type === 'register_esp32') {
          userService.registerEsp32Client(socket, payload);
          socket.send(
            JSON.stringify({
              type: 'register_ack',
              device_id: payload.device_id || null,
              launcher_device_id: payload.launcher_device_id || null,
              launcher_device_name: payload.launcher_device_name || null,
            }),
          );
          return;
        }

        if (payload.type !== 'coin_inserted') {
          return;
        }

        const result = await userService.processEsp32CoinInserted({
          deviceId: payload.device_id,
          amount: payload.amount,
          txId: payload.tx_id,
          launcherDeviceId: payload.launcher_device_id,
          launcherDeviceName: payload.launcher_device_name,
        });

        if (result.ack) {
          socket.send(
            JSON.stringify({
              type: 'ack',
              tx_id: payload.tx_id,
              device_id: result.deviceId,
              launcher_device_id: result.launcherDeviceId || null,
              duplicate: result.duplicate === true,
            }),
          );
          return;
        }

        socket.send(
          JSON.stringify({
            type: 'nack',
            tx_id: payload.tx_id,
            device_id: payload.device_id,
            reason: result.reason || 'rejected',
          }),
        );
      } catch (error) {
        console.error('ESP32 MESSAGE ERROR', error);
        socket.send(
          JSON.stringify({
            type: 'nack',
            reason: 'server_error',
          }),
        );
      }
    });

    socket.on('close', () => {
      userService.disconnectEsp32Client(socket);
      console.log('ESP32 disconnected:', request.socket.remoteAddress);
    });
  });

  chargerSocketServer.on('connection', (socket, request) => {
    console.log('Charger controller connected:', request.socket.remoteAddress);
    userService.trackChargerSocket(socket);

    socket.on('message', (rawMessage) => {
      try {
        const payload = JSON.parse(String(rawMessage || '{}'));
        if (payload.type !== 'register_charger') {
          return;
        }

        userService.registerChargerClient(socket, payload);
        socket.send(
          JSON.stringify({
            type: 'register_ack',
            device_id: payload.device_id || null,
            launcher_device_id: payload.launcher_device_id || null,
            launcher_device_name: payload.launcher_device_name || null,
          }),
        );
      } catch (error) {
        console.error('CHARGER MESSAGE ERROR', error);
      }
    });

    socket.on('close', () => {
      userService.disconnectChargerClient(socket);
      console.log('Charger controller disconnected:', request.socket.remoteAddress);
    });
  });
}

module.exports = {
  initializeSockets,
};
