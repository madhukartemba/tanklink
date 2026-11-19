import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'ble/pump_session.dart';
import 'diag/app_log.dart';
import 'diag/report_sender.dart';
import 'screens/home_screen.dart';
import 'update/app_self_update.dart';
import 'update/firmware_update.dart';

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
      runApp(const TankLinkApp());
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
  const TankLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PumpSession()..init()),
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
      child: MaterialApp(
        title: 'TankLink',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2EC4B6),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          appBarTheme: const AppBarTheme(centerTitle: false),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        // Android 15+ draws apps edge to edge. Keep every page and sheet
        // above the navigation / gesture bar (lists with their own padding
        // don't do this themselves); the top is handled by app bars,
        // SafeArea and useSafeArea on sheets.
        builder: (context, child) => ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(top: false, child: child!),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
