import test from "node:test";
import assert from "node:assert/strict";

import {
  CLIENT_PROOF_DOMAIN,
  DEFAULT_ENDPOINT,
  SERVER_PROOF_DOMAIN,
  WebSocketBridge,
  computePairingProof,
  normalizeEndpoint,
  normalizePairingCode
} from "../bridge.js";

class MockSocket extends EventTarget {
  constructor() {
    super();
    this.readyState = 0;
    this.sent = [];
  }

  open() {
    this.readyState = 1;
    this.dispatchEvent(new Event("open"));
  }

  message(value) {
    this.dispatchEvent(new MessageEvent("message", {
      data: JSON.stringify(value)
    }));
  }

  send(payload) {
    this.sent.push(JSON.parse(payload));
  }

  close() {
    if (this.readyState === 3) {
      return;
    }
    this.readyState = 3;
    this.dispatchEvent(new Event("close"));
  }
}

async function waitFor(predicate, timeout = 2_000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() >= deadline) {
      throw new Error("Timed out waiting for test condition.");
    }
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
}

test("accepts only the bundled app WebSocket endpoint", () => {
  assert.equal(normalizeEndpoint(), DEFAULT_ENDPOINT);
  assert.equal(normalizeEndpoint(" ws://127.0.0.1:17777/ "), DEFAULT_ENDPOINT);
});

test("rejects every endpoint the bundled app does not implement", () => {
  assert.throws(() => normalizeEndpoint("wss://127.0.0.1:17777"), /bundled app/);
  assert.throws(() => normalizeEndpoint("ws://localhost:17777"), /bundled app/);
  assert.throws(() => normalizeEndpoint("ws://127.0.0.1:19000"), /bundled app/);
  assert.throws(() => normalizeEndpoint("ws://user:pass@127.0.0.1:17777"), /bundled app/);
  assert.throws(() => normalizeEndpoint("ws://127.0.0.1:17777?token=secret"), /bundled app/);
});

test("normalizes and validates 256-bit pairing codes", () => {
  const code = "A1".repeat(32);
  assert.equal(normalizePairingCode(` ${code}\n`), code.toLowerCase());
  assert.equal(
    normalizePairingCode(code.match(/.{1,8}/g).join("-")),
    code.toLowerCase()
  );
  assert.equal(normalizePairingCode("", { allowEmpty: true }), "");
  assert.throws(() => normalizePairingCode("a1"), /64 hexadecimal/);
  assert.throws(() => normalizePairingCode("z".repeat(64)), /64 hexadecimal/);
});

test("does not connect when the pairing code is missing", () => {
  let factoryCalls = 0;
  const statuses = [];
  const bridge = new WebSocketBridge({
    socketFactory: () => {
      factoryCalls += 1;
      return new MockSocket();
    },
    onStatus: (value) => statuses.push(value)
  });

  bridge.start();
  assert.equal(factoryCalls, 0);
  assert.deepEqual(statuses, ["pairing"]);
  assert.equal(bridge.send({ type: "speak", text: "stale" }), false);
  bridge.stop();
});

test("reports connected only after mutual authentication", async () => {
  const pairingCode = "11".repeat(32);
  const serverNonce = "22".repeat(32);
  const statuses = [];
  const socket = new MockSocket();
  const bridge = new WebSocketBridge({
    pairingCode,
    clientVersion: "test",
    socketFactory: () => socket,
    onStatus: (value) => statuses.push(value)
  });

  bridge.start();
  socket.open();
  const hello = socket.sent[0];
  assert.equal(hello.type, "hello");
  assert.equal(hello.protocol, 1);
  assert.equal(hello.role, "chrome-extension");
  assert.match(hello.clientNonce, /^[0-9a-f]{64}$/);
  assert.equal(statuses.includes("connected"), false);

  const serverProof = await computePairingProof({
    pairingCode,
    domain: SERVER_PROOF_DOMAIN,
    clientNonce: hello.clientNonce,
    serverNonce
  });
  socket.message({
    type: "challenge",
    protocol: 1,
    clientNonce: hello.clientNonce,
    serverNonce,
    proof: serverProof
  });
  await waitFor(() => socket.sent.length === 2);

  const authenticate = socket.sent[1];
  assert.equal(authenticate.type, "authenticate");
  assert.equal(authenticate.clientNonce, hello.clientNonce);
  assert.equal(authenticate.serverNonce, serverNonce);
  assert.equal(
    authenticate.proof,
    await computePairingProof({
      pairingCode,
      domain: CLIENT_PROOF_DOMAIN,
      clientNonce: hello.clientNonce,
      serverNonce
    })
  );
  assert.equal(statuses.includes("connected"), false);

  socket.message({
    type: "authenticated",
    protocol: 1,
    clientNonce: hello.clientNonce,
    serverNonce
  });
  await waitFor(() => statuses.at(-1) === "connected");
  assert.equal(bridge.send({ type: "ping", protocol: 1, timestamp: 1 }), true);
  assert.equal(socket.sent.at(-1).type, "ping");
  bridge.stop();
});

test("rejects a stale challenge from an earlier connection", async () => {
  const pairingCode = "33".repeat(32);
  const serverNonce = "44".repeat(32);
  const sockets = [];
  const statuses = [];
  const bridge = new WebSocketBridge({
    pairingCode,
    socketFactory: () => {
      const socket = new MockSocket();
      sockets.push(socket);
      return socket;
    },
    onStatus: (value) => statuses.push(value)
  });

  bridge.start();
  sockets[0].open();
  const staleClientNonce = sockets[0].sent[0].clientNonce;

  bridge.setPairingCode("55".repeat(32));
  sockets[1].open();
  const freshClientNonce = sockets[1].sent[0].clientNonce;
  assert.notEqual(freshClientNonce, staleClientNonce);

  const staleProof = await computePairingProof({
    pairingCode,
    domain: SERVER_PROOF_DOMAIN,
    clientNonce: staleClientNonce,
    serverNonce
  });
  sockets[1].message({
    type: "challenge",
    protocol: 1,
    clientNonce: staleClientNonce,
    serverNonce,
    proof: staleProof
  });

  await waitFor(() => statuses.at(-1) === "pairing-error");
  assert.equal(sockets[1].sent.length, 1);
  assert.equal(sockets[1].readyState, 3);
  bridge.stop();
});
