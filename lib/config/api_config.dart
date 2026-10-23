/// Cấu hình địa chỉ Backend Web API tập trung
class ApiConfig {
  // Ưu tiên đọc từ biến môi trường --dart-define=BASE_URL=... khi build
  static const String baseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'https://encroach-perfume-clasp.ngrok-free.dev/api',
  );

  static const Duration timeout = Duration(seconds: 20);

  // Header chung cho tất cả request
  static Map<String, String> get commonHeaders => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'ngrok-skip-browser-warning': 'true',
      };
}
