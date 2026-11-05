"""
Cloud backends for the control app.

The control app itself is cloud-neutral: it owns the catalogue, the readiness
checks, the safety ceiling and the sweeper. Everything that talks to a cloud -
finding hosts, running a command on one, reading alarm state, creating the lab -
lives behind a provider. CLOUD picks which one (aws by default, so existing
setups keep working unchanged).

Both providers are imported lazily so an AWS operator never needs the Azure
SDK importable, and the reverse.
"""

import os


def load_provider():
    cloud = os.environ.get("CLOUD", "aws").strip().lower()
    if cloud == "aws":
        from server.providers.aws import AwsProvider
        return AwsProvider()
    if cloud == "azure":
        from server.providers.azure import AzureProvider
        return AzureProvider()
    raise RuntimeError(f"CLOUD must be aws or azure, not {cloud!r}")
