#!/usr/bin/env python3
"""Keep KeePass secrets private while invoking OpenTofu for this homelab.

Requires Python 3.10+, pykeepass, and cryptography. Initialization also uses
Authelia's CLI when the Grafana OIDC credentials are missing.

Extend APPLICATIONS for ordinary credentials. Use an OptionalBundle for fields
that must be supplied together, or GENERATED_BUNDLES for values generated
together across application boundaries. Existing KeePass entry names are stable.
"""

from __future__ import annotations

import argparse
from collections.abc import Callable, Iterator, Mapping
from dataclasses import dataclass
from functools import partial
import getpass
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pykeepass import PyKeePass


GROUP = "homelab"
DEFAULT_DATABASE = Path.home() / ".keychains" / "homelab.kdbx"


@dataclass(frozen=True)
class ProvidedSecret:
    name: str
    required: bool = True


@dataclass(frozen=True)
class GeneratedSecret:
    name: str
    generate: Callable[[], str]


@dataclass(frozen=True)
class OptionalBundle:
    """All fields may be absent; supplying any requires supplying all."""

    name: str
    fields: tuple[str, ...]


@dataclass(frozen=True)
class ApplicationSecrets:
    name: str
    secrets: tuple[ProvidedSecret | GeneratedSecret | OptionalBundle, ...]


@dataclass(frozen=True)
class SecretRef:
    application: str
    field: str

    @property
    def name(self) -> str:
        return f"{self.application}/{self.field}"


@dataclass(frozen=True)
class GeneratedBundle:
    """Required values; replace the entire bundle when any value is missing."""

    name: str
    fields: tuple[SecretRef, ...]
    generate: Callable[[], Mapping[SecretRef, str]]


@dataclass(frozen=True)
class SecretCatalog:
    applications: tuple[ApplicationSecrets, ...]
    integrations: tuple[GeneratedBundle, ...]

    def __post_init__(self) -> None:
        applications = [app.name for app in self.applications]
        if len(applications) != len(set(applications)):
            raise ValueError("duplicate application in secret catalog")
        names = [ref.name for ref, _ in self.fields()]
        if len(names) != len(set(names)):
            raise ValueError("duplicate field in secret catalog")
        for bundle in self.integrations:
            if not bundle.fields:
                raise ValueError(f"empty generated bundle: {bundle.name}")
            for ref in bundle.fields:
                if ref.application not in applications:
                    raise ValueError(f"unknown application in bundle: {ref.application}")
        for app in self.applications:
            for specification in app.secrets:
                if isinstance(specification, OptionalBundle) and not specification.fields:
                    raise ValueError(f"empty optional bundle: {specification.name}")

    def fields(self) -> Iterator[tuple[SecretRef, bool]]:
        """Yield every workload field and whether it is required."""
        for app in self.applications:
            for specification in app.secrets:
                if isinstance(specification, OptionalBundle):
                    for name in specification.fields:
                        yield SecretRef(app.name, name), False
                else:
                    required = (
                        isinstance(specification, GeneratedSecret)
                        or specification.required
                    )
                    yield SecretRef(app.name, specification.name), required
        for bundle in self.integrations:
            for ref in bundle.fields:
                yield ref, True

    def allowed_names(self) -> set[str]:
        return {ref.name for ref, _ in self.fields()}


