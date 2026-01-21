import os
import dotenv

dotenv.load_dotenv()
def _overshoot_api_key() -> str:
    api_key = os.getenv("OVERSHOOT_API_KEY", "")
    if not api_key:
        return "Not confiugred"
    return api_key
