import os
import asyncio
import base64
import json
import logging
import struct
import time
from unittest import result
from fastapi.websockets import WebSocketState
import requests
import dotenv
from fastapi import APIRouter, HTTPException, UploadFile, File, Query, Form, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
import cv2
import av
from aiortc import RTCPeerConnection, RTCSessionDescription, RTCIceCandidate, VideoStreamTrack
from aiortc.sdp import candidate_from_sdp
from aiortc.contrib.media import MediaRecorder

# Load environment variables from .env file
dotenv.load_dotenv(os.path.join(os.path.dirname(__file__), ".env"), override=True)

import numpy as np

from config import BASE_URL, HEADERS
from schemas import (
    PredictionTrainRequest,
    ClusteringTrainRequest,
    AnomalyTrainRequest,
    EmbeddingTrainRequest,
    InferenceRequest,
    OvershootCreateStreamRequest,
    OvershootUpdatePromptRequest,
    OvershootFeedbackRequest,
)
from RTMpose.rtmpose3d_handler import RTMPose3DHandler
import sys
from pathlib import Path

# Add OverShoot SDK to path
sys.path.insert(0, str(Path(__file__).parent.parent / "OverShoot"))

from overshoot import (
    # Exceptions
    ApiError,
    # Clients
    OvershootHttpClient,
    OvershootStreamRelay,
    # Action Detection
    ActionDetector,
    ActionDetectorConfig,
    ActionStore,
    DetectedAction,
    # Config types
    StreamProcessingConfig,
    StreamInferenceConfig,
    StreamInferenceResult,
    CameraSource,
    VideoFileSource,
)

logger = logging.getLogger(__name__)


# ============================================================================
# Health Router
# ============================================================================

health_router = APIRouter(tags=["Health"])


@health_router.get("/health")
def health_check():
    """Health check endpoint."""
    url = f"{BASE_URL}/health"
    try:
        response = requests.get(url, headers=HEADERS)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))



# ============================================================================
# Pose Processing Router
# ============================================================================

pose_router = APIRouter(prefix="/api/pose", tags=["Pose Processing"])

# Lazy-loaded handler to avoid loading models at import time
_pose_handler = None


def get_pose_handler():
    global _pose_handler
    if _pose_handler is None:
        _pose_handler = RTMPose3DHandler(device='cuda')
    return _pose_handler


