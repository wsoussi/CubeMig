from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app_routes import logs, k8s, migration, config, simulation, tee_encapsulation
import logging
import urllib3

# Kubeconfig may use insecure-skip-tls-verify for some clusters (e.g. self-signed API without
# embedded CA). urllib3 would log InsecureRequestWarning on every API call; disable that noise.
# For proper TLS like other contexts, remove insecure-skip-tls-verify and set certificate-authority-data.
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

app = FastAPI()

origins = [
    "http://160.85.255.146:4200"
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(migration.router, prefix="", tags=["Migrations"])
app.include_router(logs.router, prefix="/logs", tags=["Logs"])
app.include_router(k8s.router, prefix="/k8s", tags=["Kubernetes"])
app.include_router(config.router, prefix="/config", tags=["Configuration"])
app.include_router(simulation.router, prefix="/simulate", tags=["Attack Simulation"])
app.include_router(tee_encapsulation.router, prefix="/tee-operation", tags=["TEE Encapsulation"])

class IgnoreAlertEndpoint(logging.Filter):
    def filter(self, record):
        return "POST /alert" not in record.getMessage()

logging.getLogger("uvicorn.access").addFilter(IgnoreAlertEndpoint())


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)