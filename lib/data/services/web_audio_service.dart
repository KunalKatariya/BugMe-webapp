// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/foundation.dart';

/// Records audio in the browser using the MediaRecorder API.
///
/// Safari  → records as audio/mp4 (AAC) — supported since Safari 14.1
/// Chrome  → records as audio/webm (Opus)
/// Firefox → records as audio/ogg
class WebAudioService {
  html.MediaRecorder? _recorder;
  html.MediaStream? _stream;
  final List<html.Blob> _chunks = [];
  Completer<(Uint8List, String)>? _completer;
  String _activeMime = '';

  // ── MIME detection ─────────────────────────────────────────────────────────

  static String get bestMimeType {
    const candidates = [
      'audio/webm;codecs=opus',
      'audio/webm',
      'audio/mp4',
      'audio/ogg;codecs=opus',
      '',
    ];
    for (final t in candidates) {
      if (t.isEmpty) return '';
      if (html.MediaRecorder.isTypeSupported(t)) return t;
    }
    return '';
  }

  /// Gemini-friendly MIME (strips codec params e.g. ";codecs=opus").
  static String cleanMime(String raw) {
    final base = raw.split(';').first.trim();
    return base.isEmpty ? 'audio/webm' : base;
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  bool get isRecording => _recorder?.state == 'recording';

  Future<void> start() async {
    _chunks.clear();
    _completer = Completer();
    _activeMime = '';

    debugPrint('[WebAudio] Requesting mic permission…');
    try {
      _stream = await html.window.navigator.mediaDevices!
          .getUserMedia({'audio': true, 'video': false});
    } catch (e) {
      debugPrint('[WebAudio] Mic permission denied: $e');
      throw WebAudioException('Microphone access denied. $e');
    }
    debugPrint('[WebAudio] Mic stream obtained.');

    final mime = bestMimeType;
    debugPrint('[WebAudio] Best MIME type: "$mime"');

    try {
      _recorder = html.MediaRecorder(
        _stream!,
        mime.isNotEmpty ? {'mimeType': mime} : {},
      );
    } catch (e) {
      _stream?.getTracks().forEach((t) => t.stop());
      throw WebAudioException('MediaRecorder not supported: $e');
    }

    _activeMime = (_recorder!.mimeType?.isNotEmpty == true)
        ? _recorder!.mimeType!
        : mime;
    debugPrint('[WebAudio] Recorder mimeType: "$_activeMime"');

    _recorder!.addEventListener('dataavailable', (event) {
      final blob = (event as html.BlobEvent).data;
      debugPrint('[WebAudio] dataavailable: blob size=${blob?.size ?? 0}');
      if (blob != null && blob.size > 0) _chunks.add(blob);
    });

    _recorder!.addEventListener('stop', (_) {
      debugPrint('[WebAudio] stop event. chunks=${_chunks.length}');

      // Stop tracks AFTER the recorder has flushed data — not before.
      _stream?.getTracks().forEach((t) => t.stop());

      if (_completer == null || _completer!.isCompleted) return;

      if (_chunks.isEmpty) {
        debugPrint('[WebAudio] No audio chunks captured!');
        _completer!.completeError(
            WebAudioException('No audio data was captured.'));
        return;
      }

      final recordedMime =
          _activeMime.isNotEmpty ? _activeMime : cleanMime(mime);
      debugPrint('[WebAudio] Building blob: mimeType="$recordedMime"');

      final fullBlob = html.Blob(_chunks, recordedMime);
      debugPrint('[WebAudio] fullBlob.size=${fullBlob.size}');

      // Read as data URL (base64) — avoids ByteBuffer cast issues in DDC/Safari.
      final reader = html.FileReader();
      reader.readAsDataUrl(fullBlob);

      reader.addEventListener('loadend', (_) {
        if (_completer == null || _completer!.isCompleted) return;
        final dataUrl = reader.result;
        if (dataUrl == null || dataUrl is! String) {
          debugPrint('[WebAudio] FileReader result is null or not a string!');
          _completer!.completeError(
              WebAudioException('FileReader result was null.'));
          return;
        }
        // dataUrl format: "data:audio/webm;base64,AAAA..."
        final comma = dataUrl.indexOf(',');
        if (comma < 0) {
          _completer!.completeError(
              WebAudioException('Unexpected data URL format.'));
          return;
        }
        final bytes = base64Decode(dataUrl.substring(comma + 1));
        final finalMime = cleanMime(recordedMime);
        debugPrint('[WebAudio] Done: ${bytes.length} bytes, mime="$finalMime"');
        _completer!.complete((bytes, finalMime));
      });

      reader.addEventListener('error', (_) {
        if (_completer == null || _completer!.isCompleted) return;
        debugPrint('[WebAudio] FileReader error: ${reader.error}');
        _completer!.completeError(
            WebAudioException('Failed to read audio data: ${reader.error}'));
      });
    });

    _recorder!.addEventListener('error', (event) {
      debugPrint('[WebAudio] MediaRecorder error: $event');
      if (_completer != null && !_completer!.isCompleted) {
        _completer!.completeError(
            WebAudioException('MediaRecorder error: $event'));
      }
    });

    // 1-second timeslice: Safari needs this to flush chunks reliably.
    _recorder!.start(1000);
    debugPrint('[WebAudio] Recording started (timeslice=1000ms).');
  }

  /// Stops recording and returns `(audioBytes, mimeType)`.
  ///
  /// Do NOT stop stream tracks here — that happens inside the 'stop' event
  /// handler after Safari has flushed all audio data.
  Future<(Uint8List, String)> stop() async {
    debugPrint('[WebAudio] stop() called. state=${_recorder?.state}');
    if (_recorder?.state == 'recording' || _recorder?.state == 'paused') {
      _recorder!.stop();
    } else {
      debugPrint('[WebAudio] Recorder not recording — stopping tracks anyway.');
      _stream?.getTracks().forEach((t) => t.stop());
    }
    return _completer!.future;
  }

  void dispose() {
    try {
      _recorder?.stop();
      _stream?.getTracks().forEach((t) => t.stop());
    } catch (_) {}
  }
}

class WebAudioException implements Exception {
  final String message;
  const WebAudioException(this.message);

  @override
  String toString() => message;
}
