import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rebalance/features/dashboard/dashboard_page.dart';
import 'package:rebalance/features/dashboard/dashboard_repository.dart';

void main() {
  testWidgets('dashboard shows three accounts and safe paper mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DashboardView(snapshot: DashboardRepository.demoSnapshot()),
      ),
    );
    expect(find.text('PAPER · SAFE'), findsOneWidget);
    expect(find.text('Funding Account'), findsOneWidget);
    expect(find.text('Strategy Account'), findsOneWidget);
    expect(find.text('Profit Account'), findsOneWidget);
    expect(find.text('尚未连接真实 Binance 账户 · 请先配置三个子账户 API 凭据'), findsOneWidget);
    expect(find.textContaining(r'$200000.00'), findsNothing);
  });
}
