import 'dart:async';
import 'dart:io';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'talk_api.dart';
import 'talk_icons.dart';
import 'talk_models.dart';
import 'talk_theme.dart';
import 'talk_widgets.dart';

const talkQuickReact = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Tek mesaj balonu (WhatsApp düzeni; grupta başkalarının mesajında avatar + isim).
class TalkMessageView extends StatelessWidget {
  const TalkMessageView({
    super.key,
    required this.message,
    required this.mine,
    required this.api,
    required this.maxWidth,
    required this.onMenu,
    required this.onReact,
    required this.onReplyTap,
    this.onUserTap,
    this.onSwipeReply,
    this.onSelect,
    this.tick = TalkTick.sent,
    this.editing = false,
    this.onEditSave,
    this.onEditCancel,
    this.group = true,
  });

  final TalkMessage message;
  /// WhatsApp: birebir sohbette isim ve avatar yok; grupta yalnızca başkalarının mesajında var.
  final bool group;
  final bool mine;
  final TalkApi api;
  final double maxWidth;
  final void Function(Offset globalPos) onMenu;
  final void Function(String emoji) onReact;
  final void Function(int messageId) onReplyTap;
  /// Avatar / isim: kişi bilgisi
  final VoidCallback? onUserTap;
  /// WhatsApp gibi balonu sağa kaydırınca yanıtla
  final VoidCallback? onSwipeReply;
  /// WhatsApp gibi basılı tutunca çoklu seçim başlar (verilmezse menü açılır)
  final VoidCallback? onSelect;
  /// kendi mesajında WhatsApp tikleri: saat → tek tik → çift gri → çift mavi
  final TalkTick tick;
  final bool editing;
  final void Function(String body)? onEditSave;
  final VoidCallback? onEditCancel;

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    final m = message;
    final text = m.text;
    final images = m.attachments.where((a) => a.isImage).toList();
    final others = m.attachments.where((a) => !a.isImage).toList();
    final gifs = m.gifs;
    final chips = m.chips;
    final mediaOnly = text.isEmpty && chips.isEmpty && (gifs.isNotEmpty || images.isNotEmpty) && others.isEmpty;
    final gifOnly = gifs.isNotEmpty && text.isEmpty && chips.isEmpty && images.isEmpty && others.isEmpty;
    final ink = mine ? c.bubbleOutInk : c.bubbleInInk;
    final onMedia = gifOnly || (mediaOnly && images.isNotEmpty);
    final bubbleBg = mediaOnly || gifOnly ? Colors.transparent : (mine ? c.bubbleOut : c.bubbleIn);
    Widget avatar = TalkAvatar.hue(name: m.displayName.isEmpty ? m.username : m.displayName, seed: m.userId, photoUrl: api.fileUrl(m.avatarPath));
    if (onUserTap != null) {
      avatar = GestureDetector(onTap: onUserTap, child: avatar);
    }

