import json
import tempfile
import unittest
from pathlib import Path

from jsonschema import ValidationError

from runtime.store import Store
from skills.registry import Registry, SkillError


ROOT = Path(__file__).resolve().parents[2]


class SkillContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name) / "runs.sqlite3")
        self.registry = Registry(ROOT, self.store)

    def tearDown(self):
        self.temp.cleanup()

    def test_all_manifests_load_and_actions_are_unique(self):
        self.assertEqual(set(self.registry.skills), {
            "ark.applications", "ark.calendar", "ark.reminders", "ark.example", "ark.web_search", "ark.workspace", "ark.hermes"
        })
        action_ids = [action["id"] for _, action in self.registry.actions.values()]
        self.assertEqual(len(action_ids), len(set(action_ids)))

    def test_disabled_skill_is_not_exposed_or_callable(self):
        tools = self.registry.tools({"applications.find_apps"})
        self.assertNotIn("applications__find_apps",[item["function"]["name"] for item in tools])
        with self.assertRaisesRegex(SkillError, "技能已禁用"):
            self.registry.resolve("applications__find_apps", {"query": "Safari"})

    def test_web_search_is_enabled_on_first_install_and_respects_user_choice(self):
        self.assertTrue(self.store.enabled("ark.web_search"))
        names=[item["function"]["name"] for item in self.registry.tools(set())]
        self.assertIn("web__search",names)
        self.store.set_enabled("ark.web_search",False)
        Registry(ROOT,self.store)
        self.assertFalse(self.store.enabled("ark.web_search"))

    def test_enabled_skill_validates_arguments(self):
        self.store.set_enabled("ark.applications", True)
        names = [item["function"]["name"] for item in self.registry.tools({"applications.find_apps"})]
        self.assertIn("applications__find_apps", names)
        with self.assertRaisesRegex(SkillError, "required property"):
            self.registry.resolve("applications__find_apps", {})

    def test_manifest_schema_rejects_unknown_fields(self):
        schema = json.loads((ROOT / "shared/skill-protocol/v1/manifest.schema.json").read_text())
        manifest = json.loads((ROOT / "skills/example/manifest.json").read_text())
        manifest["unexpected"] = True
        from jsonschema import Draft202012Validator
        with self.assertRaises(ValidationError):
            Draft202012Validator(schema).validate(manifest)


if __name__ == "__main__":
    unittest.main()
