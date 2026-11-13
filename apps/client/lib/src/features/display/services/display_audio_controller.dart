import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../../app_brand.dart';

abstract interface class DisplaySpeechEngine {
  void errors(void Function(dynamic)? callback);
  Future<dynamic> stop();
  Future<dynamic> available(String language);
  Future<dynamic> language(String language);
  Future<dynamic> speak(String text);
}

/// Picks the best Indonesian voice. Android Chrome may report `id_ID`, `id`
/// or the legacy `in-ID`; exact `id-ID` is preferred over looser matches.
Map<String, String>? pickIndonesianVoice(Iterable<dynamic> voices) {
  Map<String, String>? loose;
  for (final raw in voices) {
    if (raw is! Map) continue;
    final locale = '${raw['locale'] ?? raw['lang'] ?? ''}'
        .trim()
        .replaceAll('_', '-')
        .toLowerCase();
    final voice = {
      'name': '${raw['name'] ?? ''}',
      'locale': '${raw['locale'] ?? raw['lang'] ?? ''}',
    };
    if (locale == 'id-id') return voice;
    if (locale == 'id' ||
        locale.startsWith('id-') ||
        locale == 'in' ||
        locale == 'in-id') {
      loose ??= voice;
    }
  }
  return loose;
}

class FlutterDisplaySpeech implements DisplaySpeechEngine {
  FlutterDisplaySpeech({
    this.voiceWait = const Duration(milliseconds: 3000),
    this.voicePoll = const Duration(milliseconds: 250),
  });

  final _tts = FlutterTts();
  final Duration voiceWait, voicePoll;
  Map<String, String>? _voice;

  @override
  void errors(void Function(dynamic)? callback) => _tts.errorHandler = callback;
  @override
  Future<dynamic> stop() => _tts.stop();

  /// Browser voices load asynchronously (empty on first call, then fires
  /// `voiceschanged`), so poll until an Indonesian voice appears or time runs out.
  @override
  Future<dynamic> available(String language) async {
    final deadline = DateTime.now().add(voiceWait);
    var total = 0;
    while (true) {
      try {
        final voices = await _tts.getVoices;
        if (voices is List) {
          total = voices.length;
          final match = pickIndonesianVoice(voices);
          if (match != null) {
            _voice = match;
            debugPrint(
              '[DisplayTTS] voice ${match['name']} (${match['locale']})',
            );
            return true;
          }
        }
      } catch (error) {
        debugPrint('[DisplayTTS] getVoices failed: $error');
        break;
      }
      if (!DateTime.now().isBefore(deadline)) break;
      await Future<void>.delayed(voicePoll);
    }
    _voice = null;
    try {
      final native = await _tts.isLanguageAvailable(language);
      debugPrint(
        '[DisplayTTS] isLanguageAvailable($language)=$native voices=$total',
      );
      return native;
    } catch (error) {
      debugPrint('[DisplayTTS] isLanguageAvailable failed: $error');
      return false;
    }
  }

  @override
  Future<dynamic> language(String language) async {
    final voice = _voice;
    if (voice != null) {
      try {
        await _tts.setVoice(voice);
      } catch (error) {
        debugPrint('[DisplayTTS] setVoice failed: $error');
      }
      return _tts.setLanguage(voice['locale']!.replaceAll('_', '-'));
    }
    return _tts.setLanguage(language);
  }

  @override
  Future<dynamic> speak(String text) => _tts.speak(text);
}

/// Separates the notification tone from speech, and permits fake audio in tests.
abstract interface class DisplayIntroChime {
  Future<void> play();
  Future<void> stop();
  Future<void> dispose();
}

/// Keeps existing speech-engine-only tests independent of the audio plugin.
class _SilentIntroChime implements DisplayIntroChime {
  @override
  Future<void> play() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

/// A small, generated 3-second PCM WAV. No extra sound asset is required.
/// The data URI works on the browser and through audioplayers' platform APIs.
class _GeneratedIntroChime implements DisplayIntroChime {
  AudioPlayer? _player;
  Completer<void>? _playing;
  int _generation = 0;
  bool _disposed = false;

  static final String _source =
      'data:audio/wav;base64,${base64Encode(_makeWav())}';

  static Uint8List _makeWav() {
    const sampleRate = 16000;
    const seconds = 3;
    const sampleCount = sampleRate * seconds;
    const dataBytes = sampleCount * 2; // PCM, mono, 16-bit.
    final output = Uint8List(44 + dataBytes);
    final bytes = ByteData.sublistView(output);

    output.setRange(0, 4, 'RIFF'.codeUnits);
    bytes.setUint32(4, 36 + dataBytes, Endian.little);
    output.setRange(8, 12, 'WAVE'.codeUnits);
    output.setRange(12, 16, 'fmt '.codeUnits);
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little); // PCM.
    bytes.setUint16(22, 1, Endian.little); // Mono.
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    output.setRange(36, 40, 'data'.codeUnits);
    bytes.setUint32(40, dataBytes, Endian.little);

    double note(double time, double start, double duration, double frequency) {
      final elapsed = time - start;
      if (elapsed < 0 || elapsed >= duration) return 0;
      final attack = (elapsed / 0.025).clamp(0.0, 1.0);
      final release = math.pow(1 - elapsed / duration, 2).toDouble();
      final fundamental = math.sin(2 * math.pi * frequency * elapsed);
      final overtone = math.sin(2 * math.pi * frequency * 2 * elapsed);
      return attack * release * (fundamental + 0.12 * overtone);
    }

