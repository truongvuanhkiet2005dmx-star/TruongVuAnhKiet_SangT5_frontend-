import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import 'login_screen.dart';
import 'qr_scanner_screen.dart';

class HomeScreen extends StatefulWidget {
  final int? deviceId;
  const HomeScreen({super.key, this.deviceId});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Trạng thái Chế độ ứng dụng: 'parent', 'child' hoặc null (Chưa chọn)
  String? _currentMode;

  // Token và ID từ SharedPreferences
  int? _childDeviceId;
  String? _childDeviceToken;
  String? _jwtToken;

  // Dữ liệu cảm biến trên thiết bị Trẻ em (Child)
  double _lat = 0.0;
  double _lng = 0.0;
  double _decibel = 0.0;
  bool _isFallDetected = false;
  bool _isSosActive = false;
  String _alertMessage = 'Trạng thái bình thường';
  bool _isLocked = false;
  String _lockMessage = '';

  // Dữ liệu Phụ huynh (Parent) từ Backend
  List<dynamic> _parentChildDevices = [];
  bool _isLoadingParentData = false;

  Timer? _telemetryTimer;
  StreamSubscription<NoiseReading>? _noiseSub;
  StreamSubscription<UserAccelerometerEvent>? _accelSub;

  @override
  void initState() {
    super.initState();
    _loadPreferencesAndInitMode();
  }

  // Khởi tạo và đọc chế độ app_mode từ SharedPreferences
  Future<void> _loadPreferencesAndInitMode() async {
    final prefs = await SharedPreferences.getInstance();
    final appMode = prefs.getString('app_mode');
    final jwtToken = prefs.getString('jwt_token');
    final childToken = prefs.getString('child_device_token');
    final childId = widget.deviceId ?? prefs.getInt('child_device_id');

    if (!mounted) return;

    // Phân định chế độ rõ ràng
    String? resolvedMode = appMode;

    // Nếu vừa xác thực Parent (có JWT) -> Tự động nhận diện Parent
    if (resolvedMode == null && jwtToken != null && jwtToken.isNotEmpty) {
      resolvedMode = 'parent';
      await prefs.setString('app_mode', 'parent');
    }

    // Nếu đã ghép nối thiết bị Child (có child_device_token) -> Nhận diện Child
    if (resolvedMode == null && childToken != null && childToken.isNotEmpty) {
      resolvedMode = 'child';
      await prefs.setString('app_mode', 'child');
    }

    setState(() {
      _currentMode = resolvedMode;
      _jwtToken = jwtToken;
      _childDeviceToken = childToken;
      _childDeviceId = childId;
    });

    if (_currentMode == 'child') {
      // Chỉ khởi động cảm biến khi ở chế độ Child đã có ghép nối
      if (_childDeviceToken != null && _childDeviceToken!.isNotEmpty && _childDeviceId != null) {
        _startChildSensors();
      }
    } else if (_currentMode == 'parent') {
      // Chế độ Parent: kiểm tra JWT và tải danh sách thiết bị
      _fetchParentData();
    }
  }

