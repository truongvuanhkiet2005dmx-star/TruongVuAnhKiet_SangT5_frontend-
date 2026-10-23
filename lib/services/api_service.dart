import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';

class ApiService {
  // Getter baseUrl lấy từ ApiConfig
  static String get baseUrl => ApiConfig.baseUrl;

  // Header dành cho Parent (JWT)
  static Future<Map<String, String>> _getHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');

    return {
      ...ApiConfig.commonHeaders,
      if (token != null && token.isNotEmpty)
        'Authorization': 'Bearer $token',
    };
  }

  // Header dành cho Child (Device Token)
  static Future<Map<String, String>> _getChildHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('child_device_token');

    return {
      ...ApiConfig.commonHeaders,
      if (token != null && token.isNotEmpty)
        'X-Child-Token': token,
    };
  }

  // Xử lý linh hoạt phản hồi từ Backend (Hỗ trợ Object, Array, Plain Text & Empty Body)
  static Map<String, dynamic> _parseResponse(http.Response response) {
    try {
      if (response.body.isEmpty) {
        return {
          'status': response.statusCode >= 200 && response.statusCode < 300,
          'statusCode': response.statusCode,
          'message': response.statusCode >= 200 && response.statusCode < 300
              ? 'Thành công'
              : 'Lỗi máy chủ (${response.statusCode})',
        };
      }

      final body = jsonDecode(response.body);

      // 1. Phản hồi là JSON Array (Ví dụ GET /api/ChildManagement/devices)
      if (body is List) {
        final isSuccess = response.statusCode >= 200 && response.statusCode < 300;
        return {
          'status': isSuccess,
          'statusCode': response.statusCode,
          'data': body,
          'devices': body,
          'items': body,
          'message': isSuccess ? 'Thành công' : 'Lỗi máy chủ (${response.statusCode})',
        };
      }

      // 2. Phản hồi là JSON Object
      if (body is Map<String, dynamic>) {
        final isSuccess = response.statusCode >= 200 &&
            response.statusCode < 300 &&
            body['status'] != false;

        String message = (body['message'] ?? body['title'] ?? '').toString();

        if (body['errors'] is List) {
          final errors = (body['errors'] as List)
              .map((e) => e is Map && e['description'] != null ? e['description'].toString() : e.toString())
              .join(', ');
          if (errors.isNotEmpty) {
            message = message.isEmpty ? errors : '$message: $errors';
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
            message = message.isEmpty ? errors.join('; ') : '$message: ${errors.join("; ")}';
          }
        }

        if (message.isEmpty) {
          message = isSuccess ? 'Thành công' : 'Lỗi máy chủ (${response.statusCode})';
        }

        return {
          ...body,
          'status': isSuccess,
          'statusCode': response.statusCode,
          'message': message,
        };
      }

      // 3. Phản hồi dạng String
      return {
        'status': response.statusCode >= 200 && response.statusCode < 300,
        'statusCode': response.statusCode,
        'message': body is String ? body : response.body,
        'data': body,
      };
    } catch (e) {
      return {
        'status': false,
        'statusCode': response.statusCode,
        'message': 'Lỗi phản hồi máy chủ (${response.statusCode}): $e',
      };
    }
  }

  // --- 1. XÁC THỰC PARENT ---
  static Future<Map<String, dynamic>> register(
    String username,
    String email,
    String password,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/Authenticate/register'),
            headers: ApiConfig.commonHeaders,
            body: jsonEncode({
              'username': username,
              'email': email,
              'password': password,
              'initials': username.isNotEmpty ? username.substring(0, 1).toUpperCase() : '',
            }),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Không thể đăng ký: $e'};
    }
  }

  static Future<Map<String, dynamic>> login(
    String username,
    String password,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/Authenticate/login'),
            headers: ApiConfig.commonHeaders,
            body: jsonEncode({
              'username': username,
              'password': password,
            }),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi đăng nhập: $e'};
    }
  }

  static Future<Map<String, dynamic>> verifyOtp(
    String username,
    String otpCode,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/Authenticate/verify-otp'),
            headers: ApiConfig.commonHeaders,
            body: jsonEncode({
              'username': username,
              'otpCode': otpCode,
            }),
          )
          .timeout(ApiConfig.timeout);

      final data = _parseResponse(response);

      if (data['status'] == true &&
          data['token'] is String &&
          (data['token'] as String).isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('jwt_token', data['token'] as String);
      }

      return data;
    } catch (e) {
      return {'status': false, 'message': 'Lỗi xác thực OTP: $e'};
    }
  }

  // --- 2. QUẢN LÝ THIẾT BỊ TRẺ EM (PARENT CHILD MANAGEMENT CRUD) ---

  // Create: POST /api/ChildManagement/devices
  static Future<Map<String, dynamic>> createChildDevice({
    required String childName,
    required String deviceName,
    int age = 10,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/ChildManagement/devices'),
            headers: await _getHeaders(),
            body: jsonEncode({
              'childName': childName.trim(),
              'deviceName': deviceName.trim(),
              'age': age,
            }),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi tạo thiết bị trẻ: $e'};
    }
  }

  // Read List: GET /api/ChildManagement/devices
  static Future<Map<String, dynamic>> getChildDevices() async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/ChildManagement/devices'),
            headers: await _getHeaders(),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi lấy danh sách thiết bị: $e'};
    }
  }

  // Read Details: GET /api/ChildManagement/devices/{id}
  static Future<Map<String, dynamic>> getChildDeviceDetails(int id) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/ChildManagement/devices/$id'),
            headers: await _getHeaders(),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi lấy chi tiết thiết bị: $e'};
    }
  }

  // Update: PUT /api/ChildManagement/devices/{id}
  static Future<Map<String, dynamic>> updateChildDevice({
    required int id,
    required String childName,
    required String deviceName,
    int age = 10,
  }) async {
    try {
      final response = await http
          .put(
            Uri.parse('$baseUrl/ChildManagement/devices/$id'),
            headers: await _getHeaders(),
            body: jsonEncode({
              'id': id,
              'childName': childName.trim(),
              'deviceName': deviceName.trim(),
              'age': age,
            }),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi cập nhật thiết bị: $e'};
    }
  }

  // Delete: DELETE /api/ChildManagement/devices/{id}
  static Future<Map<String, dynamic>> deleteChildDevice(int id) async {
    try {
      final response = await http
          .delete(
            Uri.parse('$baseUrl/ChildManagement/devices/$id'),
            headers: await _getHeaders(),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi xóa thiết bị: $e'};
    }
  }

  // --- 3. TẠO & GHÉP NỐI QR ---

  // Parent tạo QR ghép nối: POST /api/Pairing/create/{deviceId}
  static Future<Map<String, dynamic>> createPairingQr(int deviceId) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/Pairing/create/$deviceId'),
            headers: await _getHeaders(),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi tạo mã QR: $e'};
    }
  }

  // Child quét QR ghép nối: POST /api/Pairing/connect
  static Future<Map<String, dynamic>> pairDeviceByQr(String qrCode) async {
    try {
      final cleanCode = qrCode.trim();
      final response = await http
          .post(
            Uri.parse('$baseUrl/Pairing/connect'),
            headers: ApiConfig.commonHeaders,
            body: jsonEncode({
              'qrCode': cleanCode,
              'pairingCode': cleanCode,
              'code': cleanCode,
            }),
          )
          .timeout(ApiConfig.timeout);

      final data = _parseResponse(response);

      if (data['status'] == true) {
        final token = data['deviceToken'] ??
            data['token'] ??
            data['childDeviceToken'] ??
            (data['data'] is Map ? data['data']['deviceToken'] ?? data['data']['token'] : null);

        if (token is! String || token.isEmpty) {
          return {
            'status': false,
            'message': data['message'] ?? 'Server không trả về deviceToken hợp lệ',
          };
        }

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('child_device_token', token);

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
      return {'status': false, 'message': 'Lỗi ghép nối QR: $e'};
    }
  }

  // --- 4. SAFETY HISTORY & TELEMETRY ---

  // Child gửi Telemetry: POST /api/SafetyHistory/child/telemetry/{deviceId}
  static Future<Map<String, dynamic>> sendTelemetry({
    required int deviceId,
    required double latitude,
    required double longitude,
    required double noiseDecibel,
    bool isFallDetected = false,
    bool isSosActive = false,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/SafetyHistory/child/telemetry/$deviceId'),
            headers: await _getChildHeaders(),
            body: jsonEncode({
              'latitude': latitude,
              'longitude': longitude,
              'noiseDecibel': noiseDecibel,
              'isFallDetected': isFallDetected,
              'isSOSActive': isSosActive,
            }),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi gửi telemetry: $e'};
    }
  }

  // Parent xem lịch sử vị trí: GET /api/SafetyHistory/locations/{deviceId}
  static Future<Map<String, dynamic>> getDeviceLocations(int deviceId) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/SafetyHistory/locations/$deviceId'),
            headers: await _getHeaders(),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi lấy lịch sử vị trí: $e'};
    }
  }

  // Parent xem danh sách cảnh báo: GET /api/SafetyHistory/alerts/{deviceId}
  static Future<Map<String, dynamic>> getDeviceAlerts(int deviceId) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/SafetyHistory/alerts/$deviceId'),
            headers: await _getHeaders(),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi lấy lịch sử cảnh báo: $e'};
    }
  }

  // --- 5. ĐIỀU KHIỂN & KHÓA THIẾT BỊ ---

  // Child kiểm tra trạng thái khóa: GET /api/DeviceControl/child/{deviceId}/status
  static Future<Map<String, dynamic>> getChildLockStatus(int deviceId) async {
    try {
      final response = await http
          .get(
            Uri.parse('$baseUrl/DeviceControl/child/$deviceId/status'),
            headers: await _getChildHeaders(),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi kiểm tra trạng thái khóa: $e'};
    }
  }

  // Parent khóa thiết bị: PUT /api/DeviceControl/{deviceId}/lock
  static Future<Map<String, dynamic>> lockDevice(int deviceId) async {
    try {
      final response = await http
          .put(
            Uri.parse('$baseUrl/DeviceControl/$deviceId/lock'),
            headers: await _getHeaders(),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi khóa thiết bị: $e'};
    }
  }

  // Parent mở khóa thiết bị: PUT /api/DeviceControl/{deviceId}/unlock
  static Future<Map<String, dynamic>> unlockDevice(int deviceId) async {
    try {
      final response = await http
          .put(
            Uri.parse('$baseUrl/DeviceControl/$deviceId/unlock'),
            headers: await _getHeaders(),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi mở khóa thiết bị: $e'};
    }
  }

  // --- 6. XIN GIA HẠN THỜI GIAN ---

  // Child xin gia hạn 5 phút: POST /api/ExtensionRequests/child
  static Future<Map<String, dynamic>> requestExtension(
    int deviceId, {
    String appName = 'YouTube',
    int requestedMinutes = 5,
    String reason = 'Xin gia hạn thời gian',
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/ExtensionRequests/child'),
            headers: await _getChildHeaders(),
            body: jsonEncode({
              'childDeviceId': deviceId,
              'appName': appName,
              'requestedMinutes': requestedMinutes,
              'reason': reason,
            }),
          )
          .timeout(ApiConfig.timeout);

      return _parseResponse(response);
    } catch (e) {
      return {'status': false, 'message': 'Lỗi xin gia hạn: $e'};
    }
  }

  // Đăng xuất Parent
  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('jwt_token');
    await prefs.remove('app_mode');
  }
}
