import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import '../util/water_use.dart';

/// Water and power use, worked out from how long the pump ran.
///
/// Charts follow one rule set: one hue (the theme's primary) for every
/// series, hairline solid gridlines, 4 px rounded bar ends on a shared
/// baseline, a tooltip on every bar, and a table of the same numbers.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key});

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  int _days = 30;
  UseMetric? _metric;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<PumpSession>().loadUsage();
    });
  }

  UseMetric _defaultMetric(UsageSettings s) =>
      s.hasFlow ? UseMetric.water : UseMetric.time;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final s = session.usageSettingsShown;
    final report = buildUsage(
      session.usageFills,
      now: DateTime.now(),
      days: _days,
    );
    var metric = _metric ?? _defaultMetric(s);
    if (!metric.available(s)) metric = _defaultMetric(s);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Water and power'),
        actions: [
          if (kDebugMode)
            IconButton(
              tooltip: session.simUsage ? 'Real data' : 'Sample data',
              isSelected: session.simUsage,
              icon: const Icon(Icons.science_outlined),
              selectedIcon: const Icon(Icons.science_rounded),
              onPressed: () => session.simulateUsage(!session.simUsage),
            ),
          IconButton(
            tooltip: 'Pump details',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => _editSettings(context, session),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 7, label: Text('7 days')),
              ButtonSegment(value: 30, label: Text('30 days')),
              ButtonSegment(value: 90, label: Text('90 days')),
            ],
            selected: {_days},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _days = v.first),
          ),
          const SizedBox(height: 16),
          if (session.simUsage) ...[
            const _SampleBanner(),
            const SizedBox(height: 12),
          ],
          if (!s.hasFlow) ...[
            _SetupBanner(onTap: () => _editSettings(context, session)),
            const SizedBox(height: 12),
          ],
          _HeroCard(report: report, settings: s, days: _days),
          const SizedBox(height: 12),
          _StatRow(
            report: report,
            settings: s,
            onSetPrice: () => _editSettings(context, session),
          ),
          const SizedBox(height: 12),
          _DailyCard(
            report: report,
            settings: s,
            metric: metric,
            onMetric: (m) => setState(() => _metric = m),
          ),
          if (report.runSecBySlot.length > 1) ...[
            const SizedBox(height: 12),
            _ByTankCard(report: report, settings: s, metric: metric),
          ],
          const SizedBox(height: 12),
          _HoursCard(report: report),
          const SizedBox(height: 12),
          _TableCard(report: report, settings: s),
          const SizedBox(height: 16),
          Text(
            'Worked out from how long the pump ran, with the flow, power and '
            'price you set. Fills older than the pump’s last 20 count only '
            'if this phone saw them.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editSettings(BuildContext context, PumpSession session) async {
    final next = await showModalBottomSheet<UsageSettings>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SettingsSheet(initial: session.usageSettings),
    );
    if (next != null) await session.setUsageSettings(next);
  }
}

// ------------------------------------------------------------------ pieces

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}

/// Debug builds: says the charts show made-up fills.
class _SampleBanner extends StatelessWidget {
  const _SampleBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.science_rounded, color: scheme.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Sample data (debug build). Nothing here is real or saved. '
                'Tap the flask to go back.',
                style: TextStyle(
                  color: scheme.onTertiaryContainer,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                Icons.water_drop_outlined,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Set your pump’s flow to see litres. Time how long it '
                  'takes to fill a bucket.',
                  style: TextStyle(
                    color: scheme.onSecondaryContainer,
                    height: 1.3,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: scheme.onSecondaryContainer,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one number the screen leads with.
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.report,
    required this.settings,
    required this.days,
  });

