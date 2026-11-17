import 'package:flutter/material.dart';

import '../../ble/pump_session.dart';
import '../../widgets/slide_to_start.dart';

class PumpControls extends StatelessWidget {
  const PumpControls({
    super.key,
    required this.session,
    required this.ready,
    required this.linked,
    required this.statusLine,
    required this.onStart,
    required this.onStop,
    required this.onConnect,
  });

  final PumpSession session;
  final bool ready;

  /// Connected and signed in, even if the protocol versions differ.
  final bool linked;
  final String statusLine;
  final Future<void> Function() onStart;
  final VoidCallback onStop;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: session.pumpOn && ready
              ? _RunningPanel(
                  key: const ValueKey('running'),
                  statusLine: statusLine,
                  onStop: onStop,
                )
              : Column(
                  key: const ValueKey('idle'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      statusLine,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SlideToStart(
                      enabled: ready && session.canStartPump,
                      label:
                          ready &&
                              session.tankBound &&
                              session.tankOnline &&
                              session.tankFull
                          ? 'Tank is full'
                          : 'Slide to start',
                      onCompleted: onStart,
                    ),
                  ],
                ),
        ),
        if (!linked && !session.connecting) ...[
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onConnect,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: Text(
              session.connectFailed ? 'Try again' : 'Connect',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
        if (session.connecting)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}

class _RunningPanel extends StatelessWidget {
  const _RunningPanel({
    super.key,
    required this.statusLine,
    required this.onStop,
  });

  final String statusLine;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            statusLine,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: kHomeControlHeight,
          child: FilledButton(
            onPressed: onStop,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: const Text(
              'Stop pump',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}
