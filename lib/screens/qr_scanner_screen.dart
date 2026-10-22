import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/api_service.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _isProcessing = false;

  void _onDetect(BarcodeCapture capture) async {
    if (_isProcessing) return;

    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isEmpty || barcodes.first.rawValue == null) return;

    final String code = barcodes.first.rawValue!;

    // 1. Lập tức dừng quét và bật trạng thái đang xử lý
    setState(() => _isProcessing = true);
    await _controller.stop();

    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // 2. Gọi API ghép đôi thiết bị
    final result = await ApiService.pairDeviceByQr(code);

    if (!mounted) return;

    if (result['status'] == true) {
      // 3. Nếu thành công: Báo tin nhắn và quay lại màn hình trước
      messenger.showSnackBar(
        SnackBar(content: Text(result['message'] ?? 'Ghép đôi thành công!')),
      );
      navigator.pop(true);
    } else {
      // 4. Nếu lỗi: Báo lỗi, tắt cờ xử lý và mở lại máy quét
      messenger.showSnackBar(
        SnackBar(content: Text(result['message'] ?? 'Mã QR không hợp lệ hoặc lỗi ghép đôi')),
      );
      setState(() => _isProcessing = false);
      _controller.start();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quét QR Ghép Đôi'),
        centerTitle: true,
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Khung MobileScanner toàn màn hình
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),

          // Khung vuông hướng dẫn quét
          Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.green, width: 3),
              borderRadius: BorderRadius.circular(16),
            ),
          ),

          // 2. Vòng xoay tải (CircularProgressIndicator) phủ lên màn hình khi đang gọi API
          if (_isProcessing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'Đang xử lý ghép đôi...',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
