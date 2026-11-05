import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'talk_theme.dart';

/// WhatsApp "Etkinlik" / "Arama planla": sohbete düşen mesaj.
/// Sunucuda ayrı tablo yok; mesaj metni makinece okunur biçimde taşınır:
///   📅 Proje toplantısı
///   06.11.2026 15:00
/// Planlı arama başlığı "Sesli arama planlandı" / "Görüntülü arama planlandı" olur.
const _callTitles = {'Sesli arama planlandı': false, 'Görüntülü arama planlandı': true};

String talkEventBody(String title, DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '📅 ${title.trim()}\n${two(at.day)}.${two(at.month)}.${at.year} ${two(at.hour)}:${two(at.minute)}';
}

String talkCallPlanTitle({required bool video}) => video ? 'Görüntülü arama planlandı' : 'Sesli arama planlandı';

/// Mesaj bir etkinlikse başlık, zaman ve (planlı aramaysa) görüntülü mü; değilse null.
({String title, DateTime at, bool? callVideo})? talkEventLine(String body) {
  final m = RegExp(r'^📅 (.+)\n(\d{2})\.(\d{2})\.(\d{4}) (\d{2}):(\d{2})$').firstMatch(body.trim());
  if (m == null) return null;
  final at = DateTime(int.parse(m.group(4)!), int.parse(m.group(3)!), int.parse(m.group(2)!), int.parse(m.group(5)!), int.parse(m.group(6)!));
  final title = m.group(1)!.trim();
  return (title: title, at: at, callVideo: _callTitles[title]);
}

const _months = ['Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', 'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'];
const _days = ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar'];

/// "6 Kasım Perşembe · 15:00"
String talkEventWhen(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.day} ${_months[at.month - 1]} ${_days[at.weekday - 1]} · ${two(at.hour)}:${two(at.minute)}';
}

/// Sohbetteki etkinlik kartı. Planlı aramada "Ara" düğmesi aramayı başlatır.
class TalkEventCardView extends StatelessWidget {
  const TalkEventCardView({super.key, required this.event, required this.mine, required this.time, this.onCall});

  final ({String title, DateTime at, bool? callVideo}) event;
  final bool mine;
  final String time;
  final void Function(bool video)? onCall;

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    final ink = mine ? c.bubbleOutInk : c.bubbleInInk;
    final past = event.at.isBefore(DateTime.now().subtract(const Duration(hours: 1)));
    final video = event.callVideo;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(minWidth: 230, maxWidth: 280),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        decoration: BoxDecoration(color: mine ? c.bubbleOut : c.bubbleIn, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: ink.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
                  child: Icon(video == null ? CupertinoIcons.calendar : (video ? CupertinoIcons.video_camera : CupertinoIcons.phone), size: 21, color: ink),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(event.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: talkText(15, FontWeight.w600, ink)),
                      Text(talkEventWhen(event.at), style: talkText(13, FontWeight.w400, ink.withValues(alpha: 0.7))),
                    ],
                  ),
                ),
              ],
            ),
            if (video != null && onCall != null && !past) ...[
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () => onCall!(video),
                child: Container(
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: ink.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(999)),
                  child: Text(video ? 'Görüntülü katıl' : 'Ara', style: talkText(14, FontWeight.w600, ink)),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(time, style: talkText(10.88, FontWeight.w400, ink.withValues(alpha: 0.55), height: 1)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Etkinlik / planlı arama oluşturma: başlık (etkinlikte), tarih-saat ve (aramada) sesli/görüntülü.
/// Seçilenleri döner; vazgeçilirse null.
Future<({String title, DateTime at, bool video})?> showTalkEventSheet(BuildContext context, {required bool call}) {
  return showModalBottomSheet<({String title, DateTime at, bool video})>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _EventSheet(call: call),
  );
}

class _EventSheet extends StatefulWidget {
  const _EventSheet({required this.call});
  final bool call;

  @override
  State<_EventSheet> createState() => _EventSheetState();
}

class _EventSheetState extends State<_EventSheet> {
  final _title = TextEditingController();
  late DateTime _at = _nextSlot();
  bool _video = false;

  /// Bir sonraki yarım saat
  static DateTime _nextSlot() {
    final n = DateTime.now().add(const Duration(minutes: 30));
    return DateTime(n.year, n.month, n.day, n.hour, n.minute < 30 ? 30 : 0).add(Duration(hours: n.minute < 30 ? 0 : 1));
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _done() {
    final t = _title.text.trim();
    if (!widget.call && t.isEmpty) return;
    Navigator.pop(context, (title: widget.call ? talkCallPlanTitle(video: _video) : t, at: _at, video: _video));
  }

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    final bg = c.dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final card = c.dark ? const Color(0xFF2C2C2E) : Colors.white;
    final canSave = widget.call || _title.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text('Vazgeç', style: talkText(17, FontWeight.w400, c.ink)),
                    ),
                    Expanded(
                      child: Text(widget.call ? 'Arama planla' : 'Yeni etkinlik', textAlign: TextAlign.center, style: talkText(17, FontWeight.w600, c.ink)),
                    ),
                    TextButton(
                      onPressed: canSave ? _done : null,
                      child: Text(widget.call ? 'Planla' : 'Oluştur', style: talkText(17, FontWeight.w600, canSave ? c.ink : c.muted)),
                    ),
                  ],
                ),
              ),
              if (!widget.call)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(12)),
                  child: TextField(
                    controller: _title,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    style: talkText(17, FontWeight.w400, c.ink),
                    cursorColor: c.ink,
                    decoration: InputDecoration(
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: 'Etkinlik adı',
                      hintStyle: talkText(17, FontWeight.w400, c.muted),
                    ),
                  ),
                ),
              if (widget.call)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: CupertinoSlidingSegmentedControl<bool>(
                    groupValue: _video,
                    onValueChanged: (v) => setState(() => _video = v ?? false),
                    children: {
                      false: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text('Sesli', style: talkText(15, FontWeight.w500, c.ink)),
                      ),
                      true: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text('Görüntülü', style: talkText(15, FontWeight.w500, c.ink)),
                      ),
                    },
                  ),
                ),
              Container(
                height: 216,
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(12)),
                child: CupertinoTheme(
                  data: CupertinoThemeData(brightness: c.dark ? Brightness.dark : Brightness.light),
                  child: CupertinoDatePicker(
                    initialDateTime: _at,
                    minimumDate: DateTime.now().subtract(const Duration(minutes: 1)),
                    minuteInterval: 5,
                    use24hFormat: true,
                    onDateTimeChanged: (d) => _at = d,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
