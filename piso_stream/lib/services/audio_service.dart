import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AudioService {
  static final AudioService _instance = AudioService._internal();
  static const MethodChannel _channel = MethodChannel(
    'com.example.piso_stream/installed_apps',
  );
  bool _isPlaying = false;

  factory AudioService() {
    return _instance;
  }

  AudioService._internal();

  Future<void> playAudio({
    required String audioPath,
    required bool loop,
    double volume = 1.0,
  }) async {
    try {
      await _channel.invokeMethod<void>('playAudio', {
        'audioPath': audioPath,
        'loop': loop,
        'volume': volume.clamp(0.0, 1.0),
      });
      _isPlaying = true;

      debugPrint(
        'Audio playback started: $audioPath (loop: $loop, volume: $volume)',
      );
    } catch (error) {
      debugPrint('Audio playback error: $error');
      rethrow;
    }
  }

  Future<void> stopAudio() async {
    try {
      await _channel.invokeMethod<void>('stopAudio');
      _isPlaying = false;
      debugPrint('Audio playback stopped');
    } catch (error) {
      debugPrint('Stop audio error: $error');
    }
  }

  Future<void> pauseAudio() async {
    await stopAudio();
  }

  Future<void> setVolume(double volume) async {
    try {
      await _channel.invokeMethod<void>('setAudioVolume', {
        'volume': volume.clamp(0.0, 1.0),
      });
    } catch (error) {
      debugPrint('Set volume error: $error');
    }
  }

  Future<void> dispose() async {
    try {
      await stopAudio();
    } catch (error) {
      debugPrint('Dispose audio error: $error');
    }
  }

  Future<void> playEffectAudio({
    required String audioPath,
    double volume = 1.0,
  }) async {
    try {
      await _channel.invokeMethod<void>('playEffectAudio', {
        'audioPath': audioPath,
        'volume': volume.clamp(0.0, 1.0),
      });
    } catch (error) {
      debugPrint('Effect audio playback error: $error');
      rethrow;
    }
  }

  Future<int?> getAudioDurationMs(String audioPath) async {
    try {
      final duration = await _channel.invokeMethod<int>('getAudioDurationMs', {
        'audioPath': audioPath,
      });
      return duration;
    } catch (error) {
      debugPrint('Get audio duration error: $error');
      return null;
    }
  }

  bool get isPlaying => _isPlaying;
}
