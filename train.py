import os
from woodwide import WoodWide
import dotenv

dotenv.load_dotenv(override=True)

print(os.getenv("WOODWIDE_AI_API_KEY"))

client = WoodWide(
    api_key=os.getenv("WOODWIDE_AI_API_KEY"),)

with open("tmp2qss_58w.csv", "rb") as f:
    dataset = client.api.datasets.upload(
        file=f,
        name="timeseries1",
        overwrite=True,
    )

dataset_id = dataset.id

print("Uploaded Dataset ID:", dataset_id)

dataset_publics = client.api.datasets.list()
print(dataset_publics)





endpoint = "/api/models/anomaly/train"
data = {
    "model_name": "anomaly_model",
    "overwrite": "true",
}


# Make the raw HTTP request for this endpoint, it's having issues
response = client._client.post(
    endpoint,
    params={"dataset_name": "timeseries1"},
    data=data,
    headers=client.auth_headers,
    )

print("Anomaly Model Training Response:", response.json())

