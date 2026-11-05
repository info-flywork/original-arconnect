import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter/widgets.dart';

import '../auth/session_controller.dart';
import '../config.dart';
import '../talk/talk_api.dart';
import 'incoming_callkit.dart';

/// Ekran kapalıyken WhatsApp benzeri tam ekran gelen arama.
@pragma('vm:entry-point')
Future<void> arconPushBackgroundHandler(RemoteMessage message) async {
  final type = message.data['type'];
  if (type != 'call' && type != 'call_end') return;
  WidgetsFlutterBinding.ensureInitialized();
  // arayan vazgeçti: çalan tam ekran aramayı kapat
  if (type == 'call_end') {
    final id = int.tryParse('${message.data['call_id'] ?? ''}') ?? 0;
    if (id > 0) await ArconCallkit.end(id);
    return;
  }
  try {
    await Firebase.initializeApp();
  } catch (_) {}
  final callId = int.tryParse('${message.data['call_id'] ?? ''}') ?? 0;
  final channelId = int.tryParse('${message.data['channel_id'] ?? ''}') ?? 0;
  if (callId <= 0) return;
  final name = (message.data['caller'] ?? message.data['title'] ?? message.notification?.title ?? 'ARCONNECT').toString();
  await ArconCallkit.showIncoming(
    callId: callId,
    channelId: channelId,
    callerName: name,
    video: message.data['video'] == '1',
  );
}

/// Push bildirimleri (Firebase Cloud Messaging).
///
/// Uygulama ayarında `push: true` olunca (ARCONNECT) ya da `--dart-define=ARCON_PUSH=true` ile açılır.
/// Firebase dosyaları (iOS: GoogleService-Info.plist, Android: google-services.json) yoksa
/// başlatma sessizce başarısız olur ve hiçbir şey yapmaz.
///
/// Uygulama açıkken bildirimi [LocalNotifier] gösterir (açık sohbeti atlar); push yalnızca
/// uygulama arka plandayken / kapalıyken görünür, böylece çift bildirim çıkmaz.
///
/// Bildirime dokununca: `type=talk` → ilgili ARCONNECT sohbeti açılır ([openTalkChannel]).
class PushService {
  PushService._();

  static const bool _forced = bool.fromEnvironment('ARCON_PUSH');
  static bool _enabled = _forced;

  /// Açılması bekleyen ARCONNECT kanalı (bildirime dokunuldu). TalkHomeScreen dinler.
  static final ValueNotifier<int?> openTalkChannel = ValueNotifier<int?>(null);

  /// Bildirimden gelen arama (call_id). TalkHomeScreen dinler.
  static final ValueNotifier<int?> openIncomingCallId = ValueNotifier<int?>(null);
  static bool incomingCallAccepted = false;

  /// Kanal açılması istendiğinde ARCONNECT ekranı açık değilse onu açar (Club'da).
  static void Function(int channelId)? onOpenTalk;

  static bool _started = false;
  static SessionController? _session;
  static TalkApi? _talk;
  static StreamSubscription<String>? _tokenSub;
  static Timer? _apnsRetry;

  /// `main()` içinde, `runApp` öncesi (yalnızca push açik uygulamalar).
  static void bindBackgroundHandler() {
    FirebaseMessaging.onBackgroundMessage(arconPushBackgroundHandler);
    ArconCallkit.listen();
  }

  /// Uygulama yeni uyanırken oturum hazır olmadan gelen "reddet"ler oturum açılınca gönderilir.
  static final Set<int> _pendingDeclines = {};

  /// CallKit'te (kilit ekranı) kırmızı düğmeyle kapatılan arama: açık arama ekranı da kapanır.
  static final ValueNotifier<int?> hangupRequested = ValueNotifier<int?>(null);

  static Future<void> declineIncoming(int callId) async {
    hangupRequested.value = callId;
    final talk = _talk;
    if (talk == null) {
      _pendingDeclines.add(callId);
      return;
    }
    try {
      await talk.callDecline(callId);
    } catch (_) {}
  }

  static String _appVersion = '';

  /// iPhone VoIP (PushKit) belirtecini sunucuya kaydeder: kilit ekranında tam ekran arama için.
  static Future<void> registerVoip() async {
    if (!Platform.isIOS) return;
    final s = _session;
    if (s == null || s.user == null) return;
    try {
      final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
      if (token == null || token.isEmpty) return;
      await s.api.registerDevice(platform: 'ios_voip', pushToken: token, appVersion: _appVersion);
    } catch (e) {
      debugPrint('[push] VoIP kaydı başarısız: $e');
    }
  }

