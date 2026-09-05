import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:noria_checkout/noria_checkout.dart';

class StoreProduct {
  const StoreProduct({
    required this.sku,
    required this.name,
    required this.description,
    required this.unitAmount,
    required this.artwork,
    required this.accent,
  });

  factory StoreProduct.fromJson(Map<String, Object?> json) {
    final String sku = _requiredString(json, 'sku', maxLength: 64);
    final String name = _requiredString(json, 'name', maxLength: 80);
    final String description = _requiredString(
      json,
      'description',
      maxLength: 160,
    );
    final int unitAmount = _requiredInt(
      json,
      'unitAmount',
      minimum: 1,
      maximum: 100000000,
    );
    final String artwork = _requiredString(json, 'artwork', maxLength: 24);
    final String accent = _requiredString(json, 'accent', maxLength: 6);
    if (!RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(accent)) {
      throw const StoreApiException('O catálogo retornou uma cor inválida.');
    }
    return StoreProduct(
      sku: sku,
      name: name,
      description: description,
      unitAmount: unitAmount,
      artwork: artwork,
      accent: accent.toUpperCase(),
    );
  }

  final String sku;
  final String name;
  final String description;
  final int unitAmount;
  final String artwork;
  final String accent;
}

class StoreCatalog {
  const StoreCatalog({required this.version, required this.products});

  factory StoreCatalog.fromJson(Map<String, Object?> json) {
    final String version = _requiredString(json, 'version', maxLength: 128);
    final Object? rawProducts = json['products'];
    if (rawProducts is! List<Object?> ||
        rawProducts.isEmpty ||
        rawProducts.length > 50) {
      throw const StoreApiException('O catálogo retornado é inválido.');
    }
    final List<StoreProduct> products = rawProducts.map((Object? value) {
      if (value is! Map<String, Object?>) {
        throw const StoreApiException('O catálogo retornado é inválido.');
      }
      return StoreProduct.fromJson(value);
    }).toList(growable: false);
    if (products.map((StoreProduct value) => value.sku).toSet().length !=
        products.length) {
      throw const StoreApiException('O catálogo contém produtos duplicados.');
    }
    return StoreCatalog(version: version, products: products);
  }

  final String version;
  final List<StoreProduct> products;
}

class StoreCartItem {
  const StoreCartItem({required this.product, required this.quantity});

  final StoreProduct product;
  final int quantity;

  int get amount => product.unitAmount * quantity;
}

abstract interface class StoreBackend {
  bool get isConfigured;

  Future<StoreCatalog> loadCatalog();

  Future<NoriaCheckoutSession> createSession({
    required String cartId,
    required StoreCatalog catalog,
    required List<StoreCartItem> items,
  });
}

class HttpStoreBackend implements StoreBackend {
  HttpStoreBackend({
    required String baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  })  : _baseUrl = baseUrl.trim(),
        _client = client ?? http.Client();

  final String _baseUrl;
  final http.Client _client;
  final Duration timeout;

  @override
  bool get isConfigured => _baseUrl.isNotEmpty;

  Uri _endpoint(String path) {
    if (!isConfigured) {
      throw const StoreApiException(
        'Configure NORIA_DEMO_MERCHANT_API para abrir a loja de teste.',
      );
    }
    final Uri base = Uri.parse(_baseUrl);
    final bool localHttp = base.scheme == 'http' &&
        (base.host == 'localhost' || base.host == '127.0.0.1');
    final bool valid = (base.scheme == 'https' || localHttp) &&
        base.userInfo.isEmpty &&
        RegExp(r'^(/[A-Za-z0-9_-]+)*/?$').hasMatch(base.path) &&
        base.query.isEmpty &&
        base.fragment.isEmpty;
    if (!valid) {
      throw const StoreApiException('Endpoint da loja de teste inseguro.');
    }
    final String prefix = base.path == '/'
        ? ''
        : base.path.endsWith('/')
            ? base.path.substring(0, base.path.length - 1)
            : base.path;
    return base.replace(path: '$prefix$path');
  }

