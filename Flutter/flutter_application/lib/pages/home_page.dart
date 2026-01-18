import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/navigation_provider.dart';
import 'instructions_page.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navNotifier = ref.read(navigationProvider.notifier);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Physical Therapy Tracker'),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Section
              const SizedBox(height: 20),
              const Text(
                'Welcome Back!',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.teal,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Select your injury or project to continue:',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 24),

              // Project Cards
              Expanded(
                child: sampleProjects.isEmpty
                    ? const Center(
                        child: Text(
                          'No projects available',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: sampleProjects.length,
                        itemBuilder: (context, index) {
                          final project = sampleProjects[index];
                          return _ProjectCard(
                            project: project,
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
                    // Placeholder - no functionality yet
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Add project - coming soon!'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add_circle_outline, color: Colors.teal),
                  label: const Text(
                    'Add New Project',
                    style: TextStyle(color: Colors.teal),
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

class _ProjectCard extends StatelessWidget {
  final InjuryProject project;
  final VoidCallback onTap;

  const _ProjectCard({
    required this.project,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        splashColor: Colors.teal.withOpacity(0.2),
        highlightColor: Colors.teal.withOpacity(0.1),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Row(
            children: [
              // Placeholder Icon/Image
              Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  color: Colors.teal.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.fitness_center,
                  color: Colors.teal,
                  size: 36,
                ),
              ),
              const SizedBox(width: 20),

              // Project Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      project.description,
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),

              // Arrow
              const Icon(
                Icons.chevron_right,
                color: Colors.grey,
                size: 30,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
