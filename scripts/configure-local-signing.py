#!/usr/bin/env python3
"""Opt-in, login-Keychain-only signing setup; without an action, print a dry run.

The pin contains public certificate metadata only. Provisioning never alters trust,
TCC, existing item ACLs, or the installed app. Private temporary files are removed
even if import/signature verification fails.
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile

PROJECT_DIR = Path(__file__).resolve().parent.parent
IDENTIFIER = "local.solar.calldesk"
COMMON_NAME = "Solar Call Desk Local Signing"
OVERRIDE = "SOLARCALLDESK_SIGNING_IDENTITY"


class SigningError(Exception):
    pass


def config_path():
    return PROJECT_DIR / ".local-signing-identity"


def sha1_identity(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9A-Fa-f]{40}", value):
        raise SigningError("Signing identity must be an exact 40-character certificate SHA-1 hash.")
    return value.upper()


def run(arguments, label):
    # Do not echo commands, stderr, certificate bundles, or any private material.
    try:
        result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=25)
    except subprocess.TimeoutExpired as error:
        raise SigningError(f"{label} timed out. A Keychain prompt may need attention; check state before retrying.") from error
    if result.returncode:
        raise SigningError(f"{label} failed (exit {result.returncode}). No automatic trust/ACL repair is attempted.")
    return result.stdout.decode("utf-8", errors="replace") + result.stderr.decode("utf-8", errors="replace")


def load_config():
    path = config_path()
    if path.is_symlink():
        raise SigningError("Signing configuration must not be a symlink.")
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise SigningError("Signing configuration is unreadable or malformed; refusing ad-hoc fallback.") from error
    if not isinstance(data, dict) or data.get("version") != 1 or data.get("identifier") != IDENTIFIER:
        raise SigningError("Signing configuration has an unsupported version or app identifier.")
    data["identity_sha1"] = sha1_identity(data.get("identity_sha1"))
    return data


def available_identities(keychain=None):
    # Include untrusted self-signed identities: no system/user trust changes are needed
    # for a certificate-based DR. The codesign probe verifies actual usability.
    arguments = ["/usr/bin/security", "find-identity", "-p", "codesigning"]
    if keychain:
        arguments.append(str(keychain))
    output = run(arguments, "Read-only signing identity lookup")
    return set(re.findall(r"^\s*\d+\) ([0-9A-Fa-f]{40})\s+", output, re.MULTILINE))


def require_available(identity, keychain=None):
    if identity not in {item.upper() for item in available_identities(keychain)}:
        raise SigningError("The configured signing certificate/private key is unavailable. Refusing ad-hoc fallback.")


def resolve_build_identity():
    # Even an explicit override cannot hide malformed pinned configuration.
    data = load_config()
    override = os.environ.get(OVERRIDE)
    if override is not None:
        identity = sha1_identity(override)
    elif data:
        identity = data["identity_sha1"]
    else:
        print("WARNING: no local signing identity is pinned; using legacy ad-hoc signing. "
              "Its identity can change on rebuild and macOS may request permissions again. "
              "Run configure-local-signing.py to review opt-in setup.", file=sys.stderr)
        return "-"
    require_available(identity)
    return identity


def verify_designated_requirement(path):
    output = run(["/usr/bin/codesign", "-d", "-r-", str(path)], "Designated requirement inspection")
    matches = re.findall(r"^#?\s*designated\s*=>\s*(.+)$", output, re.MULTILINE)
    if len(matches) != 1:
        raise SigningError("The signature did not expose exactly one designated requirement.")
    requirement = matches[0]
    if (f'identifier "{IDENTIFIER}"' not in requirement or
            not re.search(r"\b(?:anchor|certificate)\b", requirement) or
            re.search(r"\bcdhash\b", requirement)):
        raise SigningError("Signature identity is not a stable certificate-based designated requirement for Solar.")
    return requirement


def login_keychain():
    output = run(["/usr/bin/security", "default-keychain", "-d", "user"], "Read-only login Keychain lookup")
    paths = shlex.split(output)
    if len(paths) != 1:
        raise SigningError("Could not identify exactly one user login Keychain.")
    path = Path(paths[0])
    keychain_directory = (Path.home() / "Library" / "Keychains").resolve()
    if (not path.is_absolute() or keychain_directory not in path.resolve().parents or not path.is_file()
            or path.name not in ("login.keychain", "login.keychain-db")):
        raise SigningError("Signing setup requires an existing Keychain in this user's Library/Keychains directory.")
    return path


def ensure_empty_config():
    path = config_path()
    if path.is_symlink() or (path.exists() and (not path.is_file() or path.stat().st_size != 0)):
        raise SigningError("A signing configuration already exists. Refusing to replace or rotate the pinned identity.")


def ensure_no_duplicate(keychain):
    result = subprocess.run(["/usr/bin/security", "find-certificate", "-a", "-c", COMMON_NAME, str(keychain)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=10)
    if result.returncode == 0 and result.stdout.strip():
        raise SigningError("A Solar local signing certificate already exists. Reuse its public SHA-1 with --use-existing-identity; no duplicate will be created.")
    if result.returncode not in (0, 44):  # -a may return success with no matches; 44 is errSecItemNotFound.
        raise SigningError("Duplicate-certificate lookup failed; refusing to create or import an identity.")


def probe_identity(identity, executable):
    if not executable.is_file():
        raise SigningError("An existing app executable is required for the temporary signing probe. Build it first; it will not be run or changed.")
    with tempfile.TemporaryDirectory(prefix="SolarCallDesk-signing-probe-") as directory:
        target = Path(directory) / "SolarCallDesk"
        shutil.copyfile(executable, target)
        target.chmod(0o700)
        run(["/usr/bin/codesign", "--force", "--sign", identity, "--identifier", IDENTIFIER,
             "--timestamp=none", str(target)], "Signing a temporary executable copy")
        run(["/usr/bin/codesign", "--verify", "--strict", str(target)], "Temporary signature verification")
        requirement = verify_designated_requirement(target)
        # Ask the verifier to confirm the exact leaf certificate used by the probe.
        run(["/usr/bin/codesign", "--verify", "--strict",
             f'-R=identifier "{IDENTIFIER}" and certificate leaf = H"{identity}"', str(target)],
            "Pinned certificate verification")
        return requirement


def write_config(identity, keychain, requirement, created):
    ensure_empty_config()
    data = {"version": 1, "identifier": IDENTIFIER, "identity_sha1": identity,
            "keychain": str(keychain) if keychain else None,
            "created_local_identity": created,
            "configured_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "designated_requirement": requirement}
    descriptor, name = tempfile.mkstemp(prefix=".local-signing-identity.", suffix=".tmp", dir=PROJECT_DIR)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        ensure_empty_config()
        os.replace(name, config_path())
    finally:
        if os.path.exists(name):
            os.unlink(name)


def create_identity(keychain):
    ensure_no_duplicate(keychain)
    # TemporaryDirectory is 0700; umask 077 also protects all generated key files.
    with tempfile.TemporaryDirectory(prefix="SolarCallDesk-signing-private-") as directory:
        directory = Path(directory)
        directory.chmod(0o700)
        configuration = directory / "certificate.cnf"
        configuration.write_text(
            "[req]\nprompt = no\ndistinguished_name = subject\nx509_extensions = signing\n"
            f"[subject]\nCN = {COMMON_NAME}\n"
            "[signing]\nbasicConstraints = critical,CA:FALSE\n"
            "keyUsage = critical,digitalSignature\nextendedKeyUsage = critical,codeSigning\n"
            "subjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid:always\n", encoding="utf-8")
        private_key, certificate = directory / "private.pem", directory / "certificate.pem"
        run(["/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256",
             "-nodes", "-days", "3650", "-batch", "-config", str(configuration),
             "-keyout", str(private_key), "-out", str(certificate)], "Local signing certificate creation")
        der = directory / "certificate.der"
        run(["/usr/bin/openssl", "x509", "-in", str(certificate), "-outform", "DER", "-out", str(der)],
            "Public certificate conversion")
        identity = hashlib.sha1(der.read_bytes()).hexdigest().upper()
        bundle = directory / "identity.p12"
        # The empty PKCS#12 password is not a secret. The bundle never leaves this
        # private directory; no user/keychain password enters process arguments.
        run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(private_key), "-in", str(certificate),
             "-name", COMMON_NAME, "-out", str(bundle), "-passout", "pass:"], "Temporary signing identity packaging")
        run(["/usr/bin/security", "import", str(bundle), "-k", str(keychain), "-f", "pkcs12",
             "-x", "-T", "/usr/bin/codesign", "-P", ""], "Nonextractable login-Keychain identity import")
        return identity


def configure(create, existing, executable):
    ensure_empty_config()
    if not executable.is_file():
        raise SigningError("The signing probe requires an existing app executable; no identity was created.")
    mask = os.umask(0o077)
    lock = config_path().with_name(".local-signing-identity.lock")
    locked = False
    imported = None
    try:
        try:
            descriptor = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError as error:
            raise SigningError("Signing setup is already running or its lock remains; refusing concurrent provisioning.") from error
        os.close(descriptor)
        locked = True
        ensure_empty_config()
        keychain = login_keychain() if create else None
        identity = create_identity(keychain) if create else sha1_identity(existing)
        imported = identity if create else None
        require_available(identity, keychain)
        requirement = probe_identity(identity, executable)
        write_config(identity, keychain, requirement, create)
        print(f"Pinned public signing identity: {identity}")
        print(f"Configuration: {config_path()} (0600; no private key or password)")
        print("Temporary signature passed. No installed app, trust policy, or permission setting was changed.")
    except SigningError as error:
        if imported:
            raise SigningError(f"{error} The new identity was imported, but no pin was written. "
                               f"Public SHA-1: {imported}. Temporary private files were removed; existing items were not modified.") from error
        raise
    finally:
        if locked:
            lock.unlink(missing_ok=True)
        os.umask(mask)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--create-local-identity", action="store_true", help="Explicitly create/import one local signing identity and pin it.")
    actions.add_argument("--use-existing-identity", metavar="SHA1", help="Probe and pin an existing identity; never import or alter it.")
    actions.add_argument("--resolve-build-identity", action="store_true", help="Read-only build identity resolution; output SHA1 or legacy '-'.")
    actions.add_argument("--verify-designated-requirement", metavar="PATH", type=Path, help="Read-only certificate-based signature check.")
    parser.add_argument("--probe-executable", type=Path, default=PROJECT_DIR / "dist" / "Solar Call Desk.app" / "Contents" / "MacOS" / "SolarCallDesk")
    parser.add_argument("--dry-run", action="store_true", help="Describe actions without generating keys, importing, signing, or writing configuration.")
    args = parser.parse_args()
    try:
        if args.dry_run or not any((args.create_local_identity, args.use_existing_identity,
                                    args.resolve_build_identity, args.verify_designated_requirement)):
            data = load_config()
            print("DRY RUN: no certificate creation, Keychain operations, signing, build, or installation.")
            print(f"Public configuration: {config_path()}")
            print(f"Pinned identity: {data['identity_sha1'] if data else 'none'}")
            print("Opt-in creation: self-signed RSA3072, 3650 days, codeSigning only, CA:FALSE; "
                  "nonextractable login-Keychain import permitting /usr/bin/codesign only.")
            print("After a successful temporary executable/signature probe, save public metadata atomically with mode 0600.")
            print("Use --create-local-identity to opt in, or --use-existing-identity SHA1 to reuse a certificate.")
        elif args.resolve_build_identity:
            print(resolve_build_identity())
        elif args.verify_designated_requirement:
            print(verify_designated_requirement(args.verify_designated_requirement))
        else:
            configure(args.create_local_identity, args.use_existing_identity, args.probe_executable)
    except (SigningError, OSError, subprocess.TimeoutExpired) as error:
        print(f"Signing setup stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
