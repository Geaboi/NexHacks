
'''
Handles the input to RTM pose and outputs keypoints + 3D estimation
Can also output a video with 2D keypoints overlaid
'''

import os
from rtmlib import Wholebody3d, draw_skeleton
import tempfile
import cv2
import numpy as np
from tqdm import tqdm


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
        self.model = Wholebody3d(mode='balanced', backend='onnxruntime', device=device)
        self.device = device
        self.output_file_2D = tempfile.NamedTemporaryFile(delete=False, suffix='.mp4')
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

        return norm_poses, self.output_file_2D.name

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
