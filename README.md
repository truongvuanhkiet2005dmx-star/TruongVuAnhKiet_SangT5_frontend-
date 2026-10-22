# 🛡️ ChildCare - Ứng Dụng Giám Sát An Toàn Trẻ Em

ChildCare là ứng dụng di động đa nền tảng phát triển bằng **Flutter**, kết nối trực tiếp với máy chủ Backend **ASP.NET Core 8 Web API** và cơ sở dữ liệu **SQL Server**. Ứng dụng cung cấp giải pháp giám sát an toàn toàn diện cho trẻ em với hai vai trò riêng biệt: **Phụ huynh (Parent)** và **Trẻ em (Child)**.

---

## 🌟 Tính Năng Nổi Bật

### 👨‍👩‍👧 1. Chế độ Phụ huynh (Parent Dashboard)
* **Đăng ký / Đăng nhập & Xác thực OTP**: Đăng ký tài khoản bằng Email, đăng nhập và xác thực mã 6 số OTP gửi qua Gmail.
* **Đăng nhập sinh trắc học (Local Auth)**: Hỗ trợ mở khóa nhanh bằng Vân tay khi đã có phiên đăng nhập JWT hợp lệ.
* **Tạo mã QR ghép đôi**: Sinh mã QR độc nhất cho từng thiết bị trẻ em qua API `POST /api/Pairing/create/{deviceId}`.
* **Quản lý thiết bị trẻ**: Danh sách thiết bị và trạng thái kết nối cập nhật từ Backend.
* **Đăng xuất an toàn**: Xóa JWT Token và bảo vệ thông tin quản lý.

### 👶 2. Chế độ Trẻ em (Child Device)
* **Ghép nối QR (Mobile Scanner)**: Sử dụng Camera quét mã QR của Phụ huynh để kết nối (`POST /api/Pairing/connect`), tự động lưu `child_device_token` và `child_device_id`.
* **Cảm biến GPS Vị trí**: Cập nhật tọa độ Vĩ độ & Kinh độ thời gian thực (`geolocator`).
* **Đo mức độ tiếng ồn**: Giám sát tiếng ồn môi trường xung quanh theo Decibel dB (`noise_meter`).
* **Phát hiện Té ngã Đột ngột**: Sử dụng Gia tốc kế (`sensors_plus`) nhận diện biến đổi vận tốc đột ngột > 25 m/s².
* **Báo động SOS Khẩn cấp**: Nút bấm kích hoạt cảnh báo SOS ngay lập tức.
* **Gửi Telemetry định kỳ**: Tự động gửi dữ liệu cảm biến 5 giây/lần bằng `X-Child-Token` về máy chủ (`POST /api/SafetyHistory/child/telemetry/{deviceId}`).
* **Khóa ứng dụng In-App & Xin gia hạn**: Tự động khóa giao diện ứng dụng khi bị giới hạn thời gian và cung cấp nút bấm **"Xin gia hạn 5 phút"** (`POST /api/ExtensionRequests/child`).

---

## 🛠️ Công Nghệ & Thư Viện Sử Dụng

| Thành phần | Công nghệ / Thư viện | Tác dụng |
| :--- | :--- | :--- |
| **Framework** | Flutter 3.x / Dart 3.x | Phát triển ứng dụng di động đa nền tảng |
| **UI System** | Material Design 3 | Giao diện hiện đại, responsive |
| **HTTP Client** | `http: ^1.6.0` | Gửi request REST API tới ASP.NET Core Backend |
| **Local Storage** | `shared_preferences: ^2.5.6` | Lưu JWT Token, Child Device Token, Device ID và `app_mode` |
| **Camera & QR** | `mobile_scanner: ^7.4.2` | Quét mã QR ghép đôi thiết bị |
| **Sinh trắc học** | `local_auth: ^3.0.2` | Mở khóa nhanh bằng Vân tay |
| **Định vị GPS** | `geolocator: ^14.1.2` | Lấy tọa độ GPS Vĩ độ & Kinh độ |
| **Đo tiếng ồn** | `noise_meter: ^6.0.0` | Giám sát mức độ tiếng ồn dB |
| **Cảm biến Gia tốc**| `sensors_plus: ^7.1.1` | Nhận diện sự cố té ngã |

---

## 📡 Bảng Danh Mục API Endpoint

| Tên hàm Flutter | Method | Endpoint Backend | Header Xác thực | Chức năng |
| :--- | :---: | :--- | :--- | :--- |
| `register` | `POST` | `/api/Authenticate/register` | None | Đăng ký tài khoản Phụ huynh |
| `login` | `POST` | `/api/Authenticate/login` | None | Đăng nhập Phụ huynh & Yêu cầu OTP |
| `verifyOtp` | `POST` | `/api/Authenticate/verify-otp` | None | Xác thực OTP & Nhận JWT Token |
| `pairDeviceByQr` | `POST` | `/api/Pairing/connect` | None | Child quét QR ghép nối thiết bị |
| `sendTelemetry` | `POST` | `/api/SafetyHistory/child/telemetry/{id}` | `X-Child-Token` | Child gửi vị trí GPS, Tiếng ồn, Té ngã, SOS |
| `requestExtension`| `POST` | `/api/ExtensionRequests/child` | `X-Child-Token` | Child xin gia hạn thời gian 5 phút |
| `createPairingQr` | `POST` | `/api/Pairing/create/{id}` | `Authorization: Bearer <jwt>` | Parent tạo mã QR ghép đôi |
| `getChildDevices` | `GET` | `/api/ChildManagement/devices` | `Authorization: Bearer <jwt>` | Parent xem danh sách thiết bị trẻ |

---

## 🚀 Hướng Dẫn Cài Đặt & Chạy Dự Án

### 1. Yêu cầu môi trường
* Flutter SDK >= 3.13.3
* Android Studio / VS Code
* Android SDK (API 21+) hoặc Máy ảo Android Emulator / Thiết bị thật

### 2. Cài đặt các thư viện
Mở Terminal tại thư mục dự án và chạy:
```bash
flutter pub get
```

### 3. Cấu hình Backend URL
Mở file `lib/services/api_service.dart` và cập nhật địa chỉ Conveyor Cloud / Localhost:
```dart
static const String baseUrl = 'https://littlebluepen95.conveyor.cloud/api';
```

### 4. Kiểm thử tự động & Biên dịch APK
```bash
# Kiểm tra tĩnh mã nguồn
flutter analyze

# Chạy bộ unit/widget test
flutter test

# Biên dịch file APK thử nghiệm
flutter build apk --debug
```

### 5. Chạy ứng dụng trên thiết bị / máy ảo
```bash
flutter run
```

---

## 👨‍💻 Tác Giả & Đồ Án
* **Sinh viên thực hiện**: Trương Vũ Anh Kiệt
* **Tên Đồ án**: ChildCare - Hệ Thống Giám Sát An Toàn Trẻ Em
* **Repository Frontend**: [TruongVuAnhKiet_SangT5_frontend-](https://github.com/truongvuanhkiet2005dmx-star/TruongVuAnhKiet_SangT5_frontend-.git)
