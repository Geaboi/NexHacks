"""
Overshoot Webcam Test

Captures webcam video, streams to Overshoot via WebRTC,
and prints real-time descriptions of what the camera sees.

Usage:
    python overshoot_webcam_test.py

Environment:
    OVERSHOOT_API_KEY - Your Overshoot API key (required)
    OVERSHOOT_API_URL - API URL (default: https://cluster1.overshoot.ai/api/v0.2)
"""

import asyncio
import json
import os
import sys
import logging
import dotenv

import cv2
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack, RTCConfiguration, RTCIceServer
from aiortc.contrib.media import MediaPlayer
from av import VideoFrame
import numpy as np
import aiohttp

# Setup logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
    datefmt='%H:%M:%S'
)
logger = logging.getLogger(__name__)

# Reduce noise from aiortc internals
logging.getLogger("aiortc").setLevel(logging.WARNING)
logging.getLogger("aioice").setLevel(logging.WARNING)
logging.getLogger("av").setLevel(logging.WARNING)

from overshoot_client import (
    OvershootHttpClient,
    StreamInferenceConfig,
    StreamProcessingConfig,
    ApiError,
    DEFAULT_ICE_SERVERS,
)

dotenv.load_dotenv()

import threading


class WebcamCapture:
    """
    Continuously captures frames from webcam in a background thread.
    """

    def __init__(self, camera_id: int = 0):
        logger.info(f"Opening camera {camera_id}...")
        self.cap = cv2.VideoCapture(camera_id, cv2.CAP_DSHOW)  # DirectShow on Windows
        if not self.cap.isOpened():
            raise RuntimeError(f"Could not open camera {camera_id}")

        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        self.cap.set(cv2.CAP_PROP_FPS, 30)

        self._frame = None
        self._frame_count = 0
        self._lock = threading.Lock()
        self._running = True
        self._thread = threading.Thread(target=self._capture_loop, daemon=True)
        self._thread.start()
        logger.info("Camera capture thread started")

    def _capture_loop(self):
        while self._running:
            ret, frame = self.cap.read()
            if ret:
                with self._lock:
                    self._frame = frame
                    self._frame_count += 1
                    if self._frame_count % 100 == 0:
                        logger.debug(f"Captured {self._frame_count} frames")

    def get_frame(self):
        with self._lock:
            return self._frame.copy() if self._frame is not None else None

    def stop(self):
        self._running = False
        self._thread.join(timeout=1.0)
        if self.cap.isOpened():
            self.cap.release()


class WebcamTrack(VideoStreamTrack):
    """
    A video track that reads from a shared WebcamCapture.
    """

    kind = "video"

    def __init__(self, webcam_capture: WebcamCapture):
        super().__init__()
        self._capture = webcam_capture
        self._sent_frames = 0
        logger.info("WebcamTrack created")

    async def recv(self) -> VideoFrame:
        pts, time_base = await self.next_timestamp()

        # Get latest frame from shared capture
        frame = self._capture.get_frame()
        while frame is None:
            await asyncio.sleep(0.01)
            frame = self._capture.get_frame()

        # Convert BGR to RGB
        frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

        # Create VideoFrame
        video_frame = VideoFrame.from_ndarray(frame_rgb, format="rgb24")
        video_frame.pts = pts
        video_frame.time_base = time_base

        self._sent_frames += 1
        if self._sent_frames % 30 == 0:
            logger.debug(f"WebRTC: Sent {self._sent_frames} frames")

        return video_frame