  @override
  Future<StoreCatalog> loadCatalog() async {
    final http.Response response = await _client
        .get(
          _endpoint('/v1/catalog'),
          headers: const <String, String>{
            'Accept': 'application/json',
            'Cache-Control': 'no-store',
          },
        )
        .timeout(timeout);
    final Map<String, Object?> body = _decodeObject(response);
    if (response.statusCode != 200) {
      throw StoreApiException(_errorMessage(body, response.statusCode));
    }
    return StoreCatalog.fromJson(body);
  }

  @override
  Future<NoriaCheckoutSession> createSession({
    required String cartId,
    required StoreCatalog catalog,
    required List<StoreCartItem> items,
  }) async {
    if (items.isEmpty) {
      throw const StoreApiException('O carrinho está vazio.');
    }
    final int expectedTotal = items.fold<int>(
      0,
      (int total, StoreCartItem item) => total + item.amount,
    );
    final http.Response response = await _client
        .post(
          _endpoint('/v1/checkout-session'),
          headers: const <String, String>{
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Cache-Control': 'no-store',
          },
          body: jsonEncode(<String, Object>{
            'cartId': cartId,
            'catalogVersion': catalog.version,
            'items': items
                .map(
                  (StoreCartItem item) => <String, Object>{
                    'sku': item.product.sku,
                    'quantity': item.quantity,
                  },
                )
                .toList(growable: false),
          }),
        )
        .timeout(timeout);
    final Map<String, Object?> body = _decodeObject(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StoreApiException(_errorMessage(body, response.statusCode));
    }
    final Object? orderValue = body['order'];
    if (orderValue is! Map<String, Object?> ||
        orderValue['currency'] != 'BRL' ||
        orderValue['amountTotal'] != expectedTotal) {
      throw const StoreApiException(
        'O total confirmado pelo servidor não corresponde ao carrinho.',
      );
    }
    _validateServerItems(orderValue['lineItems'], items);
    return NoriaCheckoutSession.fromJson(body);
  }

  static void _validateServerItems(
    Object? rawItems,
    List<StoreCartItem> expectedItems,
  ) {
    if (rawItems is! List<Object?> || rawItems.length != expectedItems.length) {
      throw const StoreApiException(
        'Os itens confirmados pelo servidor não correspondem ao carrinho.',
      );
    }
    final Map<String, StoreCartItem> expected = <String, StoreCartItem>{
      for (final StoreCartItem item in expectedItems) item.product.sku: item,
    };
    for (final Object? rawItem in rawItems) {
      if (rawItem is! Map<String, Object?>) {
        throw const StoreApiException(
          'Os itens confirmados pelo servidor são inválidos.',
        );
      }
      final StoreCartItem? item = expected[rawItem['sku']];
      if (item == null ||
          rawItem['quantity'] != item.quantity ||
          rawItem['unitAmount'] != item.product.unitAmount) {
        throw const StoreApiException(
          'Os itens confirmados pelo servidor não correspondem ao carrinho.',
        );
      }
    }
  }

  static Map<String, Object?> _decodeObject(http.Response response) {
    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      // The generic error below intentionally avoids reflecting upstream HTML.
    }
    throw const StoreApiException('A loja retornou uma resposta inválida.');
  }

  static String _errorMessage(Map<String, Object?> body, int statusCode) {
    final Object? errors = body['errors'];
    if (errors is List<Object?> && errors.isNotEmpty) {
      final Object? first = errors.first;
      if (first is Map<String, Object?> && first['message'] is String) {
        return first['message'] as String;
      }
    }
    return 'Não foi possível concluir a solicitação ($statusCode).';
  }
}

class StoreApiException implements Exception {
  const StoreApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _requiredString(
  Map<String, Object?> json,
  String name, {
  required int maxLength,
}) {
  final Object? value = json[name];
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw const StoreApiException('O catálogo retornado é inválido.');
  }
  return value;
}

int _requiredInt(
  Map<String, Object?> json,
  String name, {
  required int minimum,
  required int maximum,
}) {
  final Object? value = json[name];
  if (value is! int || value < minimum || value > maximum) {
    throw const StoreApiException('O catálogo retornado é inválido.');
  }
  return value;
}
