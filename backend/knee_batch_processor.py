"""
Batch video preprocessor for knee injury and movement analysis using RTMPose3D.
Extracts knee-specific metrics and exports to CSV for Wood Wide integration.
"""

import os
import glob
import numpy as np
import pandas as pd
from pathlib import Path
from typing import List, Dict, Optional, Tuple
from dataclasses import dataclass, field
from tqdm import tqdm
import requests

from RTMpose.rtmpose3d_handler import RTMPose3DHandler, KEYPOINT_NAMES
from config import BASE_URL, HEADERS


# Knee-relevant keypoint indices
KEYPOINT_INDICES = {
    "left_hip": 11,
    "right_hip": 12,
    "left_knee": 13,
    "right_knee": 14,
    "left_ankle": 15,
    "right_ankle": 16,
    "left_shoulder": 5,
    "right_shoulder": 6,
}


@dataclass
class KneeMetrics:
    """Container for computed knee metrics per frame."""
    frame: int
    timestamp: float

    # Knee flexion angles (degrees) - angle at knee joint
    left_knee_flexion: float
    right_knee_flexion: float

    # Knee valgus/varus angles (frontal plane)
    left_knee_valgus: float
    right_knee_varus: float
    right_knee_valgus: float
    left_knee_varus: float

    # Angular velocities (degrees/second)
    left_knee_angular_velocity: float = 0.0
    right_knee_angular_velocity: float = 0.0

    # Angular accelerations (degrees/second^2)
    left_knee_angular_acceleration: float = 0.0
    right_knee_angular_acceleration: float = 0.0

    # Symmetry metrics
    knee_angle_asymmetry: float = 0.0  # difference between left and right

    # Raw positions (for advanced analysis)
    left_knee_x: float = 0.0
    left_knee_y: float = 0.0
    left_knee_z: float = 0.0
    right_knee_x: float = 0.0
    right_knee_y: float = 0.0
    right_knee_z: float = 0.0


@dataclass
class VideoSummary:
    """Summary statistics for a processed video."""
    video_name: str
    total_frames: int
    fps: float
    duration_seconds: float

    # Range of motion
    left_knee_rom: float  # max - min flexion
    right_knee_rom: float

    # Peak values
    left_knee_max_flexion: float
    right_knee_max_flexion: float
    left_knee_min_flexion: float
    right_knee_min_flexion: float

    # Peak velocities
    left_knee_peak_velocity: float
    right_knee_peak_velocity: float

    # Asymmetry
    mean_asymmetry: float
    max_asymmetry: float

    # Valgus/Varus peaks (injury risk indicators)
    left_knee_max_valgus: float
    right_knee_max_valgus: float