    final foot = Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.end, children: [
      if (m.expiresAt.isNotEmpty) ...[
        Opacity(opacity: 0.75, child: Text('⏱', style: talkText(11.52, FontWeight.w400, ink, height: 1))),
        const SizedBox(width: 4),
      ],
      if (m.edited) ...[
        Opacity(opacity: 0.65, child: Text('düzenlendi', style: talkText(10.88, FontWeight.w400, ink).copyWith(fontStyle: FontStyle.italic))),
        const SizedBox(width: 4),
      ],
      Opacity(
        opacity: mine ? 0.55 : 1,
        child: Text(talkClock(m.createdAt), style: talkText(10.88, FontWeight.w400, mine ? c.bubbleOutInk : c.time, height: 1)),
      ),
      if (mine) ...[
        const SizedBox(width: 4),
        _TickMark(tick: tick, color: ink),
      ],
    ]);

    final mediaFoot = Row(mainAxisSize: MainAxisSize.min, children: [
      Opacity(
        opacity: 0.95,
        child: Text(talkClock(m.createdAt),
            style: talkText(10.88, FontWeight.w400, Colors.white, height: 1)
                .copyWith(shadows: const [Shadow(color: Color(0x8C000000), blurRadius: 2, offset: Offset(0, 1))])),
      ),
      if (mine) ...[
        const SizedBox(width: 4),
        _TickMark(tick: tick, color: Colors.white, onMedia: true),
      ],
    ]);

    final bubble = GestureDetector(
      // dokununca ya da basılı tutunca alttan menü açılır (bağlantı, görsel gibi iç dokunuşlar önceliklidir)
      onTapUp: editing ? null : (d) => onMenu(d.globalPosition),
      onLongPressStart: editing ? null : (d) => onSelect != null ? onSelect!() : onMenu(d.globalPosition),
      child: Container(
        padding: gifOnly
            ? EdgeInsets.zero
            : (mediaOnly ? const EdgeInsets.fromLTRB(4, 2, 4, 16) : const EdgeInsets.fromLTRB(12, 8, 12, 6)),
        decoration: BoxDecoration(
          color: bubbleBg,
          borderRadius: mine
              ? const BorderRadius.only(topLeft: Radius.circular(10), topRight: Radius.circular(10), bottomLeft: Radius.circular(10), bottomRight: Radius.circular(2))
              : const BorderRadius.only(topLeft: Radius.circular(10), topRight: Radius.circular(10), bottomRight: Radius.circular(10), bottomLeft: Radius.circular(2)),
        ),
        child: Stack(clipBehavior: Clip.none, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (!mine && group)
              Padding(
                padding: const EdgeInsets.only(right: 18),
                child: GestureDetector(
                  onTap: onUserTap,
                  child: Text(m.displayName.isEmpty ? m.username : m.displayName, style: talkText(13.12, FontWeight.w700, c.name, height: 1.5)),
                ),
              ),
            if (m.reply != null) _ReplyQuote(reply: m.reply!, mine: mine, onTap: () => onReplyTap(m.reply!.id)),
            if (editing)
              _EditBox(initial: m.body, mine: mine, onSave: onEditSave!, onCancel: onEditCancel!)
            else if (text.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(right: mine || m.reply != null ? 16 : 0),
                child: _MentionText(text: text, style: talkText(14.72, FontWeight.w400, ink, height: 1.45), c: c),
              ),
            if (chips.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final ch in chips)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      // `.talk-chip`: var(--talk-chip-bg) / var(--talk-chip-ink) — balon rengi ne olursa olsun aynı
                      decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(999)),
                      child: Text(ch, style: talkText(12, FontWeight.w700, c.accentContrast)),
                    ),
                ]),
              ),
            if (images.isNotEmpty || others.isNotEmpty || gifs.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: mediaOnly || text.isEmpty ? 0 : 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (images.length == 1) _SingleImage(api: api, a: images.first, maxWidth: maxWidth - 24),
                  if (images.length > 1) _ImageGrid(api: api, images: images, width: maxWidth - 24),
                  for (final a in others)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: a.isAudio
                          ? TalkVoicePlayer(url: api.fileUrl(a.path), ink: ink)
                          : (a.isVideo ? _VideoTile(api: api, a: a, width: maxWidth - 24) : TalkFileCard(api: api, a: a, mine: mine)),
                    ),
                  for (final g in gifs)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 280),
                        child: Image.network(g, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox(width: 120, height: 80)),
                      ),
                    ),
                ]),
              ),
            if (m.reactions.where((r) => r.count > 0).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(spacing: 4, runSpacing: 4, children: [
                  for (final r in m.reactions.where((r) => r.count > 0))
                    GestureDetector(
                      onTap: () => onReact(r.emoji),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: r.mine
                              ? TalkColors.reactMine.withValues(alpha: 0.15)
                              : (c.dark ? const Color(0x2E000000) : const Color(0xB3FFFFFF)),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: r.mine ? TalkColors.reactMine : c.line),
                        ),
                        child: Text('${r.emoji} ${r.count}', style: talkText(12.48, FontWeight.w400, ink, height: 1.4)),
                      ),
                    ),
                ]),
              ),
            if (!onMedia)
              Padding(padding: const EdgeInsets.only(top: 2), child: Align(alignment: Alignment.centerRight, child: foot)),
          ]),
          if (onMedia)
            Positioned(
              right: 8,
              bottom: gifOnly ? 6 : -10,
              child: DefaultTextStyle.merge(
                style: const TextStyle(shadows: [Shadow(color: Color(0x8C000000), blurRadius: 2, offset: Offset(0, 1))]),
                child: mediaFoot,
              ),
            ),
        ]),
      ),
    );

    final row = Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth + 42),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!mine && group) ...[avatar, const SizedBox(width: 8)],
            Flexible(child: bubble),
          ],
        ),
      ),
    );
    if (onSwipeReply == null || editing) return row;
    return _SwipeToReply(onReply: onSwipeReply!, child: row);
  }
}