async def listen_for_descriptions(ws_url: str, api_key: str, cookies: dict = None):
    """
    Connect to WebSocket and print incoming descriptions.
    """
    headers = {"Authorization": f"Bearer {api_key}"}
    if cookies:
        # Add sticky session cookie to headers
        cookie_str = "; ".join(f"{k}={v}" for k, v in cookies.items())
        headers["Cookie"] = cookie_str
        logger.info(f"Using sticky session cookie: {cookie_str}")

    logger.info(f"Connecting to WebSocket: {ws_url}")

    async with aiohttp.ClientSession() as session:
        try:
            logger.debug("Attempting WebSocket connection...")
            async with session.ws_connect(ws_url, headers=headers) as ws:
                logger.info("WebSocket connected successfully!")

                # CRITICAL: Send API key authentication message (required by Overshoot)
                auth_msg = json.dumps({"api_key": api_key})
                await ws.send_str(auth_msg)
                logger.info("Sent WebSocket authentication message")

                print("\n[WebSocket] Connected and authenticated, waiting for descriptions...\n")
                print("=" * 60)

                async for msg in ws:
                    logger.debug(f"WebSocket message received: type={msg.type}")
                    if msg.type == aiohttp.WSMsgType.TEXT:
                        logger.debug(f"WebSocket TEXT data: {msg.data[:200]}...")
                        try:
                            data = json.loads(msg.data)
                            logger.info(f"Parsed JSON keys: {list(data.keys())}")

                            # Check for error first (only if error value is truthy)
                            if data.get("error"):
                                logger.error(f"Error in message: {data['error']}")
                                print(f"\n[Error] {data['error']}")
                            # Handle result at top level (new format)
                            elif "result" in data:
                                result = data["result"]
                                logger.info(f"Got inference result: {str(result)[:100]}...")
                                print(f"\n[Description] {result}")
                                print("-" * 60)
                            # Handle nested inference format (legacy)
                            elif "inference" in data:
                                inference = data["inference"]
                                result = inference.get('result', inference)
                                logger.info(f"Got inference result: {str(result)[:100]}...")
                                print(f"\n[Description] {result}")
                                print("-" * 60)
                            else:
                                logger.info(f"Other message: {data}")
                                print(f"\n[Message] {data}")
                        except json.JSONDecodeError as e:
                            logger.warning(f"JSON decode error: {e}")
                            print(f"\n[Raw] {msg.data}")
                    elif msg.type == aiohttp.WSMsgType.ERROR:
                        logger.error(f"WebSocket error: {ws.exception()}")
                        print(f"\n[WebSocket Error] {ws.exception()}")
                        break
                    elif msg.type == aiohttp.WSMsgType.CLOSED:
                        logger.warning("WebSocket connection closed")
                        print("\n[WebSocket] Connection closed")
                        break
                    elif msg.type == aiohttp.WSMsgType.BINARY:
                        logger.debug(f"Binary message received: {len(msg.data)} bytes")
                    else:
                        logger.debug(f"Unknown message type: {msg.type}")
        except aiohttp.ClientError as e:
            logger.error(f"WebSocket connection failed: {e}")
            print(f"\n[WebSocket] Connection failed: {e}")
        except Exception as e:
            logger.exception(f"Unexpected error in WebSocket listener: {e}")


async def keepalive_loop(client: OvershootHttpClient, stream_id: str, interval: int = 30):
    """
    Send keepalive requests periodically to maintain the stream.
    """
    while True:
        try:
            await asyncio.sleep(interval)
            result = await client.keepalive(stream_id)
            ttl = result.get("ttl_seconds", "?")
            print(f"\n[Keepalive] Stream renewed, TTL: {ttl}s")
        except asyncio.CancelledError:
            break
        except Exception as e:
            print(f"\n[Keepalive Error] {e}")