  final UsageReport report;
  final UsageSettings settings;
  final int days;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final water = settings.hasFlow;
    final total = water
        ? formatLitres(settings.litres(report.totalRunSec))
        : formatMinutes(report.totalRunSec / 60);
    final perDay = water
        ? formatLitres(settings.litres(report.avgRunSecPerDay.round()))
        : formatMinutes(report.avgRunSecPerDay / 60);
    return _Panel(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            water
                ? 'Water pumped, last $days days'
                : 'Pump time, last $days days',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            report.isEmpty ? '—' : total,
            style: text.displaySmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            report.isEmpty
                ? 'No fills in this period yet'
                : 'About $perDay a day · ${report.totalFills} '
                      '${report.totalFills == 1 ? 'fill' : 'fills'}',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.report,
    required this.settings,
    required this.onSetPrice,
  });

  final UsageReport report;
  final UsageSettings settings;
  final VoidCallback onSetPrice;

  @override
  Widget build(BuildContext context) {
    final perDay = report.avgRunSecPerDay;
    final monthSec = (perDay * 30).round();
    return Row(
      children: [
        Expanded(
          child: _Stat(
            label: 'Pump time',
            value: formatMinutes(report.totalRunSec / 60),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _Stat(
            label: 'Energy',
            value: formatKwh(settings.kwh(report.totalRunSec)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: settings.hasPrice
              ? _Stat(
                  label: 'A month, about',
                  value: formatMoney(
                    settings.cost(monthSec),
                    settings.currency,
                  ),
                )
              : _Stat(label: 'Cost', value: 'Set price', onTap: onSetPrice),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: onTap != null ? scheme.primary : scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ charts

/// Shared look for the bar charts.
class _Bars extends StatelessWidget {
  const _Bars({
    required this.values,
    required this.bottomLabel,
    required this.tooltip,
    required this.axisLabel,
    this.height = 200,
    this.maxBarWidth = 16,
  });

  final List<double> values;

  /// Label under bar [i], or null for none.
  final String? Function(int i) bottomLabel;
  final String Function(int i) tooltip;
  final String Function(double v) axisLabel;
  final double height;
  final double maxBarWidth;

  /// A round top for the y axis, with about four gridlines.
  static double _niceStep(double max) {
    if (max <= 0) return 1;
    final raw = max / 4;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    for (final m in const [1, 2, 2.5, 5, 10]) {
      if (raw <= m * mag) return m * mag;
    }
    return 10 * mag;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peak = values.fold<double>(0, math.max);
    final step = _niceStep(peak);
    final top = peak <= 0 ? step * 4 : (peak / step).ceil() * step;
    final grid = scheme.outlineVariant.withValues(alpha: 0.6);
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 11);

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          // Bars take ~60% of their slot, capped; the rest is air.
          final slot = (box.maxWidth - 58) / math.max(1, values.length);
          final width = (slot * 0.6).clamp(2.0, maxBarWidth);
          final radius = width >= 6 ? 4.0 : width / 2;
          return BarChart(
            BarChartData(
              maxY: top,
              minY: 0,
              alignment: BarChartAlignment.spaceAround,
              barGroups: [
                for (var i = 0; i < values.length; i++)
                  BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: values[i],
                        width: width,
                        color: scheme.primary,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(radius),
                        ),
                      ),
                    ],
                  ),
              ],
              gridData: FlGridData(
                drawVerticalLine: false,
                horizontalInterval: step,
                getDrawingHorizontalLine: (_) =>
                    FlLine(color: grid, strokeWidth: 1),
              ),
              borderData: FlBorderData(
                show: true,
                border: Border(bottom: BorderSide(color: grid)),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                // A little room on the right so the last date isn't cut off.
                rightTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 14,
                    getTitlesWidget: (_, _) => const SizedBox.shrink(),
                  ),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    interval: step,
                    getTitlesWidget: (v, meta) => v == 0 || v > top
                        ? const SizedBox.shrink()
                        : SideTitleWidget(
                            meta: meta,
                            child: Text(axisLabel(v), style: muted),
                          ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    getTitlesWidget: (v, meta) {
                      final label = bottomLabel(v.toInt());
                      return label == null
                          ? const SizedBox.shrink()
                          : SideTitleWidget(
                              meta: meta,
                              child: Text(label, style: muted),
                            );
                    },
                  ),
                ),
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => scheme.inverseSurface,
                  tooltipBorderRadius: BorderRadius.circular(10),
                  tooltipPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipItem: (group, _, _, _) => BarTooltipItem(
                    tooltip(group.x),
                    TextStyle(
                      color: scheme.onInverseSurface,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            duration: const Duration(milliseconds: 250),
          );
        },
      ),
    );
  }
}

String _axisShort(UseMetric m, double v, UsageSettings s) {
  String compact(double x) => x >= 1000
      ? '${(x / 1000).toStringAsFixed(x % 1000 == 0 ? 0 : 1)}k'
      : x.round().toString();
  return switch (m) {
    UseMetric.water => '${compact(v)} L',
    UseMetric.time => '${v.round()}m',
    UseMetric.energy => v < 10 ? v.toStringAsFixed(1) : v.round().toString(),
    UseMetric.cost =>
      '${s.currency}${v < 10 ? v.toStringAsFixed(1) : compact(v)}',
  };
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _dayLong(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

class _DailyCard extends StatelessWidget {
  const _DailyCard({
    required this.report,
    required this.settings,
    required this.metric,
    required this.onMetric,
  });

  final UsageReport report;
  final UsageSettings settings;
  final UseMetric metric;
  final ValueChanged<UseMetric> onMetric;

  static const _labels = {
    UseMetric.water: 'Water',
    UseMetric.time: 'Time',
    UseMetric.energy: 'Energy',
    UseMetric.cost: 'Cost',
  };

  @override
  Widget build(BuildContext context) {
    final days = report.days;
    final values = [for (final d in days) metric.of(d.runSec, settings)];
    final n = days.length;
    // About five dates under the axis, today always last.
    final every = math.max(1, (n / 5).ceil());
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle('Each day'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final m in UseMetric.values)
                if (m.available(settings))
                  ChoiceChip(
                    label: Text(_labels[m]!),
                    selected: m == metric,
                    onSelected: (_) => onMetric(m),
                  ),
            ],
          ),
          const SizedBox(height: 16),
          Semantics(
            label:
                '${_labels[metric]} each day for the last $n days. '
                'The same numbers are in the table below.',
            child: _Bars(
              values: values,
              bottomLabel: (i) {
                if (i < 0 || i >= n) return null;
                if (n <= 7) {
                  return _weekdays[days[i].day.weekday - 1].substring(0, 1);
                }
                if ((n - 1 - i) % every != 0) return null;
                return '${days[i].day.day}/${days[i].day.month}';
              },
              tooltip: (i) =>
                  '${_dayLong(days[i].day)}\n${formatMetric(metric, values[i], settings)}'
                  '${days[i].fills > 0 ? ' · ${days[i].fills} ${days[i].fills == 1 ? 'fill' : 'fills'}' : ''}',
              axisLabel: (v) => _axisShort(metric, v, settings),
              maxBarWidth: n <= 7 ? 24 : 16,
            ),
          ),
        ],
      ),
    );
  }
}