/// Sesli mesaj: oynat/durdur, ilerleme çubuğu ve süre.
class TalkVoicePlayer extends StatefulWidget {
  const TalkVoicePlayer({super.key, required this.url, required this.ink});
  final String url;
  final Color ink;

  @override
  State<TalkVoicePlayer> createState() => _TalkVoicePlayerState();
}

class _TalkVoicePlayerState extends State<TalkVoicePlayer> {
  final _p = AudioPlayer();
  final _subs = <StreamSubscription<Object?>>[];
  PlayerState _state = PlayerState.stopped;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Uint8List? _bytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _subs
      ..add(_p.onPlayerStateChanged.listen((s) => setState(() => _state = s)))
      ..add(_p.onPositionChanged.listen((d) => setState(() => _pos = d)))
      ..add(_p.onDurationChanged.listen((d) => setState(() => _dur = d)))
      ..add(_p.onPlayerComplete.listen((_) => setState(() => _pos = Duration.zero)));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _p.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_state == PlayerState.playing) {
      await _p.pause();
      return;
    }
    if (_busy) return;
    _busy = true;
    try {
      if (_bytes == null) {
        final r = await http.get(Uri.parse(widget.url));
        if (r.statusCode != 200 || r.bodyBytes.isEmpty) return;
        _bytes = r.bodyBytes;
      }
      await _p.setAudioContext(AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
      ));
      await _p.play(BytesSource(_bytes!, mimeType: 'audio/mp4'), position: _pos);
    } catch (e) {
      debugPrint('[voice] $e');
    } finally {
      _busy = false;
    }
  }

  String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final playing = _state == PlayerState.playing;
    final total = _dur.inMilliseconds;
    return SizedBox(
      width: 230,
      child: Row(children: [
        GestureDetector(
          onTap: _toggle,
          child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 34, color: widget.ink),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: SliderComponentShape.noOverlay,
              activeTrackColor: TalkColors.ticks,
              inactiveTrackColor: widget.ink.withValues(alpha: 0.25),
              thumbColor: TalkColors.ticks,
            ),
            child: Slider(
              value: total <= 0 ? 0 : (_pos.inMilliseconds / total).clamp(0.0, 1.0),
              onChanged: total <= 0 ? null : (v) => _p.seek(Duration(milliseconds: (v * total).round())),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(_fmt(playing || _pos > Duration.zero ? _pos : _dur), style: talkText(11.5, FontWeight.w500, widget.ink.withValues(alpha: 0.75))),
      ]),
    );
  }
}

