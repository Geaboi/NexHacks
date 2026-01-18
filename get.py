import os
import dotenv
from woodwide import WoodWide

dotenv.load_dotenv()

print(os.environ.get("WOODWIDE_AI_API_KEY"))
client = WoodWide(
    api_key=os.environ.get("WOODWIDE_AI_API_KEY"),  # This is the default and can be omitted
)
model_public = client.api.models.retrieve(
    model_id="8gyw1IPYmLzwQCK7GeRO",
)
print(model_public)