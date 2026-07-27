from __future__ import annotations

from cryptography.fernet import Fernet
from pathlib import Path

KEY_PATH = Path(__file__).resolve().parent.parent / "data" / ".fernet_key"


def _get_fernet() -> Fernet:
    KEY_PATH.parent.mkdir(parents=True, exist_ok=True)
    if KEY_PATH.exists():
        key = KEY_PATH.read_bytes()
    else:
        key = Fernet.generate_key()
        KEY_PATH.write_bytes(key)
        KEY_PATH.chmod(0o600)
    return Fernet(key)


def encrypt(value: str) -> str:
    return _get_fernet().encrypt(value.encode("utf-8")).decode("utf-8")


def decrypt(token: str) -> str:
    return _get_fernet().decrypt(token.encode("utf-8")).decode("utf-8")
