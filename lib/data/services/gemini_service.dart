import 'dart:convert';
import 'dart:typed_data';

import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';
import '../models/parsed_entry.dart';

/// Wraps the Google Generative AI SDK and handles expense parsing.
class GeminiService {
  GeminiService._();

  static final GeminiService instance = GeminiService._();

  GenerativeModel? _model;
  GenerativeModel? _multiModel; // no responseMimeType — allows JSON arrays

  // ── API key management ─────────────────────────────────────────────────────

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(AppConstants.prefKeyApiKey);
    if (key != null && key.isNotEmpty) {
      _model = GenerativeModel(
        model: 'gemini-2.5-flash',
        apiKey: key,
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          temperature: 0.1,
        ),
      );
      _multiModel = GenerativeModel(
        model: 'gemini-2.5-flash',
        apiKey: key,
        generationConfig: GenerationConfig(temperature: 0.1),
      );
    }
  }

  Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefKeyApiKey, key);
    _model = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: key,
      generationConfig: GenerationConfig(
        responseMimeType: 'application/json',
        temperature: 0.1,
      ),
    );
    _multiModel = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: key,
      generationConfig: GenerationConfig(temperature: 0.1),
    );
  }

  Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(AppConstants.prefKeyApiKey);
  }

  bool get isConfigured => _model != null && _multiModel != null;

  // ── Parsing ────────────────────────────────────────────────────────────────

  /// Parse a natural-language expense string into a [ParsedEntry].
  /// Throws a descriptive [GeminiException] on failure.
  Future<ParsedEntry> parseExpense(String input) async {
    if (_model == null) {
      throw GeminiException('Gemini API key not configured.');
    }

    final prompt = AppConstants.geminiPrompt(input);

    try {
      final response = await _model!.generateContent([Content.text(prompt)]);
      final text = response.text;

      if (text == null || text.isEmpty) {
        throw GeminiException('Empty response from Gemini.');
      }

      // Strip potential markdown code fences just in case
      final clean = text
          .replaceAll(RegExp(r'```json\s*'), '')
          .replaceAll(RegExp(r'```\s*'), '')
          .trim();

      final json = jsonDecode(clean) as Map<String, dynamic>;
      return ParsedEntry.fromJson(json);
    } on GeminiException {
      rethrow;
    } catch (e) {
      throw GeminiException('Failed to parse expense: $e');
    }
  }

  /// Parse one or more expenses from a single natural-language input.
  /// Returns a list of [ParsedEntry] — handles both single and multi-expense inputs.
  Future<List<ParsedEntry>> parseExpenses(String input) async {
    if (_multiModel == null) {
      throw GeminiException('Gemini API key not configured.');
    }

    final prompt = AppConstants.geminiMultiPrompt(input);

    try {
      final response = await _multiModel!.generateContent([Content.text(prompt)]);
      final text = response.text;

      if (text == null || text.isEmpty) {
        throw GeminiException('Empty response from Gemini.');
      }

      final clean = text
          .replaceAll(RegExp(r'```json\s*'), '')
          .replaceAll(RegExp(r'```\s*'), '')
          .trim();

      final decoded = jsonDecode(clean);
      if (decoded is List) {
        return decoded
            .map((e) => ParsedEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      } else if (decoded is Map<String, dynamic>) {
        // Fallback: single object returned instead of array
        return [ParsedEntry.fromJson(decoded)];
      }
      throw GeminiException('Unexpected response format from Gemini.');
    } on GeminiException {
      rethrow;
    } catch (e) {
      throw GeminiException('Failed to parse expenses: $e');
    }
  }

  // ── Audio parsing ──────────────────────────────────────────────────────────

  /// Transcribes [audioBytes] (recorded via MediaRecorder) and extracts
  /// expense entries using Gemini's multimodal API.
  ///
  /// [mimeType] must be one Gemini accepts: audio/webm, audio/mp4, audio/ogg.
  Future<List<ParsedEntry>> parseAudioExpenses(
      Uint8List audioBytes, String mimeType) async {
    if (_multiModel == null) {
      throw GeminiException('Gemini API key not configured.');
    }

    final today = DateTime.now().toIso8601String().substring(0, 10);
    final prompt =
        'You are a personal expense tracker assistant. The user has spoken '
        'their expenses. Transcribe exactly what they said, then extract all '
        'expense entries from the transcript.\n\n'
        'Return a JSON array. Each element must have:\n'
        '  "amount": number (always positive),\n'
        '  "category": one of [${categories.join(', ')}],\n'
        '  "description": brief description,\n'
        '  "date": "YYYY-MM-DD" (use today $today if not specified)\n\n'
        'Return ONLY the raw JSON array — no markdown, no explanation, no code '
        'fences. If you cannot detect any expenses, return [].';

    try {
      final response = await _multiModel!.generateContent([
        Content.multi([
          DataPart(mimeType, audioBytes),
          TextPart(prompt),
        ]),
      ]);

      final text = response.text;
      if (text == null || text.isEmpty) {
        throw GeminiException('Empty response from Gemini.');
      }

      final clean = text
          .replaceAll(RegExp(r'```json\s*'), '')
          .replaceAll(RegExp(r'```\s*'), '')
          .trim();

      final decoded = jsonDecode(clean);
      if (decoded is List) {
        return decoded
            .map((e) => ParsedEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      } else if (decoded is Map<String, dynamic>) {
        return [ParsedEntry.fromJson(decoded)];
      }
      throw GeminiException('Unexpected response format from Gemini.');
    } on GeminiException {
      rethrow;
    } catch (e) {
      throw GeminiException('Failed to parse audio: $e');
    }
  }
}

/// Typed exception from the Gemini service.
class GeminiException implements Exception {
  final String message;
  const GeminiException(this.message);

  @override
  String toString() => 'GeminiException: $message';
}
