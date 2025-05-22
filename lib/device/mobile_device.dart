import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:record/record.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/material.dart';
import 'device_interface.dart';

class MobileDevice implements DeviceInterface {
  final _log = Logger('MobileDevice');

  // 스트림 컨트롤러들
  final _stateController = StreamController<DeviceState>.broadcast();
  final _audioStreamController = StreamController<Uint8List>.broadcast();
  final _photoStreamController = StreamController<Uint8List>.broadcast();
  final _previewController = StreamController<Widget>.broadcast();

  // 상태 변수들
  DeviceState _currentState;
  Timer? _photoTimer;
  bool _isCapturing = false;

  // 카메라/오디오 관련 변수들
  CameraController? _cameraController;
  final _audioRecorder = AudioRecorder();
  List<CameraDescription>? _cameras;
  StreamSubscription? _audioStreamSubscription;

  // 설정값들
  int _sampleRate = 8000;
  int _channelCount = 1;
  int _bitDepth = 16;
  int _resolution = 720;
  int _quality = 75; // 0-100 for JPEG quality

  MobileDevice()
      : _currentState = DeviceState(
          type: DeviceType.mobile,
          streamingState: StreamingState.idle,
          isAudioPlaying: false,
        ) {}

  @override
  Stream<DeviceState> get stateStream => _stateController.stream;

  @override
  DeviceState get currentState => _currentState;

  @override
  Stream<Uint8List> get audioStream => _audioStreamController.stream;

  @override
  Stream<Uint8List> get photoStream => _photoStreamController.stream;

  // 카메라 프리뷰 스트림 추가
  Stream<Widget> get previewStream => _previewController.stream;

