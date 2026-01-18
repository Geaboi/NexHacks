import os
import dotenv
from woodwide import WoodWide

dotenv.load_dotenv()

print(os.environ.get("WOODWIDE_AI_API_KEY"))
client = WoodWide(
    api_key=os.environ.get("WOODWIDE_AI_API_KEY"),  # This is the default and can be omitted
)

result = client.api.models.anomaly.infer(
    model_id="8gyw1IPYmLzwQCK7GeRO",
    dataset_id="hdrkG2THFEV8weO3asDA",
)

print(result)