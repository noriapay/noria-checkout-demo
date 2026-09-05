import 'dart:math';

import 'package:flutter/material.dart';
import 'package:noria_checkout/noria_checkout.dart';
import 'package:noria_checkout_demo/store_api.dart';

const String _merchantApi = String.fromEnvironment('NORIA_DEMO_MERCHANT_API');
const String _checkoutOrigin = String.fromEnvironment('NORIA_CHECKOUT_ORIGIN');
const String _returnUrl = String.fromEnvironment('NORIA_CHECKOUT_RETURN_URL');

void main() {
  runApp(const NoriaCheckoutExample());
}

class NoriaCheckoutExample extends StatelessWidget {
  const NoriaCheckoutExample({
    this.backend,
    this.checkoutController,
    this.checkoutOrigin,
    this.returnUrl,
    super.key,
  });

  final StoreBackend? backend;
  final NoriaCheckoutController? checkoutController;
  final Uri? checkoutOrigin;
  final Uri? returnUrl;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Noria Objects',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF3F3F5),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF151517),
          brightness: Brightness.light,
          surface: Colors.white,
        ),
        textTheme: Theme.of(context).textTheme.apply(
          bodyColor: const Color(0xFF1D1D1F),
          displayColor: const Color(0xFF1D1D1F),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF151517),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFFE2E2E6),
            disabledForegroundColor: const Color(0xFF8A8A8E),
            minimumSize: const Size.fromHeight(58),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
      home: _StorefrontPage(
        backend: backend ?? HttpStoreBackend(baseUrl: _merchantApi),
        checkoutController: checkoutController,
        checkoutOrigin: checkoutOrigin,
        returnUrl: returnUrl,
      ),
    );
  }
}

class _StorefrontPage extends StatefulWidget {
  const _StorefrontPage({
    required this.backend,
    this.checkoutController,
    this.checkoutOrigin,
    this.returnUrl,
  });

  final StoreBackend backend;
  final NoriaCheckoutController? checkoutController;
  final Uri? checkoutOrigin;
  final Uri? returnUrl;

  @override
  State<_StorefrontPage> createState() => _StorefrontPageState();
}

class _StorefrontPageState extends State<_StorefrontPage> {
  final Random _random = Random.secure();
  final Map<String, int> _quantities = <String, int>{};

  StoreCatalog? _catalog;
  String? _loadError;
  String _status = 'Pagamento protegido pela Noria';
  late String _cartId;
  bool _loading = true;
  bool _showCart = false;
  bool _paid = false;

  Uri get _expectedCheckoutOrigin =>
      widget.checkoutOrigin ?? Uri.tryParse(_checkoutOrigin) ?? Uri();

  Uri get _expectedReturnUrl =>
      widget.returnUrl ?? Uri.tryParse(_returnUrl) ?? Uri();

  @override
  void initState() {
    super.initState();
    _cartId = _newCartId();
    _loadCatalog();
  }

  String _newCartId() {
    const String alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List<String>.generate(
      24,
      (_) => alphabet[_random.nextInt(alphabet.length)],
      growable: false,
    ).join();
  }

  Future<void> _loadCatalog() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final StoreCatalog catalog = await widget.backend.loadCatalog();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  List<StoreCartItem> get _cartItems {
    final StoreCatalog? catalog = _catalog;
    if (catalog == null) return const <StoreCartItem>[];
    return catalog.products
        .where((StoreProduct product) => (_quantities[product.sku] ?? 0) > 0)
        .map(
          (StoreProduct product) => StoreCartItem(
            product: product,
            quantity: _quantities[product.sku]!,
          ),
        )
        .toList(growable: false);
  }

  int get _itemCount => _quantities.values.fold<int>(
    0,
    (int total, int quantity) => total + quantity,
  );

  int get _amountTotal => _cartItems.fold<int>(
    0,
    (int total, StoreCartItem item) => total + item.amount,
  );

  bool get _checkoutReady =>
      _cartItems.isNotEmpty &&
      widget.backend.isConfigured &&
      _expectedCheckoutOrigin.host.isNotEmpty &&
      _expectedReturnUrl.host.isNotEmpty;

  void _setQuantity(StoreProduct product, int quantity) {
    final int bounded = quantity.clamp(0, 10);
    setState(() {
      if (bounded == 0) {
        _quantities.remove(product.sku);
      } else {
        _quantities[product.sku] = bounded;
      }
      _cartId = _newCartId();
      _paid = false;
      _status = 'Pagamento protegido pela Noria';
      if (_quantities.isEmpty) _showCart = false;
    });
  }

