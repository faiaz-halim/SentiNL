import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/database_helper.dart';
import '../services/ocr_service.dart';
import '../services/llm_service.dart';
import '../services/sync_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final OcrService _ocrService = OcrService();
  final LlmService _llmService = LlmService();
  final SyncService _syncService = SyncService();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  bool _isAnalyzing = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String? _extractedText;
  String? _analysisResult;
  String _threatLevel = 'SAFE';
  String? _errorMessage;
  bool _showFallbackButton = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initializeServices();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.photos,
      Permission.camera,
      Permission.storage,
    ].request();
  }

  Future<void> _initializeServices() async {
    final modelDownloaded = await _llmService.isModelDownloaded();
    if (!modelDownloaded) {
      setState(() {
        _isDownloading = true;
      });
      try {
        await _llmService.downloadModel(
          onProgress: (progress) {
            setState(() {
              _downloadProgress = progress;
            });
          },
        );
        await _llmService.initialize();
      } catch (e) {
        setState(() {
          _errorMessage = 'Failed to download model: $e';
        });
      } finally {
        setState(() {
          _isDownloading = false;
        });
      }
    } else {
      await _llmService.initialize();
    }

    await _syncService.syncDatabase();
  }

  Future<void> _onAnalyzePressed() async {
    setState(() {
      _isAnalyzing = true;
      _errorMessage = null;
      _analysisResult = null;
      _showFallbackButton = false;
    });

    try {
      File? imageFile = await _ocrService.pickImage();
      if (imageFile == null) {
        imageFile = await _ocrService.pickImageFromCamera();
      }

      if (imageFile == null) {
        setState(() {
          _isAnalyzing = false;
          _errorMessage = 'No image selected';
        });
        return;
      }

      final extractedText = await _ocrService.extractText(imageFile);

      setState(() {
        _extractedText = extractedText;
      });

      if (extractedText.isEmpty) {
        setState(() {
          _isAnalyzing = false;
          _errorMessage = 'No text found in image';
        });
        return;
      }

      final urls = _ocrService.extractUrls(extractedText);
      bool dbMatchFound = false;

      for (final url in urls) {
        final isMalicious = await _dbHelper.checkIfUrlMalicious(url);
        if (isMalicious) {
          dbMatchFound = true;
          break;
        }
      }

      if (!dbMatchFound) {
        dbMatchFound = await _dbHelper.checkIfPatternMalicious(extractedText);
      }

      final analysisResult = await _llmService.analyzeText(
        extractedText,
        dbMatchFound: dbMatchFound,
      );

      final threatLevel = _llmService.parseThreatLevel(analysisResult);

      setState(() {
        _analysisResult = analysisResult;
        _threatLevel = threatLevel;
        _showFallbackButton = true;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Analysis failed: $e';
      });
    } finally {
      setState(() {
        _isAnalyzing = false;
      });
    }
  }

  Future<void> _onCheckWebPressed() async {
    if (_extractedText == null) return;

    setState(() {
      _isAnalyzing = true;
      _errorMessage = null;
    });

    try {
      final verificationResult =
          await _syncService.verifyWithCloud(_extractedText!);

      if (verificationResult.success && verificationResult.context != null) {
        final analysisResult = await _llmService.analyzeText(
          _extractedText!,
          dbMatchFound: false,
          webContext: verificationResult.context,
        );

        final threatLevel = _llmService.parseThreatLevel(analysisResult);

        setState(() {
          _analysisResult = analysisResult;
          _threatLevel = threatLevel;
        });
      } else {
        setState(() {
          _errorMessage =
              verificationResult.error ?? 'Cloud verification failed';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Cloud verification failed: $e';
      });
    } finally {
      setState(() {
        _isAnalyzing = false;
      });
    }
  }

  Color _getThreatColor() {
    switch (_threatLevel) {
      case 'DANGER':
        return Colors.red;
      case 'CAUTION':
        return Colors.orange;
      default:
        return Colors.green;
    }
  }

  @override
  void dispose() {
    _ocrService.dispose();
    _llmService.dispose();
    _syncService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFEB3B),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 20),
              const Text(
                'SentiNL',
                style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Scam Detector for Seniors',
                style: TextStyle(
                  fontSize: 24,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 40),
              if (_isDownloading)
                Column(
                  children: [
                    const Text(
                      'Downloading AI Model...',
                      style: TextStyle(fontSize: 20, color: Colors.black87),
                    ),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: _downloadProgress,
                      backgroundColor: Colors.grey[300],
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(Colors.black),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(_downloadProgress * 100).toInt()}%',
                      style:
                          const TextStyle(fontSize: 16, color: Colors.black54),
                    ),
                  ],
                )
              else
                SizedBox(
                  width: double.infinity,
                  height: 120,
                  child: ElevatedButton.icon(
                    onPressed: _isAnalyzing ? null : _onAnalyzePressed,
                    icon: _isAnalyzing
                        ? const SizedBox(
                            width: 32,
                            height: 32,
                            child:
                                CircularProgressIndicator(color: Colors.black),
                          )
                        : const Icon(Icons.camera_alt, size: 40),
                    label: Text(
                      _isAnalyzing ? 'Analyzing...' : 'Analyze Screenshot',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: const Color(0xFFFFEB3B),
                      textStyle: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.red[100],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(fontSize: 16, color: Colors.red),
                  ),
                ),
              ],
              if (_analysisResult != null) ...[
                const SizedBox(height: 24),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _getThreatColor().withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _getThreatColor(), width: 2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _threatLevel == 'SAFE'
                                ? Icons.check_circle
                                : _threatLevel == 'CAUTION'
                                    ? Icons.warning
                                    : Icons.dangerous,
                            color: _getThreatColor(),
                            size: 32,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _threatLevel,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: _getThreatColor(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      MarkdownBody(
                        data: _analysisResult!,
                        styleSheet: MarkdownStyleSheet(
                          p: const TextStyle(
                              fontSize: 16, color: Colors.black87),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_showFallbackButton) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 60,
                    child: ElevatedButton(
                      onPressed: _isAnalyzing ? null : _onCheckWebPressed,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue[700],
                        foregroundColor: Colors.white,
                        textStyle: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Check Web for Details'),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 40),
              const Text(
                'Take a photo of a message or screenshot to check for scams',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, color: Colors.black54),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
