import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/navigation_provider.dart';
import '../providers/sensor_provider.dart';
import 'recording_page.dart';

class InstructionsPage extends ConsumerWidget {
  const InstructionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navState = ref.watch(navigationProvider);
    final projectName = navState.selectedProject?.name ?? 'Exercise';

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(projectName),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              const Text(
                'Recording Instructions',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.teal,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Follow these steps to record your ${projectName.toLowerCase()} exercise',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
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
                  color: Colors.amber.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.withOpacity(0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.lightbulb_outline, color: Colors.amber),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Pro Tip',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Record multiple repetitions for more accurate analysis of your form and progress.',
                            style: TextStyle(
                              color: Colors.grey[700],
                              fontSize: 14,
                            ),
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
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.videocam),
                  label: const Text(
                    'Start Recording',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
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
                  color: Colors.teal,
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
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Description
          Text(
            description,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[600],
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
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.image_outlined, size: 40, color: Colors.grey[400]),
                  const SizedBox(height: 8),
                  Text(
                    'Image Placeholder',
                    style: TextStyle(color: Colors.grey[500]),
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

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
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
                  color: sensorState.isConnected ? Colors.green : Colors.teal,
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
              const Expanded(
                child: Text(
                  'Connect IMU Sensors',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
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
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[600],
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
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.bluetooth_connected, color: Colors.green.shade700),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SmartPT Device',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.green.shade800,
                          ),
                        ),
                        Text(
                          sensorState.statusMessage,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.green.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      ref.read(sensorProvider.notifier).disconnect();
                    },
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
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.teal,
                  side: const BorderSide(color: Colors.teal),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: sensorState.isScanning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.teal),
                        ),
                      )
                    : const Icon(Icons.bluetooth_searching),
                label: Text(
                  sensorState.isScanning ? 'Scanning...' : 'Connect Sensors',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),
            if (sensorState.statusMessage != 'Not connected') ...[
              const SizedBox(height: 8),
              Text(
                sensorState.statusMessage,
                style: TextStyle(
                  fontSize: 12,
                  color: sensorState.statusMessage.contains('error') ||
                          sensorState.statusMessage.contains('not found')
                      ? Colors.red.shade600
                      : Colors.grey[600],
                ),
              ),
            ],
            const SizedBox(height: 12),
            // Skip option
            Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: Colors.grey[500]),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Sensors are optional. You can still record without them.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[500],
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
      bgColor = Colors.green.shade50;
      textColor = Colors.green.shade700;
      label = 'Connected';
      icon = Icons.check_circle;
    } else if (state.isScanning) {
      bgColor = Colors.blue.shade50;
      textColor = Colors.blue.shade700;
      label = 'Scanning';
      icon = Icons.bluetooth_searching;
    } else {
      bgColor = Colors.grey.shade100;
      textColor = Colors.grey.shade600;
      label = 'Optional';
      icon = Icons.bluetooth_disabled;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
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
