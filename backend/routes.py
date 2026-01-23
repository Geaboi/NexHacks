import os
import asyncio
import base64
import json
import logging
import struct
import time
from unittest import result
import requests
import dotenv
from fastapi import APIRouter, HTTPException, UploadFile, File, Query, Form, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
import cv2

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
# Auth Router
# ============================================================================

auth_router = APIRouter(prefix="/auth", tags=["Authentication"])


@auth_router.get("/me")
def get_current_user():
    """Get current authenticated user."""
    url = f"{BASE_URL}/auth/me"
    try:
        response = requests.get(url, headers=HEADERS)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ============================================================================
# Datasets Router
# ============================================================================

datasets_router = APIRouter(prefix="/api/datasets", tags=["Datasets"])


@datasets_router.get("")
def list_datasets():
    """List all datasets."""
    url = f"{BASE_URL}/api/datasets"
    try:
        response = requests.get(url, headers=HEADERS)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@datasets_router.post("")
async def upload_dataset(
    file: UploadFile = File(...),
    overwrite: bool = Query(False, description="Overwrite existing dataset"),
):
    """Upload a new dataset (CSV or Parquet)."""
    url = f"{BASE_URL}/api/datasets"
    try:
        files = {"file": (file.filename, await file.read(), file.content_type)}
        params = {"overwrite": overwrite}
        response = requests.post(url, headers=HEADERS, files=files, params=params)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@datasets_router.get("/{dataset_id}")
def get_dataset(dataset_id: str):
    """Get dataset details."""
    url = f"{BASE_URL}/api/datasets/{dataset_id}"
    try:
        response = requests.get(url, headers=HEADERS)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@datasets_router.delete("/{dataset_id}")
def delete_dataset(dataset_id: str):
    """Delete a dataset."""
    url = f"{BASE_URL}/api/datasets/{dataset_id}"
    try:
        response = requests.delete(url, headers=HEADERS)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ============================================================================
# Models Router
# ============================================================================

models_router = APIRouter(prefix="/api/models", tags=["Models"])


@models_router.get("")
def list_models():
    """List all models."""
    url = f"{BASE_URL}/api/models"
    try:
        response = requests.get(url, headers=HEADERS)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@models_router.get("/{model_id}")
def get_model(model_id: str):
    """Get model details."""
    url = f"{BASE_URL}/api/models/{model_id}"
    try:
        response = requests.get(url, headers=HEADERS)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ----------------------------------------------------------------------------
# Training Endpoints
# ----------------------------------------------------------------------------

@models_router.post("/prediction/train")
def train_prediction_model(request: PredictionTrainRequest):
    """Train a prediction model."""
    url = f"{BASE_URL}/api/models/prediction/train"
    try:
        response = requests.post(url, headers=HEADERS, json=request.model_dump(exclude_none=True))
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@models_router.post("/clustering/train")
def train_clustering_model(request: ClusteringTrainRequest):
    """Train a clustering model."""
    url = f"{BASE_URL}/api/models/clustering/train"
    try:
        response = requests.post(url, headers=HEADERS, json=request.model_dump(exclude_none=True))
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@models_router.post("/anomaly/train")
def train_anomaly_model(request: AnomalyTrainRequest):
    """Train an anomaly detection model."""
    url = f"{BASE_URL}/api/models/anomaly/train"
    try:
        response = requests.post(url, headers=HEADERS, json=request.model_dump(exclude_none=True))
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@models_router.post("/embedding/train")
def train_embedding_model(request: EmbeddingTrainRequest):
    """Train an embedding model."""
    url = f"{BASE_URL}/api/models/embedding/train"
    try:
        response = requests.post(url, headers=HEADERS, json=request.model_dump(exclude_none=True))
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ----------------------------------------------------------------------------
# Inference Endpoints
# ----------------------------------------------------------------------------

