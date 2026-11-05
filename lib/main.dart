import 'package:arcon_core/arcon_core.dart';
import 'package:flutter/material.dart';

/// ARCONNECT — menü ve ekranlar ARCON sunucusundan gelir; webde açılan modül burada da görünür.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PushService.bindBackgroundHandler();
  runApp(const ArconApp(
    config: ArconAppConfig(
      appKey: 'arconnect',
      title: 'ARCONNECT',
      startModuleKey: 'arconnect',
      push: true,
    ),
  ));
}
