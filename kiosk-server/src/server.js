const http = require('http');
const { Server } = require('socket.io');

const app = require('../app');
const { initializeSockets } = require('./sockets');
const { setIO } = require('./utils/socketManager');

const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: '*' },
});

setIO(io);
initializeSockets(io, server);

module.exports = {
  server,
  io,
};