/// Mesajı sağa çekince yanıt ikonu belirir; eşiği geçip bırakınca yanıtlanır.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({required this.onReply, required this.child});
  final VoidCallback onReply;
  final Widget child;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> with SingleTickerProviderStateMixin {
  static const _max = 80.0;
  static const _trigger = 56.0;
  late final AnimationController _back;
  double _dx = 0;
  double _from = 0;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))
      ..addListener(() {
        if (!mounted) return;
        setState(() => _dx = _from * (1 - Curves.easeOut.transform(_back.value)));
      });
  }

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    _back.stop();
    final next = (_dx + d.delta.dx).clamp(0.0, _max);
    if (!_armed && next >= _trigger) {
      _armed = true;
      HapticFeedback.lightImpact();
    } else if (_armed && next < _trigger) {
      _armed = false;
    }
    setState(() => _dx = next);
  }

  void _end([DragEndDetails? _]) {
    if (_armed) widget.onReply();
    _armed = false;
    _from = _dx;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    final p = (_dx / _trigger).clamp(0.0, 1.0);
    return GestureDetector(
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _end,
      child: Stack(alignment: Alignment.centerLeft, children: [
        if (_dx > 0)
          Positioned(
            left: 4,
            child: Opacity(
              opacity: p,
              child: Transform.scale(
                scale: 0.6 + 0.4 * p,
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: c.accentSoft, shape: BoxShape.circle),
                  child: TalkIcon(TalkSvg.reply, size: 16, color: c.ink),
                ),
              ),
            ),
          ),
        Transform.translate(offset: Offset(_dx, 0), child: widget.child),
      ]),
    );
  }
}

/// @Ad Soyad → `.talk-mention`; bağlantılar tıklanınca tarayıcıda açılır.
class _MentionText extends StatefulWidget {
  const _MentionText({required this.text, required this.style, required this.c});
  final String text;
  final TextStyle style;
  final TalkColors c;

  @override
  State<_MentionText> createState() => _MentionTextState();
}

class _MentionTextState extends State<_MentionText> {
  static final _re = RegExp(r'(https?://[^\s<>"]+|www\.[^\s<>"]+)|@([A-Za-zÇĞİÖŞÜçğıöşü0-9_]+(?:\s+[A-Za-zÇĞİÖŞÜçğıöşü0-9_]+)?)');
  final _taps = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final t in _taps) {
      t.dispose();
    }
    super.dispose();
  }

  void _open(String raw) {
    // cümle sonundaki noktalama bağlantıya dahil değil
    final link = raw.replaceFirst(RegExp(r'[.,;:!?)\]]+$'), '');
    final uri = Uri.tryParse(link.startsWith('http') ? link : 'https://$link');
    if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
    final text = widget.text;
    final style = widget.style;
    final c = widget.c;
    final spans = <InlineSpan>[];
    var i = 0;
    for (final m in _re.allMatches(text)) {
      if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
      final url = m.group(1);
      if (url != null) {
        final tap = TapGestureRecognizer()..onTap = () => _open(url);
        _taps.add(tap);
        spans.add(TextSpan(
          text: url,
          recognizer: tap,
          style: TextStyle(color: c.dark ? const Color(0xFF53BDEB) : const Color(0xFF027EB5), decoration: TextDecoration.underline),
        ));
      } else {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(color: c.mentionBg, borderRadius: BorderRadius.circular(4)),
            child: Text(m.group(0)!, style: style.copyWith(fontWeight: FontWeight.w700, color: c.mentionInk)),
          ),
        ));
      }
      i = m.end;
    }
    if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

