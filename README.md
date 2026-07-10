# Kindle Private Cloud

Tools and notes for building a privacy-preserving, self-hosted Kindle workflow
on a jailbroken Kindle.

The current working design avoids pretending to be Amazon's backend. Instead,
a private server publishes a manifest and book files, while a Kindle-side agent
downloads supported files into `/mnt/us/documents/PrivateCloud`. The stock
Kindle scanner/catalog then indexes those files so they appear in the existing
Library UI.

## Current Status

- Working self-hosted file/manifest server: `privatecloud/server.py`
- Working Kindle-side shell agent: `privatecloud/kindle-agent.sh`
- Working KUAL extension scaffold: `privatecloud/kual/`
- Working local-library ingestion through Kindle scanner/catalog
- Experimental catalog-row tooling for research only
- Planned daemon: Rust for the long-lived Kindle process, shell retained for
  deployment and simple KUAL entry points

The intentionally unsupported path is raw fake remote-row injection. It can
make private books visible/searchable before download, but tapping those rows
currently crashes the Kindle UI path because the deeper KPP/KSDK download
contract is not satisfied.

## Documentation

- Main report: `docs/kindle-private-cloud-report.html`
- Observation notes: `observer/README.md`
- Private cloud prototype notes: `privatecloud/README.md`

## Repository Hygiene

Raw captures, temporary Kindle databases, copied certificates, and copied
Kindle binaries are ignored. They may contain account/device information or
proprietary Amazon material and should stay local unless they are manually
redacted first.

## Safe Direction

1. Keep private content as local/sideloaded files from the Kindle point of view.
2. Use the private daemon for manifest sync, downloads, checksum verification,
   scanner refresh, and progress sidecar sync.
3. Block Amazon sync/upload paths only after mapping them precisely.
4. Revisit KPP/KSDK hooks later only if exact stock remote tap-to-download is
   still worth the firmware-specific risk.