  Future<NoriaCheckoutSession> _createSession() async {
    final StoreCatalog? catalog = _catalog;
    final List<StoreCartItem> items = _cartItems;
    if (catalog == null || items.isEmpty) {
      throw const StoreApiException('O carrinho está vazio.');
    }
    setState(() => _status = 'Confirmando seu carrinho…');
    return widget.backend.createSession(
      cartId: _cartId,
      catalog: catalog,
      items: items,
    );
  }

  void _onComplete(NoriaCheckoutResult result) {
    if (!mounted) return;
    setState(() {
      _paid = true;
      _status = 'Pagamento confirmado';
    });
  }

  void _onError(Object error) {
    if (!mounted) return;
    setState(() => _status = 'Não foi possível abrir o Checkout');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(error.toString()),
      ),
    );
  }

  void _newOrder() {
    setState(() {
      _quantities.clear();
      _cartId = _newCartId();
      _paid = false;
      _showCart = false;
      _status = 'Pagamento protegido pela Noria';
    });
  }

  void _leaveCart() {
    if (_paid) {
      _newOrder();
      return;
    }
    setState(() => _showCart = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          child: _showCart ? _buildCart() : _buildCatalog(),
        ),
      ),
      bottomNavigationBar: !_showCart && _itemCount > 0
          ? SafeArea(
              minimum: const EdgeInsets.fromLTRB(18, 8, 18, 14),
              child: _CartBar(
                itemCount: _itemCount,
                amount: _amountTotal,
                onPressed: () => setState(() => _showCart = true),
              ),
            )
          : null,
    );
  }

  Widget _buildCatalog() {
    return CustomScrollView(
      key: const ValueKey<String>('catalog'),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
            child: _StoreHeader(
              itemCount: _itemCount,
              onCartPressed: _itemCount == 0
                  ? null
                  : () => setState(() => _showCart = true),
            ),
          ),
        ),
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(22, 42, 22, 24),
            child: _CatalogIntro(),
          ),
        ),
        if (_loading)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (_loadError != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _LoadError(message: _loadError!, onRetry: _loadCatalog),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
            sliver: SliverLayoutBuilder(
              builder: (BuildContext context, constraints) {
                final int columns = constraints.crossAxisExtent >= 900
                    ? 4
                    : constraints.crossAxisExtent >= 620
                    ? 3
                    : 2;
                return SliverGrid.builder(
                  itemCount: _catalog!.products.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    mainAxisExtent: columns == 2 ? 354 : 374,
                  ),
                  itemBuilder: (BuildContext context, int index) {
                    final StoreProduct product = _catalog!.products[index];
                    final int quantity = _quantities[product.sku] ?? 0;
                    return _ProductCard(
                      product: product,
                      quantity: quantity,
                      onAdd: () => _setQuantity(product, quantity + 1),
                      onRemove: () => _setQuantity(product, quantity - 1),
                    );
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildCart() {
    final List<StoreCartItem> items = _cartItems;
    return CustomScrollView(
      key: const ValueKey<String>('cart'),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
            child: Row(
              children: <Widget>[
                _RoundButton(
                  icon: Icons.arrow_back_rounded,
                  label: 'Voltar à loja',
                  onPressed: _leaveCart,
                ),
                const Spacer(),
                if (!_paid)
                  Text(
                    '${_itemCount.toString()} ${_itemCount == 1 ? 'item' : 'itens'}',
                    style: const TextStyle(
                      color: Color(0xFF6E6E73),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
          sliver: SliverToBoxAdapter(
            child: Text(
              _paid ? 'Tudo certo.' : 'Seu carrinho.',
              style: const TextStyle(
                fontSize: 42,
                height: 0.98,
                fontWeight: FontWeight.w800,
                letterSpacing: -2.1,
              ),
            ),
          ),
        ),
        if (_paid)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
            sliver: SliverToBoxAdapter(
              child: _PaidCard(amount: _amountTotal, onNewOrder: _newOrder),
            ),
          )
        else ...<Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
            sliver: SliverList.separated(
              itemCount: items.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(height: 10),
              itemBuilder: (BuildContext context, int index) {
                final StoreCartItem item = items[index];
                return _CartLineCard(
                  item: item,
                  onAdd: () => _setQuantity(item.product, item.quantity + 1),
                  onRemove: () => _setQuantity(item.product, item.quantity - 1),
                );
              },
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
            sliver: SliverToBoxAdapter(
              child: _CheckoutSummary(
                amount: _amountTotal,
                status: _status,
                enabled: _checkoutReady,
                createSession: _createSession,
                checkoutOrigin: _expectedCheckoutOrigin,
                returnUrl: _expectedReturnUrl,
                checkoutController: widget.checkoutController,
                onComplete: _onComplete,
                onError: _onError,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StoreHeader extends StatelessWidget {
  const _StoreHeader({required this.itemCount, required this.onCartPressed});

  final int itemCount;
  final VoidCallback? onCartPressed;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Image.asset(
          'assets/images/noria-wordmark.png',
          package: 'noria_checkout',
          width: 62,
          fit: BoxFit.contain,
          color: const Color(0xFF1D1D1F),
          colorBlendMode: BlendMode.srcIn,
        ),
        const SizedBox(width: 7),
        const Text(
          'objects',
          style: TextStyle(
            color: Color(0xFF6E6E73),
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
          ),
        ),
        const Spacer(),
        _RoundButton(
          icon: Icons.shopping_bag_outlined,
          label: itemCount == 0 ? 'Carrinho vazio' : 'Abrir carrinho',
          badge: itemCount,
          onPressed: onCartPressed,
        ),
      ],
    );
  }
}

class _CatalogIntro extends StatelessWidget {
  const _CatalogIntro();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Pequenos objetos.\nGrandes detalhes.',
          style: TextStyle(
            fontSize: 39,
            height: 0.99,
            fontWeight: FontWeight.w800,
            letterSpacing: -2,
          ),
        ),
        SizedBox(height: 14),
        Text(
          'Monte seu carrinho e teste o Checkout como seu cliente usaria.',
          style: TextStyle(
            color: Color(0xFF6E6E73),
            fontSize: 16,
            height: 1.35,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({
    required this.product,
    required this.quantity,
    required this.onAdd,
    required this.onRemove,
  });

  final StoreProduct product;
  final int quantity;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '${product.name}, ${money(product.unitAmount)}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(27),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(19),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _ProductImage(
                    artwork: product.artwork,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.05,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.35,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                product.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF77777C),
                  fontSize: 12,
                  height: 1.25,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                money(product.unitAmount),
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.25,
                ),
              ),
              const SizedBox(height: 10),
              if (quantity == 0)
                Align(
                  alignment: Alignment.centerRight,
                  child: _CircleAction(
                    icon: Icons.add_rounded,
                    label: 'Adicionar ${product.name}',
                    onPressed: onAdd,
                  ),
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: _CompactQuantity(
                    quantity: quantity,
                    onAdd: onAdd,
                    onRemove: onRemove,
                    expanded: true,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductImage extends StatelessWidget {
  const _ProductImage({required this.artwork, required this.fit});

  final String artwork;
  final BoxFit fit;

  String get asset => switch (artwork) {
    'headphones' => 'assets/products/halo-headphones.jpg',
    'lamp' => 'assets/products/lume-mini.jpg',
    'charger' => 'assets/products/orbit-charger.jpg',
    _ => 'assets/products/arc-speaker.jpg',
  };

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      fit: fit,
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
    );
  }
}

class _CartBar extends StatelessWidget {
  const _CartBar({
    required this.itemCount,
    required this.amount,
    required this.onPressed,
  });

  final int itemCount;
  final int amount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(62),
        padding: const EdgeInsets.symmetric(horizontal: 20),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFF343438),
              shape: BoxShape.circle,
            ),
            child: Text(
              itemCount.toString(),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Ver carrinho',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          Text(money(amount)),
        ],
      ),
    );
  }
}

class _CartLineCard extends StatelessWidget {
  const _CartLineCard({
    required this.item,
    required this.onAdd,
    required this.onRemove,
  });

  final StoreCartItem item;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(23),
      ),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(17),
            child: SizedBox(
              width: 76,
              height: 76,
              child: _ProductImage(
                artwork: item.product.artwork,
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  money(item.amount),
                  style: const TextStyle(
                    color: Color(0xFF6E6E73),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          _CompactQuantity(
            quantity: item.quantity,
            onAdd: onAdd,
            onRemove: onRemove,
          ),
        ],
      ),
    );
  }
}

