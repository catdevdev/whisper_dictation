export const PROTOCOL_VERSION = 1;
export const DEFAULT_ENDPOINT = "ws://127.0.0.1:17777";
export const MAX_MESSAGE_BYTES = 1_048_576;
export const MAX_TEXT_LENGTH = 200_000;

export const SERVER_PROOF_DOMAIN = "OptionVoice/ws-auth/v1/server";
export const CLIENT_PROOF_DOMAIN = "OptionVoice/ws-auth/v1/client";

const SOCKET_CONNECTING = 0;
const SOCKET_OPEN = 1;
const HEX_256 = /^[0-9a-f]{64}$/;
const encoder = new TextEncoder();

export function normalizeEndpoint(value) {
  const candidate = String(value || DEFAULT_ENDPOINT).trim();
  let endpoint;
  try {
    endpoint = new URL(candidate);
  } catch {
    throw new TypeError("Enter a valid WebSocket URL.");
  }

  if (
    endpoint.protocol !== "ws:"
    || endpoint.hostname !== "127.0.0.1"
    || endpoint.port !== "17777"
    || (endpoint.pathname !== "/" && endpoint.pathname !== "")
    || endpoint.username
    || endpoint.password
    || endpoint.search
    || endpoint.hash
  ) {
    throw new TypeError("The bundled app uses only ws://127.0.0.1:17777.");
  }

  return endpoint.toString().replace(/\/$/, "");
}

export function normalizePairingCode(value, { allowEmpty = false } = {}) {
  const normalized = String(value ?? "").replace(/[\s-]+/g, "").toLowerCase();
  if (allowEmpty && normalized === "") {
    return "";
  }
  if (!HEX_256.test(normalized)) {
    throw new TypeError("The pairing code must contain exactly 64 hexadecimal characters.");
  }
  return normalized;
}

function bytesFromHex(value, field = "value") {
  const normalized = normalizePairingCode(value);
  const bytes = new Uint8Array(32);
  for (let index = 0; index < normalized.length; index += 2) {
    bytes[index / 2] = Number.parseInt(normalized.slice(index, index + 2), 16);
  }
  if (bytes.length !== 32) {
    throw new TypeError(`${field} must contain 32 bytes.`);
  }
  return bytes;
}

