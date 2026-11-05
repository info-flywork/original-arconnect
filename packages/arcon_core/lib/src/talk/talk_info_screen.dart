import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api/api_client.dart';
import '../auth/session_controller.dart';
import '../config.dart';
import 'talk_call_screen.dart';
import 'talk_chat_screen.dart';
import 'talk_contact_sheet.dart';
import 'talk_controller.dart';
import 'talk_icons.dart';
import 'talk_message.dart';
import 'talk_models.dart';
import 'talk_pickers.dart';
import 'talk_theme.dart';
import 'talk_widgets.dart';

const _fileSvg = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></svg>';
const _mailSvg = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 4h16v16H4z"/><path d="M4 7l8 6 8-6"/></svg>';

/// `.talk-info` — Grup bilgisi / Kişi bilgisi (telefonda tam ekran).
class TalkInfoScreen extends StatefulWidget {
  const TalkInfoScreen({super.key, required this.controller, required this.channel, required this.session, required this.config, this.sidebar});

  final TalkController controller;
  final TalkChannel channel;
  final SessionController session;
  final ArconAppConfig config;
  final TalkSidebar? sidebar;

  @override
  State<TalkInfoScreen> createState() => _TalkInfoScreenState();
}

class _TalkInfoScreenState extends State<TalkInfoScreen> {
  TalkController get _c => widget.controller;
  late TalkSidebar? _s = widget.sidebar;
  final _name = TextEditingController();
  final _desc = TextEditingController();
  bool _mediaOpen = false;
  String _tab = 'media';
  String _myAvatar = '';

