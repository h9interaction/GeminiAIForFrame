import 'dart:async';
import 'dart:typed_data';
import 'package:frame_msg/rx/audio.dart';
import 'package:frame_msg/rx/photo.dart';
import 'package:frame_msg/tx/capture_settings.dart';
import 'package:frame_msg/tx/code.dart';
import 'package:frame_msg/tx/plain_text.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'device_interface.dart';

class FrameDevice implements DeviceInterface {
  final _log = Logger('FrameDevice');
  final SimpleFrameAppState frameState;

  // 스트림 컨트롤러들
  final _stateController = StreamController<DeviceState>.broadcast();
  final _audioStreamController = StreamController<Uint8List>.broadcast();
  final _photoStreamController = StreamController<Uint8List>.broadcast();

  // 상태 변수들
  DeviceState _currentState;
  Timer? _photoTimer;
  StreamSubscription? _audioSubscription;
  StreamSubscription? _photoSubscription;

  // 설정값들
  int _sampleRate = 8000;
  int _channelCount = 1;
  int _bitDepth = 16;
  int _resolution = 720;
  int _quality = 4;

  FrameDevice(this.frameState)
      : _currentState = DeviceState(
          type: DeviceType.frame,
          streamingState: StreamingState.idle,
          isAudioPlaying: false,
        );

  @override
  Stream<DeviceState> get stateStream => _stateController.stream;

  @override
  DeviceState get currentState => _currentState;

  @override
  Stream<Uint8List> get audioStream => _audioStreamController.stream;

  @override
  Stream<Uint8List> get photoStream => _photoStreamController.stream;

  @override
  Future<void> initialize() async {
    try {
      if (frameState.frame == null) {
        throw DeviceException(
          DeviceErrorType.hardwareError,
          'Frame device is not connected',
        );
      }

      // Frame 글래스 연결 상태 확인을 위해 간단한 메시지 전송 시도
      try {
        await frameState.frame!
            .sendMessage(0x0b, TxPlainText(text: ' ').pack());
      } catch (e) {
        throw DeviceException(
          DeviceErrorType.hardwareError,
          'Frame device is not properly connected',
        );
      }

      _updateState(streamingState: StreamingState.idle);
      _log.info('Frame device initialized');
    } catch (e) {
      _handleError(e);
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    await stopAudioStream();
    await stopPhotoCapture();
    await _stateController.close();
    await _audioStreamController.close();
    await _photoStreamController.close();
    _log.info('Frame device disposed');
  }

  @override
  Future<void> startAudioStream() async {
    try {
      if (_currentState.streamingState == StreamingState.streaming) {
        return;
      }

      _updateState(streamingState: StreamingState.preparing);

      final rxAudio = RxAudio(streaming: true);
      final audioStream = rxAudio.attach(frameState.frame!.dataResponse);

      _audioSubscription = audioStream.listen(
        (data) => _audioStreamController.add(data),
        onError: _handleError,
      );

      await frameState.frame!.sendMessage(0x30, TxCode(value: 1).pack());
      await frameState.frame!
          .sendMessage(0x0b, TxPlainText(text: 'AI Listening...').pack());

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
      await _audioSubscription?.cancel();
      _audioSubscription = null;

      if (frameState.frame != null) {
        await frameState.frame!.sendMessage(0x30, TxCode(value: 0).pack());
      }

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
      final rxPhoto = RxPhoto(
        quality: 'VERY_HIGH',
        resolution: _resolution,
      );

      _photoTimer?.cancel();
      _photoTimer = Timer.periodic(interval, (_) async {
        try {
          final photoStream = rxPhoto.attach(frameState.frame!.dataResponse);
          _photoSubscription?.cancel();

          _photoSubscription = photoStream.listen(
            (data) => _photoStreamController.add(data),
            onError: _handleError,
          );

          await frameState.frame!.sendMessage(
            0x0d,
            TxCaptureSettings(
              resolution: _resolution,
              qualityIndex: _quality,
            ).pack(),
          );
        } catch (e) {
          _handleError(e);
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
    _photoTimer?.cancel();
    _photoTimer = null;
    await _photoSubscription?.cancel();
    _photoSubscription = null;
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