@pose_router.post("/process")
async def process_video_to_angles(
    video: UploadFile = File(None),
    dataset_name: str = Query(..., description="Name for the dataset in Woodwide"),
    model_id: str = Query(..., description="Anomaly detection model ID for inference"),
    upload_to_woodwide: bool = Query(True, description="Upload angles to Woodwide"),
    overwrite: bool = Query(False, description="Overwrite existing dataset"),
    sensor_data: UploadFile = File(None, description="Sensor data JSON file"),
    overshoot_data: UploadFile = File(None, description="Overshoot data JSON file"),
    video_start_time: int = Form(None, description="Start time of the video in UTC"),
    joint_index: int = Form(0, description="Index of the joint to fuse (0=left_knee, 1=right_knee, etc.)"),
    stream_id: str = Form(None, description="Stream ID to retrieve detected actions from")
):
    print(stream_id)
    """Process video through RTMpose and run anomaly detection via Woodwide."""
    try:
        if video:
            video_bytes = await video.read()
        elif stream_id and stream_id in stream_videos:
             video_path = stream_videos[stream_id]
             if not os.path.exists(video_path):
                 raise HTTPException(status_code=404, detail="Accumulated video file not found")
             with open(video_path, "rb") as f:
                 video_bytes = f.read()
             # Cleanup later? Or keep it? keeping for now.
        else:
            raise HTTPException(status_code=400, detail="Either video file upload or valid stream_id is required")

        handler = get_pose_handler()

        # Parse sensor_data from file (JSON)
        parsed_sensor_data = None
        if sensor_data:
            try:
                content = await sensor_data.read()
                if content:
                    sensor_json_str = content.decode("utf-8")
                    parsed_sensor_data = json.loads(sensor_json_str)
                    print(f"Received sensor data with {len(parsed_sensor_data)} samples")
            except (json.JSONDecodeError, TypeError, UnicodeDecodeError) as e:
                logger.warning(f"Failed to parse sensor data file: {e}")
                parsed_sensor_data = None

        # Process video to get joint angles and CSV
        angles = []
        raw_angles = []
        imu_angles = []
        overlay_video_path = None
        alignment_debug = {}
        
        # Check if video bytes are valid (not empty)
        if video_bytes and len(video_bytes) > 100:
             try:
                # Unpack 6 values including debug_stats
                # (angles, raw_angles, imu_angles, output_2d_video_path, csv_path, alignment_debug)
                angles, raw_angles, imu_angles, overlay_video_path, csv_path, alignment_debug = handler.process_video(
                    video_bytes, 
                    parsed_sensor_data, 
                    joint_index=joint_index
                )
             except Exception as e:
                logger.error(f"Failed to process video: {e}")
                # We proceed without angles if video is bad, so we can still return actions
        else:
             logger.warning("Video file is empty or too small. Skipping pose estimation.")

        # Convert numpy values to native Python floats for JSON serialization
        import math
        def to_json_float(v):
            if v is None:
                return None
            try:
                f = float(v)
                return None if math.isnan(f) else f
            except (TypeError, ValueError):
                return None

        serializable_angles = [[to_json_float(v) for v in frame] for frame in angles]
        serializable_raw_angles = [[to_json_float(v) for v in frame] for frame in raw_angles]
        serializable_imu_angles = [[to_json_float(v) for v in frame] for frame in imu_angles]

        result = {
            "num_frames": len(angles),
            "num_angles": 6,
            "angles": serializable_angles,
            "raw_angles": serializable_raw_angles,
            "imu_angles": serializable_imu_angles,
            "joint_index": joint_index,
            "overlay_video_path": overlay_video_path,
            "debug_stats": alignment_debug, # Return debug stats
        }

        # Add detected actions if stream_id is provided
        detected_actions_result = []
        if stream_id:
            store = action_stores[stream_id] if stream_id in action_stores else None
            if store:
                actions = store.get_actions()
                detected_actions_result = [
                    {
                        "action": a.action,
                        "timestamp": a.timestamp,
                        "confidence": a.confidence,
                        "frame_number": a.frame_number,
                        "metadata": a.metadata
                    }
                    for a in actions
                ]
            else:
                 logger.warning(f"No ActionStore found for stream_id: {stream_id}")
        
        result["anomaly_detection"] = []
        result["detected_actions"] = detected_actions_result
        
        return result

    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    

@pose_router.get("/download-csv/{csv_filename}")
def download_keypoints_csv(csv_filename: str):
    """Download a previously generated keypoints CSV file."""
    import tempfile
    csv_path = os.path.join(tempfile.gettempdir(), csv_filename)
    if not os.path.exists(csv_path):
        raise HTTPException(status_code=404, detail="CSV file not found")
    return FileResponse(csv_path, media_type="text/csv", filename=csv_filename)


@pose_router.get("/streams/{stream_id}/video")
def get_stream_video(stream_id: str):
    """Get the accumulated video for a stream."""
    if stream_id not in stream_videos:
        raise HTTPException(status_code=404, detail="Stream ID not found or video not available")
    
    video_path = stream_videos[stream_id]
    if not os.path.exists(video_path):
        raise HTTPException(status_code=404, detail="Video file not found on server")
        
    return FileResponse(video_path, media_type="video/mp4", filename=f"{stream_id}.mp4")


@pose_router.get("/download-video/{video_filename}")
def download_overlay_video(video_filename: str):
    """Download a previously generated overlay video file."""
    import tempfile
    video_path = os.path.join(tempfile.gettempdir(), video_filename)
    if not os.path.exists(video_path):
        raise HTTPException(status_code=404, detail="Overlay video file not found")
    return FileResponse(video_path, media_type="video/mp4", filename=video_filename)


overshoot_router = APIRouter(prefix="/api/overshoot", tags=["Overshoot"])
_overshoot_sessions: dict[str, OvershootHttpClient] = {}
_overshoot_sessions_lock = asyncio.Lock()
# Global store for action detection results keyed by stream_id
action_stores: dict[str, ActionStore] = {}


