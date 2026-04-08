import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

class OcrService {
  final ImagePicker _imagePicker = ImagePicker();
  final TextRecognizer _textRecognizer = TextRecognizer();

  Future<File?> pickImage() async {
    final XFile? pickedFile = await _imagePicker.pickImage(
      source: ImageSource.gallery,
    );
    if (pickedFile != null) {
      return File(pickedFile.path);
    }
    return null;
  }

  Future<File?> pickImageFromCamera() async {
    final XFile? pickedFile = await _imagePicker.pickImage(
      source: ImageSource.camera,
    );
    if (pickedFile != null) {
      return File(pickedFile.path);
    }
    return null;
  }

  Future<String> extractText(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    final RecognizedText recognizedText =
        await _textRecognizer.processImage(inputImage);
    return recognizedText.text;
  }

  List<String> extractUrls(String text) {
    final urlRegex = RegExp(
      r'https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*)',
      caseSensitive: false,
    );
    return urlRegex.allMatches(text).map((match) => match.group(0)!).toList();
  }

  List<String> extractPhoneNumbers(String text) {
    final phoneRegex = RegExp(
      r'(\+?1?[-.\s]?)?(\(?\d{3}\)?[-.\s]?)?\d{3}[-.\s]?\d{4}',
    );
    return phoneRegex.allMatches(text).map((match) => match.group(0)!).toList();
  }

  void dispose() {
    _textRecognizer.close();
  }
}
