"""Install the Ark plugin only into this project's Hermes lab profile."""
import json
from pathlib import Path
import shutil
import yaml

root=Path(__file__).resolve().parents[1]
home=root/'.hermes-lab/hermes-home'
if not (home/'config.yaml').is_file(): raise SystemExit('请先安装 Hermes lab')
target=home/'plugins/ark-bridge'
shutil.copytree(root/'integrations/hermes/ark_bridge',target,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
actions=[]
for name in ('reminders','calendar','applications','workspace'):
    actions.extend(json.loads((root/f'skills/{name}/manifest.json').read_text())['actions'])
(target/'catalog.json').write_text(json.dumps(actions,ensure_ascii=False,indent=2)+'\n')
path=home/'config.yaml';data=yaml.safe_load(path.read_text())
enabled=data.setdefault('plugins',{}).setdefault('enabled',[])
if 'ark-bridge' not in enabled: enabled.append('ark-bridge')
path.write_text(yaml.safe_dump(data,allow_unicode=True,sort_keys=False))
print(f'Installed {len(actions)} Ark actions at {target}. Restart Hermes to load.')
