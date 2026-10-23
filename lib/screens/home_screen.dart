import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:qr_flutter/qr_flutter.dart';
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
  double? _lat;
  double? _lng;
  double _decibel = 0.0;
  bool _isFallDetected = false;
  bool _isSosActive = false;
  String _alertMessage = 'Trạng thái bình thường';
  bool _isLocked = false;
  String _lockMessage = '';

  // Cờ kiểm soát chống gửi Telemetry trùng lặp
  bool _isTelemetrySending = false;

  // Dữ liệu Phụ huynh (Parent) từ Backend
  List<dynamic> _parentChildDevices = [];
  bool _isLoadingParentData = false;

  Timer? _telemetryTimer;
  Timer? _lockStatusTimer;
  StreamSubscription<Position>? _gpsSub;
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

    String? resolvedMode = appMode;

    if (resolvedMode == null && jwtToken != null && jwtToken.isNotEmpty) {
      resolvedMode = 'parent';
      await prefs.setString('app_mode', 'parent');
    }

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
      if (_childDeviceToken != null && _childDeviceToken!.isNotEmpty && _childDeviceId != null) {
        _startChildSensors();
      }
    } else if (_currentMode == 'parent') {
      _fetchParentData();
    }
  }

  // --- 1. CHỨC NĂNG CHILD (CẢM BIẾN & TELEMETRY LIÊN TỤC) ---
  Future<void> _startChildSensors() async {
    if (_childDeviceId == null || _childDeviceToken == null || _childDeviceToken!.isEmpty) return;

    // 1. Dòng GPS liên tục (Continuous Location Stream)
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.whileInUse || perm == LocationPermission.always) {
        _gpsSub?.cancel();
        _gpsSub = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
          ),
        ).listen(
          (Position pos) {
            if (mounted) {
              setState(() {
                _lat = pos.latitude;
                _lng = pos.longitude;
              });
            }
          },
          onError: (Object error) {
            debugPrint('Lỗi GPS Location Stream: $error');
          },
        );
      }
    } catch (e) {
      debugPrint('Không thể khởi tạo GPS: $e');
    }

    // 2. Microphone (Độ ồn)
    try {
      _noiseSub?.cancel();
      _noiseSub = NoiseMeter().noise.listen(
        (NoiseReading reading) {
          if (mounted) {
            setState(() => _decibel = reading.meanDecibel);
          }
        },
        onError: (Object error) {
          debugPrint('Lỗi Stream Microphone: $error');
        },
      );
    } catch (e) {
      debugPrint('Không thể khởi tạo Microphone: $e');
    }

    // 3. Gia tốc kế (Té ngã)
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

    // 4. Định kỳ 5 giây gửi Telemetry
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 5), (_) => _syncChildTelemetry());

    // 5. Định kỳ kiểm tra trạng thái khóa bằng X-Child-Token
    _lockStatusTimer?.cancel();
    _lockStatusTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkChildLockStatus());
  }

  // Gửi Telemetry với cờ kiểm soát trùng lặp & bảo toàn cờ té ngã
  Future<void> _syncChildTelemetry() async {
    if (_childDeviceId == null || _childDeviceToken == null || _childDeviceToken!.isEmpty) return;
    if (_isTelemetrySending) return; // Chống gửi request chồng lặp

    // Không gửi tọa độ giả (0.0, 0.0) khi chưa lấy được vị trí GPS thực
    if (_lat == null || _lng == null) return;

    _isTelemetrySending = true;

    final result = await ApiService.sendTelemetry(
      deviceId: _childDeviceId!,
      latitude: _lat!,
      longitude: _lng!,
      noiseDecibel: _decibel,
      isFallDetected: _isFallDetected,
      isSosActive: _isSosActive,
    );

    _isTelemetrySending = false;

    if (!mounted) return;

    if (result['status'] == true) {
      setState(() {
        _alertMessage = result['alertMessage'] ?? result['message'] ?? 'Trạng thái bình thường';
        // Chỉ reset cờ té ngã khi Backend đã nhận thành công!
        if (_isFallDetected) {
          _isFallDetected = false;
        }
      });
    }
  }

  // Kiểm tra trạng thái khóa đọc đúng isInstantLocked từ Backend
  Future<void> _checkChildLockStatus() async {
    if (_childDeviceId == null || _childDeviceToken == null || _childDeviceToken!.isEmpty) return;

    final res = await ApiService.getChildLockStatus(_childDeviceId!);

    if (!mounted) return;

    if (res['status'] == true) {
      final isLocked = res['isInstantLocked'] ?? res['isLocked'] ?? false;
      final msg = res['lockMessage'] ?? res['message'] ?? 'Ứng dụng đang bị giới hạn thời gian';

      setState(() {
        _isLocked = isLocked == true;
        _lockMessage = msg.toString();
      });
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

  // --- 2. CHỨC NĂNG PARENT (FULL CHILDMANAGEMENT CRUD & HISTORY) ---
  Future<void> _fetchParentData() async {
    if (_jwtToken == null || _jwtToken!.isEmpty) {
      _redirectToLogin();
      return;
    }

    setState(() => _isLoadingParentData = true);
    final result = await ApiService.getChildDevices();

    if (!mounted) return;

    final statusCode = result['statusCode'];
    if (statusCode == 401 || statusCode == 403) {
      _redirectToLogin();
      return;
    }

    // Backend trả danh sách dạng JSON Array trực tiếp
    final dynamic devicesList = result['devices'] ?? result['data'] ?? result['items'];

    if (result['status'] == true && devicesList is List) {
      setState(() {
        _parentChildDevices = devicesList;
        _isLoadingParentData = false;
      });
    } else {
      setState(() => _isLoadingParentData = false);
    }
  }

  // Form Thêm thiết bị trẻ (CREATE) có SingleChildScrollView & kiểm tra tuổi 1-17
  Future<void> _handleCreateChildDevice() async {
    final nameCtrl = TextEditingController();
    final deviceCtrl = TextEditingController();
    final ageCtrl = TextEditingController(text: '10');
    final messenger = ScaffoldMessenger.of(context);

    final shouldCreate = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Thêm Thiết Bị Trẻ Em Mới'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Tên của Trẻ (vd: Bé An)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: deviceCtrl,
                decoration: const InputDecoration(labelText: 'Tên Thiết Bị (vd: Samsung Galaxy)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ageCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Tuổi của Trẻ (1 - 17)', border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('THÊM MỚI')),
        ],
      ),
    );

    final childName = nameCtrl.text.trim();
    final deviceName = deviceCtrl.text.trim();
    final age = int.tryParse(ageCtrl.text.trim());

    nameCtrl.dispose();
    deviceCtrl.dispose();
    ageCtrl.dispose();

    if (shouldCreate == true && mounted) {
      if (childName.isEmpty || deviceName.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('Vui lòng nhập đầy đủ tên trẻ và tên thiết bị')));
        return;
      }

      if (age == null || age < 1 || age > 17) {
        messenger.showSnackBar(const SnackBar(content: Text('Tuổi của trẻ phải từ 1 đến 17 tuổi')));
        return;
      }

      final res = await ApiService.createChildDevice(childName: childName, deviceName: deviceName, age: age);
      if (!mounted) return;

      messenger.showSnackBar(SnackBar(content: Text(res['message'] ?? 'Thêm thiết bị thành công!')));
      _fetchParentData();
    }
  }

  // Form Sửa thông tin thiết bị trẻ (UPDATE)
  Future<void> _handleEditChildDevice(Map<String, dynamic> device) async {
    final dynamic rawId = device['id'] ?? device['deviceId'];
    if (rawId == null) return;
    final int deviceId = rawId is int ? rawId : int.parse(rawId.toString());

    final nameCtrl = TextEditingController(text: (device['childName'] ?? device['name'] ?? '').toString());
    final deviceCtrl = TextEditingController(text: (device['deviceName'] ?? '').toString());
    final ageCtrl = TextEditingController(text: (device['age'] ?? 10).toString());
    final messenger = ScaffoldMessenger.of(context);

    final shouldUpdate = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Chỉnh Sửa Thiết Bị #$deviceId'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Tên của Trẻ', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: deviceCtrl,
                decoration: const InputDecoration(labelText: 'Tên Thiết Bị', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ageCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Tuổi của Trẻ (1 - 17)', border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('LƯU THAY ĐỔI')),
        ],
      ),
    );

    final childName = nameCtrl.text.trim();
    final deviceName = deviceCtrl.text.trim();
    final age = int.tryParse(ageCtrl.text.trim());

    nameCtrl.dispose();
    deviceCtrl.dispose();
    ageCtrl.dispose();

    if (shouldUpdate == true && mounted) {
      if (childName.isEmpty || deviceName.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('Vui lòng nhập đầy đủ tên trẻ và tên thiết bị')));
        return;
      }

      if (age == null || age < 1 || age > 17) {
        messenger.showSnackBar(const SnackBar(content: Text('Tuổi của trẻ phải từ 1 đến 17 tuổi')));
        return;
      }

      final res = await ApiService.updateChildDevice(id: deviceId, childName: childName, deviceName: deviceName, age: age);
      if (!mounted) return;

      messenger.showSnackBar(SnackBar(content: Text(res['message'] ?? 'Cập nhật thiết bị thành công!')));
      _fetchParentData();
    }
  }

  // Xóa thiết bị trẻ (DELETE)
  Future<void> _handleDeleteChildDevice(int deviceId, String childName) async {
    final messenger = ScaffoldMessenger.of(context);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xác nhận xóa thiết bị'),
        content: Text('Bạn có chắc chắn muốn xóa thiết bị của "$childName" (ID: $deviceId)?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('XÓA'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final res = await ApiService.deleteChildDevice(deviceId);
      if (!mounted) return;

      messenger.showSnackBar(SnackBar(content: Text(res['message'] ?? 'Đã xóa thiết bị!')));
      _fetchParentData();
    }
  }

  // Parent Khóa thiết bị với SnackBar phản hồi chính xác từ Backend
  Future<void> _handleLockDevice(int deviceId) async {
    final messenger = ScaffoldMessenger.of(context);
    final res = await ApiService.lockDevice(deviceId);

    if (!mounted) return;

    if (res['status'] == true) {
      messenger.showSnackBar(SnackBar(content: Text(res['message'] ?? 'Đã khóa thiết bị!')));
    } else {
      messenger.showSnackBar(SnackBar(content: Text(res['message'] ?? 'Khóa thiết bị thất bại')));
    }
  }

  // Parent Mở khóa thiết bị với SnackBar phản hồi chính xác từ Backend
  Future<void> _handleUnlockDevice(int deviceId) async {
    final messenger = ScaffoldMessenger.of(context);
    final res = await ApiService.unlockDevice(deviceId);

    if (!mounted) return;

    if (res['status'] == true) {
      messenger.showSnackBar(SnackBar(content: Text(res['message'] ?? 'Đã mở khóa thiết bị!')));
    } else {
      messenger.showSnackBar(SnackBar(content: Text(res['message'] ?? 'Mở khóa thiết bị thất bại')));
    }
  }

  // Tạo mã QR ghép đôi thật hiển thị bằng QrImageView (Báo lỗi nếu Backend không trả về qrCode)
  Future<void> _handleCreatePairingQr(int deviceId) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await ApiService.createPairingQr(deviceId);

    if (!mounted) return;

    if (result['status'] == true) {
      final rawQr = result['qrCode'] ?? result['pairingCode'] ?? result['code'];
      if (rawQr == null || rawQr.toString().isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('Backend không trả về mã QR hợp lệ')));
        return;
      }

      final qrCode = rawQr.toString();
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('Mã QR Ghép Đôi (ID: $deviceId)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 200,
                height: 200,
                child: QrImageView(
                  data: qrCode,
                  version: QrVersions.auto,
                  size: 200.0,
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(
                qrCode,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text('Quét mã hoặc copy nhập thủ công trên máy Trẻ em.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: qrCode));
                messenger.showSnackBar(const SnackBar(content: Text('Đã sao chép mã ghép đôi!')));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Sao chép mã'),
            ),
            ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Đóng')),
          ],
        ),
      );
    } else {
      messenger.showSnackBar(SnackBar(content: Text(result['message'] ?? 'Không thể tạo mã QR')));
    }
  }

  // Xem Lịch sử Vị trí GPS của Trẻ đọc đúng recordedAt
  Future<void> _showDeviceLocationsDialog(int deviceId) async {
    final messenger = ScaffoldMessenger.of(context);
    final res = await ApiService.getDeviceLocations(deviceId);

    if (!mounted) return;

    if (res['status'] == true) {
      final dynamic list = res['data'] ?? res['items'] ?? res['locations'] ?? [];
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('Lịch Sử Vị Trí GPS (#$deviceId)'),
          content: SizedBox(
            width: double.maxFinite,
            child: list is List && list.isNotEmpty
                ? ListView.builder(
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (ctx, idx) {
                      final item = list[idx];
                      final timeStr = (item['recordedAt'] ?? item['timestamp'] ?? item['createdAt'] ?? 'Mới đây').toString();
                      return ListTile(
                        leading: const Icon(Icons.location_on, color: Colors.blue),
                        title: Text('Vĩ độ: ${item['latitude']} | Kinh độ: ${item['longitude']}'),
                        subtitle: Text('Thời gian: $timeStr'),
                      );
                    },
                  )
                : const Text('Chưa có lịch sử vị trí GPS.'),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Đóng'))],
        ),
      );
    } else {
      messenger.showSnackBar(SnackBar(content: Text(res['message'] ?? 'Không thể tải lịch sử vị trí')));
    }
  }

  // Xem Lịch sử Cảnh báo
  Future<void> _showDeviceAlertsDialog(int deviceId) async {
    final messenger = ScaffoldMessenger.of(context);
    final res = await ApiService.getDeviceAlerts(deviceId);

    if (!mounted) return;

    if (res['status'] == true) {
      final dynamic list = res['data'] ?? res['items'] ?? res['alerts'] ?? [];
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('Lịch Sử Cảnh Báo (#$deviceId)'),
          content: SizedBox(
            width: double.maxFinite,
            child: list is List && list.isNotEmpty
                ? ListView.builder(
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (ctx, idx) {
                      final item = list[idx];
                      final timeStr = (item['recordedAt'] ?? item['timestamp'] ?? item['createdAt'] ?? 'Mới đây').toString();
                      return ListTile(
                        leading: const Icon(Icons.warning, color: Colors.red),
                        title: Text((item['alertMessage'] ?? item['message'] ?? 'Cảnh báo').toString()),
                        subtitle: Text('Thời gian: $timeStr'),
                      );
                    },
                  )
                : const Text('Chưa có cảnh báo nào.'),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Đóng'))],
        ),
      );
    } else {
      messenger.showSnackBar(SnackBar(content: Text(res['message'] ?? 'Không thể tải lịch sử cảnh báo')));
    }
  }

  void _redirectToLogin() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  Future<void> _handleLogoutParent() async {
    _telemetryTimer?.cancel();
    _lockStatusTimer?.cancel();
    _gpsSub?.cancel();
    _noiseSub?.cancel();
    _accelSub?.cancel();

    await ApiService.logout();

    if (!mounted) return;
    _redirectToLogin();
  }

  Future<void> _handleResetChildMode() async {
    _telemetryTimer?.cancel();
    _lockStatusTimer?.cancel();
    _gpsSub?.cancel();
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

  Future<void> _selectChildMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_mode', 'child');
    setState(() => _currentMode = 'child');
    _loadPreferencesAndInitMode();
  }

  @override
  void dispose() {
    _telemetryTimer?.cancel();
    _lockStatusTimer?.cancel();
    _gpsSub?.cancel();
    _noiseSub?.cancel();
    _accelSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentMode == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('ChildCare'), centerTitle: true),
        body: _buildModeSelectionView(),
      );
    }

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
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
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
              onPressed: _redirectToLogin,
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
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            ),
          ],
        ),
      ),
    );
  }

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
              ElevatedButton.icon(
                onPressed: _handleCreateChildDevice,
                icon: const Icon(Icons.add),
                label: const Text('Thêm Trẻ'),
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
                    const Text('Chưa có thiết bị trẻ em nào được tạo.', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _handleCreateChildDevice,
                      icon: const Icon(Icons.add),
                      label: const Text('Tạo thiết bị trẻ em mới'),
                    ),
                  ],
                ),
              ),
            )
          else
            ..._parentChildDevices.map((device) {
              final deviceMap = device is Map<String, dynamic> ? device : Map<String, dynamic>.from(device as Map);
              final dynamic rawId = deviceMap['id'] ?? deviceMap['deviceId'];
              if (rawId == null) return const SizedBox.shrink();
              final int deviceId = rawId is int ? rawId : int.parse(rawId.toString());

              final childName = deviceMap['childName'] ?? deviceMap['name'] ?? 'Thiết bị trẻ #$deviceId';
              final deviceName = deviceMap['deviceName'] ?? 'Thiết bị #$deviceId';

              return Card(
                elevation: 3,
                margin: const EdgeInsets.only(bottom: 12.0),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.smartphone, color: Colors.indigo, size: 36),
                        title: Text('$childName ($deviceName)', style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('Device ID: $deviceId'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (val) {
                            if (val == 'edit') _handleEditChildDevice(deviceMap);
                            if (val == 'delete') _handleDeleteChildDevice(deviceId, childName.toString());
                            if (val == 'locations') _showDeviceLocationsDialog(deviceId);
                            if (val == 'alerts') _showDeviceAlertsDialog(deviceId);
                          },
                          itemBuilder: (ctx) => [
                            const PopupMenuItem(value: 'edit', child: Text('Chỉnh sửa')),
                            const PopupMenuItem(value: 'locations', child: Text('Lịch sử Vị trí')),
                            const PopupMenuItem(value: 'alerts', child: Text('Lịch sử Cảnh báo')),
                            const PopupMenuItem(value: 'delete', child: Text('Xóa thiết bị', style: TextStyle(color: Colors.red))),
                          ],
                        ),
                      ),
                      const Divider(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton.icon(
                            onPressed: () => _handleCreatePairingQr(deviceId),
                            icon: const Icon(Icons.qr_code, size: 18),
                            label: const Text('Tạo QR'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _handleLockDevice(deviceId),
                            icon: const Icon(Icons.lock, size: 18),
                            label: const Text('Khóa'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _handleUnlockDevice(deviceId),
                            icon: const Icon(Icons.lock_open, size: 18),
                            label: const Text('Mở Khóa'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildChildView() {
    if (_childDeviceToken == null || _childDeviceToken!.isEmpty || _childDeviceId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.qr_code_scanner, size: 100, color: Colors.purple),
              const SizedBox(height: 24),
              const Text('Thiết bị chưa ghép nối QR', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Text('Dùng máy Trẻ em để quét mã QR do Phụ huynh cung cấp.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
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
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
              ),
            ],
          ),
        ),
      );
    }

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
                const Text('GIAO DIỆN ỨNG DỤNG ĐÃ BỊ KHÓA', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(_lockMessage, style: const TextStyle(color: Colors.white70, fontSize: 16), textAlign: TextAlign.center),
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

        Card(
          elevation: 3,
          child: ListTile(
            leading: const Icon(Icons.location_on, color: Colors.blue, size: 36),
            title: const Text('Vị trí GPS', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(_lat != null && _lng != null ? 'Vĩ độ: $_lat | Kinh độ: $_lng' : 'Đang tìm tọa độ GPS...'),
          ),
        ),
        const SizedBox(height: 12),

        Card(
          elevation: 3,
          child: ListTile(
            leading: const Icon(Icons.mic, color: Colors.orange, size: 36),
            title: const Text('Mức độ tiếng ồn', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('${_decibel.toStringAsFixed(1)} dB'),
          ),
        ),
        const SizedBox(height: 12),

        Card(
          elevation: 3,
          color: _isFallDetected ? Colors.red.shade100 : Colors.grey.shade50,
          child: ListTile(
            leading: Icon(Icons.accessibility_new, color: _isFallDetected ? Colors.red : Colors.green, size: 36),
            title: Text('Cảnh báo Té ngã', style: TextStyle(fontWeight: FontWeight.bold, color: _isFallDetected ? Colors.red.shade900 : Colors.black87)),
            subtitle: Text(_isFallDetected ? '⚠️ PHÁT HIỆN TÉ NGÃ ĐỘT NGỘT!' : 'Bình thường', style: TextStyle(color: _isFallDetected ? Colors.red.shade900 : Colors.black54)),
          ),
        ),
        const SizedBox(height: 12),

        Card(
          elevation: 3,
          color: _isSosActive ? Colors.red.shade100 : Colors.grey.shade50,
          child: ListTile(
            leading: Icon(Icons.warning, color: _isSosActive ? Colors.red : Colors.grey, size: 36),
            title: Text('Cảnh báo SOS Khẩn Cấp', style: TextStyle(fontWeight: FontWeight.bold, color: _isSosActive ? Colors.red.shade900 : Colors.black87)),
            subtitle: Text(_isSosActive ? '🚨 ĐANG KÍCH HOẠT SOS!' : 'Tắt báo động SOS', style: TextStyle(color: _isSosActive ? Colors.red.shade900 : Colors.black54)),
            trailing: Switch(
              value: _isSosActive,
              activeThumbColor: Colors.red,
              onChanged: (val) {
                setState(() => _isSosActive = val);
                if (_lat == null || _lng == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Đang bật SOS. Đang chờ tọa độ GPS...')),
                  );
                } else {
                  _syncChildTelemetry();
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 12),

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
