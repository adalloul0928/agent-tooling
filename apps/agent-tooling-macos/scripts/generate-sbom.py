#!/usr/bin/env python3
"""Generate an SPDX 2.3 manifest for the app and its pinned Swift dependencies."""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys
from datetime import datetime, timezone


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: generate-sbom.py VERSION OUTPUT_PATH COMMIT_SHA", file=sys.stderr)
        return 64
    version, output_path, commit_sha = sys.argv[1:]
    repository = os.environ.get("GITHUB_REPOSITORY")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        print("version must be semantic version X.Y.Z", file=sys.stderr)
        return 64
    if not re.fullmatch(r"[0-9a-f]{40}", commit_sha):
        print("commit SHA must be 40 lowercase hexadecimal characters", file=sys.stderr)
        return 64
    if repository and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        print("GITHUB_REPOSITORY must be an owner/repository pair", file=sys.stderr)
        return 64

    output = pathlib.Path(output_path)
    if not output.parent.is_dir() or output.is_symlink():
        print("output parent must be an existing directory", file=sys.stderr)
        return 64

    license_path = pathlib.Path(__file__).resolve().parents[3] / "LICENSE"
    try:
        license_text = license_path.read_text(encoding="utf-8")
    except OSError:
        print("could not read repository LICENSE", file=sys.stderr)
        return 66
    copyright_lines = [line for line in license_text.splitlines() if line.startswith("Copyright ")]
    if not license_text.startswith("MIT License\n") or not copyright_lines:
        print("repository LICENSE must contain the MIT license and copyright notice", file=sys.stderr)
        return 65

    package_id = "SPDXRef-Package-AgentTooling"
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"Agent-Tooling-{version}",
        "documentNamespace": f"https://spdx.org/spdxdocs/agent-tooling-{version}-{commit_sha}",
        "creationInfo": {
            "creators": ["Tool: agent-tooling-generate-sbom/1"],
            "created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
        "packages": [
            {
                "name": "Agent Tooling",
                "SPDXID": package_id,
                "versionInfo": version,
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": "MIT",
                "licenseDeclared": "MIT",
                "copyrightText": "\n".join(copyright_lines),
            }
        ],
        "relationships": [
            {
                "spdxElementId": "SPDXRef-DOCUMENT",
                "relationshipType": "DESCRIBES",
                "relatedSpdxElement": package_id,
            }
        ],
    }
    if repository:
        document["documentNamespace"] = (
            f"https://github.com/{repository}/releases/{version}/sbom-{commit_sha}"
        )
        document["packages"][0]["downloadLocation"] = (
            f"https://github.com/{repository}/releases/download/"
            f"agent-tooling-app-v{version}/Agent-Tooling-arm64.dmg"
        )
        document["packages"][0]["externalRefs"] = [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:github/{repository}@{commit_sha}",
            }
        ]
    lockfile = pathlib.Path(__file__).resolve().parents[1] / "Package.resolved"
    for pin in sorted(json.loads(lockfile.read_text())["pins"], key=lambda item: item["identity"]):
        identity = pin["identity"]
        dependency_id = f"SPDXRef-Package-{identity}"
        state = pin["state"]
        dependency = {
            "name": identity,
            "SPDXID": dependency_id,
            "versionInfo": state.get("version", state["revision"]),
            "downloadLocation": f"git+{pin['location']}@{state['revision']}",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "MIT" if identity == "yams" else "NOASSERTION",
            "copyrightText": "Copyright (c) 2016 JP Simard." if identity == "yams" else "NOASSERTION",
        }
        document["packages"].append(dependency)
        document["relationships"].append({
            "spdxElementId": package_id,
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": dependency_id,
        })
        if identity == "yams":
            document["packages"].append({
                "name": "LibYAML",
                "SPDXID": "SPDXRef-Package-libyaml",
                "downloadLocation": dependency["downloadLocation"],
                "sourceInfo": (
                    "Vendored in Yams under Sources/CYaml; upstream provenance includes "
                    "https://github.com/yaml/libyaml/commit/840b65c40675e2d06bf40405ad3f12dec7f35923."
                ),
                "filesAnalyzed": False,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "MIT",
                "copyrightText": "Copyright (c) 2017-2020 Ingy döt Net\nCopyright (c) 2006-2016 Kirill Simonov",
            })
            document["relationships"].append({
                "spdxElementId": dependency_id,
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": "SPDXRef-Package-libyaml",
            })
    output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    output.chmod(0o644)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
