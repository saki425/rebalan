import 'dart:math' as math;

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/backtest/backtest_engine.dart';
import '../../core/backtest/binance_history_service.dart';

class BacktestPage extends StatefulWidget {
  const BacktestPage({super.key});

  @override
  State<BacktestPage> createState() => _BacktestPageState();
}

class _BacktestPageState extends State<BacktestPage> {
  final _history = BinanceHistoryService();
  final _engine = const BacktestEngine();
  final _days = TextEditingController(text: '365');
  final _capital = TextEditingController(text: '100000');
  bool _running = false;
  String? _error;
  BacktestResult? _result;

  @override
  void dispose() {
    _history.close();
    _days.dispose();
    _capital.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final days = int.parse(_days.text.trim());
      final capital = Decimal.parse(_capital.text.trim());
      if (days < 2 || capital <= Decimal.zero) throw ArgumentError('参数无效');
      final end = DateTime.now().toUtc();
      final prices = await _history.dailyCloses(
        start: end.subtract(Duration(days: days)),
        end: end,
      );
      if (prices.isEmpty) throw StateError('未获取到历史数据');
      final half = capital * Decimal.parse('0.5');
      final btc = (half / prices.first.close).toDecimal(
        scaleOnInfinitePrecision: 18,
      );
      final result = _engine.run(
        prices: prices,
        initialBtc: btc,
        initialUsdt: half,
        config: BacktestConfig(
          targetBtcWeight: Decimal.parse('0.5'),
          triggerDeviation: Decimal.parse('0.1'),
          repairRatio: Decimal.parse('0.25'),
          feeRate: Decimal.parse('0.001'),
          slippageRate: Decimal.parse('0.001'),
          cooldown: const Duration(seconds: 30),
        ),
      );
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('BTC/USDT 历史回测')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _days,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '回测天数'),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _capital,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '初始资产 USDT'),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _running ? null : _run,
                  icon: _running
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: const Text('开始回测'),
                ),
              ],
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        if (_result case final result?) ...[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 26,
                runSpacing: 12,
                children: [
                  _metric('最终资产', _money(result.finalEquity)),
                  _metric('总收益率', _percent(result.totalReturn)),
                  _metric('CAGR', _percent(result.cagr)),
                  _metric('最大回撤', _percent(result.maximumDrawdown)),
                  _metric('交易次数', '${result.tradeCount}'),
                  _metric('手续费', _money(result.totalFees)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('资产曲线', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 240,
                    width: double.infinity,
                    child: CustomPaint(painter: _CurvePainter(result.curve)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

Widget _metric(String label, String value) => SizedBox(
  width: 150,
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [Text(label), const SizedBox(height: 4), Text(value)],
  ),
);

String _money(Decimal value) => '\$${value.toDouble().toStringAsFixed(2)}';
String _percent(Decimal value) =>
    '${(value.toDouble() * 100).toStringAsFixed(2)}%';

class _CurvePainter extends CustomPainter {
  const _CurvePainter(this.points);
  final List<BacktestPoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final values = points.map((point) => point.equity.toDouble()).toList();
    final low = values.reduce(math.min);
    final high = values.reduce(math.max);
    final range = high == low ? 1.0 : high - low;
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x = size.width * index / (values.length - 1);
      final y = size.height - size.height * (values[index] - low) / range;
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFF4B740)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter oldDelegate) => oldDelegate.points != points;
}
