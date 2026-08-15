# Warren Web

The responsive Web/PWA client uses React + Vite. React component source lives in `Web/src/`, and production build output is written to `Web/dist/`, which is embedded by both the Go daemon and the Go Relay Service.

## Development

```sh
npm --prefix Web install
mise run web:dev
```

The Vite dev server only serves frontend assets; React owns the UI component tree and client state, and xterm mounts onto the terminal node through a component ref. To connect to a local Warren WebSocket, keep using the daemon's 8789 port, or configure a temporary reverse proxy for Vite.

## Build and Verify

```sh
mise run web:build
mise run verify:web
```

Do not edit `Web/dist/` directly. It is Vite build output and is cleared and regenerated on every build.

Runtime parameters are injected through meta placeholders in `index.html`:

- `__WARREN_INJECTED_PARAMS__`: local Web host and token parameters.
- `__WARREN_RELAY_HOST_ID__`: target Host ID for the central Relay.

SSH, the WebSocket protocol, and the Host resource model do not belong to the Vite project; they are maintained by the Go server side.
