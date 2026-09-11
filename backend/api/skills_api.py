import asyncio
from pathlib import Path
from typing import Literal
from zoneinfo import ZoneInfo
from fastapi import APIRouter, HTTPException, WebSocket, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field, field_validator
from runtime.security import runtime_dir, authenticated
from runtime.store import Store
from skills.registry import Registry, SkillError
from tools.native_bridge import NativeBridge
from agent.run_service import RunService

class HistoryMessage(BaseModel):
    role: Literal['user','assistant']
    content: str = Field(max_length=4000)

class RunRequest(BaseModel):
    input_mode: Literal['text', 'voice'] = 'text'
    session_id: str = Field(pattern=r'^[a-zA-Z0-9-]{1,64}$')
    message: str = Field(min_length=1,max_length=4000)
    current_time: str = Field(max_length=100)
    timezone: str = Field(max_length=100)
    history: list[HistoryMessage] = Field(default_factory=list,max_length=12)
    action_id: str | None = Field(default=None,max_length=100)
    arguments: dict = Field(default_factory=dict)

    @field_validator('timezone')
    @classmethod
    def valid_timezone(cls,value):
        try: ZoneInfo(value)
        except Exception: raise ValueError('Invalid IANA timezone')
        return value

    @field_validator('current_time')
    @classmethod
    def valid_time(cls,value):
        from datetime import datetime
        parsed=datetime.fromisoformat(value.replace('Z','+00:00'))
        if not parsed.tzinfo: raise ValueError('Timezone offset required')
        return value

class EnabledRequest(BaseModel):
    enabled: bool

class ApprovalRequest(BaseModel):
    call_id: str
    digest: str
    approved: bool

class SessionRequest(BaseModel):
    session_id: str


def create_skill_router(agent,token):
    router=APIRouter()
    store=Store(runtime_dir()/'runs.sqlite3')
    registry=Registry(Path(__file__).resolve().parents[2],store)
    bridge=NativeBridge()
    service=RunService(store,registry,bridge,agent)

    def get_run(id):
        run=store.get_run(id)
        if not run: raise HTTPException(404,'任务不存在')
        return run

    @router.get('/skills')
    def skills(): return {'skills':registry.listing(bridge.actions,bridge.permissions)}

    @router.get('/skills/{id}')
    def skill(id:str):
        for item in registry.listing(bridge.actions,bridge.permissions):
            if item['id']==id: return item
        raise HTTPException(404,'技能不存在')

    @router.patch('/skills/{id}')
    async def toggle(id:str,request:EnabledRequest):
        if id not in registry.skills: raise HTTPException(404,'技能不存在')
        store.set_enabled(id,request.enabled)
        if not request.enabled:
            for run_id in list(service.tasks):
                run=store.get_run(run_id)
                if run and id in run.get('skill_ids',[]): await service.cancel(run_id)
        return {'status':'updated'}

    @router.post('/runs',status_code=201)
    async def create_run(request:RunRequest):
        try: return service.create(request)
        except SkillError as exc: raise HTTPException(409,str(exc))

    @router.get('/runs')
    def runs(session_id:str|None=None,active_only:bool=False,limit:int=Query(50,ge=1,le=200)):
        return {'runs':store.list_runs(session_id=session_id,active_only=active_only,limit=limit)}

    @router.get('/runs/{id}')
    def run(id:str): return get_run(id)

    @router.get('/runs/{id}/calls')
    def calls(id:str):
        get_run(id)
        return {'calls':store.calls(id)}

    @router.get('/runs/{id}/events')
    async def events(id:str,after:int=Query(0,ge=0)):
        get_run(id)
        return StreamingResponse(service.events(id,after),media_type='text/event-stream',headers={'Cache-Control':'no-cache','X-Accel-Buffering':'no'})

    @router.post('/runs/{id}/approvals')
    async def approve(id:str,request:ApprovalRequest):
        get_run(id)
        try: service.approve(id,request.call_id,request.digest,request.approved)
        except SkillError as exc: raise HTTPException(409,str(exc))
        return {'status':'received'}

    @router.post('/runs/{id}/cancel')
    async def cancel(id:str):
        get_run(id);await service.cancel(id)
        return {'status':'cancellation_requested'}

    @router.post('/sessions/end')
    async def end_session(request:SessionRequest):
        if service.active_for_session(request.session_id): raise HTTPException(409,'请先完成或取消本次对话的后台任务')
        messages=store.messages(request.session_id)
        if messages:
            async with service.inference_lock:
                conversation=[m for m in messages if m['role'] in {'user','assistant'} and m.get('content')]
                result=await asyncio.to_thread(agent.consolidator.consolidate,conversation,agent.memory.recall_all())
                await asyncio.to_thread(agent.memory.apply_consolidation,result)
                store.save_messages(request.session_id,[])
        return {'status':'session consolidated'}

    @router.websocket('/native/bridge')
    async def native(socket:WebSocket):
        # Browsers cannot attach this bearer header through the WebSocket constructor.
        # URLSession may attach Origin, so only the native bridge relaxes that check.
        if not authenticated(socket.headers,token,allow_origin=True): await socket.close(code=1008); return
        await bridge.serve(socket,registry)

    return router,service
