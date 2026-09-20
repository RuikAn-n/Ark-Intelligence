"""Hermes capabilities without importing its conflicting agent/tools packages."""
import asyncio
import contextlib
import hashlib
import json
import os
from pathlib import Path
import signal
import time

from jsonschema import Draft202012Validator, FormatChecker
from skills.registry import SkillError


def skill_id(name):
    return 'hermes.skill.' + hashlib.sha256(name.encode()).hexdigest()[:20]


class Worker:
    def __init__(self, command, env, cwd):
        self.command, self.env, self.cwd = command, env, cwd
        self.process = None
        self.lock = asyncio.Lock()

    async def request(self, payload, timeout=90):
        async with self.lock:
            try:
                if self.process is None:
                    self.process = await asyncio.create_subprocess_exec(*self.command,
                        cwd=self.cwd, env=self.env, stdin=asyncio.subprocess.PIPE,
                        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
                        limit=4 * 1024 * 1024, start_new_session=True)
                self.process.stdin.write((json.dumps(payload) + '\n').encode())
                await self.process.stdin.drain()
                line = await asyncio.wait_for(self.process.stdout.readline(), timeout)
                if not line: raise OSError('Hermes worker exited')
                result = json.loads(line)
                if not result.get('ok'):
                    raise SkillError('EXECUTION_FAILED', result.get('error', 'Hermes tool failed'))
                return result['data']
            except asyncio.CancelledError:
                await self.close()
                raise
            except (OSError, ValueError, asyncio.TimeoutError) as exc:
                await self.close()
                code = 'RESULT_UNKNOWN' if payload['operation'] == 'execute' else 'CAPABILITY_UNAVAILABLE'
                raise SkillError(code, 'Hermes 连接中断或超时；已发出的操作请核实结果') from exc

    async def close(self):
        process, self.process = self.process, None
        if process is None: return
        if process.returncode is None:
            with contextlib.suppress(ProcessLookupError): os.killpg(process.pid, signal.SIGTERM)
            try: await asyncio.wait_for(process.wait(), 3)
            except asyncio.TimeoutError:
                with contextlib.suppress(ProcessLookupError): os.killpg(process.pid, signal.SIGKILL)
                await process.wait()


