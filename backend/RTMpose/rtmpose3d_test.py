'''

testing the rtmpose module in rtmpose3d_handler.py
'''
import os
from rtmpose3d_handler import RTMPose3DHandler

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))

    handler = RTMPose3DHandler()
    with open(os.path.join(script_dir, "walking.mp4"), "rb") as f:
        video_bytes = f.read()
    all_poses, output_2d_video, csv_path = handler.process_video(video_bytes)
    print("Processed poses shape:", all_poses.shape)
    print("2D overlay video saved at:", output_2d_video)
    print("CSV of keypoints saved at:", csv_path)

    # since output_2d_video is a temp file, we move it to a permanent location
    with open(os.path.join(script_dir, "output_overlay.mp4"), "wb") as out_f:
        with open(output_2d_video, "rb") as in_f:
            out_f.write(in_f.read())