async def main():
    # Configuration
    api_url = os.getenv("OVERSHOOT_API_URL", "https://cluster1.overshoot.ai/api/v0.2")
    api_key = os.getenv("OVERSHOOT_API_KEY", "")

    if not api_key:
        print("Error: OVERSHOOT_API_KEY environment variable is required")
        print("\nSet it with:")
        print("  export OVERSHOOT_API_KEY=your_api_key_here  # Linux/Mac")
        print("  set OVERSHOOT_API_KEY=your_api_key_here     # Windows CMD")
        print("  $env:OVERSHOOT_API_KEY='your_api_key_here'  # PowerShell")
        sys.exit(1)

    prompt = """Describe what you see in the video.
Focus on:
- People and their actions
- Objects in the scene
- Any notable activity or movement
Be concise but descriptive."""

    print("=" * 60)
    print("Overshoot Webcam Test")
    print("=" * 60)
    print(f"\nAPI URL: {api_url}")
    print(f"Prompt: {prompt[:50]}...")
    print("\nInitializing webcam...")

    # Initialize shared webcam capture
    try:
        webcam_capture = WebcamCapture(camera_id=0)
    except RuntimeError as e:
        print(f"Error: {e}")
        sys.exit(1)

    # Create track that uses shared capture
    webcam_track = WebcamTrack(webcam_capture)

    print("Webcam initialized successfully")

    # Create WebRTC peer connection with ICE servers (TURN)
    ice_servers = [
        RTCIceServer(
            urls=server["urls"],
            username=server["username"],
            credential=server["credential"],
        )
        for server in DEFAULT_ICE_SERVERS
    ]
    config = RTCConfiguration(iceServers=ice_servers)
    pc = RTCPeerConnection(configuration=config)

    # Track connection state
    connection_failed = asyncio.Event()

    # Add connection state logging
    @pc.on("connectionstatechange")
    async def on_connectionstatechange():
        state = pc.connectionState
        logger.info(f"WebRTC connection state: {state}")
        if state == "failed":
            logger.error("WebRTC connection FAILED!")
            connection_failed.set()
        elif state == "disconnected":
            logger.warning("WebRTC connection disconnected")
        elif state == "connected":
            logger.info("WebRTC connection established successfully!")

    @pc.on("iceconnectionstatechange")
    async def on_iceconnectionstatechange():
        state = pc.iceConnectionState
        logger.info(f"ICE connection state: {state}")
        if state == "failed":
            logger.error("ICE connection FAILED! Check network/firewall settings.")
            connection_failed.set()
        elif state == "disconnected":
            logger.warning("ICE disconnected")
        elif state == "connected":
            logger.info("ICE connected!")
        elif state == "completed":
            logger.info("ICE connection completed!")

    @pc.on("icegatheringstatechange")
    async def on_icegatheringstatechange():
        logger.info(f"ICE gathering state: {pc.iceGatheringState}")

    @pc.on("track")
    def on_track(track):
        logger.info(f"Received track: {track.kind}")

    @pc.on("icecandidate")
    def on_icecandidate(candidate):
        if candidate:
            logger.debug(f"ICE candidate: {candidate.type} {candidate.protocol}")

    pc.addTrack(webcam_track)
    logger.info("Added webcam track to peer connection")

    # Create offer
    logger.info("Creating WebRTC offer...")
    offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    logger.info(f"Local description set, SDP length: {len(offer.sdp)}")

    print("\nCreating Overshoot stream...")

    # Create Overshoot client and stream
    client = OvershootHttpClient(api_url, api_key)

    try:
        processing = StreamProcessingConfig(
            sampling_ratio=0.8,  # Sample every other frame
            fps=30,
            clip_length_seconds=0.2,  # Shorter clips
            delay_seconds=0.2,  # More time between inferences (constraint: 30*0.5*2/5 = 6 <= 30)
        )

        inference = StreamInferenceConfig(
            prompt=prompt,
            backend="gemini",
            model="gemini-2.0-flash",  # Required field
        )

        logger.info("Sending create_stream request to Overshoot...")
        response = await client.create_stream(
            offer_sdp=pc.localDescription.sdp,
            processing=processing,
            inference=inference,
        )

        logger.info(f"Create stream response keys: {list(response.keys())}")
        stream_id = response["stream_id"]
        answer_sdp = response["webrtc"]["sdp"]
        logger.info(f"Stream ID: {stream_id}")
        logger.info(f"Answer SDP length: {len(answer_sdp)}")

        if "turn_servers" in response:
            logger.info(f"TURN servers: {response['turn_servers']}")

        print(f"Stream created: {stream_id}")

        # Set remote description
        logger.info("Setting remote description...")
        answer = RTCSessionDescription(sdp=answer_sdp, type="answer")
        await pc.setRemoteDescription(answer)
        logger.info("Remote description set successfully")

        print("WebRTC connection established")

        # Wait a moment for ICE to stabilize
        logger.info("Waiting for ICE connection to stabilize...")
        for i in range(10):
            await asyncio.sleep(0.5)
            state = pc.iceConnectionState
            logger.info(f"ICE state check {i+1}/10: {state}")
            if state in ("connected", "completed"):
                logger.info("ICE connection ready!")
                break
            elif state == "failed":
                logger.error("ICE connection failed!")
                raise Exception("ICE connection failed")
        else:
            logger.warning(f"ICE connection not fully established yet (state: {pc.iceConnectionState}), proceeding anyway...")

        # Get WebSocket URL and cookies for sticky session
        ws_url = client.get_websocket_url(stream_id)
        cookies = client.get_cookies()
        logger.info(f"WebSocket URL: {ws_url}")
        logger.info(f"Sticky session cookies: {cookies}")
        print(f"WebSocket URL: {ws_url}")

        # Start background tasks
        keepalive_task = asyncio.create_task(keepalive_loop(client, stream_id))
        ws_task = asyncio.create_task(listen_for_descriptions(ws_url, api_key, cookies))

        # Connection monitor task
        async def monitor_connection():
            last_state_log = 0
            while not connection_failed.is_set():
                await asyncio.sleep(5)
                last_state_log += 5
                if last_state_log >= 10:
                    logger.info(f"Status: WebRTC={pc.connectionState}, ICE={pc.iceConnectionState}, frames_sent={webcam_track._sent_frames}")
                    last_state_log = 0

        monitor_task = asyncio.create_task(monitor_connection())

        print("\nStreaming webcam to Overshoot...")
        print("Press Ctrl+C to stop, Q to close preview\n")

        # Show local webcam preview using shared capture
        preview_enabled = True
        try:
            while True:
                # Check if connection failed
                if connection_failed.is_set():
                    logger.error("Connection failed, stopping...")
                    break

                if preview_enabled:
                    frame = webcam_capture.get_frame()
                    if frame is not None:
                        cv2.imshow("Webcam Preview (Press Q to close)", frame)
                        key = cv2.waitKey(1) & 0xFF
                        if key == ord('q'):
                            preview_enabled = False
                            cv2.destroyAllWindows()

                await asyncio.sleep(0.03)  # ~30 FPS for preview

        except KeyboardInterrupt:
            print("\n\nStopping...")

        # Cleanup tasks
        for task in [monitor_task, keepalive_task, ws_task]:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    except ApiError as e:
        logger.error(f"API Error: {e.message} (status: {e.status_code})")
        print(f"\nAPI Error: {e.message} (status: {e.status_code})")
        if e.details:
            print(f"Details: {e.details}")
    except Exception as e:
        logger.exception(f"Unexpected error: {e}")
        print(f"\nError: {e}")
    finally:
        # Cleanup
        print("\nCleaning up...")
        webcam_capture.stop()
        cv2.destroyAllWindows()
        await pc.close()
        await client.close()
        print("Done!")


if __name__ == "__main__":
    asyncio.run(main())
