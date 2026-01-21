import os
import dotenv
import requests

dotenv.load_dotenv(override=True)

API_KEY = os.environ.get("WOODWIDE_AI_API_KEY")
BASE_URL = "https://beta.woodwide.ai"

print("API Key:", API_KEY[:10] + "..." if API_KEY else None)

# Using direct HTTP request like in routes.py
model_id = "1OZUO0uahYoua8SklFmr"
dataset_name = "timeseries1"  # Use dataset NAME, not ID

url = f"{BASE_URL}/api/models/anomaly/{model_id}/infer"
headers = {"Authorization": f"Bearer {API_KEY}"}
params = {"dataset_name": dataset_name}
data = {"coerce_schema": True}

response = requests.post(url, headers=headers, params=params, data=data)
print("Status:", response.status_code)
print("Response:", response.text[:500] if response.text else "(empty)")

if response.ok:
    result = response.json()
    print("Result:", result)