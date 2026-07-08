import 'package:flutter_test/flutter_test.dart';

import 'package:cc_remote/main.dart';

void main() {
  testWidgets('shows the app shell and advances to pairing', (tester) async {
    await tester.pumpWidget(const CcRemoteApp());

    expect(find.text('CC Remote'), findsOneWidget);
    expect(find.text('正在检查本地配对信息'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));

    expect(find.text('扫描电脑终端里的二维码'), findsOneWidget);
    expect(find.text('连接这台电脑'), findsOneWidget);
  });

  testWidgets('settings uses a confirmation before leaving pairing', (
    tester,
  ) async {
    await tester.pumpWidget(const CcRemoteApp());
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.text('连接这台电脑'));
    await tester.pumpAndSettle();
    expect(find.text('本机已连接'), findsOneWidget);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('退出配对'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
    expect(find.text('扫描电脑终端里的二维码'), findsNothing);

    await tester.tap(find.text('退出配对'));
    await tester.pumpAndSettle();
    expect(find.text('退出后这台手机需要重新扫码。'), findsOneWidget);

    await tester.tap(find.text('退出').last);
    await tester.pumpAndSettle();
    expect(find.text('扫描电脑终端里的二维码'), findsOneWidget);
  });
}
