import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:http_parser/http_parser.dart';

/// Response from the analytics backend
class AnalyticsResponse {
  final String?
  processedVideoPath; // Path to the downloaded processed video (null if not provided)
  final Map<String, dynamic> analyticsData; // JSON analytics data
  final List<List<dynamic>>? rawAngles; // Raw CV angles (before fusion)
  final List<List<dynamic>>? imuAngles; // Raw IMU accumulated angles
  final int? jointIndex; // The joint index used for fusion
  final List<int> anomalousIds; // Frame indices flagged as anomalous by backend
  final List<Map<String, dynamic>>
  detectedActions; // Detected action segments from Overshoot
  final bool success;
  final String? errorMessage;
  final Map<String, dynamic>? debugStats; // Alignment debug info

  const AnalyticsResponse({
    this.processedVideoPath,
    required this.analyticsData,
    this.rawAngles,
    this.imuAngles,
    this.jointIndex,
    this.anomalousIds = const [],
    this.detectedActions = const [],
    this.success = true,
    this.errorMessage,
    this.debugStats,
  });

  factory AnalyticsResponse.fromJson(
    Map<String, dynamic> json,
    String? videoPath,
  ) {
    // Parse anomalous_ids from response
    List<int> anomalousIds = [];
    if (json.containsKey('anomalous_ids') && json['anomalous_ids'] != null) {
      final rawIds = json['anomalous_ids'] as List<dynamic>;
      anomalousIds = rawIds.map((e) => e as int).toList();
    }

    // Parse raw_angles
    List<List<dynamic>>? rawAngles;
    if (json.containsKey('raw_angles') && json['raw_angles'] != null) {
      rawAngles = (json['raw_angles'] as List<dynamic>)
          .map((e) => e as List<dynamic>)
          .toList();
    }

    // Parse imu_angles
    List<List<dynamic>>? imuAngles;
    if (json.containsKey('imu_angles') && json['imu_angles'] != null) {
      imuAngles = (json['imu_angles'] as List<dynamic>)
          .map((e) => e as List<dynamic>)
          .toList();
    }

    // Parse debug_stats
    Map<String, dynamic>? debugStats;
    if (json.containsKey('debug_stats') && json['debug_stats'] != null) {
      debugStats = json['debug_stats'] as Map<String, dynamic>;
    }

    // Parse joint_index
    int? jointIndex = json['joint_index'] as int?;

    // Parse detected_actions from Overshoot
    // Format: [{action, timestamp, confidence, frame_number, metadata}, ...]
    List<Map<String, dynamic>> detectedActions = [];
    if (json.containsKey('detected_actions') &&
        json['detected_actions'] != null) {
      final rawActions = json['detected_actions'] as List<dynamic>;
      detectedActions = rawActions
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }

    return AnalyticsResponse(
      processedVideoPath: videoPath,
      analyticsData: json,
      rawAngles: rawAngles,
      imuAngles: imuAngles,
      jointIndex: jointIndex,
      anomalousIds: anomalousIds,
      detectedActions: detectedActions,
      success: true,
      debugStats: debugStats,
    );
  }

  factory AnalyticsResponse.error(String message) {
    return AnalyticsResponse(
      analyticsData: {},
      success: false,
      errorMessage: message,
    );
  }
}

/// Represents overshoot points mapped to video frames
/// Each point is [frameIndex, inferenceResult]
typedef OvershootPoints = List<List<dynamic>>;

/// Service for sending video and analysis data to backend and receiving analytics
class AnalyticsService {
  // Backend Configuration - Update with your actual backend URL
  static const String _defaultBackendUrl =
      'https://api.mateotaylortest.org/api/pose/process';
  static const String _defaultBaseUrl = 'https://api.mateotaylortest.org';