    for (var i = 0; i < sampleCount; i++) {
      final time = i / sampleRate;
      final value =
          0.20 *
          (note(time, 0.05, 0.90, 523.25) +
              note(time, 0.78, 0.95, 659.25) +
              note(time, 1.52, 1.12, 783.99));
      final pcm = (value * 32767).round().clamp(-32768, 32767);
      bytes.setInt16(44 + i * 2, pcm, Endian.little);
    }
    return output;
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    final generation = ++_generation;
    final completed = Completer<void>();
    _playing = completed;
    final player = _player ??= AudioPlayer();
    final completion = player.onPlayerComplete.listen((_) {
      if (!completed.isCompleted) completed.complete();
    });
    try {
      await player.play(
        UrlSource(_source, mimeType: 'audio/wav'),
        volume: 0.48,
      );
      if (_disposed || generation != _generation) {
        await player.stop();
        return;
      }
      // Playback completion, not an arbitrary delay, gates the spoken message.
      await completed.future.timeout(const Duration(milliseconds: 4200));
    } finally {
      await completion.cancel();
      if (identical(_playing, completed)) _playing = null;
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    final pending = _playing;
    if (pending != null && !pending.isCompleted) pending.complete();
    try {
      await _player?.stop();
    } catch (_) {
      // Continue cancelling speech even if the platform audio player fails.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _player?.dispose();
    _player = null;
  }
}

/// Per monitor, no backlog. A user gesture must successfully activate speech.
class DisplayAudioController extends ChangeNotifier {
  DisplayAudioController({
    DisplaySpeechEngine? engine,
    DisplayIntroChime? intro,
  }) : engine = engine ?? FlutterDisplaySpeech(),
       // Existing fakes only test the TTS contract; real devices use the chime.
       intro =
           intro ??
           (engine == null ? _GeneratedIntroChime() : _SilentIntroChime()) {
    this.engine.errors((message) {
      if (!['canceled', 'interrupted'].contains('$message')) _failed();
    });
  }

  final DisplaySpeechEngine engine;
  final DisplayIntroChime intro;
  bool enabled = false, busy = false, _active = false, _disposed = false;
  String? error;
  int _epoch = 0, _toggleEpoch = 0;
  bool _suspended = false;
  Future<bool>? _speechPending;
  Future<void> get settled async {
    await _speechPending;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void context(bool active) {
    _toggleEpoch++;
    _active = active;
    enabled = false;
    busy = false;
    error = null;
    rebase();
    _notify();
  }

  void suspend() {
    _suspended = true;
    _toggleEpoch++;
    busy = false;
    rebase();
    _notify();
  }

  void resume() {
    _suspended = false;
    rebase();
  }

  void rebase() {
    _epoch++;
    unawaited(_stop());
  }

  Future<void> _stop() async {
    try {
      await Future.wait([intro.stop(), engine.stop()]);
    } catch (_) {
      // The visual queue remains available if the audio device is lost.
    }
  }

  void _failed() {
    if (_disposed || !_active) return;
    _epoch++;
    enabled = false;
    busy = false;
    error = 'Suara tidak tersedia. Gunakan pengumuman visual.';
    unawaited(_stop());
    _notify();
  }

  Future<bool> _speak(String text, {bool withIntro = false}) async {
    final epoch = ++_epoch;
    bool current() => !_disposed && _active && !_suspended && epoch == _epoch;
    try {
      await _stop();
      if (!current()) return false;
      if (withIntro) {
        try {
          await intro.play();
        } catch (_) {
          // A blocked/unavailable chime must never suppress the patient call.
          await intro.stop();
        }
        if (!current()) return false;
      }
      final available = await engine.available('id-ID');
      if (!current()) return false;
      if (available != true && available != 1) {
        throw StateError('Voice unavailable');
      }
      final language = await engine.language('id-ID');
      if (!current()) return false;
      if (language == 0 || language == false) {
        throw StateError('Language rejected');
      }
      final result = await engine.speak(text);
      if (!current()) return false;
      if (result == 0 || result == false) throw StateError('Speech rejected');
      return true;
    } catch (error) {
      debugPrint('[DisplayTTS] speech failed: $error');
      if (current()) {
        _failed();
        // Audible fallback: the generated chime needs no speech voices.
        if (!withIntro) {
          try {
            await _stop();
            await intro.play();
          } catch (_) {}
        }
      }
      return false;
    }
  }

  Future<void> announce(String text) async {
    if (_disposed || !_active || _suspended || !enabled || text.isEmpty) return;
    await (_speechPending = _speak(text, withIntro: true));
  }

  Future<void> toggle() async {
    if (_disposed || !_active || _suspended || busy) return;
    final operation = ++_toggleEpoch;
    busy = true;
    _notify();
    final epoch = _epoch;
    try {
      if (enabled) {
        enabled = false;
        _epoch++;
        await _stop();
      } else if (await (_speechPending = _speak(
        'Suara pengumuman ${AppBrand.name} aktif.',
      ))) {
        if (!_disposed && _active && _epoch == epoch + 1) {
          enabled = true;
          error = null;
        }
      }
    } finally {
      if (!_disposed && operation == _toggleEpoch) {
        busy = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _active = false;
    enabled = false;
    _epoch++;
    engine.errors(null);
    unawaited(_stop().whenComplete(intro.dispose));
    super.dispose();
  }
}