/// Each tank's share, as a thin rounded bar per tank.
class _ByTankCard extends StatelessWidget {
  const _ByTankCard({
    required this.report,
    required this.settings,
    required this.metric,
  });

  final UsageReport report;
  final UsageSettings settings;
  final UseMetric metric;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    final entries = report.runSecBySlot.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = report.totalRunSec;
    final peak = entries.isEmpty ? 1 : entries.first.value;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle('By tank'),
          const SizedBox(height: 12),
          for (final e in entries) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    session.tankNameFor(e.key),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  formatMetric(metric, metric.of(e.value, settings), settings),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    '${total == 0 ? 0 : (e.value * 100 / total).round()}%',
                    textAlign: TextAlign.right,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: peak == 0 ? 0 : e.value / peak,
                minHeight: 8,
                color: scheme.primary,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }
}

/// When fills start, by hour of day.
class _HoursCard extends StatelessWidget {
  const _HoursCard({required this.report});

  final UsageReport report;

  static String _hour(int h) {
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12 ${h < 12 ? 'am' : 'pm'}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final counts = report.startsByHour;
    var busiest = 0;
    for (var h = 1; h < 24; h++) {
      if (counts[h] > counts[busiest]) busiest = h;
    }
    final none = counts.every((c) => c == 0);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle('When the pump starts'),
          const SizedBox(height: 4),
          Text(
            none
                ? 'No fills in this period yet'
                : 'Most often around ${_hour(busiest)}',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          _Bars(
            height: 140,
            maxBarWidth: 8,
            values: [for (final c in counts) c.toDouble()],
            bottomLabel: (i) => i % 6 == 0 ? _hour(i) : null,
            tooltip: (i) =>
                '${_hour(i)}–${_hour((i + 1) % 24)}\n${counts[i]} '
                '${counts[i] == 1 ? 'start' : 'starts'}',
            axisLabel: (v) => v.round().toString(),
          ),
        ],
      ),
    );
  }
}