/// `.talk-reply-quote`
class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.reply, required this.mine, required this.onTap});
  final TalkReply reply;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    final ink = mine ? c.bubbleOutInk : c.bubbleInInk;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: mine ? const Color(0x1A000000) : (c.dark ? const Color(0x1F000000) : const Color(0x0F000000)),
          borderRadius: BorderRadius.circular(7),
        ),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 4, color: mine ? const Color(0x8CFFFFFF) : TalkColors.ticks),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(reply.displayName.isEmpty ? 'Mesaj' : reply.displayName,
                      style: talkText(12.48, FontWeight.w600, mine ? const Color(0xEBFFFFFF) : TalkColors.ticks)),
                  const SizedBox(height: 1),
                  Opacity(
                    opacity: 0.85,
                    child: Text(reply.body.isEmpty ? 'Mesaj' : reply.body,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: talkText(12.48, FontWeight.w400, ink)),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// `.talk-msg-edit`
class _EditBox extends StatefulWidget {
  const _EditBox({required this.initial, required this.mine, required this.onSave, required this.onCancel});
  final String initial;
  final bool mine;
  final void Function(String) onSave;
  final VoidCallback onCancel;

  @override
  State<_EditBox> createState() => _EditBoxState();
}

class _EditBoxState extends State<_EditBox> {
  late final _t = TextEditingController(text: widget.initial);
  final _f = FocusNode();

  @override
  void initState() {
    super.initState();
    // web: ta.focus() + imleç sona
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _f.requestFocus();
      _t.selection = TextSelection.collapsed(offset: _t.text.length);
    });
  }

  @override
  void dispose() {
    _f.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        TextField(
          controller: _t,
          focusNode: _f,
          minLines: 2,
          maxLines: 6,
          maxLength: 8000,
          style: talkText(14.72, FontWeight.w400, c.dark ? Colors.white : const Color(0xFF111111)),
          decoration: InputDecoration(
            counterText: '',
            isDense: true,
            filled: true,
            fillColor: c.dark ? const Color(0x2E000000) : const Color(0xD9FFFFFF),
            contentPadding: const EdgeInsets.all(8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.dark ? const Color(0x33FFFFFF) : const Color(0x1F000000))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.dark ? const Color(0x33FFFFFF) : const Color(0x1F000000))),
          ),
        ),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: [
          _pill('İptal', const Color(0x33808080), widget.mine ? c.bubbleOutInk : c.bubbleInInk, widget.onCancel),
          const SizedBox(width: 8),
          _pill('Kaydet', c.dark ? const Color(0xFFE8EEFC) : Colors.white, const Color(0xFF111111), () => widget.onSave(_t.text)),
        ]),
      ]),
    );
  }

  Widget _pill(String t, Color bg, Color fg, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
          child: Text(t, style: talkText(13.12, FontWeight.w700, fg)),
        ),
      );
}

class _SingleImage extends StatelessWidget {
  const _SingleImage({required this.api, required this.a, required this.maxWidth});
  final TalkApi api;
  final TalkAttachment a;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final url = api.fileUrl(a.path);
    return GestureDetector(
      onTap: () => openTalkImage(context, url, a.origName),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth > 420 ? 420 : maxWidth, maxHeight: MediaQuery.sizeOf(context).height * 0.72),
          child: Container(
            color: const Color(0xFF0B141A),
            child: Image.network(url, fit: BoxFit.contain,
                loadingBuilder: (_, child, p) => p == null ? child : const SizedBox(width: 220, height: 160),
                errorBuilder: (_, _, _) => const SizedBox(width: 160, height: 120)),
          ),
        ),
      ),
    );
  }
}

/// `.talk-img-grid--n2/n3/n4` (+N kaplaması)
class _ImageGrid extends StatelessWidget {
  const _ImageGrid({required this.api, required this.images, required this.width});
  final TalkApi api;
  final List<TalkAttachment> images;
  final double width;

  @override
  Widget build(BuildContext context) {
    final w = width > 420 ? 420.0 : width;
    final shown = images.take(4).toList();
    final extra = images.length > 4 ? images.length - 4 : 0;
    Widget cell(int i, {double? aspect}) {
      final a = shown[i];
      final url = api.fileUrl(a.path);
      final img = Stack(fit: StackFit.expand, children: [
        Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => Container(color: const Color(0xFF111B21))),
        if (extra > 0 && i == 3)
          Container(
            color: const Color(0x8C0B141A),
            alignment: Alignment.center,
            child: Text('+$extra', style: talkText(25.6, FontWeight.w700, Colors.white)),
          ),
      ]);
      return GestureDetector(
        onTap: () => openTalkImage(context, url, a.origName),
        child: AspectRatio(aspectRatio: aspect ?? 3 / 4, child: Container(color: const Color(0xFF111B21), child: img)),
      );
    }