  /// Oturum açıkken çağrılır; izin ister, cihazı sunucuya kaydeder, dokunmaları dinler.
  static Future<void> start(SessionController session, {bool enabled = false, String appVersion = '', String apiBase = ''}) async {
    _enabled = _forced || enabled;
    if (!_enabled) return;
    _session = session;
    _appVersion = appVersion;
    _talk = TalkApi(arcon: session.api, baseUrl: apiBase.isEmpty ? ArconAppConfig.defaultApiBase : apiBase);
    for (final id in _pendingDeclines.toList()) {
      _pendingDeclines.remove(id);
      unawaited(declineIncoming(id));
    }
    // kilit ekranında kabul edilip sonra açılan arama: hemen bağlan
    unawaited(ArconCallkit.acceptedCall().then((id) {
      if (id != null) requestOpenCall(id, accepted: true);
    }));
    unawaited(registerVoip());
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      final fm = FirebaseMessaging.instance;
      final perm = await fm.requestPermission(alert: true, badge: true, sound: true);
      if (perm.authorizationStatus == AuthorizationStatus.denied) return;
      // Uygulama açıkken bildirimi LocalNotifier gösteriyor; iOS push'u ayrıca göstermesin
      await fm.setForegroundNotificationPresentationOptions(alert: false, badge: true, sound: false);

      await _tokenSub?.cancel();
      _tokenSub = fm.onTokenRefresh.listen((t) => _register(t, appVersion));
      await _takeFcmToken(fm, appVersion);

      ArconCallkit.listen();
      unawaited(ArconCallkit.requestAndroidLockScreen());

      if (!_started) {
        _started = true;
        FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);
        final initial = await fm.getInitialMessage();
        if (initial != null) _handleTap(initial);
      }
    } catch (e) {
      debugPrint('[push] başlatılamadı: $e');
    }
  }

  /// Çıkışta: bu cihaz artık bildirim almasın (sunucudaki token zaten iptal edilir).
  static Future<void> _takeFcmToken(FirebaseMessaging fm, String appVersion) async {
    if (Platform.isIOS) {
      String? apns;
      for (var i = 0; i < 15; i++) {
        apns = await fm.getAPNSToken();
        if (apns != null && apns.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (apns == null || apns.isEmpty) {
        _apnsRetry?.cancel();
        _apnsRetry = Timer.periodic(const Duration(seconds: 4), (t) async {
          try {
            final later = await fm.getAPNSToken();
            if (later == null || later.isEmpty) return;
            t.cancel();
            final token = await fm.getToken();
            if (token != null) await _register(token, appVersion);
          } catch (e) {
            debugPrint('[push] FCM token: $e');
          }
        });
        return;
      }
    }
    try {
      final token = await fm.getToken();
      if (token != null) await _register(token, appVersion);
    } catch (e) {
      debugPrint('[push] FCM token: $e');
    }
  }

  static Future<void> stop() async {
    if (!_enabled) return;
    _apnsRetry?.cancel();
    _apnsRetry = null;
    await _tokenSub?.cancel();
    _tokenSub = null;
    try {
      if (Firebase.apps.isNotEmpty) await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }

  static Future<void> _register(String token, String appVersion) async {
    final s = _session;
    if (s == null || s.user == null) return;
    try {
      await s.api.registerDevice(
        platform: Platform.isIOS ? 'ios' : 'android',
        pushToken: token,
        appVersion: appVersion,
      );
    } catch (e) {
      debugPrint('[push] cihaz kaydı başarısız: $e');
    }
  }

  static void _handleTap(RemoteMessage m) {
    if (m.data['type'] == 'call') {
      final id = int.tryParse('${m.data['call_id'] ?? ''}');
      if (id != null && id > 0) requestOpenCall(id);
      final ch = int.tryParse('${m.data['channel_id'] ?? ''}');
      if (ch != null && ch > 0) requestOpenTalk(ch);
      return;
    }
    if (m.data['type'] == 'talk') {
      final id = int.tryParse('${m.data['channel_id'] ?? ''}');
      if (id != null && id > 0) requestOpenTalk(id);
    }
  }

  static void handleNotificationPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    if (payload.startsWith('call:')) {
      final parts = payload.split(':');
      final callId = parts.length > 1 ? int.tryParse(parts[1]) : null;
      final ch = parts.length > 2 ? int.tryParse(parts[2]) : null;
      if (callId != null && callId > 0) requestOpenCall(callId);
      if (ch != null && ch > 0) requestOpenTalk(ch);
      return;
    }
    final id = int.tryParse(payload);
    if (id != null && id > 0) requestOpenTalk(id);
  }

  /// Bildirim dokunması (veya test) → ARCONNECT kanalını aç.
  static void requestOpenTalk(int channelId) {
    openTalkChannel.value = channelId;
    onOpenTalk?.call(channelId);
  }

  static void requestOpenCall(int callId, {bool accepted = false}) {
    incomingCallAccepted = accepted;
    openIncomingCallId.value = callId;
  }
}
