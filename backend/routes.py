import os
import asyncio
import base64
import json
import logging
import struct
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
    sensor_data: str = Form("", description="Sensor data associated with the video"),
    overshoot_data: str = Form("", description="Overshoot data associated with the video"),
    video_start_time: int = Form(None, description="Start time of the video in UTC")

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

        # Parse sensor_data from JSON string to list
        parsed_sensor_data = None
        if sensor_data:
            try:
                parsed_sensor_data = json.loads(sensor_data)
            except (json.JSONDecodeError, TypeError):
                parsed_sensor_data = None

        # Process video to get joint angles and CSV
        angles, overlay_video_path, csv_path = handler.process_video(video_bytes, parsed_sensor_data)

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

        result = {
            "num_frames": len(angles),
            "num_angles": 6,
            "angles": serializable_angles,
            "overlay_video_path": overlay_video_path,
        }

        result["anomaly_detection"] = []

        
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


def _overshoot_api_url() -> str:
    return os.getenv("OVERSHOOT_API_URL", "https://cluster1.overshoot.ai/api/v0.2").rstrip("/")


def _overshoot_api_key() -> str:
    api_key = os.getenv("OVERSHOOT_API_KEY", "")
    if not api_key:
        raise HTTPException(status_code=500, detail="OVERSHOOT_API_KEY is not configured")
    return api_key


@overshoot_router.post("/streams")
async def overshoot_create_stream(body: OvershootCreateStreamRequest):
    logger.info(f"[Overshoot] Creating stream with model={body.inference.model}, backend={body.inference.backend}")
    logger.debug(f"[Overshoot] Prompt: {body.inference.prompt[:100]}...")
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
        logger.info(f"[Overshoot] Stream created successfully: {stream_id}")
        logger.debug(f"[Overshoot] Create stream response: {resp}")
        async with _overshoot_sessions_lock:
            _overshoot_sessions[stream_id] = client
        return resp
    except ApiError as e:
        logger.error(f"[Overshoot] API error creating stream: {e.status_code} - {e.message}")
        await client.close()
        raise HTTPException(status_code=e.status_code, detail=e.message)
    except Exception as e:
        logger.error(f"[Overshoot] Unexpected error creating stream: {type(e).__name__}: {e}", exc_info=True)
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

        fps = processing_config.get("fps", config_data.get("fps", 15))
        sampling_ratio = processing_config.get("sampling_ratio", 0.8)
        clip_length_seconds = processing_config.get("clip_length_seconds", 0.5)
        delay_seconds = processing_config.get("delay_seconds", 0.5)

        width = config_data.get("width", 640)
        height = config_data.get("height", 480)
        
        # Extract processing config from frontend (with defaults for faster inference)
        processing_config = config_data.get("processing", {})
        sampling_ratio = processing_config.get("sampling_ratio", 1.0)
        clip_length_seconds = processing_config.get("clip_length_seconds", 1.0)
        delay_seconds = processing_config.get("delay_seconds", 1.0)

        logger.info(f"[Overshoot WS Stream] Config: model={model}, backend={backend}, fps={fps}, size={width}x{height}")
        logger.info(f"[Overshoot WS Stream] Processing: sampling={sampling_ratio}, clip={clip_length_seconds}s, delay={delay_seconds}s")

        # Create relay with callback to forward results to client
        async def send_result(result: dict):
            print(f"[Overshoot] 📥 RESULT FROM OVERSHOOT: {result}")
            try:
                await websocket.send_json(result)
            except Exception as e:
                print(f"[Overshoot] Failed to send result: {e}")

        def on_relay_error(e: Exception):
            print(f"[Overshoot] ❌ RELAY ERROR: {e}")

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

        logger.info("[Overshoot] 🚀 Calling relay.start()...")
        stream_id = await relay.start()
        logger.info(f"[Overshoot] ✅ Relay started with stream_id: {stream_id}")
        await websocket.send_json({"type": "ready", "stream_id": stream_id})
        await websocket.send_json({"type": "connected", "message": "Connected to Overshoot"})

        # Main loop: receive frames and control messages
        while relay.is_running:
            message = await websocket.receive()

            if message["type"] == "websocket.disconnect":
                break

            if "bytes" in message:
                # Binary frame: optional 8-byte timestamp prefix + RGB24 data
                frame_bytes = message["bytes"]
                expected_size = height * width * 3

                if len(frame_bytes) == expected_size + 8:
                    timestamp = struct.unpack('<d', frame_bytes[:8])[0]
                    frame_data = frame_bytes[8:]
                else:
                    timestamp = None
                    frame_data = frame_bytes

                try:
                    frame = np.frombuffer(frame_data, dtype=np.uint8).reshape((height, width, 3))
                    relay.push_frame(frame, timestamp)
                except (ValueError, struct.error) as e:
                    print(f"[Backend] ❌ Invalid frame: {e}")

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
        logger.info("[Overshoot] Client disconnected")
    except ApiError as e:
        logger.error(f"[Overshoot] API error: {e.status_code} - {e.message}")
        try:
            await websocket.send_json({"type": "error", "error": e.message})
        except Exception:
            pass
    except Exception as e:
        logger.exception(f"[Overshoot] Error: {e}")
        try:
            await websocket.send_json({"type": "error", "error": str(e)})
        except Exception:
            pass
    finally:
        if relay:
            await relay.stop()
        try:
            await websocket.close()
        except Exception:
            pass
