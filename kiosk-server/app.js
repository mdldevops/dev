const fs = require('fs');
const path = require('path');
const express = require('express');
const cors = require('cors');

const {
  apiRateLimiter,
  authRateLimiter,
  adminRateLimiter,
  deviceStateRateLimiter,
  buildCorsOptions,
} = require('./src/config/security');
const userController = require('./src/controllers/userController');
require('./src/config/database');

const app = express();
const corsOptions = buildCorsOptions();
const adminDistPath = path.resolve(__dirname, '../piso-stream-admin/dist');
const adminIndexPath = path.join(adminDistPath, 'index.html');
const hasAdminBuild =
  fs.existsSync(adminDistPath) && fs.existsSync(adminIndexPath);

app.set('trust proxy', 1);
app.use(cors(corsOptions));
app.options(/.*/, cors(corsOptions));
app.use(express.json());

app.use('/auth/register', authRateLimiter);
app.use('/auth/login', authRateLimiter);
app.use('/admin/verify-pin', adminRateLimiter);
app.use('/admin/update-pin', adminRateLimiter);
app.use('/device-state', deviceStateRateLimiter);
app.use(apiRateLimiter);

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

if (hasAdminBuild) {
  app.use(express.static(adminDistPath));

  app.get(/^\/(?!auth\/|admin\/|customers(?:\/|$)|broadcast$|settings\/|device-state$|devices(?:\/|$)|sessions(?:\/|$)|sales\/|start-session$|confirm-session$|release-session$|health$|socket\.io\/?).*/, (_req, res) => {
    res.sendFile(adminIndexPath);
  });
}

module.exports = app;
