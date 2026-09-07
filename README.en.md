# tunnel-kit

Self-hosted Xray (VLESS + Reality) with split routing, optional monitoring and a Telegram administration bot. Selected destinations use the tunnel; local networks and configured domains can connect directly.

[Русская документация](README.md) · [Security](SECURITY.md) · [Contributing](CONTRIBUTING.md)

## Requirements

- Server: Ubuntu 22.04/24.04, SSH key access and a provider recovery console.
- Server scripts: Bash, systemd, GNU utilities and `jq`. Traffic accounting also needs `vnstat`; the bot needs Python 3.10+, `sudo`, and optionally `qrencode`.
- Local converters: Python 3.10+, standard library only; no server access required.
- A compatible VLESS + Reality client. The included client example targets Shadowrocket.

This is an administrator toolkit, not a managed VPN service. Connectivity depends on your network, server IP, client version and destination service. No provider or region guarantees access.

## Start here

1. Read the [manual deployment guide](xray-vpn-deployment-guide.md) or the [AI-assisted setup prompt](ai-setup-prompt.md), currently in Russian. They use different SSH access models; choose one.
2. Configure your own server and client using fresh credentials. Never publish VLESS links, QR codes, subscriptions, backups or private configs.
3. Verify a real client connection and its exit IP, then test direct routes.
4. Add [monitoring, backups or the bot](optional-enhancements.md) only as needed. The router deployment guide is incomplete; converters are available.

## Local tools

```sh
python3 scripts/shadowrocket-to-xray.py ru-direct.list --strict-json
python3 scripts/wg-conf-to-routes.py /path/to/private-wireguard.conf --format xkeen
```

The Shadowrocket converter accepts a separate DIRECT list, not a full client configuration. `--geoip-file` must match the database installed on your router. WireGuard `bat` and `cli` exports support IPv4; `xkeen` can also export IPv6 networks. Diagnostics go to stderr. Exit status 2 indicates a home-network collision that must be resolved before importing routes.

## Development and release

```sh
python3 -m unittest discover -s tests -v
shellcheck --severity=warning scripts/*.sh
gitleaks git --redact --log-opts='--all' .
```

Linux service tests require a disposable container; see [CONTRIBUTING.md](CONTRIBUTING.md). Follow the [release checklist](docs/releasing.md) before publishing. Automated tests do not establish end-to-end VPN compatibility.

## License

[MIT](LICENSE). Third-party software and downloaded routing lists have their own licenses.