  /// Helper to format JSON for debug logging with truncated arrays
  /// Shows first 5 elements of arrays, then '...'
  static String _formatJsonForDebug(dynamic data, {int indent = 0}) {
    final indentStr = '  ' * indent;
    final nextIndent = '  ' * (indent + 1);

    if (data == null) {
      return 'null';
    } else if (data is String) {
      return '"$data"';
    } else if (data is num || data is bool) {
      return data.toString();
    } else if (data is List) {
      if (data.isEmpty) {
        return '[]';
      }
      final buffer = StringBuffer('[\n');
      final itemsToShow = data.length > 5 ? 5 : data.length;
      for (var i = 0; i < itemsToShow; i++) {
        buffer.write(
          '$nextIndent${_formatJsonForDebug(data[i], indent: indent + 1)}',
        );
        if (i < itemsToShow - 1 || data.length > 5) {
          buffer.write(',');
        }
        buffer.write('\n');
      }
      if (data.length > 5) {
        buffer.write('$nextIndent... (${data.length - 5} more items)\n');
      }
      buffer.write('$indentStr]');
      return buffer.toString();
    } else if (data is Map) {
      if (data.isEmpty) {
        return '{}';
      }
      final buffer = StringBuffer('{\n');
      final entries = data.entries.toList();
      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i];
        buffer.write(
          '$nextIndent"${entry.key}": ${_formatJsonForDebug(entry.value, indent: indent + 1)}',
        );
        if (i < entries.length - 1) {
          buffer.write(',');
        }
        buffer.write('\n');
      }
      buffer.write('$indentStr}');
      return buffer.toString();
    }
    return data.toString();
  }

  /// Submit analysis request to backend
  Future<AnalyticsResponse> submitAnalysis({
    required String videoPath,
    required List<Map<String, dynamic>> inferencePoints,
    required int videoStartTimeUtc,
    required int fps,
    required int videoDurationMs,
    List<Map<String, dynamic>>? sensorSamples,
    String datasetName = 'flutter_recording',
    String modelId = 'default_model',
    String? backendUrl,
    int jointIndex = 0,
    String? streamId,
  }) async {
    final url = backendUrl ?? _defaultBackendUrl;

    try {
      // 1. Gather video file (only if not a stream ID and path exists)
      File? videoFile;
      if (streamId == null || !videoPath.startsWith('stream://')) {
        try {
          videoFile = await _gatherVideoFile(videoPath);
        } catch (e) {
          print('[AnalyticsService] ⚠️ Could not load video file: $e');
          // If streamId is present, we permit missing file
          if (streamId == null) rethrow;
        }
      }

      // 2. Map overshoot points to video frame indices
      final overshootPoints = mapInferenceToVideoFrames(
        inferencePoints: inferencePoints,
        videoStartTimeUtc: videoStartTimeUtc,
        fps: fps,
        videoDurationMs: videoDurationMs,
      );

      print(
        '[AnalyticsService] 📊 Mapped ${overshootPoints.length} overshoot points to video frames',
      );

      // 3. Prepare sensor data (empty list if not available)
      final sensorJson = sensorSamples != null
          ? jsonEncode(sensorSamples)
          : '[]';

      print(
        '[AnalyticsService] 📡 Sensor data: ${sensorSamples != null ? '${sensorSamples.length} samples' : 'not available'}',
      );

      // 4. Send data to backend
      final response = await _sendDataToBackend(
        url: url,
        videoFile: videoFile,
        overshootPoints: overshootPoints,
        videoStartTimeUtc: videoStartTimeUtc,
        sensorDataJson: sensorJson,
        datasetName: datasetName,
        modelId: modelId,
        jointIndex: jointIndex,
        streamId: streamId,
      );

      // 5. Process response
      final result = await _processResponse(response);

      return result;
    } catch (e) {
      print('[AnalyticsService] ❌ Error submitting analysis: $e');
      return AnalyticsResponse.error(e.toString());
    }
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
    if (inferencePoints.isEmpty) {
      return [];
    }

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
      final frameIndex = (offsetMs * fps / 1000).round().clamp(
        0,
        totalFrames - 1,
      );

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

  /// Send data to backend API
  /// Matches the backend's process_video_to_angles endpoint
  Future<http.Response> _sendDataToBackend({
    required String url,
    File? videoFile,
    required OvershootPoints overshootPoints,
    required int videoStartTimeUtc,
    required String sensorDataJson,
    required String datasetName,
    required String modelId,
    required int jointIndex,
    String? streamId,
  }) async {
    print('[AnalyticsService] 🚀 Sending data to backend: $url');

    // Build URL with query parameters
    final uri = Uri.parse(url).replace(
      queryParameters: {
        'dataset_name': datasetName,
        'model_id': modelId,
        'upload_to_woodwide': 'false',
        'overwrite': 'false',
      },
    );

    // Create multipart request
    final request = http.MultipartRequest('POST', uri);

    // Add video file (Optional now)
    if (videoFile != null) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'video',
          videoFile.path,
          filename: 'recording.mp4',
        ),
      );
    }

    // Add overshoot points as JSON file
    request.files.add(
      http.MultipartFile.fromString(
        'overshoot_data',
        jsonEncode(overshootPoints),
        filename: 'overshoot_data.json',
        contentType: MediaType('application', 'json'),
      ),
    );

    // Add video start time (Form field)
    request.fields['video_start_time'] = videoStartTimeUtc.toString();

    // Add sensor data as JSON file
    request.files.add(
      http.MultipartFile.fromString(
        'sensor_data',
        sensorDataJson,
        filename: 'sensor_data.json',
        contentType: MediaType('application', 'json'),
      ),
    );

    // Add joint index (Form field)
    request.fields['joint_index'] = jointIndex.toString();

    // Add stream ID for detected actions retrieval (Form field)
    if (streamId != null && streamId.isNotEmpty) {
      request.fields['stream_id'] = streamId;
      print('[AnalyticsService] 📋 Including stream_id: $streamId');
    }

    // Send request with timeout (extended for video processing)
    final streamedResponse = await request.send().timeout(
      const Duration(minutes: 10),
      onTimeout: () {
        throw TimeoutException('Backend request timed out after 10 minutes');
      },
    );

    return await http.Response.fromStream(streamedResponse);
  }

  /// Process backend response
  Future<AnalyticsResponse> _processResponse(http.Response response) async {
    print('[AnalyticsService] 📥 Response status: ${response.statusCode}');

    if (response.statusCode != 200) {
      final errorBody = response.body;
      print('[AnalyticsService] ❌ Backend error: $errorBody');
      return AnalyticsResponse.error(
        'Backend request failed: ${response.statusCode} - $errorBody',
      );
    }

    try {
      final jsonResponse = jsonDecode(response.body) as Map<String, dynamic>;

      // Download overlay video if path is provided
      String? processedVideoPath;
      if (jsonResponse.containsKey('overlay_video_path') &&
          jsonResponse['overlay_video_path'] != null) {
        final videoFilename = jsonResponse['overlay_video_path'] as String;
        // Extract just the filename if it's a full path
        final filename = videoFilename.split('/').last.split('\\').last;
        try {
          processedVideoPath = await _downloadOverlayVideo(filename);
        } catch (e) {
          print("Failed to download overlay video: $e");
        }
      }

      print('[AnalyticsService] ✅ Analysis complete');

      return AnalyticsResponse.fromJson(jsonResponse, processedVideoPath);
    } catch (e) {
      print('[AnalyticsService] ⚠️ Error parsing response: $e');
      // Return raw response body as analytics data if JSON parsing fails
      return AnalyticsResponse(
        analyticsData: {'raw_response': response.body},
        success: true,
      );
    }
  }

  /// Download overlay video from backend using /api/pose/download-video/{filename} endpoint
  Future<String> _downloadOverlayVideo(String videoFilename) async {
    final videoUrl = '$_defaultBaseUrl/api/pose/download-video/$videoFilename';
    print('[AnalyticsService] 📥 Downloading overlay video from: $videoUrl');

    final response = await http
        .get(Uri.parse(videoUrl))
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            throw TimeoutException('Video download timed out after 2 minutes');
          },
        );

    if (response.statusCode != 200) {
      throw Exception(
        'Failed to download video: ${response.statusCode} - ${response.body}',
      );
    }

    // Save to temp directory
    final tempDir = await getTemporaryDirectory();
    final videoPath = '${tempDir.path}/overlay_video.mp4';
    final file = File(videoPath);
    await file.writeAsBytes(response.bodyBytes);

    print(
      '[AnalyticsService] ✅ Overlay video saved to: $videoPath (${response.bodyBytes.length} bytes)',
    );

    return videoPath;
  }
}
