import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import 'home_screen.dart';
import 'otp_verify_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final LocalAuthentication _auth = LocalAuthentication();

  bool _isLoading = false;
  bool _obscurePassword = true;

  // 1. Đăng nhập và chuyển hướng sang màn hình nhập OTP
  Future<void> _handleLogin() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng nhập đầy đủ tên đăng nhập và mật khẩu')),
      );
      return;
    }

    setState(() => _isLoading = true);

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final result = await ApiService.login(username, password);

    setState(() => _isLoading = false);

    if (!mounted) return;

    if (result['status'] == true) {
      messenger.showSnackBar(
        SnackBar(content: Text(result['message'] ?? 'Mã OTP đã được gửi về Gmail!')),
      );
      // Chuyển hướng sang OtpVerifyScreen và truyền biến username
      navigator.push(
        MaterialPageRoute(
          builder: (_) => OtpVerifyScreen(username: username),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(result['message'] ?? 'Đăng nhập thất bại')),
      );
    }
  }

  // 2. Mở nhanh bằng sinh trắc học khi ĐÃ CÓ phiên JWT Phụ huynh hợp lệ trước đó
  Future<void> _handleBiometricAuth() async {
    final prefs = await SharedPreferences.getInstance();
    final jwtToken = prefs.getString('jwt_token');

    // Chỉ cho phép mở bằng vân tay khi ĐÃ CÓ phiên đăng nhập JWT hợp lệ
    if (jwtToken == null || jwtToken.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chưa có phiên đăng nhập. Vui lòng nhập tên tài khoản, mật khẩu và xác thực OTP!'),
        ),
      );
      return;
    }

    try {
      final bool canAuthenticateWithBiometrics = await _auth.canCheckBiometrics;
      final bool canAuthenticate = canAuthenticateWithBiometrics || await _auth.isDeviceSupported();

      if (!canAuthenticate) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Thiết bị không hỗ trợ hoặc chưa cài đặt sinh trắc học')),
        );
        return;
      }

      final bool didAuthenticate = await _auth.authenticate(
        localizedReason: 'Vui lòng quét vân tay để mở nhanh ứng dụng Phụ huynh',
        biometricOnly: true,
      );

      if (didAuthenticate && mounted) {
        await prefs.setString('app_mode', 'parent');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Xác thực vân tay thành công!')),
        );
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi sinh trắc học: $e')),
      );
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Đăng nhập ChildCare'),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.shield_outlined,
                size: 80,
                color: Colors.blue,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'Tên đăng nhập',
                  prefixIcon: Icon(Icons.person),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Mật khẩu',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _handleLogin,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('ĐĂNG NHẬP', style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RegisterScreen()),
                  );
                },
                child: const Text('Chưa có tài khoản? Đăng ký ngay'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _handleBiometricAuth,
                icon: const Icon(Icons.fingerprint, size: 28),
                label: const Text('Đăng nhập nhanh bằng vân tay'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
