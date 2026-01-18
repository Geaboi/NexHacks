## Key Finding: Overshoot Needs Cookies
- Overshoot’s Media Gateway uses **sticky sessions via cookies** (e.g. `media-gateway-route`). The JS SDK sets `credentials: "include"` so the browser will store and resend those cookies automatically.
- In Python, this means we must use a **single persistent HTTP session with a cookie jar** (not one-off requests), so the `Set-Cookie` response from the first request is replayed on subsequent requests.

## Answer: “Did you implement cookies for the API?”
- **For this repo’s FastAPI backend:** no—current auth is Bearer header only ([config.py](file:///c:/Users/dang1/OneDrive/Documents/GitHub/NexHacks/backend/config.py)).
- **For connecting to Overshoot:** yes, we should implement cookie persistence because Overshoot itself relies on it.

## Implementation Plan (Python Overshoot Client)
1. **Read the overshoot-js-sdk source to extract exact endpoints + flows**
   - Identify:
     - the REST paths used by `request<T>(path, …)`
     - where the cookie is first set (which call), and what must be sent afterward
     - WebRTC signaling route(s) (offer/answer exchange) and any “session/config” calls
     - how results arrive (datachannel vs polling endpoint)
2. **Add `backend/overshoot_client.py` with two layers**
   - **HTTP layer (aiohttp)**
     - One `aiohttp.ClientSession(cookie_jar=CookieJar(...))` held for the client lifetime.
     - `request_json(path, …)` mirrors JS SDK:
       - always sends `Authorization: Bearer …`
       - includes and persists cookies automatically via the session
       - translates status codes into typed exceptions (Unauthorized/Validation/NotFound/Server/Network)
   - **Realtime layer (aiortc)**
     - Implements WebRTC connect using signaling discovered in step 1.
     - Creates a datachannel (if that’s what the SDK uses) and dispatches `on_result` callbacks.
     - Supports:
       - `start()` / `stop()`
       - `update_prompt()` (likely a REST call or a datachannel message; determined from SDK)
       - video sources: camera and file (OpenCV/av → `VideoStreamTrack`)
   - Env vars:
     - `OVERSHOOT_API_URL` (default `https://api.overshoot.ai` from the JS README)
     - `OVERSHOOT_API_KEY` (required)
3. **Optional: Backend wrapper endpoint (if you need browser-safe usage)**
   - Add a FastAPI endpoint that mints/returns a short-lived session (or proxies signaling) so the browser never sees the real API key.
   - Only do this if your frontend needs direct live streaming.

## Test Plan (Add a Test File)
1. **Add pytest** to [requirements.txt](file:///c:/Users/dang1/OneDrive/Documents/GitHub/NexHacks/backend/requirements.txt).
2. **Create `backend/tests/test_overshoot_cookies.py` (unit test, no network)**
   - Simulate a first HTTP response that sets `Set-Cookie: media-gateway-route=…`.
   - Assert the next request includes that cookie header (via the aiohttp cookie jar behavior).
3. **Create `backend/tests/test_overshoot_request_errors.py`**
   - Validate status → exception mapping (401/400/404/5xx).
4. **Add opt-in integration test (skipped unless key provided)**
   - Run only when `OVERSHOOT_API_KEY` is set; verify we can complete the initial “cookie-setting” call and proceed to the next call using the same session.

## What I’ll Deliver After You Confirm
- Working `OvershootClient` that preserves sticky-session cookies and can run a basic stream/inference loop.
- At least one test file proving cookie persistence + error handling, with network-free defaults.
