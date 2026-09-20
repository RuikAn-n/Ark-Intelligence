"""Workspace files and an approval-gated, macOS-sandboxed shell."""
import asyncio
import contextlib
import hashlib
import os
from pathlib import Path, PurePosixPath
import signal
import stat
import sys
import threading
import uuid

from runtime.security import runtime_dir
from skills.registry import SkillError

MAX_BYTES = 1024 * 1024

class WorkspaceExecutor:
    def __init__(self, root=None):
        self.root = Path(root or runtime_dir().parent / 'workspace').resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock = threading.Lock()
        self.shell_slot = asyncio.Lock()

    @contextlib.contextmanager
    def parent(self, relative):
        path = PurePosixPath(relative)
        if path.is_absolute() or '..' in path.parts or not path.parts or '\x00' in relative:
            raise SkillError('INVALID_ARGUMENT', '必须使用工作区内的相对路径，不能包含 ..')
        if any(part.startswith('.') for part in path.parts):
            raise SkillError('PERMISSION_DENIED', '首版文件接口不访问隐藏文件或目录')
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for part in path.parts[:-1]:
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd); fd = next_fd
            yield fd, path.name
        finally:
            os.close(fd)

    def snapshot(self, fd, name):
        try:
            handle = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        except FileNotFoundError:
            return None
        with os.fdopen(handle, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise SkillError('PERMISSION_DENIED', '只允许普通文件，不支持符号链接、硬链接或设备')
            if info.st_size > MAX_BYTES:
                raise SkillError('INVALID_ARGUMENT', '文件超过 1MB 限制')
            value = stream.read(MAX_BYTES + 1)
            if len(value) > MAX_BYTES: raise SkillError('CONFLICT', '文件在读取期间增长，请重试查询')
            return value

    def prepare(self, handler, args):
        try:
            if handler == 'workspace.write_file':
                with self.parent(args['path']) as (fd, name): value = self.snapshot(fd, name)
                version = hashlib.sha256(value).hexdigest() if value is not None else 'absent'
                if args['expected_version'] != version:
                    raise SkillError('CONFLICT', '文件已变化，请重新读取并生成预览')
                return {'summary': '创建或替换工作区文本文件（不是桌面）', 'workspace': str(self.root),
                        'absolute_path': str(self.root / args['path']),
                        'arguments': dict(args), 'version': version,
                        'before': value.decode('utf-8')[:6000] if value is not None else None,
                        'before_truncated': value is not None and len(value.decode('utf-8'))>6000}
            return {'summary': '在受限工作区执行命令（禁网络；命令可能修改工作区文件）',
                    'workspace': str(self.root), 'arguments': dict(args)}
        except (OSError, UnicodeError) as exc:
            raise SkillError('INVALID_ARGUMENT', str(exc)) from exc

    def files(self, handler, args):
        try:
            if handler == 'workspace.list_files':
                # A flat root listing keeps discovery bounded and hides no recursive traversal.
                entries=[]
                with os.scandir(self.root) as iterator:
                    for item in iterator:
                        if item.name.startswith('.'): continue
                        if len(entries) >= 100: break
                        entries.append({'name':item.name, 'kind':'symlink' if item.is_symlink() else 'directory' if item.is_dir(follow_symlinks=False) else 'file'})
                return {'workspace':str(self.root),'entries':entries,'limit':100}
            with self.lock, self.parent(args['path']) as (fd, name):
                value=self.snapshot(fd,name)
                version=hashlib.sha256(value).hexdigest() if value is not None else 'absent'
                if handler == 'workspace.read_file':
                    if value is None: return {'path':args['path'],'exists':False,'version':'absent'}
                    content=value.decode('utf-8')
                    return {'path':args['path'],'exists':True,'version':version,'content':content[:6000],'truncated':len(content)>6000}
                if args['expected_version'] != version:
                    raise SkillError('CONFLICT','文件在审批期间已变化，没有写入')
                temporary='ark-write-'+uuid.uuid4().hex
                raw=args['content'].encode('utf-8')
                try:
                    out=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
                    with os.fdopen(out,'wb') as stream:
                        stream.write(raw);stream.flush();os.fsync(stream.fileno())
                    os.replace(temporary,name,src_dir_fd=fd,dst_dir_fd=fd)
                finally:
                    with contextlib.suppress(FileNotFoundError): os.unlink(temporary,dir_fd=fd)
                actual=self.snapshot(fd,name)
                if actual != raw: raise SkillError('RESULT_UNKNOWN','写入后校验不一致，请重新读取')
                return {'path':args['path'],'absolute_path':str(self.root / args['path']),'workspace':str(self.root),
                        'location_scope':'workspace_only','version':hashlib.sha256(raw).hexdigest(),'bytes':len(raw),'verified':True}
        except (OSError, UnicodeError) as exc:
            raise SkillError('INVALID_ARGUMENT',str(exc)) from exc

    def sandbox_profile(self):
        # Dedicated workspace, no parent runtime/token access, no network or IPC services.
        escaped=str(self.root).replace('\\','\\\\').replace('"','\\"')
        return '''(version 1)
(deny default)
(import "dyld-support.sb")
(allow process-fork process-exec sysctl-read)
(allow signal (target same-sandbox))
(allow file-read-metadata)
(allow file-map-executable (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin"))
(allow file-read* (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/Library/Apple") (subpath "/private/etc") (subpath "/dev"))
(allow file-write* (literal "/dev/null") (literal "/dev/tty"))
(allow file-read* file-write* (subpath "''' + escaped + '''"))
'''

    async def shell(self, args):
        if sys.platform != 'darwin' or not Path('/usr/bin/sandbox-exec').exists():
            raise SkillError('CAPABILITY_UNAVAILABLE','当前环境没有 macOS sandbox-exec；拒绝无隔离执行')
        async with self.shell_slot:
            proc=await asyncio.create_subprocess_exec('/usr/bin/sandbox-exec','-p',self.sandbox_profile(),'/bin/sh','-c',args['command'],
                cwd=self.root,env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(self.root),'TMPDIR':str(self.root),'LANG':'en_US.UTF-8'},
                stdin=asyncio.subprocess.DEVNULL,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,start_new_session=True)
            async def drain(reader):
                chunks=bytearray(); total=0
                while chunk:=await reader.read(4096):
                    total+=len(chunk)
                    if len(chunks)<6000: chunks.extend(chunk[:6000-len(chunks)])
                return chunks.decode('utf-8',errors='replace'),total>6000
            readers=[asyncio.create_task(drain(proc.stdout)),asyncio.create_task(drain(proc.stderr))]
            try:
                await asyncio.wait_for(proc.wait(),args.get('timeout_seconds',30))
                # Stop any grandchildren that outlive their shell and keep pipes open.
                with contextlib.suppress(ProcessLookupError): os.killpg(proc.pid,signal.SIGKILL)
                out,err=await asyncio.wait_for(asyncio.gather(*readers),2)
                if proc.returncode != 0:
                    raise SkillError('EXECUTION_FAILED',f'命令退出码 {proc.returncode}；文件可能已有变化。{err[0][:350]}')
                return {'exit_code':proc.returncode,'stdout':out[0],'stderr':err[0],
                        'truncated':out[1] or err[1],'verified':True,'workspace':str(self.root)}
            except asyncio.TimeoutError as exc:
                raise SkillError('RESULT_UNKNOWN','命令超时，已停止进程组；部分文件可能已改变，请读取核实') from exc
            finally:
                with contextlib.suppress(ProcessLookupError): os.killpg(proc.pid,signal.SIGKILL)
                await proc.wait()
                for task in readers: task.cancel()
                await asyncio.gather(*readers,return_exceptions=True)

    async def execute(self, handler, args):
        if handler == 'workspace.run_command': return await self.shell(args)
        return await asyncio.to_thread(self.files,handler,args)