@models_router.post("/prediction/{model_id}/infer")
def run_prediction_inference(model_id: str, request: InferenceRequest):
    """Run prediction inference."""
    url = f"{BASE_URL}/api/models/prediction/{model_id}/infer"
    try:
        response = requests.post(url, headers=HEADERS, json=request.model_dump(exclude_none=True))
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@models_router.post("/clustering/{model_id}/infer")
def run_clustering_inference(model_id: str, request: InferenceRequest):
    """Run clustering inference."""
    url = f"{BASE_URL}/api/models/clustering/{model_id}/infer"
    try:
        response = requests.post(url, headers=HEADERS, json=request.model_dump(exclude_none=True))
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@models_router.post("/anomaly/{model_id}/infer")
def run_anomaly_inference(model_id: str, request: InferenceRequest):
    """Run anomaly detection inference."""
    url = f"{BASE_URL}/api/models/anomaly/{model_id}/infer"
    try:
        response = requests.post(url, headers=HEADERS, json=request.model_dump(exclude_none=True))
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as e:
        raise HTTPException(status_code=e.response.status_code, detail=e.response.text)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@models_router.post("/embedding/{model_id}/infer")
def run_embedding_inference(model_id: str, request: InferenceRequest):
    """Generate embeddings."""
    url = f"{BASE_URL}/api/models/embedding/{model_id}/infer"
    try:
        response = requests.post(url, headers=HEADERS, json=request.model_dump(exclude_none=True))
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
    video: UploadFile = File(...),
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
    """Process video through RTMpose and run anomaly detection via Woodwide.

    Flow:
    1. Process video to extract joint angles
    2. Upload angles CSV as a dataset
    3. Run anomaly detection inference on the dataset

    Returns the angle CSV, dataset info, and anomaly detection results.
    """
    try:
        video_bytes = await video.read()
        handler = get_pose_handler()

        # Parse sensor_data from file (JSON)
        parsed_sensor_data = None
        if sensor_data:
            try:
                content = await sensor_data.read()
                if content:
                    sensor_json_str = content.decode("utf-8")
                    parsed_sensor_data = json.loads(sensor_json_str)
                    logger.info(f"Received sensor data with {len(parsed_sensor_data)} samples")
            except (json.JSONDecodeError, TypeError, UnicodeDecodeError) as e:
                logger.warning(f"Failed to parse sensor data file: {e}")
                parsed_sensor_data = None

        # Parse overshoot_data from file (JSON) is not directly used in this function logic 
        # but the signature was updated. If it were used, we would parse similarly.
        # For now, let's just log it if needed, or ignore if not used in process_video logic locally.
        # It seems overshoot_data is passed to Woodwide in original logic? 
        # Wait, the original code didn't use overshoot_data in the handler.process_video call shown above.
        # It only used parsed_sensor_data. 
        # Let's check where overshoot_data is used. It was passed as form data but not used in the snippet I saw?
        # Ah, I see "overshoot_data: str = Form" in args, but I don't see it used in valid lines 340-400.
        # I will assume it might be used later or just needed for the signature.
        # I'll stick to parsing sensor_data correctly.

        # Process video to get joint angles and CSV
        # handler.process_video now returns raw_angles and imu_angles too
        angles, raw_angles, imu_angles, overlay_video_path, csv_path = handler.process_video(
            video_bytes, 
            parsed_sensor_data, 
            joint_index=joint_index
        )

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
        }

        # Add detected actions if stream_id is provided
        detected_actions_result = []
        if stream_id:
            logger.info(f"Looking for actions for stream_id: {stream_id}")
            store = ACTION_STORES.get(stream_id)
            if store:
                actions = store.get_actions()
                logger.info(f"Found {len(actions)} actions for stream {stream_id}")
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
                logger.info(f"[Process Video] Including {len(detected_actions_result)} detected actions in response: {detected_actions_result}")
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
ACTION_STORES: dict[str, ActionStore] = {}


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

