const express = require('express');
const cors = require('cors');

const userController = require('./src/controllers/userController');
require('./src/config/database');

const app = express();

app.use(cors());
app.use(express.json());

app.get('/health', (_req, res) => {
  res.json({
    success: true,
    status: 'ok',
    timestamp: new Date().toISOString(),
  });
});

app.post('/auth/register', userController.register);
app.post('/auth/login', userController.login);
app.get('/customers', userController.getCustomers);
app.post('/customers/status', userController.updateCustomerStatus);
app.post('/auth/save-session', userController.saveSession);
app.post('/auth/claim-session', userController.claimSession);
app.post('/admin/verify-pin', userController.verifyAdminPin);
app.post('/admin/update-pin', userController.updateAdminPin);
app.post('/broadcast', userController.broadcastMessage);
app.get('/settings/coin-config', userController.getCoinSettings);
app.post('/settings/coin-config', userController.updateCoinSettings);
app.get('/settings/charging-config', userController.getChargingSettings);
app.post('/settings/charging-config', userController.updateChargingSettings);
app.post('/device-state', userController.updateDeviceState);

app.get('/devices', userController.getDevices);
app.get('/devices/:deviceId/status', userController.getDeviceStatus);
app.post('/devices/lock', userController.setDeviceLock);
app.get('/sessions', userController.getLiveSessions);
app.get('/sessions/:deviceId/state', userController.getSessionState);
app.get('/sales/coin-logs', userController.getCoinLogs);

app.post('/start-session', userController.startSession);
app.post('/confirm-session', userController.confirmSession);
app.post('/release-session', userController.releaseSession);
app.get('/settings/audio-config', userController.getAudioSettings);
app.post('/settings/audio-config', userController.updateAudioSettings);

module.exports = app;