class _CheckoutSummary extends StatelessWidget {
  const _CheckoutSummary({
    required this.amount,
    required this.status,
    required this.enabled,
    required this.createSession,
    required this.checkoutOrigin,
    required this.returnUrl,
    required this.checkoutController,
    required this.onComplete,
    required this.onError,
  });

  final int amount;
  final String status;
  final bool enabled;
  final NoriaCreateSession createSession;
  final Uri checkoutOrigin;
  final Uri returnUrl;
  final NoriaCheckoutController? checkoutController;
  final NoriaCheckoutCallback onComplete;
  final ValueChanged<Object> onError;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(27),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _SummaryLine(label: 'Entrega', value: 'Grátis'),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Divider(height: 1, color: Color(0xFFE8E8EC)),
          ),
          _SummaryLine(label: 'Total', value: money(amount), strong: true),
          const SizedBox(height: 24),
          Row(
            children: <Widget>[
              const Icon(Icons.lock_outline_rounded, size: 16),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  status,
                  style: const TextStyle(
                    color: Color(0xFF6E6E73),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          NoriaCheckoutButton(
            enabled: enabled,
            controller: checkoutController,
            createSession: createSession,
            expectedCheckoutOrigin: checkoutOrigin,
            returnUrl: returnUrl,
            onComplete: onComplete,
            onError: onError,
            child: const NoriaCheckoutButtonLabel(),
          ),
          if (!enabled) ...<Widget>[
            const SizedBox(height: 11),
            const Text(
              'Configure o backend merchant para testar o pagamento.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF8A8A8E),
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 13),
          const Text(
            'Os preços são recalculados no servidor. Nenhuma chave privada fica no app.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF8A8A8E),
              fontSize: 11,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _PaidCard extends StatelessWidget {
  const _PaidCard({required this.amount, required this.onNewOrder});

  final int amount;
  final VoidCallback onNewOrder;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFFDDF6E8),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              color: Color(0xFF153D28),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_rounded, color: Colors.white),
          ),
          const SizedBox(height: 26),
          const Text(
            'Pagamento confirmado',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${money(amount)} recebidos. A confirmação veio do estado financeiro da sessão.',
            style: const TextStyle(
              color: Color(0xFF42604D),
              fontSize: 14,
              height: 1.4,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: onNewOrder,
            child: const Text('Fazer nova compra'),
          ),
        ],
      ),
    );
  }
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine({
    required this.label,
    required this.value,
    this.strong = false,
  });

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = TextStyle(
      color: strong ? const Color(0xFF1D1D1F) : const Color(0xFF6E6E73),
      fontSize: strong ? 20 : 14,
      fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
      letterSpacing: strong ? -0.6 : -0.1,
    );
    return Row(
      children: <Widget>[
        Expanded(child: Text(label, style: style)),
        Text(value, style: style),
      ],
    );
  }
}