class KneeAnalyzer:
    """Computes knee-specific metrics from 3D pose data."""

    @staticmethod
    def calculate_angle_3d(p1: np.ndarray, p2: np.ndarray, p3: np.ndarray) -> float:
        """
        Calculate angle at p2 formed by vectors p2->p1 and p2->p3.
        Returns angle in degrees.
        """
        v1 = p1 - p2
        v2 = p3 - p2

        # Handle zero vectors
        norm1 = np.linalg.norm(v1)
        norm2 = np.linalg.norm(v2)
        if norm1 < 1e-6 or norm2 < 1e-6:
            return 0.0

        v1_normalized = v1 / norm1
        v2_normalized = v2 / norm2

        cos_angle = np.clip(np.dot(v1_normalized, v2_normalized), -1.0, 1.0)
        angle_rad = np.arccos(cos_angle)
        return np.degrees(angle_rad)

    @staticmethod
    def calculate_valgus_varus(hip: np.ndarray, knee: np.ndarray, ankle: np.ndarray) -> Tuple[float, float]:
        """
        Calculate knee valgus (inward) and varus (outward) angles in frontal plane.
        Uses the medial-lateral deviation of knee from hip-ankle line.
        Returns (valgus_angle, varus_angle) in degrees.
        """
        # Project to frontal plane (X-Z plane, assuming Y is vertical)
        hip_frontal = np.array([hip[0], hip[2]])
        knee_frontal = np.array([knee[0], knee[2]])
        ankle_frontal = np.array([ankle[0], ankle[2]])

        # Vector from hip to ankle
        hip_to_ankle = ankle_frontal - hip_frontal
        hip_to_ankle_norm = np.linalg.norm(hip_to_ankle)

        if hip_to_ankle_norm < 1e-6:
            return 0.0, 0.0

        # Project knee onto hip-ankle line
        hip_to_knee = knee_frontal - hip_frontal
        t = np.dot(hip_to_knee, hip_to_ankle) / (hip_to_ankle_norm ** 2)
        projection = hip_frontal + t * hip_to_ankle

        # Lateral deviation
        deviation = knee_frontal - projection
        deviation_magnitude = np.linalg.norm(deviation)

        # Calculate angle
        if deviation_magnitude < 1e-6:
            return 0.0, 0.0

        angle = np.degrees(np.arctan2(deviation_magnitude, hip_to_ankle_norm * abs(t - 0.5)))

        # Determine direction (valgus = inward, varus = outward)
        # This depends on which leg - simplified here
        cross = hip_to_ankle[0] * hip_to_knee[1] - hip_to_ankle[1] * hip_to_knee[0]

        if cross > 0:
            return angle, 0.0  # valgus
        else:
            return 0.0, angle  # varus

    def compute_frame_metrics(
        self,
        pose: np.ndarray,
        frame_idx: int,
        fps: float,
        prev_left_angle: Optional[float] = None,
        prev_right_angle: Optional[float] = None,
        prev_left_velocity: Optional[float] = None,
        prev_right_velocity: Optional[float] = None
    ) -> KneeMetrics:
        """Compute all knee metrics for a single frame."""

        # Extract keypoints
        left_hip = pose[KEYPOINT_INDICES["left_hip"]]
        right_hip = pose[KEYPOINT_INDICES["right_hip"]]
        left_knee = pose[KEYPOINT_INDICES["left_knee"]]
        right_knee = pose[KEYPOINT_INDICES["right_knee"]]
        left_ankle = pose[KEYPOINT_INDICES["left_ankle"]]
        right_ankle = pose[KEYPOINT_INDICES["right_ankle"]]

        # Calculate flexion angles
        left_flexion = self.calculate_angle_3d(left_hip, left_knee, left_ankle)
        right_flexion = self.calculate_angle_3d(right_hip, right_knee, right_ankle)

        # Calculate valgus/varus
        left_valgus, left_varus = self.calculate_valgus_varus(left_hip, left_knee, left_ankle)
        right_valgus, right_varus = self.calculate_valgus_varus(right_hip, right_knee, right_ankle)

        # Calculate velocities
        dt = 1.0 / fps if fps > 0 else 1.0 / 30.0

        left_velocity = 0.0
        right_velocity = 0.0
        if prev_left_angle is not None:
            left_velocity = (left_flexion - prev_left_angle) / dt
        if prev_right_angle is not None:
            right_velocity = (right_flexion - prev_right_angle) / dt

        # Calculate accelerations
        left_acceleration = 0.0
        right_acceleration = 0.0
        if prev_left_velocity is not None:
            left_acceleration = (left_velocity - prev_left_velocity) / dt
        if prev_right_velocity is not None:
            right_acceleration = (right_velocity - prev_right_velocity) / dt

        # Asymmetry
        asymmetry = abs(left_flexion - right_flexion)

        return KneeMetrics(
            frame=frame_idx,
            timestamp=frame_idx / fps if fps > 0 else frame_idx / 30.0,
            left_knee_flexion=left_flexion,
            right_knee_flexion=right_flexion,
            left_knee_valgus=left_valgus,
            left_knee_varus=left_varus,
            right_knee_valgus=right_valgus,
            right_knee_varus=right_varus,
            left_knee_angular_velocity=left_velocity,
            right_knee_angular_velocity=right_velocity,
            left_knee_angular_acceleration=left_acceleration,
            right_knee_angular_acceleration=right_acceleration,
            knee_angle_asymmetry=asymmetry,
            left_knee_x=left_knee[0],
            left_knee_y=left_knee[1],
            left_knee_z=left_knee[2],
            right_knee_x=right_knee[0],
            right_knee_y=right_knee[1],
            right_knee_z=right_knee[2],
        )

    def analyze_video(self, poses: np.ndarray, fps: float) -> List[KneeMetrics]:
        """Analyze all frames of a video and return list of knee metrics."""
        metrics = []
        prev_left_angle = None
        prev_right_angle = None
        prev_left_velocity = None
        prev_right_velocity = None

        for frame_idx in range(len(poses)):
            frame_metrics = self.compute_frame_metrics(
                poses[frame_idx],
                frame_idx,
                fps,
                prev_left_angle,
                prev_right_angle,
                prev_left_velocity,
                prev_right_velocity
            )
            metrics.append(frame_metrics)

            prev_left_angle = frame_metrics.left_knee_flexion
            prev_right_angle = frame_metrics.right_knee_flexion
            prev_left_velocity = frame_metrics.left_knee_angular_velocity
            prev_right_velocity = frame_metrics.right_knee_angular_velocity

        return metrics

    def compute_summary(self, metrics: List[KneeMetrics], video_name: str, fps: float) -> VideoSummary:
        """Compute summary statistics for a video."""
        if not metrics:
            return None

        left_flexions = [m.left_knee_flexion for m in metrics]
        right_flexions = [m.right_knee_flexion for m in metrics]
        left_velocities = [abs(m.left_knee_angular_velocity) for m in metrics]
        right_velocities = [abs(m.right_knee_angular_velocity) for m in metrics]
        asymmetries = [m.knee_angle_asymmetry for m in metrics]
        left_valgus = [m.left_knee_valgus for m in metrics]
        right_valgus = [m.right_knee_valgus for m in metrics]

        return VideoSummary(
            video_name=video_name,
            total_frames=len(metrics),
            fps=fps,
            duration_seconds=len(metrics) / fps if fps > 0 else 0,
            left_knee_rom=max(left_flexions) - min(left_flexions),
            right_knee_rom=max(right_flexions) - min(right_flexions),
            left_knee_max_flexion=max(left_flexions),
            right_knee_max_flexion=max(right_flexions),
            left_knee_min_flexion=min(left_flexions),
            right_knee_min_flexion=min(right_flexions),
            left_knee_peak_velocity=max(left_velocities),
            right_knee_peak_velocity=max(right_velocities),
            mean_asymmetry=np.mean(asymmetries),
            max_asymmetry=max(asymmetries),
            left_knee_max_valgus=max(left_valgus),
            right_knee_max_valgus=max(right_valgus),
        )