    const gap = 3.0;
    final rows = <Widget>[];
    if (shown.length == 3) {
      rows.add(cell(0, aspect: 16 / 10));
      rows.add(const SizedBox(height: gap));
      rows.add(Row(children: [Expanded(child: cell(1)), const SizedBox(width: gap), Expanded(child: cell(2))]));
    } else {
      for (var i = 0; i < shown.length; i += 2) {
        if (i > 0) rows.add(const SizedBox(height: gap));
        rows.add(Row(children: [
          Expanded(child: cell(i)),
          const SizedBox(width: gap),
          Expanded(child: i + 1 < shown.length ? cell(i + 1) : const SizedBox()),
        ]));
      }
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(width: w, color: const Color(0x40000000), child: Column(children: rows)),
    );
  }
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.api, required this.a, required this.width});
  final TalkApi api;
  final TalkAttachment a;
  final double width;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => launchUrl(Uri.parse(api.fileUrl(a.path)), mode: LaunchMode.externalApplication),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: width > 420 ? 420 : width,
            height: 180,
            color: const Color(0xFF0B141A),
            alignment: Alignment.center,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 48),
              const SizedBox(height: 6),
              Text(a.origName, maxLines: 1, overflow: TextOverflow.ellipsis, style: talkText(12, FontWeight.w600, Colors.white70)),
            ]),
          ),
        ),
      );
}

/// `.talk-file` — uzantı rozeti, ad, boyut, indirme ikonu
class TalkFileCard extends StatelessWidget {
  const TalkFileCard({super.key, required this.api, required this.a, this.mine = false});
  final TalkApi api;
  final TalkAttachment a;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    // arcon-talk-demo.css: .talk-file / html:not(.dark) .talk-msg.is-mine .talk-file / html.dark .talk-msg.is-mine .talk-file
    final (Color bg, Color border, Color ink, Color sub, Color icoBg, Color icoInk) = switch ((c.dark, mine)) {
      (false, true) => (const Color(0x14FFFFFF), const Color(0x29FFFFFF), Colors.white, const Color(0xB3FFFFFF), Colors.white, const Color(0xFF111111)),
      (true, true) => (const Color(0x0F000000), const Color(0x1A000000), const Color(0xFF111111), c.muted, const Color(0xFF111111), Colors.white),
      (false, false) => (const Color(0xFFFAFAFA), c.line, c.bubbleInInk, c.muted, c.accent, c.accentContrast),
      (true, false) => (const Color(0x2E000000), const Color(0x14FFFFFF), c.bubbleInInk, c.muted, c.accent, c.accentContrast),
    };
    final dl = mine && !c.dark ? const Color(0xB3FFFFFF) : const Color(0xFF8696A0);
    return GestureDetector(
      onTap: () => openTalkFile(context, api.fileUrl(a.path), a.origName),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: border)),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: icoBg, borderRadius: BorderRadius.circular(10)),
            child: Text(a.ext, style: talkText(10.88, FontWeight.w800, icoInk)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.origName, maxLines: 1, overflow: TextOverflow.ellipsis, style: talkText(14.08, FontWeight.w700, ink)),
              const SizedBox(height: 2),
              Text(talkFmtSize(a.sizeBytes), style: talkText(11.84, FontWeight.w400, sub)),
            ]),
          ),
          const SizedBox(width: 12),
          SizedBox(width: 36, height: 36, child: Center(child: TalkIcon(TalkSvg.download, size: 16, color: dl))),
        ]),
      ),
    );
  }
}

