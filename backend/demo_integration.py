
import asyncio
import json
import logging
import struct
import time
import requests
import websockets
import numpy as np
import cv2
import argparse
import os

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

API_BASE_URL = "http://localhost:8000"
WS_URL = "ws://localhost:8000/api/overshoot/ws/stream"

async def run_demo(use_webcam: bool = False, duration: int = 15):
    """
    Runs the integration demo:
    1. Connects to WebSocket
    2. Streams video (synthetic or webcam)
    3. Receives stream_id
    4. Simulates action detection (by sending frames)
    5. Calls process_video_to_angles with the stream_id to retrieve actions
    """
    
    stream_id = None
    
    logger.info(f"Connecting to WebSocket: {WS_URL}")
    async with websockets.connect(WS_URL) as ws:
        # 1. Handshake / Config
        config = {
            "type": "config",
            "prompt": "Detect waving hand, thumbs up",
            "model": "gemini-2.0-flash",
            "fps": 10
        }
        await ws.send(json.dumps(config))
        
        # 2. Receive Ready
        response = await ws.recv()
        data = json.loads(response)
        
        if data.get("type") == "ready":
            stream_id = data.get("stream_id")
            logger.info(f"Stream Ready! ID: {stream_id}")
            logger.info("Actions detected in this stream will be stored on the server.")
        else:
            logger.error(f"Failed to initialize stream: {data}")
            return

        # 3. Stream Video
        logger.info(f"Streaming for {duration} seconds... Please perform actions (Wave, Thumbs Up)!")
        
        cap = None
        if use_webcam:
            cap = cv2.VideoCapture(0)
            if not cap.isOpened():
                logger.error("Could not open webcam. Falling back to synthetic frames.")
                use_webcam = False
        
        start_time = time.time()
        frame_count = 0
        
        try:
            while time.time() - start_time < duration:
                if use_webcam and cap:
                    ret, frame = cap.read()
                    if not ret: break
                    frame = cv2.resize(frame, (640, 480))
                    # Convert BGR to RGB
                    frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                else:
                    # Synthetic frame (noise)
                    frame = np.random.randint(0, 255, (480, 640, 3), dtype=np.uint8)
                    # Add a visual indicator
                    cv2.putText(frame, "DEMO FRAME", (50, 50), cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 255, 255), 2)
                    
                # Send frame
                # Protocol: 8 bytes timestamp + RGB data
                timestamp = time.time()
                timestamp_bytes = struct.pack('<d', timestamp)
                await ws.send(timestamp_bytes + frame.tobytes())
                
                # Consume messages (inference results)
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=0.01)
                    msg_data = json.loads(msg)
                    if msg_data.get("type") == "inference":
                        # Print generic inference result (action detection logic happens on server)
                        pass
                except asyncio.TimeoutError:
                    pass
                
                frame_count += 1
                await asyncio.sleep(0.1) # Limit FPS
                
        except KeyboardInterrupt:
            logger.info("Stopping stream...")
        finally:
            if cap: cap.release()
            
        logger.info(f"Stream finished. Sent {frame_count} frames.")
    
    # WebSocket closed automatically by context manager context
    logger.info("WebSocket connection closed.")
    
    # 4. Call HTTP Endpoint using the stream_id
    if stream_id:
        logger.info("="*50)
        logger.info(f"Retrieving stored actions for Stream ID: {stream_id}")
        logger.info("="*50)
        
        # Create a dummy video file for the upload requirement
        dummy_filename = "demo_video.mp4"
        with open(dummy_filename, "wb") as f:
            f.write(os.urandom(1024))
            
        try:
            url = f"{API_BASE_URL}/api/pose/process"
            
            # Query parameters (must match @pose_router.post("/process") Query args)
            params = {
                'dataset_name': 'demo_dataset',
                'model_id': 'demo_model',
                'upload_to_woodwide': 'false',
                'overwrite': 'false'
            }
            
            # Form data (must match Form args)
            data = {
                'stream_id': stream_id
            }

            logger.info(f"POST {url}")
            
            # Open file in a context manager so it closes before os.remove
            with open(dummy_filename, 'rb') as video_file:
                files = {'video': (dummy_filename, video_file, 'video/mp4')}
                response = requests.post(url, params=params, files=files, data=data)
            
            if response.status_code == 200:
                result = response.json()
                detected = result.get("detected_actions", [])
                
                logger.info(f"Response Success!")
                logger.info(f"Detected Actions from Server Store: {len(detected)}")
                for action in detected:
                    logger.info(f" - {action['action']} at {action['timestamp']:.2f}s (conf: {action['confidence']:.2f})")
                    
                if not detected:
                    logger.info("No actions were detected (this is expected if using synthetic noise or no actions performed).")
            else:
                logger.error(f"Request failed: {response.status_code} - {response.text}")
                
        finally:
            if os.path.exists(dummy_filename):
                os.remove(dummy_filename)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Demo Action Detection Integration")
    parser.add_argument("--webcam", action="store_true", help="Use webcam to real action testing")
    args = parser.parse_args()
    
    if os.getenv("OVERSHOOT_API_KEY") is None:
        logger.warning("OVERSHOOT_API_KEY not found in environment. Make sure the backend has it configured.")

    try:
        asyncio.run(run_demo(use_webcam=args.webcam))
    except ConnectionRefusedError:
        logger.error("Connection Refused. Is the backend server running? (uvicorn backend.main:app --reload)")
