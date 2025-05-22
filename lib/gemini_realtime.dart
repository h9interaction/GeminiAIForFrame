import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'audio_data_extractor.dart';

enum GeminiVoiceName { Puck, Charon, Kore, Fenrir, Aoede }

// 모드 열거형 추가
enum GeminiMode {
  textOnly, // 텍스트만 사용하는 모드
  fullMode // 음성, 이미지, 텍스트 모두 사용하는 모드
}

class GeminiRealtime {
  final _log = Logger("Gem");

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubs;
  bool _connected = false;
  GeminiMode _currentMode = GeminiMode.fullMode; // 현재 모드

  // 트랜스크립션 버퍼 추가
  String _userTranscriptBuffer = '';
  String _aiTranscriptBuffer = '';

  // 발화 상태 추적을 위한 변수
  bool _isSpeaking = false;
  // bool _isProcessingResponse = false;
  Timer? _interruptionProtectionTimer;
  int _interruptionCount = 0;
  static const int MAX_INTERRUPTIONS = 3;
  static const Duration INTERRUPTION_PROTECTION_TIME =
      Duration(milliseconds: 3000); // 응답 시작 후 3초간 인터럽션 무시

  // interestingly, 'response_modalities' seems to allow only "text", "audio", "image" - not a list. Audio only is fine for us
  // Valid voices are: Puck, Charon, Kore, Fenrir, Aoede (Set to Puck, override in connect())
  // system instruction is also not set in the template map (set during connect())
  final Map<String, dynamic> _setupMap = {
    'setup': {
      'model': 'models/gemini-2.0-flash-live-001',
      'generation_config': {
        'response_modalities': 'audio',
        'speech_config': {
          'voice_config': {
            'prebuilt_voice_config': {'voice_name': 'Puck'}
          }
        },
      },
      'system_instruction': {
        'parts': [
          {'text': ''}
        ]
      },
      'output_audio_transcription': {},
      'input_audio_transcription': {},
      'tools': [
        {'googleSearch': {}}
      ]
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

  // 텍스트 입력을 위한 맵 추가
  final Map<String, dynamic> _realtimeTextInputMap = {
    'realtimeInput': {'text': ''}
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

  /// 현재 모드 반환
  GeminiMode getCurrentMode() => _currentMode;

  /// 모드 설정
  void setMode(GeminiMode mode) {
    _currentMode = mode;
    _log.info('Gemini 모드 변경: $mode');
  }

  /// Connect to Gemini Live and set up the websocket connection using the specified API key
  Future<bool> connect(
      String apiKey, GeminiVoiceName voice, String systemInstruction) async {
    // _log.info('Connecting to Gemini');
    _log.info(
        '[Gemini] 연결 시도: API Key, Voice: ${voice.name}, SystemInstruction: $systemInstruction');

    // configure the session with the specified voice and system instruction
    _setupMap['setup']['generation_config']['speech_config']['voice_config']
        ['prebuilt_voice_config']['voice_name'] = voice.name;
    _setupMap['setup']['system_instruction']['parts'][0]['text'] =
        systemInstruction;

    _log.info('[Gemini] 세션 설정 준비 완료: ${_setupMap.toString()}');

    // get the audio playback ready
    _audioBuffer.clear();
    _isSpeaking = false;
    // _isProcessingResponse = false;
    _interruptionCount = 0;
    _interruptionProtectionTimer?.cancel();

    // get a fresh websocket channel each time we start a conversation for now
    await _channel?.sink.close();
    _log.info('[Gemini] WebSocket 채널 연결 시도...');
    _channel = WebSocketChannel.connect(Uri.parse(
        'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=$apiKey'));

    // connection doesn't complete immediately, wait until it's ready
    // TODO check what happens if API key is bad, host is bad etc, how long are the timeouts?
    // and return false if not connected properly (or throw the exception and print the error?)
    await _channel!.ready;
    _log.info('[Gemini] WebSocket 연결 완료');

    // set up stream handler for channel to handle events
    _log.info('[Gemini] WebSocket 스트림 구독 시작');
    _channelSubs = _channel!.stream.listen(_handleGeminiEvent);

    // set up the config for the model/modality
    _log.info('[Gemini] 모델/모달리티 설정 전송: ${_setupMap.toString()}');
    _channel!.sink.add(jsonEncode(_setupMap));

    _connected = true;
    // _log.info('Connected');
    _log.info('[Gemini] 연결 완료 및 준비됨');
    return _connected;
  }

  /// Disconnect from Gemini Live by closing the websocket connection
  Future<void> disconnect() async {
    _log.info('[Gemini] Disconnecting from Gemini');
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
      _log.info('[Gemini] App trying to send audio when disconnected');
      return;
    }

    // 발화 중에는 오디오를 Gemini로 전송하지 않음 (하울링 방지)
    if (_isSpeaking) {
      // _log.fine('[Gemini] SendAudio : 오디오 전송 스킵: AI 말하는 중');
      return;
    }

    // base64 encode
    var base64audio = base64Encode(pcm16x16);

    // set the data into the realtime input map before serializing
    _realtimeAudioInputMap['realtimeInput']['mediaChunks'][0]['data'] =
        base64audio;

    // send data to websocket
    _channel!.sink.add(jsonEncode(_realtimeAudioInputMap));
    // _log.fine('[Gemini] SendAudio ', base64audio);
  }

  /// Send the photo to Gemini, encoded as jpeg
  void sendPhoto(Uint8List jpegBytes) {
    if (!_connected) {
      _log.info(
          '[Gemini] App trying to send a photo when disconnected or in text-only mode');
      return;
    }

    // base64 encode
    var base64image = base64Encode(jpegBytes);

    // set the data into the realtime input map before serializing
    // TODO can't I just cache the last little map and set it there at least?
    _realtimeImageInputMap['realtimeInput']['mediaChunks'][0]['data'] =
        base64image;

    // send data to websocket
    // _log.info('[Gemini] sending photo');
    _channel!.sink.add(jsonEncode(_realtimeImageInputMap));
  }

  /// Send text to Gemini
  void sendText(String text) {
    _log.info('[Gemini] 텍스트 전송 시도: $text');

    if (!_connected) {
      _log.warning('[Gemini] Gemini가 연결되지 않아 텍스트를 전송할 수 없습니다.');
      _log.info('App trying to send text when disconnected');
      return;
    }

    // 발화 중에는 텍스트를 Gemini로 전송하지 않음
    if (_isSpeaking) {
      _log.fine('SendText : 텍스트 전송 스킵: AI 말하는 중');
      return;
    }

    try {
      // set the text into the realtime input map before serializing
      _realtimeTextInputMap['realtimeInput']['text'] = text;
      _log.info('텍스트 데이터 준비 완료: ${_realtimeTextInputMap}');

      // send data to websocket
      _channel!.sink.add(jsonEncode(_realtimeTextInputMap));
      _log.info('텍스트 전송 완료');
    } catch (e) {
      _log.severe('텍스트 전송 중 오류 발생: $e');
      _log.info('텍스트 전송 실패: $e');
    }
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
      if (_isSpeaking && _audioBuffer.isEmpty) {
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
        _log.info('AI 응답 시작');
        // AI 응답 시작 시 사용자 트랜스크립션 출력
        if (_userTranscriptBuffer.isNotEmpty) {
          eventLogger('사용자 : $_userTranscriptBuffer');
          _userTranscriptBuffer = '';
        }
        // 발화 시작 시 인터럽션 보호 타이머 시작
        _interruptionProtectionTimer?.cancel();
        _interruptionProtectionTimer = Timer(INTERRUPTION_PROTECTION_TIME, () {
          _log.info('초기 응답 보호 기간 종료');
        });
      } else {
        _log.info('AI 응답 종료');
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
  FutureOr<void> _handleGeminiEvent(dynamic eventJson) async {
    String eventString = utf8.decode(eventJson);
    // _log.info('Gemini 이벤트 수신: $eventString');

    // parse the json
    var event = jsonDecode(eventString);
    // _log.info('이벤트 파싱 완료: ${event.toString()}');

    // try audio message types first
    var audioData = AudioDataExtractor.extractAudioData(event);

    if (audioData != null) {
      // _log.info('오디오 데이터 수신: ${audioData.length} 청크');
      // 오디오 데이터가 있으면 발화 중으로 설정
      if (!_isSpeaking && audioData.isNotEmpty) {
        _setSpeakingState(true);
      }

      for (var chunk in audioData) {
        _audioBuffer.add(chunk);
        // _log.fine('오디오 청크 추가: ${chunk.length} 바이트');

        // notify the main app in case playback had stopped, it should start again
        audioReadyCallback();
      }
    } else {
      // some other kind of event
      var serverContent = event['serverContent'];
      if (serverContent != null) {
        // _log.info('[Gemini] 서버 컨텐츠 수신: ${serverContent.toString()}');

        // 사용자 트랜스크립션 처리
        if (serverContent['inputTranscription'] != null) {
          var text = serverContent['inputTranscription']['text'] ?? '';
          _userTranscriptBuffer += text;
          _log.info('[대화] 사용자 : $_userTranscriptBuffer');
        }

        // AI 트랜스크립션 처리
        if (serverContent['outputTranscription'] != null) {
          var text = serverContent['outputTranscription']['text'] ?? '';
          _aiTranscriptBuffer += text;
          _log.info('[대화] AI : $_aiTranscriptBuffer');
        }

        // AI 응답 생성 완료 처리
        if (serverContent['generationComplete'] == true) {
          _log.info('[Gemini] AI 응답 생성 완료');
          if (_aiTranscriptBuffer.isNotEmpty) {
            eventLogger('AI : $_aiTranscriptBuffer');
            _aiTranscriptBuffer = '';
          }
        }

        if (serverContent['interrupted'] != null) {
          // 인터럽션 처리
          _interruptionCount++;
          _log.info('[Gemini] 인터럽션 발생: ${_interruptionCount}번째');
          if (_aiTranscriptBuffer.isNotEmpty) {
            eventLogger('AI : $_aiTranscriptBuffer');
          }
          _aiTranscriptBuffer = '';

          if (_userTranscriptBuffer.isNotEmpty) {
            eventLogger('사용자 : $_userTranscriptBuffer');
          }
          _userTranscriptBuffer = '';

          if (_interruptionCount > MAX_INTERRUPTIONS) {
            _log.info('[Gemini] 최대 인터럽션 횟수 초과: 무시 ($MAX_INTERRUPTIONS)');
            return;
          }

          _audioBuffer.clear();
          _log.info('[Gemini] ---Interruption--- (${_interruptionCount}번째)');
          _log.fine('[Gemini] Response interrupted by user');
          _setSpeakingState(false);
        } else if (serverContent['turnComplete'] != null) {
          _log.info('[Gemini] 서버 턴 완료');
          _log.info('[Gemini] Server turn complete');

          if (_aiTranscriptBuffer.isNotEmpty) {
            eventLogger('AI : $_aiTranscriptBuffer');
          }
          _aiTranscriptBuffer = '';

          if (_isSpeaking) {
            _setSpeakingState(false);
          }
        } else {
          // _log.info('[Gemini] 기타 서버 컨텐츠: ${serverContent.toString()}');
          _log.info(serverContent);
        }
      } else if (event['setupComplete'] != null) {
        _log.info('[Gemini] 설정 완료');
        _log.info('[Gemini] Setup is complete');
      } else {
        _log.info('[Gemini] 알 수 없는 서버 메시지: $eventString');
        _log.info(eventString);
      }
    }
  }
}
