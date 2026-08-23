from fastapi import FastAPI, BackgroundTasks
from pydantic import BaseModel

from agent.core import ArkAgent


app = FastAPI()

agent = ArkAgent()


class ChatRequest(BaseModel):
    message: str


@app.get("/")
def home():
    return {
        "status": "Ark Intelligence online"
    }


@app.post("/chat")
def chat(request: ChatRequest, background_tasks: BackgroundTasks):

    response = agent.chat(
        request.message,
        background_tasks
    )

    return {
        "response": response
    }

@app.post("/session/end")
def end_session():

    result = agent.end_session()

    return {
        "status": "session consolidated",
        "result": result
    }