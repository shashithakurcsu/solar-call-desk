#!/usr/bin/env python3
"""Offline signing setup checks. All security/codesign/openssl commands are mocked."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).with_name("configure-local-signing.py")
spec = importlib.util.spec_from_file_location("solar_local_signing", MODULE_PATH)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
IDENTITY = "A" * 40


class SigningChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="SolarCallDesk-signing-check-")
        self.root = Path(self.directory.name)
        self.project = patch.object(signing, "PROJECT_DIR", self.root)
        self.project.start()
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.project.stop()
        self.directory.cleanup()

    def write_pin(self):
        signing.write_config(IDENTITY, None, f'identifier "{signing.IDENTIFIER}" and anchor H"{IDENTITY}"', False)

    def test_default_dry_run_performs_no_system_commands(self):
        with patch.object(sys, "argv", [str(MODULE_PATH)]), patch.object(signing.subprocess, "run", side_effect=AssertionError("system command")), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(signing.main(), 0)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_missing_pin_warns_and_only_then_allows_ad_hoc(self):
        warning = io.StringIO()
        with patch.object(signing, "run", side_effect=AssertionError("system command")), contextlib.redirect_stderr(warning):
            self.assertEqual(signing.resolve_build_identity(), "-")
        self.assertIn("identity can change", warning.getvalue())

    def test_pinned_identity_and_override_require_available_certificate(self):
        self.write_pin()
        with patch.object(signing, "available_identities", return_value=set()):
            with self.assertRaises(signing.SigningError):
                signing.resolve_build_identity()
        with patch.object(signing, "available_identities", return_value={IDENTITY}):
            self.assertEqual(signing.resolve_build_identity(), IDENTITY)
        os.environ[signing.OVERRIDE] = "b" * 40
        with patch.object(signing, "available_identities", return_value={"B" * 40}):
            self.assertEqual(signing.resolve_build_identity(), "B" * 40)
        for override in ("-", "Solar signing name", "", "F" * 39, "A" * 40 + "\n"):
            os.environ[signing.OVERRIDE] = override
            with self.assertRaises(signing.SigningError):
                signing.resolve_build_identity()

    def test_malformed_pin_cannot_be_hidden_by_override(self):
        signing.config_path().write_text("not JSON")
        os.environ[signing.OVERRIDE] = IDENTITY
        with patch.object(signing, "available_identities", return_value={IDENTITY}):
            with self.assertRaises(signing.SigningError):
                signing.resolve_build_identity()

    def test_pin_atomic_permissions_and_no_overwrite(self):
        self.write_pin()
        self.assertEqual(stat.S_IMODE(signing.config_path().stat().st_mode), 0o600)
        self.assertEqual(signing.load_config()["identity_sha1"], IDENTITY)
        self.assertEqual([path.name for path in self.root.iterdir()], [".local-signing-identity"])
        with self.assertRaises(signing.SigningError):
            self.write_pin()
        signing.config_path().unlink()
        signing.config_path().symlink_to(self.root / "elsewhere")
        with self.assertRaises(signing.SigningError):
            signing.load_config()
        with self.assertRaises(signing.SigningError):
            signing.ensure_empty_config()

    def test_designated_requirement_requires_identifier_and_certificate_not_cdhash(self):
        valid = f'# designated => identifier "{signing.IDENTIFIER}" and anchor H"{IDENTITY}"'
        with patch.object(signing, "run", return_value=valid):
            self.assertIn("anchor", signing.verify_designated_requirement(self.root / "app"))
        for invalid in (f'designated => cdhash H"{IDENTITY}"',
                        f'designated => identifier "{signing.IDENTIFIER}"',
                        'designated => identifier "another.app" and anchor apple',
                        valid + f' and cdhash H"{IDENTITY}"',
                        valid + "\n" + valid):
            with patch.object(signing, "run", return_value=invalid):
                with self.assertRaises(signing.SigningError):
                    signing.verify_designated_requirement(self.root / "app")

    def test_duplicate_and_lookup_failure_prevent_creation(self):
        for status in (0, 1):
            with patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess([], status, b"public certificate" if status == 0 else b"", b"")), patch.object(signing, "run", side_effect=AssertionError("creation attempted")):
                with self.assertRaises(signing.SigningError):
                    signing.create_identity(self.root / "login.keychain-db")

    def test_empty_successful_certificate_search_is_not_a_duplicate(self):
        with patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"", b"")):
            signing.ensure_no_duplicate(self.root / "login.keychain-db")

    def simulate_creation(self, fail_import):
        commands, directories = [], []

        def simulated_run(arguments, label):
            commands.append(arguments)
            if arguments[1] == "req":
                private = Path(arguments[arguments.index("-keyout") + 1])
                directory = private.parent
                directories.append(directory)
                self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
                self.assertIn("rsa:3072", arguments)
                self.assertEqual(arguments[arguments.index("-days") + 1], "3650")
                configuration = Path(arguments[arguments.index("-config") + 1]).read_text()
                self.assertIn("CA:FALSE", configuration)
                self.assertIn("extendedKeyUsage = critical,codeSigning", configuration)
                self.assertNotIn("serverAuth", configuration)
                private.write_bytes(b"synthetic private bytes")
                self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o600)
                Path(arguments[arguments.index("-out") + 1]).write_bytes(b"synthetic public certificate")
            elif arguments[1] in ("x509", "pkcs12"):
                Path(arguments[arguments.index("-out") + 1]).write_bytes(b"synthetic certificate/bundle bytes")
            elif arguments[1] == "import":
                self.assertEqual(arguments[0], "/usr/bin/security")
                self.assertIn("-x", arguments)
                self.assertNotIn("-A", arguments)
                self.assertEqual(arguments.count("-T"), 1)
                self.assertEqual(arguments[arguments.index("-T") + 1], "/usr/bin/codesign")
                self.assertEqual(arguments[arguments.index("-P") + 1], "")
                if fail_import:
                    raise signing.SigningError("Synthetic denied import")
            return ""

        with patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess([], 44, b"", b"")), patch.object(signing, "run", side_effect=simulated_run):
            mask = os.umask(0o077)
            try:
                if fail_import:
                    with self.assertRaises(signing.SigningError):
                        signing.create_identity(self.root / "login.keychain-db")
                else:
                    self.assertRegex(signing.create_identity(self.root / "login.keychain-db"), r"^[A-F0-9]{40}$")
            finally:
                os.umask(mask)
        self.assertEqual(len(commands), 4)
        self.assertTrue(directories)
        self.assertTrue(all(not directory.exists() for directory in directories))

    def test_creation_scopes_access_and_cleans_temporary_private_files(self):
        self.simulate_creation(False)
        self.simulate_creation(True)

    def test_existing_identity_configuration_never_imports(self):
        executable = self.root / "SolarCallDesk"
        executable.write_bytes(b"synthetic executable")
        with patch.object(signing, "create_identity", side_effect=AssertionError("creation attempted")), patch.object(signing, "require_available"), patch.object(signing, "probe_identity", return_value=f'identifier "{signing.IDENTIFIER}" and anchor H"{IDENTITY}"'), contextlib.redirect_stdout(io.StringIO()):
            signing.configure(False, IDENTITY, executable)
        self.assertFalse((self.root / ".local-signing-identity.lock").exists())
        self.assertFalse(signing.load_config()["created_local_identity"])

    def test_failed_post_import_probe_leaves_no_pin_and_clears_lock(self):
        executable = self.root / "SolarCallDesk"
        executable.write_bytes(b"synthetic executable")
        with patch.object(signing, "login_keychain", return_value=self.root / "login.keychain-db"), patch.object(signing, "create_identity", return_value=IDENTITY), patch.object(signing, "require_available"), patch.object(signing, "probe_identity", side_effect=signing.SigningError("denied")):
            with self.assertRaisesRegex(signing.SigningError, "identity was imported, but no pin was written"):
                signing.configure(True, None, executable)
        self.assertFalse(signing.config_path().exists())
        self.assertFalse((self.root / ".local-signing-identity.lock").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
