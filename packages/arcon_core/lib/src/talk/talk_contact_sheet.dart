import 'package:flutter/material.dart';

import 'talk_models.dart';
import 'talk_theme.dart';
import 'talk_widgets.dart';

/// WhatsApp kişi bilgisi: fotoğraf, ad, mesaj / ses / görüntü.
Future<void> showTalkContactSheet({
  required BuildContext context,
  required TalkUser user,
  required String photoUrl,
  required VoidCallback onMessage,
  required VoidCallback onVoice,
  required VoidCallback onVideo,
}) {
  final c = TalkColors.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: c.dark ? const Color(0xFF111B21) : Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (ctx) {
      final sheet = TalkColors.of(ctx);
      final handle = sheet.dark ? const Color(0xFF3B4A54) : const Color(0xFFD1D7DB);
      final iconBg = sheet.dark ? const Color(0xFF2A3942) : const Color(0xFFF0F2F5);
      void run(VoidCallback action) {
        Navigator.pop(ctx);
        action();
      }

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: handle, borderRadius: BorderRadius.circular(99))),
            const SizedBox(height: 18),
            Align(alignment: Alignment.centerLeft, child: Text('Kişi bilgisi', style: talkText(16, FontWeight.w600, sheet.ink))),
            const SizedBox(height: 22),
            TalkAvatar.solid(name: user.displayName, photoUrl: photoUrl, size: 120, fontSize: 36, personIfEmpty: true),
            const SizedBox(height: 16),
            Text(user.displayName, textAlign: TextAlign.center, style: talkText(24, FontWeight.w600, sheet.ink)),
            if (user.username.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('@${user.username}', style: talkText(15, FontWeight.w400, sheet.muted)),
            ],
            if (user.department.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(user.department, style: talkText(13, FontWeight.w400, sheet.muted)),
            ],
            const SizedBox(height: 28),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _act(sheet, iconBg, Icons.chat_bubble_outline, 'Mesaj', () => run(onMessage)),
              _act(sheet, iconBg, Icons.call_outlined, 'Sesli', () => run(onVoice)),
              _act(sheet, iconBg, Icons.videocam_outlined, 'Görüntülü', () => run(onVideo)),
            ]),
            const SizedBox(height: 12),
          ]),
        ),
      );
    },
  );
}

Widget _act(TalkColors c, Color bg, IconData icon, String label, VoidCallback onTap) {
  return GestureDetector(
    onTap: onTap,
    child: Column(children: [
      Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Icon(icon, color: c.ink, size: 24),
      ),
      const SizedBox(height: 8),
      Text(label, style: talkText(13, FontWeight.w500, c.ink)),
    ]),
  );
}
