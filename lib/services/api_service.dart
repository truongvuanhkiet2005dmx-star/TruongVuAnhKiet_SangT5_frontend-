
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  // Dia chi Backend hien tai
  static const String baseUrl =
      'https://littlebluepen95.conveyor.cloud/api';

  // Header danh cho Parent (JWT)
  static Future<Map<String, String>> _getHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('jwt_token');

    return {
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty)
        'Authorization': 'Bearer $token',
    };
  }

  // Header danh cho Child (Device Token)
  static Future<Map<String, String>> _getChildHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('child_device_token');

    return {
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty)
        'X-Child-Token': token,
    };
  }

  // Xu ly ket qua API
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
        'status': response.statusCode >= 200 &&
            response.statusCode < 300,
        'statusCode': response.statusCode,
        'message': response.body,
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

  // 1. Dang ky tai khoan
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
        }),
      ).timeout(const Duration(seconds: 20));

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Khong the dang ky: $e',
      };
    }
  }

  // 2. Dang nhap Parent
  static Future<Map<String, dynamic>> login(
      String username,
      String password,
      ) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Authenticate/login'),
        headers: await _getHeaders(),
        body: jsonEncode({
          'username': username,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 20));

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi dang nhap: $e',
      };
    }
  }

  // 3. Xac thuc OTP
  static Future<Map<String, dynamic>> verifyOtp(
      String username,
      String otpCode,
      ) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Authenticate/verify-otp'),
        headers: await _getHeaders(),
        body: jsonEncode({
          'username': username,
          'otpCode': otpCode,
        }),
      ).timeout(const Duration(seconds: 20));

      final data = _parseResponse(response);

      if (data['status'] == true &&
          data['token'] is String) {
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

  // 4. Child quet QR de ghep noi
  static Future<Map<String, dynamic>> pairDeviceByQr(
      String qrCode,
      ) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Pairing/connect'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'qrCode': qrCode.trim(),
        }),
      ).timeout(const Duration(seconds: 20));

      final data = _parseResponse(response);

      if (data['status'] == true) {
        final token = data['deviceToken'];

        if (token is! String || token.isEmpty) {
          return {
            'status': false,
            'message': 'Server khong tra ve deviceToken',
          };
        }

        final prefs = await SharedPreferences.getInstance();

        await prefs.setString(
          'child_device_token',
          token,
        );

        final deviceId = data['deviceId'];

        if (deviceId is int) {
          await prefs.setInt(
            'child_device_id',
            deviceId,
          );
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

  // 5. Child gui GPS, tieng on, te nga va SOS
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
      ).timeout(const Duration(seconds: 20));

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi gui telemetry: $e',
      };
    }
  }

  // 6. Child xin gia han 5 phut
  // appName phai trung voi ten ung dung da gioi han
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
      ).timeout(const Duration(seconds: 20));

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi xin gia han: $e',
      };
    }
  }

  // 7. Parent tao ma QR ghep noi cho thiet bi tre
  static Future<Map<String, dynamic>> createPairingQr(int deviceId) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/Pairing/create/$deviceId'),
        headers: await _getHeaders(),
      ).timeout(const Duration(seconds: 20));

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi tao ma QR: $e',
      };
    }
  }

  // 8. Parent lay danh sach thiet bi tre em
  static Future<Map<String, dynamic>> getChildDevices() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/ChildManagement/devices'),
        headers: await _getHeaders(),
      ).timeout(const Duration(seconds: 20));

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi lay danh sach thiet bi: $e',
      };
    }
  }

  // 9. Parent xem telemetry va trang thai cua thiet bi tre
  static Future<Map<String, dynamic>> getDeviceTelemetry(int deviceId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/SafetyHistory/parent/telemetry/$deviceId'),
        headers: await _getHeaders(),
      ).timeout(const Duration(seconds: 20));

      return _parseResponse(response);
    } catch (e) {
      return {
        'status': false,
        'message': 'Loi lay du lieu giam sat: $e',
      };
    }
  }
}
