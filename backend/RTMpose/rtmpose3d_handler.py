
'''
Handles the input to RTM pose and outputs keypoints + 3D estimation
Can also output a video with 2D keypoints overlaid
'''

import os
import sys

# Add cuDNN/cuBLAS DLLs to path for ONNX Runtime GPU support (Windows)
if sys.platform == 'win32':
    nvidia_base = os.path.join(sys.prefix, 'Lib', 'site-packages', 'nvidia')
    cudnn_path = os.path.join(nvidia_base, 'cudnn', 'bin')
    cublas_path = os.path.join(nvidia_base, 'cublas', 'bin')
    
    # Add to PATH environment variable (needed for DLL dependencies)
    paths_to_add = [p for p in [cudnn_path, cublas_path] if os.path.exists(p)]
    if paths_to_add:
        os.environ['PATH'] = os.pathsep.join(paths_to_add) + os.pathsep + os.environ.get('PATH', '')
    
    # Also use add_dll_directory for Python 3.8+
    for path in paths_to_add:
        os.add_dll_directory(path)

def _ensure_onnxruntime_gpu():
    """Ensure onnxruntime-gpu is installed with CUDA support."""
    import subprocess
    try:
        import onnxruntime as ort
        providers = ort.get_available_providers()
        if 'CUDAExecutionProvider' not in providers:
            print("CUDA provider not found. Reinstalling onnxruntime-gpu...")
            subprocess.check_call([sys.executable, '-m', 'pip', 'uninstall', 'onnxruntime', '-y'], 
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.check_call([sys.executable, '-m', 'pip', 'uninstall', 'onnxruntime-gpu', '-y'], 
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'onnxruntime-gpu'],
                                  stdout=subprocess.DEVNULL)
            print("Reinstalled onnxruntime-gpu. Please restart the script.")
            sys.exit(0)
    except ImportError:
        print("onnxruntime not found. Installing onnxruntime-gpu...")
        subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'onnxruntime-gpu'],
                              stdout=subprocess.DEVNULL)
        print("Installed onnxruntime-gpu. Please restart the script.")
        sys.exit(0)

_ensure_onnxruntime_gpu()

from rtmlib import Wholebody3d, draw_skeleton
import tempfile
import cv2
import numpy as np
import pandas as pd
from tqdm import tqdm

# COCO-style keypoint names for body + feet (23 keypoints)
KEYPOINT_NAMES = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip",
    "left_knee", "right_knee", "left_ankle", "right_ankle",
    "left_big_toe", "left_small_toe", "left_heel",
    "right_big_toe", "right_small_toe", "right_heel"
]


class VideoHandler():

    def __init__(self, video_bytes):
        self.tfile = tempfile.NamedTemporaryFile(delete=False, suffix='.mp4')
        self.tfile.write(video_bytes)
        self.tfile.close() # Close so OpenCV can open it
        self.cap = cv2.VideoCapture(self.tfile.name)

    def read_frame(self):
        ret, frame = self.cap.read()
        if not ret:
            self.cap.release()
            os.unlink(self.tfile.name) # Manual cleanup to be safe
            return False, None # return False to indicate end of video
        return ret, frame
    
    def release(self):
        self.cap.release()
        os.unlink(self.tfile.name) # Cleanup temporary file

