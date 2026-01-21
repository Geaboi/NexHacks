import os
import dotenv

dotenv.load_dotenv(override=True)

BASE_URL = "https://beta.woodwide.ai"
API_KEY = os.getenv("WOODWIDE_AI_API_KEY", "sk_your_api_key_here")

HEADERS = {
    "accept": "application/json",
    "Authorization": f"Bearer {API_KEY}"
}
