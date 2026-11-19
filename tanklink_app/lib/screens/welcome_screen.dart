import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'add_pump_screen.dart';
import 'home_screen.dart';

const _welcomeSeenKey = 'welcome_seen';

/// First screen of the app: the welcome pages for a first launch with no
/// pumps, the home screen otherwise.
class StartGate extends StatefulWidget {
  const StartGate({super.key});

  @override
  State<StartGate> createState() => _StartGateState();
}

class _StartGateState extends State<StartGate> {
  bool? _welcome;

  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    var show = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasPumps = (prefs.getString('saved_pumps') ?? '[]') != '[]';
      show = !(prefs.getBool(_welcomeSeenKey) ?? false) && !hasPumps;
    } catch (_) {
      // Prefs unreadable: go straight home.
    }
    if (mounted) setState(() => _welcome = show);
  }

  @override
  Widget build(BuildContext context) {
    final welcome = _welcome;
    if (welcome == null) {
      return Scaffold(backgroundColor: Theme.of(context).colorScheme.surface);
    }
    return welcome ? const WelcomeScreen() : const HomeScreen();
  }
}

/// Opens the welcome pages again (from the home screen), on top of home.
void openWelcome(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => const WelcomeScreen(fromHome: true),
    ),
  );
}

class _Page {
  const _Page(this.icon, this.title, this.text);

  final IconData icon;
  final String title;
  final String text;
}

const _pages = [
  _Page(
    Icons.water_drop_rounded,
    'Welcome to TankLink',
    'Your water pump and tank, on your phone. It talks to the pump over '
        'Bluetooth, so it works without internet or an account.',
  ),
  _Page(
    Icons.waves_rounded,
    'Know your tank',
    'A sensor in the tank shows when it’s full or almost empty. The pump '
        'stops by itself when the tank is full.',
  ),
  _Page(
    Icons.schedule_rounded,
    'Start, stop, schedule',
    'Run the pump from your phone or set fill times. It also switches off '
        'after a time you choose, so it never runs longer than you want.',
  ),
  _Page(
    Icons.bluetooth_searching_rounded,
    'Add your pump',
    'Stand near the pump with Bluetooth on. If the pump is already on '
        'someone else’s phone, they can let you add it from Settings → '
        'Add another phone.',
  ),
];

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, this.fromHome = false});

  /// Opened again from home: closing just goes back.
  final bool fromHome;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _controller = PageController();
  int _page = 0;

  bool get _last => _page == _pages.length - 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish({required bool addPump}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_welcomeSeenKey, true);
    } catch (_) {}
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (widget.fromHome) {
      nav.pop();
    } else {
      nav.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
      );
    }
    if (addPump) {
      nav.push(MaterialPageRoute<void>(builder: (_) => const AddPumpScreen()));
    }
  }

  void _next() {
    _controller.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: AnimatedOpacity(
                  opacity: _last ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: TextButton(
                    onPressed: _last ? null : () => _finish(addPump: false),
                    child: const Text('Skip'),
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final p = _pages[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.primaryContainer.withValues(
                              alpha: 0.6,
                            ),
                          ),
                          child: Icon(p.icon, size: 56, color: scheme.primary),
                        ),
                        const SizedBox(height: 36),
                        Text(
                          p.title,
                          textAlign: TextAlign.center,
                          style: text.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          p.text,
                          textAlign: TextAlign.center,
                          style: text.bodyLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _pages.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _page ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: i == _page
                          ? scheme.primary
                          : scheme.outlineVariant,
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: _last ? () => _finish(addPump: true) : _next,
                    child: Text(_last ? 'Add your pump' : 'Next'),
                  ),
                  const SizedBox(height: 8),
                  // Same height on every page, so the button doesn't jump.
                  SizedBox(
                    height: 40,
                    child: _last
                        ? TextButton(
                            onPressed: () => _finish(addPump: false),
                            child: Text(widget.fromHome ? 'Close' : 'Not now'),
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