class KneeBatchProcessor:
    """Batch processor for knee movement analysis across multiple videos."""

    def __init__(self, device: str = 'cuda', output_dir: str = './knee_analysis_output'):
        self.rtmpose = RTMPose3DHandler(device=device)
        self.analyzer = KneeAnalyzer()
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)

    def process_video(self, video_path: str) -> Tuple[pd.DataFrame, VideoSummary]:
        """Process a single video and return knee metrics DataFrame and summary."""
        video_name = Path(video_path).stem

        # Read video bytes
        with open(video_path, 'rb') as f:
            video_bytes = f.read()

        # Get poses from RTMPose
        poses, overlay_path, _ = self.rtmpose.process_video(video_bytes)

        # Get FPS from video
        import cv2
        cap = cv2.VideoCapture(video_path)
        fps = cap.get(cv2.CAP_PROP_FPS)
        cap.release()

        # Analyze knee metrics
        metrics = self.analyzer.analyze_video(poses, fps)
        summary = self.analyzer.compute_summary(metrics, video_name, fps)

        # Convert to DataFrame
        df = self._metrics_to_dataframe(metrics, video_name)

        return df, summary

    def _metrics_to_dataframe(self, metrics: List[KneeMetrics], video_name: str) -> pd.DataFrame:
        """Convert list of KneeMetrics to DataFrame."""
        rows = []
        for m in metrics:
            rows.append({
                'video_name': video_name,
                'frame': m.frame,
                'timestamp': m.timestamp,
                'left_knee_flexion': m.left_knee_flexion,
                'right_knee_flexion': m.right_knee_flexion,
                'left_knee_valgus': m.left_knee_valgus,
                'left_knee_varus': m.left_knee_varus,
                'right_knee_valgus': m.right_knee_valgus,
                'right_knee_varus': m.right_knee_varus,
                'left_knee_angular_velocity': m.left_knee_angular_velocity,
                'right_knee_angular_velocity': m.right_knee_angular_velocity,
                'left_knee_angular_acceleration': m.left_knee_angular_acceleration,
                'right_knee_angular_acceleration': m.right_knee_angular_acceleration,
                'knee_angle_asymmetry': m.knee_angle_asymmetry,
                'left_knee_x': m.left_knee_x,
                'left_knee_y': m.left_knee_y,
                'left_knee_z': m.left_knee_z,
                'right_knee_x': m.right_knee_x,
                'right_knee_y': m.right_knee_y,
                'right_knee_z': m.right_knee_z,
            })
        return pd.DataFrame(rows)

    def process_batch(
        self,
        video_dir: str,
        extensions: List[str] = ['*.mp4', '*.avi', '*.mov', '*.mkv']
    ) -> Tuple[pd.DataFrame, pd.DataFrame]:
        """
        Process all videos in a directory.

        Returns:
            - combined_metrics_df: All frame-by-frame metrics combined
            - summaries_df: Summary statistics per video
        """
        video_paths = []
        for ext in extensions:
            video_paths.extend(glob.glob(os.path.join(video_dir, ext)))
            video_paths.extend(glob.glob(os.path.join(video_dir, '**', ext), recursive=True))

        video_paths = list(set(video_paths))  # Remove duplicates

        if not video_paths:
            print(f"No video files found in {video_dir}")
            return pd.DataFrame(), pd.DataFrame()

        print(f"Found {len(video_paths)} videos to process")

        all_metrics = []
        all_summaries = []

        for video_path in tqdm(video_paths, desc="Processing videos"):
            try:
                df, summary = self.process_video(video_path)
                all_metrics.append(df)
                if summary:
                    all_summaries.append(summary)
            except Exception as e:
                print(f"Error processing {video_path}: {e}")
                continue

        # Combine all metrics
        combined_df = pd.concat(all_metrics, ignore_index=True) if all_metrics else pd.DataFrame()

        # Create summaries DataFrame
        summaries_df = pd.DataFrame([
            {
                'video_name': s.video_name,
                'total_frames': s.total_frames,
                'fps': s.fps,
                'duration_seconds': s.duration_seconds,
                'left_knee_rom': s.left_knee_rom,
                'right_knee_rom': s.right_knee_rom,
                'left_knee_max_flexion': s.left_knee_max_flexion,
                'right_knee_max_flexion': s.right_knee_max_flexion,
                'left_knee_min_flexion': s.left_knee_min_flexion,
                'right_knee_min_flexion': s.right_knee_min_flexion,
                'left_knee_peak_velocity': s.left_knee_peak_velocity,
                'right_knee_peak_velocity': s.right_knee_peak_velocity,
                'mean_asymmetry': s.mean_asymmetry,
                'max_asymmetry': s.max_asymmetry,
                'left_knee_max_valgus': s.left_knee_max_valgus,
                'right_knee_max_valgus': s.right_knee_max_valgus,
            }
            for s in all_summaries
        ]) if all_summaries else pd.DataFrame()

        return combined_df, summaries_df

    def save_to_csv(
        self,
        metrics_df: pd.DataFrame,
        summaries_df: pd.DataFrame,
        metrics_filename: str = 'knee_metrics.csv',
        summaries_filename: str = 'knee_summaries.csv'
    ) -> Tuple[str, str]:
        """Save DataFrames to CSV files."""
        metrics_path = self.output_dir / metrics_filename
        summaries_path = self.output_dir / summaries_filename

        metrics_df.to_csv(metrics_path, index=False)
        summaries_df.to_csv(summaries_path, index=False)

        print(f"Saved metrics to: {metrics_path}")
        print(f"Saved summaries to: {summaries_path}")

        return str(metrics_path), str(summaries_path)

    def upload_to_woodwide(
        self,
        csv_path: str,
        dataset_name: str,
        overwrite: bool = False
    ) -> Dict:
        """Upload CSV to Wood Wide API."""
        url = f"{BASE_URL}/api/datasets"

        with open(csv_path, 'rb') as f:
            files = {'file': (os.path.basename(csv_path), f, 'text/csv')}
            params = {
                'dataset_name': dataset_name,
                'overwrite': str(overwrite).lower()
            }

            response = requests.post(
                url,
                headers={"Authorization": HEADERS["Authorization"]},
                files=files,
                params=params
            )

        if response.status_code in [200, 201]:
            print(f"Successfully uploaded {csv_path} to Wood Wide as '{dataset_name}'")
            return response.json()
        else:
            print(f"Failed to upload: {response.status_code} - {response.text}")
            return {"error": response.text, "status_code": response.status_code}

    def batch_upload_to_woodwide(
        self,
        metrics_path: str,
        summaries_path: str,
        metrics_dataset_name: str = 'knee_metrics',
        summaries_dataset_name: str = 'knee_summaries',
        overwrite: bool = False
    ) -> Dict:
        """Upload both metrics and summaries CSVs to Wood Wide."""
        results = {}

        results['metrics'] = self.upload_to_woodwide(
            metrics_path,
            metrics_dataset_name,
            overwrite
        )

        results['summaries'] = self.upload_to_woodwide(
            summaries_path,
            summaries_dataset_name,
            overwrite
        )

        return results


