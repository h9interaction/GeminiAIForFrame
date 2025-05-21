import 'dart:typed_data';

enum DeviceType { frame, mobile, none }

enum StreamingState { idle, preparing, streaming, error }

enum DeviceErrorType {
  permissionDenied,
  hardwareError,
  streamError,
  memoryError
}

class DeviceState {
  final DeviceType type;
  final StreamingState streamingState;
  final bool isAudioPlaying;
  final String? errorMessage;

  DeviceState({
    required this.type,
    required this.streamingState,
    required this.isAudioPlaying,
    this.errorMessage,
  });

  DeviceState copyWith({
    DeviceType? type,
    StreamingState? streamingState,
    bool? isAudioPlaying,
    String? errorMessage,
  }) {
    return DeviceState(
      type: type ?? this.type,
      streamingState: streamingState ?? this.streamingState,
      isAudioPlaying: isAudioPlaying ?? this.isAudioPlaying,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class DeviceException implements Exception {
  final DeviceErrorType type;
  final String message;
  final String? technicalDetails;

  DeviceException(this.type, this.message, [this.technicalDetails]);

  @override
  String toString() {
    return 'DeviceException: $message ${technicalDetails != null ? '($technicalDetails)' : ''}';
  }
}

abstract class DeviceInterface {
  // 상태 관리
  Stream<DeviceState> get stateStream;
  DeviceState get currentState;

  // 초기화 및 해제
  Future<void> initialize();
  Future<void> dispose();

  // 오디오 스트리밍
  Future<void> startAudioStream();
  Future<void> stopAudioStream();
  Stream<Uint8List> get audioStream;

  // 사진 캡처
  Future<void> startPhotoCapture(Duration interval);
  Future<void> stopPhotoCapture();
  Stream<Uint8List> get photoStream;

  // 설정
  Future<void> setAudioConfig({
    required int sampleRate,
    required int channelCount,
    required int bitDepth,
  });

  Future<void> setPhotoConfig({
    required int resolution,
    required int quality,
  });
}