class SecretVault:
    """Keep KeePass mechanics out of the command workflows."""

    def __init__(self, database: PyKeePass, path: Path):
        self.database = database
        self.path = path
        self.group = database.find_groups(name=GROUP, first=True)

    def _find_entry(self, name: str):
        if self.group is None:
            return None
        return self.database.find_entries(
            title=name, group=self.group, recursive=False, first=True,
        )

    def read_secret(self, name: str) -> str | None:
        """An absent entry or an empty password counts as missing."""
        entry = self._find_entry(name)
        if entry is None or not entry.password:
            return None
        return entry.password

    def set_secret(self, name: str, value: str) -> None:
        if not isinstance(value, str) or not value:
            raise ValueError(f"secret is empty or invalid: {name}")
        if self.group is None:
            self.group = self.database.add_group(self.database.root_group, GROUP)
        entry = self._find_entry(name)
        if entry is None:
            self.database.add_entry(self.group, name, "", value)
        else:
            entry.password = value

    def ensure_generated_secret(self, specification: GeneratedSecret) -> None:
        if self.read_secret(specification.name) is None:
            self.set_secret(specification.name, specification.generate())

    def save(self) -> None:
        # Finish writing before replacing the vault. A sibling temporary file
        # allows atomic replacement and is created with private permissions.
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(
                dir=self.path.parent, prefix=".homelab-", delete=False,
            ) as output:
                temporary = Path(output.name)
                self.database.save(output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


def generate_oidc_signing_key() -> str:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


GRAFANA_CLIENT_SECRET = SecretRef("grafana", "client_secret")
GRAFANA_CLIENT_HASH = SecretRef("authelia", "grafana_client_secret_hash")


def generate_grafana_oidc_pair() -> Mapping[SecretRef, str]:
    command = [
        "authelia", "crypto", "hash", "generate", "pbkdf2",
        "--variant", "sha512", "--random", "--random.length", "72",
        "--random.charset", "rfc3986",
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        # Authelia output can contain credentials; do not include it in errors.
        raise ValueError("Authelia could not generate the Grafana OIDC client secret")
    values = {}
    for line in result.stdout.splitlines():
        label, separator, value = line.partition(": ")
        if separator and label in ("Random Password", "Digest"):
            if label in values:
                raise ValueError("duplicate field in Authelia generator output")
            values[label] = value
    secret = values.get("Random Password", "")
    digest = values.get("Digest", "")
    if len(secret) != 72 or not digest.startswith("$pbkdf2-sha512$"):
        raise ValueError("unexpected output from Authelia's PBKDF2 generator")
    return {GRAFANA_CLIENT_SECRET: secret, GRAFANA_CLIENT_HASH: digest}


# partial binds generator parameters without generating a value at import time.
APPLICATIONS = (
    ApplicationSecrets("authelia", (
        GeneratedSecret("session_secret", partial(secrets.token_hex, 32)),
        GeneratedSecret("storage_encryption_key", partial(secrets.token_hex, 32)),
        GeneratedSecret("reset_password_jwt_secret", partial(secrets.token_hex, 32)),
        GeneratedSecret("oidc_hmac_secret", partial(secrets.token_hex, 64)),
        GeneratedSecret("oidc_jwks", generate_oidc_signing_key),
        ProvidedSecret("users_yml"),
        ProvidedSecret("smtp_password", required=False),
    )),
    ApplicationSecrets("grafana", (
        GeneratedSecret("admin_password", partial(secrets.token_urlsafe, 48)),
        GeneratedSecret("secret_key", partial(secrets.token_urlsafe, 48)),
    )),
    ApplicationSecrets("prometheus", (
        OptionalBundle("incus_metrics_credentials", (
            "incus_server_cert", "incus_metrics_cert", "incus_metrics_key",
        )),
    )),
)
GENERATED_BUNDLES = (
    GeneratedBundle(
        "grafana_oidc", (GRAFANA_CLIENT_SECRET, GRAFANA_CLIENT_HASH),
        generate_grafana_oidc_pair,
    ),
)
CATALOG = SecretCatalog(APPLICATIONS, GENERATED_BUNDLES)
STATE_PASSPHRASE = GeneratedSecret(
    "state_passphrase", partial(secrets.token_urlsafe, 64),
)


def ensure_generated_bundle(vault: SecretVault, bundle: GeneratedBundle) -> bool:
    """Return whether an incomplete existing bundle was replaced."""
    present = [vault.read_secret(ref.name) is not None for ref in bundle.fields]
    if all(present):
        return False
    # A missing plaintext secret cannot be recovered from its hash. Generate
    # and validate the complete replacement before changing either entry.
    generated = bundle.generate()
    if set(generated) != set(bundle.fields):
        raise ValueError(f"generator returned incorrect fields for {bundle.name}")
    if any(not isinstance(value, str) or not value for value in generated.values()):
        raise ValueError(f"generator returned empty or invalid values for {bundle.name}")
    for ref, value in generated.items():
        vault.set_secret(ref.name, value)
    return any(present)


def initialize_secrets(vault: SecretVault, catalog: SecretCatalog = CATALOG) -> None:
    vault.ensure_generated_secret(STATE_PASSPHRASE)
    read_state_passphrase(vault)
    for app in catalog.applications:
        for specification in app.secrets:
            if isinstance(specification, GeneratedSecret):
                vault.ensure_generated_secret(GeneratedSecret(
                    f"{app.name}/{specification.name}", specification.generate,
                ))
    replaced = []
    for bundle in catalog.integrations:
        if ensure_generated_bundle(vault, bundle):
            replaced.append(bundle.name)
    vault.save()
    for name in replaced:
        print(f"Replaced incomplete {name} with a matching bundle.")
    print("KeePass entries created or retained.")
    missing = [
        ref.name for ref, required in catalog.fields()
        if required and vault.read_secret(ref.name) is None
    ]
    if missing:
        print("Add before apply: " + ", ".join(missing))


def read_state_passphrase(vault: SecretVault) -> str:
    value = vault.read_secret(STATE_PASSPHRASE.name)
    if value is None or len(value) < 16:
        raise ValueError("missing or invalid state_passphrase (at least 16 characters)")
    return value


def read_workload_secrets(
    vault: SecretVault, catalog: SecretCatalog = CATALOG,
) -> dict[str, dict[str, str]]:
    values: dict[str, dict[str, str]] = {}
    for ref, _ in catalog.fields():
        value = vault.read_secret(ref.name)
        if value is not None:
            values.setdefault(ref.application, {})[ref.field] = value
    return values


def validate_workload_secrets(
    values: dict[str, dict[str, str]], catalog: SecretCatalog = CATALOG,
) -> None:
    problems = []
    for ref, required in catalog.fields():
        if required and not values.get(ref.application, {}).get(ref.field):
            problems.append(f"missing {ref.name}")
    for app in catalog.applications:
        for specification in app.secrets:
            if isinstance(specification, OptionalBundle):
                present = [
                    bool(values.get(app.name, {}).get(name))
                    for name in specification.fields
                ]
                if any(present) and not all(present):
                    names = ", ".join(specification.fields)
                    problems.append(f"provide {app.name}/{specification.name} together: {names}")
    if problems:
        raise ValueError("; ".join(problems))


def check_local_state(path: Path = Path("terraform.tfstate")) -> None:
    if not path.exists():
        return
    try:
        envelope = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise ValueError("cannot identify local state format; inspect it privately") from error
    if not isinstance(envelope, dict):
        raise ValueError("cannot identify local state format; inspect it privately")
    # Retain the original migration guard. This is an envelope marker check,
    # not cryptographic verification of the state or a check of remote state.
    if "encrypted_data" not in envelope:
        raise ValueError(
            "plaintext state is still in this checkout; archive it before starting the new state"
        )


def run_tofu(vault: SecretVault, arguments: list[str]) -> int:
    check_local_state()
    state_passphrase = read_state_passphrase(vault)
    values = read_workload_secrets(vault)
    # Preserve the command policy: only tofu init may omit workload secrets.
    if arguments[0] != "init":
        validate_workload_secrets(values)
    environment = os.environ.copy()
    environment["TF_VAR_state_passphrase"] = state_passphrase
    environment["TF_VAR_workload_secrets"] = json.dumps(values)
    # Do not allow an inherited override to replace configured encryption.
    environment.pop("TF_ENCRYPTION", None)
    return subprocess.run(["tofu", *arguments], env=environment, check=False).returncode


def prompt_new_password() -> str:
    password = getpass.getpass("New KeePass master password: ")
    if password != getpass.getpass("Confirm master password: "):
        raise ValueError("passwords differ")
    if len(password) < 16:
        raise ValueError("use a master password of at least 16 characters")
    return password


def open_vault(path: Path, *, create_if_missing: bool) -> SecretVault:
    from pykeepass import PyKeePass, create_database

    if create_if_missing and not path.exists():
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        database = create_database(str(path), password=prompt_new_password())
    else:
        if not path.is_file():
            raise ValueError("database does not exist; run init-secrets first")
        status = path.stat()
        if status.st_uid != os.getuid():
            raise ValueError("database must be owned by the current user")
        if status.st_mode & 0o077:
            os.chmod(path, 0o600)
        database = PyKeePass(str(path), password=getpass.getpass("KeePass master password: "))
    return SecretVault(database, path)


def set_secret_from_input(vault: SecretVault, name: str) -> None:
    if sys.stdin.isatty():
        value = getpass.getpass(f"{name}: ")
    else:
        value = sys.stdin.read().rstrip("\n")
    vault.set_secret(name, value)
    vault.save()
    print(f"Saved {name}.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--database", default=DEFAULT_DATABASE, type=Path,
        help="KeePass KDBX file (default: ~/.keychains/homelab.kdbx)",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init-secrets", help="create database and stable generated secrets")
    set_parser = commands.add_parser("set", help="prompt for one secret or read it from stdin")
    set_parser.add_argument("name", help="service/field, for example authelia/users_yml")
    run_parser = commands.add_parser("tofu", help="run OpenTofu with KeePass values")
    run_parser.add_argument("args", nargs=argparse.REMAINDER)
    return parser


def main() -> int:
    os.umask(0o077)
    args = build_parser().parse_args()
    try:
        if args.command == "set" and args.name not in CATALOG.allowed_names():
            raise ValueError("unknown secret name")
        if args.command == "tofu" and (not args.args or args.args[0].startswith("-")):
            raise ValueError("supply a tofu subcommand")
        vault = open_vault(
            args.database.expanduser().resolve(),
            create_if_missing=args.command == "init-secrets",
        )
        if args.command == "init-secrets":
            initialize_secrets(vault)
        elif args.command == "set":
            set_secret_from_input(vault, args.name)
        else:
            return run_tofu(vault, args.args)
    except (OSError, ValueError) as error:
        print(f"homelab: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
