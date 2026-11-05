import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../auth/session_controller.dart';
import '../config.dart';
import 'theme.dart';

/// Web paneliyle aynı hesap: kullanıcı adı veya e-posta + şifre.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.config, required this.session});

  final ArconAppConfig config;
  final SessionController session;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 980));
  final _form = GlobalKey<FormState>();
  final _login = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.config.appKey == 'arconnect') _enter.forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.login(
        _login.text,
        _password.text,
        deviceName: '${Platform.operatingSystem} · ${widget.config.title}',
      );
    } on ArconApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.config.appKey == 'arconnect') return _buildConnect();
    return _buildClassic(context);
  }

  Widget _buildConnect() {
    final theme = Theme.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Theme(
        data: theme.copyWith(
          brightness: Brightness.dark,
          textSelectionTheme: const TextSelectionThemeData(cursorColor: Colors.white, selectionColor: Color(0x44FFFFFF)),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0x14FFFFFF),
            labelStyle: const TextStyle(color: Color(0xB3FFFFFF), fontWeight: FontWeight.w500),
            floatingLabelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            prefixIconColor: const Color(0xD9FFFFFF),
            suffixIconColor: const Color(0xD9FFFFFF),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: const BorderSide(color: Color(0x2EFFFFFF))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: const BorderSide(color: Colors.white, width: 1.4)),
            errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: const BorderSide(color: Color(0xFFFF8A80))),
            focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: const BorderSide(color: Color(0xFFFF8A80))),
          ),
        ),
        child: Scaffold(
          backgroundColor: const Color(0xFF050608),
          body: Stack(
            children: [
              const Positioned.fill(child: _ConnectGlow()),
              SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: AnimatedBuilder(
                        animation: _enter,
                        builder: (context, _) {
                          return Form(
                            key: _form,
                            child: AutofillGroup(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _rise(0, const _ConnectMark()),
                                  const SizedBox(height: 28),
                                  _rise(0.12, _glassCard(theme)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rise(double start, Widget child) {
    final t = Curves.easeOutCubic.transform(((_enter.value - start) / (1 - start)).clamp(0.0, 1.0));
    return Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, (1 - t) * 22), child: child),
    );
  }

  Widget _glassCard(ThemeData theme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          decoration: BoxDecoration(
            color: const Color(0x1AFFFFFF),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _login,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                autofillHints: const [AutofillHints.username, AutofillHints.email],
                keyboardType: TextInputType.emailAddress,
                keyboardAppearance: Brightness.dark,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Kullanıcı adı veya e-posta',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Bu alan gerekli' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                obscureText: _obscure,
                keyboardAppearance: Brightness.dark,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Şifre',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    tooltip: _obscure ? 'Şifreyi göster' : 'Şifreyi gizle',
                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) => (v == null || v.isEmpty) ? 'Şifre gerekli' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 16),
              _ConnectButton(busy: _busy, onPressed: _submit),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClassic(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Align(alignment: Alignment.center, child: ArconLogo(height: 26)),
                      const SizedBox(height: 32),
                      Text(widget.config.title,
                          style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text('ARCON hesabınla giriş yap',
                          style: theme.textTheme.bodyLarge?.copyWith(color: ArconColors.muted)),
                      const SizedBox(height: 28),
                      TextFormField(
                        controller: _login,
                        autofillHints: const [AutofillHints.username, AutofillHints.email],
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Kullanıcı adı veya e-posta',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Bu alan gerekli' : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Şifre',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? 'Şifreyi göster' : 'Şifreyi gizle',
                            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) => (v == null || v.isEmpty) ? 'Şifre gerekli' : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Giriş yap'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectMark extends StatefulWidget {
  const _ConnectMark();

  @override
  State<_ConnectMark> createState() => _ConnectMarkState();
}

class _ConnectMarkState extends State<_ConnectMark> with SingleTickerProviderStateMixin {
  late final AnimationController _shine = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));

  @override
  void initState() {
    super.initState();
    _shine.repeat();
  }

  @override
  void dispose() {
    _shine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Image.asset(
          'assets/arcon_logo_dark.png',
          package: 'arcon_core',
          height: 22,
          semanticLabel: 'ARCON',
        ),
        const SizedBox(height: 22),
        AnimatedBuilder(
          animation: _shine,
          builder: (context, child) {
            final dx = -1.3 + _shine.value * 2.6;
            return ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (rect) => LinearGradient(
                begin: Alignment(dx, -0.3),
                end: Alignment(dx + 0.55, 0.3),
                colors: const [Colors.white, Color(0xFFC5D0DA), Colors.white],
                stops: const [0.2, 0.5, 0.8],
              ).createShader(rect),
              child: child,
            );
          },
          child: const Text(
            'ARCONNECT',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w800, letterSpacing: 1.6, height: 1),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'ARCON hesabınla giriş yap',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

class _ConnectGlow extends StatefulWidget {
  const _ConnectGlow();

  @override
  State<_ConnectGlow> createState() => _ConnectGlowState();
}

class _ConnectGlowState extends State<_ConnectGlow> with TickerProviderStateMixin {
  static const _brands = [
    'Dior',
    'Hermès',
    'Jean Paul Gaultier',
    'Sensai',
    'Carolina Herrera',
    'Rabanne',
    'Dolce&Gabbana',
    'La Prairie',
    'Givenchy',
    'Sisley Paris',
    'Paradis des Sens',
    'Dr. Barbara Sturm',
    'Penhaligon\'s',
    'Byredo',
    'L\'Artisan Parfumeur',
    'Dries Van Noten',
    'Scentologia',
  ];

  // üst şerit soldan sağa, alt şerit sağdan sola ve daha yavaş/soluk
  late final AnimationController _top = AnimationController(vsync: this, duration: const Duration(seconds: 60))..repeat();
  late final AnimationController _bottom = AnimationController(vsync: this, duration: const Duration(seconds: 180))..repeat();

  @override
  void dispose() {
    _top.dispose();
    _bottom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final half = _brands.length ~/ 2;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF050608)),
          // sabit, hafif ışık (dönen / kayan parıltı yok)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(-0.6, -0.95),
                radius: 1.05,
                colors: [Color(0xCC3A4352), Color(0x00050608)],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: pad.top + 18,
            child: _Marquee(names: _brands.sublist(0, half + 1), anim: _top, leftToRight: true, opacity: 0.42, fontSize: 15),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: pad.bottom + 18,
            child: _Marquee(names: _brands.sublist(half), anim: _bottom, leftToRight: false, opacity: 0.22, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// Sonsuz kayan marka şeridi; kenarlarda yumuşakça kaybolur.
class _Marquee extends StatelessWidget {
  const _Marquee({required this.names, required this.anim, required this.leftToRight, required this.opacity, required this.fontSize});

  final List<String> names;
  final Animation<double> anim;
  final bool leftToRight;
  final double opacity;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: const Color(0xFFE7EDF2).withValues(alpha: opacity),
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
    );
    final text = '${names.join('     ·     ')}     ·     ';
    final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, maxLines: 1)..layout();
    final w = tp.width;
    return IgnorePointer(
      child: SizedBox(
        height: tp.height + 4,
        child: ShaderMask(
          shaderCallback: (r) => const LinearGradient(
            colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
            stops: [0, 0.14, 0.86, 1],
          ).createShader(r),
          blendMode: BlendMode.dstIn,
          child: AnimatedBuilder(
            animation: anim,
            builder: (context, child) {
              final dx = leftToRight ? -w + anim.value * w : -anim.value * w;
              return OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: double.infinity,
                child: Transform.translate(offset: Offset(dx, 0), child: child),
              );
            },
            child: Text('$text$text$text', maxLines: 1, softWrap: false, style: style),
          ),
        ),
      ),
    );
  }
}

class _ConnectButton extends StatefulWidget {
  const _ConnectButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  State<_ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<_ConnectButton> with SingleTickerProviderStateMixin {
  late final AnimationController _sheen = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    _sheen.repeat();
  }

  @override
  void dispose() {
    _sheen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _sheen,
      builder: (context, child) {
        final dx = -1.5 + _sheen.value * 3;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment(dx, -0.4),
              end: Alignment(dx + 0.9, 0.5),
              colors: const [Color(0xFFE8EEF3), Color(0xFFFFFFFF), Color(0xFFC9D3DC), Color(0xFFFFFFFF)],
            ),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 22, offset: Offset(0, 10))],
          ),
          child: child,
        );
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.busy ? null : widget.onPressed,
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: 54,
            child: Center(
              child: widget.busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0B0D10)),
                    )
                  : const Text(
                      'Giriş yap',
                      style: TextStyle(color: Color(0xFF0B0D10), fontWeight: FontWeight.w800, fontSize: 16),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
