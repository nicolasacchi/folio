# Security Policy

## Scope and threat model

This is a self-hosted project designed for a **trusted private network**.
It is not hardened for public internet exposure:

- The kindled↔server device API and the legacy `privatecloud/` prototype
  speak plain HTTP with bearer tokens. Deploy them only on a trusted LAN
  or over WireGuard/Tailscale.
- The Folio web UI should be served over HTTPS (Rails `force_ssl` is
  enabled in production; put a TLS-terminating reverse proxy in front of
  it).
- The Kindle daemon runs on a jailbroken device and intentionally
  interacts with firmware internals; only run it against servers you
  control.

Security reports are in scope for issues that break this model — for
example token leakage, authentication bypass on the device API or web UI,
path traversal in file serving/download, or unsafe handling of uploaded
ebooks. Issues that only apply when the server is exposed to the open
internet are still welcome, but please say so in the report.

## Reporting a vulnerability

Please report vulnerabilities through **GitHub Private Vulnerability
Reporting** on the repository:

https://github.com/nicolasacchi/kindle-private-cloud/security/advisories/new

Please do not open public issues for security problems. Include a
description, affected component (`server/`, `kindled/`, `privatecloud/`,
`tools/`), steps to reproduce, and the commit or version you tested
against. There is no bounty program and no formal response-time
commitment — this is a hobby project — but reports will be acknowledged
and credited (with your permission) in the fix commit.
