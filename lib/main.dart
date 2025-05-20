import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:frame_realtime_gemini_voicevision/api_key_manager.dart';
import 'package:frame_realtime_gemini_voicevision/audio_upsampler.dart';
import 'package:frame_realtime_gemini_voicevision/gemini_realtime.dart';
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:frame_msg/rx/audio.dart';
import 'package:frame_msg/rx/photo.dart';
import 'package:frame_msg/rx/tap.dart';
import 'package:frame_msg/tx/capture_settings.dart';
import 'package:frame_msg/tx/code.dart';
import 'package:frame_msg/tx/plain_text.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'foreground_service.dart';

void main() async {
  // 위젯 바인딩 초기화
  WidgetsFlutterBinding.ensureInitialized();

  // 프레임 렌더링 성능 최적화
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // 프레임 렌더링 모드 설정
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // apikey.env 파일에서 API 키 로드 시도
  String? apiKeyFromEnvFile = await ApiKeyManager.loadApiKeyFromEnvFile();
  if (apiKeyFromEnvFile != null && apiKeyFromEnvFile.isNotEmpty) {
    debugPrint('apikey.env 파일에서 API 키가 성공적으로 로드되었습니다.');
  }

  // Set up Android foreground service
  initializeForegroundService();

  // quieten FBP logs
  fbp.FlutterBluePlus.setLogLevel(fbp.LogLevel.info);

  runApp(const MainApp());
}

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

/// SimpleFrameAppState mixin helps to manage the lifecycle of the Frame connection outside of this file
class MainAppState extends State<MainApp> with SimpleFrameAppState {
  /// realtime voice application members
  late final GeminiRealtime _gemini;
  GeminiVoiceName _voiceName = GeminiVoiceName.Puck;

  // status of audio output with FlutterPCMSound
  bool _playingAudio = false;

  // true when audio/photos are being streamed from Frame
  bool _streaming = false;

  // tap subscription
  StreamSubscription<int>? _tapSubs;

  // Audio: 8kHz 16-bit linear PCM from Frame mic (only the high 10 bits iirc)
  final RxAudio _rxAudio = RxAudio(streaming: true);
  StreamSubscription<Uint8List>? _frameAudioSubs;
  Stream<Uint8List>? _frameAudioSampleStream;

  // Photos: 720px VERY_HIGH quality JPEGs
  static const resolution = 720;
  static const qualityIndex = 4;
  static const qualityLevel = 'VERY_HIGH';
  final RxPhoto _rxPhoto =
      RxPhoto(quality: qualityLevel, resolution: resolution);
  StreamSubscription<Uint8List>? _photoSubs;
  Stream<Uint8List>? _photoStream;
  static const int photoInterval = 3;
  Timer? _photoTimer;
  Image? _image;

  // UI display
  final _apiKeyController = TextEditingController();
  final _systemInstructionController = TextEditingController();
  final List<String> _eventLog = List.empty(growable: true);
  final _eventLogController = ScrollController();
  static const _textStyle = TextStyle(fontSize: 20);
  String? _errorMsg;
  bool _isSettingsExpanded = true; // 설정 섹션 확장/축소 상태

  // 디버깅 패널 관련 변수
  bool _isDebugPanelVisible = false;
  final List<String> _debugLog = List.empty(growable: true);
  final _debugLogController = ScrollController();
  static const _debugTextStyle =
      TextStyle(fontSize: 14, fontFamily: 'monospace');

