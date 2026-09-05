import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noria_checkout_demo/store_api.dart';

const StoreProduct _product = StoreProduct(
  sku: 'ARC-SPEAKER-01',
  name: 'Arc Speaker',
  description: 'Som compacto.',
  unitAmount: 2490,
  artwork: 'speaker',
  accent: 'DCE9DF',
);

const StoreCatalog _catalog = StoreCatalog(
  version: 'catalog-v1',
  products: <StoreProduct>[_product],
);

Map<String, Object?> response({required int amountTotal}) => <String, Object?>{
      'sessionId': '11111111-1111-4111-8111-111111111111',
      'checkoutUrl':
          'https://checkout.development.noriapay.com.br/session/11111111-1111-4111-8111-111111111111',
      'clientSecret': 'secret-with-at-least-twenty-characters',
      'expiresAt': '2030-01-01T00:00:00Z',
      'returnState': 'state-with-at-least-sixteen-chars',
      'order': <String, Object?>{
        'currency': 'BRL',
        'amountTotal': amountTotal,
        'lineItems': <Object?>[
          <String, Object?>{
            'sku': _product.sku,
            'quantity': 2,
            'unitAmount': _product.unitAmount,
          },
        ],
      },
    };

void main() {
  test('sends only cart identity, catalog version, SKU and quantity', () async {
    late Map<String, Object?> requestBody;
    late Uri requestUrl;
    final HttpStoreBackend backend = HttpStoreBackend(
      baseUrl: 'https://merchant.example/demo-merchant',
      client: MockClient((http.Request request) async {
        requestUrl = request.url;
        requestBody = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response(jsonEncode(response(amountTotal: 4980)), 201);
      }),
    );

    await backend.createSession(
      cartId: 'cart-valid-1234567890',
      catalog: _catalog,
      items: const <StoreCartItem>[
        StoreCartItem(product: _product, quantity: 2),
      ],
    );

    expect(
      requestUrl,
      Uri.parse('https://merchant.example/demo-merchant/v1/checkout-session'),
    );
    expect(requestBody.keys, <String>{'cartId', 'catalogVersion', 'items'});
    final List<Object?> items = requestBody['items']! as List<Object?>;
    expect((items.single as Map<String, Object?>).keys, <String>{'sku', 'quantity'});
  });

  test('blocks the Checkout when the server total differs by one cent', () async {
    final HttpStoreBackend backend = HttpStoreBackend(
      baseUrl: 'https://merchant.example',
      client: MockClient(
        (_) async => http.Response(jsonEncode(response(amountTotal: 4979)), 201),
      ),
    );

    expect(
      () => backend.createSession(
        cartId: 'cart-valid-1234567890',
        catalog: _catalog,
        items: const <StoreCartItem>[
          StoreCartItem(product: _product, quantity: 2),
        ],
      ),
      throwsA(
        isA<StoreApiException>().having(
          (StoreApiException value) => value.message,
          'message',
          contains('não corresponde'),
        ),
      ),
    );
  });
}
