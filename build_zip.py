#!/usr/bin/env python3
"""
Packaging script for hyperos-accessibility-fix.
Creates a KernelSU / Magisk / APatch flashable zip archive with strict LF line endings.
"""

import os
import zipfile
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

# Files and directories to include in the module package
INCLUDE_PATTERNS = [
    "META-INF/com/google/android/update-binary",
    "META-INF/com/google/android/updater-script",
    "common/functions.sh",
    "common/install.sh",
    "common/repo.json",
    "scripts/a11y_watchdog.sh",
    "scripts/a11y_watchdog_monitor.sh",
    "action.sh",
    "customize.sh",
    "service.sh",
    "uninstall.sh",
    "module.prop",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
]

TEXT_EXTENSIONS = {".sh", ".prop", ".md", ".json", ".txt"}


def build_package():
    version = "1.1.2"
    with open(BASE_DIR / "module.prop", "r") as f:
        for line in f:
            if line.startswith("version="):
                version = line.split("=")[1].strip()
    output_name = f"hyperos-accessibility-fix-v{version}.zip"
    output_path = BASE_DIR / output_name

    print(f"[*] Building module zip: {output_path}")

    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for rel_path in INCLUDE_PATTERNS:
            file_path = BASE_DIR / rel_path
            if not file_path.exists():
                raise FileNotFoundError(f"Required file missing: {file_path}")

            # Read content
            with open(file_path, "rb") as f:
                content = f.read()

            # Ensure LF line endings for scripts and text files
            is_text = (
                file_path.suffix in TEXT_EXTENSIONS
                or file_path.name in {"update-binary", "updater-script"}
            )
            if is_text:
                # Normalize any CRLF to LF
                content = content.replace(b"\r\n", b"\n")

            # Standard unix permissions: 0o755 for scripts/executables, 0o644 for regular files
            is_exec = (
                file_path.suffix == ".sh"
                or file_path.name == "update-binary"
                or "scripts/" in rel_path
            )
            attr = 0o755 if is_exec else 0o644

            zip_info = zipfile.ZipInfo(rel_path)
            zip_info.external_attr = (attr << 16) | 0o100000  # regular file + unix permissions
            zf.writestr(zip_info, content)
            print(f"  + Added: {rel_path} (exec={is_exec}, bytes={len(content)})")

    print(f"[+] Successfully built {output_name} ({output_path.stat().st_size} bytes)")
    return output_path


def verify_package(zip_path: Path):
    print(f"[*] Verifying package: {zip_path}")
    with zipfile.ZipFile(zip_path, "r") as zf:
        namelist = zf.namelist()
        print(f"  Files in zip: {len(namelist)}")
        for name in namelist:
            info = zf.getinfo(name)
            data = zf.read(name)
            # Check for Windows CRLF in scripts
            if name.endswith(".sh") or "update-binary" in name:
                if b"\r\n" in data:
                    raise ValueError(f"FATAL: {name} contains CRLF line endings!")
            perm = (info.external_attr >> 16) & 0o777
            print(f"  OK: {name:40s} | Size: {len(data):6d} | Perm: {oct(perm)}")
    print("[+] All verification checks passed!")


if __name__ == "__main__":
    out = build_package()
    verify_package(out)
