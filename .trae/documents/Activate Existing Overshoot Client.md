I will implement the Overshoot API integration from scratch as requested, using `backend/overshoot.py`.

### **Implementation Plan**
1.  **Cleanup**: Delete the old `backend/overshoot_opencv.py` to start fresh.
2.  **Core Implementation (`backend/overshoot.py`)**:
    *   Create a clean, asynchronous `OvershootClient` class.
    *   Implement WebRTC signaling and streaming using `aiortc` and `aiohttp`.
    *   **Authentication**: Configure it to automatically load `OVERSHOOT_API_KEY` from your `.env` file.
    *   **Features**: Add methods for common tasks: `connect()`, `stream_camera()`, and `update_prompt()`.
3.  **Configuration**: Update your `.env` file to include a placeholder for `OVERSHOOT_API_KEY` if it's not already there.
4.  **Verification**: Create a simple script `backend/test_overshoot.py` that connects to your camera and prints the AI's description of the scene to the console.

I will begin by cleaning up the old file and writing the new client.