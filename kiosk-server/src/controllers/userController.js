const userService = require('../services/userService');

function handleError(res, label, error) {
  console.error(label, error);
  return res.status(error.statusCode || 500).json({
    error: error.message || 'Internal server error',
  });
}

async function register(req, res) {
  try {
    const result = await userService.registerAccount(
      req.body.username,
      req.body.password,
    );
    return res.json(result);
  } catch (error) {
    return handleError(res, 'REGISTER ERROR', error);
  }
}

async function login(req, res) {
  try {
    const result = await userService.loginAccount(
      req.body.username,
      req.body.password,
    );
    return res.json(result);
  } catch (error) {
    return handleError(res, 'LOGIN ERROR', error);
  }
}

async function saveSession(req, res) {
  try {
    const result = await userService.saveSessionForAccount(
      req.body.username,
      req.body.remainingSeconds,
    );
    return res.json(result);
  } catch (error) {
    return handleError(res, 'SAVE SESSION ERROR', error);
  }
}

async function claimSession(req, res) {
  try {
    const result = await userService.claimSessionForAccount(req.body.username);
    return res.json(result);
  } catch (error) {
    return handleError(res, 'CLAIM SESSION ERROR', error);
  }
}

async function getCustomers(req, res) {
  try {
    const result = await userService.listCustomerAccounts();
    return res.json(result);
  } catch (error) {
    return handleError(res, 'CUSTOMER LIST ERROR', error);
  }
}

async function updateCustomerStatus(req, res) {
  try {
    const result = await userService.updateCustomerAccountStatus(
      req.body.username,
      req.body.status,
    );
    return res.json(result);
  } catch (error) {
    return handleError(res, 'CUSTOMER STATUS UPDATE ERROR', error);
  }
}

async function getCoinLogs(req, res) {
  try {
    const result = await userService.listCoinLogs(req.query.limit);
    return res.json(result);
  } catch (error) {
    return handleError(res, 'COIN LOG LIST ERROR', error);
  }
}

async function getCoinSettings(req, res) {
  try {
    const result = await userService.getCoinSettings();
    return res.json(result);
  } catch (error) {
    return handleError(res, 'GET COIN SETTINGS ERROR', error);
  }
}

async function updateCoinSettings(req, res) {
  try {
    const result = await userService.updateCoinSettings(req.body.ratios);
    return res.json(result);
  } catch (error) {
    return handleError(res, 'UPDATE COIN SETTINGS ERROR', error);
  }
}

async function getChargingSettings(req, res) {
  try {
    const result = await userService.getChargingSettings();
    return res.json(result);
  } catch (error) {
    return handleError(res, 'GET CHARGING SETTINGS ERROR', error);
  }
}

async function updateChargingSettings(req, res) {
  try {
    const result = await userService.updateChargingSettings(req.body.settings);
    return res.json(result);
  } catch (error) {
    return handleError(res, 'UPDATE CHARGING SETTINGS ERROR', error);
  }
}

function broadcastMessage(req, res) {
  try {
    const result = userService.broadcastMessage(
      req.body.message,
      req.body.deviceIds,
    );
    return res.json(result);
  } catch (error) {
    return handleError(res, 'BROADCAST MESSAGE ERROR', error);
  }
}

async function getDevices(req, res) {
  try {
    const result = await userService.listDevices();
    return res.json({
      success: true,
      items: result,
    });
  } catch (error) {
    return handleError(res, 'DEVICE LIST ERROR', error);
  }
}

async function getDeviceStatus(req, res) {
  try {
    const result = await userService.getDeviceStatus(req.params.deviceId);
    return res.json(result);
  } catch (error) {
    return handleError(res, 'DEVICE STATUS ERROR', error);
  }
}

async function setDeviceLock(req, res) {
  try {
    const result = await userService.setDeviceLock(
      req.body.deviceId,
      req.body.isLocked,
    );
    return res.json(result);
  } catch (error) {
    return handleError(res, 'DEVICE LOCK UPDATE ERROR', error);
  }
}

function getLiveSessions(req, res) {
  try {
    const result = userService.listLiveSessions();
    return res.json({
      success: true,
      items: result,
    });
  } catch (error) {
    return handleError(res, 'LIVE SESSION LIST ERROR', error);
  }
}

function getSessionState(req, res) {
  try {
    const result = userService.getSessionState(req.params.deviceId);
    return res.json(result);
  } catch (error) {
    return handleError(res, 'SESSION STATE ERROR', error);
  }
}

async function verifyAdminPin(req, res) {
  try {
    const result = await userService.verifyAdminPin(req.body.pin);
    return res.json(result);
  } catch (error) {
    return handleError(res, 'VERIFY ADMIN PIN ERROR', error);
  }
}

async function updateAdminPin(req, res) {
  try {
    const result = await userService.updateAdminPin(
      req.body.currentPin,
      req.body.newPin,
    );
    return res.json(result);
  } catch (error) {
    return handleError(res, 'UPDATE ADMIN PIN ERROR', error);
  }
}

async function updateDeviceState(req, res) {
  try {
    const result = await userService.updateDeviceState({
      deviceId: req.body.deviceId,
      status: req.body.status,
      remainingSeconds: req.body.remainingSeconds,
      username: req.body.username,
      role: req.body.role,
      isSessionActive: req.body.isSessionActive,
      batteryLevel: req.body.batteryLevel,
    });
    return res.json(result);
  } catch (error) {
    return handleError(res, 'UPDATE DEVICE STATE ERROR', error);
  }
}

async function startSession(req, res) {
  try {
    const result = await userService.startSession(
      req.body.deviceId,
      req.body.deviceName,
    );
    return res.json(result);
  } catch (error) {
    return handleError(res, 'START SESSION ERROR', error);
  }
}

function confirmSession(req, res) {
  try {
    const result = userService.confirmSession(req.body.deviceId);
    return res.json(result);
  } catch (error) {
    return handleError(res, 'CONFIRM SESSION ERROR', error);
  }
}

function releaseSession(req, res) {
  try {
    const result = userService.releaseSession(req.body.deviceId);
    return res.json(result);
  } catch (error) {
    return handleError(res, 'RELEASE SESSION ERROR', error);
  }
}

async function getAudioSettings(req, res) {
  try {
    const result = await userService.getAudioSettings();
    return res.json(result);
  } catch (error) {
    return handleError(res, 'GET AUDIO SETTINGS ERROR', error);
  }
}

async function updateAudioSettings(req, res) {
  try {
    const result = await userService.updateAudioSettings(
      req.body.audioEnabled,
      req.body.audioUrl,
      req.body.audioLoop,
      req.body.audioVolume,
    );
    return res.json(result);
  } catch (error) {
    return handleError(res, 'UPDATE AUDIO SETTINGS ERROR', error);
  }
}

module.exports = {
  register,
  login,
  getCustomers,
  updateCustomerStatus,
  saveSession,
  claimSession,
  getDevices,
  getDeviceStatus,
  setDeviceLock,
  getLiveSessions,
  getSessionState,
  getCoinLogs,
  getCoinSettings,
  updateCoinSettings,
  getChargingSettings,
  updateChargingSettings,
  broadcastMessage,
  verifyAdminPin,
  updateAdminPin,
  updateDeviceState,
  startSession,
  confirmSession,
  releaseSession,
  getAudioSettings,
  updateAudioSettings,
};
