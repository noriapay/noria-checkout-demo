import {
  createHash,
  createPrivateKey,
  randomBytes,
  sign,
} from 'node:crypto';
import { readFile } from 'node:fs/promises';
import http from 'node:http';
import https from 'node:https';
import { fileURLToPath } from 'node:url';

const catalogFile = new URL('./catalog.json', import.meta.url);
const rawCatalog = await readFile(catalogFile);
const parsedCatalog = JSON.parse(rawCatalog);
const catalogVersion = createHash('sha256').update(rawCatalog).digest('hex');
const catalogProducts = new Map(
  parsedCatalog.products.map((product) => [product.sku, Object.freeze(product)]),
);
const catalogResponse = Object.freeze({
  version: catalogVersion,
  products: [...catalogProducts.values()],
});

function required(value, name) {
  const normalized = value?.trim();
  if (!normalized) throw new Error(`${name} is required`);
  return normalized;
}

function verifiedUrl(value, name, { allowLoopback = false } = {}) {
  const url = new URL(required(value, name));
  const loopback =
    allowLoopback &&
    url.protocol === 'http:' &&
    (url.hostname === '127.0.0.1' || url.hostname === 'localhost');
  if (
    (url.protocol !== 'https:' && !loopback) ||
    url.username ||
    url.password ||
    url.hash
  ) {
    throw new Error(`${name} must be a trusted HTTPS URL`);
  }
  return url;
}

function parseAllowedOrigins(value) {
  if (!value?.trim()) return new Set();
  return new Set(
    value.split(',').map((origin) => verifiedUrl(origin, 'STORE_ALLOWED_ORIGINS').origin),
  );
}

function pathPrefix(value) {
  const normalized = value?.trim().replace(/\/$/, '') ?? '';
  if (!normalized) return '';
  if (!/^\/[a-z0-9-]+(?:\/[a-z0-9-]+)*$/.test(normalized)) {
    throw new Error('STORE_BASE_PATH must be a simple absolute path');
  }
  return normalized;
}

async function configuration(overrides = {}) {
  const apiUrl = verifiedUrl(
    overrides.apiUrl ?? process.env.NORIA_API_URL,
    'NORIA_API_URL',
    { allowLoopback: true },
  );
  const privateKey = overrides.privateKey ?? createPrivateKey(
    await readFile(required(
      overrides.privateKeyFile ?? process.env.NORIA_PRIVATE_KEY_FILE,
      'NORIA_PRIVATE_KEY_FILE',
    )),
  );
  const merchantOrigin = verifiedUrl(
    overrides.merchantOrigin ?? process.env.NORIA_MERCHANT_ORIGIN,
    'NORIA_MERCHANT_ORIGIN',
  ).origin;
  const returnUrl = verifiedUrl(
    overrides.returnUrl ?? process.env.NORIA_MERCHANT_RETURN_URL,
    'NORIA_MERCHANT_RETURN_URL',
  ).toString();
  return {
    apiUrl,
    projectId: required(overrides.projectId ?? process.env.NORIA_PROJECT_ID, 'NORIA_PROJECT_ID'),
    workspaceId: required(overrides.workspaceId ?? process.env.NORIA_WORKSPACE_ID, 'NORIA_WORKSPACE_ID'),
    merchantOrigin,
    returnUrl,
    privateKey,
    allowedOrigins: overrides.allowedOrigins ?? parseAllowedOrigins(process.env.STORE_ALLOWED_ORIGINS),
    basePath: pathPrefix(overrides.basePath ?? process.env.STORE_BASE_PATH),
  };
}

function signedHeaders(config, method, path, rawBody) {
  const accessId = `project/${config.projectId}/workspace/${config.workspaceId}`;
  const accessTime = new Date().toISOString();
  const canonical = [
    accessId,
    accessTime,
    method,
    path,
    '',
    createHash('sha256').update(rawBody).digest('hex'),
  ].join('\n');
  return {
    Accept: 'application/json',
    'Access-Id': accessId,
    'Access-Time': accessTime,
    'Access-Signature': sign(null, Buffer.from(canonical), config.privateKey).toString('base64'),
    'Content-Type': 'application/json',
  };
}

