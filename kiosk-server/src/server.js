const http = require('http');
const { Server } = require('socket.io');

const app = require('../app');
const { buildSocketCorsOptions } = require('./config/security');
const { initializeSockets } = require('./sockets');
const { setIO } = require('./utils/socketManager');

const server = http.createServer(app);
const io = new Server(server, {
  cors: buildSocketCorsOptions(),
});

setIO(io);
initializeSockets(io, server);

module.exports = {
  server,
  io,
};
