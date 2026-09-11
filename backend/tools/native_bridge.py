import asyncio
import uuid
from skills.registry import SkillError

class NativeBridge:
    def __init__(self):
        self.socket=None
        self.actions=set()
        self.permissions={}
        self.pending={}

    async def serve(self, socket, registry):
        if self.socket is not None:
            await socket.close(code=1008, reason='A native host is already connected')
            return
        await socket.accept()
        try:
            hello=await asyncio.wait_for(socket.receive_json(mode='binary'),10)
            if hello.get('type')!='hello' or hello.get('protocol_version')!='1.0':
                await socket.close(code=1008); return
            offered=set(hello.get('actions',[]))
            digests=hello.get('digests',{})
            self.actions={a['id'] for s,a in registry.actions.values() if a['executor']=='native' and a['id'] in offered and digests.get(s['id'])==s['digest']}
            self.permissions=hello.get('permissions',{})
            self.socket=socket
            await socket.send_json({'type':'ready','actions':sorted(self.actions)})
            while True:
                result=await socket.receive_json(mode='binary')
                if result.get('type')=='permissions': self.permissions=result.get('permissions',{}); continue
                future=self.pending.get(result.get('message_id'))
                if future and not future.done(): future.set_result(result)
        except Exception as exc:
            print(f'[NativeBridge] disconnected: {type(exc).__name__}: {str(exc)[:300]}', flush=True)
        finally:
            if self.socket is socket:
                self.socket=None; self.actions=set(); self.permissions={}
                for future in self.pending.values():
                    if not future.done(): future.set_exception(SkillError('RESULT_UNKNOWN','原生连接中断；执行结果需要核实'))

    async def request(self, envelope):
        if not self.socket or envelope['action_id'] not in self.actions:
            raise SkillError('CAPABILITY_UNAVAILABLE','请打开 Ark 应用并连接本地原生宿主；更新技能后需要重新构建应用')
        message_id=uuid.uuid4().hex
        future=asyncio.get_running_loop().create_future()
        self.pending[message_id]=future
        try:
            await self.socket.send_json(dict(envelope,message_id=message_id))
            result=await asyncio.wait_for(future,envelope.get('timeout_ms',60000)/1000)
            if result.get('status')!='succeeded':
                error=result.get('error',{})
                raise SkillError(error.get('code','EXECUTION_FAILED'),error.get('message','原生执行失败'))
            return result.get('data',{})
        except asyncio.TimeoutError:
            raise SkillError('RESULT_UNKNOWN','原生请求超时，可能已执行，请核实目标，不能自动重试')
        finally:
            self.pending.pop(message_id,None)
