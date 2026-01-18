"""
Overshoot WebSocket Test

Tests the /api/overshoot/ws/stream WebSocket endpoint on your local backend.

Usage:
    python test_overshoot_websocket.py

    # With custom backend URL:
    python test_overshoot_websocket.py --url ws://localhost:8000/api/overshoot/ws/stream

    # With webcam test:
    python test_overshoot_websocket.py --webcam
"""

import asyncio
import argparse
import json
import struct
import sys
import logging
import time
from typing import Optional

import websockets
import numpy as np

# Setup logging
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s.%(msecs)03d [%(levelname)s] %(message)s',
    datefmt='%H:%M:%S'
)
logger = logging.getLogger(__name__)

# Reduce noise from websockets library
logging.getLogger("websockets").setLevel(logging.WARNING)


class OvershootWebSocketTester:
    """Test client for the Overshoot WebSocket endpoint."""

    def __init__(self, ws_url: str):
        self.ws_url = ws_url
        self.ws: Optional[websockets.WebSocketClientProtocol] = None
        self.stream_id: Optional[str] = None
        self.is_connected = False
        self.frame_count = 0
        self.inference_count = 0

    async def connect(self) -> bool:
        """Connect to the WebSocket endpoint."""
        logger.info(f"Connecting to {self.ws_url}...")
        try:
            self.ws = await websockets.connect(
                self.ws_url,
                ping_interval=30,
                ping_timeout=10,
                close_timeout=5,
            )
            self.is_connected = True
            logger.info("WebSocket connection established")
            return True
        except Exception as e:
            logger.error(f"Failed to connect: {type(e).__name__}: {e}")
            return False

    async def send_config(
        self,
        prompt: str = "Describe what you see",
        model: str = "gemini-2.0-flash",
        backend: str = "gemini",
        fps: int = 30,
        width: int = 640,
        height: int = 480,
    ) -> bool:
        """Send configuration message and wait for ready response."""
        if not self.ws:
            logger.error("Not connected")
            return False

        config = {
            "type": "config",
            "prompt": prompt,
            "model": model,
            "backend": backend,
            "fps": fps,
            "width": width,
            "height": height,
        }

        logger.info(f"Sending config: model={model}, backend={backend}, size={width}x{height}")
        logger.debug(f"Full config: {json.dumps(config, indent=2)}")

        try:
            await self.ws.send(json.dumps(config))
            logger.info("Config sent, waiting for ready response...")

            # Wait for ready response
            response = await asyncio.wait_for(self.ws.recv(), timeout=30.0)
            data = json.loads(response)
            logger.info(f"Received response: {data}")

            if data.get("type") == "ready":
                self.stream_id = data.get("stream_id")
                logger.info(f"Stream ready! stream_id={self.stream_id}")
                return True
            elif data.get("type") == "error":
                logger.error(f"Error from server: {data.get('error')}")
                return False
            else:
                logger.warning(f"Unexpected response type: {data.get('type')}")
                return False

        except asyncio.TimeoutError:
            logger.error("Timeout waiting for ready response")
            return False
        except Exception as e:
            logger.error(f"Error sending config: {type(e).__name__}: {e}")
            return False

    async def send_test_frame(self, width: int = 640, height: int = 480) -> bool:
        """Send a test frame (random colored noise)."""
        if not self.ws:
            logger.error("Not connected")
            return False

        try:
            # Create a test frame with some pattern
            frame = np.zeros((height, width, 3), dtype=np.uint8)

            # Add some color bands
            frame[:height//3, :, 0] = 255  # Red band
            frame[height//3:2*height//3, :, 1] = 255  # Green band
            frame[2*height//3:, :, 2] = 255  # Blue band

            # Add frame number text area (white box)
            frame[10:50, 10:200, :] = 255

            # Create timestamp
            timestamp = time.time()

            # Pack as binary: 8 bytes timestamp + RGB24 frame data
            timestamp_bytes = struct.pack('<d', timestamp)
            frame_bytes = frame.tobytes()
            message = timestamp_bytes + frame_bytes

            await self.ws.send(message)
            self.frame_count += 1

            if self.frame_count % 30 == 0:
                logger.info(f"Sent {self.frame_count} frames")

            return True

        except Exception as e:
            logger.error(f"Error sending frame: {type(e).__name__}: {e}")
            return False

    async def send_webcam_frame(self, frame: np.ndarray) -> bool:
        """Send a webcam frame."""
        if not self.ws:
            return False

        try:
            timestamp = time.time()
            timestamp_bytes = struct.pack('<d', timestamp)

            # Ensure frame is RGB24
            if frame.shape[2] == 3:
                frame_bytes = frame.tobytes()
            else:
                logger.warning(f"Unexpected frame shape: {frame.shape}")
                return False

            message = timestamp_bytes + frame_bytes
            await self.ws.send(message)
            self.frame_count += 1
            return True

        except Exception as e:
            logger.error(f"Error sending webcam frame: {e}")
            return False

    async def receive_messages(self):
        """Listen for incoming messages."""
        if not self.ws:
            return

        logger.info("Starting message receiver...")
        try:
            async for message in self.ws:
                if isinstance(message, str):
                    try:
                        data = json.loads(message)
                        msg_type = data.get("type", "unknown")
                        timestamp = data.get("timestamp")

                        if msg_type == "inference":
                            self.inference_count += 1
                            result = data.get("result", "")
                            logger.info(f"[INFERENCE #{self.inference_count}] timestamp={timestamp}")
                            print(f"\n{'='*60}")
                            print(f"INFERENCE RESULT #{self.inference_count}")
                            print(f"Timestamp: {timestamp}")
                            print(f"Result: {result}")
                            print(f"{'='*60}\n")

                        elif msg_type == "connected":
                            logger.info(f"Connected message: {data.get('message')}")

                        elif msg_type == "error":
                            logger.error(f"Error from server: {data.get('error')}")
                            print(f"\n[ERROR] {data.get('error')}\n")

                        elif msg_type == "prompt_updated":
                            logger.info(f"Prompt updated to: {data.get('prompt')}")

                        elif msg_type == "message":
                            logger.info(f"Server message: {data.get('data')}")

                        else:
                            logger.debug(f"Unknown message type '{msg_type}': {data}")

                    except json.JSONDecodeError as e:
                        logger.warning(f"Failed to parse JSON: {e}")
                        logger.debug(f"Raw message: {message[:200]}")

                elif isinstance(message, bytes):
                    logger.debug(f"Received binary message: {len(message)} bytes")

        except websockets.exceptions.ConnectionClosed as e:
            logger.warning(f"Connection closed: {e}")
        except Exception as e:
            logger.error(f"Error receiving messages: {type(e).__name__}: {e}")

    async def send_stop(self):
        """Send stop message."""
        if self.ws:
            try:
                await self.ws.send(json.dumps({"type": "stop"}))
                logger.info("Sent stop message")
            except Exception as e:
                logger.warning(f"Error sending stop: {e}")

    async def close(self):
        """Close the connection."""
        if self.ws:
            try:
                await self.ws.close()
                logger.info("WebSocket closed")
            except Exception:
                pass
        self.is_connected = False


async def run_test_frames(tester: OvershootWebSocketTester, duration: int = 30, fps: int = 30):
    """Send test frames for a specified duration."""
    logger.info(f"Sending test frames for {duration} seconds at {fps} FPS...")
    frame_interval = 1.0 / fps
    start_time = time.time()

    while time.time() - start_time < duration:
        await tester.send_test_frame()
        await asyncio.sleep(frame_interval)

    logger.info(f"Finished sending {tester.frame_count} test frames")


async def run_webcam_test(tester: OvershootWebSocketTester, duration: int = 60):
    """Capture and send webcam frames."""
    try:
        import cv2
    except ImportError:
        logger.error("OpenCV not installed. Run: pip install opencv-python")
        return

    logger.info("Opening webcam...")
    cap = cv2.VideoCapture(0)

    if not cap.isOpened():
        logger.error("Failed to open webcam")
        return

    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    cap.set(cv2.CAP_PROP_FPS, 30)

    logger.info(f"Webcam opened. Streaming for {duration} seconds...")
    logger.info("Press Ctrl+C to stop")

    start_time = time.time()
    try:
        while time.time() - start_time < duration:
            ret, frame = cap.read()
            if not ret:
                logger.warning("Failed to read frame")
                await asyncio.sleep(0.1)
                continue

            # Convert BGR to RGB
            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            await tester.send_webcam_frame(frame_rgb)
            await asyncio.sleep(1/30)  # ~30 FPS

    except KeyboardInterrupt:
        logger.info("Interrupted by user")
    finally:
        cap.release()
        logger.info(f"Webcam closed. Sent {tester.frame_count} frames")


async def main():
    parser = argparse.ArgumentParser(description="Test Overshoot WebSocket endpoint")
    parser.add_argument(
        "--url",
        default="ws://localhost:8000/api/overshoot/ws/stream",
        help="WebSocket URL (default: ws://localhost:8000/api/overshoot/ws/stream)"
    )
    parser.add_argument(
        "--prompt",
        default="Describe what you see in the video. Be concise.",
        help="Prompt for the AI model"
    )
    parser.add_argument(
        "--model",
        default="gemini-2.0-flash",
        help="Model to use (default: gemini-2.0-flash)"
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=30,
        help="Test duration in seconds (default: 30)"
    )
    parser.add_argument(
        "--webcam",
        action="store_true",
        help="Use webcam instead of test frames"
    )
    parser.add_argument(
        "--fps",
        type=int,
        default=30,
        help="Frames per second (default: 30)"
    )

    args = parser.parse_args()

    print("=" * 60)
    print("Overshoot WebSocket Tester")
    print("=" * 60)
    print(f"URL: {args.url}")
    print(f"Model: {args.model}")
    print(f"Duration: {args.duration}s")
    print(f"Mode: {'Webcam' if args.webcam else 'Test frames'}")
    print("=" * 60)
    print()

    tester = OvershootWebSocketTester(args.url)

    try:
        # Connect
        if not await tester.connect():
            logger.error("Failed to connect. Is the backend running?")
            sys.exit(1)

        # Send config
        if not await tester.send_config(
            prompt=args.prompt,
            model=args.model,
            fps=args.fps,
        ):
            logger.error("Failed to initialize stream")
            await tester.close()
            sys.exit(1)

        # Start receiver task
        receiver_task = asyncio.create_task(tester.receive_messages())

        # Run frame sender
        if args.webcam:
            await run_webcam_test(tester, args.duration)
        else:
            await run_test_frames(tester, args.duration, args.fps)

        # Wait a bit for final inferences
        logger.info("Waiting for final inference results...")
        await asyncio.sleep(5)

        # Cleanup
        await tester.send_stop()
        receiver_task.cancel()
        try:
            await receiver_task
        except asyncio.CancelledError:
            pass

    except KeyboardInterrupt:
        logger.info("Interrupted by user")
    except Exception as e:
        logger.exception(f"Unexpected error: {e}")
    finally:
        await tester.close()

    print()
    print("=" * 60)
    print("Test Summary")
    print("=" * 60)
    print(f"Frames sent: {tester.frame_count}")
    print(f"Inferences received: {tester.inference_count}")
    print("=" * 60)


if __name__ == "__main__":
    asyncio.run(main())
