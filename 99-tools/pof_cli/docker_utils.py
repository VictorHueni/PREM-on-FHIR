#!/usr/bin/env python3
from __future__ import annotations

import shlex
import subprocess
from pathlib import Path
from typing import List, Optional

from utils import die

# ---------------------------
# docker exec (for synthea)
# ---------------------------

def check_docker() -> None:
    try:
        subprocess.run(["docker", "--version"], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except Exception as e:
        die("Docker is not available on PATH. Install Docker Desktop or add it to PATH.", 2)

def run_cmd(cmd: List[str], cwd: Optional[Path] = None) -> int:
    """
    Thin wrapper over subprocess.run so every call is consistent and prints command.
    """
    print("→", " ".join(shlex.quote(x) for x in cmd))
    try:
        cp = subprocess.run(cmd, cwd=str(cwd) if cwd else None)
        return cp.returncode
    except KeyboardInterrupt:
        print("\n(Interrupted)")
        return 130
