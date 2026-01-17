import uvicorn
from fastapi import FastAPI

from routes import health_router, auth_router, datasets_router, models_router, pose_router

app = FastAPI(title="Wood Wide AI Proxy API")

app.include_router(health_router)
app.include_router(auth_router)
app.include_router(datasets_router)
app.include_router(models_router)
app.include_router(pose_router)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
