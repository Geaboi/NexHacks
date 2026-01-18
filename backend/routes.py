import os
import requests
from fastapi import APIRouter, HTTPException, UploadFile, File, Query, Form
from fastapi.responses import FileResponse

from config import BASE_URL, HEADERS
from schemas import (
    PredictionTrainRequest,
    ClusteringTrainRequest,
    AnomalyTrainRequest,
    EmbeddingTrainRequest,
    InferenceRequest,
)
from RTMpose.rtmpose3d_handler import RTMPose3DHandler


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
    upload_to_woodwide: bool = Query(True, description="Upload angles to Woodwide"),
    overwrite: bool = Query(False, description="Overwrite existing dataset"),
    sensor_data: str = Form(None, description="Sensor data associated with the video")
):
    """Process video through RTMpose and optionally upload joint angles to Woodwide.

    Returns the angle CSV and Woodwide upload result.
    """
    try:
        video_bytes = await video.read()
        handler = get_pose_handler()

        # Process video to get joint angles and CSV
        angles, overlay_video_path, csv_path = handler.process_video(video_bytes, sensor_data)

        result = {
            "num_frames": len(angles),
            "num_angles": 6,
            "csv_path": csv_path,
            "overlay_video_path": overlay_video_path,
        }

        # Upload to Woodwide if requested
        if upload_to_woodwide:
            url = f"{BASE_URL}/api/datasets"
            with open(csv_path, "rb") as f:
                files = {"file": (f"{dataset_name}.csv", f, "text/csv")}
                data = {"name": dataset_name, "overwrite": str(overwrite).lower()}
                response = requests.post(url, headers=HEADERS, files=files, data=data)
                response.raise_for_status()
                result["woodwide_response"] = response.json()

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
