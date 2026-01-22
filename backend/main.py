import uvicorn
from fastapi import FastAPI

from routes import health_router, auth_router, datasets_router, models_router, pose_router, overshoot_router

app = FastAPI(title="Wood Wide AI Proxy API")

app.include_router(health_router)
app.include_router(auth_router)
app.include_router(datasets_router)
app.include_router(models_router)
app.include_router(pose_router)
app.include_router(overshoot_router)


if __name__ == "__main__":
    # Add .%(msecs)03d to the end of asctime for both formatters
    uvicorn.config.LOGGING_CONFIG["formatters"]["default"]["fmt"] = "%(asctime)s.%(msecs)03d [%(name)s] %(levelprefix)s %(message)s"
    uvicorn.config.LOGGING_CONFIG["formatters"]["access"]["fmt"] = '%(asctime)s.%(msecs)03d [%(name)s] %(levelprefix)s %(client_addr)s - "%(request_line)s" %(status_code)s'
    
    # Use the custom date format (without milliseconds here, as they are added above)
    uvicorn.config.LOGGING_CONFIG["formatters"]["default"]["datefmt"] = "%Y-%m-%d %H:%M:%S"
    uvicorn.config.LOGGING_CONFIG["formatters"]["access"]["datefmt"] = "%Y-%m-%d %H:%M:%S"
    
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True, log_level="debug", log_config=uvicorn.config.LOGGING_CONFIG)