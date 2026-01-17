// lib/services/overshoot_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

class OvershootService {
  // --- CONFIG ---
  final String _apiKey = "ovs_b0720dbcdee515308124d4b82c0d7ff3";
  final String _apiUrl = "https://cluster1.overshoot.ai/api/v0.2";
  
  final Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {
        'urls': 'turn:34.63.114.235:3478',
        'username': '1769538895:c66a907c-61f4-4ec2-93a6-9d6b932776bb',
        'credential': 'Fu9L4CwyYZvsOLc+23psVAo3i/Y='
      }
    ]
  };

  RTCPeerConnection? _peerConnection;
  IOWebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;

  // --- METHODS ---

  Future<MediaStream> getCameraStream() async {
    final Map<String, dynamic> constraints = {
      'audio': false,
      'video': {
        'facingMode': 'environment',
        'width': 1280,
        'height': 720
      }
    };
    return await navigator.mediaDevices.getUserMedia(constraints);
  }

  Future<Stream<String>> startConnection(MediaStream localStream, String prompt) async {
    final resultController = StreamController<String>();

    try {
      // 1. Create Peer Connection
      print("Overshoot: Creating Peer Connection...");
      _peerConnection = await createPeerConnection(_iceConfig);
      localStream.getTracks().forEach((track) {
        _peerConnection!.addTrack(track, localStream);
      });

      // 2. Create Offer
      RTCSessionDescription offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      // 3. ICE Wait (Crucial Hack)
      await Future.delayed(const Duration(seconds: 2));

      // 4. Prepare Headers (The Chameleon Fix)
      final headers = {
        "Authorization": "Bearer $_apiKey",
        "Content-Type": "application/json",
        "User-Agent": "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
        "Origin": "https://playground.overshoot.ai",
      };

      // 5. Send Handshake
      final payload = {
        "webrtc": { "type": "offer", "sdp": await _peerConnection!.getLocalDescription().then((d) => d!.sdp) },
        "processing": { "sampling_ratio": 1.0, "fps": 30, "clip_length_seconds": 1.0, "delay_seconds": 1.0 },
        "inference": { "prompt": prompt, "backend": "overshoot", "model": "Qwen/Qwen3-VL-30B-A3B-Instruct" }
      };

      print("Overshoot: Sending Handshake to $_apiUrl/streams...");
      final response = await http.post(Uri.parse("$_apiUrl/streams"), headers: headers, body: jsonEncode(payload));

      if (response.statusCode != 200) {
        throw Exception("Handshake failed [${response.statusCode}]: ${response.body}");
      }

      final data = jsonDecode(response.body);
      print("Overshoot: Handshake success. Stream ID: ${data['stream_id']}");
      
      // 6. Set Remote Description
      if (data['webrtc'] != null) {
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(data['webrtc']['sdp'], data['webrtc']['type'])
        );
      }

      // 7. Connect WebSocket
      // FIX: Robust URL Construction. 
      // This strips the "/api/v0.2" path to ensure we hit the correct WS root.
      final apiUri = Uri.parse(_apiUrl);
      final wsUri = Uri(
        scheme: apiUri.scheme == 'https' ? 'wss' : 'ws',
        host: apiUri.host,
        path: "/ws/streams/${data['stream_id']}",
      );

      print("Overshoot: Connecting WS to $wsUri");
      
      // Pass headers here as well for auth
      _wsChannel = IOWebSocketChannel.connect(wsUri, headers: headers);
      
      // FIX: Listen BEFORE sending data to avoid race conditions
      _wsSubscription = _wsChannel!.stream.listen((message) {
        print("WS Message: $message"); // Debug log
        try {
          final res = jsonDecode(message);
          if (res.containsKey('result')) {
            resultController.add(res['result']);
          } else if (res.containsKey('error')) {
            resultController.add("Error: ${res['error']}");
          }
        } catch (e) {
          // Sometimes messages might be plain text strings
          resultController.add("Raw: $message");
        }
      }, onError: (e) {
        print("WS Error: $e");
        resultController.add("WS Error: $e");
      }, onDone: () {
        print("WS Closed");
      });

      // Send Auth Message (If required in addition to headers)
      // Note: If the headers above work, this might be optional, but we leave it for safety.
      _wsChannel!.sink.add(jsonEncode({"api_key": _apiKey}));

    } catch (e) {
      print("Overshoot Init Error: $e");
      resultController.add("Init Error: $e");
      // Clean up if init fails
      stop(); 
      rethrow;
    }

    return resultController.stream;
  }

  void stop() {
    print("Overshoot: Stopping services...");
    _wsSubscription?.cancel();
    _wsChannel?.sink.close();
    _peerConnection?.close();
    _peerConnection = null;
  }
}