class _CompactQuantity extends StatelessWidget {
  const _CompactQuantity({
    required this.quantity,
    required this.onAdd,
    required this.onRemove,
    this.expanded = false,
  });

  final int quantity;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F1F3),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          _QuantityButton(
            icon: quantity == 1 ? Icons.delete_outline_rounded : Icons.remove,
            label: quantity == 1 ? 'Remover item' : 'Diminuir quantidade',
            onPressed: onRemove,
          ),
          if (expanded)
            Expanded(child: _QuantityValue(quantity: quantity))
          else
            SizedBox(width: 27, child: _QuantityValue(quantity: quantity)),
          _QuantityButton(
            icon: Icons.add_rounded,
            label: 'Aumentar quantidade',
            onPressed: quantity >= 10 ? null : onAdd,
          ),
        ],
      ),
    );
  }
}

class _QuantityValue extends StatelessWidget {
  const _QuantityValue({required this.quantity});

  final int quantity;

  @override
  Widget build(BuildContext context) {
    return Text(
      quantity.toString(),
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
    );
  }
}

class _QuantityButton extends StatelessWidget {
  const _QuantityButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: label,
      constraints: const BoxConstraints.tightFor(width: 35, height: 35),
      padding: EdgeInsets.zero,
      iconSize: 17,
      icon: Icon(icon),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filled(
      onPressed: onPressed,
      tooltip: label,
      style: IconButton.styleFrom(
        backgroundColor: const Color(0xFF151517),
        foregroundColor: Colors.white,
        fixedSize: const Size.square(38),
      ),
      icon: Icon(icon, size: 20),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.badge = 0,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final int badge;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          IconButton(
            onPressed: onPressed,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF1D1D1F),
              fixedSize: const Size.square(43),
            ),
            icon: Icon(icon, size: 20),
          ),
          if (badge > 0)
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: const BoxDecoration(
                  color: Color(0xFF151517),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  badge.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(Icons.cloud_off_outlined, size: 34),
          const SizedBox(height: 16),
          const Text(
            'A loja não carregou',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF6E6E73), height: 1.4),
          ),
          const SizedBox(height: 22),
          FilledButton.tonal(
            onPressed: onRetry,
            child: const Text('Tentar novamente'),
          ),
        ],
      ),
    );
  }
}

String money(int amountMinor) {
  final String digits = amountMinor.abs().toString().padLeft(3, '0');
  final String reais = digits.substring(0, digits.length - 2);
  final String centavos = digits.substring(digits.length - 2);
  final StringBuffer grouped = StringBuffer();
  for (int index = 0; index < reais.length; index += 1) {
    if (index > 0 && (reais.length - index) % 3 == 0) grouped.write('.');
    grouped.write(reais[index]);
  }
  return '${amountMinor < 0 ? '-' : ''}R\$ $grouped,$centavos';
}
