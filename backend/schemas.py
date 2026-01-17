from pydantic import BaseModel
from typing import Optional


class PredictionTrainRequest(BaseModel):
    dataset_id: str
    target_column: str
    feature_columns: Optional[list[str]] = None


class ClusteringTrainRequest(BaseModel):
    dataset_id: str
    feature_columns: Optional[list[str]] = None
    n_clusters: Optional[int] = None


class AnomalyTrainRequest(BaseModel):
    dataset_id: str
    feature_columns: Optional[list[str]] = None


class EmbeddingTrainRequest(BaseModel):
    dataset_id: str
    text_column: str


class InferenceRequest(BaseModel):
    dataset_id: str
    coerce_schema: Optional[bool] = False