def _overshoot_api_url() -> str:
    return os.getenv("OVERSHOOT_API_URL", "https://cluster1.overshoot.ai/api/v0.2").rstrip("/")


def _overshoot_api_key() -> str:
    api_key = os.getenv("OVERSHOOT_API_KEY", "")
    if not api_key:
        raise HTTPException(status_code=500, detail="OVERSHOOT_API_KEY is not configured")
    return api_key


@overshoot_router.post("/streams")
async def overshoot_create_stream(body: OvershootCreateStreamRequest):
    client = OvershootHttpClient(_overshoot_api_url(), _overshoot_api_key())
    processing = body.processing or StreamProcessingConfig()
    inference = StreamInferenceConfig(
        prompt=body.inference.prompt,
        model=body.inference.model,
        backend=body.inference.backend,
        output_schema_json=body.inference.output_schema_json,
    )
    try:
        resp = await client.create_stream(
            offer_sdp=body.offer_sdp,
            processing=processing,
            inference=inference,
            request_id=body.request_id,
        )
        stream_id = resp["stream_id"]
        async with _overshoot_sessions_lock:
            _overshoot_sessions[stream_id] = client
        return resp
    except ApiError as e:
        await client.close()
        raise HTTPException(status_code=e.status_code, detail=e.message)
    except Exception as e:
        logger.exception("Stream creation failed")
        await client.close()
        raise HTTPException(status_code=500, detail=str(e))


async def _get_overshoot_client(stream_id: str) -> OvershootHttpClient:
    async with _overshoot_sessions_lock:
        client = _overshoot_sessions.get(stream_id)
    if client is None:
        raise HTTPException(status_code=404, detail="Unknown stream_id")
    return client


@overshoot_router.post("/streams/{stream_id}/keepalive")
async def overshoot_keepalive(stream_id: str):
    client = await _get_overshoot_client(stream_id)
    try:
        return await client.keepalive(stream_id)
    except ApiError as e:
        raise HTTPException(status_code=e.status_code, detail=e.message)


@overshoot_router.patch("/streams/{stream_id}/prompt")
async def overshoot_update_prompt(stream_id: str, body: OvershootUpdatePromptRequest):
    client = await _get_overshoot_client(stream_id)
    try:
        return await client.update_prompt(stream_id, body.prompt)
    except ApiError as e:
        raise HTTPException(status_code=e.status_code, detail=e.message)


@overshoot_router.post("/streams/{stream_id}/feedback")
async def overshoot_feedback(stream_id: str, body: OvershootFeedbackRequest):
    client = await _get_overshoot_client(stream_id)
    try:
        return await client.submit_feedback(
            stream_id=stream_id,
            rating=body.rating,
            category=body.category,
            feedback=body.feedback,
        )
    except ApiError as e:
        raise HTTPException(status_code=e.status_code, detail=e.message)


@overshoot_router.delete("/streams/{stream_id}")
async def overshoot_close_stream(stream_id: str):
    async with _overshoot_sessions_lock:
        client = _overshoot_sessions.pop(stream_id, None)
    if client is None:
        raise HTTPException(status_code=404, detail="Unknown stream_id")
    await client.close()
    return {"ok": True}


# ============================================================================
# WebSocket Video Streaming to Overshoot
# ============================================================================

# Global registry for stream video paths
stream_videos: dict[str, str] = {}

