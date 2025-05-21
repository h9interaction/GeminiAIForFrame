import 'package:flutter/material.dart';

class CustomAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final VoidCallback onBugReportPressed;
  final VoidCallback onSettingsPressed;
  final VoidCallback onRefreshPressed;
  final Widget? batteryWidget;

  const CustomAppBar({
    Key? key,
    required this.title,
    required this.onBugReportPressed,
    required this.onSettingsPressed,
    required this.onRefreshPressed,
    this.batteryWidget,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title),
      actions: [
        IconButton(
          icon: const Icon(Icons.bug_report),
          tooltip: '디버그 패널',
          onPressed: onBugReportPressed,
        ),
        IconButton(
          icon: const Icon(Icons.settings),
          tooltip: '설정',
          onPressed: onSettingsPressed,
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: '앱 초기화',
          onPressed: onRefreshPressed,
        ),
        if (batteryWidget != null) batteryWidget!,
      ],
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
