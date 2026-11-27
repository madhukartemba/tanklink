import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'ble/pump_session.dart';
import 'diag/app_log.dart';
import 'glance/glance_bridge.dart';
import 'diag/report_sender.dart';
import 'screens/welcome_screen.dart';
import 'update/app_self_update.dart';
import 'update/firmware_update.dart';
import 'util/app_prefs.dart';

/// flutter_blue_plus logs every read and write at info level. Keep only the
/// lines that point at a problem, so the app log covers hours, not seconds.
final _fbpProblem = RegExp(
  r'error|fail|exception|timeout|disconnect',
  caseSensitive: false,
);

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        // presentError dumps the whole error through debugPrint, which would
        // log it twice. Print it only while developing.
        if (kDebugMode) FlutterError.presentError(details);
        AppLog.e('flutter', details.exceptionAsString(), null, details.stack);
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        AppLog.e('uncaught', 'Uncaught error', error, stack);
        return true;
      };
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) AppLog.i('debug', message);
      };
      await AppLog.init();
      final info = await PackageInfo.fromPlatform();
      AppLog.i('app', 'Started ${info.version}+${info.buildNumber}');
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      FlutterBluePlus.setLogLevel(LogLevel.info, color: false);
      final appPrefs = await AppPrefs.load();
      runApp(TankLinkApp(prefs: appPrefs));
      unawaited(ReportSender.sendQueued());
    },
    (error, stack) => AppLog.e('uncaught', 'Uncaught error', error, stack),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        if (line.startsWith('[FBP]')) {
          if (_fbpProblem.hasMatch(line)) AppLog.w('ble', line);
        } else {
          AppLog.i('print', line);
        }
        if (kDebugMode) parent.print(zone, line);
      },
    ),
  );
}

class TankLinkApp extends StatelessWidget {
  const TankLinkApp({super.key, required this.prefs});

  final AppPrefs prefs;

  static ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2EC4B6),
      brightness: b,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      appBarTheme: const AppBarTheme(centerTitle: false),
      // Android 14+ back gesture: the page follows the finger.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: prefs),
        ChangeNotifierProvider(
          create: (_) {
            final session = PumpSession()..init();
            GlanceBridge(session); // widget and Quick Settings tile
            return session;
          },
        ),
        // Each updater only offers firmware built for the connected board.
        ChangeNotifierProxyProvider<PumpSession, PumpFirmwareUpdate>(
          create: (_) => PumpFirmwareUpdate()..loadCache(),
          update: (_, session, fw) => fw!..setBoardRev(session.pumpHwRev),
        ),
        ChangeNotifierProxyProvider<PumpSession, TankFirmwareUpdate>(
          create: (_) => TankFirmwareUpdate()..loadCache(),
          update: (_, session, fw) => fw!..setBoardRev(session.tankHwRev),
        ),
        ChangeNotifierProvider(create: (_) => AppSelfUpdate()..loadCache()),
      ],
      child: Consumer<AppPrefs>(
        builder: (context, prefs, _) => MaterialApp(
          title: 'TankLink',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: prefs.theme,
          // Android 15+ draws apps edge to edge. Keep every page and sheet
          // above the navigation / gesture bar (lists with their own padding
          // don't do this themselves); the top is handled by app bars,
          // SafeArea and useSafeArea on sheets.
          // Status and navigation bar icons follow the theme: the home
          // screen has no app bar to set them.
          builder: (context, child) {
            final dark = Theme.of(context).brightness == Brightness.dark;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: dark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark,
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: SafeArea(top: false, child: child!),
              ),
            );
          },
          home: const StartGate(),
        ),
      ),
    );
  }
}
