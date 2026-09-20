"""Configure the existing project Hermes lab for Ark's reverse adapter.

Does not install/upgrade Hermes or OMH. All dependencies stay in the lab.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import yaml


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--without-browser', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    lab = root / '.hermes-lab'
    home = lab / 'hermes-home'
    python = lab / 'venv/bin/python'
    config = home / 'config.yaml'
    if not python.is_file() or not config.is_file():
        raise SystemExit('请先安装 Hermes lab，或使用 ARK_HERMES_* 连接自己的 Hermes 环境。')
    if not shutil.which('uv'): raise SystemExit('需要 uv 来管理 Hermes 独立环境依赖。')
    subprocess.run(['uv', 'pip', 'install', '--python', str(python),
                    '-r', str(root / 'integrations/hermes/requirements-ark.txt')], check=True)
    if not args.without_browser:
        subprocess.run(['npm', 'install', '--prefix', str(home), '--cache', str(lab / 'npm-cache'),
                        '--save-exact', 'agent-browser@0.26.0'], check=True)
        subprocess.run([str(home / 'node_modules/.bin/agent-browser'), '--version'], check=True)
        # Local browser automation must not auto-select a paid cloud provider.
        data = yaml.safe_load(config.read_text()) or {}
        data.setdefault('browser', {})['cloud_provider'] = 'local'
        data['browser']['backend'] = 'off'  # Hermes' built-in agent-browser tools
        config.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False))
    subprocess.run([str(python), str(root / 'scripts/install_hermes_bridge.py')], check=True)
    print('Hermes runtime ready. Restart the Ark backend and refresh Skill 管理.')


if __name__ == '__main__': main()