  MainAppState() {
    // filter logging
    hierarchicalLoggingEnabled = true;
    Logger.root.level = Level.FINE;
    Logger('Bluetooth').level = Level.FINE;
    Logger('RxPhoto').level = Level.FINE;
    Logger('RxAudio').level = Level.FINE;
    Logger('RxTap').level = Level.FINE;

    Logger.root.onRecord.listen((record) {
      debugPrint(
          '${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });

    // Pass the "audio ready" and UI logger callbacks to GeminiRealtime class
    // so audio will play and events can be displayed
    _gemini = GeminiRealtime(_audioReadyCallback, _appendEvent);
  }

  @override
  void initState() {
    super.initState();

    // 프레임 렌더링 성능 최적화
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _asyncInit();
  }

  Future<void> _asyncInit() async {
    // load up the saved text field data
    await _loadPrefs();

    // Initialize the audio playback framework
    // (Gemini sends response audio as mono pcm16 24kHz)
    const sampleRate = 24000;
    FlutterPcmSound.setLogLevel(LogLevel.error);
    try {
      await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
      _addDebugLog('Audio setup successful: $sampleRate Hz, 1 channel');
      // 버퍼 크기를 더 작게 조정하여 더 자주 피드하도록 함
      FlutterPcmSound.setFeedThreshold(sampleRate ~/ 30);
      FlutterPcmSound.setFeedCallback(_onFeed);
    } catch (e) {
      _addDebugLog('Error setting up audio: $e');
    }

    // then kick off the connection to Frame and start the app if possible, unawaited
    tryScanAndConnectAndStart(andRun: true);
  }

  /// Feed the audio player with samples if we have some more, but don't send
  /// too much to the player because we want to be able to interrupt quickly
  /// If we don't feed the player and it stops, we won't get called again so we need to kick it off again
  void _onFeed(int remainingFrames) async {
    // remainingFrames 임계값을 더 낮게 설정하여 더 자주 피드하도록 함
    if (remainingFrames < 1000) {
      if (_gemini.hasResponseAudio()) {
        final audioData = _gemini.getResponseAudioByteData();
        _addDebugLog(
            'Feeding audio data: ${audioData.lengthInBytes} bytes, remaining frames: $remainingFrames');
        try {
          await FlutterPcmSound.feed(PcmArrayInt16(bytes: audioData));
          _addDebugLog('Audio feed successful');
        } catch (e) {
          _addDebugLog('Error feeding audio: $e');
          // 오류 발생 시 오디오 재시작 시도
          try {
            FlutterPcmSound.release();
            await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
            FlutterPcmSound.start();
            _addDebugLog('Audio playback restarted after error');
          } catch (restartError) {
            _addDebugLog('Failed to restart audio: $restartError');
          }
        }
      } else {
        _log.fine('Response audio ended');
        _addDebugLog('Response audio ended');
        _playingAudio = false;
      }
    }
  }

  @override
  Future<void> dispose() async {
    await _gemini.disconnect();
    await _frameAudioSubs?.cancel();
    await FlutterPcmSound.release();
    _photoTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    // 시스템 지시문을 외부 파일에서 로드
    String defaultSystemInstruction = await _loadSystemInstructionsFromAsset();

    // API 키 관리자에서 API 키 로드
    String? apiKey = await ApiKeyManager.getApiKey();

    // 저장된 API 키가 없으면 샘플 키나 빈 문자열 사용
    if (apiKey == null || apiKey.isEmpty) {
      apiKey = ApiKeyManager.getSampleApiKey();
    }

    setState(() {
      _apiKeyController.text = apiKey!;
      _systemInstructionController.text =
          prefs.getString('system_instruction') ?? defaultSystemInstruction;
      _voiceName = GeminiVoiceName.values.firstWhere(
        (e) =>
            e.toString().split('.').last ==
            (prefs.getString('voice_name') ?? 'Aoede'),
        orElse: () => GeminiVoiceName.Puck,
      );
    });
  }

  // 시스템 지시문을 외부 파일에서 로드하는 함수
  Future<String> _loadSystemInstructionsFromAsset() async {
    try {
      return await rootBundle.loadString('assets/system_instructions.txt');
    } catch (e) {
      _log.severe('Failed to load system instructions: $e');
      // 파일 로드 실패시 기본값 반환
      return '당신은 사용자의 스마트 글래스에서 실시간으로 전송되는 이미지를 보고 있습니다. 이는 녹화된 영상이 아닌 실시간 영상입니다. 모든 응답은 반드시 한국어로 제공해 주세요.';
    }
  }

  // SharedPreferences에 설정 저장하는 함수
  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();

    // API 키 저장에 ApiKeyManager 사용
    await ApiKeyManager.saveApiKey(_apiKeyController.text);

    await prefs.setString(
        'system_instruction', _systemInstructionController.text);
    await prefs.setString('voice_name', _voiceName.name);

    // 저장 완료 알림
    _appendEvent('설정이 저장되었습니다.');
  }

  /// This application uses Gemini's realtime API over WebSockets.
  /// It has a running main loop in this function and also on the Frame (frame_app.lua)
  @override
  Future<void> run() async {
    // validate API key exists at least
    _errorMsg = null;
    if (_apiKeyController.text.isEmpty) {
      setState(() {
        _errorMsg = 'Error: Set value for Gemini API Key';
      });

      return;
    }

    // connect to Gemini realtime
    await _gemini.connect(
        _apiKeyController.text, _voiceName, _systemInstructionController.text);

    if (!_gemini.isConnected()) {
      _log.severe('Connection to Gemini failed');
      return;
    }

    setState(() {
      currentState = ApplicationState.running;
    });

    try {
      // let Frame know to subscribe for taps and send them to us
      await frame!.sendMessage(0x10, TxCode(value: 1).pack());

      // 앱 시작 시 "Double tap to resume!" 메시지 표시
      await frame!
          .sendMessage(0x0b, TxPlainText(text: 'Double tap to resume!').pack());

      // listen for double taps to start/stop transcribing
      _tapSubs?.cancel();
      _tapSubs = RxTap().attach(frame!.dataResponse).listen((taps) async {
        _log.info('taps: $taps');
        if (_gemini.isConnected()) {
          if (taps >= 2) {
            if (!_streaming) {
              await _startFrameStreaming();
            } else {
              await _stopFrameStreaming();

              // prompt the user to begin tapping
              await frame!.sendMessage(
                  0x0b, TxPlainText(text: 'Double tap to resume!').pack());
            }
          }
          // ignore spurious 1-taps
        } else {
          // Disconnected from Gemini, go back to Ready state
          _appendEvent('Disconnected from Gemini');

          _stopFrameStreaming();

          setState(() {
            currentState = ApplicationState.ready;
          });
        }
      });

      // 사용자가 말하기 시작할 때 "AI 듣는 중..." 표시
      // await frame!
      //     .sendMessage(0x0b, TxPlainText(text: 'AI Listening...').pack());

      // // AI가 응답을 시작하면 "AI 응답 중..." 메시지 표시
      // frame!.sendMessage(0x0b, TxPlainText(text: 'AI Speaking...').pack());
    } catch (e) {
      _errorMsg = 'Error executing application logic: $e';
      _log.fine(_errorMsg);

      setState(() {
        currentState = ApplicationState.ready;
      });
    }
  }

  /// Once running(), audio streaming is controlled by taps. But the user can cancel
  /// here as well, whether they are currently streaming audio or not.
  @override
  Future<void> cancel() async {
    setState(() {
      currentState = ApplicationState.canceling;
    });

    // cancel the subscription for taps
    _tapSubs?.cancel();

    // cancel the conversation if it's running
    if (_streaming) _stopFrameStreaming();

    // tell the Frame to stop streaming audio (regardless of if we are currently)
    await frame!.sendMessage(0x30, TxCode(value: 0).pack());

    // let Frame know to stop sending taps too
    await frame!.sendMessage(0x10, TxCode(value: 0).pack());

    // clear the display
    await frame!.sendMessage(0x0b, TxPlainText(text: ' ').pack());

    // disconnect from Gemini
    await _gemini.disconnect();

    setState(() {
      currentState = ApplicationState.ready;
    });
  }

  /// When we receive a tap to start the conversation, we need to start
  /// audio and photo streaming on Frame
  Future<void> _startFrameStreaming() async {
    _appendEvent('Starting Frame Streaming');
    _addDebugLog('Starting Frame Streaming');

    try {
      // 오디오 재생 시작 전에 이전 세션 정리
      FlutterPcmSound.release();
      await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
      FlutterPcmSound.start();
      _addDebugLog('Audio playback started');
    } catch (e) {
      _addDebugLog('Error starting audio playback: $e');
    }

    _streaming = true;

    try {
      _frameAudioSampleStream = _rxAudio.attach(frame!.dataResponse);
      _frameAudioSubs?.cancel();
      _frameAudioSubs = _frameAudioSampleStream!.listen((data) {
        _addDebugLog('Received audio data: ${data.length} bytes');
        _handleFrameAudio(data);
      });

      await frame!.sendMessage(0x30, TxCode(value: 1).pack());
      _addDebugLog('Sent AUDIO_SUBS_MSG with value 1');

      await frame!
          .sendMessage(0x0b, TxPlainText(text: 'AI Listening...').pack());
      _addDebugLog('Sent TEXT_MSG: AI Listening...');

      await _requestPhoto();
      _photoTimer =
          Timer.periodic(const Duration(seconds: photoInterval), (timer) async {
        if (!_streaming) {
          timer.cancel();
          _photoTimer = null;
          _addDebugLog('Photo timer cancelled');
          return;
        }
        await _requestPhoto();
      });
    } catch (e) {
      _addDebugLog('Error in _startFrameStreaming: $e');
      _log.warning(() => 'Error executing application logic: $e');
    }
  }

  /// When we receive a tap to stop the conversation, cancel the audio streaming from Frame,
  /// which will send "final chunk" message, which will close the audio stream
  /// and the Gemini conversation needs to stop too
  Future<void> _stopFrameStreaming() async {
    _streaming = false;
    _addDebugLog('Stopping Frame Streaming');

    _gemini.stopResponseAudio();
    _playingAudio = false;

    _photoTimer?.cancel();
    _photoTimer = null;

    await frame!.sendMessage(0x30, TxCode(value: 0).pack());
    _addDebugLog('Sent AUDIO_SUBS_MSG with value 0');

    _rxAudio.detach();
    _addDebugLog('Audio stream detached');

    _appendEvent('Ending Frame Streaming');
  }

  /// Request a photo from Frame
  Future<void> _requestPhoto() async {
    _log.info('requesting photo from Frame');

    // prepare to receive the photo from Frame
    // this must happen each time as the stream
    // closes after each photo is sent
    _photoStream = _rxPhoto.attach(frame!.dataResponse);
    _photoSubs?.cancel();
    _photoSubs = _photoStream!.listen(_handleFramePhoto);

    // TODO check if we can request a raw (headerless) jpeg
    //_rxPhoto.

    await frame!.sendMessage(
        0x0d,
        TxCaptureSettings(resolution: resolution, qualityIndex: qualityIndex)
            .pack());
  }

  /// pass the audio from Frame (upsampled) to the API
  void _handleFrameAudio(Uint8List pcm16x8) {
    if (_gemini.isConnected()) {
      var pcm16x16 = AudioUpsampler.upsample8kTo16k(pcm16x8);
      _addDebugLog('Upsampled audio: ${pcm16x16.length} bytes');
      _gemini.sendAudio(pcm16x16);
    }
  }

  /// pass the photo from Frame to the API
  void _handleFramePhoto(Uint8List jpegBytes) {
    _addDebugLog('Received photo: ${jpegBytes.length} bytes');
    if (_gemini.isConnected()) {
      _gemini.sendPhoto(jpegBytes);
      _addDebugLog('Sent photo to Gemini');
    }

    // 이전 이미지 참조 제거
    _image = null;

    // update the UI with the latest image
    setState(() {
      _image = Image.memory(jpegBytes, gaplessPlayback: true);
    });
  }

  /// Notification from GeminiRealtime that some audio is ready for playback
  void _audioReadyCallback() {
    if (!_playingAudio) {
      _playingAudio = true;
      _addDebugLog('Audio ready callback triggered');
      frame!.sendMessage(0x0b, TxPlainText(text: 'AI Speaking...').pack());
      _addDebugLog('Sent TEXT_MSG: AI Speaking...');
      _onFeed(0);
      _log.fine('Response audio started');
    }
  }

  /// puts some text into our scrolling log in the UI
  void _appendEvent(String evt) {
    setState(() {
      _eventLog.add(evt);
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_eventLogController.hasClients) {
        _eventLogController.animateTo(
          _eventLogController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // 디버그 로그 추가 함수
  void _addDebugLog(String message) {
    final timestamp = DateTime.now().toString().split('.')[0];
    final memoryInfo =
        'Memory: ${(DateTime.now().millisecondsSinceEpoch % 1000)}KB';
    setState(() {
      _debugLog.add('[$timestamp] $message ($memoryInfo)');
      if (_debugLog.length > 1000) {
        // 로그 최대 1000줄로 제한
        _debugLog.removeAt(0);
      }
    });
    _scrollDebugToBottom();
  }

  void _scrollDebugToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_debugLogController.hasClients) {
        _debugLogController.animateTo(
          _debugLogController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // 디버그 패널 위젯
  Widget _buildDebugPanel() {
    return Container(
      color: Colors.black87,
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Text(
                  'Debug Panel',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () {
                  setState(() {
                    _isDebugPanelVisible = false;
                  });
                },
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              controller: _debugLogController,
              itemCount: _debugLog.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8.0, vertical: 2.0),
                  child: Text(
                    _debugLog[index],
                    style: _debugTextStyle,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    startForegroundService();
    return WithForegroundTask(
        child: MaterialApp(
      title: 'Frame Realtime Gemini Voice and Vision',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
            title: const Text('Frame Realtime Gemini Voice and Vision'),
            actions: [
              IconButton(
                icon: const Icon(Icons.bug_report),
                onPressed: () {
                  setState(() {
                    _isDebugPanelVisible = !_isDebugPanelVisible;
                  });
                },
              ),
              getBatteryWidget(),
            ]),
        body: Stack(
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ExpansionTile(
                      title: const Text('설정'),
                      initiallyExpanded: _isSettingsExpanded,
                      onExpansionChanged: (bool expanded) {
                        setState(() {
                          _isSettingsExpanded = expanded;
                        });
                      },
                      children: <Widget>[
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _apiKeyController,
                                    decoration: const InputDecoration(
                                      hintText: 'Enter Gemini API Key',
                                      helperText: '보안을 위해 API 키는 안전하게 보관됩니다',
                                      helperStyle: TextStyle(
                                        fontSize: 12,
                                        color: Colors.amber,
                                      ),
                                      prefixIcon: Icon(Icons.security),
                                    ),
                                    obscureText: true, // API 키를 마스킹 처리
                                    enableSuggestions: false,
                                    autocorrect: false,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                DropdownButton<GeminiVoiceName>(
                                  value: _voiceName,
                                  onChanged: (GeminiVoiceName? newValue) {
                                    setState(() {
                                      _voiceName = newValue!;
                                    });
                                  },
                                  items: GeminiVoiceName.values
                                      .map<DropdownMenuItem<GeminiVoiceName>>(
                                          (GeminiVoiceName value) {
                                    return DropdownMenuItem<GeminiVoiceName>(
                                      value: value,
                                      child: Text(
                                          value.toString().split('.').last),
                                    );
                                  }).toList(),
                                ),
                              ],
                            ),
                            const Text(
                              'API 키는 앱 내에 암호화되어 저장됩니다. GitHub에 푸시하지 마세요.',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _systemInstructionController,
                          maxLines: 3,
                          decoration: const InputDecoration(
                              hintText: 'System Instruction'),
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerRight,
                          child: ElevatedButton(
                              onPressed: _savePrefs, child: const Text('Save')),
                        ),
                      ],
                    ),
                    if (_errorMsg != null)
                      Text(_errorMsg!,
                          style: const TextStyle(backgroundColor: Colors.red)),
                    Expanded(
                        child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _image ?? Container(),
                        Expanded(
                          child: ListView.builder(
                            controller:
                                _eventLogController, // Auto-scroll controller
                            itemCount: _eventLog.length,
                            itemBuilder: (context, index) {
                              return Text(
                                _eventLog[index],
                                style: _textStyle,
                              );
                            },
                          ),
                        ),
                      ],
                    )),
                  ],
                ),
              ),
            ),
            if (_isDebugPanelVisible)
              Positioned.fill(
                child: _buildDebugPanel(),
              ),
          ],
        ),
        floatingActionButton: Stack(children: [
          if (_eventLog.isNotEmpty)
            Positioned(
              bottom: 90,
              right: 20,
              child: FloatingActionButton(
                  onPressed: () {
                    Share.share(_eventLog.join('\n'));
                  },
                  child: const Icon(Icons.share)),
            ),
          Positioned(
            bottom: 20,
            right: 20,
            child: getFloatingActionButtonWidget(
                    const Icon(Icons.mic), const Icon(Icons.mic_off)) ??
                Container(),
          ),
        ]),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    ));
  }
}