void openTalkImage(BuildContext context, String url, String name) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(name, style: talkText(15, FontWeight.w600, Colors.white)),
          actions: [IconButton(icon: const TalkIcon(TalkSvg.download, size: 20, color: Colors.white), onPressed: () => openTalkFile(context, url, name))],
        ),
        body: InteractiveViewer(maxScale: 5, child: Center(child: Image.network(url))),
      ),
    ));

/// Dosyayı indirip telefonun ilgili uygulamasında aç (web: `download` linki).
Future<void> openTalkFile(BuildContext context, String url, String name) async {
  try {
    final res = await http.get(Uri.parse(url));
    if (res.statusCode != 200) throw Exception('${res.statusCode}');
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/${name.replaceAll(RegExp(r'[/\\]'), '_')}');
    await f.writeAsBytes(res.bodyBytes);
    await OpenFilex.open(f.path);
  } on Exception {
    if (context.mounted) talkToast(context, 'Dosya açılamadı', error: true);
  }
}

/// Mesaj menüsü — WhatsApp gibi alttan açılır: üstte hızlı tepkiler, altta işlemler.
/// [decided]: grupta Kararlar/Görevler menüsü (null: gösterme; true: zaten karar).
Future<String?> showTalkMessageMenu(BuildContext context, {required bool mine, required bool canCopy, bool canForward = true, bool? decided}) {
  final c = TalkColors.of(context);
  final fg = c.dark ? const Color(0xFFE9EDEF) : const Color(0xFF111111);
  final sep = c.dark ? const Color(0x14FFFFFF) : const Color(0x14000000);
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: c.dark ? const Color(0xFF233138) : Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) {
      Widget item(String act, String svg, String label, {bool danger = false}) => InkWell(
            onTap: () => Navigator.pop(ctx, act),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(children: [
                TalkIcon(svg, size: 20, color: danger ? TalkColors.danger : fg),
                const SizedBox(width: 16),
                Text(label, style: talkText(15.5, FontWeight.w600, danger ? TalkColors.danger : fg)),
              ]),
            ),
          );
      return SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 6),
              decoration: BoxDecoration(color: sep, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              for (final e in talkQuickReact)
                GestureDetector(
                  onTap: () => Navigator.pop(ctx, 'react:$e'),
                  child: SizedBox(width: 42, height: 42, child: Center(child: Text(e, style: const TextStyle(fontSize: 26, height: 1)))),
                ),
              GestureDetector(
                onTap: () => Navigator.pop(ctx, 'react-more'),
                child: Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: c.dark ? const Color(0x14FFFFFF) : const Color(0xFFE9EDEF), shape: BoxShape.circle),
                  child: Text('+', style: talkText(20, FontWeight.w700, fg, height: 1)),
                ),
              ),
            ]),
          ),
          Container(height: 1, color: sep),
          item('reply', TalkSvg.reply, 'Yanıtla'),
          if (canCopy) item('copy', TalkSvg.msg, 'Kopyala'),
          if (canForward) item('forward', TalkSvg.send, 'İlet'),
          if (decided != null) ...[
            item('decision', TalkSvg.decisions, decided ? 'Kararı kaldır' : 'Karar olarak işaretle'),
            item('task', TalkSvg.tasks, 'Görev yap'),
          ],
          if (mine) ...[
            item('info', TalkSvg.check, 'Bilgi'),
            item('edit', TalkSvg.edit, 'Düzenle'),
            item('delete', TalkSvg.trash, 'Sil', danger: true),
          ],
          const SizedBox(height: 6),
        ]),
      );
    },
  );
}

/// Emoji seçici (`emoji-picker-element` karşılığı) — seçilen emojiyi döner.
Future<String?> showTalkEmojiPicker(BuildContext context) {
  final c = TalkColors.of(context);
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: c.dark ? const Color(0xFF1F2C34) : Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
    builder: (ctx) => SizedBox(
      height: 340,
      child: EmojiPicker(
        onEmojiSelected: (_, e) => Navigator.pop(ctx, e.emoji),
        config: talkEmojiConfig(c),
      ),
    ),
  );
}

