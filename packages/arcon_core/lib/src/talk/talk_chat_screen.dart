import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../auth/session_controller.dart';
import '../config.dart';
import '../push/local_notifier.dart';
import 'talk_call_screen.dart';
import 'talk_contact_sheet.dart';
import 'talk_controller.dart';
import 'talk_icons.dart';
import 'talk_info_screen.dart';
import 'talk_media_composer.dart';
import 'talk_message.dart';
import 'talk_models.dart';
import 'talk_theme.dart';
import 'talk_widgets.dart';

/// Yüklenmekte olan dosya (web: pending entry — ilerleme halkası, İptal, Tekrar).
class _Pending {
  _Pending(this.path, this.name, this.isImage, this.caption, this.replyTo);
  final String path;
  final String name;
  final bool isImage;
  final String caption;
  final int replyTo;
  double progress = 0.02;
  bool failed = false;
  Completer<void> cancel = Completer<void>();
}

/// ARCONNECT sohbet ekranı — web `talk-main` (başlık, mesajlar, yazma alanı) telefon görünümü.
class TalkChatScreen extends StatefulWidget {
  const TalkChatScreen({super.key, required this.controller, required this.channel, required this.config, required this.session, this.initialMedia});

  final TalkController controller;
  final TalkChannel channel;
  final ArconAppConfig config;
  final SessionController session;

  /// Ana ekrandaki kameradan gelen fotoğraf: sohbet açılınca gönderme ekranı açılır
  final List<TalkMediaItem>? initialMedia;

  @override
  State<TalkChatScreen> createState() => _TalkChatScreenState();
}

class _TalkChatScreenState extends State<TalkChatScreen> {
  TalkController get _c => widget.controller;
  TalkChannel get _ch => widget.channel;

  final List<TalkMessage> _messages = [];
  final List<_Pending> _pending = [];
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  bool _loading = true;
  int _lastId = 0;
  List<TalkTyping> _typing = const [];
  TalkSidebar? _side;
  TalkMessage? _reply;
  int? _editing;
  int? _highlight;
  String? _pop; // 'emoji' | 'gif' | 'mention'
  String _mentionQ = '';
  Timer? _poll;
  Timer? _typingStop;
  int _typingPingAt = 0;
  int _localSeq = 0;
  bool _farFromBottom = false; // "aşağı in" butonu
  int _unseen = 0; // yukarıdayken gelen mesaj sayısı
  String _readUpto = ''; // diğer üyelerin hepsinin okuduğu an → mavi tik
  String _deliveredUpto = ''; // hepsinin uygulamayı açtığı an → çift gri tik
  /// İnternet yokken yazılanlar: saat simgesiyle bekler, bağlantı gelince sırayla gider (WhatsApp).
  final List<({int localId, String body, int replyTo})> _outbox = [];
  bool _flushing = false;

  /// Basılı tutunca açılan çoklu seçim (WhatsApp): seçili mesaj id'leri
  final Set<int> _selected = {};
  bool _searching = false;
  final _searchCtl = TextEditingController();
  List<int> _hits = const [];
  int _hitIdx = 0;
  final _rec = AudioRecorder();
  bool _recording = false;
  DateTime _recStart = DateTime.now();
  Timer? _recTick;

  int get _meId => _c.me?.id ?? 0;

