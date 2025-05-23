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
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';

class MobileDevice implements DeviceInterface {
  final _log = Logger('MobileDevice');

  // 스트림 컨트롤러들
  final _stateController = StreamController<DeviceState>.broadcast();
  final _audioStreamController = StreamController<Uint8List>.broadcast();
  final _photoStreamController = StreamController<Uint8List>.broadcast();
  final _previewController = StreamController<Widget>.broadcast();
  Widget? _lastPreviewWidget;

  CameraImage? _latestCameraImage;

  // 상태 변수들
  DeviceState _currentState;
  Timer? _photoTimer;
  bool _isCapturing = false;
  bool _isConverting = false;

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
      final permissionsGranted = await _checkPermissions();
      if (!permissionsGranted) {
        _log.info('필요한 권한이 없습니다. 설정 패널에서 권한을 요청해 주세요.');
        return;
      }

      // 기존 리소스 정리
      await _cleanupResources();

      // 상태 초기화
      _resetState();

      // 디바이스 타입에 따른 초기화
      if (_currentState.type == DeviceType.mobile) {
        await _initializeMobileDevice();
      }

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
    _cameraController?.removeListener(_updatePreviewWidget);
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
          sampleRate: 16000,
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
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      _log.warning('카메라가 초기화되지 않았습니다.');
      return;
    }

    _isCapturing = true;
    _photoTimer?.cancel();
    _photoTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!_isCapturing || _latestCameraImage == null || _isConverting) return;
      _isConverting = true;
      try {
        final imageData = _extractImageData(_latestCameraImage!);
        final jpeg = await compute(_yuv420MapToJpeg, imageData);
        _photoStreamController.add(jpeg);
      } catch (e) {
        _log.warning('사진 변환 오류: $e');
      } finally {
        _isConverting = false;
      }
    });

    _log.info('Photo capture via image stream every 1000 ms');
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

  // 리소스 정리 메서드 추가
  Future<void> _cleanupResources() async {
    try {
      await _cameraController?.stopImageStream();
      await _cameraController?.dispose();
      _cameraController = null;

      await _audioRecorder.dispose();

      _photoTimer?.cancel();
      _photoTimer = null;

      _isCapturing = false;

      _log.info('기존 리소스 정리 완료');
    } catch (e) {
      _log.warning('리소스 정리 중 오류 발생: $e');
    }
  }

  // 프리뷰 위젯 업데이트 메서드 추가
  void _updatePreviewWidget() {
    if (_cameraController != null &&
        _cameraController!.value.isInitialized &&
        !_cameraController!.value.isRecordingVideo) {
      final preview = ClipRect(
        child: Transform.scale(
          scale: 1.0,
          child: Center(
            child: AspectRatio(
              aspectRatio: 1 / _cameraController!.value.aspectRatio,
              child: CameraPreview(_cameraController!),
            ),
          ),
        ),
      );
      if (!identical(preview, _lastPreviewWidget)) {
        _lastPreviewWidget = preview;
        _previewController.add(preview);
      }
    }
  }

  /// 보유 중인 프리뷰 위젯을 다시 스트림에 넣어
  /// 새 구독자도 즉시 볼 수 있게 한다.
  void refreshPreview() {
    if (_lastPreviewWidget != null) {
      _previewController.add(_lastPreviewWidget!);
    }
  }

  void _resetState() {
    // Implementation of _resetState method
  }

  Future<bool> _checkPermissions() async {
    final micStatus = await Permission.microphone.status;
    final cameraStatus = await Permission.camera.status;

    bool micGranted = micStatus.isGranted;
    bool cameraGranted = cameraStatus.isGranted;

    if (!micGranted) {
      micGranted = (await Permission.microphone.request()).isGranted;
    }
    if (!cameraGranted) {
      cameraGranted = (await Permission.camera.request()).isGranted;
    }

    return micGranted && cameraGranted;
  }

  Future<void> _initializeMobileDevice() async {
    // 카메라 리스트 가져오기
    _cameras = await availableCameras();
    if (_cameras == null || _cameras!.isEmpty) {
      throw DeviceException(
        DeviceErrorType.streamError,
        '카메라를 찾을 수 없습니다.',
        '',
      );
    }

    // 후면 카메라(없으면 첫 번째 카메라) 선택
    final CameraDescription camera = _cameras!.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => _cameras!.first,
    );

    // 카메라 컨트롤러 생성
    _cameraController = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    // 컨트롤러 초기화
    await _cameraController!.initialize();

    // 플래시 항상 끔
    await _cameraController!.setFlashMode(FlashMode.off);

    // 프리뷰 업데이트 리스너 등록
    _cameraController!.addListener(_updatePreviewWidget);
    _updatePreviewWidget();

    // 이미지 스트림 시작 – 프리뷰 부드럽게 유지
    await _cameraController!.startImageStream((CameraImage img) {
      _latestCameraImage = img;
    });
  }

  Map<String, dynamic> _extractImageData(CameraImage image) {
    return {
      'width': image.width,
      'height': image.height,
      'plane0': image.planes[0].bytes,
      'plane1': image.planes[1].bytes,
      'plane2': image.planes[2].bytes,
      'plane1RowStride': image.planes[1].bytesPerRow,
      'plane1PixelStride': image.planes[1].bytesPerPixel ?? 1,
    };
  }

  static Future<Uint8List> _yuv420MapToJpeg(Map<String, dynamic> data) async {
    final w = data['width'] as int;
    final h = data['height'] as int;
    final y = data['plane0'] as Uint8List;
    final u = data['plane1'] as Uint8List;
    final v = data['plane2'] as Uint8List;
    final uvRowStride = data['plane1RowStride'] as int;
    final uvPixStride = data['plane1PixelStride'] as int;

    final img.Image rgb = img.Image(width: w, height: h);

    for (int yy = 0; yy < h; yy++) {
      final uvRow = uvRowStride * (yy >> 1);
      for (int xx = 0; xx < w; xx++) {
        final yp = yy * w + xx;
        final up = uvRow + (xx >> 1) * uvPixStride;
        final vp = up;
        final yVal = y[yp];
        final uVal = u[up];
        final vVal = v[vp];

        int r = (yVal + 1.370705 * (vVal - 128)).clamp(0, 255).toInt();
        int g = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128))
            .clamp(0, 255)
            .toInt();
        int b = (yVal + 1.732446 * (uVal - 128)).clamp(0, 255).toInt();

        rgb.setPixelRgb(xx, yy, r, g, b);
      }
    }
    final img.Image resized = img.copyResize(rgb, width: 640);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 50));
  }
}
