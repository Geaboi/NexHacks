"""
Pydantic schemas for API request/response validation.
"""

from typing import Any, Optional
from pydantic import BaseModel, Field


# ============================================================================
# Woodwide Model Training Schemas
# ============================================================================

class PredictionTrainRequest(BaseModel):
    """Request schema for training a prediction model."""

    dataset_id: str
    target_column: str
    feature_columns: Optional[list[str]] = None
    model_name: Optional[str] = None
    hyperparameters: Optional[dict[str, Any]] = None


class ClusteringTrainRequest(BaseModel):
    """Request schema for training a clustering model."""

    dataset_id: str
    feature_columns: Optional[list[str]] = None
    n_clusters: Optional[int] = None
    model_name: Optional[str] = None
    hyperparameters: Optional[dict[str, Any]] = None


class AnomalyTrainRequest(BaseModel):
    """Request schema for training an anomaly detection model."""

    dataset_id: str
    feature_columns: Optional[list[str]] = None
    contamination: Optional[float] = None
    model_name: Optional[str] = None
    hyperparameters: Optional[dict[str, Any]] = None


class EmbeddingTrainRequest(BaseModel):
    """Request schema for training an embedding model."""

    dataset_id: str
    text_column: str
    model_name: Optional[str] = None
    hyperparameters: Optional[dict[str, Any]] = None


class InferenceRequest(BaseModel):
    """Request schema for model inference."""

    data: dict[str, Any]


# ============================================================================
# Overshoot Schemas
# ============================================================================

class OvershootInferenceConfig(BaseModel):
    """Inference configuration for Overshoot streams."""

    prompt: str = Field(..., min_length=1, description="Inference prompt")
    backend: str = Field(default="gemini", description="Backend: gemini or overshoot")
    model: str = Field(..., description="Model identifier (e.g., gemini-2.0-flash)")
    output_schema_json: Optional[str] = Field(
        default=None, description="Optional JSON schema for structured output"
    )


class OvershootProcessingConfig(BaseModel):
    """Processing configuration for Overshoot streams."""

    sampling_ratio: float = Field(
        default=1.0, ge=0.1, le=1.0, description="Sampling ratio (0.1-1.0)"
    )
    fps: int = Field(default=30, ge=1, description="Frames per second")
    clip_length_seconds: float = Field(
        default=3.0, ge=0.1, le=60.0, description="Clip length in seconds (0.1-60)"
    )
    delay_seconds: float = Field(
        default=3.0, gt=0.0,
        description="Delay in seconds. Must satisfy: (fps * sampling_ratio * clip_length) / delay <= 30"
    )


class OvershootCreateStreamRequest(BaseModel):
    """Request schema for creating an Overshoot stream."""

    offer_sdp: str = Field(..., description="WebRTC offer SDP")
    inference: OvershootInferenceConfig = Field(..., description="Inference configuration")
    processing: Optional[OvershootProcessingConfig] = Field(
        default=None, description="Processing configuration"
    )
    request_id: Optional[str] = Field(default=None, description="Client request ID")


class OvershootUpdatePromptRequest(BaseModel):
    """Request schema for updating stream prompt."""

    prompt: str = Field(..., min_length=1, description="New prompt text")


class OvershootFeedbackRequest(BaseModel):
    """Request schema for submitting stream feedback."""

    rating: int = Field(..., ge=0, le=10, description="Rating (0-10)")
    category: str = Field(..., min_length=1, description="Feedback category")
    feedback: Optional[str] = Field(default=None, description="Detailed feedback text")
