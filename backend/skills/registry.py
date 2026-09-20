import hashlib
import json
from pathlib import Path
from jsonschema import Draft202012Validator, FormatChecker

class SkillError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code

class Registry:
    def __init__(self, root, store):
        self.store, self.skills, self.actions = store, {}, {}
        root = Path(root)
        self.root = root
        self.hermes = None
        schema=json.loads((root/'shared/skill-protocol/v1/manifest.schema.json').read_text())
        for path in sorted((root/'skills').glob('*/manifest.json')):
            raw=path.read_bytes()
            manifest=json.loads(raw)
            Draft202012Validator(schema).validate(manifest)
            instructions=(path.parent/manifest['instructions']).resolve()
            if not instructions.is_relative_to(path.parent.resolve()): raise ValueError('Instructions escape skill directory')
            if manifest['id'] in self.skills: raise ValueError('Duplicate skill ID')
            if manifest.get('default_enabled',False) and self.store.setting(manifest['id']) is None:
                self.store.set_enabled(manifest['id'],True)
            manifest['instructions_text']=instructions.read_text()[:4000]
            manifest['digest']=hashlib.sha256(raw).hexdigest()
            self.skills[manifest['id']]=manifest
            for action in manifest['actions']:
                Draft202012Validator.check_schema(action['input_schema'])
                Draft202012Validator.check_schema(action['output_schema'])
                name=action['id'].replace('.','__')
                if name in self.actions: raise ValueError('Duplicate action ID')
                if action['handler'] != action['id']: raise ValueError('Handler must match action ID in v1')
                self.actions[name]=(manifest,action)

    def resolve(self, name, arguments):
        pair=self.actions.get(name.replace('.','__'))
        if not pair: raise SkillError('CAPABILITY_UNAVAILABLE','未知动作')
        skill,action=pair
        if not self.store.enabled(skill['id']): raise SkillError('SKILL_DISABLED','技能已禁用')
        errors=list(Draft202012Validator(action['input_schema'],format_checker=FormatChecker()).iter_errors(arguments))
        if errors: raise SkillError('INVALID_ARGUMENT',errors[0].message[:400])
        return skill,action

    def tools(self, native_ids):
        return [{'type':'function','function':{'name':name,'description':action['description'],'parameters':action['input_schema']}}
                for name,(skill,action) in self.actions.items() if self.store.enabled(skill['id']) and
                (action['executor']=='python' or action['id'] in native_ids) and
                (skill['id'] != 'ark.hermes' or (self.hermes is not None and self.hermes.configured and not self.hermes.error))]

    def listing(self, native_ids, permissions):
        items=[]
        for skill in self.skills.values():
            available=all(a['executor']=='python' or a['id'] in native_ids for a in skill['actions'])
            item={k:v for k,v in skill.items() if k not in {'instructions_text'}}
            required=sorted({permission for action in skill['actions'] for permission in action['permissions']})
            item.update(
                isEnabled=self.store.enabled(skill['id']),
                available=available,
                required_permissions=required,
                permission_status={name: permissions.get(name, 'notDetermined') for name in required},
            )
            if skill['id'] == 'ark.hermes':
                item['source'] = 'hermes_runtime'
                item['available'] = self.hermes is not None and self.hermes.configured and not self.hermes.error
                item['availability_reason'] = (self.hermes.error if self.hermes else None) or ('Hermes 本地环境未配置' if not item['available'] else None)
            items.append(item)
        if self.hermes: items.extend(self.hermes.listing())
        return items
