import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noria_checkout/noria_checkout.dart';
import 'package:noria_checkout_demo/main.dart';
import 'package:noria_checkout_demo/store_api.dart';

const StoreCatalog _catalog = StoreCatalog(
  version: 'catalog-v1',
  products: <StoreProduct>[
    StoreProduct(
      sku: 'ARC-SPEAKER-01',
      name: 'Arc Speaker',
      description: 'Som compacto.',
      unitAmount: 2490,
      artwork: 'speaker',
      accent: 'DCE9DF',
    ),
    StoreProduct(
      sku: 'ORBIT-CHARGER-01',
      name: 'Orbit Charger',
      description: 'Energia sem cabos.',
      unitAmount: 1290,
      artwork: 'charger',
      accent: 'DDE8F1',
    ),
  ],
);

class _FakeBackend implements StoreBackend {
  _FakeBackend({this.session});

  final NoriaCheckoutSession? session;

  @override
  bool get isConfigured => true;

  @override
  Future<StoreCatalog> loadCatalog() async => _catalog;

  @override
  Future<NoriaCheckoutSession> createSession({
    required String cartId,
    required StoreCatalog catalog,
    required List<StoreCartItem> items,
  }) async {
    return session ?? (throw UnimplementedError());
  }
}

class _CompletingController extends NoriaCheckoutController {
  @override
  Future<NoriaCheckoutResult?> open({
    required NoriaCheckoutSession session,
    required Uri expectedCheckoutOrigin,
    required Uri returnUrl,
    NoriaCheckoutPresentation presentation =
        NoriaCheckoutPresentation.inAppBrowser,
    VoidCallback? onOpened,
  }) async {
    onOpened?.call();
    return NoriaCheckoutResult(sessionId: session.sessionId);
  }
}

NoriaCheckoutSession _checkoutSession() => NoriaCheckoutSession(
  sessionId: '11111111-1111-4111-8111-111111111111',
  checkoutUrl:
      'https://checkout.development.noriapay.com.br/session/11111111-1111-4111-8111-111111111111',
  clientSecret: 'secret-with-at-least-twenty-characters',
  expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
  returnState: 'state-with-enough-entropy',
);

void main() {
  test('formats BRL from integer cents', () {
    expect(money(0), 'R\$ 0,00');
    expect(money(500), 'R\$ 5,00');
    expect(money(6270), 'R\$ 62,70');
    expect(money(123456789), 'R\$ 1.234.567,89');
  });

  testWidgets('builds a real multi-product cart with exact totals', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(NoriaCheckoutExample(backend: _FakeBackend()));
    await tester.pumpAndSettle();

    expect(find.text('Arc Speaker'), findsOneWidget);
    expect(find.text('Orbit Charger'), findsOneWidget);
    expect(find.text('R\$ 24,90'), findsOneWidget);
    expect(find.text('R\$ 12,90'), findsOneWidget);

    await tester.tap(find.byTooltip('Adicionar Arc Speaker'));
    await tester.pumpAndSettle();
    expect(find.text('Ver carrinho'), findsOneWidget);
    expect(find.text('R\$ 24,90'), findsNWidgets(2));

    await tester.scrollUntilVisible(
      find.byTooltip('Adicionar Orbit Charger'),
      200,
    );
    await tester.tap(find.byTooltip('Adicionar Orbit Charger'));
    await tester.pumpAndSettle();
    expect(find.text('R\$ 37,80'), findsOneWidget);

    await tester.tap(find.text('Ver carrinho'));
    await tester.pumpAndSettle();
    expect(find.text('Seu carrinho.'), findsOneWidget);
    expect(find.text('Arc Speaker'), findsOneWidget);
    expect(find.text('Orbit Charger'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.text('R\$ 37,80'), findsOneWidget);
    expect(find.text('Pagar com a '), findsOneWidget);
    final Iterable<String> assetNames = tester
        .widgetList<Image>(find.byType(Image))
        .map((Image image) => image.image)
        .whereType<AssetImage>()
        .map((AssetImage image) => image.assetName);
    expect(assetNames, contains('assets/products/arc-speaker.jpg'));
    expect(assetNames, contains('assets/products/orbit-charger.jpg'));
    expect(assetNames, contains('assets/images/noria-wordmark.png'));
  });

  testWidgets('back after a completed payment starts an empty cart', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      NoriaCheckoutExample(
        backend: _FakeBackend(session: _checkoutSession()),
        checkoutController: _CompletingController(),
        checkoutOrigin: Uri.parse(
          'https://checkout.development.noriapay.com.br',
        ),
        returnUrl: Uri.parse('https://shop.example/payment/return'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Adicionar Arc Speaker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ver carrinho'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Abrir Noria Checkout'));
    await tester.pumpAndSettle();

    expect(find.text('Pagamento confirmado'), findsOneWidget);
    expect(find.text('Tudo certo.'), findsOneWidget);
    expect(find.text('1 item'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Voltar à loja'));
    await tester.pumpAndSettle();

    expect(find.text('Pequenos objetos.\nGrandes detalhes.'), findsOneWidget);
    expect(find.text('Ver carrinho'), findsNothing);
    expect(find.bySemanticsLabel('Carrinho vazio'), findsOneWidget);
  });
}