function requestJson(url, { method, headers, body }) {
  const transport = url.protocol === 'https:' ? https : http;
  return new Promise((resolve, reject) => {
    const request = transport.request(url, { method, headers, timeout: 10000 }, (response) => {
      const chunks = [];
      let size = 0;
      response.on('data', (chunk) => {
        size += chunk.length;
        if (size > 1024 * 1024) {
          request.destroy(new Error('upstream response is too large'));
          return;
        }
        chunks.push(chunk);
      });
      response.on('end', () => {
        try {
          resolve({
            status: response.statusCode ?? 502,
            body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
          });
        } catch {
          reject(new Error('upstream returned invalid JSON'));
        }
      });
    });
    request.on('timeout', () => request.destroy(new Error('upstream timeout')));
    request.on('error', reject);
    request.end(body);
  });
}

function error(status, code, message) {
  return { status, body: { errors: [{ code, message }] } };
}

function validateCheckoutRequest(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return error(400, 'invalidRequest', 'O carrinho é inválido.');
  }
  const allowedKeys = new Set(['cartId', 'catalogVersion', 'items']);
  if (Object.keys(input).some((key) => !allowedKeys.has(key))) {
    return error(422, 'unexpectedField', 'O app não pode enviar preços ou campos extras.');
  }
  if (!/^[a-z0-9_-]{16,64}$/.test(input.cartId ?? '')) {
    return error(422, 'invalidCartId', 'O identificador do carrinho é inválido.');
  }
  if (input.catalogVersion !== catalogVersion) {
    return error(409, 'catalogChanged', 'O catálogo mudou. Atualize a loja antes de pagar.');
  }
  if (!Array.isArray(input.items) || input.items.length === 0 || input.items.length > 20) {
    return error(422, 'invalidItems', 'O carrinho deve conter de 1 a 20 produtos.');
  }
  const seen = new Set();
  const items = [];
  for (const item of input.items) {
    if (
      !item ||
      typeof item !== 'object' ||
      Array.isArray(item) ||
      Object.keys(item).some((key) => key !== 'sku' && key !== 'quantity') ||
      typeof item.sku !== 'string' ||
      !Number.isSafeInteger(item.quantity) ||
      item.quantity < 1 ||
      item.quantity > 10 ||
      seen.has(item.sku)
    ) {
      return error(422, 'invalidItems', 'Os itens do carrinho são inválidos.');
    }
    const product = catalogProducts.get(item.sku);
    if (!product) return error(422, 'unknownProduct', 'Um produto não está mais disponível.');
    seen.add(item.sku);
    items.push({
      sku: product.sku,
      name: product.name,
      description: product.description,
      quantity: item.quantity,
      unitAmount: product.unitAmount,
    });
  }
  const amountTotal = items.reduce(
    (total, item) => total + item.quantity * item.unitAmount,
    0,
  );
  if (!Number.isSafeInteger(amountTotal) || amountTotal <= 0) {
    return error(422, 'invalidAmount', 'O total do carrinho é inválido.');
  }
  return { cartId: input.cartId, items, amountTotal };
}

async function readBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 16 * 1024) throw new Error('requestTooLarge');
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new Error('invalidJson');
  }
}

function responseHeaders(request, config, { noStore = false } = {}) {
  const headers = {
    'Content-Type': 'application/json; charset=utf-8',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'Cross-Origin-Resource-Policy': 'same-site',
  };
  if (noStore) headers['Cache-Control'] = 'no-store';
  const origin = request.headers.origin;
  if (origin && config.allowedOrigins.has(origin)) {
    headers['Access-Control-Allow-Origin'] = origin;
    headers.Vary = 'Origin';
  }
  return headers;
}

function send(request, response, config, status, body, options) {
  response.writeHead(status, responseHeaders(request, config, options));
  response.end(JSON.stringify(body));
}

