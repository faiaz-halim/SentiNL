import 'dart:io';
import 'package:dio/dio.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LlmService {
  static const String _modelUrl = const String.fromEnvironment('MODEL_URL',
      defaultValue: 'http://10.0.2.2:8080/gemma-4-E2b-scam-q4_k_m.gguf');
  static const String _modelFileName = 'gemma-4-E2b-scam-q4_k_m.gguf';

  LlamaEngine? _engine;
  ChatSession? _chatSession;
  bool _isInitialized = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;

  bool get isInitialized => _isInitialized;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;

  Future<String> get _modelPath async {
    // Look directly in the external storage directory so the developer can push the file over USB!
    final appDir = await getExternalStorageDirectory();
    if (appDir == null) {
      // Fallback to internal documents if external is unavailable
      final fallbackDir = await getApplicationDocumentsDirectory();
      return '${fallbackDir.path}/$_modelFileName';
    }
    return '${appDir.path}/$_modelFileName';
  }

  Future<bool> isModelDownloaded() async {
    final path = await _modelPath;
    final file = File(path);
    if (!file.existsSync()) return false;

    // Safety check: The full GGUF is roughly 3.4GB (3,427,873,280 bytes).
    // If it is drastically smaller, it's a corrupted/partial download.
    if (file.lengthSync() < 3000000000) {
      await file.delete();
      return false;
    }
    return true;
  }

  Future<void> downloadModel({
    void Function(double progress)? onProgress,
  }) async {
    if (_isDownloading) return;

    final modelPath = await _modelPath;
    final file = File(modelPath);

    if (file.existsSync()) {
      _downloadProgress = 1.0;
      onProgress?.call(1.0);
      return;
    }

    _isDownloading = true;
    _downloadProgress = 0.0;

    // Crucial: Keep the screen and CPU awake during a 3GB transfer!
    WakelockPlus.enable();

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(minutes: 5),
        receiveTimeout: const Duration(hours: 2),
      ));

      await dio.download(
        _modelUrl,
        modelPath,
        deleteOnError: true, // Crucial: delete partial downloads!
        onReceiveProgress: (received, total) {
          if (total != -1) {
            _downloadProgress = received / total;
            onProgress?.call(_downloadProgress);
          }
        },
      );
    } catch (e) {
      _isDownloading = false;
      WakelockPlus.disable(); // Safety cleanup
      rethrow;
    }

    _isDownloading = false;
    _downloadProgress = 1.0;
    WakelockPlus.disable(); // Turn screen timeout back on
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    final modelPath = await _modelPath;
    final modelFile = File(modelPath);

    if (!modelFile.existsSync()) {
      throw Exception('Model not found. Please download the model first.');
    }

    final backend = LlamaBackend();
    _engine = LlamaEngine(backend);
    await _engine!.loadModel(modelPath);
    _chatSession = ChatSession(_engine!);
    _isInitialized = true;
  }

  String buildPrompt(String extractedText, bool dbMatchFound) {
    final dbMatchInstruction = dbMatchFound
        ? 'A match was found in the local blacklist database.'
        : 'No match found in the local blacklist database.';

    return '''Instruction: You are a scam detection assistant for seniors. Analyze the following message for potential scams. Provide a clear explanation in simple language.

$dbMatchInstruction

Message to analyze:
"$extractedText"

Response format:
- Threat level: SAFE / CAUTION / DANGER
- Explanation: [Simple explanation in 2-3 sentences]
- Recommendation: [What the user should do]''';
  }

  Future<String> analyzeText(
    String extractedText, {
    bool dbMatchFound = false,
    String? webContext,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    var prompt = buildPrompt(extractedText, dbMatchFound);

    if (webContext != null && webContext.isNotEmpty) {
      prompt += '''

Additional web verification context:
$webContext

Please consider this additional context and provide your final analysis.''';
    }

    final chunks = _chatSession!.create([LlamaTextContent(prompt)],
        params: const GenerationParams(maxTokens: 2048), enableThinking: false);
    final responseBuffer = StringBuffer();
    await for (final chunk in chunks) {
      final text = chunk.choices.first.delta.content;
      if (text != null) {
        responseBuffer.write(text);
      }
    }

    String finalResponse = responseBuffer.toString();

    // PRINT RAW RESPONSE FOR DEBUGGING
    print("\n\n=== RAW LLM RESPONSE ===");
    print(finalResponse);
    print("=========================\n\n");

    // 1. Strip raw model tags
    finalResponse =
        finalResponse.replaceAll(RegExp(r'<[^>]*channel[^>]*>'), '');
    finalResponse = finalResponse.replaceAll(RegExp(r'<\|.*?\|>'), '');

    // 2. If the model accidentally echoed the prompt instructions, delete them
    finalResponse = finalResponse.replaceAll(prompt, '');
    finalResponse = finalResponse.replaceAll(
        RegExp(r'Instruction:.*?Response format:.*?Recommendation: \[.*?\]',
            dotAll: true),
        '');

    // 3. Strip the Qwen thinking block entirely
    if (finalResponse.contains('</think>')) {
      finalResponse = finalResponse.split('</think>').last;
    }

    // 4. STRICTLY grab everything starting from "Threat level:"
    final regex =
        RegExp(r'(?:-\s*\*?\*?)?Threat\s*level:', caseSensitive: false);
    final matches = regex.allMatches(finalResponse);
    if (matches.isNotEmpty) {
      // Find the last occurrence to bypass any prompt echoes or thinking hallucinations
      finalResponse = finalResponse.substring(matches.last.start);
    } else {
      // Fallback: If model didn't use the exact word "Threat level:", assume the end of the thought block is the start of the answer.
      if (finalResponse.contains('</think>')) {
        finalResponse =
            "- Threat level: " + finalResponse.split('</think>').last.trim();
      } else if (finalResponse.contains('</channel>')) {
        finalResponse =
            "- Threat level: " + finalResponse.split('</channel>').last.trim();
      }
    }

    return finalResponse.trim();
  }

  String parseThreatLevel(String response) {
    // Only check the very first line to prevent the explanation from triggering false positives
    final firstLine = response.split('\n').first.toLowerCase();
    if (firstLine.contains('danger')) {
      return 'DANGER';
    } else if (firstLine.contains('caution')) {
      return 'CAUTION';
    }
    return 'SAFE';
  }

  Future<void> dispose() async {
    _chatSession = null;
    _engine?.dispose();
    _engine = null;
    _isInitialized = false;
  }
}
