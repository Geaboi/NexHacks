import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Response from the analytics backend
class AnalyticsResponse {
  final String processedVideoPath; // Path to the downloaded processed video
  final Map<String, dynamic> analyticsData; // JSON analytics data
  
  const AnalyticsResponse({
    required this.processedVideoPath,
    required this.analyticsData,
  });
  
  factory AnalyticsResponse.fromJson(Map<String, dynamic> json, String videoPath) {
    return AnalyticsResponse(
      processedVideoPath: videoPath,
      analyticsData: json,
    );
  }
}

/// Represents overshoot points mapped to video frames
/// Each point is [frameIndex, inferenceResult]
typedef OvershootPoints = List<List<dynamic>>;

/// Service for sending video and analysis data to backend and receiving analytics
class AnalyticsService {
  // Backend Configuration - Update with your actual backend URL
  static const String _defaultBackendUrl = 'http://localhost:8000/api/analyze';
  
  /// Submit analysis request to backend
  /// 
  /// This method will:
  /// 1. Gather the recorded video file (temp_record.mp4)
  /// 2. Gather overshoot points from FrameAnalysisProvider
  /// 3. Gather sensor data from SensorProvider (when available)
  /// 4. Send all data to backend
  /// 5. Receive processed video and analytics JSON
  /// 
  /// Parameters:
  /// - videoPath: Path to the recorded MP4 file
  /// - overshootPoints: List of [frameIndex, inferenceResult] pairs
  /// - videoStartTimeUtc: UTC timestamp (ms) when the MP4 recording started
  /// - fps: Frame rate of the video (for frame index calculation)
  /// - videoDurationMs: Duration of the video in milliseconds
  /// 
  /// Returns: AnalyticsResponse with video path and analytics data
  Future<AnalyticsResponse> submitAnalysis({
    required String videoPath,
    required OvershootPoints overshootPoints,
    required int videoStartTimeUtc,
    required int fps,
    required int videoDurationMs,
    String? backendUrl,
  }) async {
    final url = backendUrl ?? _defaultBackendUrl;
    
    // Gather video file
    final videoFile = await _gatherVideoFile(videoPath);
    
    // Gather sensor data (placeholder for future SensorProvider)
    final sensorData = await _gatherSensorData();
    
    // Send data to backend
    final response = await _sendDataToBackend(
      url: url,
      videoFile: videoFile,
      overshootPoints: overshootPoints,
      videoStartTimeUtc: videoStartTimeUtc,
      sensorData: sensorData,
    );
    
    // Process response and download video
    final result = await _processResponse(response);
    
    return result;
  }
  
  /// Helper function to map inference timestamps to video frame indices
  /// 
  /// Parameters:
  /// - inferencePoints: List of {timestampUtc, inferenceResult} maps
  /// - videoStartTimeUtc: UTC timestamp when the MP4 started recording
  /// - fps: Frame rate of the video
  /// - videoDurationMs: Total duration of the video in milliseconds
  /// - toleranceMs: Tolerance for matching frames (default 100ms)
  /// 
  /// Returns: List of [frameIndex, inferenceResult] pairs
  static OvershootPoints mapInferenceToVideoFrames({
    required List<Map<String, dynamic>> inferencePoints,
    required int videoStartTimeUtc,
    required int fps,
    required int videoDurationMs,
    int toleranceMs = 100,
  }) {
    final result = <List<dynamic>>[];
    final totalFrames = (videoDurationMs * fps / 1000).round();

    for (final point in inferencePoints) {
      final timestampUtc = point['timestampUtc'] as int;
      final inferenceResult = point['inferenceResult'] as String;
      
      // Calculate offset from video start
      final offsetMs = timestampUtc - videoStartTimeUtc;
      
      // Skip if before video started or after video ended (with tolerance)
      if (offsetMs < -toleranceMs || offsetMs > videoDurationMs + toleranceMs) {
        continue;
      }

      // Calculate frame index (clamped to valid range)
      final frameIndex = (offsetMs * fps / 1000).round().clamp(0, totalFrames - 1);
      
      result.add([frameIndex, inferenceResult]);
    }

    return result;
  }
  
  /// Gather the recorded video file
  Future<File> _gatherVideoFile(String videoPath) async {
    final file = File(videoPath);
    
    if (!await file.exists()) {
      throw Exception('Video file not found at: $videoPath');
    }
    
    return file;
  }
  
  /// Gather sensor data from SensorProvider (future implementation)
  Future<Map<String, dynamic>?> _gatherSensorData() async {
    // TODO: Access SensorProvider when it exists
    // This will gather data like:
    // - Accelerometer readings
    // - Gyroscope readings
    // - Other sensor data with timestamps
    
    // Placeholder return - null indicates no sensor provider yet
    return null;
  }
  
  /// Send data to backend API
  Future<http.Response> _sendDataToBackend({
    required String url,
    required File videoFile,
    required OvershootPoints overshootPoints,
    required int videoStartTimeUtc,
    required Map<String, dynamic>? sensorData,
  }) async {
    // Create multipart request with:
    // - Video file
    // - Overshoot points as JSON (list of [frameIndex, result])
    // - Video start time
    // - Sensor data JSON (if available)
    
    final request = http.MultipartRequest('POST', Uri.parse(url));
    
    // Add video file
    request.files.add(await http.MultipartFile.fromPath(
      'video',
      videoFile.path,
      filename: 'recording.mp4',
    ));
    
    // Add overshoot points as JSON
    request.fields['overshootPoints'] = jsonEncode(overshootPoints);
    
    // Add video start time
    request.fields['videoStartTimeUtc'] = videoStartTimeUtc.toString();
    
    // Add sensor data if available
    if (sensorData != null) {
      request.fields['sensorData'] = jsonEncode(sensorData);
    }
    
    // Send request
    final streamedResponse = await request.send();
    return await http.Response.fromStream(streamedResponse);
  }
  
  /// Process backend response
  /// 
  /// Expected response format:
  /// - Video file (binary or URL)
  /// - Analytics JSON with metrics
  Future<AnalyticsResponse> _processResponse(http.Response response) async {
    // TODO: Parse response
    // Expected response contains:
    // 1. Processed video (download if URL, or save if binary)
    // 2. Analytics JSON with metrics like:
    //    - Flexion angles
    //    - Form analysis
    //    - Recommendations
    //    - etc.
    
    if (response.statusCode != 200) {
      throw Exception('Backend request failed: ${response.statusCode}');
    }
    
    // TODO: Parse JSON response
    // final jsonResponse = jsonDecode(response.body);
    
    // TODO: Download or save processed video
    // final processedVideoPath = await _downloadProcessedVideo(jsonResponse['videoUrl']);
    
    // Placeholder return
    throw UnimplementedError('Response processing not yet implemented');
  }
  
  /// Download processed video from backend
  Future<String> _downloadProcessedVideo(String videoUrl) async {
    // TODO: Download video from URL and save to temp directory
    // Return the local file path
    
    throw UnimplementedError('Video download not yet implemented');
  }
  
  /// Save binary video data to file
  Future<String> _saveBinaryVideo(List<int> videoData) async {
    // TODO: Save binary video data to temp directory
    // Return the local file path
    
    throw UnimplementedError('Binary video save not yet implemented');
  }
}
