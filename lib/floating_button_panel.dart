import 'package:flutter/material.dart';

class FloatingButtonPanel extends StatelessWidget {
  final bool isPlayingAudio;
  final bool isSpeaking;
  final VoidCallback onStopPressed;
  final Widget? micButtonWidget;

  const FloatingButtonPanel({
    super.key,
    required this.isPlayingAudio,
    required this.isSpeaking,
    required this.onStopPressed,
    this.micButtonWidget,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Stop(정지) 플로팅 버튼: 오디오 응답 즉시 멈추고 AI Listening... 상태로 전환
        Positioned(
          bottom: 105,
          right: 15,
          child: FloatingActionButton(
            onPressed: (isPlayingAudio || isSpeaking) ? onStopPressed : null,
            child: const Icon(Icons.stop),
            backgroundColor:
                (isPlayingAudio || isSpeaking) ? Colors.red : Colors.grey,
          ),
        ),
        // 마이크 버튼
        // if (micButtonWidget != null)
        //   Positioned(
        //     bottom: 155,
        //     right: 15,
        //     child: micButtonWidget!,
        //   ),
      ],
    );
  }
}