  @override
  void dispose() {
    _taskInput.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _apply(_s);
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await _c.api.sidebar(widget.channel.id);
      if (mounted) setState(() => _apply(s));
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message, error: true);
    }
  }

  void _apply(TalkSidebar? s) {
    _s = s;
    if (s == null) return;
    _name.text = s.name;
    _desc.text = s.isDm ? 'Direkt mesaj' : s.description;
    _myAvatar = _c.me?.avatarPath ?? '';
  }

  bool get _isDm => _s?.isDm ?? widget.channel.isDm;
  bool get _canManage => (_s?.canManage ?? false) && !_isDm;
  bool get _canInvite => (_s?.canInvite ?? false) && !_isDm;

  Future<void> _saveChannel() async {
    try {
      final s = await _c.api.updateChannel(widget.channel.id, name: _name.text.trim(), description: _desc.text.trim());
      setState(() => _apply(s));
      widget.channel.name = s.name;
      if (mounted) talkToast(context, 'Kaydedildi');
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'Kaydedilemedi' : e.message, error: true);
    }
  }

  Future<void> _pickChannelAvatar() async {
    if (!_canManage) return;
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (x == null) return;
    try {
      final s = await _c.api.updateChannel(widget.channel.id, avatarPath: x.path);
      setState(() => _apply(s));
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'Foto yüklenemedi' : e.message, error: true);
    }
  }

  Future<void> _pickMyAvatar() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (x == null) return;
    try {
      final p = await _c.api.profileAvatar(x.path);
      setState(() => _myAvatar = p);
      if (mounted) talkToast(context, 'Profil fotoğrafı güncellendi');
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'Foto yüklenemedi' : e.message, error: true);
    }
  }

  Future<void> _disappear() async {
    final s = _s;
    if (s == null) return;
    if (!s.canSetDisappear) {
      talkToast(context, s.disappearSec > 0
          ? 'Süreli mesaj açık: ${s.disappearLabel}. Değiştirmek için grup admini olmalısın.'
          : 'Süreli mesajı yalnızca grup admini (DM’de her iki taraf) ayarlayabilir.');
      return;
    }
    final sec = await showDisappearModal(context, s.disappearSec);
    if (sec == null) return;
    try {
      final ns = await _c.api.setDisappear(widget.channel.id, sec);
      setState(() => _apply(ns));
      if (mounted) talkToast(context, sec > 0 ? 'Süreli mesaj: ${ns.disappearLabel}' : 'Süreli mesaj kapatıldı');
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'Ayarlanamadı' : e.message, error: true);
    }
  }

  Future<void> _invite() async {
    if (!_canInvite) {
      talkToast(context, 'Üye ekleme yetkin yok', error: true);
      return;
    }
    final ns = await showInviteModal(context, _c, widget.channel.id, [for (final p in _s?.people ?? const <TalkUser>[]) p.id]);
    if (ns != null) setState(() => _apply(ns));
  }

  Future<void> _openMember(TalkUser p) async {
    await showTalkContactSheet(
      context: context,
      user: p,
      photoUrl: _c.api.fileUrl(p.avatarPath),
      onMessage: () => _memberOp('dm', p),
      onVoice: () => _callMember(p, video: false),
      onVideo: () => _callMember(p, video: true),
    );
  }

  Future<void> _callMember(TalkUser u, {required bool video}) async {
    try {
      final ch = await _c.api.openDm(u.id);
      if (ch == null || !mounted) return;
      _c.upsertChannel(ch);
      await TalkCallScreen.start(
        context,
        api: _c.api,
        channelId: ch.id,
        video: video,
        title: u.displayName,
        peerName: u.displayName,
        photoUrl: _c.api.fileUrl(u.avatarPath),
      );
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'Arama başlatılamadı' : e.message, error: true);
    }
  }

  Future<void> _memberOp(String act, TalkUser u) async {
    try {
      if (act == 'dm') {
        final ch = await _c.api.openDm(u.id);
        if (ch != null) _c.upsertChannel(ch);
        if (ch != null && mounted) {
          Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => TalkChatScreen(controller: _c, channel: ch, config: widget.config, session: widget.session),
          ));
        }
        return;
      }
      TalkSidebar ns;
      if (act == 'remove') {
        if (!await talkConfirm(context, title: 'Üyeyi çıkar', message: 'Üyeyi kanaldan çıkarmak istiyor musun?')) return;
        ns = await _c.api.removeMember(widget.channel.id, u.id);
        if (mounted) talkToast(context, 'Üye kanaldan çıkarıldı');
      } else if (act == 'promote') {
        ns = await _c.api.setRole(widget.channel.id, u.id, 'admin');
        if (mounted) talkToast(context, 'Admin yapıldı');
      } else {
        ns = await _c.api.setRole(widget.channel.id, u.id, 'member');
        if (mounted) talkToast(context, 'Üye rolüne alındı');
      }
      setState(() => _apply(ns));
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'İşlem başarısız' : e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    final s = _s;
    final white = c.dark ? c.infoCard : Colors.white;
    return Scaffold(
      backgroundColor: c.dark ? c.infoBg : const Color(0xFFF7F8FA),
      appBar: talkStatusBar(context),
      body: Column(children: [
        // `.talk-info__top`
        Container(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
          decoration: BoxDecoration(color: c.dark ? const Color(0xFF111827) : Colors.white, border: Border(bottom: BorderSide(color: c.line))),
          child: Row(children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: c.dark ? const Color(0x0FFFFFFF) : const Color(0x0F000000), shape: BoxShape.circle),
                child: TalkIcon(TalkSvg.back, size: 22, color: c.ink),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(child: Text(_isDm ? 'Kişi bilgisi' : 'Grup bilgisi', style: talkText(16.8, FontWeight.w700, c.ink, letterSpacing: -0.3))),
            const SizedBox(width: 44),
          ]),
        ),
        Expanded(
          child: s == null
              ? Center(child: Text('Yükleniyor…', style: talkText(16, FontWeight.w700, c.ink)))
              : ListView(padding: const EdgeInsets.only(bottom: 28), children: [
                  _hero(c, s),
                  _quickCard(c, white),
                  if (!_isDm) _actions(c, white),
                  _myPhoto(c),
                  _disappearRow(c, s),
                  _media(c, s, white),
                  if (!_isDm) ...[
                    _block(c, white, 'Adminler', s.admins, true),
                    _block(c, white, 'Üyeler', s.members, false),
                    _card(c, white, TalkSvg.decisions, 'Kararlar', _decisions(c, s)),
                    _card(c, white, TalkSvg.tasks, 'Görevler', _tasks(c, s)),
                  ],
                  _card(c, white, TalkSvg.clock, 'Aktivite', _activity(c, s)),
                  if (s.channel['type'] == 'group') _leaveRow(c, white),
                ]),
        ),
      ]),
    );
  }

  /// WhatsApp iOS bilgi ekranı: sohbette ara, sessize al, arşivle, favori
  Widget _quickCard(TalkColors c, Color white) {
    final id = widget.channel.id;
    Widget tile(IconData i, String t, VoidCallback onTap, {bool last = false}) => InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Row(children: [
              Icon(i, size: 22, color: c.ink),
              const SizedBox(width: 14),
              Expanded(
                child: Container(
                  height: 48,
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: c.rowLine, width: 0.6))),
                  child: Text(t, style: talkText(16, FontWeight.w400, c.ink)),
                ),
              ),
            ]),
          ),
        );
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Material(
          color: white,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            tile(CupertinoIcons.search, 'Sohbette ara', () => Navigator.pop(context, 'search')),
            tile(_c.muted.contains(id) ? CupertinoIcons.bell : CupertinoIcons.bell_slash,
                _c.muted.contains(id) ? 'Bildirimleri aç' : 'Sessize al', () => _c.toggleMute(id)),
            tile(_c.favourites.contains(id) ? CupertinoIcons.star_fill : CupertinoIcons.star,
                _c.favourites.contains(id) ? 'Favorilerden çıkar' : 'Favorilere ekle', () => _c.toggleFavourite(id)),
            tile(CupertinoIcons.archivebox, _c.archived.contains(id) ? 'Arşivden çıkar' : 'Sohbeti arşivle', () => _c.toggleArchive(id), last: true),
          ]),
        ),
      ),
    );
  }

  /// WhatsApp'taki kırmızı "Gruptan çık" satırı
  Widget _leaveRow(TalkColors c, Color white) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Material(
          color: white,
          borderRadius: BorderRadius.circular(12),
          child: ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            leading: const Icon(Icons.logout, color: Color(0xFFE11D48)),
            title: Text('Gruptan çık', style: talkText(15, FontWeight.w600, const Color(0xFFE11D48))),
            onTap: _leave,
          ),
        ),
      );

  Future<void> _leave() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('"${widget.channel.name}" grubundan çıkılsın mı?'),
        content: const Text('Bu gruptan artık mesaj almayacaksın.'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Çık')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _c.leaveChannel(widget.channel);
      if (!mounted) return;
      talkToast(context, 'Gruptan çıktın');
      Navigator.of(context).pop('left');
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'Gruptan çıkılamadı' : e.message, error: true);
    }
  }

  /// `.talk-info__hero` (telefon: ortalı, 120px avatar)
  Widget _hero(TalkColors c, TalkSidebar s) {
    final peer = s.channel['peer'] is Map ? TalkUser.fromJson((s.channel['peer'] as Map).cast<String, dynamic>()) : null;
    final photo = s.avatarPath.isNotEmpty ? s.avatarPath : (peer?.avatarPath ?? '');
    final input = InputDecoration(
      isDense: true,
      filled: _canManage,
      fillColor: c.accentSoft,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: _canManage ? c.line : Colors.transparent)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: _canManage ? c.line : Colors.transparent)),
      disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.transparent)),
    );
    // web: ch.member_count (sidebar kanalında yok) || admins + members
    final total = (s.channel['member_count'] as num?)?.toInt() ?? (s.admins.length + s.members.length);
    final official = s.channel['type'] == 'department' && s.channel['is_private'] != true ? ' · Resmî grup' : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 28, 18, 18),
      child: Column(children: [
        GestureDetector(
          onTap: _pickChannelAvatar,
          child: SizedBox(
            width: 120,
            height: 120,
            child: Stack(children: [
              Container(
                width: 120,
                height: 120,
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0xFFDBE4EE),
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Color(0x14000000), blurRadius: 10, offset: Offset(0, 2))],
                ),
                child: photo.isNotEmpty
                    ? Image.network(_c.api.fileUrl(photo), fit: BoxFit.cover, width: 120, height: 120)
                    : _isDm
                        ? Text(talkInitials(s.name), style: talkText(35.2, FontWeight.w700, const Color(0xFF5B6B7C)))
                        : const TalkIcon(TalkSvg.camera, size: 36, color: Color(0xFF5B6B7C)),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(children: [
            TextField(
              controller: _name,
              enabled: _canManage,
              textAlign: TextAlign.center,
              maxLength: 120,
              style: talkText(21.6, FontWeight.w700, c.ink, letterSpacing: -0.4),
              decoration: input.copyWith(counterText: '', hintText: 'Grup adı'),
            ),
            const SizedBox(height: 2),
            Text(_isDm ? 'Direkt yazışma' : 'Grup · $total üye$official',
                textAlign: TextAlign.center, style: talkText(13.76, FontWeight.w500, c.muted)),
            const SizedBox(height: 2),
            TextField(
              controller: _desc,
              enabled: _canManage,
              textAlign: TextAlign.center,
              maxLength: 255,
              style: talkText(14.08, FontWeight.w400, _canManage ? c.ink : c.muted),
              decoration: input.copyWith(counterText: '', hintText: 'Grup açıklaması ekle', hintStyle: talkText(14.08, FontWeight.w400, c.muted)),
            ),
            if (_canManage)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: GestureDetector(
                  onTap: _saveChannel,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(8)),
                    child: Text('Kaydet', style: talkText(12.48, FontWeight.w700, Colors.white)),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  /// `.talk-info__actions` — Üye ekle / Üyeleri gör
  Widget _actions(TalkColors c, Color white) {
    Widget action(String svg, String label, VoidCallback onTap, {bool divider = false}) => Expanded(
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
              decoration: divider ? BoxDecoration(border: Border(right: BorderSide(color: c.line))) : null,
              child: Column(children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: TalkColors.infoGreen, shape: BoxShape.circle),
                  child: TalkIcon(svg, size: 18, color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(label, style: talkText(12.8, FontWeight.w700, c.dark ? c.ink : TalkColors.infoGreenText)),
              ]),
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(color: white, border: Border(bottom: BorderSide(color: c.line))),
      child: Row(children: [
        if (_canInvite) action(TalkSvg.userAdd, 'Üye ekle', _invite, divider: true),
        action(TalkSvg.members, 'Üyeleri gör', () => Scrollable.ensureVisible(_membersKey.currentContext!, duration: const Duration(milliseconds: 250))),
      ]),
    );
  }

  final _membersKey = GlobalKey();

  /// `.talk-info__my-photo`
  Widget _myPhoto(TalkColors c) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 2, 14),
        child: Material(
          color: c.infoCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: c.popBorder)),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _pickMyAvatar,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Container(
                  width: 48,
                  height: 48,
                  clipBehavior: Clip.antiAlias,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: TalkColors.wa, shape: BoxShape.circle),
                  child: _myAvatar.isNotEmpty
                      ? Image.network(_c.api.fileUrl(_myAvatar), fit: BoxFit.cover, width: 48, height: 48)
                      : Text(talkInitials(_c.me?.displayName ?? '?'), style: talkText(15.2, FontWeight.w800, Colors.white)),
                ),
                const SizedBox(width: 12),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Profil fotoğrafım', style: talkText(14.72, FontWeight.w700, c.ink)),
                  const SizedBox(height: 2),
                  Text('Fotoğraf ekle veya değiştir', style: talkText(12.48, FontWeight.w400, c.muted)),
                ]),
              ]),
            ),
          ),
        ),
      );

  /// `.talk-disappear-row`
  Widget _disappearRow(TalkColors c, TalkSidebar s) {
    final on = s.disappearSec > 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: on ? const Color(0x0F25D366) : (c.dark ? c.infoCard : Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: on ? const Color(0x5925D366) : c.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _disappear,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: const Color(0x1F25D366), borderRadius: BorderRadius.circular(10)),
                child: const TalkIcon(TalkSvg.clock, size: 20, color: Color(0xFF128C7E)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Süreli mesajlar', style: dmSansLike(c)),
                  const SizedBox(height: 2),
                  Text(s.disappearLabel, style: talkText(12, FontWeight.w400, c.muted)),
                ]),
              ),
              Text('›', style: talkText(20, FontWeight.w400, c.muted)),
            ]),
          ),
        ),
      ),
    );
  }

  TextStyle dmSansLike(TalkColors c) => talkText(13.5, FontWeight.w600, c.ink);

  /// `.talk-media` — Medya, bağlantılar ve dosyalar
  Widget _media(TalkColors c, TalkSidebar s, Color white) {
    final files = s.files;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 10),
      decoration: BoxDecoration(color: white, border: Border(top: BorderSide(color: c.line))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: () => setState(() => _mediaOpen = !_mediaOpen),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 28, child: Padding(padding: const EdgeInsets.only(top: 2), child: TalkIcon(TalkSvg.media, size: 20, color: c.muted))),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Medya, bağlantılar ve dosyalar', style: talkText(14.72, FontWeight.w700, c.ink, height: 1.3)),
                  const SizedBox(height: 2),
                  Row(children: [
                    Text('${files.length}', style: talkText(13.44, FontWeight.w600, c.muted)),
                    const SizedBox(width: 4),
                    AnimatedRotation(turns: _mediaOpen ? 0.25 : 0, duration: const Duration(milliseconds: 150), child: Text('›', style: talkText(16, FontWeight.w400, c.muted, height: 1))),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
        if (!_mediaOpen)
          Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 12), child: Text('Henüz medya yok', style: talkText(13.44, FontWeight.w400, c.muted)))
        else ...[
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line), bottom: BorderSide(color: c.line))),
            child: Row(children: [
              for (final (k, l) in const [('media', 'Medya'), ('links', 'Bağlantılar'), ('files', 'Dosyalar')])
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _tab = k),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _tab == k ? c.ink : Colors.transparent, width: 2))),
                      child: Text(l, style: talkText(13.12, FontWeight.w700, _tab == k ? c.ink : c.muted)),
                    ),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
            child: switch (_tab) {
              'media' => Text('Medya yok', style: talkText(13.44, FontWeight.w400, c.muted)),
              'links' => Text('Bağlantı yok', style: talkText(13.44, FontWeight.w400, c.muted)),
              _ => files.isEmpty
                  ? Text('Dosya yok', style: talkText(13.44, FontWeight.w400, c.muted))
                  : Column(children: [
                      for (final f in files)
                        InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => openTalkFile(context, _c.api.fileUrl(f.path), f.origName),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                            child: Row(children: [
                              Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(color: c.dark ? c.accentSoft : const Color(0xFF111111), borderRadius: BorderRadius.circular(10)),
                                child: TalkIcon(_fileSvg, size: 16, color: c.dark ? c.ink : Colors.white),
                              ),
                              const SizedBox(width: 10),
                              Expanded(child: Text(f.origName, maxLines: 1, overflow: TextOverflow.ellipsis, style: talkText(13.76, FontWeight.w700, c.ink))),
                              TalkIcon(TalkSvg.download, size: 14, color: c.muted),
                            ]),
                          ),
                        ),
                    ]),
            },
          ),
        ],
      ]),
    );
  }

  /// `.talk-info__block` — Adminler / Üyeler
  Widget _block(TalkColors c, Color white, String title, List<TalkUser> people, bool admins) => Container(
        key: admins ? null : _membersKey,
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(color: white, border: Border(top: BorderSide(color: c.line))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(children: [
              Text(title, style: talkText(14.72, FontWeight.w700, c.dark ? c.muted : TalkColors.infoGreen)),
              const Spacer(),
              if (_canManage)
                GestureDetector(
                  onTap: _invite,
                  child: Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: Color(0x2E00A884), shape: BoxShape.circle),
                    child: Text('+', style: talkText(16, FontWeight.w700, TalkColors.wa, height: 1)),
                  ),
                ),
              const SizedBox(width: 6),
              Text('${people.length}', style: talkText(13.6, FontWeight.w600, c.dark ? c.muted : TalkColors.infoGreen)),
            ]),
          ),
          for (final p in people) _person(c, p, admins),
        ]),
      );

  Widget _person(TalkColors c, TalkUser p, bool asAdmin) {
    final isMe = p.id == _c.me?.id;
    final role = p.role == 'owner' ? 'Owner' : (p.role == 'admin' ? 'Admin' : 'Üye');
    Widget op(String svg, String act, String tip) => Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Tooltip(
            message: tip,
            child: GestureDetector(
              onTap: () => _memberOp(act, p),
              child: Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: c.infoCard, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.line)),
                child: TalkIcon(svg, size: 14, color: c.ink),
              ),
            ),
          ),
        );
    final manage = (_s?.canManage ?? false) && !isMe && p.role != 'owner';
    return Material(
      color: c.accentSoft,
      child: InkWell(
      onTap: isMe ? null : () => _openMember(p),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          TalkAvatar.solid(name: p.displayName, photoUrl: _c.api.fileUrl(p.avatarPath), size: 48, fontSize: 13.12),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: talkText(15.2, FontWeight.w600, c.ink, height: 1.25)),
              const SizedBox(height: 2),
              Text('$role${p.department.isNotEmpty ? ' · ${p.department}' : ''}', style: talkText(12.48, FontWeight.w400, c.muted)),
            ]),
          ),
          if (manage && asAdmin) ...[op(TalkSvg.user, 'demote', 'Üye yap'), op(TalkSvg.x, 'remove', 'Çıkar')],
          if (manage && !asAdmin) ...[op(TalkSvg.shield, 'promote', 'Admin yap'), op(TalkSvg.x, 'remove', 'Çıkar')],
          if (!manage && !isMe) op(TalkSvg.msg, 'dm', 'Mesaj gönder'),
        ]),
      ),
      ),
    );
  }

  // ---------- Kararlar / Görevler ----------
  final _taskInput = TextEditingController();

  int get _meId => _c.me?.id ?? 0;

  Future<void> _board(Future<({List<TalkDecision> decisions, List<TalkTask> tasks})> Function() call) async {
    try {
      final r = await call();
      final s = _s;
      if (!mounted || s == null) return;
      setState(() {
        s.decisions = r.decisions;
        s.tasks = r.tasks;
      });
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'İşlem başarısız' : e.message, error: true);
    }
  }

  static String _shortDate(String at) {
    final d = talkParseTime(at);
    return d == null ? '' : talkDayLabel(d);
  }

  Widget _decisions(TalkColors c, TalkSidebar s) {
    if (s.decisions.isEmpty) {
      return Text('Henüz karar yok. Bir mesaja dokunup "Karar olarak işaretle" diyebilirsin.', style: talkText(13.6, FontWeight.w400, c.muted));
    }
    return Column(children: [
      for (final d in s.decisions)
        InkWell(
          // dokununca sohbette o mesaja gider
          onTap: () => Navigator.of(context).pop('jump:${d.messageId}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: talkText(13.6, FontWeight.w700, c.ink)),
                  Text('${d.markedBy} · ${_shortDate(d.createdAt)}', style: talkText(12, FontWeight.w400, c.muted)),
                ]),
              ),
              if (d.userId == _meId || s.canManage)
                IconButton(
                  tooltip: 'Kararı kaldır',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close, size: 18, color: c.muted),
                  onPressed: () => _board(() => _c.api.toggleDecision(d.messageId)),
                ),
            ]),
          ),
        ),
    ]);
  }

  Widget _tasks(TalkColors c, TalkSidebar s) {
    final total = s.tasks.length;
    final open = s.tasks.where((t) => !t.done).length;
    Future<void> add() async {
      final title = _taskInput.text.trim();
      if (title.isEmpty) return;
      _taskInput.clear();
      await _board(() => _c.api.addTask(widget.channel.id, title));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(total == 0 ? 'Görev yok' : (open == 0 ? 'Tüm görevler tamamlandı' : '$open açık görev'), style: talkText(14.4, FontWeight.w600, c.ink)),
      if (total > 0) ...[
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: (total - open) / total,
            minHeight: 8,
            color: c.dark ? Colors.white : const Color(0xFF111111),
            backgroundColor: c.dark ? const Color(0xFF2A3942) : const Color(0xFFE8E8E8),
          ),
        ),
        const SizedBox(height: 6),
        for (final t in s.tasks)
          InkWell(
            onTap: () => _board(() => _c.api.toggleTask(t.id)),
            onLongPress: (t.createdBy == _meId || s.canManage) ? () => _confirmDeleteTask(t) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Checkbox(
                  value: t.done,
                  activeColor: TalkColors.wa,
                  visualDensity: VisualDensity.compact,
                  onChanged: (_) => _board(() => _c.api.toggleTask(t.id)),
                ),
                Expanded(
                  child: Text(
                    t.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: talkText(13.6, FontWeight.w500, t.done ? c.muted : c.ink)
                        .copyWith(decoration: t.done ? TextDecoration.lineThrough : null),
                  ),
                ),
                if (t.messageId > 0)
                  IconButton(
                    tooltip: 'Mesaja git',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.chat_bubble_outline, size: 16, color: c.muted),
                    onPressed: () => Navigator.of(context).pop('jump:${t.messageId}'),
                  ),
              ]),
            ),
          ),
      ],
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _taskInput,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => add(),
            style: talkText(14, FontWeight.w400, c.ink),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Görev ekle',
              hintStyle: talkText(14, FontWeight.w400, c.muted),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.line)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.line)),
            ),
          ),
        ),
        IconButton(tooltip: 'Ekle', onPressed: add, icon: const Icon(Icons.add_circle, color: TalkColors.wa)),
      ]),
    ]);
  }

  Future<void> _confirmDeleteTask(TalkTask t) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        content: Text('"${t.title}" görevi silinsin mi?'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true) await _board(() => _c.api.deleteTask(t.id));
  }

  /// `.talk-info__card`
  Widget _card(TalkColors c, Color white, String svg, String title, Widget body) => Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(color: white, border: Border(top: BorderSide(color: c.line))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(10)),
              child: TalkIcon(svg, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Text(title, style: talkText(14.72, FontWeight.w800, c.ink, letterSpacing: -0.15)),
          ]),
          const SizedBox(height: 10),
          body,
        ]),
      );

  Widget _activity(TalkColors c, TalkSidebar s) {
    if (s.activity.isEmpty) return Text('Aktivite yok', style: talkText(13.6, FontWeight.w400, c.muted));
    String icon(String label) {
      final t = label.toLowerCase();
      if (RegExp(r'dosya|yükle|upload|file').hasMatch(t)) return _fileSvg;
      if (RegExp(r'karar|onay|decision').hasMatch(t)) return TalkSvg.decisions;
      if (RegExp(r'mail|e-?posta|email').hasMatch(t)) return _mailSvg;
      return TalkSvg.user;
    }

    return Column(children: [
      for (final a in s.activity)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0xFF111111), borderRadius: BorderRadius.circular(7)),
              child: TalkIcon(icon('${a['label'] ?? ''}'), size: 12, color: Colors.white),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: '${a['label'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  if ('${a['preview'] ?? ''}'.trim().isNotEmpty)
                    TextSpan(
                        text: ' · ${'${a['preview']}'.replaceAll(RegExp(r'\[\[chip:[^\]]+\]\]'), '').replaceAll(RegExp(r'\[\[gif:[^\]]+\]\]'), '[GIF]').trim()}'),
                ]),
                style: talkText(12.8, FontWeight.w400, c.muted),
              ),
            ),
            Text(_clock('${a['created_at'] ?? ''}'), style: talkText(11.52, FontWeight.w400, c.muted)),
          ]),
        ),
    ]);
  }

  String _clock(String iso) {
    final d = talkParseTime(iso);
    return d == null ? '' : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
