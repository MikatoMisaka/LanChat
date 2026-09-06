import 'server_profile.dart';

enum ServerFormField { baseUrl, username, password, displayName, inviteCode }

class ServerFormValidator {
  static Map<ServerFormField, String> validate({
    required String baseUrl,
    required String username,
    required String password,
    required String displayName,
    required String inviteCode,
    required bool isJoining,
    bool passwordRequired = true,
  }) {
    final errors = <ServerFormField, String>{};
    try {
      ServerProfile.normalizeBaseUrl(baseUrl);
    } on ArgumentError {
      errors[ServerFormField.baseUrl] = '请输入有效的 http 或 https 服务器地址。';
    }
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{2,31}$').hasMatch(username.trim())) {
      errors[ServerFormField.username] = '用户名需要 3-32 位小写字母、数字、下划线或短横线。';
    }
    if (passwordRequired && (password.length < 8 || password.length > 128)) {
      errors[ServerFormField.password] = '密码需要 8-128 位，可使用任意字符。';
    }
    final nameLength = displayName.trim().runes.length;
    if (isJoining && (nameLength < 1 || nameLength > 64)) {
      errors[ServerFormField.displayName] = '昵称需要 1-64 个字符。';
    }
    if (isJoining && inviteCode.trim().isEmpty) {
      errors[ServerFormField.inviteCode] = '申请加入时需要填写邀请码。';
    }
    return errors;
  }
}
