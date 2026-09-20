"""Private JSON-lines adapter. Run with Hermes' Python, never import into Ark.

Ark owns planning, approval and memory. This process only loads skills and
dispatches a bounded set of tools; no nested agent or approval bridge recursion.
"""
import contextlib
import json
import importlib.util
import os
import signal
import sys

ALLOWED_TOOLS = frozenset({
    'terminal', 'read_file', 'write_file', 'patch', 'search_files',
    'browser_navigate', 'browser_snapshot', 'browser_click', 'browser_type',
    'browser_press', 'browser_scroll', 'browser_back', 'browser_get_images',
    'browser_console', 'browser_vision', 'vision_analyze',
})
TOOLSETS = ['terminal', 'file', 'browser', 'vision']


def decode(value):
    if isinstance(value, str):
        try: return json.loads(value)
        except ValueError: return {'content': value}
    return value


def definitions():
    from model_tools import get_tool_definitions
    return {item['function']['name']: item['function'] for item in get_tool_definitions(
        enabled_toolsets=TOOLSETS, quiet_mode=True, skip_tool_search_assembly=True,
    ) if item['function']['name'] in ALLOWED_TOOLS}


def dispatch(request):
    op = request['operation']
    if op == 'catalog':
        from tools.skills_tool import skills_list, _SKILLS_CACHE
        _SKILLS_CACHE.clear()
        result = decode(skills_list())
        if result.get('success') is False or result.get('error'):
            raise ValueError(str(result.get('error', 'Hermes skill discovery failed')))
        return {'skills': result.get('skills', []), 'tools': list(definitions().values())}
    if op == 'skill':
        from tools.skills_tool import skill_view
        # Reading instructions must never run inline shell templates.
        result = decode(skill_view(request['name'], file_path=request.get('file_path'),
                                   task_id=request['run_id'], preprocess=False))
        result['runtime_python'] = sys.executable
        # Upstream readiness checks credentials, but these bundled skills also
        # require Python packages. Report missing packages before execution.
        dependencies = {'docx': ['docx'], 'xlsx': ['openpyxl'],
                        'pdf': ['pypdf', 'reportlab'], 'powerpoint': ['pptx']}
        missing = [name for name in dependencies.get(request['name'], [])
                   if importlib.util.find_spec(name) is None]
        result['missing_python_modules'] = missing
        if missing:
            result.update(setup_needed=True, readiness_status='setup_needed')
        return result
    if op == 'execute':
        name, arguments = request['name'], request['arguments']
        if name not in ALLOWED_TOOLS:
            raise ValueError('Tool is not exposed to Ark')
        from jsonschema import Draft202012Validator
        spec = definitions().get(name)
        if spec is None: raise ValueError('Tool dependencies are unavailable')
        schema = dict(spec['parameters'], additionalProperties=False)
        Draft202012Validator(schema).validate(arguments)
        if name == 'terminal':
            if arguments.get('background') or arguments.get('pty') or arguments.get('notify'):
                raise ValueError('Ark supports foreground commands only')
            if not 1 <= arguments.get('timeout', 60) <= 60:
                raise ValueError('Terminal timeout must be between 1 and 60 seconds')
            arguments = dict(arguments, timeout=arguments.get('timeout', 60))
        from model_tools import handle_function_call
        return decode(handle_function_call(name, arguments, task_id=request['run_id'],
            session_id=request['run_id'], enabled_tools=list(ALLOWED_TOOLS),
            enabled_toolsets=TOOLSETS))
    raise ValueError('Unknown operation')


def main():
    wire = sys.stdout
    # All library/plugin prints are logs, never protocol data.
    sys.stdout = sys.stderr
    def stop(*_): raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    try:
        from jsonschema import Draft202012Validator  # dependency check at startup
        from tools.terminal_scope import build_profile_terminal_scope, set_terminal_scope
        policy = build_profile_terminal_scope(os.environ['HERMES_HOME'])
        if policy.get('TERMINAL_ENV', 'local') != 'local':
            raise RuntimeError('Ark Hermes adapter requires terminal.backend: local')
        policy['TERMINAL_CWD'] = os.getcwd()
        set_terminal_scope(policy)
        for line in sys.stdin:
            try:
                request = json.loads(line)
                data = dispatch(request)
                response = {'ok': True, 'data': data}
            except Exception as exc:
                response = {'ok': False, 'error': str(exc)[:1000]}
            wire.write(json.dumps(response, ensure_ascii=False) + '\n')
            wire.flush()
    finally:
        # Hermes may promote a timed-out command to a tracked process.
        with contextlib.suppress(Exception):
            from tools.process_registry import process_registry
            process_registry.kill_all()
        with contextlib.suppress(Exception):
            from tools.terminal_tool import cleanup_all_environments
            cleanup_all_environments()


if __name__ == '__main__': main()
