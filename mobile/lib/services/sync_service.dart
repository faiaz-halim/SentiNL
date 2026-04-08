import 'dart:convert';
import 'package:http/http.dart' as http;
import 'database_helper.dart';

class SyncService {
  static const String _baseUrl = const String.fromEnvironment('BACKEND_URL', defaultValue: 'http://10.0.2.2:8000');
  static const Duration _timeout = Duration(seconds: 30);

  final DatabaseHelper _dbHelper;
  final http.Client _httpClient;

  SyncService({
    DatabaseHelper? dbHelper,
    http.Client? httpClient,
  })  : _dbHelper = dbHelper ?? DatabaseHelper.instance,
        _httpClient = httpClient ?? http.Client();

  Future<SyncResult> checkForUpdates() async {
    int currentVersion = 0;
    try {
      currentVersion = await _dbHelper.getDbVersion();
      final response = await _httpClient
          .get(Uri.parse('$_baseUrl/api/db-updates?version=$currentVersion'))
          .timeout(_timeout);

      if (response.statusCode == 200) {
        return SyncResult.fromJson(response.body, currentVersion);
      } else {
        return SyncResult(
          hasUpdates: false,
          newVersion: currentVersion,
          error: 'Server returned status ${response.statusCode}',
        );
      }
    } catch (e) {
      return SyncResult(
        hasUpdates: false,
        newVersion: currentVersion,
        error: e.toString(),
      );
    }
  }

  Future<bool> syncDatabase() async {
    try {
      final updateResult = await checkForUpdates();

      if (!updateResult.hasUpdates) {
        return true;
      }

      for (final url in updateResult.blacklistedUrls) {
        await _dbHelper.insertBlacklistedUrl({
          'url': url['url'],
          'threat_level': url['threat_level'],
          'description': url['description'],
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      for (final pattern in updateResult.scamPatterns) {
        await _dbHelper.insertScamPattern({
          'pattern': pattern['pattern'],
          'pattern_type': pattern['pattern_type'],
          'threat_level': pattern['threat_level'],
          'description': pattern['description'],
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  Future<VerificationResult> verifyWithCloud(String text) async {
    try {
      final response = await _httpClient
          .post(
            Uri.parse('$_baseUrl/api/verify'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'text': text}),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        return VerificationResult.fromJson(response.body);
      } else {
        return VerificationResult(
          success: false,
          error: 'Server returned status ${response.statusCode}',
        );
      }
    } catch (e) {
      return VerificationResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  void dispose() {
    _httpClient.close();
  }
}

class SyncResult {
  final bool hasUpdates;
  final int newVersion;
  final List<Map<String, dynamic>> blacklistedUrls;
  final List<Map<String, dynamic>> scamPatterns;
  final String? error;

  SyncResult({
    required this.hasUpdates,
    required this.newVersion,
    this.blacklistedUrls = const [],
    this.scamPatterns = const [],
    this.error,
  });

  factory SyncResult.fromJson(String jsonBody, int currentVersion) {
    try {
      final Map<String, dynamic> data = jsonDecode(jsonBody);

      if (data['version'] != null && data['version'] > currentVersion) {
        return SyncResult(
          hasUpdates: true,
          newVersion: data['version'] ?? currentVersion,
          blacklistedUrls:
              List<Map<String, dynamic>>.from(data['blacklisted_urls'] ?? []),
          scamPatterns:
              List<Map<String, dynamic>>.from(data['scam_patterns'] ?? []),
        );
      }

      return SyncResult(
        hasUpdates: false,
        newVersion: currentVersion,
      );
    } catch (e) {
      return SyncResult(
        hasUpdates: false,
        newVersion: currentVersion,
        error: 'Failed to parse response: $e',
      );
    }
  }
}

class VerificationResult {
  final bool success;
  final String? context;
  final String? error;

  VerificationResult({
    required this.success,
    this.context,
    this.error,
  });

  factory VerificationResult.fromJson(String jsonBody) {
    try {
      final Map<String, dynamic> data = jsonDecode(jsonBody);
      return VerificationResult(
        success: true,
        context: data['context'] ?? '',
      );
    } catch (e) {
      return VerificationResult(
        success: false,
        error: 'Failed to parse response: $e',
      );
    }
  }
}
