import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';
import 'settings_service.dart';
import 'i18n.dart';

/// Экран/диалог блокировки PIN-ом для доступа к скрытым папкам (секретным
/// альбомам). Хранится только хеш PIN-а (см. settings_service.dart) — здесь
/// только UI ввода и сверка.

const int _kPinLength = 4;
const int _kMaxAttemptsBeforeLock = 3;
const int _kLockSeconds = 15;

enum _PinDialogMode { verify, create }

/// Запросить у пользователя ввод текущего PIN. Возвращает true, если код
/// верный. Если PIN ещё не задан — защищать нечего, сразу true.
Future<bool> requestPin(BuildContext context, {String? subtitle}) async {
  if (!SettingsService.instance.hasPin) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _PinDialog(mode: _PinDialogMode.verify, subtitle: subtitle),
  );
  return ok ?? false;
}

/// Задать новый PIN (ввод + повторное подтверждение). true — PIN сохранён.
Future<bool> setNewPin(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => const _PinDialog(mode: _PinDialogMode.create),
  );
  return ok ?? false;
}

/// Сменить PIN: сперва проверка текущего, затем ввод нового.
Future<bool> changePin(BuildContext context) async {
  final verified = await requestPin(
    context,
    subtitle: tr('Подтвердите текущий PIN', 'Confirm your current PIN',
        'Confirma tu PIN actual'),
  );
  if (!verified || !context.mounted) return false;
  return setNewPin(context);
}

/// Снять защиту PIN-ом — только после ввода текущего кода.
Future<bool> removePin(BuildContext context) async {
  final verified = await requestPin(
    context,
    subtitle: tr(
        'Введите PIN, чтобы снять защиту',
        'Enter your PIN to remove protection',
        'Introduce el PIN para quitar la protección'),
  );
  if (!verified) return false;
  SettingsService.instance.clearPin();
  return true;
}

class _PinDialog extends StatefulWidget {
  final _PinDialogMode mode;
  final String? subtitle;
  const _PinDialog({required this.mode, this.subtitle});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

enum _Stage { first, confirm }

class _PinDialogState extends State<_PinDialog>
    with SingleTickerProviderStateMixin {
  String _digits = '';
  String? _firstPin; // код с первого ввода (режим создания)
  _Stage _stage = _Stage.first;
  String? _error;
  int _attempts = 0;
  Timer? _lockTimer;
  int _lockSecondsLeft = 0;

  late final AnimationController _shakeCtl;

  @override
  void initState() {
    super.initState();
    _shakeCtl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
  }

  @override
  void dispose() {
    _shakeCtl.dispose();
    _lockTimer?.cancel();
    super.dispose();
  }

  bool get _locked => _lockSecondsLeft > 0;

  String get _title {
    if (widget.mode == _PinDialogMode.verify) {
      return tr('Введите PIN', 'Enter PIN', 'Introduce el PIN');
    }
    return _stage == _Stage.first
        ? tr('Придумайте PIN', 'Choose a PIN', 'Elige un PIN')
        : tr('Повторите PIN', 'Confirm PIN', 'Confirma el PIN');
  }

  void _onDigit(String d) {
    if (_locked || _digits.length >= _kPinLength) return;
    setState(() {
      _digits += d;
      _error = null;
    });
    if (_digits.length == _kPinLength) {
      Future.delayed(const Duration(milliseconds: 110), _submit);
    }
  }

  void _onBackspace() {
    if (_locked || _digits.isEmpty) return;
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  Future<void> _submit() async {
    if (!mounted) return;
    final entered = _digits;

    if (widget.mode == _PinDialogMode.verify) {
      if (SettingsService.instance.verifyPin(entered)) {
        Navigator.of(context).pop(true);
      } else {
        _fail();
      }
      return;
    }

    // режим создания PIN
    if (_stage == _Stage.first) {
      setState(() {
        _firstPin = entered;
        _digits = '';
        _stage = _Stage.confirm;
      });
      return;
    }
    if (entered == _firstPin) {
      SettingsService.instance.setPin(entered);
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _error = tr('PIN не совпадает, попробуйте снова',
            "PINs don't match, try again",
            'Los PIN no coinciden, inténtalo de nuevo');
        _digits = '';
        _firstPin = null;
        _stage = _Stage.first;
      });
      _shakeCtl.forward(from: 0);
    }
  }

  void _fail() {
    _attempts++;
    setState(() {
      _digits = '';
      _error = tr('Неверный PIN', 'Wrong PIN', 'PIN incorrecto');
    });
    _shakeCtl.forward(from: 0);
    if (_attempts >= _kMaxAttemptsBeforeLock) {
      _startLock();
    }
  }

