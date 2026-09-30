"""Run with python3 -m unittest discover -s scripts -p 'test_*.py'."""

import unittest
from unittest.mock import patch
from types import SimpleNamespace

import homelab


class MemoryVault:
    def __init__(self, values):
        self.values = dict(values)

    def read_secret(self, name):
        return self.values.get(name)

    def set_secret(self, name, value):
        self.values[name] = value


class OidcSecretsTest(unittest.TestCase):
    def test_existing_deployments_do_not_require_optional_webui_secrets(self):
        values = {}
        for ref, required in homelab.CATALOG.fields():
            if required:
                values.setdefault(ref.application, {})[ref.field] = "existing"
        homelab.validate_workload_secrets(values)
        self.assertNotIn("openwebui", values)

    def test_complete_pair_is_retained_without_running_generator(self):
        refs = (homelab.OPENWEBUI_CLIENT_SECRET, homelab.OPENWEBUI_CLIENT_HASH)
        vault = MemoryVault({ref.name: "existing-" + ref.field for ref in refs})
        bundle = homelab.GeneratedBundle("webui", refs, lambda: self.fail("must retain pair"))
        before = dict(vault.values)
        self.assertFalse(homelab.ensure_generated_bundle(vault, bundle))
        self.assertEqual(before, vault.values)

    def test_partial_pair_is_replaced_together(self):
        refs = (homelab.OPENWEBUI_CLIENT_SECRET, homelab.OPENWEBUI_CLIENT_HASH)
        for existing in refs:
            with self.subTest(existing=existing):
                vault = MemoryVault({existing.name: "stale"})
                generated = {refs[0]: "new-secret", refs[1]: "new-hash"}
                bundle = homelab.GeneratedBundle("webui", refs, lambda: generated)
                self.assertTrue(homelab.ensure_generated_bundle(vault, bundle))
                self.assertEqual(vault.values, {ref.name: value for ref, value in generated.items()})

    def test_generator_targets_correct_client_and_does_not_report_secret_on_error(self):
        refs = (homelab.OPENWEBUI_CLIENT_SECRET, homelab.OPENWEBUI_CLIENT_HASH)
        secret = "s" * 72
        digest = "$pbkdf2-sha512$test"
        result = SimpleNamespace(returncode=0, stdout=f"Random Password: {secret}\nDigest: {digest}\n")
        with patch("homelab.subprocess.run", return_value=result):
            self.assertEqual(homelab.generate_oidc_pair(*refs), dict(zip(refs, (secret, digest))))
        result.returncode = 1
        with patch("homelab.subprocess.run", return_value=result):
            with self.assertRaises(ValueError) as error:
                homelab.generate_oidc_pair(*refs)
        self.assertNotIn(secret, str(error.exception))
        self.assertIn("openwebui", str(error.exception))


if __name__ == "__main__":
    unittest.main()