/// The same daily numbers as a table, for reading exact values.
class _TableCard extends StatelessWidget {
  const _TableCard({required this.report, required this.settings});

  final UsageReport report;
  final UsageSettings settings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = report.days.reversed.where((d) => d.fills > 0).toList();
    final head = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    return _Panel(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          shape: const RoundedRectangleBorder(),
          title: const Text('Daily numbers'),
          subtitle: Text('${rows.length} days with fills', style: head),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: [
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No fills in this period yet'),
              )
            else
              Table(
                columnWidths: const {0: FlexColumnWidth(1.4)},
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  TableRow(
                    children: [
                      Text('Day', style: head),
                      Text('Time', style: head, textAlign: TextAlign.right),
                      if (settings.hasFlow)
                        Text('Water', style: head, textAlign: TextAlign.right),
                      if (settings.hasPrice)
                        Text('Cost', style: head, textAlign: TextAlign.right),
                    ],
                  ),
                  for (final d in rows)
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(_dayLong(d.day)),
                        ),
                        Text(
                          formatMinutes(d.runSec / 60),
                          textAlign: TextAlign.right,
                        ),
                        if (settings.hasFlow)
                          Text(
                            formatLitres(settings.litres(d.runSec)),
                            textAlign: TextAlign.right,
                          ),
                        if (settings.hasPrice)
                          Text(
                            formatMoney(
                              settings.cost(d.runSec),
                              settings.currency,
                            ),
                            textAlign: TextAlign.right,
                          ),
                      ],
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ settings

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.initial});

  final UsageSettings initial;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final _flow = TextEditingController(text: _fmt(widget.initial.flowLpm));
  late final _watts = TextEditingController(
    text: _fmt(widget.initial.pumpWatts),
  );
  late final _price = TextEditingController(
    text: _fmt(widget.initial.pricePerKwh),
  );
  late final _currency = TextEditingController(text: widget.initial.currency);

  static String _fmt(double? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.round().toString() : v.toString();
  }

  static double? _parse(String t) {
    final v = double.tryParse(t.trim().replaceAll(',', '.'));
    return v != null && v > 0 ? v : null;
  }

  @override
  void dispose() {
    _flow.dispose();
    _watts.dispose();
    _price.dispose();
    _currency.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const number = TextInputType.numberWithOptions(decimal: true);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pump details', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _flow,
            keyboardType: number,
            decoration: const InputDecoration(
              labelText: 'Flow',
              suffixText: 'litres a minute',
              helperText: 'Fill a bucket: its litres ÷ the minutes it took',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _watts,
            keyboardType: number,
            decoration: const InputDecoration(
              labelText: 'Power',
              suffixText: 'watts',
              helperText: 'On the motor’s label. 1 HP is about 750 W',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 96,
                child: TextField(
                  controller: _currency,
                  maxLength: 4,
                  decoration: const InputDecoration(
                    labelText: 'Currency',
                    hintText: '₹',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _price,
                  keyboardType: number,
                  decoration: const InputDecoration(
                    labelText: 'Price',
                    suffixText: 'per kWh',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Saved on this phone, for this pump.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              UsageSettings(
                flowLpm: _parse(_flow.text),
                pumpWatts: _parse(_watts.text) ?? UsageSettings.defaultWatts,
                pricePerKwh: _parse(_price.text),
                currency: _currency.text.trim(),
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
