import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import 'ble/pump_session.dart';
import 'screens/home_screen.dart';
import 'update/app_self_update.dart';
import 'update/firmware_update.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  FlutterBluePlus.setLogLevel(LogLevel.info, color: false);
  runApp(const TankLinkApp());
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
        ChangeNotifierProvider(
          create: (_) => AppSelfUpdate()..loadCache(),
        ),
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
        home: const HomeScreen(),
      ),
    );
  }
}