class HermesIntegration:
    def __init__(self, root, store, worker_factory=None):
        self.root, self.store = Path(root), store
        lab = self.root / '.hermes-lab'
        self.home = Path(os.getenv('ARK_HERMES_HOME', str(lab / 'hermes-home'))).expanduser()
        self.python = Path(os.getenv('ARK_HERMES_PYTHON', str(lab / 'venv/bin/python'))).expanduser()
        self.cwd = Path(os.getenv('ARK_HERMES_WORKSPACE', str(lab / 'workspace'))).expanduser()
        self.worker_factory = worker_factory
        self.workers = {}
        self.skills, self.tools = {}, {}
        self.error = None
        self.updated = 0
        self.catalog_lock = asyncio.Lock()

    @property
    def configured(self):
        return self.worker_factory is not None or (self.python.is_file() and (self.home / 'config.yaml').is_file() and self.cwd.is_dir())

    def worker(self, run_id):
        if run_id not in self.workers:
            if not self.configured: raise SkillError('CAPABILITY_UNAVAILABLE', 'Hermes 未安装；请配置本地 Hermes Python、Home 和工作目录')
            env = dict(os.environ, HERMES_HOME=str(self.home), HERMES_QUIET='1',
                       HERMES_REDACT_SECRETS='true', PYTHONUNBUFFERED='1')
            # Do not leak Ark's PYTHONPATH into Hermes' identically named packages.
            env.pop('PYTHONPATH', None)
            env['PATH'] = str(self.python.parent) + os.pathsep + env.get('PATH', '')
            # Use an isolated automation profile with the installed Chrome binary.
            chrome = Path('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
            if chrome.is_file(): env.setdefault('AGENT_BROWSER_EXECUTABLE_PATH', str(chrome))
            self.workers[run_id] = (self.worker_factory() if self.worker_factory else
                Worker([str(self.python), str(self.root / 'integrations/hermes/worker.py')], env, str(self.cwd)))
        return self.workers[run_id]

    async def close(self, run_id):
        worker = self.workers.pop(run_id, None)
        if worker: await worker.close()

    async def refresh(self, force=False):
        async with self.catalog_lock:
            if not force and time.monotonic() - self.updated < 30: return
            try:
                data = await self.worker('catalog').request({'operation': 'catalog'}, timeout=30)
                self.skills = {s['name']: s for s in data['skills']}
                self.tools = {t['name']: t for t in data['tools']}
                self.error = None
            except SkillError as exc:
                self.skills, self.tools = {}, {}
                self.error = str(exc)
            finally:
                self.updated = time.monotonic()
                await self.close('catalog')

    def enabled(self, name):
        return self.store.setting(skill_id(name)) is not False

    def listing(self):
        master = self.store.enabled('ark.hermes')
        return [dict(id=skill_id(name), name=name, version='1.0.0',
            description=s.get('description') or 'Hermes 工作流技能', icon='books.vertical',
            isEnabled=self.enabled(name), available=master and not self.error,
            required_permissions=[], permission_status={}, actions=[], source='hermes',
            category=s.get('category'), availability_reason=None if master else '请先启用 Hermes 本地能力',
        ) for name, s in sorted(self.skills.items())]

    def require_skill(self, name):
        if name not in self.skills: raise SkillError('CAPABILITY_UNAVAILABLE', 'Hermes 技能不存在、已在 Hermes 禁用或不支持本机平台')
        if not self.enabled(name): raise SkillError('SKILL_DISABLED', 'Hermes 技能已在 Ark 禁用')

    async def prepare(self, handler, args, run_id):
        await self.refresh()
        if self.error: raise SkillError('CAPABILITY_UNAVAILABLE', self.error)
        if handler == 'hermes.skill_view': self.require_skill(args['name'])
        if handler != 'hermes.execute': return {}
        spec = self.tools.get(args['name'])
        if not spec: raise SkillError('CAPABILITY_UNAVAILABLE', '此 Hermes 工具未接入或依赖未就绪，请先查询工具目录')
        schema = dict(spec['parameters'], additionalProperties=False)
        errors = list(Draft202012Validator(schema, format_checker=FormatChecker()).iter_errors(args['arguments']))
        if errors: raise SkillError('INVALID_ARGUMENT', errors[0].message[:400])
        if args['name'] == 'terminal':
            a = args['arguments']
            if a.get('background') or a.get('pty') or a.get('notify') or not 1 <= a.get('timeout', 60) <= 60:
                raise SkillError('INVALID_ARGUMENT', '仅支持前台非交互命令，超时为 1–60 秒')
        return {'summary': '通过 Hermes 执行 ' + args['name'], 'tool': args['name'],
                'arguments': args['arguments'], 'working_directory': args['arguments'].get('workdir', str(self.cwd)),
                'execution_scope': 'Hermes 本机账户权限，可访问工作区外文件和网络；此操作需单独确认',
                'schema_digest': hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()}

    async def execute(self, handler, args, run_id):
        if handler == 'hermes.skills_list':
            query = args.get('query', '').casefold()
            items = [s for name, s in self.skills.items() if self.enabled(name) and
                (not query or query in (name + ' ' + (s.get('description') or '') + ' ' + (s.get('category') or '')).casefold())]
            offset, limit = args.get('offset', 0), args.get('limit', 12)
            return {'skills': items[offset:offset+limit], 'total': len(items),
                    'next_offset': offset+limit if offset+limit < len(items) else None}
        if handler == 'hermes.tools_list':
            if args.get('name'):
                spec = self.tools.get(args['name'])
                if not spec: raise SkillError('CAPABILITY_UNAVAILABLE', '工具未接入或所需依赖不可用')
                return {'tool': spec, 'requires_approval': True}
            return {'tools': [{'name': n, 'description': t['description'][:240]} for n, t in self.tools.items()],
                    'hint': '使用 name 查询完整参数，再调用 hermes.execute；所有执行均须 Ark 审批。'}
        if handler == 'hermes.skill_view':
            self.require_skill(args['name'])
            data = await self.worker(run_id).request(dict(operation='skill', run_id=run_id,
                name=args['name'], file_path=args.get('file_path')))
            self.check_result(data)
            # Keep large skills usable via explicit pages instead of silent truncation.
            content = data.get('content', '')
            offset, limit = args.get('offset', 0), args.get('limit', 6000)
            data['content'] = content[offset:offset+limit]
            data['total_chars'] = len(content)
            data['next_offset'] = offset+limit if offset+limit < len(content) else None
            data.pop('_source_path', None)
            return data
        if handler == 'hermes.execute':
            data = await self.worker(run_id).request(dict(operation='execute', run_id=run_id,
                name=args['name'], arguments=args['arguments']))
            self.check_result(data)
            if isinstance(data, dict) and data.get('_multimodal'):
                return {'multimodal': data}
            rendered = json.dumps(data, ensure_ascii=False)
            if len(rendered) > 12000:
                return {'output': rendered[:12000], 'truncated': True,
                        'hint': '返回内容已截断，请缩小读取范围；不能根据截断内容断言业务结果。'}
            return {'result': data, 'hint': '这是工具执行结果；文件和系统变更应读回核验后再报告完成。'}
        raise SkillError('CAPABILITY_UNAVAILABLE', '未知 Hermes 动作')

    @staticmethod
    def check_result(data):
        if isinstance(data, dict) and (data.get('error') or data.get('success') is False or
                data.get('ok') is False or data.get('status') in {'error', 'failed'} or
                data.get('isError') or data.get('exit_code') not in (None, 0)):
            raise SkillError('EXECUTION_FAILED', str(data.get('error') or data)[:500])
        if isinstance(data, dict) and data.get('status') in {'running', 'background', 'timeout'}:
            raise SkillError('RESULT_UNKNOWN', 'Hermes 操作未在前台完成，必须核实结果，不能自动重试')
