import 'package:flutter_riverpod/flutter_riverpod.dart';

// Model for an injury/project
class InjuryProject {
  final String id;
  final String name;
  final String description;

  const InjuryProject({
    required this.id,
    required this.name,
    required this.description,
  });
}

// Sample injury projects for placeholder
final sampleProjects = [
  const InjuryProject(
    id: '1',
    name: 'Knee Rehabilitation',
    description: 'ACL recovery exercises',
  ),
];

// State for navigation
class NavigationState {
  final InjuryProject? selectedProject;

  const NavigationState({
    this.selectedProject,
  });

  NavigationState copyWith({
    InjuryProject? selectedProject,
  }) {
    return NavigationState(
      selectedProject: selectedProject ?? this.selectedProject,
    );
  }
}

// Navigation notifier using Riverpod 2.0 Notifier
class NavigationNotifier extends Notifier<NavigationState> {
  @override
  NavigationState build() {
    return const NavigationState();
  }

  void selectProject(InjuryProject project) {
    state = state.copyWith(selectedProject: project);
  }

  void clearProject() {
    state = const NavigationState(selectedProject: null);
  }
}

// Provider using Riverpod 2.0 NotifierProvider
final navigationProvider =
    NotifierProvider<NavigationNotifier, NavigationState>(
  NavigationNotifier.new,
);
