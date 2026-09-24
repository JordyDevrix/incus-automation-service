from fastapi import FastAPI
import uvicorn

app = FastAPI(title="Incus Automation Service", version="0.1.0")

@app.get("/health")
def health():
    return {"status": "ok", "service": "incus-automation-service"}

def main():
    """CLI entrypoint invoked by the console script."""
    uvicorn.run("incus_automation_service.main:app", host="0.0.0.0", port=8000, reload=True)

if __name__ == "__main__":
    main()
