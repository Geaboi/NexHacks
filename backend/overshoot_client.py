"""
Overshoot API Client with sticky session management.

This client handles communication with the Overshoot Media Gateway API,
maintaining sticky sessions via cookies for proper stream routing.
"""

from dataclasses import dataclass, field
from typing import Any, Optional
import logging
import aiohttp

logger = logging.getLogger(__name__)


# ============================================================================
# Default Configuration
# ============================================================================

DEFAULT_ICE_SERVERS = [
    {
        "urls": "turn:34.63.114.235:3478",
        "username": "1769538895:c66a907c-61f4-4ec2-93a6-9d6b932776bb",
        "credential": "Fu9L4CwyYZvsOLc+23psVAo3i/Y=",
    },
]


# ============================================================================
# Error Classes
# ============================================================================

class ApiError(Exception):
    """Base API error."""

    def __init__(
        self,
        message: str,
        status_code: int,
        request_id: Optional[str] = None,
        details: Optional[dict] = None,
    ):
        super().__init__(message)
        self.message = message
        self.status_code = status_code
        self.request_id = request_id
        self.details = details


class ValidationError(ApiError):
    """Validation error (400/422)."""

    def __init__(
        self,
        message: str,
        request_id: Optional[str] = None,
        details: Optional[dict] = None,
    ):
        super().__init__(message, 422, request_id, details)


class NotFoundError(ApiError):
    """Resource not found (404)."""

    def __init__(self, message: str, request_id: Optional[str] = None):
        super().__init__(message, 404, request_id)


class UnauthorizedError(ApiError):
    """Unauthorized (401)."""

    def __init__(self, message: str, request_id: Optional[str] = None):
        super().__init__(message, 401, request_id)


class ServerError(ApiError):
    """Server error (5xx)."""

    def __init__(
        self,
        message: str,
        request_id: Optional[str] = None,
        details: Optional[dict] = None,
    ):
        super().__init__(message, 500, request_id, details)


class NetworkError(Exception):
    """Network connectivity error."""

    def __init__(self, message: str, cause: Optional[Exception] = None):
        super().__init__(message)
        self.cause = cause


# ============================================================================
# Configuration Types
# ============================================================================

@dataclass
class StreamProcessingConfig:
    """Configuration for stream processing."""

    sampling_ratio: float = 1.0
    fps: int = 30
    clip_length_seconds: float = 3.0
    delay_seconds: float = 3.0  # Must satisfy: (fps * sampling_ratio * clip_length) / delay <= 30

    def to_dict(self) -> dict:
        return {
            "sampling_ratio": self.sampling_ratio,
            "fps": self.fps,
            "clip_length_seconds": self.clip_length_seconds,
            "delay_seconds": self.delay_seconds,
        }


@dataclass
class StreamInferenceConfig:
    """Configuration for stream inference."""

    prompt: str
    model: str  # Required (e.g., "gemini-2.0-flash")
    backend: str = "gemini"
    output_schema_json: Optional[str] = None

    def to_dict(self) -> dict:
        result = {
            "prompt": self.prompt,
            "backend": self.backend,
            "model": self.model,
        }
        if self.output_schema_json:
            result["output_schema_json"] = self.output_schema_json
        return result


@dataclass
class WebRtcOffer:
    """WebRTC offer."""

    sdp: str
    type: str = "offer"

    def to_dict(self) -> dict:
        return {"sdp": self.sdp, "type": self.type}


# ============================================================================
# Overshoot HTTP Client
# ============================================================================

