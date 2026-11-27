import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'haptics.dart';

/// This phone's own settings (not the pump's): appearance and vibration.
class AppPrefs extends ChangeNotifier {
  AppPrefs._(this._prefs)
    : _theme = ThemeMode.values.firstWhere(
        (m) => m.name == _prefs.getString(_themeKey),
        orElse: () => ThemeMode.system,
      ),
      _haptics = _prefs.getBool(_hapticsKey) ?? true {
    Haptics.enabled = _haptics;
  }

  static const _themeKey = 'app_theme';
  static const _hapticsKey = 'app_haptics';

  static Future<AppPrefs> load() async =>
      AppPrefs._(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;
  ThemeMode _theme;
  bool _haptics;

  ThemeMode get theme => _theme;
  bool get haptics => _haptics;

  Future<void> setTheme(ThemeMode m) async {
    _theme = m;
    notifyListeners();
    await _prefs.setString(_themeKey, m.name);
  }

  Future<void> setHaptics(bool on) async {
    _haptics = on;
    Haptics.enabled = on;
    notifyListeners();
    await _prefs.setBool(_hapticsKey, on);
  }
}