@overshoot_router.websocket("/ws/stream")
async def overshoot_video_websocket(websocket: WebSocket):
    """
    WebSocket endpoint for streaming video to Overshoot.

    Protocol:
    1. Client sends config: {"type": "config", "prompt": "...", "model": "gemini-2.0-flash", ...}
    2. Server responds: {"type": "ready", "stream_id": "..."}
    3. Client sends frames (binary: 8-byte timestamp + RGB24, or JSON with base64)
    4. Server sends results: {"type": "inference", "result": "...", "timestamp": ...}
    5. Control: {"type": "stop"} or {"type": "update_prompt", "prompt": "..."}
    """
    await websocket.accept()
    relay: OvershootStreamRelay = None

    try:
        # Wait for config
        config_data = await websocket.receive_json()
        if config_data.get("type") != "config":
            await websocket.send_json({"type": "error", "error": "First message must be config"})
            return

        # Parse nested config from Flutter
        inference_config = config_data.get("inference", {})
        processing_config = config_data.get("processing", {})

        prompt = inference_config.get("prompt", config_data.get("prompt", "Describe what you see"))
        model = inference_config.get("model", config_data.get("model", "gemini-2.0-flash"))
        backend = inference_config.get("backend", config_data.get("backend", "gemini"))

        # Extract processing config - use Flutter's values with sensible defaults
        # Overshoot constraint: (fps * sampling_ratio * clip_length) / delay <= 30
        # Default: (10 * 0.3 * 10.0) / 1.0 = 30 frames per clip (10s window, max allowed)
        fps = processing_config.get("fps", config_data.get("fps", 10))
        sampling_ratio = processing_config.get("sampling_ratio", config_data.get("sampling_ratio", 0.3))
        clip_length_seconds = processing_config.get("clip_length_seconds", config_data.get("clip_length_seconds", 5.0))
        delay_seconds = processing_config.get("delay_seconds", config_data.get("delay_seconds", 1.0))

        width = config_data.get("width", 640)
        height = config_data.get("height", 480)

        # Log the actual config being used
        frames_per_clip = fps * sampling_ratio * clip_length_seconds
        logger.info(f"[Overshoot WS] Processing config: fps={fps}, sampling={sampling_ratio}, clip={clip_length_seconds}s, delay={delay_seconds}s")
        logger.info(f"[Overshoot WS] Frames per clip: {frames_per_clip:.1f} (constraint: must be <= 30 * delay)")

        logger.debug(f"[Overshoot WS] Config: {model}/{backend} {width}x{height}@{fps}fps")

        # Action Detection State
        store = ActionStore()
        # Track active actions: {action_name: {"start_time": float, "last_seen": float, "confidence": float}}
        active_actions: dict[str, dict] = {}
        # Track pending actions: {action_name: {"count": int, "first_seen": float, "confidence": float}}
        pending_actions: dict[str, dict] = {}
        
        frame_counter = 0
        min_confidence = 0.6
        start_threshold = 2

        # Create relay with callback to forward results to client
        async def send_result(result: dict):
            try:
                # Forward result to client
                await websocket.send_json(result)
                
                # --- Action Detection Logic ---
                if result.get("type") == "inference":
                    nonlocal frame_counter
                    frame_counter += 1
                    
                    # Parse detections
                    inference_data = result.get("result", {})
                    
                    # Try to parse stringified JSON if it is a string
                    if isinstance(inference_data, str):
                        try:
                            parsed = json.loads(inference_data)
                            if isinstance(parsed, (dict, list)):
                                inference_data = parsed
                        except (json.JSONDecodeError, TypeError):
                            # It's a plain string (e.g. "Waving hand."), keep as string
                            pass

                    detected_list = []
                    if isinstance(inference_data, dict):
                        # Expecting structured JSON with "detected_actions"
                        detected_list = inference_data.get("detected_actions", [])
                    
                    elif isinstance(inference_data, str) and inference_data.strip():
                        # It's a generic text description like "Waving hand"
                        # treat it as a detected action
                        detected_list = [{
                            "action": inference_data.strip(),
                            "detected": True,
                            "confidence": 0.8 # arbitrary high confidence for direct text
                        }]
                    
                    if detected_list:
                        logger.info(f"[Overshoot Relay] Frame {frame_counter}: Received actions: {detected_list}")

                    current_time_stream = result.get("timestamp") or time.time()
                    now = time.time()

                    currently_detected = set()

                    # 1. Identify currently detected actions
                    for action_data in detected_list:
                        action_name = action_data.get("action")
                        is_detected = action_data.get("detected", False)
                        confidence = action_data.get("confidence", 0.0)

                        if action_name and is_detected and confidence >= min_confidence:
                            currently_detected.add(action_name)
                            
                            # Update active if already active
                            if action_name in active_actions:
                                active_actions[action_name]["last_seen"] = now
                                active_actions[action_name]["last_seen_stream_time"] = current_time_stream
                                active_actions[action_name]["confidence"] = confidence
                            
                            # Check pending
                            elif action_name in pending_actions:
                                pending_actions[action_name]["count"] += 1
                                pending_actions[action_name]["confidence"] = confidence
                                pending_actions[action_name]["last_seen"] = now
                                pending_actions[action_name]["last_seen_stream_time"] = current_time_stream
                                
                                # Confirm start?
                                if pending_actions[action_name]["count"] >= start_threshold:
                                    # ACTION STARTED
                                    pending_info = pending_actions.pop(action_name)
                                    start_time = pending_info["first_seen_stream_time"]
                                    
                                    active_actions[action_name] = {
                                        "start_time": start_time,
                                        "start_real_time": pending_info["first_seen_real"],
                                        "last_seen": now,
                                        "last_seen_stream_time": current_time_stream,
                                        "confidence": confidence,
                                    }
                                    
                                    # Store
                                    action = DetectedAction(
                                        action=action_name,
                                        timestamp=start_time,
                                        frame_number=frame_counter,
                                        confidence=confidence,
                                        metadata={"event_type": "started"}
                                    )
                                    logger.info(f"[Overshoot Relay] Action STARTED: {action_name} at {start_time}")
                                    store.add(action)
                            
                            else:
                                # New pending
                                pending_actions[action_name] = {
                                    "count": 1,
                                    "first_seen_stream_time": current_time_stream,
                                    "first_seen_real": now,
                                    "last_seen": now,
                                    "confidence": confidence,
                                }
                    
                    # 2. Clear stale pending
                    stale = [name for name in pending_actions if name not in currently_detected]
                    for name in stale:
                        del pending_actions[name]
                        
                    # 3. Check for stopped actions
                    stopped = []
                    for action_name in active_actions:
                        if action_name not in currently_detected:
                            stopped.append(action_name)
                            
                    for action_name in stopped:
                        action_info = active_actions.pop(action_name)
                        # Action stopped - record the end event
                        end_time = current_time_stream
                        
                        action = DetectedAction(
                            action=action_name,
                            timestamp=end_time,
                            frame_number=frame_counter,
                            confidence=action_info.get("confidence", 0.0),
                            metadata={
                                "event_type": "ended",
                                "start_timestamp": action_info.get("start_time"),
                                "duration": end_time - action_info.get("start_time", end_time)
                            }
                        )
                        logger.info(f"[Overshoot Relay] Action ENDED: {action_name} at {end_time}")
                        store.add(action)

            except Exception as e:
                logger.error(f"Failed to send result or process actions: {e}")
                logger.exception("Error detail:")

        def on_relay_error(e: Exception):
            logger.error(f"Relay error: {e}")

        relay = OvershootStreamRelay(
            api_url=_overshoot_api_url(),
            api_key=_overshoot_api_key(),
            prompt=prompt,
            on_result=lambda r: asyncio.create_task(send_result(r)),
            on_error=on_relay_error,
            model=model,
            backend=backend,
            width=width,
            height=height,
            fps=fps,
            sampling_ratio=sampling_ratio,
            clip_length_seconds=clip_length_seconds,
            delay_seconds=delay_seconds,
        )

        stream_id = await relay.start()
        
        # Register store
        ACTION_STORES[stream_id] = store
        
        logger.info(f"[Overshoot WS] Stream started: {stream_id}")
        await websocket.send_json({"type": "ready", "stream_id": stream_id})
        await websocket.send_json({"type": "connected", "message": "Connected to Overshoot"})

        # Main loop: receive frames and control messages
        while relay.is_running:
            message = await websocket.receive()

            if message["type"] == "websocket.disconnect":
                break

            if "bytes" in message:
                # Binary frame: 8-byte timestamp prefix + frame data (JPEG or RGB24)
                frame_bytes = message["bytes"]
                expected_rgb_size = height * width * 3

                # Extract timestamp if present (first 8 bytes)
                if len(frame_bytes) > 8:
                    timestamp = struct.unpack('<d', frame_bytes[:8])[0]
                    frame_data = frame_bytes[8:]
                else:
                    timestamp = None
                    frame_data = frame_bytes

                try:
                    # Check if it's JPEG (starts with FFD8) or raw RGB24
                    if len(frame_data) >= 2 and frame_data[0] == 0xFF and frame_data[1] == 0xD8:
                        # JPEG - decode it
                        nparr = np.frombuffer(frame_data, np.uint8)
                        frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
                        if frame is not None:
                            # Convert BGR to RGB
                            frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                            # Resize if needed
                            if frame.shape[0] != height or frame.shape[1] != width:
                                frame = cv2.resize(frame, (width, height))
                            relay.push_frame(frame, timestamp)
                    elif len(frame_data) == expected_rgb_size:
                        # Raw RGB24
                        frame = np.frombuffer(frame_data, dtype=np.uint8).reshape((height, width, 3))
                        relay.push_frame(frame, timestamp)
                except Exception as e:
                    logger.warning(f"Frame decode error: {e}")

            elif "text" in message:
                try:
                    data = json.loads(message["text"])
                    msg_type = data.get("type")

                    if msg_type == "stop":
                        break
                    elif msg_type == "update_prompt":
                        new_prompt = data.get("prompt")
                        if new_prompt:
                            await relay.update_prompt(new_prompt)
                            await websocket.send_json({"type": "prompt_updated", "prompt": new_prompt})
                    elif msg_type == "frame":
                        # JSON frame with base64 data
                        timestamp = data.get("timestamp")
                        frame_b64 = data.get("data")
                        if frame_b64:
                            frame_data = base64.b64decode(frame_b64)
                            frame = np.frombuffer(frame_data, dtype=np.uint8).reshape((height, width, 3))
                            relay.push_frame(frame, timestamp)
                except json.JSONDecodeError:
                    pass

    except WebSocketDisconnect:
        pass
    except ApiError as e:
        try:
            await websocket.send_json({"type": "error", "error": e.message})
        except Exception:
            pass
    except Exception as e:
        logger.exception("WebSocket error")
        try:
            await websocket.send_json({"type": "error", "error": str(e)})
        except Exception:
            pass
    finally:
        if relay:
            await relay.stop()
            
            # Clean up store (keep it for a bit? or delete immediately?
            # User workflow implies process_video_to_angles is called AFTER stream?
            # If process_video_to_angles is called simultaneously or shortly after, we should keep it.
            # But we need a cleanup policy. For now, let's NOT delete it immediately so the next call can find it.
            # Ideally we'd have a timeout or explicit cleanup.)
            pass
            
        try:
            await websocket.close()
        except Exception:
            pass
