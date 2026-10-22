/// Model đại diện cho phản hồi từ API Xác thực ASP.NET Core
class AuthResponseModel {
  final bool status;
  final String message;
  final String? token;
  final int? statusCode;
  final dynamic errors;

  AuthResponseModel({
    required this.status,
    required this.message,
    this.token,
    this.statusCode,
    this.errors,
  });

  factory AuthResponseModel.fromJson(Map<String, dynamic> json) {
    return AuthResponseModel(
      status: json['status'] == true,
      message: (json['message'] ?? json['title'] ?? '').toString(),
      token: json['token'] as String?,
      statusCode: json['statusCode'] as int?,
      errors: json['errors'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'status': status,
      'message': message,
      if (token != null) 'token': token,
      if (statusCode != null) 'statusCode': statusCode,
      if (errors != null) 'errors': errors,
    };
  }
}