function hexFromBytes(value) {
  return Array.from(new Uint8Array(value), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function canonicalProof(domain, clientNonce, serverNonce) {
  return `${domain}\n${clientNonce}\n${serverNonce}`;
}

function cryptoAPI(provider = globalThis.crypto) {
  if (!provider?.subtle || typeof provider.getRandomValues !== "function") {
    throw new Error("Web Crypto is unavailable.");
  }
  return provider;
}

async function hmacKey(pairingCode, provider) {
  return cryptoAPI(provider).subtle.importKey(
    "raw",
    bytesFromHex(pairingCode, "pairing code"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"]
  );
}

export async function computePairingProof({
  pairingCode,
  domain,
  clientNonce,
  serverNonce,
  cryptoProvider = globalThis.crypto
}) {
  const code = normalizePairingCode(pairingCode);
  const client = normalizePairingCode(clientNonce);
  const server = normalizePairingCode(serverNonce);
  if (domain !== SERVER_PROOF_DOMAIN && domain !== CLIENT_PROOF_DOMAIN) {
    throw new TypeError("Unknown pairing proof domain.");
  }
  const key = await hmacKey(code, cryptoProvider);
  const signature = await cryptoProvider.subtle.sign(
    "HMAC",
    key,
    encoder.encode(canonicalProof(domain, client, server))
  );
  return hexFromBytes(signature);
}

export async function verifyPairingProof({
  pairingCode,
  domain,
  clientNonce,
  serverNonce,
  proof,
  cryptoProvider = globalThis.crypto
}) {
  const code = normalizePairingCode(pairingCode);
  const client = normalizePairingCode(clientNonce);
  const server = normalizePairingCode(serverNonce);
  const normalizedProof = normalizePairingCode(proof);
  if (domain !== SERVER_PROOF_DOMAIN && domain !== CLIENT_PROOF_DOMAIN) {
    return false;
  }
  const key = await hmacKey(code, cryptoProvider);
  return cryptoProvider.subtle.verify(
    "HMAC",
    key,
    bytesFromHex(normalizedProof, "proof"),
    encoder.encode(canonicalProof(domain, client, server))
  );
}

export class WebSocketBridge {
  constructor({
    endpoint = DEFAULT_ENDPOINT,
    pairingCode = "",
    onMessage = () => {},
    onStatus = () => {},
    socketFactory = (url) => new WebSocket(url),
    clientVersion = globalThis.chrome?.runtime?.getManifest?.().version || "unknown",
    cryptoProvider = globalThis.crypto
  } = {}) {
    this.endpoint = normalizeEndpoint(endpoint);
    this.pairingCode = normalizePairingCode(pairingCode, { allowEmpty: true });
    this.onMessage = onMessage;
    this.onStatus = onStatus;
    this.socketFactory = socketFactory;
    this.clientVersion = clientVersion;
    this.cryptoProvider = cryptoAPI(cryptoProvider);
    this.socket = null;
    this.reconnectTimer = null;
    this.heartbeatTimer = null;
    this.authenticationTimer = null;
    this.reconnectAttempt = 0;
    this.shouldReconnect = false;
    this.authenticated = false;
    this.authenticationBlocked = false;
    this.handshake = null;
  }

  start() {
    this.shouldReconnect = true;
    if (!this.pairingCode) {
      this.onStatus("pairing");
      return;
    }
    this.#connect();
  }

  stop() {
    this.shouldReconnect = false;
    this.#resetConnection("bridge stopped");
    this.onStatus("disconnected");
  }

  setEndpoint(endpoint) {
    const normalized = normalizeEndpoint(endpoint);
    if (normalized === this.endpoint) {
      return normalized;
    }
    this.endpoint = normalized;
    this.#restartIfActive("endpoint changed");
    return normalized;
  }

  setPairingCode(pairingCode) {
    const normalized = normalizePairingCode(pairingCode, { allowEmpty: true });
    if (normalized === this.pairingCode && !this.authenticationBlocked) {
      return normalized;
    }
    this.pairingCode = normalized;
    this.authenticationBlocked = false;
    this.#restartIfActive("pairing changed");
    return normalized;
  }

  send(message) {
    const serialized = JSON.stringify(message);
    if (encoder.encode(serialized).byteLength > MAX_MESSAGE_BYTES) {
      throw new RangeError("Bridge message exceeds the 1 MiB limit.");
    }

    if (this.authenticated && this.socket?.readyState === SOCKET_OPEN) {
      this.socket.send(serialized);
      return true;
    }
    return false;
  }

  #restartIfActive(reason) {
    const restart = this.shouldReconnect;
    this.#resetConnection(reason);
    if (!restart) {
      return;
    }
    if (!this.pairingCode) {
      this.onStatus("pairing");
    } else {
      this.#connect();
    }
  }

  #resetConnection(reason) {
    clearTimeout(this.reconnectTimer);
    clearInterval(this.heartbeatTimer);
    clearTimeout(this.authenticationTimer);
    this.reconnectTimer = null;
    this.heartbeatTimer = null;
    this.authenticationTimer = null;
    this.authenticated = false;
    this.handshake = null;
    const socket = this.socket;
    this.socket = null;
    socket?.close(1000, reason);
  }

  #rawSend(socket, message) {
    const serialized = JSON.stringify(message);
    if (encoder.encode(serialized).byteLength > MAX_MESSAGE_BYTES) {
      throw new RangeError("Bridge message exceeds the 1 MiB limit.");
    }
    if (socket === this.socket && socket.readyState === SOCKET_OPEN) {
      socket.send(serialized);
      return true;
    }
    return false;
  }

  #connect() {
    if (
      !this.shouldReconnect
      || !this.pairingCode
      || this.authenticationBlocked
      || this.socket?.readyState === SOCKET_OPEN
      || this.socket?.readyState === SOCKET_CONNECTING
    ) {
      return;
    }

    clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    this.onStatus("connecting");

    let socket;
    try {
      socket = this.socketFactory(this.endpoint);
    } catch (error) {
      this.onStatus("error", error instanceof Error ? error.message : String(error));
      this.#scheduleReconnect();
      return;
    }

    this.socket = socket;
    socket.addEventListener("open", () => {
      if (socket !== this.socket) {
        return;
      }
      this.authenticated = false;
      const nonceBytes = new Uint8Array(32);
      this.cryptoProvider.getRandomValues(nonceBytes);
      const clientNonce = hexFromBytes(nonceBytes);
      this.handshake = {
        socket,
        clientNonce,
        serverNonce: null,
        proofSent: false
      };
      this.onStatus("authenticating");
      this.#rawSend(socket, {
        type: "hello",
        protocol: PROTOCOL_VERSION,
        role: "chrome-extension",
        version: this.clientVersion,
        clientNonce
      });
      clearTimeout(this.authenticationTimer);
      this.authenticationTimer = setTimeout(() => {
        this.#failAuthentication(socket, "Pairing handshake timed out.");
      }, 7_500);
    });

    socket.addEventListener("message", (event) => {
      void this.#receive(socket, event);
    });

    socket.addEventListener("error", () => {
      if (socket === this.socket && !this.authenticationBlocked) {
        this.onStatus("error", "Не удаётся подключиться к Whisper.");
      }
    });

    socket.addEventListener("close", () => {
      if (socket !== this.socket) {
        return;
      }
      clearInterval(this.heartbeatTimer);
      clearTimeout(this.authenticationTimer);
      this.heartbeatTimer = null;
      this.authenticationTimer = null;
      this.socket = null;
      this.authenticated = false;
      this.handshake = null;
      if (this.authenticationBlocked) {
        return;
      }
      this.onStatus(this.pairingCode ? "disconnected" : "pairing");
      this.#scheduleReconnect();
    });
  }

  async #receive(socket, event) {
    if (
      socket !== this.socket
      || typeof event.data !== "string"
      || encoder.encode(event.data).byteLength > MAX_MESSAGE_BYTES
    ) {
      if (socket === this.socket) {
        this.onStatus("error", "The bridge sent an invalid or oversized message.");
      }
      return;
    }

    let message;
    try {
      message = JSON.parse(event.data);
      if (!message || typeof message !== "object" || Array.isArray(message)) {
        throw new TypeError("Message must be a JSON object.");
      }
    } catch {
      this.onStatus("error", "The bridge sent invalid JSON.");
      return;
    }

    if (!this.authenticated) {
      await this.#handleAuthenticationMessage(socket, message);
      return;
    }
    if (message.type === "challenge" || message.type === "authenticated") {
      this.onStatus("error", "The bridge sent a stale authentication message.");
      return;
    }
    this.onMessage(message);
  }

  async #handleAuthenticationMessage(socket, message) {
    if (message.type === "error") {
      this.#failAuthentication(
        socket,
        typeof message.message === "string"
          ? message.message
          : "The local app rejected the pairing code."
      );
      return;
    }
    if (message.protocol !== PROTOCOL_VERSION || !this.handshake) {
      this.#failAuthentication(socket, "The local app uses an incompatible pairing protocol.");
      return;
    }

    if (message.type === "challenge") {
      const handshake = this.handshake;
      try {
        const clientNonce = normalizePairingCode(message.clientNonce);
        const serverNonce = normalizePairingCode(message.serverNonce);
        const proof = normalizePairingCode(message.proof);
        if (
          handshake.socket !== socket
          || handshake.clientNonce !== clientNonce
          || handshake.serverNonce !== null
        ) {
          throw new Error("The local app sent a stale pairing challenge.");
        }

        const validServer = await verifyPairingProof({
          pairingCode: this.pairingCode,
          domain: SERVER_PROOF_DOMAIN,
          clientNonce,
          serverNonce,
          proof,
          cryptoProvider: this.cryptoProvider
        });
        if (!validServer || socket !== this.socket || handshake !== this.handshake) {
          throw new Error("The pairing code does not match the local app.");
        }

        const clientProof = await computePairingProof({
          pairingCode: this.pairingCode,
          domain: CLIENT_PROOF_DOMAIN,
          clientNonce,
          serverNonce,
          cryptoProvider: this.cryptoProvider
        });
        if (socket !== this.socket || handshake !== this.handshake) {
          return;
        }
        handshake.serverNonce = serverNonce;
        handshake.proofSent = true;
        this.#rawSend(socket, {
          type: "authenticate",
          protocol: PROTOCOL_VERSION,
          clientNonce,
          serverNonce,
          proof: clientProof
        });
      } catch (error) {
        this.#failAuthentication(
          socket,
          error instanceof Error ? error.message : "Pairing verification failed."
        );
      }
      return;
    }

    if (message.type === "authenticated") {
      const handshake = this.handshake;
      try {
        const clientNonce = normalizePairingCode(message.clientNonce);
        const serverNonce = normalizePairingCode(message.serverNonce);
        if (
          handshake.socket !== socket
          || !handshake.proofSent
          || handshake.clientNonce !== clientNonce
          || handshake.serverNonce !== serverNonce
        ) {
          throw new Error("The local app sent a stale authentication result.");
        }
      } catch (error) {
        this.#failAuthentication(
          socket,
          error instanceof Error ? error.message : "Pairing verification failed."
        );
        return;
      }

      clearTimeout(this.authenticationTimer);
      this.authenticationTimer = null;
      this.authenticated = true;
      this.handshake = null;
      this.authenticationBlocked = false;
      this.reconnectAttempt = 0;
      this.onStatus("connected");
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = setInterval(() => {
        this.send({
          type: "ping",
          protocol: PROTOCOL_VERSION,
          timestamp: Date.now()
        });
      }, 20_000);
      return;
    }

    this.#failAuthentication(socket, "The local app sent data before authentication.");
  }

  #failAuthentication(socket, message) {
    if (socket !== this.socket) {
      return;
    }
    this.authenticationBlocked = true;
    this.authenticated = false;
    clearTimeout(this.authenticationTimer);
    this.authenticationTimer = null;
    this.onStatus("pairing-error", message);
    socket.close(4003, "pairing failed");
  }

  #scheduleReconnect() {
    if (
      !this.shouldReconnect
      || !this.pairingCode
      || this.authenticationBlocked
      || this.reconnectTimer
    ) {
      return;
    }
    const exponential = Math.min(15_000, 500 * (2 ** this.reconnectAttempt));
    const delay = exponential + Math.floor(Math.random() * 250);
    this.reconnectAttempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.#connect();
    }, delay);
  }
}