class OvershootHttpClient:
    """
    Async HTTP client for the Overshoot Media Gateway API.

    Manages sticky sessions via cookies (media-gateway-route) to ensure
    requests for a given stream are routed to the same backend instance.
    """

    def __init__(self, base_url: str, api_key: str):
        """
        Initialize the client.

        Args:
            base_url: Base URL for the API (e.g., "https://cluster1.overshoot.ai/api/v0.2")
            api_key: Bearer token for authentication
        """
        if not api_key:
            raise ValueError("api_key is required")

        self.base_url = base_url.rstrip("/")
        self.api_key = api_key

        # Cookie jar for sticky session management
        self._cookie_jar = aiohttp.CookieJar()
        self._session: Optional[aiohttp.ClientSession] = None

    async def _get_session(self) -> aiohttp.ClientSession:
        """Get or create the aiohttp session with cookie support."""
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(
                cookie_jar=self._cookie_jar,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {self.api_key}",
                },
            )
        return self._session

    async def close(self) -> None:
        """Close the HTTP session."""
        if self._session and not self._session.closed:
            await self._session.close()

    async def _request(
        self,
        method: str,
        path: str,
        json_data: Optional[dict] = None,
    ) -> Any:
        """
        Make an HTTP request with error handling.

        Args:
            method: HTTP method (GET, POST, PATCH, DELETE)
            path: API path (e.g., "/streams")
            json_data: Optional JSON body

        Returns:
            Parsed JSON response

        Raises:
            ApiError subclasses for various HTTP errors
            NetworkError for connection issues
        """
        url = f"{self.base_url}{path}"
        session = await self._get_session()

        logger.debug(f"HTTP {method} {url}")
        if json_data:
            # Log request body but truncate large fields like SDP
            log_data = {}
            for k, v in json_data.items():
                if isinstance(v, str) and len(v) > 200:
                    log_data[k] = f"{v[:100]}... ({len(v)} chars)"
                elif isinstance(v, dict):
                    log_data[k] = {kk: (f"{vv[:50]}..." if isinstance(vv, str) and len(vv) > 50 else vv) for kk, vv in v.items()}
                else:
                    log_data[k] = v
            logger.debug(f"Request body: {log_data}")

        try:
            async with session.request(method, url, json=json_data) as response:
                logger.debug(f"Response status: {response.status}")

                # Log cookies for sticky session debugging
                cookies = session.cookie_jar.filter_cookies(url)
                if cookies:
                    logger.debug(f"Cookies: {dict(cookies)}")

                if response.ok:
                    result = await response.json()
                    logger.debug(f"Response keys: {list(result.keys()) if isinstance(result, dict) else type(result)}")
                    return result

                # Handle error responses
                try:
                    error_data = await response.json()
                except Exception:
                    error_data = {"error": "unknown_error", "message": response.reason}

                logger.error(f"API error {response.status}: {error_data}")
                message = error_data.get("message") or error_data.get("error", "Unknown error")
                request_id = error_data.get("request_id")
                details = error_data.get("details")

                if response.status == 401:
                    raise UnauthorizedError(message or "Invalid or revoked API key", request_id)
                elif response.status in (400, 422):
                    raise ValidationError(message, request_id, details)
                elif response.status == 404:
                    raise NotFoundError(message, request_id)
                elif response.status >= 500:
                    raise ServerError(message, request_id, details)
                else:
                    raise ApiError(message, response.status, request_id, details)

        except aiohttp.ClientError as e:
            logger.error(f"Network error: {e}")
            raise NetworkError(f"Network error: {e}", e)

    # ========================================================================
    # API Methods
    # ========================================================================

    async def create_stream(
        self,
        offer_sdp: str,
        processing: Optional[StreamProcessingConfig] = None,
        inference: Optional[StreamInferenceConfig] = None,
        request_id: Optional[str] = None,
    ) -> dict:
        """
        Create a new stream.

        Args:
            offer_sdp: WebRTC offer SDP string
            processing: Stream processing configuration
            inference: Stream inference configuration
            request_id: Optional client request ID

        Returns:
            Response containing stream_id, webrtc answer, lease info, and TURN servers
        """
        if processing is None:
            processing = StreamProcessingConfig()
        if inference is None:
            raise ValueError("inference config is required")

        body: dict = {
            "webrtc": WebRtcOffer(sdp=offer_sdp).to_dict(),
            "processing": processing.to_dict(),
            "inference": inference.to_dict(),
        }

        if request_id:
            body["client"] = {"request_id": request_id}

        return await self._request("POST", "/streams", body)

    async def keepalive(self, stream_id: str) -> dict:
        """
        Renew the stream lease.

        Args:
            stream_id: The stream ID

        Returns:
            Response containing status, stream_id, and ttl_seconds
        """
        return await self._request("POST", f"/streams/{stream_id}/keepalive")

    async def update_prompt(self, stream_id: str, prompt: str) -> dict:
        """
        Update the stream inference prompt.

        Args:
            stream_id: The stream ID
            prompt: New prompt text (min 1 character)

        Returns:
            Updated stream configuration
        """
        return await self._request(
            "PATCH",
            f"/streams/{stream_id}/config/prompt",
            {"prompt": prompt},
        )

    async def submit_feedback(
        self,
        stream_id: str,
        rating: int,
        category: str,
        feedback: Optional[str] = None,
    ) -> dict:
        """
        Submit feedback for a stream.

        Args:
            stream_id: The stream ID
            rating: Numeric rating (0-10)
            category: Feedback category
            feedback: Optional detailed feedback text

        Returns:
            Status response
        """
        body: dict = {
            "rating": rating,
            "category": category,
        }
        if feedback:
            body["feedback"] = feedback

        return await self._request("POST", f"/streams/{stream_id}/feedback", body)

    async def get_all_feedback(self) -> list:
        """
        Get all feedback entries.

        Returns:
            List of feedback objects
        """
        return await self._request("GET", "/streams/feedback")

    def get_websocket_url(self, stream_id: str) -> str:
        """
        Get the WebSocket URL for a stream.

        Args:
            stream_id: The stream ID

        Returns:
            WebSocket URL string
        """
        ws_url = self.base_url.replace("http://", "ws://").replace("https://", "wss://")
        return f"{ws_url}/ws/streams/{stream_id}"

    def get_cookies(self) -> dict:
        """
        Get the current cookies (for sticky session).

        Returns:
            Dictionary of cookie name -> value
        """
        cookies = {}
        for cookie in self._cookie_jar:
            cookies[cookie.key] = cookie.value
            logger.debug(f"Cookie: {cookie.key}={cookie.value}")
        return cookies

    async def health_check(self) -> str:
        """
        Perform a health check.

        Returns:
            Health status string
        """
        session = await self._get_session()
        url = f"{self.base_url}/healthz"
        async with session.get(url) as response:
            return await response.text()