class RelayProxyTrack(VideoStreamTrack):
    """
    Proxy track that pulls frames from an upstream track,
    forwards them to OvershootRelay (subsampled), and yields them
    downstream (e.g. to MediaRecorder).
    """
    kind = "video"

    def __init__(self, track, relay, subsample=3):
        super().__init__()
        self.track = track
        self.relay = relay
        self.subsample = subsample
        self.counter = 0
        self.start_timestamp = None

    async def recv(self):
        try:
            start_time = time.time()
            frame = await self.track.recv()
            duration = time.time() - start_time
            if duration > 1.0:
                 logger.warning(f"RelayProxyTrack ({self.track.kind}) slow recv: {duration:.3f}s")
        except Exception as e:
            # Track ended or error
            logger.info(f"RelayProxyTrack stopped: {e}")
            self.stop() 
            raise e
        
        # Forward to relay (subsampled)
        if self.counter % self.subsample == 0:
            if self.relay and self.relay.is_running:
                try:
                    # Convert AVFrame to numpy RGB24 for Overshoot
                    # This might be expensive, so we do it only for sampled frames
                    img = frame.to_ndarray(format="rgb24")
                    
                    # Calculate timestamp in seconds
                    timestamp = float(frame.pts * frame.time_base) if (frame.pts is not None and frame.time_base is not None) else None
                    
                    # Normalize timestamp relative to first frame
                    if timestamp is not None:
                        if self.start_timestamp is None:
                            self.start_timestamp = timestamp
                        timestamp = timestamp - self.start_timestamp
                    
                    # Push to relay
                    self.relay.push_frame(img, timestamp)
                except Exception as e:
                    logger.error(f"RelayProxyTrack error processing frame: {e}")

        if self.counter % 60 == 0:
             logger.info(f"RelayProxyTrack processed {self.counter} frames")

        self.counter += 1
        return frame

