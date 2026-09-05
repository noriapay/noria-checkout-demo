# Noria Checkout demo store

This example reproduces a real purchase: it loads a server-owned catalog,
supports multiple products and quantities, builds a cart and opens the hosted
Noria Checkout. The app sends only `sku`, `quantity`, `cartId` and the catalog
version. The test merchant recalculates every price before signing the Checkout
session request.

Start the merchant backend with a development project that has
`checkout-session:write`:

```bash
cd merchant_server
NORIA_API_URL=https://api.development.noriapay.com.br \
NORIA_PROJECT_ID=your-project-id \
NORIA_WORKSPACE_ID=your-workspace-id \
NORIA_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem \
NORIA_MERCHANT_ORIGIN=https://your-registered-origin.example \
NORIA_MERCHANT_RETURN_URL=https://your-registered-origin.example/checkout/return \
STORE_BASE_PATH=/demo-merchant \
node server.mjs
```

The private key belongs only in this backend process. Never commit it, serve it
to the app or put it in a Dart define.

## Which URLs to register in Marketplace

The Checkout profile accepts two different values. They must exactly match the
`origin` and `returnUrl` sent by the merchant backend when it creates a session:

- **Allowed origin:** the public HTTPS origin of the merchant product, with
  scheme and host only and no path. For Web, use a value such as
  `https://store.example.com`. For Flutter, use a stable public HTTPS domain
  that represents the app, such as `https://app.example.com`.
- **HTTPS return URL:** the complete URL that receives the buyer after the
  hosted Checkout. For Web, this can be
  `https://store.example.com/payment/return`. For Flutter, use a verified
  Android App Link / iOS Universal Link such as
  `https://app.example.com/noria/checkout/return`.

Do not register a Noria dashboard URL for a customer's integration. The
dashboard URLs are used only by Noria's own internal demo.

Then run the Flutter app:

```bash
flutter run -d chrome \
  --dart-define=NORIA_DEMO_MERCHANT_API=http://127.0.0.1:8787/demo-merchant \
  --dart-define=NORIA_CHECKOUT_ORIGIN=https://checkout.development.noriapay.com.br \
  --dart-define=NORIA_CHECKOUT_RETURN_URL=https://merchant.example/payment/return
```

For iOS Simulator use the same loopback address. The debug Android manifest and
iOS transport policy permit loopback HTTP only for local development; remote
merchant endpoints must use HTTPS. The app verifies that the backend-confirmed
SKUs, quantities, unit values and total are exactly equal to the visible cart
before opening Checkout.

The SDK is consumed from `noriapay/noria-checkout-flutter`; this repository is
only the merchant-side reference application and local demonstration backend.
