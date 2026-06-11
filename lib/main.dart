import 'package:flutter/material.dart';
import 'theme.dart';
import 'home_page.dart';
import 'favorites.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Favorites.instance.load();
  runApp(const AuroraApp());
}

class AuroraApp extends StatefulWidget {
  const AuroraApp({super.key});

  @override
  State<AuroraApp> createState() => _AuroraAppState();
}

class _AuroraAppState extends State<AuroraApp> {
  String _themeId = 'sand';

  AuroraColors get _colors =>
      kThemes.firstWhere((t) => t.id == _themeId, orElse: () => kThemes.first);

  void _setTheme(String id) => setState(() => _themeId = id);

  @override
  Widget build(BuildContext context) {
    return AuroraTheme(
      colors: _colors,
      setTheme: _setTheme,
      child: MaterialApp(
        title: 'Aurora',
        debugShowCheckedModeBanner: false,
        theme: _colors.toThemeData(),
        home: const HomePage(),
      ),
    );
  }
}
