import 'package:flutter/material.dart';

class DebugPanel extends StatelessWidget {
  final ScrollController debugLogController;
  final List<String> debugLog;
  final VoidCallback onClosePanel;
  final TextStyle debugTextStyle;

  const DebugPanel({
    Key? key,
    required this.debugLogController,
    required this.debugLog,
    required this.onClosePanel,
    this.debugTextStyle = const TextStyle(
        fontSize: 14, fontFamily: 'monospace', color: Colors.white),
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
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
                onPressed: onClosePanel,
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              controller: debugLogController,
              itemCount: debugLog.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8.0, vertical: 2.0),
                  child: Text(
                    debugLog[index],
                    style: debugTextStyle,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
