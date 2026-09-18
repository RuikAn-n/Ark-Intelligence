import os
import secrets
from pathlib import Path

DEFAULT_DIR = Path.home()/'Library/Application Support/ArkIntelligence/runtime'

def runtime_dir(): return Path(os.getenv('ARK_RUNTIME_DIR',str(DEFAULT_DIR)))

def get_token(name='token'):
    folder=runtime_dir(); folder.mkdir(parents=True,exist_ok=True,mode=0o700)
    if name not in {'token','hermes-token'}: raise ValueError('Unknown token purpose')
    path=folder/name
    try:
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as f: f.write(secrets.token_urlsafe(32))
    except FileExistsError: pass
    path.chmod(0o600)
    value=path.read_text().strip()
    if len(value)<32: raise RuntimeError('Invalid local authentication token')
    return value

def authenticated(headers, token, allow_origin=False):
    host=headers.get('host','').split(':')[0]
    # Native client has no Origin; arbitrary browser origins are deliberately rejected.
    origin_allowed = allow_origin or not headers.get('origin')
    return host in {'127.0.0.1','localhost'} and origin_allowed and secrets.compare_digest(headers.get('authorization',''),'Bearer '+token)
