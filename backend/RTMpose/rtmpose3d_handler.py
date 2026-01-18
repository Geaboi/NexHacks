
'''
Handles the input to RTM pose and outputs keypoints + 3D estimation
Can also output a video with 2D keypoints overlaid
'''

import os
import sys
from sensorFusion import FusionEKF
import datetime

JOINT_INDEX = 0 # hard-code to left knee for now.

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
    
    def process_video(self, video_bytes, sensor_data=None):
        """Process video with optional IMU sensor data for Kalman-filtered joint angles.
        
        Args:
            video_bytes: Raw video file bytes
            sensor_data: Optional list of IMU samples from Flutter getSamplesForBackend():
                [
                    {
                        'data': {
                            'xA': float,  # Gyro A x-axis (°/s)
                            'yA': float,  # Gyro A y-axis (°/s)
                            'zA': float,  # Gyro A z-axis (°/s)
                            'xB': float,  # Gyro B x-axis (°/s)
                            'yB': float,  # Gyro B y-axis (°/s)
                            'zB': float,  # Gyro B z-axis (°/s)
                        },
                        'timestamp_ms': int,  # Milliseconds from session start
                    },
                    ...
                ]
        
        Returns:
            tuple: (angles_list, output_2d_video_path, csv_path)
        """
        video_handler = VideoHandler(video_bytes)

        total = int(video_handler.cap.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = video_handler.cap.get(cv2.CAP_PROP_FPS)
        w = int(video_handler.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        h = int(video_handler.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

        out2d = cv2.VideoWriter(self.output_file_2D.name, cv2.VideoWriter_fourcc(*'mp4v'), fps, (w, h))

        all_poses = []
        all_scores = []
        frame_timestamps_ms = []  # Frame timestamps in milliseconds
        
        # Calculate frame duration in milliseconds
        frame_duration_ms = 1000.0 / fps if fps > 0 else 33.33  # Default to ~30fps
        
        # INITIAL PASS: PROCESS FRAMES
        frame_idx = 0
        for _ in tqdm(range(total)): # for all frames
            ret, frame = video_handler.read_frame()
            if not ret:
                break
            
            # Calculate timestamp for this frame (in milliseconds)
            frame_timestamps_ms.append(frame_idx * frame_duration_ms)
            frame_idx += 1
            
            kps_3d, scores, _, kps_2d = self.model(frame)
            # sizings for kps_3d: (num_people, num_keypoints, 3)
            # sizings for kps_2d: (num_people, num_keypoints, 2)

            # return body + foot keypoints only as [X, Y, Z]
            if len(kps_3d) > 0:
                raw = kps_3d[0][:23, :]
                # Fix Axes: X->X, Z->Y, -Y->Z
                corrected = np.zeros_like(raw)
                corrected[:, 0] = raw[:, 0]
                corrected[:, 1] = raw[:, 2]
                corrected[:, 2] = -raw[:, 1]
                all_poses.append(corrected)
                all_scores.append(scores[0][:23])

                out2d.write(draw_skeleton(frame, kps_2d, scores, kpt_thr=self.CONF_THRESHOLD)) # draw first person's 2D keypoints
            else:
                all_poses.append(np.zeros((23, 3)))
                all_scores.append(np.zeros(23))
                out2d.write(frame) # write original frame if no person detected
            
        out2d.release()
        video_handler.release()
        all_poses = np.array(all_poses)

        # NOW NORMALIZE AND STUFF
        norm_poses = self.normalize_by_torso_height(all_poses)
        
        # build angles from leg keypoints, should be same size as norm_poses
        angles = self.build_leg_angles(norm_poses)
        angle_scores = self.average_leg_scores(all_scores)

        # Sensor fusion with Kalman filtering
        # sensor_data format from Flutter getSamplesForBackend():
        # [{'data': {'xA', 'yA', 'zA', 'xB', 'yB', 'zB'}, 'timestamp_ms': int}, ...]
        if sensor_data is not None and len(sensor_data) > 1 and \
           len(angles) == len(angle_scores) == len(frame_timestamps_ms):
            
            pre_sensor_angles = [a.copy() if isinstance(a, list) else list(a) for a in angles]
            out_angles = []
            
            # Kalman filtering with sensor data
            ekf = FusionEKF(initial_angle=pre_sensor_angles[0][JOINT_INDEX])

            cv_idx = 1

            for i in range(1, len(sensor_data)):
                s_samp = sensor_data[i]
                s_prev = sensor_data[i-1]

                # Extract gyroscope values from new format
                # Relative angular velocity between the two IMU sensors
                w_rel = s_samp['data']['yB'] - s_samp['data']['yA']
                
                # Calculate dt in seconds from millisecond timestamps
                dt = (s_samp['timestamp_ms'] - s_prev['timestamp_ms']) / 1000.0
                if dt <= 0: 
                    continue

                ekf.predict(w_rel, dt)

                # Update with vision measurements when sensor timestamp passes frame timestamp
                while cv_idx < len(pre_sensor_angles) and \
                      s_samp['timestamp_ms'] >= frame_timestamps_ms[cv_idx]:
                    # Only update if we have valid angle measurement
                    if not np.isnan(pre_sensor_angles[cv_idx][JOINT_INDEX]) and \
                       not np.isnan(angle_scores[cv_idx][JOINT_INDEX]):
                        ekf.update(
                            pre_sensor_angles[cv_idx][JOINT_INDEX], 
                            angle_scores[cv_idx][JOINT_INDEX]
                        )
                    cv_idx += 1
                
                out_angles.append({
                    'timestamp_ms': s_samp['timestamp_ms'],
                    'joint_angle': float(ekf.x[0]),
                    'bias_est': float(ekf.x[1])
                })

            # Map fused angles back to frame timestamps
            if out_angles:
                out_ang_idx = 0
                for i in range(len(frame_timestamps_ms)):
                    angle_sum = 0.0
                    count = 0
                    
                    # Average all sensor-fused angles that fall before this frame's timestamp
                    while out_ang_idx < len(out_angles) and \
                          out_angles[out_ang_idx]['timestamp_ms'] < frame_timestamps_ms[i]:
                        angle_sum += out_angles[out_ang_idx]['joint_angle']
                        count += 1
                        out_ang_idx += 1
                    
                    if count > 0:
                        angles[i][JOINT_INDEX] = angle_sum / count
                
        # Save angles to CSV
        csv_path = self.angles_to_csv(angles, self.output_file_csv.name)

        return angles, self.output_file_2D.name, csv_path

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
    def angles_to_dataframe(angles_list: list) -> pd.DataFrame:
        """Convert angle list to pandas DataFrame for Woodwide upload.

        Args:
            angles_list: list of 6-element lists containing joint angles
                [left_knee, right_knee, left_hip, right_hip, left_ankle, right_ankle]

        Returns:
            DataFrame with columns: frame, left_knee_flexion, right_knee_flexion,
                left_hip_flexion, right_hip_flexion, left_ankle_flexion, right_ankle_flexion
        """
        df = pd.DataFrame(angles_list, columns=[
            "left_knee_flexion",
            "right_knee_flexion",
            "left_hip_flexion",
            "right_hip_flexion",
            "left_ankle_flexion",
            "right_ankle_flexion"
        ])
        df.insert(0, 'frame', pd.array(range(len(angles_list)), dtype='int64'))
        return df

    @staticmethod
    def angles_to_csv(angles_list: list, output_path: str = '/output.csv') -> str:
        """Convert angle list to CSV file.

        Args:
            angles_list: list of 6-element lists containing joint angles
                [left_knee, right_knee, left_hip, right_hip, left_ankle, right_ankle]
            output_path: optional path for output file, creates temp file if None

        Returns:
            Path to the CSV file
        """
        df = RTMPose3DHandler.angles_to_dataframe(angles_list)

        if output_path is None:
            temp_file = tempfile.NamedTemporaryFile(delete=False, suffix='.csv')
            output_path = temp_file.name
            temp_file.close()

        df.to_csv(output_path, index=False)
        return output_path

    def build_leg_angles(self, norm_poses):
        angles_list = []
        for pose in norm_poses:
            # Check if the pose is entirely empty (sum is 0) to skip fast
            if np.sum(np.abs(pose)) == 0:
                # Append a dict of NaNs so the row count matches the frame count
                angles_list.append([
                    np.nan, np.nan,
                    np.nan, np.nan,
                    np.nan, np.nan
                ])
                continue

            frame_angles = [
                # Knee Flexion: Hip (11/12) -> Knee (13/14) -> Ankle (15/16)
                self.calculate_angle(pose[11], pose[13], pose[15]), # "left_knee_flexion"
                self.calculate_angle(pose[12], pose[14], pose[16]), # "right_knee_flexion"

                # Hip Flexion: Shoulder (5/6) -> Hip (11/12) -> Knee (13/14)
                self.calculate_angle(pose[5], pose[11], pose[13]), # "left_hip_flexion"
                self.calculate_angle(pose[6], pose[12], pose[14]), # "right_hip_flexion"

                # Ankle Dorsiflexion: Knee (13/14) -> Ankle (15/16) -> Big Toe (17/20)
                self.calculate_angle(pose[13], pose[15], pose[17]), # "left_ankle_flexion"
                self.calculate_angle(pose[14], pose[16], pose[20]), # "right_ankle_flexion"
            ]
            angles_list.append(frame_angles)
            
        return angles_list
    
    def average_leg_scores(self, scores_structure):
        leg_scores = []
        for score_list in scores_structure:
            if np.sum(score_list) == 0:
                leg_scores.append([
                    np.nan, np.nan,
                    np.nan, np.nan,
                    np.nan, np.nan
                ])
                continue
            
            frame_scores = [
                # Knee Flexion: Hip (11/12) -> Knee (13/14) -> Ankle (15/16)
                np.mean([score_list[11], score_list[13], score_list[15]]), # "left_knee_score"
                np.mean([score_list[12], score_list[14], score_list[16]]), # "right_knee_score"

                # Hip Flexion: Shoulder (5/6) -> Hip (11/12) -> Knee (13/14)
                np.mean([score_list[5], score_list[11], score_list[13]]), # "left_hip_score"
                np.mean([score_list[6], score_list[12], score_list[14]]), # "right_hip_score"

                # Ankle Dorsiflexion: Knee (13/14) -> Ankle (15/16) -> Big Toe (17/20)
                np.mean([score_list[13], score_list[15], score_list[17]]), # "left_ankle_score"
                np.mean([score_list[14], score_list[16], score_list[20]]), # "right_ankle_score"
            ]
            leg_scores.append(frame_scores)

        return leg_scores
            

    def calculate_angle(self, a, b, c):
        """
        Calculates angle at vertex b, given points a, b, c.
        Returns np.nan if points are missing/invalid.
        """
        # Create vectors BA and BC
        ba = a - b
        bc = c - b

        norm_ba = np.linalg.norm(ba)
        norm_bc = np.linalg.norm(bc)

        # EDGE CASE CHECK:
        # If the magnitude of the vector is 0 (meaning a point is missing/zero 
        # or two points are identical), return NaN.
        if norm_ba == 0 or norm_bc == 0:
            return np.nan

        # Calculate cosine and angle
        cosine_angle = np.dot(ba, bc) / (norm_ba * norm_bc)
        angle = np.arccos(np.clip(cosine_angle, -1.0, 1.0))

        return np.degrees(angle)
    