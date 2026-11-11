import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import 'ble/pump_session.dart';
import 'screens/home_screen.dart';
import 'update/pump_firmware_update.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
        ChangeNotifierProvider(
          create: (_) => PumpFirmwareUpdate()..loadCache(),
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
