import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/progress_metrics.dart';
import '../providers/session_history_provider.dart';
import '../main.dart';

/// Widget that displays progress over time for a single joint.
/// Shows the percentile value across sessions as a trend line.
class JointProgressChart extends ConsumerWidget {
  final JointProgressConfig config;
  final Color color;
  final IconData icon;

  const JointProgressChart({super.key, required this.config, required this.color, required this.icon});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progressAsync = ref.watch(jointProgressProvider(config));

    return progressAsync.when(
      loading: () => _buildLoadingState(context),
      error: (error, stack) => _buildErrorState(context, error.toString()),
      data: (data) => _buildChart(context, data),
    );
  }

  Widget _buildLoadingState(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, null),
          const SizedBox(height: 16),
          const SizedBox(height: 120, child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, String error) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, null),
          const SizedBox(height: 16),
          SizedBox(
            height: 120,
            child: Center(
              child: Text('Error: $error', style: TextStyle(color: Colors.red.shade300)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChart(BuildContext context, JointProgressData data) {
    final theme = Theme.of(context);
    final hasData = data.hasData;

    // Build chart data points
    final chartData = <FlSpot>[];
    for (int i = 0; i < data.dataPoints.length; i++) {
      chartData.add(FlSpot(i.toDouble(), data.dataPoints[i].value));
    }

    // Calculate Y bounds with some padding
    final yBounds = _calculateYBounds(data);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, data),
          const SizedBox(height: 16),
          SizedBox(
            height: 120,
            child: hasData
                ? LineChart(
                    LineChartData(
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: (yBounds.$2 - yBounds.$1) / 4,
                        getDrawingHorizontalLine: (value) =>
                            FlLine(color: AppColors.textLight.withOpacity(0.2), strokeWidth: 1),
                      ),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 40,
                            interval: (yBounds.$2 - yBounds.$1) / 4,
                            getTitlesWidget: (value, meta) {
                              return Text(
                                '${value.toInt()}°',
                                style: TextStyle(color: AppColors.textLight, fontSize: 10),
                              );
                            },
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 28,
                            interval: 1,
                            getTitlesWidget: (value, meta) {
                              final index = value.toInt();
                              if (index < 0 || index >= data.dataPoints.length) {
                                return const SizedBox.shrink();
                              }
                              // Only show every Nth label if too many sessions
                              final skipInterval = (data.dataPoints.length / 5).ceil().clamp(1, 10);
                              if (index % skipInterval != 0 && index != data.dataPoints.length - 1) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  data.dataPoints[index].formattedDate,
                                  style: TextStyle(color: AppColors.textLight, fontSize: 9),
                                ),
                              );
                            },
                          ),
                        ),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      borderData: FlBorderData(show: false),
                      minY: yBounds.$1,
                      maxY: yBounds.$2,
                      lineBarsData: [
                        LineChartBarData(
                          spots: chartData,
                          isCurved: true,
                          curveSmoothness: 0.3,
                          color: color,
                          barWidth: 2.5,
                          isStrokeCapRound: true,
                          dotData: FlDotData(
                            show: true,
                            getDotPainter: (spot, percent, bar, index) {
                              return FlDotCirclePainter(
                                radius: 4,
                                color: color,
                                strokeWidth: 1.5,
                                strokeColor: Colors.white,
                              );
                            },
                          ),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              colors: [color.withOpacity(0.2), color.withOpacity(0.0)],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                          ),
                        ),
                      ],
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (touchedSpots) {
                            return touchedSpots.map((spot) {
                              final index = spot.x.toInt();
                              final point = data.dataPoints[index];
                              return LineTooltipItem(
                                '${point.formattedDate}\n${spot.y.toStringAsFixed(1)}°',
                                TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
                              );
                            }).toList();
                          },
                        ),
                      ),
                    ),
                  )
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.show_chart, color: AppColors.textLight, size: 32),
                        const SizedBox(height: 8),
                        Text(
                          data.dataPoints.isEmpty ? 'No sessions yet' : 'Need 2+ sessions for progress',
                          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textLight),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, JointProgressData? data) {
    final theme = Theme.of(context);

    // Build value string
    String valueStr = '--°';
    String? subtitle;
    Widget? trendIndicator;

    if (data != null && data.latestValue != null) {
      valueStr = '${data.latestValue!.toStringAsFixed(1)}°';

      if (data.hasData) {
        final absChange = data.absoluteChange.abs();
        final improving = data.isImproving;

        // For lowerIsBetter: down arrow = improvement (angle decreased)
        // For higherIsBetter: up arrow = improvement (angle increased)
        final IconData trendIcon;
        if (config.lowerIsBetter) {
          trendIcon = improving ? Icons.arrow_downward : Icons.arrow_upward;
        } else {
          trendIcon = improving ? Icons.arrow_upward : Icons.arrow_downward;
        }

        // Trend indicator
        trendIndicator = Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: improving ? AppColors.success.withOpacity(0.15) : Colors.orange.withOpacity(0.15),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                trendIcon,
                size: 14,
                color: improving ? AppColors.success : Colors.orange,
              ),
              const SizedBox(width: 2),
              Text(
                '${absChange.toStringAsFixed(1)}°',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: improving ? AppColors.success : Colors.orange,
                ),
              ),
            ],
          ),
        );

        subtitle = '${data.dataPoints.length} sessions • ${config.goalDescription}';
      } else if (data.dataPoints.length == 1) {
        subtitle = '1 session recorded';
      }
    }

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: color, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(config.shortName, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  if (trendIndicator != null) trendIndicator,
                ],
              ),
              if (subtitle != null)
                Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              valueStr,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: color),
            ),
            Text(
              '${(config.progressPercentile * 100).toInt()}th %ile',
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textLight, fontSize: 10),
            ),
          ],
        ),
      ],
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: AppColors.cardBackground,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [BoxShadow(color: color.withOpacity(0.1), blurRadius: 16, offset: const Offset(0, 4))],
      border: Border.all(color: color.withOpacity(0.15)),
    );
  }

  (double, double) _calculateYBounds(JointProgressData data) {
    if (data.dataPoints.isEmpty) return (0, 100);

    final values = data.dataPoints.map((p) => p.value).toList();
    final minVal = values.reduce((a, b) => a < b ? a : b);
    final maxVal = values.reduce((a, b) => a > b ? a : b);

    // Add 10% padding
    final range = maxVal - minVal;
    final padding = range * 0.1;

    final yMin = (minVal - padding).clamp(0.0, double.infinity);
    final yMax = maxVal + padding;

    // Ensure minimum range for visibility
    if (yMax - yMin < 10) {
      return (yMin - 5, yMax + 5);
    }

    return (yMin, yMax);
  }
}

