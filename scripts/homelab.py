#!/usr/bin/env python3
"""Keep KeePass secrets private while invoking OpenTofu for this homelab."""

import argparse
import getpass
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile

from pykeepass import PyKeePass, create_database


GROUP = "homelab"
DEFAULT_DATABASE = Path.home() / ".keychains" / "homelab.kdbx"
REQUIRED = {
    "authelia": (
        "session_secret", "storage_encryption_key", "reset_password_jwt_secret",
        "oidc_hmac_secret", "oidc_jwks", "grafana_client_secret_hash", "users_yml",
    ),
    "grafana": ("client_secret", "admin_password", "secret_key"),
}
OPTIONAL = {
    "authelia": ("smtp_password",),
    "prometheus": ("incus_server_cert", "incus_metrics_cert", "incus_metrics_key"),
}
FIELDS = {
    service: REQUIRED.get(service, ()) + OPTIONAL.get(service, ())
    for service in REQUIRED.keys() | OPTIONAL.keys()
}


def group_for(db):
    return db.find_groups(name=GROUP, first=True) or db.add_group(db.root_group, GROUP)


def entry(db, group, title):
    return db.find_entries(title=title, group=group, recursive=False, first=True)


def put(db, group, title, value, *, replace=False):
    existing = entry(db, group, title)
    if existing:
        if not replace:
            return False
        existing.password = value
    else:
        db.add_entry(group, title, "", value)
    return True


def save_private(db, path):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".homelab-", delete=False) as tmp:
        temporary = Path(tmp.name)
        try:
            db.save(tmp)
            tmp.flush()
            os.fsync(tmp.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def grafana_oidc_pair():
    command = ["authelia", "crypto", "hash", "generate", "pbkdf2", "--variant", "sha512",
               "--random", "--random.length", "72", "--random.charset", "rfc3986"]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError("Authelia could not generate the Grafana OIDC client secret")
    lines = dict(line.split(": ", 1) for line in result.stdout.splitlines()
                 if line.startswith(("Random Password: ", "Digest: ")))
    secret, digest = lines.get("Random Password"), lines.get("Digest")
    if not secret or len(secret) != 72 or not digest or not digest.startswith("$pbkdf2-sha512$"):
        raise ValueError("unexpected output from Authelia's PBKDF2 generator")
    return secret, digest


def init(db, group, path):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    generated = {
        "state_passphrase": secrets.token_urlsafe(64),
        "authelia/session_secret": secrets.token_hex(32),
        "authelia/storage_encryption_key": secrets.token_hex(32),
        "authelia/reset_password_jwt_secret": secrets.token_hex(32),
        "authelia/oidc_hmac_secret": secrets.token_hex(64),
        "grafana/admin_password": secrets.token_urlsafe(48),
        "grafana/secret_key": secrets.token_urlsafe(48),
    }
    for name, value in generated.items():
        put(db, group, name, value)
    if not entry(db, group, "authelia/oidc_jwks"):
        key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        pem = key.private_bytes(serialization.Encoding.PEM,
                                serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption()).decode()
        put(db, group, "authelia/oidc_jwks", pem)
    client = entry(db, group, "grafana/client_secret")
    digest = entry(db, group, "authelia/grafana_client_secret_hash")
    if bool(client and client.password) != bool(digest and digest.password):
        raise ValueError("Grafana OIDC client pair is incomplete; restore both entries or remove the partial entry and rerun init-secrets")
    if not client or not client.password:
        secret, hashed = grafana_oidc_pair()
        put(db, group, "grafana/client_secret", secret, replace=True)
        put(db, group, "authelia/grafana_client_secret_hash", hashed, replace=True)
    save_private(db, path)
    print("KeePass entries created or retained. Add authelia/users_yml before apply.")


def load_values(db, group, *, require_all):
    state = entry(db, group, "state_passphrase")
    if not state or not state.password or len(state.password) < 16:
        raise ValueError("missing state_passphrase (at least 16 characters)")
    result = {}
    for service, names in FIELDS.items():
        values = {}
        for name in names:
            item = entry(db, group, f"{service}/{name}")
            if item and item.password:
                values[name] = item.password
            elif require_all and name in REQUIRED.get(service, ()):
                raise ValueError(f"missing {service}/{name}")
        if values:
            result[service] = values
    if require_all:
        metrics = result.get("prometheus", {})
        if metrics and len(metrics) != len(OPTIONAL["prometheus"]):
            raise ValueError("provide all three Prometheus certificates/keys together")
    return state.password, result


def invoke(db, group, args):
    state_file = Path("terraform.tfstate")
    if state_file.exists():
        try:
            state_envelope = json.loads(state_file.read_text())
        except (OSError, ValueError) as error:
            raise ValueError("cannot identify local state format; inspect it privately") from error
        if "encrypted_data" not in state_envelope:
            raise ValueError("plaintext state is still in this checkout; archive it before starting the new state")
    state, values = load_values(db, group, require_all=args[0] != "init")
    env = os.environ.copy()
    env["TF_VAR_state_passphrase"] = state
    env["TF_VAR_workload_secrets"] = json.dumps(values)
    env.pop("TF_ENCRYPTION", None)
    return subprocess.run(["tofu", *args], env=env, check=False).returncode


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", default=DEFAULT_DATABASE, type=Path,
                        help="KeePass KDBX file (default: ~/.keychains/homelab.kdbx)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init-secrets", help="create database and stable generated secrets")
    set_parser = commands.add_parser("set", help="prompt for one secret or read it from stdin")
    set_parser.add_argument("name", help="service/field, for example authelia/users_yml")
    run_parser = commands.add_parser("tofu", help="run OpenTofu with KeePass values")
    run_parser.add_argument("args", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    try:
        path = args.database.expanduser().resolve()
        if args.command == "init-secrets" and not path.exists():
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            password = getpass.getpass("New KeePass master password: ")
            if password != getpass.getpass("Confirm master password: "):
                raise ValueError("passwords differ")
            if len(password) < 16:
                raise ValueError("use a master password of at least 16 characters")
            db = create_database(str(path), password=password)
        else:
            if not path.is_file():
                raise ValueError("database does not exist; run init-secrets first")
            if path.stat().st_uid != os.getuid():
                raise ValueError("database must be owned by the current user")
            if path.stat().st_mode & 0o077:
                os.chmod(path, 0o600)
            db = PyKeePass(str(path), password=getpass.getpass("KeePass master password: "))
        group = group_for(db)
        if args.command == "init-secrets":
            init(db, group, path)
        elif args.command == "set":
            allowed = {f"{service}/{field}" for service, fields in FIELDS.items() for field in fields}
            if args.name not in allowed:
                raise ValueError("unknown secret name")
            value = (getpass.getpass(f"{args.name}: ") if sys.stdin.isatty()
                     else sys.stdin.read().rstrip("\n"))
            if not value:
                raise ValueError("secret is empty")
            put(db, group, args.name, value, replace=True)
            save_private(db, path)
            print(f"Saved {args.name}.")
        else:
            if not args.args or args.args[0].startswith("-"):
                raise ValueError("supply a tofu subcommand")
            return invoke(db, group, args.args)
    except (OSError, ValueError) as error:
        print(f"homelab: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