def main():
    """Example usage of the batch processor."""
    import argparse

    parser = argparse.ArgumentParser(description='Batch process videos for knee analysis')
    parser.add_argument('video_dir', help='Directory containing video files')
    parser.add_argument('--output-dir', default='./knee_analysis_output', help='Output directory for CSVs')
    parser.add_argument('--device', default='cuda', choices=['cuda', 'cpu'], help='Device for inference')
    parser.add_argument('--upload', action='store_true', help='Upload to Wood Wide after processing')
    parser.add_argument('--dataset-prefix', default='knee_analysis', help='Prefix for Wood Wide dataset names')
    parser.add_argument('--overwrite', action='store_true', help='Overwrite existing datasets in Wood Wide')

    args = parser.parse_args()

    # Initialize processor
    processor = KneeBatchProcessor(device=args.device, output_dir=args.output_dir)

    # Process all videos
    metrics_df, summaries_df = processor.process_batch(args.video_dir)

    if metrics_df.empty:
        print("No videos processed successfully")
        return

    # Save to CSV
    metrics_path, summaries_path = processor.save_to_csv(
        metrics_df,
        summaries_df,
        f'{args.dataset_prefix}_metrics.csv',
        f'{args.dataset_prefix}_summaries.csv'
    )

    # Upload to Wood Wide if requested
    if args.upload:
        results = processor.batch_upload_to_woodwide(
            metrics_path,
            summaries_path,
            f'{args.dataset_prefix}_metrics',
            f'{args.dataset_prefix}_summaries',
            args.overwrite
        )
        print("Upload results:", results)

    print("\nProcessing complete!")
    print(f"Total frames analyzed: {len(metrics_df)}")
    print(f"Total videos processed: {len(summaries_df)}")


if __name__ == '__main__':
    main()
