import 'package:flutter/material.dart';

class TextInputPanel extends StatelessWidget {
  final TextEditingController textInputController;
  final Function(String) onTextSubmit;
  final Map<int, String> buttonTexts;

  const TextInputPanel({
    super.key,
    required this.textInputController,
    required this.onTextSubmit,
    required this.buttonTexts,
  });

  void _handleSubmit(BuildContext context, String text) {
    if (text.isNotEmpty) {
      onTextSubmit(text);
      textInputController.clear();
      // 키보드 닫기
      FocusScope.of(context).unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withOpacity(0.95),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 숫자 버튼 4개
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (var i = 1; i <= 4; i++)
                ElevatedButton(
                  onPressed: () {
                    final text = buttonTexts[i] ?? '';
                    if (text.isNotEmpty) {
                      _handleSubmit(context, text);
                    }
                  },
                  child: Text('$i'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: textInputController,
                  decoration: const InputDecoration(
                    hintText: '텍스트 입력...',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (text) => _handleSubmit(context, text),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: () {
                  _handleSubmit(context, textInputController.text);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
