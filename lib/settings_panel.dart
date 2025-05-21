import 'package:flutter/material.dart';
import 'package:frame_realtime_gemini_voicevision/gemini_realtime.dart'; // GeminiVoiceName 때문에 필요

class SettingsPanel extends StatefulWidget {
  final TextEditingController apiKeyController;
  final TextEditingController systemInstructionController;
  final GeminiVoiceName initialVoiceName;
  final Function(GeminiVoiceName) onVoiceNameChanged;
  final VoidCallback onSavePrefs;
  final VoidCallback onClosePanel;
  final List<Widget>? footerButtons;

  const SettingsPanel({
    Key? key,
    required this.apiKeyController,
    required this.systemInstructionController,
    required this.initialVoiceName,
    required this.onVoiceNameChanged,
    required this.onSavePrefs,
    required this.onClosePanel,
    this.footerButtons,
  }) : super(key: key);

  @override
  _SettingsPanelState createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late GeminiVoiceName _currentVoiceName;

  @override
  void initState() {
    super.initState();
    _currentVoiceName = widget.initialVoiceName;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black87.withOpacity(0.95),
      child: SafeArea(
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    '설정',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: widget.onClosePanel,
                ),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: widget.apiKeyController,
                            decoration: const InputDecoration(
                              hintText: 'Enter Gemini API Key',
                              helperText: '보안을 위해 API 키는 안전하게 보관됩니다',
                              helperStyle: TextStyle(
                                fontSize: 12,
                                color: Colors.amber,
                              ),
                              prefixIcon: Icon(Icons.security),
                            ),
                            obscureText: true,
                            enableSuggestions: false,
                            autocorrect: false,
                          ),
                        ),
                        const SizedBox(width: 10),
                        DropdownButton<GeminiVoiceName>(
                          value: _currentVoiceName,
                          onChanged: (GeminiVoiceName? newValue) {
                            if (newValue != null) {
                              setState(() {
                                _currentVoiceName = newValue;
                              });
                              widget.onVoiceNameChanged(newValue);
                            }
                          },
                          items: GeminiVoiceName.values
                              .map<DropdownMenuItem<GeminiVoiceName>>(
                                  (GeminiVoiceName value) {
                            return DropdownMenuItem<GeminiVoiceName>(
                              value: value,
                              child: Text(value.toString().split('.').last),
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
                    const SizedBox(height: 10),
                    TextField(
                      controller: widget.systemInstructionController,
                      maxLines: 3,
                      decoration:
                          const InputDecoration(hintText: 'System Instruction'),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton(
                          onPressed: widget.onSavePrefs,
                          child: const Text('Save')),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.footerButtons != null &&
                widget.footerButtons!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0, top: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: widget.footerButtons!,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
