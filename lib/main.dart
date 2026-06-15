import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'theme.dart';
import 'home_page.dart';
import 'favorites.dart';
import 'tag_service.dart';
import 'settings_service.dart';
import 'lan_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Favorites.instance.load();
  await SettingsService.instance.load();
  await LanStore.instance.load();
  try {
    await TagService.instance.init();
  } catch (_) {
    // если база не открылась — приложение всё равно работает (без тегов)
  }
  runApp(const GoatApp());
}

/// Корневой виджет. Перестраивается, когда меняются настройки
/// (тема, режим яркости и пр.) или когда система переключает светлый/тёмный.
class GoatApp extends StatefulWidget {
  const GoatApp({super.key});

  @override
  State<GoatApp> createState() => _GoatAppState();
}

class _GoatAppState extends State<GoatApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SettingsService.instance.addListener(_onSettings);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SettingsService.instance.removeListener(_onSettings);
    super.dispose();
  }

  void _onSettings() => setState(() {});

  /// Системная яркость поменялась — пересобрать тему, если выбран режим «как в системе».
  @override
  void didChangePlatformBrightness() {
    if (SettingsService.instance.themeMode == ThemeModeChoice.system) {
      setState(() {});
    }
  }

  Brightness _effectiveBrightness() {
    final mode = SettingsService.instance.themeMode;
    switch (mode) {
      case ThemeModeChoice.light:
        return Brightness.light;
      case ThemeModeChoice.dark:
        return Brightness.dark;
      case ThemeModeChoice.system:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }

  AuroraColors _resolveColors() {
    final s = SettingsService.instance;
    final brightness = _effectiveBrightness();
    final base = resolveBase(
        brightness == Brightness.light ? s.lightBaseId : s.darkBaseId,
        brightness);
    final accent = resolveAccent(s.accentId);
    return composeColors(base, accent);
  }

  @override
  Widget build(BuildContext context) {
    final colors = _resolveColors();
    return AuroraTheme(
      colors: colors,
      child: MaterialApp(
        title: 'GOAT',
        debugShowCheckedModeBanner: false,
        theme: colors.toThemeData(),
        home: const HomePage(),
      ),
    );
  }
}
