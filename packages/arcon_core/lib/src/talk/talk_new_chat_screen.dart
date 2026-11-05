import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import 'talk_controller.dart';
import 'talk_models.dart';
import 'talk_pickers.dart';
import 'talk_theme.dart';
import 'talk_widgets.dart';

/// WhatsApp iOS "Yeni sohbet": üstte "Yeni grup", altında ARCONNECT'teki kişiler.
/// Açılan sohbetin id'sini döner.
class TalkNewChatScreen extends StatefulWidget {
  const TalkNewChatScreen({super.key, required this.controller});
  final TalkController controller;

  @override
  State<TalkNewChatScreen> createState() => _TalkNewChatScreenState();
}

class _TalkNewChatScreenState extends State<TalkNewChatScreen> {
  int _busy = 0;

  Future<void> _openDm(TalkUser u) async {
    if (_busy != 0) return;
    setState(() => _busy = u.id);
    try {
      final ch = await widget.controller.api.openDm(u.id);
      if (ch != null) widget.controller.upsertChannel(ch);
      if (mounted) Navigator.pop(context, ch?.id);
    } on ArconApiException catch (e) {
      if (mounted) {
        talkToast(context, e.message.isEmpty ? 'Sohbet açılamadı' : e.message, error: true);
        setState(() => _busy = 0);
      }
    }
  }

  Future<void> _newGroup() async {
    final id = await showNewGroupSheet(context, widget.controller);
    if (mounted && id != null && id > 0) Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) => _PeopleList(
        controller: widget.controller,
        title: 'Yeni sohbet',
        busyId: _busy,
        onPick: _openDm,
        showMe: true,
        actions: [(CupertinoIcons.person_2, 'Yeni grup', _newGroup)],
      );
}

/// Kişi seç (arama için): seçilen kişiyi döner.
class TalkUserPickerScreen extends StatelessWidget {
  const TalkUserPickerScreen({super.key, required this.controller, required this.title, this.favouritesOnly = false});
  final TalkController controller;
  final String title;

  /// Yalnızca favorilere eklenmiş birebir sohbetlerdeki kişiler
  final bool favouritesOnly;

  @override
  Widget build(BuildContext context) {
    Set<int>? only;
    if (favouritesOnly) {
      only = {
        for (final ch in controller.channels)
          if (ch.isDm && ch.peer != null && controller.favourites.contains(ch.id)) ch.peer!.id,
      };
    }
    return _PeopleList(
      controller: controller,
      title: title,
      only: only,
      emptyText: favouritesOnly ? 'Favori kişi yok.\nSohbetler listesinde bir kişiye basılı tutup “Favori”ye ekle.' : null,
      onPick: (u) => Navigator.pop(context, u),
    );
  }
}

/// Sohbet seç (kameradan çekilen fotoğrafı göndermek için): seçilen sohbeti döner.
class TalkChatPickerScreen extends StatefulWidget {
  const TalkChatPickerScreen({super.key, required this.controller});
  final TalkController controller;

  @override
  State<TalkChatPickerScreen> createState() => _TalkChatPickerScreenState();
}

class _TalkChatPickerScreenState extends State<TalkChatPickerScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    final q = _q.trim().toLowerCase();
    final list = widget.controller.channels.where((ch) => q.isEmpty || ch.name.toLowerCase().contains(q)).toList();
    return Scaffold(
      backgroundColor: c.rail,
      appBar: _sheetBar(context, c, 'Gönder…'),
      body: ListView(children: [
        _SearchBox(hint: 'Ara', onChanged: (v) => setState(() => _q = v)),
        for (final ch in list)
          _Row(
            avatar: ch.isDm || ch.photo.isNotEmpty
                ? TalkAvatar.solid(name: ch.name, photoUrl: widget.controller.api.fileUrl(ch.photo), size: 44, personIfEmpty: true)
                : _groupAvatar(c, 44),
            title: ch.name,
            subtitle: ch.isDm ? '' : '${ch.memberCount} üye',
            onTap: () => Navigator.pop(context, ch),
          ),
      ]),
    );
  }
}

// ---------- ortak parçalar ----------

PreferredSizeWidget _sheetBar(BuildContext context, TalkColors c, String title, {String? subtitle}) => AppBar(
      backgroundColor: c.rail,
      foregroundColor: c.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: c.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      automaticallyImplyLeading: false,
      centerTitle: true,
      title: Column(children: [
        Text(title, style: talkText(17, FontWeight.w600, c.ink)),
        if (subtitle != null) Text(subtitle, style: talkText(12.5, FontWeight.w400, c.muted)),
      ]),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: c.searchBg, shape: BoxShape.circle),
              child: Icon(Icons.close, size: 20, color: c.ink),
            ),
          ),
        ),
      ],
    );