export async function createMerchantServer(overrides = {}) {
  const config = await configuration(overrides);
  return http.createServer(async (request, response) => {
    const url = new URL(request.url, 'http://merchant.local');
    const routePath = config.basePath
      ? url.pathname.startsWith(`${config.basePath}/`)
        ? url.pathname.slice(config.basePath.length)
        : ''
      : url.pathname;
    const origin = request.headers.origin;
    if (origin && !config.allowedOrigins.has(origin)) {
      send(request, response, config, 403, error(403, 'originDenied', 'Origem não autorizada.').body, { noStore: true });
      return;
    }
    if (request.method === 'OPTIONS') {
      if (!origin) {
        send(request, response, config, 400, error(400, 'invalidRequest', 'Origem obrigatória.').body);
        return;
      }
      response.writeHead(204, {
        ...responseHeaders(request, config),
        'Access-Control-Allow-Headers': 'content-type',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Max-Age': '600',
      });
      response.end();
      return;
    }
    if (request.method === 'GET' && routePath === '/health' && !url.search) {
      send(request, response, config, 200, { status: 'ok' }, { noStore: true });
      return;
    }
    if (request.method === 'GET' && routePath === '/v1/catalog' && !url.search) {
      send(request, response, config, 200, catalogResponse, { noStore: true });
      return;
    }
    if (request.method !== 'POST' || routePath !== '/v1/checkout-session' || url.search) {
      send(request, response, config, 404, error(404, 'notFound', 'Rota não encontrada.').body, { noStore: true });
      return;
    }
    try {
      const input = validateCheckoutRequest(await readBody(request));
      if ('status' in input) {
        send(request, response, config, input.status, input.body, { noStore: true });
        return;
      }
      const path = '/v1/checkout-session';
      const payload = {
        externalId: `flutter-store-${input.cartId}`,
        currency: 'BRL',
        lineItems: input.items.map(({ sku: _sku, ...item }) => item),
        paymentMethodTypes: ['pix'],
        returnUrl: config.returnUrl,
        returnState: randomBytes(24).toString('base64url'),
        origin: config.merchantOrigin,
        platformFeeAmount: 0,
        metadata: { source: 'flutter-store-demo', cartId: input.cartId },
      };
      const rawBody = JSON.stringify(payload);
      const upstream = await requestJson(new URL(path, config.apiUrl), {
        method: 'POST',
        headers: signedHeaders(config, 'POST', path, rawBody),
        body: rawBody,
      });
      if (upstream.status < 200 || upstream.status >= 300) {
        send(request, response, config, upstream.status, upstream.body, { noStore: true });
        return;
      }
      if (upstream.body.amountTotal !== input.amountTotal) {
        throw new Error('upstream total mismatch');
      }
      send(request, response, config, upstream.status, {
        sessionId: upstream.body.id,
        checkoutUrl: upstream.body.checkoutUrl,
        clientSecret: upstream.body.clientSecret,
        expiresAt: upstream.body.expiresAt,
        returnState: upstream.body.returnState,
        order: {
          id: payload.externalId,
          currency: 'BRL',
          amountTotal: input.amountTotal,
          lineItems: input.items,
        },
      }, { noStore: true });
    } catch (reason) {
      const tooLarge = reason instanceof Error && reason.message === 'requestTooLarge';
      const invalidJson = reason instanceof Error && reason.message === 'invalidJson';
      const status = tooLarge ? 413 : invalidJson ? 400 : 502;
      const code = tooLarge ? 'requestTooLarge' : invalidJson ? 'invalidJson' : 'checkoutUnavailable';
      const message = tooLarge
        ? 'O carrinho excede o limite permitido.'
        : invalidJson
          ? 'O corpo da solicitação é inválido.'
          : 'Não foi possível criar o pagamento agora.';
      send(request, response, config, status, error(status, code, message).body, { noStore: true });
    }
  });
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  const server = await createMerchantServer();
  const port = Number.parseInt(process.env.PORT ?? '8787', 10);
  const host = process.env.HOST?.trim() || '127.0.0.1';
  server.listen(port, host, () => {
    console.log(`Noria test merchant listening on ${host}:${port}`);
  });
}
