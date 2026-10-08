# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them privately through GitHub's
[private vulnerability reporting](https://github.com/colonket/kual-games-and-utils/security/advisories/new)
(the **Security → Report a vulnerability** button on this repository).

Include what you found, how to reproduce it, and which Kindle model and firmware you used if it matters.
You'll get an acknowledgement within about a week. Fixes go into `main`, and the advisory is published once a
fix is available.

## Scope

In scope: everything in this repository, especially

- `extension/einkapps/lua/core/net.lua` and `ws.lua` (TLS, certificate and hostname checks, redirects)
- handling of the OGS and Lichess credentials (`lua/apps/ogs/api.lua`, `lua/apps/lichess/api.lua`)
- anything that turns network content (feeds, web pages, API responses) into shell commands or file paths
- `extension/einkapps/bin/run.sh`, which runs as root on the Kindle

Out of scope: the jailbreak, KUAL and KOReader themselves (report those upstream), and attacks that need
physical or USB access to an unlocked Kindle, since that already gives full control of the device.

## Known limitations

- Tokens are stored in plain text under `extensions/einkapps/data/`. The Kindle's user storage has no file
  permissions, so anything on the device or anyone with USB access can read them. Revoke them from your
  Lichess / OGS account settings if a Kindle is lost.
- The bundled CA list (`assets/cacert.pem`, from certifi) is refreshed with `tools/build_assets.py`.
