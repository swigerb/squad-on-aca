#!/usr/bin/env python3
"""Verify restored Aspire 17 application archives, not the CLI bundle's packages."""

import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    assets = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
    cache = Path(os.environ["NUGET_PACKAGES"]).resolve(strict=True)
    if cache not in {Path(p).resolve() for p in assets["packageFolders"]}:
        raise ValueError("The isolated NuGet cache is not in the restored assets")
    sources = {s.rstrip("/") for s in assets["project"]["restore"]["sources"]}
    packages = {
        key: value
        for key, value in assets["libraries"].items()
        if value["type"] == "package"
        and key.lower().startswith("aspire.")
        and key.split("/", 1)[1].startswith("17.")
    }
    required = {"Aspire.Hosting.AppHost/17.0.0", "Aspire.Hosting.Dotnet/17.0.0"}
    if not required.issubset(packages):
        raise ValueError("Required Aspire 17.0.0 application packages were not restored")

    for identity, library in sorted(packages.items()):
        package_id, version = identity.split("/", 1)
        directory = cache / library["path"]
        archive = directory / f"{package_id.lower()}.{version.lower()}.nupkg"
        metadata = json.loads((directory / ".nupkg.metadata").read_text(encoding="utf-8-sig"))
        source = metadata["source"]
        if source.rstrip("/") not in sources:
            raise ValueError(f"{identity}: source is not in the restore's configured sources")
        with archive.open("rb") as stream:
            digest = base64.b64encode(hashlib.file_digest(stream, "sha512").digest()).decode()
        # NuGet's signed content hash differs from the raw archive digest.
        content_hash = library["sha512"].removeprefix("sha512-")
        if content_hash != metadata["contentHash"]:
            raise ValueError(f"{identity}: cache metadata does not match the restored assets")
        print(json.dumps({
            "package": identity, "source": source,
            "restoreContentHash": content_hash, "archiveSha512": digest,
        }), flush=True)
        subprocess.run(["dotnet", "nuget", "verify", "--all", str(archive)], check=True)

    print(f"Verified signatures and restore-source evidence for {len(packages)} Aspire 17 packages.")


if __name__ == "__main__":
    main()
