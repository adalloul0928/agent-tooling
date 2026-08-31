#!/usr/bin/env python3
"""Generate the minimal SPDX 2.3 release SBOM for the self-contained app."""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: generate-sbom.py VERSION OUTPUT_PATH COMMIT_SHA", file=sys.stderr)
        return 64
    version, output_path, commit_sha = sys.argv[1:]
    license_identifier = os.environ.get("AGENT_TOOLING_LICENSE", "NOASSERTION")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        print("version must be semantic version X.Y.Z", file=sys.stderr)
        return 64
    if not re.fullmatch(r"[0-9a-f]{40}", commit_sha):
        print("commit SHA must be 40 lowercase hexadecimal characters", file=sys.stderr)
        return 64
    if not re.fullmatch(r"(?:NOASSERTION|[A-Za-z0-9.+-]+)", license_identifier):
        print("AGENT_TOOLING_LICENSE must be an SPDX identifier or NOASSERTION", file=sys.stderr)
        return 64

    output = pathlib.Path(output_path)
    if not output.parent.is_dir() or output.is_symlink():
        print("output parent must be an existing directory", file=sys.stderr)
        return 64

    package_id = "SPDXRef-Package-AgentTooling"
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"Agent-Tooling-{version}",
        "documentNamespace": (
            "https://github.com/agent-tooling/agent-tooling-app/"
            f"releases/{version}/sbom-{commit_sha}"
        ),
        "creationInfo": {
            "creators": ["Tool: agent-tooling-generate-sbom/1"],
            "created": "1970-01-01T00:00:00Z",
            "comment": "The release workflow records the immutable commit and artifact provenance.",
        },
        "packages": [
            {
                "name": "Agent Tooling",
                "SPDXID": package_id,
                "versionInfo": version,
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": license_identifier,
                "licenseDeclared": license_identifier,
                "copyrightText": "NOASSERTION",
                "externalRefs": [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": f"pkg:github/agent-tooling/agent-tooling-app@{commit_sha}",
                    }
                ],
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
    output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    output.chmod(0o644)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