  @override
  Future<void> initialize() async {
    try {
      _updateState(streamingState: StreamingState.preparing);

      // 권한 상태 확인
      final cameraStatus = await Permission.camera.status;
      final microphoneStatus = await Permission.microphone.status;

      // 권한이 없는 경우에만 요청
      if (!cameraStatus.isGranted) {
        final cameraResult = await Permission.camera.request();
        if (cameraResult != PermissionStatus.granted) {
          throw DeviceException(
            DeviceErrorType.permissionDenied,
            '카메라 권한이 거부되었습니다.',
          );
        }
      }

      if (!microphoneStatus.isGranted) {
        final microphoneResult = await Permission.microphone.request();
        if (microphoneResult != PermissionStatus.granted) {
          throw DeviceException(
            DeviceErrorType.permissionDenied,
            '마이크 권한이 거부되었습니다.',
          );
        }
      }

      // 카메라 초기화 시도
      try {
        _cameras = await availableCameras();
        if (_cameras!.isEmpty) {
          _log.warning('사용 가능한 카메라가 없습니다. 카메라 없이 계속 진행합니다.');
        } else {
          // 후면 카메라 선택 (없으면 첫 번째 카메라)
          final camera = _cameras!.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
            orElse: () => _cameras!.first,
          );

          _cameraController = CameraController(
            camera,
            ResolutionPreset.medium, // 720p
            enableAudio: false,
            imageFormatGroup: ImageFormatGroup.jpeg,
          );

          await _cameraController!.initialize();

          // 자동 플래시 비활성화
          await _cameraController!.setFlashMode(FlashMode.off);

          // 카메라 프리뷰 위젯 생성 및 스트림에 추가
          _previewController.add(
            ClipRect(
              child: Transform.scale(
                scale: 1.0,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1 / _cameraController!.value.aspectRatio,
                    child: CameraPreview(_cameraController!),
                  ),
                ),
              ),
            ),
          );

          // 카메라 프리뷰 자동 업데이트 시작
          _cameraController!.startImageStream((image) {
            if (_previewController.hasListener) {
              _previewController.add(
                ClipRect(
                  child: Transform.scale(
                    scale: 1.0,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1 / _cameraController!.value.aspectRatio,
                        child: CameraPreview(_cameraController!),
                      ),
                    ),
                  ),
                ),
              );
            }
          });

          _log.info('카메라 초기화 완료');
        }
      } catch (e) {
        _log.warning('카메라 초기화 실패: $e');
        // 카메라 초기화 실패해도 계속 진행
      }

      // 오디오 레코더 초기화 및 권한 확인
      if (!await _audioRecorder.hasPermission()) {
        throw DeviceException(
          DeviceErrorType.permissionDenied,
          '마이크 권한이 없습니다.',
        );
      }

      _updateState(streamingState: StreamingState.idle);
      _log.info('Mobile device initialized');
    } catch (e) {
      _handleError(e);
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    _isCapturing = false;
    await stopAudioStream();
    await stopPhotoCapture();
    await _cameraController?.stopImageStream();
    await _cameraController?.dispose();
    await _audioRecorder.dispose();
    await _stateController.close();
    await _audioStreamController.close();
    await _photoStreamController.close();
    await _previewController.close();
    _log.info('Mobile device disposed');
  }

  @override
  Future<void> startAudioStream() async {
    try {
      if (_currentState.streamingState == StreamingState.streaming) {
        return;
      }

      _updateState(streamingState: StreamingState.preparing);

      // 오디오 스트림 시작
      final stream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: 8000,
        ),
      );

      _audioStreamSubscription = stream.listen(
        (data) {
          _audioStreamController.add(data);
        },
        onError: _handleError,
      );

      _updateState(streamingState: StreamingState.streaming);
      _log.info('Audio streaming started');
    } catch (e) {
      _handleError(e);
      rethrow;
    }
  }

  @override
  Future<void> stopAudioStream() async {
    try {
      await _audioStreamSubscription?.cancel();
      await _audioRecorder.stop();
      _updateState(streamingState: StreamingState.idle);
      _log.info('Audio streaming stopped');
    } catch (e) {
      _handleError(e);
      rethrow;
    }
  }

  @override
  Future<void> startPhotoCapture(Duration interval) async {
    try {
      if (_cameraController == null ||
          !_cameraController!.value.isInitialized) {
        _log.warning('카메라가 초기화되지 않았습니다.');
        return;
      }

      _isCapturing = true;
      _photoTimer?.cancel();
      _photoTimer = Timer.periodic(interval, (_) async {
        try {
          if (_cameraController!.value.isInitialized && _isCapturing) {
            final xFile = await _cameraController!.takePicture();
            final bytes = await xFile.readAsBytes();
            _photoStreamController.add(bytes);
          }
        } catch (e) {
          _log.warning('사진 촬영 중 오류 발생: $e');
        }
      });

      _log.info('Photo capture started with interval: ${interval.inSeconds}s');
    } catch (e) {
      _handleError(e);
      rethrow;
    }
  }

  @override
  Future<void> stopPhotoCapture() async {
    _isCapturing = false;
    _photoTimer?.cancel();
    _photoTimer = null;
    _log.info('Photo capture stopped');
  }

  @override
  Future<void> setAudioConfig({
    required int sampleRate,
    required int channelCount,
    required int bitDepth,
  }) async {
    _sampleRate = sampleRate;
    _channelCount = channelCount;
    _bitDepth = bitDepth;
    _log.info('Audio config updated');
  }

  @override
  Future<void> setPhotoConfig({
    required int resolution,
    required int quality,
  }) async {
    _resolution = resolution;
    _quality = quality;
    _log.info('Photo config updated');
  }

  void _updateState({
    DeviceType? type,
    StreamingState? streamingState,
    bool? isAudioPlaying,
    String? errorMessage,
  }) {
    _currentState = _currentState.copyWith(
      type: type,
      streamingState: streamingState,
      isAudioPlaying: isAudioPlaying,
      errorMessage: errorMessage,
    );
    _stateController.add(_currentState);
  }

  void _handleError(dynamic error) {
    final deviceError = (error is DeviceException)
        ? error
        : DeviceException(
            DeviceErrorType.streamError,
            'An unexpected error occurred',
            error.toString(),
          );

    _log.severe('Error: ${deviceError.message}', error);
    _updateState(
      streamingState: StreamingState.error,
      errorMessage: deviceError.message,
    );
  }
}
