
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  // Backend ASP.NET Core qua ngrok
  static const String baseUrl =
      'https://encroach-perfume-clasp.ngrok-free.dev/api';

  static const Duration _timeout = Duration(seconds: 20);

  // Header chung cho ngrok
  static Map<String, String> get _commonHeaders => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'ngrok-skip-browser-warning': 'true',
  };

  // Header dành cho Parent (JWT)
  static Future<Map<String, String>> _getHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');

    return {
      ..._commonHeaders,
      if (token != null && token.isNotEmpty)
        'Authorization': 'Bearer $token',
    };
  }

  // Header dành cho Child (Device Token)
  static Future<Map<String, String>> _getChildHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('child_device_token');

    return {
      ..._commonHeaders,
      if (token != null && token.isNotEmpty)
        'X-Child-Token': token,
    };
  }

  // Xử lý kết quả API
  static Map<String, dynamic> _parseResponse(
      http.Response response,
      ) {
    try {
      final body = jsonDecode(response.body);

      if (body is Map<String, dynamic>) {
        final isSuccess =
            response.statusCode >= 200 &&
                response.statusCode < 300 &&
                body['status'] != false;

        String message =
        (body['message'] ?? body['title'] ?? '').toString();

        if (body['errors'] is List) {
          final errors = (body['errors'] as List)
              .map((e) {
            if (e is Map && e['description'] != null) {
              return e['description'].toString();
            }
            return e.toString();
          })
              .join(', ');

          if (errors.isNotEmpty) {
            message = message.isEmpty
                ? errors
                : '$message: $errors';
          }
        } else if (body['errors'] is Map) {
          final errors = <String>[];

          (body['errors'] as Map).forEach((key, value) {
            if (value is List) {
              errors.add('$key: ${value.join(", ")}');
            } else {
              errors.add('$key: $value');
            }
          });

          if (errors.isNotEmpty) {
            message = message.isEmpty
                ? errors.join('; ')
                : '$message: ${errors.join("; ")}';
          }
        }

        if (message.isEmpty) {
          message = isSuccess
              ? 'Thanh cong'
              : 'Loi may chu: ${response.statusCode}';
        }

        return {
          ...body,
          'status': isSuccess,
          'statusCode': response.statusCode,
          'message': message,
        };
      }

      return {
        'status':
        response.statusCode >= 200 &&
            response.statusCode < 300,
        'statusCode': response.statusCode,
        'message': body is String
            ? body
            : response.body,
        'data': body,
      };
    } catch (_) {
      return {
        'status': false,
        'statusCode': response.statusCode,
        'message':
        'Loi phan hoi may chu (${response.statusCode})',
      };
    }
  }

  // 1. Đăng ký tài khoản Parent
  static Future<Map<String, dynamic>> register(
      String username,
      String email,
      String password,
      ) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Authenticate/register'),
        headers: await _getHeaders(),
        body: jsonEncode({
          'username': username,
          'email': email,
          'password': password,
          'initials': username.isNotEmpty
              ? username.substring(0, 1).toUpperCase()
              : '',
        }),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Khong the dang ky: $e',
      };
    }
  }

  // 2. Đăng nhập Parent
  static Future<Map<String, dynamic>> login(
      String username,
      String password,
      ) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Authenticate/login'),
        headers: _commonHeaders,
        body: jsonEncode({
          'username': username,
          'password': password,
        }),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi dang nhap: $e',
      };
    }
  }

  // 3. Xác thực OTP
  static Future<Map<String, dynamic>> verifyOtp(
      String username,
      String otpCode,
      ) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Authenticate/verify-otp'),
        headers: _commonHeaders,
        body: jsonEncode({
          'username': username,
          'otpCode': otpCode,
        }),
      ).timeout(_timeout);

      final data = _parseResponse(response);

      if (data['status'] == true &&
          data['token'] is String &&
          (data['token'] as String).isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();

        await prefs.setString(
          'jwt_token',
          data['token'] as String,
        );
      }

      return data;
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi xac thuc OTP: $e',
      };
    }
  }

  // 4. Child quét QR để ghép nối
  static Future<Map<String, dynamic>> pairDeviceByQr(
      String qrCode,
      ) async {
    try {
      final cleanCode = qrCode.trim();
      final response = await http.post(
        Uri.parse('$baseUrl/Pairing/connect'),
        headers: _commonHeaders,
        body: jsonEncode({
          'qrCode': cleanCode,
          'pairingCode': cleanCode,
          'code': cleanCode,
        }),
      ).timeout(_timeout);

      final data = _parseResponse(response);

      if (data['status'] == true) {
        final token = data['deviceToken'] ??
            data['token'] ??
            data['childDeviceToken'] ??
            (data['data'] is Map ? data['data']['deviceToken'] ?? data['data']['token'] : null);

        if (token is! String || token.isEmpty) {
          return {
            'status': false,
            'message': data['message'] ?? 'Server khong tra ve deviceToken',
          };
        }

        final prefs = await SharedPreferences.getInstance();

        await prefs.setString(
          'child_device_token',
          token,
        );

        final dynamic rawDeviceId = data['deviceId'] ??
            data['childDeviceId'] ??
            data['id'] ??
            (data['data'] is Map ? data['data']['deviceId'] ?? data['data']['id'] : null);

        if (rawDeviceId is int) {
          await prefs.setInt('child_device_id', rawDeviceId);
        } else if (rawDeviceId is num) {
          await prefs.setInt('child_device_id', rawDeviceId.toInt());
        } else if (rawDeviceId is String) {
          final parsedId = int.tryParse(rawDeviceId);
          if (parsedId != null) {
            await prefs.setInt('child_device_id', parsedId);
          }
        }
      }

      return data;
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi ghep noi QR: $e',
      };
    }
  }

  // 5. Child gửi GPS, tiếng ồn, té ngã và SOS
  static Future<Map<String, dynamic>> sendTelemetry({
    required int deviceId,
    required double latitude,
    required double longitude,
    required double noiseDecibel,
    bool isFallDetected = false,
    bool isSosActive = false,
  }) async {
    try {
      final response = await http.post(
        Uri.parse(
          '$baseUrl/SafetyHistory/child/telemetry/$deviceId',
        ),
        headers: await _getChildHeaders(),
        body: jsonEncode({
          'latitude': latitude,
          'longitude': longitude,
          'noiseDecibel': noiseDecibel,
          'isFallDetected': isFallDetected,
          'isSOSActive': isSosActive,
        }),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi gui telemetry: $e',
      };
    }
  }

  // 6. Child xin gia hạn thời gian
  static Future<Map<String, dynamic>> requestExtension(
      int deviceId, {
        String appName = 'YouTube',
        int requestedMinutes = 5,
        String reason = 'Xin gia han thoi gian',
      }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/ExtensionRequests/child'),
        headers: await _getChildHeaders(),
        body: jsonEncode({
          'childDeviceId': deviceId,
          'appName': appName,
          'requestedMinutes': requestedMinutes,
          'reason': reason,
        }),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi xin gia han: $e',
      };
    }
  }

  // 7. Parent tạo mã QR ghép nối
  static Future<Map<String, dynamic>> createPairingQr(
      int deviceId,
      ) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Pairing/create/$deviceId'),
        headers: await _getHeaders(),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi tao ma QR: $e',
      };
    }
  }

  // 8. Parent lấy danh sách thiết bị trẻ em
  static Future<Map<String, dynamic>> getChildDevices() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/ChildManagement/devices'),
        headers: await _getHeaders(),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi lay danh sach thiet bi: $e',
      };
    }
  }

  // 9. Parent xem telemetry của thiết bị trẻ
  static Future<Map<String, dynamic>> getDeviceTelemetry(
      int deviceId,
      ) async {
    try {
      final response = await http.get(
        Uri.parse(
          '$baseUrl/SafetyHistory/parent/telemetry/$deviceId',
        ),
        headers: await _getHeaders(),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi lay du lieu giam sat: $e',
      };
    }
  }

  // 10. Parent khóa thiết bị
  static Future<Map<String, dynamic>> lockDevice(
      int deviceId,
      ) async {
    try {
      final response = await http.put(
        Uri.parse('$baseUrl/DeviceControl/$deviceId/lock'),
        headers: await _getHeaders(),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi khoa thiet bi: $e',
      };
    }
  }

  // 11. Parent mở khóa thiết bị
  static Future<Map<String, dynamic>> unlockDevice(
      int deviceId,
      ) async {
    try {
      final response = await http.put(
        Uri.parse('$baseUrl/DeviceControl/$deviceId/unlock'),
        headers: await _getHeaders(),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi mo khoa thiet bi: $e',
      };
    }
  }

  // 12. Child kiểm tra trạng thái khóa
  static Future<Map<String, dynamic>> getChildLockStatus(
      int deviceId,
      ) async {
    try {
      final response = await http.get(
        Uri.parse(
          '$baseUrl/DeviceControl/child/$deviceId/status',
        ),
        headers: await _getChildHeaders(),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi kiem tra trang thai: $e',
      };
    }
  }

  // 13. Parent xem thống kê sử dụng ứng dụng
  static Future<Map<String, dynamic>> getAppUsage(
      int deviceId, {
        int days = 7,
      }) async {
    try {
      final response = await http.get(
        Uri.parse(
          '$baseUrl/AppUsage/parent/$deviceId?days=$days',
        ),
        headers: await _getHeaders(),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi lay thong ke su dung: $e',
      };
    }
  }

  // 14. Child báo cáo thời gian sử dụng
  static Future<Map<String, dynamic>> reportAppUsage({
    required int deviceId,
    required String appName,
    required int usedMinutes,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/AppUsage/child/report'),
        headers: await _getChildHeaders(),
        body: jsonEncode({
          'childDeviceId': deviceId,
          'appName': appName,
          'usedMinutes': usedMinutes,
        }),
      ).timeout(_timeout);

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi bao cao su dung: $e',
      };
    }
  }

  // 15. Đăng xuất Parent
  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('jwt_token');
  }
}
