import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/navigation_provider.dart';
import '../providers/session_history_provider.dart';
import '../main.dart';
import 'instructions_page.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navNotifier = ref.read(navigationProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Physical Therapy Tracker'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Section
              const SizedBox(height: 16),
              Text(
                'Welcome Back!',
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Select your injury or project to continue:',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),

              // Project Cards
              Expanded(
                child: sampleProjects.isEmpty
                    ? Center(
                        child: Text(
                          'No projects available',
                          style: theme.textTheme.bodyMedium,
                        ),
                      )
                    : ListView.builder(
                        itemCount: sampleProjects.length,
                        itemBuilder: (context, index) {
                          final project = sampleProjects[index];
                          return _ProjectCard(
                            project: project,
                            ref: ref,
                            onTap: () {
                              navNotifier.selectProject(project);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const InstructionsPage(),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),

              // Add New Project Button (placeholder)
              Center(
                child: TextButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Add project - coming soon!'),
                        backgroundColor: AppColors.primary,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add_circle_outline, color: AppColors.primary),
                  label: Text(
                    'Add New Project',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.primary,
                    ),
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

class _ProjectCard extends StatefulWidget {
  final InjuryProject project;
  final VoidCallback onTap;
  final WidgetRef ref;

  const _ProjectCard({
    required this.project,
    required this.onTap,
    required this.ref,
  });

  @override
  State<_ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends State<_ProjectCard> {
  bool _isExpanded = false;

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionState = widget.ref.watch(sessionHistoryProvider);
    final latestSession = sessionState.latestSession;
    final hasHistory = latestSession != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Main card content
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.vertical(
                top: const Radius.circular(16),
                bottom: Radius.circular(_isExpanded ? 0 : 16),
              ),
              splashColor: AppColors.primary.withOpacity(0.1),
              highlightColor: AppColors.primary.withOpacity(0.05),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Row(
                  children: [
                    // Icon Container
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppColors.primary.withOpacity(0.1),
                            AppColors.accent.withOpacity(0.1),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.fitness_center,
                        color: AppColors.primary,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 20),

                    // Project Info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.project.name,
                            style: theme.textTheme.titleLarge,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            widget.project.description,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),

                    // Arrow
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.arrow_forward_ios,
                        color: AppColors.primary,
                        size: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Expand/Collapse button
          if (hasHistory)
            InkWell(
              onTap: () {
                setState(() {
                  _isExpanded = !_isExpanded;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.03),
                  border: Border(
                    top: BorderSide(color: AppColors.primary.withOpacity(0.1)),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _isExpanded ? 'Hide details' : 'View history',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: AppColors.primary,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),

          // Expanded content
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
              ),
              child: Column(
                children: [
                  _InfoRow(
                    icon: Icons.calendar_today,
                    label: 'Last check-in',
                    value: latestSession != null
                        ? _formatDate(latestSession.createdAt)
                        : 'No sessions yet',
                  ),
                  const SizedBox(height: 12),
                  _InfoRow(
                    icon: Icons.timer,
                    label: 'Session duration',
                    value: latestSession?.durationMs != null
                        ? '${(latestSession!.durationMs! / 1000).toStringAsFixed(0)}s'
                        : '--',
                  ),
                  const SizedBox(height: 12),
                  _InfoRow(
                    icon: Icons.analytics,
                    label: 'Frames analyzed',
                    value: latestSession?.totalFrames?.toString() ?? '--',
                  ),
                  const SizedBox(height: 12),
                  _InfoRow(
                    icon: Icons.trending_up,
                    label: 'Total sessions',
                    value: '${sessionState.sessions.length}',
                  ),
                ],
              ),
            ),
            crossFadeState: _isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.textSecondary),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