Widget _groupAvatar(TalkColors c, double size) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.dark ? const Color(0xFF2C2C2E) : const Color(0xFFEBEBEF), shape: BoxShape.circle),
      child: Icon(CupertinoIcons.person_2_fill, size: size * 0.52, color: c.dark ? const Color(0xFFAEAEB2) : const Color(0xFF6E6E73)),
    );

class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    return Container(
      height: 40,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: c.searchBg, borderRadius: BorderRadius.circular(999)),
      child: Row(children: [
        Icon(CupertinoIcons.search, size: 20, color: c.muted),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            onChanged: onChanged,
            style: talkText(17, FontWeight.w400, c.ink),
            cursorColor: c.ink,
            decoration: InputDecoration(
              isCollapsed: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              hintText: hint,
              hintStyle: talkText(17, FontWeight.w400, c.muted),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.avatar, required this.title, this.subtitle = '', required this.onTap, this.trailing, this.bold = false});
  final Widget avatar;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Row(children: [
          avatar,
          const SizedBox(width: 14),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 60),
              padding: const EdgeInsets.fromLTRB(0, 8, 16, 8),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.rowLine, width: 0.6))),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: talkText(17, bold ? FontWeight.w500 : FontWeight.w400, c.ink)),
                    if (subtitle.isNotEmpty) Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: talkText(14, FontWeight.w400, c.muted)),
                  ]),
                ),
                ?trailing,
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _PeopleList extends StatefulWidget {
  const _PeopleList({
    required this.controller,
    required this.title,
    required this.onPick,
    this.actions = const [],
    this.only,
    this.busyId = 0,
    this.emptyText,
    this.showMe = false,
  });
  final TalkController controller;
  final String title;
  final void Function(TalkUser u) onPick;
  final List<(IconData, String, VoidCallback)> actions;
  final Set<int>? only;
  final int busyId;
  final String? emptyText;

  /// WhatsApp gibi listenin başında "Ad (Siz) · Kendinize mesaj gönderin"
  final bool showMe;

  @override
  State<_PeopleList> createState() => _PeopleListState();
}

class _PeopleListState extends State<_PeopleList> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final c = TalkColors.of(context);
    final meUser = widget.controller.me;
    final me = meUser?.id;
    final q = _q.trim().toLowerCase();
    final showMe =
        widget.showMe && meUser != null && (q.isEmpty || '${meUser.displayName} ${meUser.username} siz'.toLowerCase().contains(q));
    final people = widget.controller.users
        .where((u) => u.id != me && (widget.only == null || widget.only!.contains(u.id)))
        .where((u) => q.isEmpty || '${u.displayName} ${u.username} ${u.department}'.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return Scaffold(
      backgroundColor: c.rail,
      appBar: _sheetBar(context, c, widget.title, subtitle: '${people.length} kişi'),
      body: ListView(children: [
        _SearchBox(hint: 'Ad veya kullanıcı adı ara', onChanged: (v) => setState(() => _q = v)),
        if (q.isEmpty)
          for (final (icon, label, onTap) in widget.actions)
            _Row(
              avatar: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: c.searchBg, shape: BoxShape.circle),
                child: Icon(icon, size: 22, color: c.ink),
              ),
              title: label,
              bold: true,
              onTap: onTap,
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Text("ARCONNECT'teki kişiler", style: talkText(14, FontWeight.w600, c.muted)),
        ),
        if (showMe)
          _Row(
            avatar: TalkAvatar.solid(name: meUser.displayName, photoUrl: widget.controller.api.fileUrl(meUser.avatarPath), size: 44, personIfEmpty: true),
            title: '${meUser.displayName} (Siz)',
            subtitle: 'Kendinize mesaj gönderin',
            trailing: widget.busyId == meUser.id ? CupertinoActivityIndicator(color: c.muted) : null,
            onTap: () => widget.onPick(meUser),
          ),
        for (final u in people)
          _Row(
            avatar: TalkAvatar.solid(name: u.displayName, photoUrl: widget.controller.api.fileUrl(u.avatarPath), size: 44, personIfEmpty: true),
            title: u.displayName,
            subtitle: u.about.trim().isNotEmpty ? u.about.trim() : (u.department.trim().isNotEmpty ? u.department.trim() : '@${u.username}'),
            trailing: widget.busyId == u.id ? CupertinoActivityIndicator(color: c.muted) : null,
            onTap: () => widget.onPick(u),
          ),
        if (people.isEmpty && !showMe)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(widget.emptyText ?? (q.isEmpty ? 'Kişi yok' : 'Sonuç yok'), textAlign: TextAlign.center, style: talkText(15, FontWeight.w400, c.muted)),
          ),
      ]),
    );
  }
}
