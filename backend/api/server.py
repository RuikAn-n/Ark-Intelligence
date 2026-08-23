import json

from fastapi import BackgroundTasks, FastAPI
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from agent.core import ArkAgent

app = FastAPI()
agent = ArkAgent()


class ChatRequest(BaseModel):
    message: str


def sse_events(message, background_tasks):
    for event in agent.chat_stream(message, background_tasks):
        yield f"event: {event['event']}\ndata: {json.dumps(event, ensure_ascii=False)}\n\n"


@app.get("/")
def home():
    return {"status": "Ark Intelligence online"}


@app.post("/chat")
def chat(request: ChatRequest, background_tasks: BackgroundTasks):
    return {"response": agent.chat(request.message, background_tasks)}


@app.post("/chat/stream")
def chat_stream(request: ChatRequest, background_tasks: BackgroundTasks):
    return StreamingResponse(
        sse_events(request.message, background_tasks),
        media_type="text/event-stream",
        background=background_tasks,
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.post("/session/end")
def end_session():
    return {"status": "session consolidated", "result": agent.end_session()}
