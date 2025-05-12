import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// API 키를 안전하게 관리하기 위한 클래스
class ApiKeyManager {
  static const String _apiKeyPrefKey = 'gemini_api_key';
  static const String _apikeyEnvFile = 'apikey.env';

  /// API 키 저장
  static Future<bool> saveApiKey(String apiKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(_apiKeyPrefKey, apiKey);
    } catch (e) {
      debugPrint('API 키 저장 오류: $e');
      return false;
    }
  }

  /// 저장된 API 키 가져오기
  static Future<String?> getApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_apiKeyPrefKey);
    } catch (e) {
      debugPrint('API 키 로드 오류: $e');
      return null;
    }
  }

  /// API 키 삭제
  static Future<bool> deleteApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.remove(_apiKeyPrefKey);
    } catch (e) {
      debugPrint('API 키 삭제 오류: $e');
      return false;
    }
  }

  /// apikey.env 파일에서 API 키 로드
  static Future<String?> loadApiKeyFromEnvFile() async {
    try {
      // 파일 존재 여부 확인
      final fileExists = await File(_apikeyEnvFile).exists();

      if (fileExists) {
        // 파일이 존재하면 내용 읽기
        final content = await File(_apikeyEnvFile).readAsString();
        final apiKey = content.trim();

        if (apiKey.isNotEmpty) {
          debugPrint('apikey.env 파일에서 API 키 로드 성공');
          // API 키를 SharedPreferences에 저장
          await saveApiKey(apiKey);
          return apiKey;
        }
      } else {
        // 대안으로 애셋에서 읽기 시도
        try {
          final content = await rootBundle.loadString(_apikeyEnvFile);
          final apiKey = content.trim();

          if (apiKey.isNotEmpty) {
            debugPrint('애셋에서 API 키 로드 성공');
            // API 키를 SharedPreferences에 저장
            await saveApiKey(apiKey);
            return apiKey;
          }
        } catch (assetError) {
          debugPrint('애셋에서 API 키 로드 오류: $assetError');
        }
      }

      return null;
    } catch (e) {
      debugPrint('apikey.env 파일에서 API 키 로드 오류: $e');
      return null;
    }
  }

  /// 앱 첫 실행 시 샘플 API 키 제공 (실제 배포에서는 빈 문자열 반환 권장)
  static String getSampleApiKey() {
    // 개발용 샘플 키 - 실제 프로덕션 앱에서는 이 부분을 비워두는 것이 좋습니다
    if (kDebugMode) {
      return '여기에_샘플_API_키_입력'; // 개발 시에만 사용할 샘플 키
    }
    return ''; // 프로덕션 환경에서는 빈 문자열 반환
  }
}