  // --- 1. CHỨC NĂNG CHILD (CẢM BIẾN & TELEMETRY TỰ BẢO VỆ LỖI STREAM) ---
  Future<void> _startChildSensors() async {
    if (_childDeviceId == null || _childDeviceToken == null || _childDeviceToken!.isEmpty) return;

    // 1. GPS Location với try-catch an toàn
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.whileInUse || perm == LocationPermission.always) {
        Position pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
        if (mounted) {
          setState(() {
            _lat = pos.latitude;
            _lng = pos.longitude;
          });
        }
      }
    } catch (e) {
      debugPrint('Không thể lấy vị trí GPS: $e');
    }

    // 2. Microphone (Độ ồn) - Bắt lỗi Async Stream onError tránh văng app
    try {
      _noiseSub?.cancel();
      _noiseSub = NoiseMeter().noise.listen(
        (NoiseReading reading) {
          if (mounted) {
            setState(() => _decibel = reading.meanDecibel);
          }
        },
        onError: (Object error) {
          debugPrint('Lỗi Stream Microphone (NoiseMeter): $error');
        },
      );
    } catch (e) {
      debugPrint('Không thể khởi tạo Microphone: $e');
    }

    // 3. Gia tốc kế - Bắt lỗi Async Stream onError tránh văng app
    try {
      _accelSub?.cancel();
      _accelSub = userAccelerometerEventStream().listen(
        (event) {
          if (event.x.abs() > 25 || event.y.abs() > 25 || event.z.abs() > 25) {
            if (mounted) {
              setState(() => _isFallDetected = true);
            }
          }
        },
        onError: (Object error) {
          debugPrint('Lỗi Stream Gia tốc kế: $error');
        },
      );
    } catch (e) {
      debugPrint('Không thể khởi tạo Gia tốc kế: $e');
    }

    // 4. Định kỳ 5 giây gửi Telemetry bằng X-Child-Token
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 5), (_) => _syncChildTelemetry());
  }

  Future<void> _syncChildTelemetry() async {
    if (_childDeviceId == null || _childDeviceToken == null || _childDeviceToken!.isEmpty) return;

    final result = await ApiService.sendTelemetry(
      deviceId: _childDeviceId!,
      latitude: _lat,
      longitude: _lng,
      noiseDecibel: _decibel,
      isFallDetected: _isFallDetected,
      isSosActive: _isSosActive,
    );

    if (!mounted) return;

    if (result['status'] == true) {
      setState(() {
        _isLocked = result['isInstantLocked'] ?? false;
        _lockMessage = result['lockMessage'] ?? 'Ứng dụng đang bị giới hạn thời gian';
        _alertMessage = result['alertMessage'] ?? 'Trạng thái bình thường';
      });
    }

    if (_isFallDetected) {
      setState(() => _isFallDetected = false);
    }
  }

  // Child xin gia hạn 5 phút
  Future<void> _handleRequestExtension() async {
    if (_childDeviceId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final res = await ApiService.requestExtension(_childDeviceId!);

    if (!mounted) return;

    messenger.showSnackBar(
      SnackBar(content: Text(res['message'] ?? 'Đã gửi yêu cầu gia hạn!')),
    );
  }

  // --- 2. CHỨC NĂNG PARENT (DASHBOARD & PAIRING QR CREATION) ---
  Future<void> _fetchParentData() async {
    if (_jwtToken == null || _jwtToken!.isEmpty) {
      _redirectToLogin();
      return;
    }

    setState(() => _isLoadingParentData = true);
    final result = await ApiService.getChildDevices();

    if (!mounted) return;

    // Kiểm tra trực tiếp statusCode HTTP 401 hoặc 403
    final statusCode = result['statusCode'];
    if (statusCode == 401 || statusCode == 403) {
      _redirectToLogin();
      return;
    }

    if (result['status'] == true && result['devices'] is List) {
      setState(() {
        _parentChildDevices = result['devices'];
        _isLoadingParentData = false;
      });
    } else {
      setState(() => _isLoadingParentData = false);
    }
  }

  // Chuyển hướng về màn hình đăng nhập nếu chưa xác thực Parent
  void _redirectToLogin() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  // Parent tạo mã QR ghép đôi cho thiết bị trẻ
  Future<void> _handleCreatePairingQr(int deviceId) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await ApiService.createPairingQr(deviceId);

    if (!mounted) return;

    if (result['status'] == true) {
      final qrCode = result['qrCode'] ?? result['pairingCode'] ?? 'Mã QR ghép nối';
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('Mã QR Ghép Đôi (ID: $deviceId)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.qr_code_2, size: 120, color: Colors.blue),
              const SizedBox(height: 16),
              SelectableText(
                qrCode.toString(),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 2),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text('Cho thiết bị Trẻ em quét mã này để hoàn tất ghép nối.', textAlign: TextAlign.center),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: qrCode.toString()));
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Đã sao chép mã ghép đôi vào bộ nhớ tạm!'),
                  ),
                );
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Sao chép mã'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'),
            ),
          ],
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(result['message'] ?? 'Không thể tạo mã QR')),
      );
    }
  }

  // Đăng xuất Parent (Xóa jwt_token và app_mode của Parent)
  Future<void> _handleLogoutParent() async {
    _telemetryTimer?.cancel();
    _noiseSub?.cancel();
    _accelSub?.cancel();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('jwt_token');
    await prefs.remove('app_mode');

    if (!mounted) return;

    _redirectToLogin();
  }

  // Đổi vai trò Child về Màn hình chọn vai trò
  Future<void> _handleResetChildMode() async {
    _telemetryTimer?.cancel();
    _noiseSub?.cancel();
    _accelSub?.cancel();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('app_mode');
    await prefs.remove('child_device_token');
    await prefs.remove('child_device_id');

    if (!mounted) return;

    setState(() {
      _currentMode = null;
      _childDeviceToken = null;
      _childDeviceId = null;
    });
  }

  // Đặt chế độ Child và lưu SharedPreferences
  Future<void> _selectChildMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_mode', 'child');
    setState(() => _currentMode = 'child');
    _loadPreferencesAndInitMode();
  }

  @override
  void dispose() {
    _telemetryTimer?.cancel();
    _noiseSub?.cancel();
    _accelSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 1. Nếu chưa xác định chế độ (app_mode chưa có trong SharedPreferences)
    if (_currentMode == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('ChildCare'),
          centerTitle: true,
        ),
        body: _buildModeSelectionView(),
      );
    }

    // 2. Chế độ Child (Trẻ em)
    if (_currentMode == 'child') {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Thiết Bị Trẻ Em (Child)'),
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.swap_horiz),
              tooltip: 'Đổi vai trò / Đăng xuất Child',
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Chuyển vai trò thiết bị'),
                    content: const Text('Bạn có muốn thoát chế độ Trẻ em để về màn hình Chọn vai trò ban đầu?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Hủy'),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _handleResetChildMode();
                        },
                        child: const Text('ĐỒNG Ý'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        body: _buildChildView(),
      );
    }

    // 3. Chế độ Parent (Phụ huynh)
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard Phụ Huynh'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Đăng xuất Phụ huynh',
            onPressed: _handleLogoutParent,
          ),
        ],
      ),
      body: _buildParentView(),
    );
  }

  // --- GIAO DIỆN CHỌN CHẾ ĐỘ NẾU CHƯA THIẾT LẬP ---
  Widget _buildModeSelectionView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.shield, size: 90, color: Colors.blue),
            const SizedBox(height: 24),
            const Text(
              'Chào mừng bạn đến với ChildCare',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Vui lòng chọn vai trò của thiết bị này:',
              style: TextStyle(fontSize: 16, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () {
                // Đăng nhập Phụ huynh
                _redirectToLogin();
              },
              icon: const Icon(Icons.supervisor_account, size: 28),
              label: const Text('PHỤ HUYNH (PARENT)', style: TextStyle(fontSize: 16)),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Colors.blue.shade800,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _selectChildMode,
              icon: const Icon(Icons.child_care, size: 28),
              label: const Text('TRẺ EM (CHILD)', style: TextStyle(fontSize: 16)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- GIAO DIỆN PARENT ---
  Widget _buildParentView() {
    return RefreshIndicator(
      onRefresh: _fetchParentData,
      child: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Card(
            elevation: 2,
            color: Colors.blue.shade50,
            child: const ListTile(
              leading: Icon(Icons.admin_panel_settings, color: Colors.blue, size: 36),
              title: Text('Chế độ Quản lý Phụ Huynh', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Quản lý danh sách thiết bị trẻ em và tạo mã QR ghép nối bằng tài khoản Phụ huynh.'),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Danh Sách Thiết Bị Trẻ', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _fetchParentData,
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (_isLoadingParentData)
            const Center(child: Padding(padding: EdgeInsets.all(24.0), child: CircularProgressIndicator()))
          else if (_parentChildDevices.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    const Icon(Icons.devices_other, size: 60, color: Colors.grey),
                    const SizedBox(height: 12),
                    const Text('Chưa có thiết bị trẻ em nào được kết nối.', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () => _handleCreatePairingQr(1),
                      icon: const Icon(Icons.qr_code_2),
                      label: const Text('Tạo mã QR ghép đôi thiết bị #1'),
                    ),
                  ],
                ),
              ),
            )
          else
            ..._parentChildDevices.map((device) {
              final deviceId = device['id'] ?? device['deviceId'] ?? 1;
              final deviceName = device['name'] ?? device['deviceName'] ?? 'Thiết bị trẻ #$deviceId';
              return Card(
                elevation: 3,
                margin: const EdgeInsets.only(bottom: 12.0),
                child: ListTile(
                  leading: const Icon(Icons.smartphone, color: Colors.indigo, size: 36),
                  title: Text(deviceName.toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('Device ID: $deviceId'),
                  trailing: ElevatedButton.icon(
                    onPressed: () => _handleCreatePairingQr(deviceId as int),
                    icon: const Icon(Icons.qr_code, size: 18),
                    label: const Text('Tạo QR'),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  // --- GIAO DIỆN CHILD ---
  Widget _buildChildView() {
    // Nếu chưa ghép nối QR (Chưa có child_device_id / child_device_token)
    if (_childDeviceToken == null || _childDeviceToken!.isEmpty || _childDeviceId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.qr_code_scanner, size: 100, color: Colors.purple),
              const SizedBox(height: 24),
              const Text(
                'Thiết bị chưa ghép nối QR',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'Dùng máy Trẻ em để quét mã QR do Phụ huynh cung cấp.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () async {
                  final paired = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(builder: (_) => const QrScannerScreen()),
                  );
                  if (paired == true) {
                    _loadPreferencesAndInitMode();
                  }
                },
                icon: const Icon(Icons.camera_alt),
                label: const Text('Quét Mã QR Kết Nối'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Nếu ứng dụng bị khóa giao diện tức thì trong Flutter App
    if (_isLocked) {
      return Container(
        color: Colors.red.shade900,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_clock, size: 80, color: Colors.white),
                const SizedBox(height: 16),
                const Text(
                  'GIAO DIỆN ỨNG DỤNG ĐÃ BỊ KHÓA',
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  _lockMessage,
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _handleRequestExtension,
                  icon: const Icon(Icons.timer),
                  label: const Text('Xin gia hạn 5 phút'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Màn hình Cảm biến & Telemetry trên thiết bị Child
    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        Card(
          elevation: 2,
          color: Colors.green.shade50,
          child: ListTile(
            leading: const Icon(Icons.check_circle, color: Colors.green, size: 36),
            title: const Text('Thiết bị đã ghép nối Trẻ em', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('Child Device ID: $_childDeviceId\nĐang gửi Telemetry định kỳ.'),
          ),
        ),
        const SizedBox(height: 12),

        // GPS
        Card(
          elevation: 3,
          child: ListTile(
            leading: const Icon(Icons.location_on, color: Colors.blue, size: 36),
            title: const Text('Vị trí GPS', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('Vĩ độ: $_lat | Kinh độ: $_lng'),
          ),
        ),
        const SizedBox(height: 12),

        // Tiếng ồn
        Card(
          elevation: 3,
          child: ListTile(
            leading: const Icon(Icons.mic, color: Colors.orange, size: 36),
            title: const Text('Mức độ tiếng ồn', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('${_decibel.toStringAsFixed(1)} dB'),
          ),
        ),
        const SizedBox(height: 12),

        // Cảnh báo Té ngã
        Card(
          elevation: 3,
          color: _isFallDetected ? Colors.red.shade100 : Colors.grey.shade50,
          child: ListTile(
            leading: Icon(
              Icons.accessibility_new,
              color: _isFallDetected ? Colors.red : Colors.green,
              size: 36,
            ),
            title: Text(
              'Cảnh báo Té ngã',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: _isFallDetected ? Colors.red.shade900 : Colors.black87,
              ),
            ),
            subtitle: Text(
              _isFallDetected ? '⚠️ PHÁT HIỆN TÉ NGÃ ĐỘT NGỘT!' : 'Bình thường',
              style: TextStyle(color: _isFallDetected ? Colors.red.shade900 : Colors.black54),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Cảnh báo SOS
        Card(
          elevation: 3,
          color: _isSosActive ? Colors.red.shade100 : Colors.grey.shade50,
          child: ListTile(
            leading: Icon(
              Icons.warning,
              color: _isSosActive ? Colors.red : Colors.grey,
              size: 36,
            ),
            title: Text(
              'Cảnh báo SOS Khẩn Cấp',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: _isSosActive ? Colors.red.shade900 : Colors.black87,
              ),
            ),
            subtitle: Text(
              _isSosActive ? '🚨 ĐANG KÍCH HOẠT SOS!' : 'Tắt báo động SOS',
              style: TextStyle(color: _isSosActive ? Colors.red.shade900 : Colors.black54),
            ),
            trailing: Switch(
              value: _isSosActive,
              activeThumbColor: Colors.red,
              onChanged: (val) {
                setState(() => _isSosActive = val);
                _syncChildTelemetry();
              },
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Card thông báo từ Máy Chủ
        if (_alertMessage.isNotEmpty)
          Card(
            elevation: 2,
            color: Colors.blue.shade50,
            child: ListTile(
              leading: const Icon(Icons.info, color: Colors.blue),
              title: const Text('Thông báo từ Máy chủ'),
              subtitle: Text(_alertMessage),
            ),
          ),
        const SizedBox(height: 12),

        // Nút Xin gia hạn 5 phút
        ElevatedButton.icon(
          onPressed: _handleRequestExtension,
          icon: const Icon(Icons.timer),
          label: const Text('Xin gia hạn 5 phút'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blue.shade800,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(50),
          ),
        ),
      ],
    );
  }
}
