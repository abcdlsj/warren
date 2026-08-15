const parameterMeta = document.querySelector('meta[name="warren-injected-params"]');
const relayHostMeta = document.querySelector('meta[name="warren-relay-host-id"]');

const injectedParams = parameterMeta?.content || "__WARREN_INJECTED_PARAMS__";
const rawParams = injectedParams.startsWith("__WARREN_")
  ? (location.search || location.hash)
  : injectedParams;
const params = new URLSearchParams(rawParams.replace(/^[?#]/, ""));
const relayHostID = relayHostMeta?.content || "__WARREN_RELAY_HOST_ID__";
const usesControlPlane = !relayHostID.startsWith("__WARREN_");
const tokenStorageKey = usesControlPlane
  ? `warren.accessToken.${relayHostID}`
  : "warren.accessToken";
const suppliedToken = params.get("t") || "";

if (suppliedToken) localStorage.setItem(tokenStorageKey, suppliedToken);

export const runtime = {
  relayHostID,
  usesControlPlane,
  token: suppliedToken || localStorage.getItem(tokenStorageKey) || "",
};

export function webSocketURL() {
  const hostParam = params.get("host");
  const protocol = usesControlPlane
    ? (location.protocol === "https:" ? "wss:" : "ws:")
    : (hostParam ? "wss:" : (location.protocol === "https:" ? "wss:" : "ws:"));
  const host = usesControlPlane
    ? location.host
    : (hostParam || location.hostname || "127.0.0.1");
  const port = usesControlPlane || hostParam ? "" : (location.port || "8789");
  const path = usesControlPlane
    ? `/v1/client/connect?host_id=${encodeURIComponent(relayHostID)}`
    : "/v1/ws";
  return `${protocol}//${host}${port ? `:${port}` : ""}${path}`;
}

export function serviceWorkerURL() {
  return usesControlPlane
    ? `/h/${encodeURIComponent(relayHostID)}/service-worker.js`
    : "/service-worker.js";
}

export function webAssetURL(name) {
  const resource = String(name).replace(/^\/+/, "");
  return usesControlPlane
    ? `/h/${encodeURIComponent(relayHostID)}/${resource}`
    : `/${resource}`;
}