  void _startLock() {
    _attempts = 0;
    setState(() {
      _lockSecondsLeft = _kLockSeconds;
      _error = null;
    });
    _lockTimer?.cancel();
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _lockSecondsLeft--;
        if (_lockSecondsLeft <= 0) {
          _lockSecondsLeft = 0;
          t.cancel();
        }
      });
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.backspace) {
      _onBackspace();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop(false);
      return KeyEventResult.handled;
    }
    final digitKeys = {
      LogicalKeyboardKey.digit0: '0',
      LogicalKeyboardKey.numpad0: '0',
      LogicalKeyboardKey.digit1: '1',
      LogicalKeyboardKey.numpad1: '1',
      LogicalKeyboardKey.digit2: '2',
      LogicalKeyboardKey.numpad2: '2',
      LogicalKeyboardKey.digit3: '3',
      LogicalKeyboardKey.numpad3: '3',
      LogicalKeyboardKey.digit4: '4',
      LogicalKeyboardKey.numpad4: '4',
      LogicalKeyboardKey.digit5: '5',
      LogicalKeyboardKey.numpad5: '5',
      LogicalKeyboardKey.digit6: '6',
      LogicalKeyboardKey.numpad6: '6',
      LogicalKeyboardKey.digit7: '7',
      LogicalKeyboardKey.numpad7: '7',
      LogicalKeyboardKey.digit8: '8',
      LogicalKeyboardKey.numpad8: '8',
      LogicalKeyboardKey.digit9: '9',
      LogicalKeyboardKey.numpad9: '9',
    };
    final d = digitKeys[k];
    if (d != null) {
      _onDigit(d);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = AuroraTheme.of(context).colors;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Dialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: c.accentSoft, shape: BoxShape.circle),
              child: Icon(Icons.lock_outline_rounded, color: c.accentInk, size: 26),
            ),
            const SizedBox(height: 14),
            Text(_title,
                style: TextStyle(
                    color: c.text, fontSize: 17, fontWeight: FontWeight.w800)),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 6),
              Text(widget.subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted, fontSize: 12.5)),
            ],
            const SizedBox(height: 20),
            AnimatedBuilder(
              animation: _shakeCtl,
              builder: (ctx, child) {
                final t = _shakeCtl.value;
                final dx = t == 0 ? 0.0 : math.sin(t * math.pi * 6) * 10 * (1 - t);
                return Transform.translate(offset: Offset(dx, 0), child: child);
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_kPinLength, (i) {
                  final filled = i < _digits.length;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    margin: const EdgeInsets.symmetric(horizontal: 7),
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled ? c.accent : Colors.transparent,
                      border: Border.all(
                          color: filled ? c.accent : c.line, width: 1.4),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 18,
              child: _locked
                  ? Text(
                      tr(
                          'Слишком много попыток. Подождите $_lockSecondsLeft с',
                          'Too many attempts. Wait ${_lockSecondsLeft}s',
                          'Demasiados intentos. Espera ${_lockSecondsLeft}s'),
                      style: TextStyle(color: c.muted, fontSize: 12),
                      textAlign: TextAlign.center,
                    )
                  : (_error != null
                      ? Text(_error!,
                          style: const TextStyle(
                              color: Colors.redAccent, fontSize: 12.5))
                      : const SizedBox.shrink()),
            ),
            const SizedBox(height: 8),
            _Keypad(
              enabled: !_locked,
              c: c,
              onDigit: _onDigit,
              onBackspace: _onBackspace,
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(tr('Отмена', 'Cancel', 'Cancelar'),
                  style: TextStyle(color: c.muted)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  final bool enabled;
  final AuroraColors c;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  const _Keypad({
    required this.enabled,
    required this.c,
    required this.onDigit,
    required this.onBackspace,
  });

  static const _layout = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['', '0', '⌫'],
  ];

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _layout.map((row) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: row.map((key) {
                  if (key.isEmpty) {
                    return const SizedBox(width: 56, height: 52);
                  }
                  final isBackspace = key == '⌫';
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Material(
                      color: c.surface2,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => isBackspace ? onBackspace() : onDigit(key),
                        child: SizedBox(
                          width: 54,
                          height: 54,
                          child: Center(
                            child: isBackspace
                                ? Icon(Icons.backspace_outlined,
                                    color: c.text, size: 20)
                                : Text(key,
                                    style: TextStyle(
                                        color: c.text,
                                        fontSize: 20,
                                        fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
