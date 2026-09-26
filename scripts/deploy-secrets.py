#!/usr/bin/env python3
"""Copy declared OpenBao KV v2 fields into private Incus volumes.

The OpenTofu output contains names, destinations, and ownership only. Secret
bytes travel through this process and Incus stdin, never command arguments,
environment variables, local files, or OpenTofu state.
"""

import argparse
import json
import re
import subprocess
import sys


NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*\Z")


def run(args, *, data=None):
    try:
        result = subprocess.run(args, input=data, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, check=False)
    except OSError as error:
        raise RuntimeError(f"{args[0]} could not start: {error.strerror}") from error
    if result.returncode:
        # CLI stderr may include the requested path, but never print stdout:
        # bao stdout contains the secret and Incus might echo it on failure.
        raise RuntimeError(f"{args[0]} failed (exit {result.returncode})")
    return result.stdout


def validate_name(value, label):
    if not isinstance(value, str) or not NAME.fullmatch(value):
        raise ValueError(f"invalid {label} in OpenTofu output")
    return value


def deploy(service, spec):
    remote = validate_name(spec["remote"], "remote")
    pool = validate_name(spec["pool"], "pool")
    volume = validate_name(spec["volume"], "volume")
    uid, gid = spec["uid"], spec["gid"]
    if type(uid) is not int or type(gid) is not int or uid < 0 or gid < 0:
        raise ValueError("invalid UID/GID in OpenTofu output")
    fields = spec["fields"]
    if not isinstance(fields, dict) or not fields:
        raise ValueError("no fields declared for workload")
    for filename, field in fields.items():
        validate_name(filename, "filename")
        validate_name(field, "field")

    # Fetch everything first. A missing field leaves the installed files alone.
    values = {}
    for filename, field in fields.items():
        value = run(["bao", "kv", "get", "-mount=kv", f"-field={field}", service])
        if not value:
            raise ValueError(f"empty secret field {service}/{field}")
        values[filename] = value

    for filename, value in values.items():
        run(["incus", "storage", "volume", "file", "push", "-", f"{remote}:{pool}",
             f"{volume}/{filename}", f"--uid={uid}", f"--gid={gid}", "--mode=0400"],
            data=value)
    print(f"Installed {len(fields)} fields for {service}; start or restart {remote}:{service}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("services", nargs="*", help="Selected workloads (default: all)")
    args = parser.parse_args()
    try:
        manifest = json.loads(run(["tofu", "output", "-json", "secret_deployment"]))
        if not isinstance(manifest, dict):
            raise ValueError("invalid secret_deployment output")
        services = args.services or sorted(manifest)
        for service in services:
            validate_name(service, "workload")
            if service not in manifest:
                raise ValueError(f"no secret declaration for {service}")
        for service in services:
            deploy(service, manifest[service])
    except (KeyError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"Secret deployment stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