@overshoot_router.websocket("/ws/stream")
async def overshoot_video_websocket(websocket: WebSocket):
    """
    WebRTC Signaling WebSocket for Overshoot.
    """
    await websocket.accept()
    relay: OvershootStreamRelay = None
    pc: RTCPeerConnection = None
    recorder: MediaRecorder = None
    stream_id: str = None
    temp_video_path: str = None

    try:
        # Wait for config
        config_msg = await websocket.receive_json()
        if config_msg.get("type") != "config":
            await websocket.send_json({"type": "error", "error": "First message must be config"})
            return

        # Parse config
        inference_config = config_msg.get("inference", {})
        processing_config = config_msg.get("processing", {})

        prompt = inference_config.get("prompt", config_msg.get("prompt", "Describe what you see"))
        model = inference_config.get("model", config_msg.get("model", "gemini-2.0-flash"))
        backend = inference_config.get("backend", config_msg.get("backend", "gemini"))

        fps = processing_config.get("fps", config_msg.get("fps", 10))
        sampling_ratio = processing_config.get("sampling_ratio", config_msg.get("sampling_ratio", 0.3))
        clip_length_seconds = processing_config.get("clip_length_seconds", config_msg.get("clip_length_seconds", 5.0))
        delay_seconds = processing_config.get("delay_seconds", config_msg.get("delay_seconds", 1.0))
        
        width = config_msg.get("width", 640)
        height = config_msg.get("height", 480)

        # Initialize Relay
        store = ActionStore()
        # action_stores_lock is global, but used locally here? No, declared global at module level but referenced?
        # Actually line 687 in original file said `action_stores_lock = asyncio.Lock()`.
        # This seems to be a local variable shadowing a global if there is one, or just a local lock?
        # The global `action_stores` is used.
        # Let's keep it simple.
        
        # Initialize filtering state
        last_logged_action: str | None = None
        pending_action: str | None = None
        consecutive_count: int = 0

        # Helper to send results back
        async def send_result(result: dict):
            nonlocal last_logged_action, pending_action, consecutive_count
            try:
                # Log inference results for debugging
                if result.get("type") == "inference":
                    print(f"[WebRTC] 🧠 Inference: {result.get('result')}")
                elif result.get("type") == "error":
                     print(f"[WebRTC] ❌ Error from Overshoot: {result.get('error')}")

                if websocket.client_state == WebSocketState.CONNECTED:
                    await websocket.send_json(result)
                else:
                    # Connection closed, ignore
                    pass
                
                # Action Detection Logic Integration
                if result.get("type") == "inference":
                    inference_data = result.get("result", {})
                    # Parse JSON string if needed
                    if isinstance(inference_data, str):
                        try:
                            parsed = json.loads(inference_data)
                            if isinstance(parsed, (dict, list)): inference_data = parsed
                        except: pass
                    
                    detected_list = []
                    if isinstance(inference_data, dict):
                        detected_list = inference_data.get("detected_actions", [])
                    elif isinstance(inference_data, str) and inference_data.strip():
                        detected_list = [{"action": inference_data.strip(), "detected": True, "confidence": 0.8}]
                    
                    # Find the best action (highest confidence > 0.6)
                    candidates = []
                    for act in detected_list:
                         if act.get("detected") and act.get("confidence", 0) > 0.6:
                             candidates.append(act)
                    
                    current_best_action = None
                    current_best_data = None
                    
                    if candidates:
                        # Pick best by confidence
                        candidates.sort(key=lambda x: x.get("confidence", 0), reverse=True)
                        current_best_data = candidates[0]
                        current_best_action = current_best_data.get("action")
                    
                    # Smoothing Logic (Debounce)
                    # We require the SAME action to be detected for 3 consecutive frames
                    if current_best_action == pending_action:
                        consecutive_count += 1
                    else:
                        pending_action = current_best_action
                        consecutive_count = 1
                    
                    # Threshold Check
                    if consecutive_count >= 2:
                         # The pending action is now CONFIRMED
                         confirmed_action = pending_action
                         
                         # Deduplication: Only log if this confirmed action is DIFFERENT from the last logged one
                         if confirmed_action != last_logged_action:
                             last_logged_action = confirmed_action
                             print(f"[ActionLog] Action confirmed & changed to: {last_logged_action}")
                             
                             if confirmed_action is not None and current_best_data:
                                   import time
                                   ts = result.get("timestamp", time.time())
                                   # Estimate local frame number (approximate)
                                   frame_num = int(ts * fps) if isinstance(ts, (int, float)) and ts > 0 else 0
                                   
                                   store.add(DetectedAction(
                                       action=confirmed_action,
                                       timestamp=ts,
                                       frame_number=frame_num,
                                       confidence=current_best_data.get("confidence", 0.8),
                                       metadata={"raw": str(current_best_data)}
                                   )) 

            except Exception as e:
                # Swallow errors if we are shutting down or socket is closed
                if "websocket.send" in str(e) or "closed" in str(e):
                    pass
                else:
                    logger.error(f"Send result error: {e}")

        # Prepare Relay (sync initialization of queues and local PC)
        relay = OvershootStreamRelay(
            api_url=_overshoot_api_url(),
            api_key=_overshoot_api_key(),
            prompt=prompt,
            on_result=lambda r: asyncio.create_task(send_result(r)),
            model=model,
            backend=backend,
            width=width,
            height=height,
            fps=fps,
            sampling_ratio=sampling_ratio, 
            clip_length_seconds=clip_length_seconds,
            delay_seconds=delay_seconds,
        )
        
        await relay.prepare()
        
        # Prepare MediaRecorder
        import tempfile
        tfile = tempfile.NamedTemporaryFile(delete=False, suffix='.mp4')
        tfile.close() # Close so recorder can open
        temp_video_path = tfile.name
        # Note: stream_id is not yet available, use temporary key or handle later.
        # But we need to store it so process endpoint can find it.
        # We will update stream_videos once we have stream_id.
        
        recorder = MediaRecorder(temp_video_path)
        
        # Initialize WebRTC (Local PC)
        pc = RTCPeerConnection()
        
        @pc.on("icecandidate")
        async def on_icecandidate(candidate):
            # print("ICE")
            # Send candidate to client
            if candidate:
                msg = {
                    "type": "candidate", 
                    "candidate": candidate.candidate, 
                    "sdpMid": candidate.sdpMid, 
                    "sdpMLineIndex": candidate.sdpMLineIndex
                }
                await websocket.send_json(msg)

        @pc.on("track")
        def on_track(track):
            print("TRACK")
            if track.kind == "video":
                print(f"[WebRTC] Video track received: {track.kind}")
                # Create proxy track
                proxy = RelayProxyTrack(track, relay, subsample=1) 
                recorder.addTrack(proxy)

        @pc.on("connectionstatechange")
        async def on_connectionstatechange():
            print(f"[WebRTC] Connection state: {pc.connectionState}")
            if pc.connectionState == "failed":
                await pc.close()

        # Send Ready IMMEDIATELY to unblock client
        # Stream ID is not yet available, client should handle null stream_id or wait for 'stream_created'
        await websocket.send_json({"type": "ready", "stream_id": None})

        # Start Relay Connect in Background
        async def connect_relay_task():
            nonlocal stream_id
            try:
                stream_id = await relay.connect()
                # Store action store
                action_stores[stream_id] = store
                # Video path mapping is now done in finally block
                print(f"[WebRTC] ☁️ Stream created on Overshoot: {stream_id}")
                
                # Notify client
                if websocket.client_state == WebSocketState.CONNECTED:
                    await websocket.send_json({"type": "stream_created", "stream_id": stream_id})
            except Exception as e:
                logger.error(f"[WebRTC] Failed to connect relay: {e}")
                if websocket.client_state == WebSocketState.CONNECTED:
                    await websocket.send_json({"type": "error", "error": f"Cloud connection failed: {e}"})

        asyncio.create_task(connect_relay_task())

        # Main Loop
        async for message_str in websocket.iter_text():
            try:
                msg = json.loads(message_str)
                msg_type = msg.get("type")
                
                if msg_type == "offer":
                    offer = RTCSessionDescription(sdp=msg["sdp"], type="offer")
                    await pc.setRemoteDescription(offer)
                    
                    # Start recorder after track is set up
                    await recorder.start()
                    
                    answer = await pc.createAnswer()
                    await pc.setLocalDescription(answer)
                    
                    await websocket.send_json({
                        "type": "answer",
                        "sdp": pc.localDescription.sdp
                    })
                
                elif msg_type == "candidate":
                    cand_str = msg["candidate"]
                    if cand_str.startswith("candidate:"):
                        cand_str = cand_str.split(":", 1)[1].strip()
                    
                    candidate = candidate_from_sdp(cand_str)
                    candidate.sdpMid = msg["sdpMid"]
                    candidate.sdpMLineIndex = msg["sdpMLineIndex"]
                    
                    await pc.addIceCandidate(candidate)
                    
                elif msg_type == "stop":
                    break
                
                elif msg_type == "update_prompt":
                     await relay.update_prompt(msg["prompt"])
                     
            except Exception as e:
                logger.error(f"Error handling message: {e}")
                pass

    except WebSocketDisconnect:
        print("[WebRTC] Client disconnected")
    except Exception as e:
        print(f"WebRTC Error: {e}")
        try:
            if websocket.client_state == WebSocketState.CONNECTED:
                await websocket.send_json({"type": "error", "error": str(e)})
        except: pass
    finally:
        # Cleanup
        print("[WebRTC] 🧹 Cleaning up resources...")

        # 1. Stop Recorder
        if recorder:
            try:
                await recorder.stop()
                print("[WebRTC] ⏹️ Recorder stopped")
                
                # Register video path ONLY after recorder is fully stopped
                if stream_id:
                     stream_videos[stream_id] = temp_video_path
                     print(f"[WebRTC] 💾 Video ready for stream {stream_id}")
                     
                     # Notify client that recording is finished and video is ready
                     if websocket.client_state == WebSocketState.CONNECTED:
                        await websocket.send_json({
                            "type": "stopped", 
                            "stream_id": stream_id
                        })
            except Exception as e:
                logger.error(f"[WebRTC] ⚠️ Recorder stop failed: {e}")
            finally:
                recorder = None

        # 2. Stop Relay
        if relay:
            try:
                await relay.stop()
                print("[WebRTC] 🛑 Relay stopped")
            except Exception as e:
                logger.error(f"[WebRTC] ⚠️ Relay stop error: {e}")

        # 3. Stop PC
        if pc:
            try:
                # Stop transceivers
                for transceiver in pc.getTransceivers():
                    if transceiver.sender and transceiver.sender.track: 
                         try:
                             transceiver.sender.track.stop()
                         except: pass
                
                await pc.close()
                print("[WebRTC] 🔌 PeerConnection closed")
            except Exception as e:
                logger.error(f"[WebRTC] PeerConnection close error: {e}")
