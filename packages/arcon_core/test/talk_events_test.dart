import 'package:arcon_core/src/talk/talk_contact_sheet.dart';
import 'package:arcon_core/src/talk/talk_events.dart';
import 'package:arcon_core/src/talk/talk_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('etkinlik mesajı yazılır ve geri okunur', () {
    final at = DateTime(2026, 11, 6, 15, 30);
    final body = talkEventBody('Proje toplantısı', at);
    expect(body, '📅 Proje toplantısı\n06.11.2026 15:30');
    final e = talkEventLine(body)!;
    expect(e.title, 'Proje toplantısı');
    expect(e.at, at);
    expect(e.callVideo, isNull);
    expect(talkEventWhen(at), '6 Kasım Cuma · 15:30');
  });

  test('planlı arama türü başlıktan anlaşılır; düz metin etkinlik değildir', () {
    final e = talkEventLine(talkEventBody(talkCallPlanTitle(video: true), DateTime(2026, 11, 7, 9)))!;
    expect(e.callVideo, isTrue);
    expect(talkEventLine('📅 toplantı yarın'), isNull);
    expect(talkEventLine('merhaba'), isNull);
  });

  Future<void> openSheet(WidgetTester t, {TalkMemberAdmin? admin, VoidCallback? onInfo}) async {
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showTalkContactSheet(
            context: ctx,
            user: const TalkUser(id: 7, username: 'emrah', displayName: 'Emrah Fly Work', department: 'Ui&Ux Designer'),
            photoUrl: '',
            onMessage: () {},
            onVoice: () {},
            onVideo: () {},
            onInfo: onInfo,
            admin: admin,
          ),
          child: const Text('aç'),
        ),
      ),
    ));
    await t.tap(find.text('aç'));
    await t.pumpAndSettle();
  }

  testWidgets('üye kartı: yönetici değilsem yalnızca Mesaj / Sesli / Görüntülü ve Bilgi', (t) async {
    await openSheet(t, onInfo: () {});
    for (final s in ['Emrah Fly Work', '@emrah', 'Ui&Ux Designer', 'Mesaj', 'Sesli', 'Görüntülü', 'Bilgi']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.text('Gruptan çıkar'), findsNothing);
    expect(find.text('Grup yöneticisi yap'), findsNothing);
  });

  testWidgets('üye kartı: yöneticiysem Grup yöneticisi yap ve Gruptan çıkar çalışır', (t) async {
    var promoted = false, removed = false;
    await openSheet(t, onInfo: () {}, admin: (isAdmin: false, onToggleAdmin: () => promoted = true, onRemove: () => removed = true));
    expect(find.text('Grup yöneticisi yap'), findsOneWidget);
    await t.tap(find.text('Grup yöneticisi yap'));
    await t.pumpAndSettle();
    expect(promoted, isTrue);

    await openSheet(t, admin: (isAdmin: true, onToggleAdmin: () {}, onRemove: () => removed = true));
    expect(find.text('Yöneticilikten çıkar'), findsOneWidget);
    await t.tap(find.text('Gruptan çıkar'));
    await t.pumpAndSettle();
    expect(removed, isTrue);
  });
}
