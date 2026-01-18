import os
from woodwide import WoodWide
import dotenv

dotenv.load_dotenv()

print(os.getenv("WOODWIDE_AI_API_KEY"))

client = WoodWide(
    api_key=os.getenv("WOODWIDE_AI_API_KEY"),)


dataset_publics = client.api.datasets.list()
print(dataset_publics)


dataset_id = "hdrkG2THFEV8weO3asDA"
print("Uploaded Dataset ID:", dataset_id)



endpoint = "/api/models/anomaly/train"
data = {
    "model_name": "angles_anomaly_model",
    "overwrite": "true",
}


# Make the raw HTTP request for this endpoint, it's having issues
response = client._client.post(
    endpoint,
    params={"dataset_name": "joint_angles_timeseries1"},
    data=data,
    headers=client.auth_headers,
    )

print("Anomaly Model Training Response:", response.json())

