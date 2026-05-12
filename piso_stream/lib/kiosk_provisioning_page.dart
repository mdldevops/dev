import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'theme_provider.dart';

class KioskProvisioningPage extends StatelessWidget {
  const KioskProvisioningPage({super.key});

  static const List<_ChecklistItem> _prerequisites = [
    _ChecklistItem(
      title: 'Use a fresh or factory-reset device',
      detail: 'Device-owner provisioning usually fails on devices that are already set up.',
    ),
    _ChecklistItem(
      title: 'Enable Developer Options and USB debugging',
      detail: 'ADB is required for the device-owner command during provisioning.',
    ),
    _ChecklistItem(
      title: 'Install the kiosk app first',
      detail: 'The package must already exist on the device before running the owner command.',
    ),
    _ChecklistItem(
      title: 'Keep the device connected to your setup PC',
      detail: 'Run the command from the technician machine with ADB available.',
    ),
    _ChecklistItem(
      title: 'Set this app as the Home app after provisioning',
      detail: 'That makes the device reopen straight into your launcher experience.',
    ),
  ];

  static const List<_ChecklistItem> _verification = [
    _ChecklistItem(
      title: 'Check admin settings for Device Owner Active',
      detail: 'The status should flip from Not Active to Active after successful provisioning.',
    ),
    _ChecklistItem(
      title: 'Tap Apply Kiosk Policies once',
      detail: 'This reapplies immersive mode, lock task, and the device policy restrictions.',
    ),
    _ChecklistItem(
      title: 'Try opening system UI and device settings',
      detail: 'On a correctly provisioned device those escape paths should be blocked or heavily limited.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final colors = themeProvider.currentTheme;

    return Scaffold(
      backgroundColor: colors[0],
      appBar: AppBar(
        backgroundColor: colors[1].withValues(alpha: 0.85),
        title: const Text('Provisioning Checklist'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _InfoPanel(
            title: 'ADB Command',
            panelColor: Colors.black.withValues(alpha: 0.22),
            child: SelectableText(
              'adb shell dpm set-device-owner '
              'com.example.piso_stream/.KioskDeviceAdminReceiver',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                height: 1.5,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SectionTitle('Before You Run It'),
          const SizedBox(height: 8),
          ..._prerequisites.asMap().entries.map(
            (entry) => _ChecklistTile(
              number: entry.key + 1,
              item: entry.value,
            ),
          ),
          const SizedBox(height: 20),
          _InfoPanel(
            title: 'What This Enables',
            panelColor: Colors.black.withValues(alpha: 0.22),
            child: const Text(
              'Device-owner mode lets the app enforce lock task, hide system surfaces more reliably, '
              'disable keyguard, and apply the kiosk restrictions that normal apps cannot hold on their own.',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          const SizedBox(height: 20),
          _SectionTitle('After Provisioning'),
          const SizedBox(height: 8),
          ..._verification.asMap().entries.map(
            (entry) => _ChecklistTile(
              number: entry.key + 1,
              item: entry.value,
            ),
          ),
          const SizedBox(height: 20),
          _InfoPanel(
            title: 'If It Fails',
            panelColor: Colors.black.withValues(alpha: 0.22),
            child: const Text(
              'Most failures mean the device was already provisioned before the command was run. '
              'In that case, factory reset the device and repeat the checklist from the top.',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.title,
    required this.child,
    required this.panelColor,
  });

  final String title;
  final Widget child;
  final Color panelColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: panelColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _ChecklistTile extends StatelessWidget {
  const _ChecklistTile({
    required this.number,
    required this.item,
  });

  final int number;
  final _ChecklistItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Colors.cyanAccent.withValues(alpha: 0.15),
            child: Text(
              '$number',
              style: const TextStyle(
                color: Colors.cyanAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.detail,
                  style: const TextStyle(
                    color: Colors.white70,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChecklistItem {
  const _ChecklistItem({
    required this.title,
    required this.detail,
  });

  final String title;
  final String detail;
}
