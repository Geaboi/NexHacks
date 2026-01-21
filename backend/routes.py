import os
import asyncio
import base64
import json
import logging
import struct
import requests
import dotenv
from fastapi import APIRouter, HTTPException, UploadFile, File, Query, Form, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
import cv2

# Load environment variables from .env file
dotenv.load_dotenv(os.path.join(os.path.dirname(__file__), ".env"), override=True)

import aiohttp
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack, RTCConfiguration, RTCIceServer
from av import VideoFrame
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
from overshoot_client import (
    ApiError,
    OvershootHttpClient,
    StreamInferenceConfig,
    StreamProcessingConfig,
    DEFAULT_ICE_SERVERS,
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

        if upload_to_woodwide:
            # Step 1: Upload the CSV as a dataset
            upload_url = f"{BASE_URL}/api/datasets"
            with open(csv_path, "rb") as f:
                files = {"file": (f"{dataset_name}.csv", f, "text/csv")}
                params = {"overwrite": overwrite}
                data = {"name": dataset_name}
                upload_response = requests.post(upload_url, headers=HEADERS, files=files, params=params, data=data)
                upload_response.raise_for_status()
                dataset_info = upload_response.json()
                result["dataset"] = dataset_info

            # Step 2: Run anomaly detection inference using the uploaded dataset
            infer_url = f"{BASE_URL}/api/models/anomaly/1OZUO0uahYoua8SklFmr/infer"
            infer_params = {"dataset_name": dataset_name}
            infer_data = {"coerce_schema": True}
            infer_response = requests.post(
                infer_url,
                headers=HEADERS,
                params=infer_params,
                data=infer_data
            )
            infer_response.raise_for_status()
            result["anomaly_detection"] = infer_response.json()

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

class QueuedVideoTrack(VideoStreamTrack):
    """
    A video track that receives frames from an asyncio queue.
    Frames should be numpy arrays in RGB format (H, W, 3).
    """

    kind = "video"

    def __init__(self, frame_queue: asyncio.Queue, width: int = 640, height: int = 480):
        super().__init__()
        self._queue = frame_queue
        self._width = width
        self._height = height
        self._frame_count = 0

    async def recv(self) -> VideoFrame:
        pts, time_base = await self.next_timestamp()

        # Wait for a frame from the queue (with timeout to avoid blocking forever)
        try:
            frame_data = await asyncio.wait_for(self._queue.get(), timeout=1.0)
        except asyncio.TimeoutError:
            # Return a black frame if no data received
            frame_data = np.zeros((self._height, self._width, 3), dtype=np.uint8)

        # Convert numpy array to VideoFrame
        video_frame = VideoFrame.from_ndarray(frame_data, format="rgb24")
        video_frame.pts = pts
        video_frame.time_base = time_base

        self._frame_count += 1
        return video_frame


async def _listen_overshoot_ws(
    ws_url: str,
    api_key: str,
    cookies: dict,
    client_ws: WebSocket,
    stop_event: asyncio.Event,
    timestamp_state: dict,
):
    """
    Connect to Overshoot WebSocket and forward inference results to the client.
    Includes the latest frame timestamp in all inference responses.
    """
    logger.info(f"[Overshoot WS] Connecting to: {ws_url}")
    headers = {"Authorization": f"Bearer {api_key}"}
    if cookies:
        cookie_str = "; ".join(f"{k}={v}" for k, v in cookies.items())
        headers["Cookie"] = cookie_str
        logger.debug(f"[Overshoot WS] Using cookies: {list(cookies.keys())}")

    async with aiohttp.ClientSession() as session:
        try:
            async with session.ws_connect(ws_url, headers=headers) as ws:
                # Send authentication message
                auth_msg = json.dumps({"api_key": api_key})
                await ws.send_str(auth_msg)
                logger.info("[Overshoot WS] Sent authentication message")

                # Notify client that we're connected
                await client_ws.send_json({"type": "connected", "message": "Connected to Overshoot"})
                logger.info("[Overshoot WS] Connected successfully")

                async for msg in ws:
                    if stop_event.is_set():
                        logger.info("[Overshoot WS] Stop event set, exiting")
                        break

                    if msg.type == aiohttp.WSMsgType.TEXT:
                        logger.info(f"[Overshoot WS] Raw message received: {msg.data[:500] if len(msg.data) > 500 else msg.data}")
                        try:
                            data = json.loads(msg.data)
                            logger.info(f"[Overshoot WS] Parsed data keys: {list(data.keys()) if isinstance(data, dict) else type(data)}")
                            # Get current timestamp to include in response
                            current_ts = timestamp_state.get("latest")
                            # Forward inference results to client
                            if data.get("error"):
                                logger.error(f"[Overshoot WS] Error from Overshoot: {data['error']}")
                                await client_ws.send_json({"type": "error", "error": data["error"], "timestamp": current_ts})
                            elif "result" in data:
                                logger.info(f"[Overshoot WS] Result received: {str(data['result'])[:200]}")
                                await client_ws.send_json({"type": "inference", "result": data["result"], "timestamp": current_ts})
                            elif "inference" in data:
                                result = data["inference"].get("result", data["inference"])
                                logger.info(f"[Overshoot WS] Inference received: {str(result)[:200]}")
                                await client_ws.send_json({"type": "inference", "result": result, "timestamp": current_ts})
                            else:
                                logger.info(f"[Overshoot WS] Other message type: {data}")
                                await client_ws.send_json({"type": "message", "data": data, "timestamp": current_ts})
                        except json.JSONDecodeError as e:
                            logger.warning(f"[Overshoot WS] JSON decode error: {e}, raw data: {msg.data[:200]}")
                            await client_ws.send_json({"type": "raw", "data": msg.data})
                    elif msg.type == aiohttp.WSMsgType.CLOSED:
                        logger.info("[Overshoot WS] Connection closed by server")
                        break
                    elif msg.type == aiohttp.WSMsgType.ERROR:
                        logger.error(f"[Overshoot WS] WebSocket error: {ws.exception()}")
                        break
                    else:
                        logger.debug(f"[Overshoot WS] Unhandled message type: {msg.type}")
        except aiohttp.ClientError as e:
            logger.error(f"[Overshoot WS] Client error: {type(e).__name__}: {e}")
            try:
                await client_ws.send_json({"type": "error", "error": f"Connection error: {e}"})
            except Exception:
                pass
        except Exception as e:
            logger.error(f"[Overshoot WS] Unexpected error: {type(e).__name__}: {e}", exc_info=True)
            try:
                await client_ws.send_json({"type": "error", "error": str(e)})
            except Exception:
                pass


async def _keepalive_loop(client: OvershootHttpClient, stream_id: str, stop_event: asyncio.Event):
    """Send keepalive requests periodically."""
    while not stop_event.is_set():
        try:
            await asyncio.sleep(30)
            if stop_event.is_set():
                break
            await client.keepalive(stream_id)
        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.error(f"Keepalive error: {e}")


@overshoot_router.websocket("/ws/stream")
async def overshoot_video_websocket(websocket: WebSocket):
    """
    WebSocket endpoint for streaming video to Overshoot.

    Protocol:
    1. Client connects and sends a JSON config message:
       {
         "type": "config",
         "prompt": "Describe what you see",
         "model": "gemini-2.0-flash",
         "backend": "gemini",  // optional, default "gemini"
         "fps": 30,  // optional
         "width": 640,  // optional
         "height": 480  // optional
       }

    2. Server responds with:
       {"type": "ready", "stream_id": "..."}

    3. Client sends video frames with timestamps:
       - Binary format: first 8 bytes = timestamp (float64 little-endian),
         remaining bytes = RGB24 numpy array
       - OR JSON format: {"type": "frame", "timestamp": 1234567890.123, "data": "<base64>"}

    4. Server forwards inference results with the latest timestamp:
       {"type": "inference", "result": "...", "timestamp": 1234567890.123}

    5. Client can send control messages:
       {"type": "stop"} - Stop the stream
       {"type": "update_prompt", "prompt": "new prompt"}
    """
    await websocket.accept()

    api_key = _overshoot_api_key()
    api_url = _overshoot_api_url()

    frame_queue: asyncio.Queue = asyncio.Queue(maxsize=30)
    stop_event = asyncio.Event()
    timestamp_state: dict = {"latest": None}  # Shared state for tracking latest timestamp
    pc: RTCPeerConnection | None = None
    client: OvershootHttpClient | None = None
    stream_id: str | None = None
    tasks: list[asyncio.Task] = []

    try:
        # Wait for config message
        config_data = await websocket.receive_json()
        logger.info(f"[Overshoot WS Stream] Received config: {config_data}")
        if config_data.get("type") != "config":
            logger.warning("[Overshoot WS Stream] First message was not config type")
            await websocket.send_json({"type": "error", "error": "First message must be config"})
            await websocket.close()
            return

        prompt = config_data.get("prompt", "Describe what you see")
        model = config_data.get("model", "gemini-2.0-flash")
        backend = config_data.get("backend", "gemini")
        fps = config_data.get("fps", 30)
        width = config_data.get("width", 640)
        height = config_data.get("height", 480)

        logger.info(f"[Overshoot WS Stream] Config: model={model}, backend={backend}, fps={fps}, size={width}x{height}")

        # Create video track
        video_track = QueuedVideoTrack(frame_queue, width=width, height=height)

        # Create WebRTC peer connection with ICE servers
        ice_servers = [
            RTCIceServer(
                urls=server["urls"],
                username=server["username"],
                credential=server["credential"],
            )
            for server in DEFAULT_ICE_SERVERS
        ]
        config = RTCConfiguration(iceServers=ice_servers)
        pc = RTCPeerConnection(configuration=config)
        pc.addTrack(video_track)

        # Create offer
        offer = await pc.createOffer()
        await pc.setLocalDescription(offer)
        logger.info("[Overshoot WS Stream] WebRTC offer created")

        # Create Overshoot stream
        client = OvershootHttpClient(api_url, api_key)

        processing = StreamProcessingConfig(
            sampling_ratio=0.5,
            fps=fps,
            clip_length_seconds=2.0,
            delay_seconds=5.0,
        )
        inference = StreamInferenceConfig(
            prompt=prompt,
            backend=backend,
            model=model,
        )

        logger.info("[Overshoot WS Stream] Creating Overshoot stream...")
        response = await client.create_stream(
            offer_sdp=pc.localDescription.sdp,
            processing=processing,
            inference=inference,
        )
        logger.info(f"[Overshoot WS Stream] Stream created, response: {response}")

        stream_id = response["stream_id"]
        answer_sdp = response["webrtc"]["sdp"]

        # Set remote description
        answer = RTCSessionDescription(sdp=answer_sdp, type="answer")
        await pc.setRemoteDescription(answer)
        logger.info(f"[Overshoot WS Stream] WebRTC connection established, stream_id={stream_id}")

        # Store client for session management
        async with _overshoot_sessions_lock:
            _overshoot_sessions[stream_id] = client

        # Get WebSocket URL for inference results
        ws_url = client.get_websocket_url(stream_id)
        cookies = client.get_cookies()
        logger.info(f"[Overshoot WS Stream] Inference WS URL: {ws_url}")

        # Start background tasks
        ws_task = asyncio.create_task(
            _listen_overshoot_ws(ws_url, api_key, cookies, websocket, stop_event, timestamp_state)
        )
        keepalive_task = asyncio.create_task(
            _keepalive_loop(client, stream_id, stop_event)
        )
        tasks = [ws_task, keepalive_task]

        # Send ready message
        await websocket.send_json({"type": "ready", "stream_id": stream_id})
        logger.info(f"[Overshoot WS Stream] Ready, stream_id={stream_id}")

        # Main loop: receive frames and control messages
        while not stop_event.is_set():
            message = await websocket.receive()

            if message["type"] == "websocket.disconnect":
                break

            if "bytes" in message:
                # Binary frame data with timestamp
                # Format: first 8 bytes = timestamp (float64 little-endian), rest = RGB24 frame
                frame_bytes = message["bytes"]
                try:
                    expected_frame_size = height * width * 3
                    if len(frame_bytes) == expected_frame_size + 8:
                        # Extract timestamp (first 8 bytes as float64 little-endian)
                        timestamp = struct.unpack('<d', frame_bytes[:8])[0]
                        timestamp_state["latest"] = timestamp
                        frame_data = frame_bytes[8:]
                    else:
                        # Backward compatibility: no timestamp, just frame data
                        frame_data = frame_bytes

                    # Decode frame (expecting RGB24 numpy array)
                    frame = np.frombuffer(frame_data, dtype=np.uint8)
                    frame = cv2.imdecode(frame, cv2.IMREAD_COLOR)
                    frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                    # Put frame in queue (non-blocking, drop if full)
                    try:
                        frame_queue.put_nowait(frame)
                    except asyncio.QueueFull:
                        # Drop frame if queue is full
                        pass
                except (ValueError, struct.error) as e:
                    logger.warning(f"Invalid frame data: {e}")

            elif "text" in message:
                # JSON control message
                try:
                    data = json.loads(message["text"])
                    msg_type = data.get("type")

                    if msg_type == "stop":
                        break
                    elif msg_type == "update_prompt":
                        new_prompt = data.get("prompt")
                        if new_prompt and stream_id:
                            await client.update_prompt(stream_id, new_prompt)
                            await websocket.send_json({"type": "prompt_updated", "prompt": new_prompt})
                    elif msg_type == "frame":
                        # JSON frame with timestamp and base64-encoded data
                        timestamp = data.get("timestamp")
                        if timestamp is not None:
                            timestamp_state["latest"] = timestamp
                        frame_b64 = data.get("data")
                        if frame_b64:
                            frame_data = base64.b64decode(frame_b64)
                            frame = np.frombuffer(frame_data, dtype=np.uint8).reshape((height, width, 3))
                            try:
                                frame_queue.put_nowait(frame)
                            except asyncio.QueueFull:
                                pass
                except json.JSONDecodeError:
                    pass

    except WebSocketDisconnect:
        logger.info("[Overshoot WS Stream] Client disconnected")
    except ApiError as e:
        logger.error(f"[Overshoot WS Stream] API error: {e.status_code} - {e.message}")
        try:
            await websocket.send_json({"type": "error", "error": e.message})
        except Exception:
            pass
    except Exception as e:
        logger.exception(f"[Overshoot WS Stream] Unexpected error: {type(e).__name__}: {e}")
        try:
            await websocket.send_json({"type": "error", "error": str(e)})
        except Exception:
            pass
    finally:
        # Cleanup
        logger.info(f"[Overshoot WS Stream] Cleaning up, stream_id={stream_id}")
        stop_event.set()

        for task in tasks:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

        if pc:
            await pc.close()

        if stream_id:
            async with _overshoot_sessions_lock:
                _overshoot_sessions.pop(stream_id, None)

        if client:
            await client.close()

        try:
            await websocket.close()
        except Exception:
            pass