/// A collection of progress charts for all joints, organized by joint type.
class AllJointsProgressView extends ConsumerWidget {
  const AllJointsProgressView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Knees
        JointProgressChart(
          config: JointProgressConfig.allJoints[0], // left knee
          color: AppColors.kneeColor,
          icon: Icons.accessibility_new,
        ),
        const SizedBox(height: 12),
        JointProgressChart(
          config: JointProgressConfig.allJoints[1], // right knee
          color: AppColors.kneeColor,
          icon: Icons.accessibility_new,
        ),
        const SizedBox(height: 12),
        // Hips
        JointProgressChart(
          config: JointProgressConfig.allJoints[2], // left hip
          color: AppColors.hipColor,
          icon: Icons.airline_seat_legroom_normal,
        ),
        const SizedBox(height: 12),
        JointProgressChart(
          config: JointProgressConfig.allJoints[3], // right hip
          color: AppColors.hipColor,
          icon: Icons.airline_seat_legroom_normal,
        ),
        const SizedBox(height: 12),
        // Ankles
        JointProgressChart(
          config: JointProgressConfig.allJoints[4], // left ankle
          color: AppColors.ankleColor,
          icon: Icons.directions_walk,
        ),
        const SizedBox(height: 12),
        JointProgressChart(
          config: JointProgressConfig.allJoints[5], // right ankle
          color: AppColors.ankleColor,
          icon: Icons.directions_walk,
        ),
      ],
    );
  }
}