  @override
  void initState() {
    super.initState();
    LocalNotifier.openChannelId = _ch.id; // açık sohbetin mesajları için bildirim gösterme
    _c.addListener(_onLive);
    _load();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
    final draft = _c.draftOf(_ch.id);
    if (draft.isNotEmpty) {
      _input.value = TextEditingValue(text: draft, selection: TextSelection.collapsed(offset: draft.length));
    }
    _input.addListener(_onInput);
    _scroll.addListener(_onScroll);
    final media = widget.initialMedia;
    if (media != null && media.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sendPicked(media);
      });
    }
  }

  /// Liste ters (reverse): 0 = en alt. Yukarı çıkınca "aşağı in" butonu görünür.
  void _onScroll() {
    final far = _scroll.hasClients && _scroll.offset > 320;
    if (far != _farFromBottom || (!far && _unseen > 0)) {
      setState(() {
        _farFromBottom = far;
        if (!far) _unseen = 0;
      });
    }
  }

  @override
  void dispose() {
    if (LocalNotifier.openChannelId == _ch.id) LocalNotifier.openChannelId = null;
    _c.removeListener(_onLive);
    _poll?.cancel();
    _typingStop?.cancel();
    if (_typingPingAt > 0) _c.api.typing(_ch.id, false).catchError((_) {});
    _c.setDraft(_ch.id, _input.text);
    _recTick?.cancel();
    _rec.dispose();
    _input.dispose();
    _searchCtl.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await _c.api.messages(_ch.id);
      _messages
        ..clear()
        ..addAll(r.messages);
      _lastId = _messages.isEmpty ? 0 : _messages.map((m) => m.id).reduce((a, b) => a > b ? a : b);
      _typing = r.typing;
      _readUpto = r.readUpto;
      _deliveredUpto = r.deliveredUpto;
      _c.markRead(_ch.id);
    } on ArconApiException catch (e) {
      await widget.session.handleError(e);
      if (mounted) talkToast(context, e.message.isEmpty ? 'Mesaj açılamadı' : e.message, error: true);
    }
    if (mounted) setState(() => _loading = false);
    _refreshSidebar();
  }

  Future<void> _refreshSidebar() async {
    try {
      final s = await _c.api.sidebar(_ch.id);
      if (mounted) setState(() => _side = s);
    } on ArconApiException {
      // sessiz
    }
  }

  /// web `poll`: 2 sn'de bir yeni mesajlar + yazıyor bilgisi; süresi dolan mesajları kaldır.
  Future<void> _pollOnce() async {
    if (_loading) return;
    final now = DateTime.now();
    _messages.removeWhere((m) => m.expiresAt.isNotEmpty && (talkParseTime(m.expiresAt)?.isBefore(now) ?? false));
    try {
      final r = await _c.api.messages(_ch.id, afterId: _lastId);
      if (!mounted) return;
      if (r.messages.isNotEmpty) {
        _append(r.messages);
        _refreshSidebar();
        // sohbet açıkken gelenler okunmuş sayılır (karşı taraf mavi tik görsün)
        if (r.messages.any((m) => m.userId != _meId) && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
          _c.api.read(_ch.id).catchError((_) {});
        }
      }
      if (r.readUpto != _readUpto || r.deliveredUpto != _deliveredUpto) {
        setState(() {
          _readUpto = r.readUpto;
          _deliveredUpto = r.deliveredUpto;
        });
      }
      unawaited(_flushOutbox());
      if (!_c.live) setState(() => _typing = r.typing);
    } on ArconApiException {
      // web: poll hataları yok sayılır
    }
  }

  void _append(List<TalkMessage> list) {
    for (final m in list) {
      if (_messages.any((x) => x.id == m.id)) continue;
      if (m.userId == _meId) {
        final ghost = _messages.indexWhere((x) => x.id < 0 && x.body == m.body);
        if (ghost >= 0) _messages.removeAt(ghost);
      }
      _messages.add(m);
      if (m.id > _lastId) _lastId = m.id;
      if (_farFromBottom && m.userId != _meId) _unseen++;
    }
    if (list.isNotEmpty) _c.updateLast(_ch.id, list.last.body, list.last.createdAt, userId: list.last.userId);
    setState(() {});
  }

  void _onLive() {
    if (!mounted || !_c.live) return;
    setState(() => _typing = _c.typingOf(_ch.id));
  }

  // ---------- yazıyor ----------
  void _onInput() {
    final t = _input.text;
    // @bahsetme: imleçten önceki son "@kelime"
    final sel = _input.selection.baseOffset < 0 ? t.length : _input.selection.baseOffset;
    final before = t.substring(0, sel.clamp(0, t.length));
    final m = RegExp(r'@([A-Za-zÇĞİÖŞÜçğıöşü0-9_]*)$').firstMatch(before);
    if (m != null) {
      setState(() {
        _pop = 'mention';
        _mentionQ = m.group(1) ?? '';
      });
    } else if (_pop == 'mention') {
      setState(() => _pop = null);
    }
    if (t.trim().isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _typingStop?.cancel();
    _typingStop = Timer(const Duration(milliseconds: 2800), () {
      _typingPingAt = 0;
      _c.api.typing(_ch.id, false).catchError((_) {});
    });
    if (now - _typingPingAt < 1800) return;
    _typingPingAt = now;
    _c.api.typing(_ch.id, true).catchError((_) {});
  }

  String get _sub {
    final names = _typing.where((t) => t.userId != _meId).map((t) => talkFirstName(t.displayName)).toList();
    if (names.length == 1) return '${names[0]} yazıyor…';
    if (names.length == 2) return '${names[0]} ve ${names[1]} yazıyor…';
    if (names.length > 2) return 'Birkaç kişi yazıyor…';
    if (_ch.isSelf) return 'Kendinize mesaj gönderin';
    if (_peerOnline) return 'çevrimiçi';
    var base = _ch.isDm
        ? 'kişi bilgisi için dokun'
        : '${_ch.memberCount > 0 ? _ch.memberCount : '—'} üye${_ch.type == 'department' && !_ch.isPrivate ? ' · Resmî grup' : ''}';
    final s = _side;
    if (s != null && s.disappearSec > 0) base = '$base · Süreli: ${s.disappearLabel}';
    return base;
  }

  bool get _isTyping => _typing.any((t) => t.userId != _meId);

  bool get _peerOnline => _ch.isDm && _ch.peer != null && _c.online.contains(_ch.peer!.id);

  // ---------- gönderme ----------
  String _stampNow() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  }

  Future<void> _send([String? override]) async {
    final body = (override ?? _input.text).trim();
    if (body.isEmpty) return;
    final replyTo = _reply?.id ?? 0;
    final reply = _reply;
    final me = _c.me;
    final localId = --_localSeq;
    final local = TalkMessage.fromJson({
      'id': localId,
      'channel_id': _ch.id,
      'user_id': _meId,
      'username': me?.username ?? '',
      'display_name': me?.displayName ?? '',
      'avatar_path': me?.avatarPath ?? '',
      'body': body,
      'created_at': _stampNow(),
      if (reply != null)
        'reply': {
          'id': reply.id,
          'user_id': reply.userId,
          'display_name': reply.displayName,
          'body': reply.body,
        },
    });
    if (override == null) _input.clear();
    setState(() {
      _reply = null;
      _pop = null;
      _messages.add(local);
    });
    _scrollToBottom();
    _c.updateLast(_ch.id, body, local.createdAt, userId: _meId);
    _typingStop?.cancel();
    _typingPingAt = 0;
    _outbox.add((localId: localId, body: body, replyTo: replyTo));
    await _flushOutbox();
  }

  /// Bekleyenleri sırayla gönderir; bağlantı yoksa saat simgesiyle kalır, sonraki denemede gider.
  Future<void> _flushOutbox() async {
    if (_flushing || _outbox.isEmpty) return;
    _flushing = true;
    try {
      while (_outbox.isNotEmpty && mounted) {
        final o = _outbox.first;
        // yanıt kaybolup gerçek mesaj yoklamayla geldiyse yer tutucu zaten kalktı: tekrar gönderme
        if (!_messages.any((m) => m.id == o.localId)) {
          _outbox.removeAt(0);
          continue;
        }
        try {
          final j = await _c.api.sendMessage(channelId: _ch.id, body: o.body, replyTo: o.replyTo);
          _outbox.remove(o);
          if (!mounted) return;
          setState(() => _messages.removeWhere((m) => m.id == o.localId));
          if (j['message'] is Map) _append([TalkMessage.fromJson((j['message'] as Map).cast<String, dynamic>())]);
          _scrollToBottom();
        } on ArconApiException catch (e) {
          if (e.code == 'network') return; // internet yok: saat simgesiyle bekle
          _outbox.remove(o);
          if (!mounted) return;
          setState(() => _messages.removeWhere((m) => m.id == o.localId));
          talkToast(context, e.message.isEmpty ? 'Gönderilemedi' : e.message, error: true);
          if (_input.text.isEmpty) _input.text = o.body;
        }
      }
    } finally {
      _flushing = false;
    }
  }

  TalkTick _tickFor(TalkMessage m) {
    if (m.id < 0) return TalkTick.pending;
    if (_readUpto.isNotEmpty && m.createdAt.compareTo(_readUpto) <= 0) return TalkTick.read;
    if (_deliveredUpto.isNotEmpty && m.createdAt.compareTo(_deliveredUpto) <= 0) return TalkTick.delivered;
    return TalkTick.sent;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  /// Web'deki `<input type="file" multiple>` telefonda bu üç seçeneği gösterir.
  Future<List<TalkMediaItem>> _pickFiles([String? preset]) async {
    final choice = preset ?? await showCupertinoModalPopup<String>(
      context: context,
      // iPhone'da Safari'nin dosya menüsü sistem mavisiyle görünür
      builder: (ctx) => CupertinoTheme(
        data: const CupertinoThemeData(primaryColor: CupertinoColors.systemBlue),
        child: CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx, 'library'), child: const Text('Fotoğraf Arşivi')),
          CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx, 'camera'), child: const Text('Fotoğraf veya Video Çek')),
          CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx, 'files'), child: const Text('Dosya Seç')),
        ],
        cancelButton: CupertinoActionSheetAction(isDefaultAction: true, onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
      ),
      ),
    );
    if (choice == null) return const [];
    final out = <TalkMediaItem>[];
    if (choice == 'files') {
      for (final f in await FilePicker.pickFiles()) {
        final p = f.path;
        if (p != null) out.add(TalkMediaItem(path: p, name: f.name, size: await f.length() ?? 0));
      }
    } else {
      final picker = ImagePicker();
      final xs = choice == 'camera'
          ? [?await picker.pickImage(source: ImageSource.camera, imageQuality: 90)]
          : await picker.pickMultipleMedia(imageQuality: 90);
      for (final x in xs) {
        out.add(TalkMediaItem(path: x.path, name: x.name, size: await x.length()));
      }
    }
    return out;
  }

  /// WhatsApp iOS "+" menüsü: Fotoğraflar, Kamera, Belge, Kişi
  Future<void> _attach() async {
    setState(() => _pop = null);
    _focus.unfocus();
    final c = TalkColors.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      showDragHandle: true,
      builder: (ctx) {
        Widget item(String key, IconData icon, String label) => Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(ctx, key),
                child: Column(children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(color: c.dark ? const Color(0xFF2C2C2E) : Colors.white, shape: BoxShape.circle),
                    child: Icon(icon, size: 28, color: c.ink),
                  ),
                  const SizedBox(height: 8),
                  Text(label, style: talkText(14, FontWeight.w500, c.ink)),
                ]),
              ),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
            child: Row(children: [
              item('library', CupertinoIcons.photo_on_rectangle, 'Fotoğraflar'),
              item('camera', CupertinoIcons.camera, 'Kamera'),
              item('files', CupertinoIcons.doc, 'Belge'),
              item('contact', CupertinoIcons.person_crop_circle, 'Kişi'),
            ]),
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    if (choice == 'contact') return _shareContact();
    final picked = await _pickFiles(choice);
    if (picked.isEmpty || !mounted) return;
    await _sendPicked(picked);
  }

  /// Kişi kartı: seçilen kişinin adı ve kullanıcı adı mesaj olarak gider
  Future<void> _shareContact() async {
    final me = _meId;
    final people = _c.users.where((u) => u.id != me).toList()..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    final c = TalkColors.of(context);
    final u = await showModalBottomSheet<TalkUser>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.rail,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.75,
        child: ListView(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text('Kişi paylaş', textAlign: TextAlign.center, style: talkText(17, FontWeight.w600, c.ink)),
          ),
          for (final p in people)
            ListTile(
              leading: TalkAvatar.solid(name: p.displayName, photoUrl: _c.api.fileUrl(p.avatarPath), size: 40, personIfEmpty: true),
              title: Text(p.displayName, style: talkText(16, FontWeight.w500, c.ink)),
              subtitle: Text('@${p.username}', style: talkText(13.5, FontWeight.w400, c.muted)),
              onTap: () => Navigator.pop(ctx, p),
            ),
        ]),
      ),
    );
    if (u == null || !mounted) return;
    final dept = u.department.trim().isEmpty ? '' : ' · ${u.department.trim()}';
    await _send('👤 ${u.displayName} (@${u.username})$dept');
  }

  Future<void> _sendPicked(List<TalkMediaItem> picked) async {
    if (picked.isEmpty || !mounted) return;
    final items = <TalkMediaItem>[];
    for (final it in picked) {
      if (it.size > 64 * 1024 * 1024) {
        talkToast(context, 'Dosya 64 MB’dan büyük olamaz: ${it.name}', error: true);
        continue;
      }
      items.add(it);
    }
    if (items.length > 12) {
      talkToast(context, 'En fazla 12 dosya gönderebilirsin', error: true);
      items.removeRange(12, items.length);
    }
    if (items.isEmpty || !mounted) return;
    final res = await openTalkMediaComposer(context, items, onAddMore: _pickFiles);
    if (res == null || res.items.isEmpty) return;
    final replyTo = _reply?.id ?? 0;
    setState(() => _reply = null);
    // web: her dosya ayrı mesaj; açıklama ilkinde
    for (var i = 0; i < res.items.length; i++) {
      final it = res.items[i];
      final p = _Pending(it.path, it.name, it.isImage, i == 0 ? res.caption : '', i == 0 ? replyTo : 0);
      setState(() => _pending.add(p));
      _upload(p);
    }
    _scrollToBottom();
  }

  Future<void> _upload(_Pending p) async {
    setState(() {
      p
        ..failed = false
        ..progress = 0.02
        ..cancel = Completer<void>();
    });
    try {
      final j = await _c.api.sendMessage(
        channelId: _ch.id,
        body: p.caption,
        replyTo: p.replyTo,
        filePaths: [p.path],
        onProgress: (v) {
          if (mounted) setState(() => p.progress = (v * 0.95).clamp(0.02, 0.95));
        },
        cancel: p.cancel.future,
      );
      if (!mounted) return;
      setState(() => _pending.remove(p));
      if (j['message'] is Map) _append([TalkMessage.fromJson((j['message'] as Map).cast<String, dynamic>())]);
    } on ArconApiException catch (e) {
      if (!mounted) return;
      if (p.cancel.isCompleted) {
        setState(() => _pending.remove(p));
      } else {
        setState(() => p.failed = true);
        talkToast(context, e.message.isEmpty ? 'Gönderilemedi' : e.message, error: true);
      }
    }
  }

  // ---------- mesaj menüsü ----------
  Future<void> _menu(TalkMessage m, Offset at) async {
    final mine = m.userId == _meId;
    _focus.unfocus();
    final act = await showTalkMessageMenu(
      context,
      mine: mine,
      canCopy: m.text.trim().isNotEmpty,
      canForward: m.id > 0,
      decided: _ch.isGroup && m.id > 0 ? (_side?.decisions.any((d) => d.messageId == m.id) ?? false) : null,
    );
    if (act == null || !mounted) return;
    if (act.startsWith('react:')) return _react(m, act.substring(6));
    switch (act) {
      case 'react-more':
        final e = await showTalkEmojiPicker(context);
        if (e != null) _react(m, e);
      case 'reply':
        _startReply(m);
      case 'info':
        _showInfo(m);
      case 'forward':
        _forward([m]);
      case 'decision':
        await _board(() => _c.api.toggleDecision(m.id), done: (r) => r.decisions.any((d) => d.messageId == m.id) ? 'Karar olarak işaretlendi' : 'Karar kaldırıldı');
      case 'task':
        await _board(() => _c.api.addTask(_ch.id, '', messageId: m.id), done: (_) => 'Görevlere eklendi');
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        if (mounted) talkToast(context, 'Mesaj kopyalandı');
      case 'edit':
        _focus.unfocus();
        setState(() => _editing = m.id);
      case 'delete':
        await _delete([m]);
    }
  }

  /// Kararlar / Görevler işlemi: paneli günceller, kısa bilgi gösterir.
  Future<void> _board(
    Future<({List<TalkDecision> decisions, List<TalkTask> tasks})> Function() call, {
    required String Function(({List<TalkDecision> decisions, List<TalkTask> tasks}) r) done,
  }) async {
    try {
      final r = await call();
      if (!mounted) return;
      final s = _side;
      if (s != null) {
        setState(() {
          s.decisions = r.decisions;
          s.tasks = r.tasks;
        });
      }
      talkToast(context, done(r));
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'İşlem başarısız' : e.message, error: true);
    }
  }

  Future<void> _delete(List<TalkMessage> list) async {
    // web: window.confirm(...) — telefonda sistemin kendi onay kutusu
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        content: Text(list.length == 1 ? 'Bu mesajı silmek istiyor musun?' : '${list.length} mesajı silmek istiyor musun?'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Tamam')),
        ],
      ),
    );
    if (ok != true) return;
    for (final m in list) {
      try {
        await _c.api.deleteMessage(m.id);
        if (mounted) setState(() => _messages.removeWhere((x) => x.id == m.id));
      } on ArconApiException catch (e) {
        if (mounted) talkToast(context, e.message.isEmpty ? 'Silinemedi' : e.message, error: true);
        return;
      }
    }
  }

  // ---------- çoklu seçim ----------
  List<TalkMessage> get _selectedMessages => [
    for (final m in _messages)
      if (_selected.contains(m.id)) m,
  ];

  void _toggleSelect(TalkMessage m) {
    if (m.id <= 0) return;
    _focus.unfocus();
    setState(() => _selected.contains(m.id) ? _selected.remove(m.id) : _selected.add(m.id));
  }

  Future<void> _copySelected() async {
    final list = _selectedMessages;
    final text = list.length == 1
        ? list.first.text
        : list.map((m) => '[${talkClock(m.createdAt)}] ${m.displayName.isEmpty ? m.username : m.displayName}: ${m.text}').join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(_selected.clear);
    talkToast(context, list.length == 1 ? 'Mesaj kopyalandı' : '${list.length} mesaj kopyalandı');
  }

  Widget _selectHead(TalkColors c) {
    final list = _selectedMessages;
    final allMine = list.isNotEmpty && list.every((m) => m.userId == _meId);
    final one = list.length == 1 ? list.first : null;
    Widget act(IconData icon, String tip, VoidCallback onTap) => IconButton(
      tooltip: tip,
      onPressed: onTap,
      icon: Icon(icon, color: c.ink),
    );
    return Container(
      height: 64,
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
      decoration: BoxDecoration(
        color: c.chatHead,
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Seçimi kapat',
            onPressed: () => setState(_selected.clear),
            icon: Icon(Icons.close, color: c.ink),
          ),
          const SizedBox(width: 6),
          Expanded(child: Text('${list.length}', style: talkText(18, FontWeight.w700, c.ink))),
          if (one != null)
            act(Icons.reply, 'Yanıtla', () {
              setState(_selected.clear);
              _startReply(one);
            }),
          if (list.any((m) => m.text.trim().isNotEmpty)) act(Icons.copy_outlined, 'Kopyala', _copySelected),
          act(Icons.shortcut, 'İlet', () {
            final l = _selectedMessages;
            setState(_selected.clear);
            _forward(l);
          }),
          if (allMine)
            act(Icons.delete_outline, 'Sil', () {
              final l = _selectedMessages;
              setState(_selected.clear);
              _delete(l);
            }),
          if (one != null && allMine)
            act(Icons.info_outline, 'Bilgi', () {
              setState(_selected.clear);
              _showInfo(one);
            }),
        ],
      ),
    );
  }

  /// WhatsApp "Bilgi": kim okudu, kim henüz okumadı
  Future<void> _showInfo(TalkMessage m) async {
    final c = TalkColors.of(context);
    final future = _c.api.messageInfo(m.id);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.dark ? const Color(0xFF1F2C34) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
        child: FutureBuilder(
          future: future,
          builder: (ctx, snap) {
            Widget head(String t) => Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                  child: Text(t, style: talkText(13.5, FontWeight.w700, TalkColors.ticks)),
                );
            Widget person(TalkUser u, String sub) => ListTile(
                  leading: TalkAvatar.solid(name: u.displayName, photoUrl: _c.api.fileUrl(u.avatarPath), size: 36, fontSize: 12),
                  title: Text(u.displayName, style: talkText(15, FontWeight.w600, c.ink)),
                  subtitle: sub.isEmpty ? null : Text(sub, style: talkText(12.5, FontWeight.w400, c.muted)),
                );
            final body = <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
                child: Text('Mesaj bilgisi', style: talkText(17, FontWeight.w700, c.ink)),
              ),
            ];
            if (snap.hasError) {
              body.add(Padding(padding: const EdgeInsets.all(20), child: Text('Bilgi alınamadı', style: talkText(14, FontWeight.w400, c.muted))));
            } else if (!snap.hasData) {
              body.add(const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator(strokeWidth: 2))));
            } else {
              final d = snap.data!;
              body.add(head('Okudu'));
              if (d.read.isEmpty) body.add(Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 8), child: Text('Henüz kimse okumadı', style: talkText(13.5, FontWeight.w400, c.muted))));
              for (final (u, at) in d.read) {
                final t = talkParseTime(at);
                body.add(person(u, t == null ? '' : '${talkDayLabel(t)} ${talkClock(at)}'));
              }
              if (d.unread.isNotEmpty) {
                body.add(head('Henüz okumadı'));
                for (final u in d.unread) {
                  body.add(person(u, ''));
                }
              }
            }
            return SafeArea(top: false, child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: body));
          },
        ),
      ),
    );
  }

  /// Mesajı başka sohbetlere ilet (birden fazla seçilebilir)
  Future<void> _forward(List<TalkMessage> list) async {
    final c = TalkColors.of(context);
    final picked = <int>{};
    final targets = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.dark ? const Color(0xFF1F2C34) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(children: [
                  Expanded(child: Text('İletilecek sohbet', style: talkText(17, FontWeight.w700, c.ink))),
                  TextButton(
                    onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, picked.toList()),
                    child: Text(picked.isEmpty ? 'Gönder' : 'Gönder (${picked.length})', style: talkText(14.5, FontWeight.w700, picked.isEmpty ? c.muted : TalkColors.wa)),
                  ),
                ]),
              ),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final ch in _c.channels)
                    CheckboxListTile(
                      value: picked.contains(ch.id),
                      activeColor: TalkColors.wa,
                      onChanged: (v) => setSheet(() => v == true ? picked.add(ch.id) : picked.remove(ch.id)),
                      secondary: TalkAvatar.solid(name: ch.name, photoUrl: _c.api.fileUrl(ch.photo), size: 36, fontSize: 12),
                      title: Text(ch.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: talkText(15, FontWeight.w600, c.ink)),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
    if (targets == null || targets.isEmpty || !mounted) return;
    try {
      var n = 0;
      for (final m in list) {
        n = await _c.api.forward(m.id, targets);
      }
      if (mounted) {
        talkToast(context, list.length > 1 ? '${list.length} mesaj iletildi' : (n == 1 ? 'Mesaj iletildi' : '$n sohbete iletildi'));
      }
      _c.refresh(silent: true);
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'İletilemedi' : e.message, error: true);
    }
  }

  // ---------- sesli mesaj ----------
  Future<void> _startRec() async {
    if (!await _rec.hasPermission()) {
      if (mounted) talkToast(context, 'Sesli mesaj için mikrofon izni gerekli', error: true);
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/sesli-mesaj-${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100), path: path);
    HapticFeedback.mediumImpact();
    _focus.unfocus();
    setState(() {
      _recording = true;
      _recStart = DateTime.now();
      _pop = null;
    });
    _recTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _stopRec({required bool send}) async {
    _recTick?.cancel();
    final ms = DateTime.now().difference(_recStart).inMilliseconds;
    final path = await _rec.stop();
    if (!mounted) return;
    setState(() => _recording = false);
    if (path == null) return;
    if (!send || ms < 1000) {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // geçici dosya zaten yoksa sorun değil
      }
      if (send) talkToast(context, 'Sesli mesaj çok kısa');
      return;
    }
    final p = _Pending(path, 'sesli-mesaj.m4a', false, '', _reply?.id ?? 0);
    setState(() {
      _reply = null;
      _pending.add(p);
    });
    _upload(p);
    _scrollToBottom();
  }

  Widget _recordingBar(TalkColors c) {
    final secs = DateTime.now().difference(_recStart).inSeconds;
    return Row(children: [
      const SizedBox(width: 4),
      const Icon(Icons.fiber_manual_record, color: TalkColors.danger, size: 14),
      const SizedBox(width: 8),
      Text('${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}', style: talkText(15.2, FontWeight.w600, c.ink)),
      const SizedBox(width: 10),
      Expanded(child: Text('Kaydediliyor…', style: talkText(14, FontWeight.w400, c.muted))),
      IconButton(
        tooltip: 'Vazgeç',
        onPressed: () => _stopRec(send: false),
        icon: TalkIcon(TalkSvg.trash, size: 20, color: TalkColors.danger),
      ),
      GestureDetector(
        onTap: () => _stopRec(send: true),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
          child: TalkIcon(TalkSvg.send, size: 18, color: c.accentContrast),
        ),
      ),
    ]);
  }

  // ---------- sohbette arama ----------
  void _runSearch(String q) {
    final needle = q.trim().toLowerCase();
    final hits = needle.isEmpty ? <int>[] : [for (final m in _messages.reversed) if (m.id > 0 && m.text.toLowerCase().contains(needle)) m.id];
    setState(() {
      _hits = hits;
      _hitIdx = 0;
    });
    if (hits.isNotEmpty) _jumpTo(hits.first);
  }

  void _stepHit(int dir) {
    if (_hits.isEmpty) return;
    setState(() => _hitIdx = (_hitIdx + dir) % _hits.length);
    if (_hitIdx < 0) _hitIdx += _hits.length;
    _jumpTo(_hits[_hitIdx]);
  }

  void _closeSearch() {
    _searchCtl.clear();
    setState(() {
      _searching = false;
      _hits = const [];
    });
  }

  void _startReply(TalkMessage m) {
    setState(() {
      _reply = m;
      _editing = null;
    });
    _focus.requestFocus();
  }

  Future<void> _react(TalkMessage m, String emoji) async {
    try {
      await _c.api.react(m.id, emoji);
      // web: sunucudan güncel tepki listesi gelene kadar yerelde çevir
      final list = [...m.reactions];
      final i = list.indexWhere((r) => r.emoji == emoji);
      if (i >= 0) {
        final r = list[i];
        list[i] = TalkReaction(emoji: emoji, count: r.mine ? r.count - 1 : r.count + 1, mine: !r.mine);
      } else {
        list.add(TalkReaction(emoji: emoji, count: 1, mine: true));
      }
      setState(() => m.reactions = list.where((r) => r.count > 0).toList());
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'Tepki eklenemedi' : e.message, error: true);
    }
  }

  Future<void> _saveEdit(TalkMessage m, String body) async {
    if (body.trim().isEmpty) {
      talkToast(context, 'Mesaj boş olamaz', error: true);
      return;
    }
    try {
      await _c.api.editMessage(m.id, body.trim());
      setState(() {
        m
          ..body = body.trim()
          ..edited = true;
        _editing = null;
      });
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'Düzenlenemedi' : e.message, error: true);
    }
  }

  void _jumpTo(int id) {
    final ctx = _keys[id]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx, alignment: 0.4, duration: const Duration(milliseconds: 250));
    setState(() => _highlight = id);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _highlight = null);
    });
  }

  Future<void> _startCall({required bool video}) async {
    final existing = _c.liveCallOn(_ch.id);
    if (existing != null) {
      await TalkCallScreen.joinLive(
        context,
        api: _c.api,
        call: existing,
        photoUrl: _c.api.fileUrl(_ch.photo),
      );
      return;
    }
    var title = _ch.name;
    if (_ch.isGroup) {
      final ctrl = TextEditingController(text: _ch.name);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(video ? 'Görüntülü toplantı' : 'Sesli toplantı'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Toplantı adı'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ara')),
          ],
        ),
      );
      if (ok != true || !mounted) {
        ctrl.dispose();
        return;
      }
      title = ctrl.text.trim().isEmpty ? _ch.name : ctrl.text.trim();
      ctrl.dispose();
    }
    await TalkCallScreen.start(
      context,
      api: _c.api,
      channelId: _ch.id,
      video: video,
      title: title,
      peerName: _ch.isDm ? (_ch.peer?.displayName ?? _ch.name) : title,
      photoUrl: _c.api.fileUrl(_ch.photo),
    );
  }

  void _openInfo() async {
    final res = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => TalkInfoScreen(controller: _c, channel: _ch, sidebar: _side, session: widget.session, config: widget.config),
    ));
    if (!mounted) return;
    // gruptan çıkıldı: sohbet listesine dön
    if (res == 'left') {
      Navigator.of(context).pop();
      return;
    }
    // Kararlar / Görevler'den bir mesaja dokunuldu
    if (res != null && res.startsWith('jump:')) _jumpTo(int.tryParse(res.substring(5)) ?? 0);
    // bilgi ekranındaki "Sohbette ara"
    if (res == 'search') setState(() => _searching = true);
    _refreshSidebar();
  }

  TalkUser _userFromMessage(TalkMessage m) {
    for (final u in _c.users) {
      if (u.id == m.userId) return u;
    }
    for (final u in _side?.people ?? const <TalkUser>[]) {
      if (u.id == m.userId) return u;
    }
    return TalkUser(id: m.userId, username: m.username, displayName: m.displayName.isEmpty ? m.username : m.displayName, avatarPath: m.avatarPath);
  }

  Future<void> _openContact(TalkUser user) async {
    if (user.id == _c.me?.id) return;
    await showTalkContactSheet(
      context: context,
      user: user,
      photoUrl: _c.api.fileUrl(user.avatarPath),
      onMessage: () => unawaited(_contactMessage(user)),
      onVoice: () => unawaited(_contactCall(user, video: false)),
      onVideo: () => unawaited(_contactCall(user, video: true)),
    );
  }

  Future<void> _contactMessage(TalkUser user) async {
    if (_ch.isDm && _ch.peer?.id == user.id) return;
    try {
      final ch = await _c.api.openDm(user.id);
      if (ch == null || !mounted) return;
      _c.upsertChannel(ch);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TalkChatScreen(controller: _c, channel: ch, config: widget.config, session: widget.session),
        ),
      );
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'Sohbet açılamadı' : e.message, error: true);
    }
  }

  Future<void> _contactCall(TalkUser user, {required bool video}) async {
    try {
      TalkChannel? ch = (_ch.isDm && _ch.peer?.id == user.id) ? _ch : await _c.api.openDm(user.id);
      if (ch == null || !mounted) return;
      _c.upsertChannel(ch);
      await TalkCallScreen.start(
        context,
        api: _c.api,
        channelId: ch.id,
        video: video,
        title: user.displayName,
        peerName: user.displayName,
        photoUrl: _c.api.fileUrl(user.avatarPath),
      );
    } on ArconApiException catch (e) {
      if (mounted) talkToast(context, e.message.isEmpty ? 'Arama başlatılamadı' : e.message, error: true);
    }
  }

  // ---------- arayüz ----------
  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    // Android geri tuşu önce seçimi kapatır (WhatsApp)
    return PopScope(
      canPop: _selected.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
      backgroundColor: c.msgBg,
      resizeToAvoidBottomInset: true,
      appBar: talkStatusBar(context),
      body: Column(children: [
        _head(c),
        Expanded(
          child: GestureDetector(
            // WhatsApp gibi: mesajlara dokununca klavye ve açık pencereler kapanır
            onTap: () {
              _focus.unfocus();
              setState(() => _pop = null);
            },
            child: Stack(children: [
              Positioned.fill(child: _background(c)),
              _list(c),
              if (_c.liveCallOn(_ch.id) != null)
                Positioned(
                  left: 12,
                  right: 12,
                  top: 8,
                  child: Material(
                    color: TalkColors.wa,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: () => _startCall(video: _c.liveCallOn(_ch.id)?.video ?? false),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: Text(
                          'Devam eden arama — katıl',
                          textAlign: TextAlign.center,
                          style: talkText(14, FontWeight.w700, Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_farFromBottom) Positioned(right: 14, bottom: 14, child: _toBottomButton(c)),
            ]),
          ),
        ),
        _composer(c),
      ]),
    ),
    );
  }

  Widget _head(TalkColors c) => _selected.isNotEmpty ? _selectHead(c) : (_searching ? _searchHead(c) : _mainHead(c));

  Widget _searchHead(TalkColors c) => Container(
        height: 64,
        padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
        decoration: BoxDecoration(color: c.chatHead, border: Border(bottom: BorderSide(color: c.line))),
        child: Row(children: [
          IconButton(onPressed: _closeSearch, icon: TalkIcon(TalkSvg.back, size: 22, color: c.ink)),
          Expanded(
            child: TextField(
              controller: _searchCtl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _runSearch,
              onSubmitted: (_) => _stepHit(1),
              style: talkText(15.5, FontWeight.w400, c.ink),
              cursorColor: c.ink,
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                hintText: 'Sohbette ara…',
                hintStyle: talkText(15.5, FontWeight.w400, c.muted),
              ),
            ),
          ),
          if (_searchCtl.text.trim().isNotEmpty)
            Text(_hits.isEmpty ? '0' : '${_hitIdx + 1}/${_hits.length}', style: talkText(13, FontWeight.w600, c.muted)),
          IconButton(onPressed: _hits.isEmpty ? null : () => _stepHit(1), icon: Icon(Icons.keyboard_arrow_up, color: c.ink)),
          IconButton(onPressed: _hits.isEmpty ? null : () => _stepHit(-1), icon: Icon(Icons.keyboard_arrow_down, color: c.ink)),
        ]),
      );

  /// WhatsApp iOS başlığı: yuvarlak geri, fotoğraf + ad, sağda görüntülü/sesli arama kapsülü
  Widget _mainHead(TalkColors c) {
    final glass = BoxDecoration(
      color: c.dark ? const Color(0xFF1C1C1E) : Colors.white,
      border: Border.all(color: c.dark ? const Color(0xFF2C2C2E) : const Color(0xFFE6E6E8)),
      boxShadow: c.dark ? null : const [BoxShadow(color: Color(0x12000000), blurRadius: 10, offset: Offset(0, 3))],
    );
    void openPeer() {
      if (_ch.isDm && _ch.peer != null) {
        unawaited(_openContact(_ch.peer!));
      } else {
        _openInfo();
      }
    }

    return Container(
      height: 64,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: c.chatHead,
      child: Row(children: [
        Tooltip(
          message: 'Sohbet listesine dön',
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 44,
              height: 44,
              decoration: glass.copyWith(shape: BoxShape.circle),
              child: Icon(CupertinoIcons.chevron_left, size: 24, color: c.ink),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openInfo,
            onLongPress: openPeer,
            child: Row(children: [
              _ch.isDm || _ch.photo.isNotEmpty
                  ? TalkAvatar.solid(name: _ch.name, photoUrl: _c.api.fileUrl(_ch.photo), size: 40, personIfEmpty: true)
                  : Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: c.dark ? const Color(0xFF2C2C2E) : const Color(0xFFEBEBEF), shape: BoxShape.circle),
                      child: Icon(CupertinoIcons.person_2_fill, size: 22, color: c.dark ? const Color(0xFFAEAEB2) : const Color(0xFF6E6E73)),
                    ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(_ch.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: talkText(17, FontWeight.w600, c.ink, height: 1.25)),
                  if (_isTyping || _peerOnline || !_ch.isDm || _ch.isSelf)
                    Text(_sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: talkText(12.5, FontWeight.w400, c.muted, height: 1.3).copyWith(fontStyle: _isTyping ? FontStyle.italic : FontStyle.normal)),
                ]),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        // kendinle sohbette arama yok
        if (!_ch.isSelf)
          Container(
            height: 44,
            decoration: glass.copyWith(borderRadius: BorderRadius.circular(22)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Görüntülü ara',
                onPressed: () => _startCall(video: true),
                icon: Icon(CupertinoIcons.video_camera, size: 30, color: c.ink),
              ),
              IconButton(
                tooltip: 'Sesli ara',
                onPressed: () => _startCall(video: false),
                icon: Icon(CupertinoIcons.phone, size: 24, color: c.ink),
              ),
            ]),
          ),
      ]),
    );
  }

  /// `.talk-messages` arka planı: iki hafif radyal gölge
  Widget _background(TalkColors c) => DecoratedBox(
        decoration: BoxDecoration(color: c.msgBg),
        child: Stack(children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.6, -0.8),
                  radius: 0.9,
                  colors: [c.dark ? const Color(0x08FFFFFF) : const Color(0x08000000), const Color(0x00000000)],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.6, 0.8),
                  radius: 0.95,
                  colors: [c.dark ? const Color(0x06FFFFFF) : const Color(0x06000000), const Color(0x00000000)],
                ),
              ),
            ),
          ),
        ]),
      );

  Widget _list(TalkColors c) {
    if (_loading) {
      return Center(child: Text('Yükleniyor…', style: talkText(16, FontWeight.w700, c.ink)));
    }
    if (_messages.isEmpty && _pending.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: 'Henüz mesaj yok\n', style: talkText(16.8, FontWeight.w700, c.ink, height: 1.6)),
                const TextSpan(text: 'İlk mesajı sen yaz veya dosya paylaş.'),
              ]),
              textAlign: TextAlign.center,
              style: talkText(16, FontWeight.w400, c.muted),
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(builder: (context, box) {
      final contentW = box.maxWidth - 45;
      final maxBubble = contentW * 0.82 - 42;
      final children = <Widget>[];
      DateTime? lastDay;
      for (final m in _messages) {
        final d = talkParseTime(m.createdAt);
        if (d != null) {
          final day = DateTime(d.year, d.month, d.day);
          if (lastDay == null || day != lastDay) {
            children.add(_dayChip(c, talkDayLabel(d)));
            lastDay = day;
          }
        }
        final key = _keys.putIfAbsent(m.id, GlobalKey.new);
        final picked = _selected.contains(m.id);
        final callLine = m.attachments.isEmpty ? talkCallLine(m.body) : null;
        final view = callLine != null
            // WhatsApp gibi arama balonu; dokununca geri arar
            ? TalkCallLineView(line: callLine, mine: m.userId == _meId, time: talkClock(m.createdAt), onTap: () => _startCall(video: callLine.video))
            : TalkMessageView(
          message: m,
          mine: m.userId == _meId,
          group: _ch.isGroup,
          api: _c.api,
          maxWidth: maxBubble,
          onMenu: (at) => _menu(m, at),
          onSelect: m.id > 0 ? () => _toggleSelect(m) : null,
          onReact: (e) => _react(m, e),
          onReplyTap: _jumpTo,
          onSwipeReply: m.id > 0 ? () => _startReply(m) : null,
          tick: _tickFor(m),
          editing: _editing == m.id,
          onEditSave: (b) => _saveEdit(m, b),
          onEditCancel: () => setState(() => _editing = null),
          onUserTap: m.userId == _meId ? null : () => _openContact(_userFromMessage(m)),
        );
        children.add(AnimatedContainer(
          key: key,
          duration: const Duration(milliseconds: 300),
          color: picked ? TalkColors.wa.withValues(alpha: 0.22) : (_highlight == m.id ? c.accentSoft : Colors.transparent),
          // seçim açıkken dokunuş mesajı seçer / bırakır (menü açılmaz)
          child: _selected.isEmpty
              ? view
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _toggleSelect(m),
                  child: AbsorbPointer(child: view),
                ),
        ));
        children.add(const SizedBox(height: 8));
      }
      for (final p in _pending) {
        children.add(_PendingView(p: p, maxWidth: maxBubble, me: _c.me, photoUrl: _c.api.fileUrl(_c.me?.avatarPath ?? ''), onCancel: () => p.cancel.complete(), onRetry: () => _upload(p)));
        children.add(const SizedBox(height: 8));
      }
      return SingleChildScrollView(
        controller: _scroll,
        reverse: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(22.5, 18, 22.5, 28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );
    });
  }

  /// WhatsApp'taki gün ayracı ("Bugün", "Dün", "2 Kasım")
  Widget _dayChip(TalkColors c, String label) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 12),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(color: c.chatHead, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.line)),
            child: Text(label, style: talkText(12.2, FontWeight.w600, c.muted, height: 1.3)),
          ),
        ),
      );

  /// En alta inme butonu; yukarıdayken gelen mesaj sayısını gösterir.
  Widget _toBottomButton(TalkColors c) => GestureDetector(
        onTap: () {
          setState(() => _unseen = 0);
          _scrollToBottom();
        },
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.composerBar,
              shape: BoxShape.circle,
              border: Border.all(color: c.line),
              boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 8, offset: Offset(0, 2))],
            ),
            child: RotatedBox(quarterTurns: 3, child: TalkIcon(TalkSvg.back, size: 20, color: c.ink)),
          ),
          if (_unseen > 0)
            Positioned(
              top: -6,
              right: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                constraints: const BoxConstraints(minWidth: 20),
                decoration: BoxDecoration(color: TalkColors.wa, borderRadius: BorderRadius.circular(999)),
                child: Text('$_unseen', textAlign: TextAlign.center, style: talkText(11, FontWeight.w700, Colors.white, height: 1.3)),
              ),
            ),
        ]),
      );

  /// Mesaj yazma alanı (WhatsApp düzeni)
  Widget _composer(TalkColors c) {
    return Container(
      padding: EdgeInsets.fromLTRB(8, 6, 8, 8 + MediaQuery.paddingOf(context).bottom * (MediaQuery.viewInsetsOf(context).bottom > 0 ? 0 : 1)),
      color: c.composerArea,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_pop == 'mention') _mentionPop(c),
        if (_pop == 'emoji' || _pop == 'gif') _emojiPop(c),
        if (_reply != null) _replyBar(c),
        // Anahtar şart: üstüne açılan pencere de Container; anahtarsız olunca yazı kutusu
        // yeniden kurulup odağı (klavyeyi) kaybediyordu.
        // WhatsApp iOS: "+" · yazı kutusu (içinde çıkartma/emoji) · kamera · siyah mikrofon / gönder
        Row(
          key: const ValueKey('talk-composer-bar'),
          crossAxisAlignment: CrossAxisAlignment.end,
          children: _recording
              ? [Expanded(child: Container(height: 48, padding: const EdgeInsets.symmetric(horizontal: 4), decoration: BoxDecoration(color: c.composerBar, borderRadius: BorderRadius.circular(24)), child: _recordingBar(c)))]
              : [
                  _composerIcon(c, Icons.add, 'Ekle', _attach, size: 30),
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 40),
                      padding: const EdgeInsets.fromLTRB(14, 0, 4, 0),
                      decoration: BoxDecoration(
                        color: c.composerBar,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: c.composerBorder, width: 0.6),
                      ),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 9),
                            child: TextField(
                              controller: _input,
                              focusNode: _focus,
                              minLines: 1,
                              maxLines: 5,
                              maxLength: 8000,
                              textCapitalization: TextCapitalization.sentences,
                              style: talkText(16.5, FontWeight.w400, c.ink, height: 1.3),
                              cursorColor: c.ink,
                              onTap: () => setState(() => _pop = _pop == 'mention' ? 'mention' : null),
                              decoration: const InputDecoration(
                                isCollapsed: true,
                                filled: false,
                                counterText: '',
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                              ),
                            ),
                          ),
                        ),
                        // çıkartma simgesi: emoji ve GIF penceresi
                        _barBtn(TalkSvg.sticker, 'Emoji ve GIF', () {
                          _focus.unfocus();
                          setState(() => _pop = _pop == 'emoji' || _pop == 'gif' ? null : 'emoji');
                        }),
                      ]),
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _input,
                    builder: (_, v, _) {
                      final empty = v.text.trim().isEmpty;
                      return Row(mainAxisSize: MainAxisSize.min, children: [
                        if (empty) _composerIcon(c, CupertinoIcons.camera, 'Kamera', () async => _sendPicked(await _pickFiles('camera')), size: 26),
                        Padding(
                          padding: EdgeInsets.only(left: empty ? 2 : 8),
                          child: Tooltip(
                            message: empty ? 'Sesli mesaj' : 'Gönder',
                            child: GestureDetector(
                              onTap: empty ? _startRec : () => _send(),
                              child: Container(
                                width: 40,
                                height: 40,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                                child: empty
                                    ? Icon(CupertinoIcons.mic_fill, size: 21, color: c.accentContrast)
                                    : Icon(CupertinoIcons.arrow_up, size: 22, color: c.accentContrast),
                              ),
                            ),
                          ),
                        ),
                      ]);
                    },
                  ),
                ],
        ),
      ]),
    );
  }

  Widget _composerIcon(TalkColors c, IconData icon, String tip, VoidCallback onTap, {double size = 26}) => Tooltip(
        message: tip,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(width: 44, height: 40, child: Center(child: Icon(icon, size: size, color: c.ink))),
        ),
      );

  Widget _barBtn(String svg, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(width: 38, height: 40, child: Center(child: TalkIcon(svg, size: 22, color: TalkColors.of(context).ink))),
        ),
      );

  /// `.talk-reply-bar`
  Widget _replyBar(TalkColors c) {
    final r = _reply!;
    final name = r.userId == _meId ? 'Sen' : (r.displayName.isEmpty ? 'Mesaj' : r.displayName);
    final text = r.text.isNotEmpty ? r.text : (r.attachments.isNotEmpty ? r.attachments.first.origName : (r.gifs.isNotEmpty ? 'GIF' : 'Mesaj'));
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0x1F7F7F7F),
        borderRadius: BorderRadius.circular(10),
        border: const Border(left: BorderSide(color: TalkColors.ticks, width: 3)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: talkText(12.8, FontWeight.w600, TalkColors.ticks)),
            const SizedBox(height: 2),
            Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: talkText(12.8, FontWeight.w400, c.muted)),
          ]),
        ),
        GestureDetector(
          onTap: () => setState(() => _reply = null),
          child: SizedBox(width: 28, height: 28, child: Center(child: Text('×', style: talkText(20, FontWeight.w400, c.muted, height: 1)))),
        ),
      ]),
    );
  }

  /// Yazılmakta olan "@kelime"yi seçilen adla değiştirir; klavye açık kalır.
  void _insertMention(String name) {
    final t = _input.text;
    final sel = _input.selection.baseOffset < 0 ? t.length : _input.selection.baseOffset.clamp(0, t.length);
    final before = t.substring(0, sel).replaceFirst(RegExp(r'@([A-Za-zÇĞİÖŞÜçğıöşü0-9_]*)$'), '@$name ');
    _input.value = TextEditingValue(text: before + t.substring(sel), selection: TextSelection.collapsed(offset: before.length));
    setState(() => _pop = null);
    _focus.requestFocus();
  }

  /// `.talk-pop--mention`
  Widget _mentionPop(TalkColors c) {
    final q = _mentionQ.toLowerCase();
    final pool = (_side?.people ?? const <TalkUser>[])
        .where((u) => u.id != _meId)
        .where((u) => q.isEmpty || u.displayName.toLowerCase().contains(q) || u.username.toLowerCase().contains(q))
        .take(8)
        .toList();
    final everyone = !_ch.isDm && 'herkes'.startsWith(q);
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 6),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: c.railTop,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.popBorder),
        boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 40, offset: Offset(0, 16))],
      ),
      child: pool.isEmpty && !everyone
          ? Padding(padding: const EdgeInsets.all(10), child: Text('Kullanıcı yok', style: talkText(13.6, FontWeight.w400, const Color(0xFF6B7280))))
          : ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(6),
              children: [
                if (everyone)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _insertMention('herkes'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(children: [
                        Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: c.accentSoft, shape: BoxShape.circle),
                          child: Text('@', style: talkText(14, FontWeight.w800, c.ink, height: 1)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text('herkes', style: talkText(16, FontWeight.w600, c.ink))),
                        Text('Gruptaki herkes', style: talkText(12.48, FontWeight.w400, c.muted)),
                      ]),
                    ),
                  ),
                for (final u in pool)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _insertMention(u.displayName),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(children: [
                        TalkAvatar.solid(name: u.displayName, photoUrl: _c.api.fileUrl(u.avatarPath), size: 28, fontSize: 10.4),
                        const SizedBox(width: 10),
                        Expanded(child: Text(u.displayName, style: talkText(16, FontWeight.w400, c.ink))),
                        Text(u.department, style: talkText(12.48, FontWeight.w400, c.muted)),
                      ]),
                    ),
                  ),
              ],
            ),
    );
  }

  /// `.talk-pop--emoji`: Emoji / GIF sekmeleri
  Widget _emojiPop(TalkColors c) {
    final tabOn = BoxDecoration(color: c.railTop, boxShadow: [BoxShadow(color: c.accent, offset: const Offset(0, -2), spreadRadius: -0.1)]);
    Widget tab(String label, String key) => Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _pop = key),
            child: Container(
              padding: const EdgeInsets.all(10),
              alignment: Alignment.center,
              decoration: _pop == key
                  ? tabOn.copyWith(border: Border(bottom: BorderSide(color: c.accent, width: 2)), boxShadow: const [])
                  : null,
              child: Text(label, style: talkText(13.12, FontWeight.w700, _pop == key ? c.ink : const Color(0xFF8696A0))),
            ),
          ),
        );
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: MediaQuery.sizeOf(context).width - 16 > 380 ? 380 : MediaQuery.sizeOf(context).width - 16,
        margin: const EdgeInsets.only(bottom: 12),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.railTop,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.popBorder),
          boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 40, offset: Offset(0, 16))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            decoration: BoxDecoration(color: c.accentSoft, border: const Border(bottom: BorderSide(color: Color(0xFF2A3942)))),
            child: Row(children: [tab('Emoji', 'emoji'), tab('GIF', 'gif')]),
          ),
          if (_pop == 'emoji')
            SizedBox(
              height: 300,
              child: EmojiPicker(
                textEditingController: _input,
                config: talkEmojiConfig(c),
              ),
            )
          else
            _GifPane(onPick: (url) {
              setState(() => _pop = null);
              _send('[[gif:$url]]');
            }),
        ]),
      ),
    );
  }
}

