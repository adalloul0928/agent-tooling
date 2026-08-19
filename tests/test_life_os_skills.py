import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILLS_ROOT = REPO_ROOT / "plugins" / "personal" / "skills"

LIFE_OS_SKILLS = {
    "life-os-setup",
    "life-os-capture",
    "life-os-daily-plan",
    "life-os-day-review",
    "life-os-communications",
    "life-os-weekly-review",
    "life-os-journal",
    "life-os-voice",
    "life-os-meeting",
    "life-os-decision",
    "life-os-health-review",
    "life-os-relationship-review",
    "life-os-strategic-review",
    "life-os-chief-of-staff",
}


class LifeOSSkillTests(unittest.TestCase):
    def test_complete_skill_suite_exists_and_names_match(self):
        for name in LIFE_OS_SKILLS:
            path = SKILLS_ROOT / name / "SKILL.md"
            self.assertTrue(path.is_file(), name)
            text = path.read_text(encoding="utf-8")
            self.assertRegex(text, rf"(?m)^name: {re.escape(name)}$")
            self.assertIn("../../runtime/references/workflow-contract.md", text)

    def test_every_description_has_positive_and_negative_trigger_boundaries(self):
        for name in LIFE_OS_SKILLS:
            text = (SKILLS_ROOT / name / "SKILL.md").read_text(encoding="utf-8")
            frontmatter = text.split("---", 2)[1]
            self.assertRegex(frontmatter, r"\bUse (?:for|when)\b", name)
            self.assertIn("Do not", frontmatter, name)

    def test_impersonating_actions_are_confirmation_gated(self):
        communications = (SKILLS_ROOT / "life-os-communications" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("requires Aren to see and confirm the exact recipient", communications)
        self.assertIn("Sending Gmail or iMessage always requires", communications)
        self.assertIn("Do not include raw bodies", communications)

    def test_chief_of_staff_cannot_weaken_policy(self):
        text = (SKILLS_ROOT / "life-os-chief-of-staff" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("No sub-workflow may bypass the action policy", text)
        self.assertIn("Prohibited actions remain prohibited", text)

    def test_health_skill_has_non_medical_boundary(self):
        text = (SKILLS_ROOT / "life-os-health-review" / "SKILL.md").read_text(encoding="utf-8")
        for phrase in ("Never diagnose", "never as a medical authority", "read-only"):
            self.assertIn(phrase, text)

    def test_runtime_contract_defines_authorities_and_confidence_thresholds(self):
        text = (REPO_ROOT / "plugins" / "personal" / "runtime" / "references" / "workflow-contract.md").read_text(encoding="utf-8")
        for authority in ("TickTick", "Obsidian", "Gmail", "iMessage", "Oura", "Apple Health"):
            self.assertIn(authority, text)
        self.assertIn("0.55–0.84", text)
        self.assertIn("0.85 or higher", text)

    def test_activation_script_uses_bounded_private_canaries(self):
        text = (REPO_ROOT / "scripts" / "activate-life-os").read_text(encoding="utf-8")
        self.assertIn("umask 077", text)
        self.assertIn("--lookback-hours 24 --chat-limit 1 --message-limit 1", text)
        self.assertIn("raw_bodies_retained:false", text)
        self.assertIn("connector-verify ticktick", text)
        self.assertIn("connector-verify imessage", text)
        self.assertNotIn("imsg send", text)

    def test_host_preflight_is_read_only_and_checks_production_prerequisites(self):
        source = (REPO_ROOT / "scripts" / "life-os-host-preflight").read_text(encoding="utf-8")
        self.assertIn('model == "Mac mini"', source)
        self.assertIn('"pmset", "-g", "custom"', source)
        self.assertIn('"chatgpt-login-item"', source)
        self.assertIn('"tailscale"', source)
        self.assertNotIn("subprocess.run(\"sudo\"", source)
        self.assertNotIn("pmset -a", source)

    def test_remote_deployer_is_dry_run_scoped_and_non_deleting(self):
        source = (REPO_ROOT / "scripts" / "deploy-life-os-to-host").read_text(encoding="utf-8")
        self.assertIn("--dry-run", source)
        self.assertIn("--apply", source)
        self.assertIn("remote checkout has changes overlapping", source)
        self.assertIn("plugins/personal/runtime/", source)
        self.assertIn("-name 'life-os-*'", source)
        self.assertNotIn("--delete", source)


if __name__ == "__main__":
    unittest.main()
