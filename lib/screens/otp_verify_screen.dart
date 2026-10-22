import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import 'home_screen.dart';

class OtpVerifyScreen extends StatefulWidget {
  final String username;

  const OtpVerifyScreen({super.key, required this.username});

  @override
  State<OtpVerifyScreen> createState() => _OtpVerifyScreenState();
}

class _OtpVerifyScreenState extends State<OtpVerifyScreen> {
  final TextEditingController _otpController = TextEditingController();
  bool _isLoading = false;

  Future<void> _handleVerifyOtp() async {
    final otp = _otpController.text.trim();

    if (otp.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng nhập đúng 6 chữ số OTP')),
      );
      return;
    }

    setState(() => _isLoading = true);

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // 1. Gọi API xác thực OTP
    final verifyResult = await ApiService.verifyOtp(widget.username, otp);

    setState(() => _isLoading = false);

    if (!mounted) return;

    // 2. Kiểm tra xác thực có thực sự thành công hay không
    final prefs = await SharedPreferences.getInstance();
    final jwtToken = prefs.getString('jwt_token');

    if (verifyResult['status'] == true && jwtToken != null && jwtToken.isNotEmpty) {
      // Chỉ khi xác thực thành công VÀ đã lưu jwt_token mới đánh dấu app_mode = 'parent'
      await prefs.setString('app_mode', 'parent');

      if (!mounted) return;

      messenger.showSnackBar(
        SnackBar(content: Text(verifyResult['message'] ?? 'Xác thực Phụ huynh thành công!')),
      );

      // Điều hướng đến HomeScreen và xóa toàn bộ luồng đăng nhập/OTP khỏi Navigation Stack
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    } else {
      // Nếu OTP sai, hết hạn hoặc lỗi Backend: không lưu app_mode = 'parent' và không điều hướng
      messenger.showSnackBar(
        SnackBar(content: Text(verifyResult['message'] ?? 'Mã OTP không chính xác hoặc đã hết hạn')),
      );
    }
  }

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Xác thực mã OTP Phụ huynh'),
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
                Icons.mark_email_read_outlined,
                size: 80,
                color: Colors.blue,
              ),
              const SizedBox(height: 24),
              Text(
                'Mã OTP 6 số đã được gửi đến Gmail của tài khoản "${widget.username}".',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  hintText: '123456',
                  counterText: '',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.key),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _handleVerifyOtp,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('XÁC NHẬN OTP', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
