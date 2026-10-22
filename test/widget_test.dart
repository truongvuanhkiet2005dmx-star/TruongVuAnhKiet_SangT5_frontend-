import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truong_vu_anh_kiet_de1_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App launch displays Role Selection View when app_mode is null', (WidgetTester tester) async {
    // 1. Render ứng dụng
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    // 2. Kiểm tra màn hình chọn vai trò mở ra khi chưa chọn app_mode
    expect(find.text('Chào mừng bạn đến với ChildCare'), findsOneWidget);
    expect(find.text('Vui lòng chọn vai trò của thiết bị này:'), findsOneWidget);
    expect(find.text('PHỤ HUYNH (PARENT)'), findsOneWidget);
    expect(find.text('TRẺ EM (CHILD)'), findsOneWidget);
  });

  testWidgets('Selecting Child mode updates UI to unpaired Child View', (WidgetTester tester) async {
    // 1. Render ứng dụng
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    // 2. Nhấn vào nút TRẺ EM (CHILD)
    final childButton = find.text('TRẺ EM (CHILD)');
    expect(childButton, findsOneWidget);
    await tester.tap(childButton);
    await tester.pumpAndSettle();

    // 3. Kiểm tra giao diện chuyển sang chế độ Child báo chưa ghép nối QR
    expect(find.text('Thiết Bị Trẻ Em (Child)'), findsOneWidget);
    expect(find.text('Thiết bị chưa ghép nối QR'), findsOneWidget);
    expect(find.text('Quét Mã QR Kết Nối'), findsOneWidget);
  });
}