Config talkEmojiConfig(TalkColors c) => Config(
      emojiViewConfig: EmojiViewConfig(
        backgroundColor: c.dark ? const Color(0xFF1F2C34) : Colors.white,
        emojiSizeMax: 24,
        columns: 8,
      ),
      categoryViewConfig: CategoryViewConfig(
        backgroundColor: c.dark ? const Color(0xFF1F2C34) : Colors.white,
        indicatorColor: TalkColors.wa,
        iconColorSelected: TalkColors.wa,
        iconColor: c.dark ? const Color(0xFF8696A0) : const Color(0xFF667781),
      ),
      bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
      searchViewConfig: SearchViewConfig(backgroundColor: c.dark ? const Color(0xFF1F2C34) : Colors.white),
    );

/// Kendi mesajının durumu (WhatsApp): gönderiliyor, sunucuya ulaştı, karşıya iletildi, okundu, gönderilemedi.
enum TalkTick { pending, sent, delivered, read, failed }

class _TickMark extends StatelessWidget {
  const _TickMark({required this.tick, required this.color, this.onMedia = false});

  final TalkTick tick;
  final Color color;
  final bool onMedia;

  @override
  Widget build(BuildContext context) {
    final dim = onMedia ? 0.95 : 0.6;
    return switch (tick) {
      TalkTick.pending => Opacity(opacity: dim, child: TalkIcon(TalkSvg.pendingClock, size: 12, color: color)),
      TalkTick.sent => Opacity(opacity: dim, child: TalkIcon(TalkSvg.tick, width: 16, height: 11, color: color)),
      TalkTick.delivered => Opacity(opacity: dim, child: TalkIcon(TalkSvg.ticks, width: 16, height: 11, color: color)),
      TalkTick.read => Opacity(opacity: 0.95, child: TalkIcon(TalkSvg.ticks, width: 16, height: 11, color: TalkColors.ticks)),
      TalkTick.failed => const Icon(Icons.error_outline, size: 14, color: Color(0xFFEF4444)),
    };
  }
}

/// Sohbetteki arama satırı (WhatsApp): simge, "Sesli arama" / "Cevapsız sesli arama", süre, saat.
class TalkCallLineView extends StatelessWidget {
  const TalkCallLineView({super.key, required this.line, required this.mine, required this.time, required this.onTap});

  final ({bool video, bool missed, String duration}) line;
  final bool mine;
  final String time;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    final ink = mine ? c.bubbleOutInk : c.bubbleInInk;
    final kind = line.video ? 'Görüntülü arama' : 'Sesli arama';
    final title = line.missed ? (mine ? kind : 'Cevapsız ${kind.toLowerCase()}') : kind;
    final sub = line.missed ? (mine ? 'Cevap yok' : 'Geri aramak için dokun') : line.duration;
    final red = line.missed && !mine;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 210, maxWidth: 260),
          padding: const EdgeInsets.fromLTRB(10, 10, 12, 8),
          decoration: BoxDecoration(color: mine ? c.bubbleOut : c.bubbleIn, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: ink.withValues(alpha: 0.08), shape: BoxShape.circle),
              child: Icon(
                line.missed ? (line.video ? Icons.missed_video_call : Icons.phone_missed) : (line.video ? Icons.videocam : Icons.call),
                size: 19,
                color: red ? const Color(0xFFE11D48) : ink,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: talkText(14.5, FontWeight.w600, red ? const Color(0xFFE11D48) : ink)),
                if (sub.isNotEmpty) Text(sub, style: talkText(12.5, FontWeight.w400, ink.withValues(alpha: 0.65))),
              ]),
            ),
            const SizedBox(width: 6),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(time, style: talkText(10.88, FontWeight.w400, ink.withValues(alpha: 0.55), height: 1)),
            ),
          ]),
        ),
      ),
    );
  }
}
