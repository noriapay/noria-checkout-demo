import { generateKeyPairSync } from 'crypto';
import http from 'http';
import assert from 'assert';

import { createMerchantServer } from './server.mjs';

function listen(server) {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => {
    resolve(server.address().port);
  }));
}

function close(server) {
  return new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}

function request(url, { method = 'GET', body } = {}) {
  return new Promise((resolve, reject) => {
    const rawBody = body === undefined ? undefined : JSON.stringify(body);
    const call = http.request(url, {
      method,
      headers: rawBody ? { 'Content-Type': 'application/json' } : undefined,
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({
        status: response.statusCode,
        body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
      }));
    });
    call.on('error', reject);
    call.end(rawBody);
  });
}

async function fixture() {
  const { privateKey } = generateKeyPairSync('ed25519');
  let receivedPayload;
  const upstream = http.createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    receivedPayload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    response.writeHead(201, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({
      id: '11111111-1111-4111-8111-111111111111',
      amountTotal: receivedPayload.lineItems.reduce(
        (total, item) => total + item.quantity * item.unitAmount,
        0,
      ),
      checkoutUrl: 'https://checkout.development.noriapay.com.br/session/11111111-1111-4111-8111-111111111111',
      clientSecret: 'secret-with-at-least-twenty-characters',
      expiresAt: '2030-01-01T00:00:00Z',
      returnState: receivedPayload.returnState,
    }));
  });
  const upstreamPort = await listen(upstream);
  const merchant = await createMerchantServer({
    apiUrl: `http://127.0.0.1:${upstreamPort}`,
    projectId: 'project-test',
    workspaceId: 'workspace-test',
    merchantOrigin: 'https://merchant.example',
    returnUrl: 'https://merchant.example/checkout/return',
    privateKey,
    basePath: '/demo-merchant',
  });
  const merchantPort = await listen(merchant);
  return {
    baseUrl: `http://127.0.0.1:${merchantPort}`,
    get receivedPayload() { return receivedPayload; },
    async close() {
      await close(merchant);
      await close(upstream);
    },
  };
}

async function run(name, body) {
  const server = await fixture();
  try {
    await body(server);
    console.log(`ok - ${name}`);
  } finally {
    await server.close();
  }
}

await run('serves a versioned server-owned catalog', async (server) => {
  const result = await request(`${server.baseUrl}/demo-merchant/v1/catalog`);
  assert.equal(result.status, 200);
  assert.equal(result.body.products.length, 4);
  assert.match(result.body.version, /^[a-f0-9]{64}$/);
});

await run('recalculates SKU values before creating a session', async (server) => {
  const catalog = await request(`${server.baseUrl}/demo-merchant/v1/catalog`);
  const result = await request(`${server.baseUrl}/demo-merchant/v1/checkout-session`, {
    method: 'POST',
    body: {
      cartId: 'cart-valid-1234567890',
      catalogVersion: catalog.body.version,
      items: [
        { sku: 'ARC-SPEAKER-01', quantity: 2 },
        { sku: 'ORBIT-CHARGER-01', quantity: 1 },
      ],
    },
  });
  assert.equal(result.status, 201);
  assert.equal(result.body.order.amountTotal, 6270);
  assert.equal(server.receivedPayload.lineItems[0].unitAmount, 2490);
  assert.equal(server.receivedPayload.lineItems[1].unitAmount, 1290);
  assert.equal('unitAmount' in result.body.order.lineItems[0], true);
});

await run('rejects a price supplied by the app', async (server) => {
  const catalog = await request(`${server.baseUrl}/demo-merchant/v1/catalog`);
  const result = await request(`${server.baseUrl}/demo-merchant/v1/checkout-session`, {
    method: 'POST',
    body: {
      cartId: 'cart-valid-1234567890',
      catalogVersion: catalog.body.version,
      items: [{ sku: 'ARC-SPEAKER-01', quantity: 1, unitAmount: 1 }],
    },
  });
  assert.equal(result.status, 422);
  assert.equal(result.body.errors[0].code, 'invalidItems');
});

await run('rejects a stale catalog version', async (server) => {
  const result = await request(`${server.baseUrl}/demo-merchant/v1/checkout-session`, {
    method: 'POST',
    body: {
      cartId: 'cart-valid-1234567890',
      catalogVersion: 'stale',
      items: [{ sku: 'ARC-SPEAKER-01', quantity: 1 }],
    },
  });
  assert.equal(result.status, 409);
  assert.equal(result.body.errors[0].code, 'catalogChanged');
});
