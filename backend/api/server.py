import json

from fastapi import BackgroundTasks, FastAPI, HTTPException, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from agent.core import ArkAgent
from memory.database import (
    delete_memory,
    delete_memory_permanently,
    get_all_memories,
    save_memory,
    update_memory,
)

app = FastAPI()
agent = ArkAgent()


class ChatRequest(BaseModel):
    message: str


class MemoryRequest(BaseModel):
    content: str = Field(min_length=1)
    category: str = "general"
    memory_type: str = "fact"
    source: str = "manual"
    confidence: float = 1.0
    importance: float = 0.5


def _memory_response(memory_id):
    memories = get_all_memories(include_deleted=True)
    for memory in memories:
        if memory["id"] == memory_id:
            return memory
    raise HTTPException(status_code=404, detail="Memory not found")


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


@app.get("/memories")
def list_memories(include_deleted: bool = Query(False)):
    return {"memories": get_all_memories(include_deleted=include_deleted)}


@app.post("/memories", status_code=201)
def create_memory(request: MemoryRequest):
    memory_id = save_memory(
        request.content,
        request.category,
        request.memory_type,
        request.source,
        request.confidence,
        request.importance,
    )
    if memory_id is None:
        raise HTTPException(status_code=409, detail="Memory already exists")
    return _memory_response(memory_id)


@app.patch("/memories/{memory_id}")
def edit_memory(memory_id: int, request: MemoryRequest):
    try:
        update_memory(memory_id, request.content, request.category, request.memory_type)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return _memory_response(memory_id)


@app.delete("/memories/{memory_id}")
def remove_memory(memory_id: int, permanent: bool = Query(False)):
    try:
        if permanent:
            delete_memory_permanently(memory_id)
        else:
            delete_memory(memory_id)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return {"status": "deleted", "permanent": permanent}


@app.post("/session/end")
def end_session():
    return {"status": "session consolidated", "result": agent.end_session()}
