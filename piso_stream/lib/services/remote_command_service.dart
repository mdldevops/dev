class RemoteCommandService {
  RemoteCommandService._();

  static final RemoteCommandService instance = RemoteCommandService._();

  bool _started = false;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    print('[REMOTE] Service ready');
  }

  Future<void> stop() async {
    if (!_started) {
      return;
    }
    _started = false;
    print('[REMOTE] Service stopped');
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> dispatch(String command, [Map<String, dynamic>? payload]) async {
    print('[REMOTE] Command received: $command');
  }
}
