import 'dart:convert';
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

    String code = barcodes.first.rawValue!.trim();

    // Nếu barcode chứa chuỗi JSON, tự động trích xuất thuộc tính qrCode / pairingCode
    if (code.startsWith('{') && code.endsWith('}')) {
      try {
        final parsedJson = jsonDecode(code);
        if (parsedJson is Map) {
          code = (parsedJson['qrCode'] ??
                  parsedJson['pairingCode'] ??
                  parsedJson['code'] ??
                  code)
              .toString();
        }
      } catch (_) {}
    }

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

  // Phương thức cho phép nhập mã ghép đôi thủ công (Hữu ích khi test trên Máy ảo không có Camera)
  Future<void> _showManualInputDialog() async {
    final controller = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final manualCode = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nhập mã ghép đôi thủ công'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Nhập hoặc dán mã QR / Pairing code...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('XÁC NHẬN'),
          ),
        ],
      ),
    );

    if (manualCode == null || manualCode.isEmpty) return;

    setState(() => _isProcessing = true);

    final result = await ApiService.pairDeviceByQr(manualCode);

    if (!mounted) return;

    if (result['status'] == true) {
      messenger.showSnackBar(
        SnackBar(content: Text(result['message'] ?? 'Ghép đôi thành công!')),
      );
      navigator.pop(true);
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(result['message'] ?? 'Mã ghép đôi không hợp lệ')),
      );
      setState(() => _isProcessing = false);
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
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_note),
            tooltip: 'Nhập mã ghép đôi thủ công',
            onPressed: _showManualInputDialog,
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Khung MobileScanner toàn màn hình với errorBuilder xử lý khi không có Camera
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.camera_alt_outlined, size: 80, color: Colors.orange),
                      const SizedBox(height: 16),
                      const Text(
                        'Camera máy ảo không khả dụng',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Bạn có thể nhập hoặc dán mã ghép đôi thủ công bằng nút bấm bên dưới.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _showManualInputDialog,
                        icon: const Icon(Icons.edit),
                        label: const Text('Nhập Mã Thủ Công'),
                      ),
                    ],
                  ),
                ),
              );
            },
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
