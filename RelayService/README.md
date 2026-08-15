# Warren Relay Service

Warren Relay is an independently deployable remote control plane. It stores Host identity, online presence, and revocation generations, and forwards WebSocket frames; Projects, Workspaces, Sessions, tmux, and Terminal output exist only on the macOS Host. Relay never records or parses terminal business frames.

## One-Command Experience

From the repository root:

```bash
mise run relay:dev
```

This command automatically generates a local development secret, starts Relay, registers the current Mac, builds and starts Warren, waits for the Host to come online, completes a one-time pairing, and opens the Web/PWA. Generated development state is stored in the git-ignored `.build/relay-dev/8080` directory, and secret files use `0600` permissions. The local Relay listens on all LAN interfaces by default and writes the Mac's LAN address into the pairing URL, so phones on the same network as the Mac can reach it. Use `WARREN_RELAY_DEV_HOST=192.168.1.23` to specify an address reachable from the phone, or `WARREN_RELAY_DEV_BIND_HOST=192.168.1.23` to restrict listening to a single interface. This development mode is only suitable for a trusted LAN; do not expose the port to the public internet.

Daily commands:

```bash
mise run relay:pair    # open another remote client
mise run relay:status  # show Relay and Host status
mise run relay:stop    # stop only the Relay; keep Warren running and tmux alive
```

Connecting to a deployed public Relay is also one command; the admin token is only needed for the first registration of this Mac:

```bash
WARREN_RELAY_URL=https://relay.example.com \
WARREN_RELAY_ADMIN_TOKEN='<admin-token>' \
mise run relay:connect
```

Afterwards, the same address keeps the Host ID and a `0600`-permissioned Host credential in `~/Library/Application Support/Warren/relay-cli/<relay-id>`; Warren itself imports the credential into the macOS Keychain, so later runs can omit the admin token. If the Host is already online, re-running does not rebuild or restart the app; it only generates a new pairing URL. Add `WARREN_RELAY_NO_OPEN=1` to skip opening the browser automatically.

## Start

First generate three secrets: the admin token and a signing key of at least 32 bytes. Production must terminate TLS behind an HTTPS/WSS reverse proxy.

```bash
export WARREN_RELAY_ADMIN_TOKEN='replace-admin-token'
export WARREN_RELAY_SIGNING_KEY='replace-with-at-least-32-random-bytes'
export WARREN_RELAY_PUBLIC_URL='https://relay.example.com'
export WARREN_RELAY_ALLOWED_ORIGIN='https://relay.example.com'
go run ./RelayService/cmd/warren-relay
```

Or build a container:

```bash
docker build -f RelayService/Dockerfile -t warren-relay .
docker run --read-only -p 8080:8080 -v warren-relay-data:/data \
  -e WARREN_RELAY_ADMIN_TOKEN \
  -e WARREN_RELAY_SIGNING_KEY \
  -e WARREN_RELAY_PUBLIC_URL \
  -e WARREN_RELAY_ALLOWED_ORIGIN \
  warren-relay
```

If using `--read-only`, the runtime also needs a writable temporary directory (for example `--tmpfs /tmp`); persistent data is only written to `/data`.

## Host Registration and Connection

Admins issue a separate credential for each Host; the credential is shown only once in the response, and Relay stores only its SHA-256 hash. Re-provisioning the same Host rotates the credential and revokes existing client tokens.

```bash
export WARREN_HOST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
curl -sS -X POST https://relay.example.com/v1/hosts \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"$WARREN_HOST_ID\",\"name\":\"My Mac\"}"
```

Configure the returned credential in the launch environment of Warren.app the first time. Warren imports it into the macOS Keychain and reads it on later launches; control-plane secrets are stripped from the environment of every tmux/shell child process:

```bash
env WARREN_CONTROL_PLANE_URL=https://relay.example.com \
  WARREN_CONTROL_PLANE_HOST_ID="$WARREN_HOST_ID" \
  WARREN_CONTROL_PLANE_HOST_TOKEN='<host-credential>' \
  ./Warren.app/Contents/MacOS/Warren
```

Warren only makes outbound WSS connections; with no control plane configured, it still listens on `127.0.0.1` only.

## Pairing, Discovery, and Revocation

An admin or the Host's own credential can generate a 10-minute, one-time pairing code:

```bash
curl -sS -X POST https://relay.example.com/v1/hosts/<host-uuid>/pairing \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN"
```

A client exchanges the code for an access token bound to the Host and credential generation:

```bash
curl -sS -X POST https://relay.example.com/v1/pair \
  -H 'Content-Type: application/json' \
  -d '{"host_id":"<host-uuid>","pairing_code":"<one-time-code>"}'
```

`web_url` in the response is the responsive Web/PWA entry point. Revoking a Host disconnects the outbound tunnel and immediately invalidates all previously issued access tokens:

```bash
curl -sS -X DELETE https://relay.example.com/v1/hosts/<host-uuid> \
  -H "Authorization: Bearer $WARREN_RELAY_ADMIN_TOKEN"
```

## Security Boundaries

- The admin API uses a separate bootstrap token; each Host uses a separate credential.
- Pairing codes are one-time and short-lived; client tokens use HMAC-SHA256 bound to the Host and generation.
- Client tokens appear only in the URL fragment and the first WebSocket auth frame, never in HTTP query strings or normal access logs.
- Relay registry writes are atomic with `0600` permissions and only store Host credential hashes and control-plane metadata.
- Each WebSocket message is capped at 8 MiB, and each virtual connection has a bounded memory queue; slow clients are closed.
- Relay never sends the local Web pairing token to browsers: the Host connector rewrites only the first auth frame at a trusted edge.
- Production deployments must use TLS, strong random secrets, a persistent volume, and a strict `WARREN_RELAY_ALLOWED_ORIGIN`.

The registry and Host tunnels currently live in a single Relay instance; deployments should stay single-replica with a persistent volume. Horizontal scaling requires moving registry, presence, and connection routing to a shared storage/messaging layer first.
