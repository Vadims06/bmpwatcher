"""Keeps onboarding/manifest.json, docker-compose.yml and VERSION in step.

Topolograph builds its Add watcher form from the manifest and installs the
tag in VERSION, so a gap between these files breaks installs from Topolograph.
"""
import json
import pathlib
import re
import subprocess
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Written by configure.sh itself, not asked in Topolograph.
CONFIGURE_SH_VARIABLES = {"WATCHER_VERSION"}
VARIABLE = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)(:?[-?+])?")


def get_errors(tag: str) -> list:
    errors = []
    manifest = json.loads((ROOT / "onboarding" / "manifest.json").read_text())
    version = (ROOT / "VERSION").read_text().strip()
    manifest_variables = {field["env"] for field in manifest["fields"] if "env" in field}

    for name, operator in VARIABLE.findall((ROOT / "docker-compose.yml").read_text()):
        if operator in ("", ":?", "?") and name not in manifest_variables | CONFIGURE_SH_VARIABLES:
            errors.append(f"docker-compose.yml needs ${{{name}}}, the manifest does not declare it")

    example = (ROOT / ".env.example").read_text()
    if f"WATCHER_VERSION={version}\n" not in example:
        errors.append(".env.example WATCHER_VERSION differs from VERSION")
    if tag and tag != version:
        errors.append(f"tag {tag} differs from VERSION {version}")

    images = subprocess.run(
        ["docker", "compose", "--profile", "*", "config", "--images"],
        cwd=ROOT, check=True, capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(pathlib.Path.home()), "WATCHER_VERSION": version,
             **{field["env"]: str(field.get("default", "1")) for field in manifest["fields"] if "env" in field}},
    ).stdout.split()
    for image in images:
        name, _, image_tag = image.rpartition(":")
        if not name or "/" in image_tag or image_tag == "latest":
            errors.append(f"{image}: pin an explicit tag")
        first_segment = image.split("/")[0]
        if "/" in image and ("." in first_segment or ":" in first_segment):
            errors.append(f"{image}: only Docker Hub images, so one mirror prefix serves them all")
        if tag and name.startswith("vadims06/") and image_tag == version and not is_published(name, image_tag):
            errors.append(f"{image} is not published on Docker Hub")
    return errors


def is_published(name: str, image_tag: str) -> bool:
    url = f"https://hub.docker.com/v2/repositories/{name}/tags/{image_tag}"
    try:
        with urllib.request.urlopen(url, timeout=20):
            return True
    except OSError:
        return False


if __name__ == "__main__":
    found = get_errors(sys.argv[1] if len(sys.argv) > 1 else "")
    for error in found:
        print(f"::error::{error}")
    sys.exit(1 if found else 0)