class RTMPose3DHandler:

    def __init__(self, device='cuda'):
        print(f"Using device: {device}")
        self.model = Wholebody3d(mode='balanced', backend='onnxruntime', device=device)
        self.device = device
        self.output_file_2D = tempfile.NamedTemporaryFile(delete=False, suffix='.mp4')
        self.output_file_csv = tempfile.NamedTemporaryFile(delete=False, suffix='.csv')
        self.CONF_THRESHOLD = 0.3
    
    def process_video(self, video_bytes):
        video_handler = VideoHandler(video_bytes)

        total = int(video_handler.cap.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = video_handler.cap.get(cv2.CAP_PROP_FPS)
        w = int(video_handler.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        h = int(video_handler.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

        out2d = cv2.VideoWriter(self.output_file_2D.name, cv2.VideoWriter_fourcc(*'mp4v'), fps, (w, h))

        all_poses = []
        
        # INITIAL PASS: PROCESS FRAMES
        for _ in tqdm(range(total)): # for all frames
            ret, frame = video_handler.read_frame()
            if not ret:
                break
            
            kps_3d, scores, _, kps_2d = self.model(frame)
            # sizings for kps_3d: (num_people, num_keypoints, 3)
            # sizings for kps_2d: (num_people, num_keypoints, 2)

            # return body + foot keypoints only as [X, Y, Z]
            if len(kps_3d) > 0:
                raw = kps_3d[0][:23, :3]
                # Fix Axes: X->X, Z->Y, -Y->Z
                corrected = np.zeros_like(raw)
                corrected[:, 0] = raw[:, 0]
                corrected[:, 1] = raw[:, 2]
                corrected[:, 2] = -raw[:, 1]
                all_poses.append(corrected)

                out2d.write(draw_skeleton(frame, kps_2d, scores, kpt_thr=self.CONF_THRESHOLD)) # draw first person's 2D keypoints
            else:
                all_poses.append(np.zeros((23, 3)))
                out2d.write(frame) # write original frame if no person detected
            
        out2d.release()
        video_handler.release()
        all_poses = np.array(all_poses)

        # NOW NORMALIZE AND STUFF
        norm_poses = self.normalize_by_torso_height(all_poses)

        # Save keypoints to CSV
        csv_path = self.keypoints_to_csv(norm_poses, self.output_file_csv.name)

        return norm_poses, self.output_file_2D.name, csv_path

    def normalize_by_torso_height(self, all_poses):
        norm_poses = []
        for pose in all_poses:
            if np.sum(np.abs(pose)) > 0.1:
                # Assuming keypoint 0 is pelvis, 1 is spine/chest
                torso_height = np.linalg.norm(pose[1] - pose[0])
                if torso_height > 0.01:
                    norm_poses.append(pose / torso_height)
                else:
                    norm_poses.append(pose)
            else:
                norm_poses.append(np.zeros_like(pose))
        return np.array(norm_poses)

    @staticmethod
    def keypoints_to_dataframe(all_poses: np.ndarray) -> pd.DataFrame:
        """Convert keypoint array to pandas DataFrame for Woodwide upload.

        Args:
            all_poses: numpy array of shape (num_frames, 23, 3)

        Returns:
            DataFrame with columns: frame, kp_name_x, kp_name_y, kp_name_z for each keypoint
        """
        num_frames = all_poses.shape[0]

        # Build column names
        columns = ["frame"]
        for kp_name in KEYPOINT_NAMES:
            columns.extend([f"{kp_name}_x", f"{kp_name}_y", f"{kp_name}_z"])

        # Flatten data
        rows = []
        for frame_idx in range(num_frames):
            row = [frame_idx]
            for kp_idx in range(23):
                row.extend(all_poses[frame_idx, kp_idx, :].tolist())
            rows.append(row)

        return pd.DataFrame(rows, columns=columns)

    @staticmethod
    def keypoints_to_csv(all_poses: np.ndarray, output_path: str = '/output.csv') -> str:
        """Convert keypoint array to CSV file.

        Args:
            all_poses: numpy array of shape (num_frames, 23, 3)
            output_path: optional path for output file, creates temp file if None

        Returns:
            Path to the CSV file
        """
        df = RTMPose3DHandler.keypoints_to_dataframe(all_poses)

        if output_path is None:
            temp_file = tempfile.NamedTemporaryFile(delete=False, suffix='.csv')
            output_path = temp_file.name
            temp_file.close()

        df.to_csv(output_path, index=False)
        return output_path
