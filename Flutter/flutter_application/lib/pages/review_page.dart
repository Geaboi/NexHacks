import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../main.dart';
import '../providers/navigation_provider.dart';
import 'analytics_page.dart';

class ReviewPage extends ConsumerStatefulWidget {
  final String videoPath;

  const ReviewPage({super.key, required this.videoPath});

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    final file = File(widget.videoPath);
    if (await file.exists()) {
      _controller = VideoPlayerController.file(file);
      await _controller!.initialize();
      _controller!.addListener(_videoListener);
      setState(() {
        _isInitialized = true;
      });
    }
  }

  void _videoListener() {
    final isPlaying = _controller?.value.isPlaying ?? false;
    if (isPlaying != _isPlaying) {
      setState(() {
        _isPlaying = isPlaying;
      });
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_videoListener);
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_controller == null) return;
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
    }
  }

  void _replayVideo() {
    _controller?.seekTo(Duration.zero);
    _controller?.play();
  }

  void _proceedToAnalysis() {
    // Get video duration in milliseconds
    final videoDurationMs = _controller?.value.duration.inMilliseconds ?? 0;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AnalyticsPage(
          videoPath: widget.videoPath,
          videoDurationMs: videoDurationMs,
          fps: 30, // Default FPS, adjust if needed
        ),
      ),
    );
  }

  void _retakeRecording() {
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final navState = ref.watch(navigationProvider);
    final projectName = navState.selectedProject?.name ?? 'Exercise';
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      appBar: AppBar(
        title: const Text('Review Recording'),
        backgroundColor: AppColors.primaryDark,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Video Player Area
            Expanded(
              child: _isInitialized && _controller != null
                  ? Stack(
                      alignment: Alignment.center,
                      children: [
                        // Video Player
                        AspectRatio(aspectRatio: _controller!.value.aspectRatio, child: VideoPlayer(_controller!)),

                        // Play/Pause Overlay
                        GestureDetector(
                          onTap: _togglePlayPause,
                          child: Container(
                            color: Colors.transparent,
                            child: Center(
                              child: AnimatedOpacity(
                                opacity: _isPlaying ? 0.0 : 1.0,
                                duration: const Duration(milliseconds: 200),
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryDark.withOpacity(0.7),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 48),
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Progress Bar
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: VideoProgressIndicator(
                            _controller!,
                            allowScrubbing: true,
                            colors: VideoProgressColors(
                              playedColor: AppColors.accent,
                              bufferedColor: AppColors.primaryLight.withOpacity(0.4),
                              backgroundColor: AppColors.primaryLight.withOpacity(0.2),
                            ),
                          ),
                        ),
                      ],
                    )
                  : _buildPlaceholder(),
            ),

            // Info Section
            Container(
              padding: const EdgeInsets.all(16),
              color: AppColors.primary,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    projectName,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Review your recording before submitting for analysis.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),

            // Playback Controls
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              color: AppColors.primary,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Replay Button
                  IconButton(
                    onPressed: _isInitialized ? _replayVideo : null,
                    icon: const Icon(Icons.replay),
                    color: Colors.white,
                    iconSize: 32,
                  ),

                  // Play/Pause Button
                  IconButton(
                    onPressed: _isInitialized ? _togglePlayPause : null,
                    icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                    color: Colors.white,
                    iconSize: 48,
                  ),

                  // Placeholder for symmetry
                  const SizedBox(width: 48),
                ],
              ),
            ),

            // Action Buttons
            Container(
              padding: const EdgeInsets.all(16),
              color: AppColors.primary,
              child: Row(
                children: [
                  // Retake Button
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _retakeRecording,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(color: Colors.white.withOpacity(0.4)),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retake'),
                    ),
                  ),
                  const SizedBox(width: 16),

                  // Continue Button
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _proceedToAnalysis,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.analytics),
                      label: const Text('Analyze'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppColors.primary,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.videocam_outlined, size: 80, color: AppColors.primaryLight.withOpacity(0.6)),
          const SizedBox(height: 16),
          Text('Video Preview', style: TextStyle(color: AppColors.primaryLight.withOpacity(0.8), fontSize: 18)),
          const SizedBox(height: 8),
          Text('(Placeholder - no video recorded yet)', style: TextStyle(color: AppColors.primaryLight.withOpacity(0.6), fontSize: 14)),
        ],
      ),
    );
  }
}
