'''
testing the rtmpose module in rtmpose3d_handler.py
'''
from rtmpose3d_handler import RTMPose3DHandler

if __name__ == "__main__":
    handler = RTMPose3DHandler(device='cpu')
    with open("RTMpose/walking.mp4", "rb") as f:
        video_bytes = f.read()
    all_poses, output_2d_video = handler.process_video(video_bytes)
    print("Processed poses shape:", all_poses.shape)
    print("2D overlay video saved at:", output_2d_video)
    
    # since output_2d_video is a temp file, we move it to a permanent location
    with open("RTMpose/output_overlay.mp4", "wb") as out_f:
        with open(output_2d_video, "rb") as in_f:
            out_f.write(in_f.read())