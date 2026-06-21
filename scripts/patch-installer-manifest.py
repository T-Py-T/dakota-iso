#!/usr/bin/env python3
# scripts/patch-installer-manifest.py
# Patches a bootc-installer flatpak manifest for aarch64 builds: swaps the pinned
# amd64 Go toolchain source for arm64, and installs bge headers that bazaar
# v0.7.15 omits from install_headers (bge-markdown-render.h + wdgt/*), which
# otherwise breaks libpastry compilation. Idempotent.
# Does NOT modify anything else in the manifest.

import json
import sys

AMD64 = "https://go.dev/dl/go1.26.1.linux-amd64.tar.gz"
ARM64 = "https://go.dev/dl/go1.26.1.linux-arm64.tar.gz"
ARM64_SHA = "a290581cfe4fe28ddd737dde3095f3dbeb7f2e4065cab4eae44dfc53b760c2f7"

# Upstream bug: bazaar-org/bazaar bge/meson.build lists these as sources but not
# in install_headers, yet the installed bge.h #includes bge-markdown-render.h.
HDR_CMDS = [
    "install -Dm644 bge/bge-markdown-render.h /app/include/bge/bge-markdown-render.h",
    "install -Dm644 bge/wdgt/bge-easing.h /app/include/bge/wdgt/bge-easing.h",
    "install -Dm644 bge/wdgt/bge-wdgt-renderer.h /app/include/bge/wdgt/bge-wdgt-renderer.h",
    "install -Dm644 bge/wdgt/bge-wdgt-spec.h /app/include/bge/wdgt/bge-wdgt-spec.h",
]


def patch(path: str) -> None:
    with open(path) as f:
        data = json.load(f)

    for mod in data.get("modules", []):
        if not isinstance(mod, dict):
            continue
        for src in mod.get("sources", []):
            if isinstance(src, dict) and src.get("url") == AMD64:
                src["url"] = ARM64
                src["sha256"] = ARM64_SHA
        if mod.get("name") == "libbge":
            cmds = mod.setdefault("build-commands", [])
            for c in HDR_CMDS:
                if c not in cmds:
                    cmds.append(c)

    with open(path, "w") as f:
        json.dump(data, f, indent=4)
    print(f"patched {path}")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        patch(p)
