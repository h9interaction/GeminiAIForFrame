import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'audio_data_extractor.dart';

enum GeminiVoiceName { Puck, Charon, Kore, Fenrir, Aoede }

class GeminiRealtime {
  final _log = Logger("Gem");

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubs;
  bool _connected = false;

  // 발화 상태 추적을 위한 변수
  bool _isSpeaking = false;
  // bool _isProcessingResponse = false;
  Timer? _interruptionProtectionTimer;
  int _interruptionCount = 0;
  static const int MAX_INTERRUPTIONS = 3;
  static const Duration INTERRUPTION_PROTECTION_TIME =
      Duration(milliseconds: 1000); // 응답 시작 후 3초간 인터럽션 무시

  // interestingly, 'response_modalities' seems to allow only "text", "audio", "image" - not a list. Audio only is fine for us
  // Valid voices are: Puck, Charon, Kore, Fenrir, Aoede (Set to Puck, override in connect())
  // system instruction is also not set in the template map (set during connect())
  final Map<String, dynamic> _setupMap = {
    'setup': {
      'model': 'models/gemini-2.0-flash-exp',
      'generation_config': {
        'response_modalities': 'audio',
        'speech_config': {
          'voice_config': {
            'prebuilt_voice_config': {'voice_name': 'Puck'}
          }
        }
      },
      'system_instruction': {
        'parts': [
          {'text': ''}
        ]
      }
    }
  };
  final Map<String, dynamic> _realtimeAudioInputMap = {
    'realtimeInput': {
      'mediaChunks': [
        {'mimeType': 'audio/pcm;rate=16000', 'data': ''}
      ]
    }
  };
  final Map<String, dynamic> _realtimeImageInputMap = {
    'realtimeInput': {
      'mediaChunks': [
        {'mimeType': 'image/jpeg', 'data': ''}
      ]
    }
  };

  // audio buffer
  final _audioBuffer = ListQueue<Uint8List>();

  // a handle on the main app's event logger (in the UI)
  final Function(String) eventLogger;

  // a callback to notify the main app that some audio is ready for playback
  final Function() audioReadyCallback;

  /// Constructor just registers callbacks for audio ready and log messages
  GeminiRealtime(this.audioReadyCallback, this.eventLogger);

  /// Returns the current state of the Gemini connection
  bool isConnected() => _connected;

  /// 현재 발화 중인지 여부 반환
  bool isSpeaking() => _isSpeaking;

  /// Connect to Gemini Live and set up the websocket connection using the specified API key
  Future<bool> connect(
      String apiKey, GeminiVoiceName voice, String systemInstruction) async {
    eventLogger('Connecting to Gemini');
    _log.info('Connecting to Gemini');

    // configure the session with the specified voice and system instruction
    _setupMap['setup']['generation_config']['speech_config']['voice_config']
        ['prebuilt_voice_config']['voice_name'] = voice.name;
    _setupMap['setup']['system_instruction']['parts'][0]['text'] =
        systemInstruction;

    // get the audio playback ready
    _audioBuffer.clear();
    _isSpeaking = false;
    // _isProcessingResponse = false;
    _interruptionCount = 0;
    _interruptionProtectionTimer?.cancel();

    // get a fresh websocket channel each time we start a conversation for now
    await _channel?.sink.close();
    _channel = WebSocketChannel.connect(Uri.parse(
        'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=$apiKey'));

    // connection doesn't complete immediately, wait until it's ready
    // TODO check what happens if API key is bad, host is bad etc, how long are the timeouts?
    // and return false if not connected properly (or throw the exception and print the error?)
    await _channel!.ready;

    // set up stream handler for channel to handle events
    _channelSubs = _channel!.stream.listen(_handleGeminiEvent);

    // set up the config for the model/modality
    _log.info(_setupMap);
    _channel!.sink.add(jsonEncode(_setupMap));

    _connected = true;
    eventLogger('Connected');
    return _connected;
  }

  /// Disconnect from Gemini Live by closing the websocket connection
  Future<void> disconnect() async {
    eventLogger('Disconnecting from Gemini');
    _log.info('Disconnecting from Gemini');
    _connected = false;
    _isSpeaking = false;
    // _isProcessingResponse = false;
    _interruptionProtectionTimer?.cancel();
    await _channelSubs?.cancel();
    await _channel?.sink.close();
  }

  /// Sends the audio to Gemini - bytes should be provided as PCM16 samples at 16kHz
  void sendAudio(Uint8List pcm16x16) {
    if (!_connected) {
      eventLogger('App trying to send audio when disconnected');
      return;
    }

    // 발화 중에는 오디오를 Gemini로 전송하지 않음 (하울링 방지)
    // if (_isSpeaking) {
    //   // 디버그 용도로만 로깅하고 전송은 중단
    //   _log.fine('오디오 전송 스킵: AI 응답 중');
    //   return;
    // }

    // base64 encode
    var base64audio = base64Encode(pcm16x16);

    // set the data into the realtime input map before serializing
    // TODO can't I just cache the last little map and set it there at least?
    _realtimeAudioInputMap['realtimeInput']['mediaChunks'][0]['data'] =
        base64audio;

    // send data to websocket
    _channel!.sink.add(jsonEncode(_realtimeAudioInputMap));
  }

