#!/usr/bin/env python3

import re
import subprocess
import sys


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, text=True, capture_output=True)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> None:
    if len(sys.argv) != 2:
        raise RuntimeError("usage: vault_image_contract.py IMAGE")
    image = sys.argv[1]

    version = run(
        "docker",
        "image",
        "inspect",
        "--format",
        '{{ index .Config.Labels "org.opencontainers.image.version" }}',
        image,
    ).stdout.strip()
    match = re.fullmatch(r"(\d+\.\d+\.\d+)-libops\.\d+", version)
    require(match is not None, f"invalid Vault image version label: {version!r}")

    reported_version = run(
        "docker",
        "run",
        "--rm",
        "--entrypoint",
        "/usr/local/bin/vault",
        image,
        "version",
    ).stdout
    require(
        f"Vault v{match.group(1)}" in reported_version,
        "Vault binary and image label versions differ",
    )

    uid = run(
        "docker", "run", "--rm", "--entrypoint", "/bin/sh", image, "-c", "id -u"
    ).stdout.strip()
    require(uid == "65532", f"Vault runtime UID is {uid}, want 65532")

    run(
        "docker",
        "run",
        "--rm",
        "-e",
        "KMS_KEY_RING=ring-one",
        "-e",
        "KMS_CRYPTO_KEY=key_two",
        image,
        "/bin/sh",
        "-ec",
        'test -r /tmp/vault-config.hcl; grep -F \'key_ring   = "ring-one"\' /tmp/vault-config.hcl; grep -F \'crypto_key = "key_two"\' /tmp/vault-config.hcl; test "$(stat -c %a /tmp/vault-config.hcl)" = 600',
    )

    for key_ring, crypto_key in (
        ("ring&one", "key-two"),
        ("a" * 64, "key-two"),
    ):
        rejected = run(
            "docker",
            "run",
            "--rm",
            "-e",
            f"KMS_KEY_RING={key_ring}",
            "-e",
            f"KMS_CRYPTO_KEY={crypto_key}",
            image,
            "true",
            check=False,
        )
        require(
            rejected.returncode != 0,
            f"invalid KMS key ring was accepted: {key_ring!r}",
        )

    print(f"validated {image} as Vault {version}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Vault image contract failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
