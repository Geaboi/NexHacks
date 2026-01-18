import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/navigation_provider.dart';
import '../providers/sensor_provider.dart';
import '../main.dart';
import 'recording_page.dart';

class InstructionsPage extends ConsumerWidget {
  const InstructionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navState = ref.watch(navigationProvider);
    final projectName = navState.selectedProject?.name ?? 'Exercise';
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(projectName),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                'Recording Instructions',
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Follow these steps to record your ${projectName.toLowerCase()} exercise',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),

              // Instruction Step 1
              _InstructionStep(
                stepNumber: 1,
                title: 'Position Your Camera',
                description:
                    'Place your phone at a stable position where your full body movement is visible.',
                imagePlaceholder: true,
              ),
              const SizedBox(height: 16),

              // Instruction Step 2
              _InstructionStep(
                stepNumber: 2,
                title: 'Ensure Good Lighting',
                description:
                    'Make sure the area is well-lit so the camera can clearly capture your movements.',
                imagePlaceholder: true,
              ),
              const SizedBox(height: 16),

              // Instruction Step 3 - Sensor Connection
              _SensorConnectionStep(stepNumber: 3),
              const SizedBox(height: 16),

              // Instruction Step 4
              _InstructionStep(
                stepNumber: 4,
                title: 'Start Recording',
                description:
                    'Press the record button and perform your exercise as instructed by your therapist.',
                imagePlaceholder: false,
              ),
              const SizedBox(height: 32),

              // Tips Section
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.warning.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.warning.withOpacity(0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.lightbulb_outline, color: AppColors.warning),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Pro Tip',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Record multiple repetitions for more accurate analysis of your form and progress.',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // Start Recording Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const RecordingPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.videocam),
                  label: const Text('Start Recording'),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstructionStep extends StatelessWidget {
  final int stepNumber;
  final String title;
  final String description;
  final bool imagePlaceholder;

  const _InstructionStep({
    required this.stepNumber,
    required this.title,
    required this.description,
    required this.imagePlaceholder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Step Header
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '$stepNumber',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: theme.textTheme.titleLarge,
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Description
          Text(
            description,
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.5,
            ),
          ),

          // Image Placeholder
          if (imagePlaceholder) ...[
            const SizedBox(height: 16),
            Container(
              height: 120,
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.textLight.withOpacity(0.3)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.image_outlined, size: 40, color: AppColors.textLight),
                  const SizedBox(height: 8),
                  Text(
                    'Image Placeholder',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Sensor connection step with Bluetooth pairing functionality
class _SensorConnectionStep extends ConsumerWidget {
  final int stepNumber;

  const _SensorConnectionStep({required this.stepNumber});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sensorState = ref.watch(sensorProvider);
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Step Header
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: sensorState.isConnected ? AppColors.success : AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: sensorState.isConnected
                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                      : Text(
                          '$stepNumber',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Connect IMU Sensors',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              // Status indicator
              _buildStatusChip(sensorState),
            ],
          ),
          const SizedBox(height: 12),

          // Description
          Text(
            sensorState.isConnected
                ? 'Your SmartPT sensors are connected and ready to capture motion data.'
                : 'Connect your SmartPT sensors via Bluetooth for enhanced motion tracking (optional).',
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),

          // Connection UI
          if (sensorState.isConnected) ...[
            // Connected state
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.success.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.success.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.bluetooth_connected, color: AppColors.success),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SmartPT Device',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: AppColors.success,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          sensorState.statusMessage,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppColors.success,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      ref.read(sensorProvider.notifier).disconnect();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                    ),
                    child: const Text('Disconnect'),
                  ),
                ],
              ),
            ),
          ] else ...[
            // Not connected state - show connect button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: sensorState.isScanning
                    ? null
                    : () {
                        ref.read(sensorProvider.notifier).scanAndConnect();
                      },
                icon: sensorState.isScanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                        ),
                      )
                    : const Icon(Icons.bluetooth_searching),
                label: Text(
                  sensorState.isScanning ? 'Scanning...' : 'Connect Sensors',
                ),
              ),
            ),
            if (sensorState.statusMessage != 'Not connected') ...[
              const SizedBox(height: 8),
              Text(
                sensorState.statusMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: sensorState.statusMessage.contains('error') ||
                          sensorState.statusMessage.contains('not found')
                      ? AppColors.error
                      : AppColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 12),
            // Skip option
            Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: AppColors.textLight),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Sensors are optional. You can still record without them.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusChip(SensorState state) {
    Color bgColor;
    Color textColor;
    String label;
    IconData icon;

    if (state.isConnected) {
      bgColor = AppColors.success.withOpacity(0.1);
      textColor = AppColors.success;
      label = 'Connected';
      icon = Icons.check_circle;
    } else if (state.isScanning) {
      bgColor = AppColors.info.withOpacity(0.1);
      textColor = AppColors.info;
      label = 'Scanning';
      icon = Icons.bluetooth_searching;
    } else {
      bgColor = AppColors.textLight.withOpacity(0.2);
      textColor = AppColors.textSecondary;
      label = 'Optional';
      icon = Icons.bluetooth_disabled;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: textColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: textColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