  /// Send the photo to Gemini, encoded as jpeg
  void sendPhoto(Uint8List jpegBytes) {
    if (!_connected) {
      eventLogger('App trying to send a photo when disconnected');
      return;
    }

    // base64 encode
    var base64image = base64Encode(jpegBytes);

    // set the data into the realtime input map before serializing
    // TODO can't I just cache the last little map and set it there at least?
    _realtimeImageInputMap['realtimeInput']['mediaChunks'][0]['data'] =
        base64image;

    // send data to websocket
    _log.info('sending photo');
    _channel!.sink.add(jsonEncode(_realtimeImageInputMap));
  }

  /// If there is any audio that has been received from Gemini, ready for playback
  bool hasResponseAudio() {
    return _audioBuffer.isNotEmpty;
  }

  /// Returns PCM16 24kHz samples as ByteData (interpret as PCM16)
  ByteData getResponseAudioByteData() {
    if (hasResponseAudio()) {
      return (_audioBuffer.removeFirst()).buffer.asByteData();
    } else {
      // 오디오 버퍼가 비었을 때, 발화 종료로 간주할 수 있음
      if (_audioBuffer.isEmpty) {
        _setSpeakingState(false);
      }
      return ByteData(0);
    }
  }

  /// 발화 상태 변경 처리
  void _setSpeakingState(bool speaking) {
    if (_isSpeaking != speaking) {
      _isSpeaking = speaking;
      _log.info('Gemini 발화 상태 변경: $speaking');

      if (speaking) {
        eventLogger('AI 응답 시작');
        // 발화 시작 시 인터럽션 보호 타이머 시작
        // _isProcessingResponse = true;
        _interruptionProtectionTimer?.cancel();
        _interruptionProtectionTimer = Timer(INTERRUPTION_PROTECTION_TIME, () {
          // _isProcessingResponse = false;
          _log.info('초기 응답 보호 기간 종료');
        });
      } else {
        eventLogger('AI 응답 종료');
        // _isProcessingResponse = false;
        _interruptionProtectionTimer?.cancel();
      }
    }
  }

  /// Clears the audio buffer so the main app can't pull any more samples
  void stopResponseAudio() {
    // by clearing the buffered PCM data, the player will stop being fed audio
    _audioBuffer.clear();
    _setSpeakingState(false);
  }

  /// handle the Gemini server events that come through the websocket
  /// TODO work out how the closed/session time is up message comes back - maybe just the socket status subscription?
  FutureOr<void> _handleGeminiEvent(dynamic eventJson) async {
    String eventString = utf8.decode(eventJson);

    // parse the json
    var event = jsonDecode(eventString);

    // try audio message types first
    var audioData = AudioDataExtractor.extractAudioData(event);

    if (audioData != null) {
      // 오디오 데이터가 있으면 발화 중으로 설정
      if (audioData.isNotEmpty) {
        _setSpeakingState(true);
      }

      for (var chunk in audioData) {
        _audioBuffer.add(chunk);

        // notify the main app in case playback had stopped, it should start again
        audioReadyCallback();
      }
    } else {
      // some other kind of event
      var serverContent = event['serverContent'];
      if (serverContent != null) {
        if (serverContent['interrupted'] != null) {
          // 응답 초기 단계에서는 인터럽션 이벤트 무시
          // if (_isProcessingResponse) {
          //   _log.info('초기 응답 단계에서 인터럽션 이벤트 무시됨');
          //   return;
          // }

          // 인터럽션 횟수 증가 및 제한 확인
          _interruptionCount++;

          if (_interruptionCount > MAX_INTERRUPTIONS) {
            _log.info('최대 인터럽션 횟수 초과: 무시 ($MAX_INTERRUPTIONS)');
            return;
          }

          // process interruption to stop audio
          _audioBuffer.clear();
          eventLogger('---Interruption--- (${_interruptionCount}번째)');
          _log.fine('Response interrupted by user');
          _setSpeakingState(false);

          // TODO communicate interruption playback point back to server?
        } else if (serverContent['turnComplete'] != null) {
          // server has finished sending
          eventLogger('Server turn complete');

          // 발화 종료 처리
          // if (_isSpeaking) {
          //   _setSpeakingState(false);
          // }
        } else {
          eventLogger(serverContent);
        }
      } else if (event['setupComplete'] != null) {
        eventLogger('Setup is complete');
        _log.info('Gemini setup is complete');
      } else {
        // unknown server message
        _log.info(eventString);
        eventLogger(eventString);
      }
    }
  }
}
