const rateLimit = require('express-rate-limit');

function getAllowedOrigins() {
  const rawOrigins = process.env.ALLOWED_ORIGINS || 'www.portal.pisostream.online';

  return rawOrigins
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean);
}

function isOriginAllowed(origin, allowedOrigins) {
  if (!origin) {
    return true;
  }

  if (!allowedOrigins.length) {
    return true;
  }

  return allowedOrigins.includes(origin);
}

function buildCorsOriginHandler() {
  const allowedOrigins = getAllowedOrigins();

  return (origin, callback) => {
    if (isOriginAllowed(origin, allowedOrigins)) {
      callback(null, true);
      return;
    }

    callback(new Error('Not allowed by CORS'));
  };
}

function buildCorsOptions() {
  return {
    origin: buildCorsOriginHandler(),
    credentials: true,
    methods: ['GET', 'POST', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization'],
  };
}

function buildSocketCorsOptions() {
  return {
    origin: buildCorsOriginHandler(),
    methods: ['GET', 'POST'],
    credentials: true,
  };
}

function createJsonRateLimiter({
  windowMs,
  max,
  message,
  skip,
}) {
  return rateLimit({
    windowMs,
    max,
    standardHeaders: true,
    legacyHeaders: false,
    skip,
    handler: (_req, res) => {
      res.status(429).json({
        success: false,
        error: message || 'Too many requests. Please try again later.',
      });
    },
  });
}

const authRateLimiter = createJsonRateLimiter({
  windowMs: 60 * 1000,
  max: 20,
  message: 'Too many authentication attempts. Please wait a minute and try again.',
});

const adminRateLimiter = createJsonRateLimiter({
  windowMs: 60 * 1000,
  max: 30,
  message: 'Too many admin requests. Please slow down and try again in a minute.',
});

const deviceStateRateLimiter = createJsonRateLimiter({
  windowMs: 60 * 1000,
  max: 1800,
  message: 'Too many device state updates. Please try again shortly.',
});

const apiRateLimiter = createJsonRateLimiter({
  windowMs: 60 * 1000,
  max: 600,
  message: 'Too many API requests. Please try again shortly.',
  skip: (req) => req.path === '/health' || req.path === '/device-state',
});

module.exports = {
  apiRateLimiter,
  authRateLimiter,
  adminRateLimiter,
  deviceStateRateLimiter,
  buildCorsOptions,
  buildSocketCorsOptions,
};