/// GIF paneli: web ile aynı hazır paket + Giphy araması.
class _GifPane extends StatefulWidget {
  const _GifPane({required this.onPick});
  final void Function(String url) onPick;

  @override
  State<_GifPane> createState() => _GifPaneState();
}

class _GifPaneState extends State<_GifPane> {
  static const _pack = [
    ('ok', 'https://media.giphy.com/media/111ebonMs90YLu/giphy.gif'),
    ('clap', 'https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif'),
    ('party', 'https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif'),
    ('wow', 'https://media.giphy.com/media/3o7aCTPPm4OZnLLPeE/giphy.gif'),
    ('yes', 'https://media.giphy.com/media/l0MYC0LjbYagzsYVy/giphy.gif'),
    ('work', 'https://media.giphy.com/media/13HgwGsXF0aiGY/giphy.gif'),
    ('coffee', 'https://media.giphy.com/media/3oKIPnAiaMCws8nOsE/giphy.gif'),
    ('ship', 'https://media.giphy.com/media/xT9IgG50Fb7Mi0prBC/giphy.gif'),
    ('done', 'https://media.giphy.com/media/artj92V8o75VPL7ATN/giphy.gif'),
  ];
  List<String> _urls = [for (final g in _pack) g.$2];
  Timer? _debounce;

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final query = q.trim().toLowerCase();
      var list = [for (final g in _pack) if (query.isEmpty || g.$1.contains(query)) g.$2];
      if (query.isNotEmpty) {
        try {
          final res = await http.get(Uri.parse(
              'https://api.giphy.com/v1/gifs/search?api_key=dc6zaTOxFJmzC&q=${Uri.encodeQueryComponent(query)}&limit=12&rating=g'));
          final data = (jsonDecode(res.body) as Map)['data'] as List? ?? const [];
          final remote = [
            for (final g in data)
              if (((g as Map)['images'] as Map?)?['fixed_height_small']?['url'] case final String u) u,
          ];
          if (remote.isNotEmpty) list = remote;
        } on Exception {
          // paket yedeği
        }
      }
      if (mounted) setState(() => _urls = list.isEmpty ? [for (final g in _pack) g.$2] : list);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          onChanged: _search,
          style: talkText(13.6, FontWeight.w400, const Color(0xFF111111)),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: const Color(0xFFF7F7F8),
            hintText: 'GIF ara…',
            hintStyle: talkText(13.6, FontWeight.w400, c.muted),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.line)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c.line)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 220,
          child: GridView.count(
            crossAxisCount: 3,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            children: [
              for (final u in _urls)
                GestureDetector(
                  onTap: () => widget.onPick(u),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(color: const Color(0xFFF0F0F0), child: Image.network(u, fit: BoxFit.cover)),
                  ),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Gönderilmekte olan dosya — kendi balonunda ilerleme halkası (×) veya "Tekrar".
class _PendingView extends StatelessWidget {
  const _PendingView({required this.p, required this.maxWidth, required this.me, required this.photoUrl, required this.onCancel, required this.onRetry});
  final _Pending p;
  final double maxWidth;
  final TalkUser? me;
  final String photoUrl;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    Widget ring() => GestureDetector(
          onTap: onCancel,
          child: Container(
            width: 36,
            height: 36,
            decoration: p.isImage ? const BoxDecoration(color: Color(0x8C0B141A), shape: BoxShape.circle) : null,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(value: p.progress, strokeWidth: 3, color: p.isImage ? Colors.white : c.bubbleOutInk, backgroundColor: const Color(0x40FFFFFF)),
              Text('×', style: talkText(16, FontWeight.w700, p.isImage ? Colors.white : c.bubbleOutInk, height: 1)),
            ]),
          ),
        );
    Widget retry() => GestureDetector(
          onTap: onRetry,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: TalkColors.wa, borderRadius: BorderRadius.circular(999)),
            child: Text('Tekrar', style: talkText(12, FontWeight.w700, Colors.white)),
          ),
        );
    final body = p.isImage
        ? ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(alignment: Alignment.center, children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth - 24 > 280 ? 280 : maxWidth - 24),
                child: Opacity(opacity: 0.85, child: Image.file(File(p.path), fit: BoxFit.cover)),
              ),
              p.failed ? retry() : ring(),
            ]),
          )
        : Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0x24000000),
              borderRadius: BorderRadius.circular(10),
              border: p.failed ? Border.all(color: const Color(0x59EF4444)) : null,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              p.failed ? retry() : ring(),
              const SizedBox(width: 10),
              Flexible(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: talkText(14.08, FontWeight.w700, c.bubbleOutInk))),
            ]),
          );
    return Align(
      alignment: Alignment.centerRight,
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Flexible(
          child: Container(
            constraints: BoxConstraints(maxWidth: maxWidth),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            decoration: BoxDecoration(
              color: c.bubbleOut,
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(10), topRight: Radius.circular(10), bottomLeft: Radius.circular(10), bottomRight: Radius.circular(2)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              body,
              if (p.caption.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(p.caption, style: talkText(14.72, FontWeight.w400, c.bubbleOutInk, height: 1.45)),
                ),
              const SizedBox(height: 2),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Opacity(opacity: 0.55, child: Text(talkClock(DateTime.now().toString()), style: talkText(10.88, FontWeight.w400, c.bubbleOutInk))),
                const SizedBox(width: 4),
                Opacity(opacity: 0.55, child: TalkIcon(TalkSvg.pendingClock, size: 12, color: c.bubbleOutInk)),
              ]),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        TalkAvatar.hue(name: me?.displayName ?? '?', seed: me?.id, photoUrl: photoUrl),
      ]),
    );
  }
}
