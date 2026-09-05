#include "flutter_window.h"

#include <windows.h>
#include <wincred.h>

#include <flutter/standard_method_codec.h>

#include <optional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

struct CompletedIdentityStorageRequest {
  uint64_t request_id;
  std::optional<std::string> value;
  std::string error_code;
  std::string error_message;
  bool dispatch_failed = false;
};

struct IdentityStorageDispatcher {
  std::mutex mutex;
  HWND window = nullptr;
  bool closing = false;
  std::vector<std::unique_ptr<CompletedIdentityStorageRequest>> completions;
};

namespace {

constexpr wchar_t kCredentialPrefix[] = L"LanChat/";
constexpr UINT kIdentityStorageResultMessage = WM_APP + 1;
constexpr UINT_PTR kIdentityStoragePollTimerId = 1;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int input_length = static_cast<int>(value.size());
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(), input_length, nullptr, 0);
  if (length == 0) return {};
  std::wstring result(length, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          input_length, result.data(), length) == 0) {
    return {};
  }
  return result;
}

std::string WindowsError() {
  return "Windows error " + std::to_string(GetLastError());
}

const std::string* Argument(const flutter::MethodCall<flutter::EncodableValue>& call,
                            const char* name) {
  const auto* arguments = call.arguments();
  if (arguments == nullptr) return nullptr;
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) return nullptr;
  const auto it = map->find(flutter::EncodableValue(name));
  return it == map->end() ? nullptr : std::get_if<std::string>(&it->second);
}

void RunIdentityStorageOperation(const std::string& method,
                                 const std::wstring& target,
                                 const std::optional<std::string>& value,
                                 CompletedIdentityStorageRequest* completed) {
  if (method == "read") {
    PCREDENTIALW credential = nullptr;
    if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
      if (GetLastError() != ERROR_NOT_FOUND) {
        completed->error_code = "CREDENTIAL_READ_FAILED";
        completed->error_message = WindowsError();
      }
      return;
    }
    completed->value = std::string(
        reinterpret_cast<char*>(credential->CredentialBlob),
        credential->CredentialBlobSize);
    CredFree(credential);
    return;
  }

  if (method == "write") {
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<wchar_t*>(target.c_str());
    credential.CredentialBlobSize = static_cast<DWORD>(value->size());
    credential.CredentialBlob =
        reinterpret_cast<LPBYTE>(const_cast<char*>(value->data()));
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    credential.UserName = const_cast<wchar_t*>(L"LanChat");
    if (!CredWriteW(&credential, 0)) {
      completed->error_code = "CREDENTIAL_WRITE_FAILED";
      completed->error_message = WindowsError();
    }
    return;
  }

  if (!CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) &&
      GetLastError() != ERROR_NOT_FOUND) {
    completed->error_code = "CREDENTIAL_DELETE_FAILED";
    completed->error_message = WindowsError();
  }
}

void StartIdentityStorageOperation(
    std::shared_ptr<IdentityStorageDispatcher> dispatcher, uint64_t request_id,
    std::string method, std::wstring target, std::optional<std::string> value) {
  std::thread([dispatcher = std::move(dispatcher), request_id,
               method = std::move(method), target = std::move(target),
               value = std::move(value)]() mutable {
    auto completed = std::make_unique<CompletedIdentityStorageRequest>();
    completed->request_id = request_id;
    RunIdentityStorageOperation(method, target, value, completed.get());

    std::lock_guard<std::mutex> lock(dispatcher->mutex);
    if (dispatcher->closing) {
      return;
    }
    dispatcher->completions.push_back(std::move(completed));
    if (!PostMessage(dispatcher->window, kIdentityStorageResultMessage, 0, 0)) {
      dispatcher->completions.back()->dispatch_failed = true;
    }
  }).detach();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  identity_storage_dispatcher_ = std::make_shared<IdentityStorageDispatcher>();
  identity_storage_dispatcher_->window = GetHandle();
  identity_storage_timer_active_ =
      SetTimer(GetHandle(), kIdentityStoragePollTimerId, 50, nullptr) != 0;
  identity_storage_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "lanchat/identity_storage",
          &flutter::StandardMethodCodec::GetInstance());
  identity_storage_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleIdentityStorage(call, std::move(result));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (identity_storage_dispatcher_) {
    std::lock_guard<std::mutex> lock(identity_storage_dispatcher_->mutex);
    identity_storage_dispatcher_->closing = true;
    identity_storage_dispatcher_->completions.clear();
  }
  if (identity_storage_timer_active_) {
    KillTimer(GetHandle(), kIdentityStoragePollTimerId);
    identity_storage_timer_active_ = false;
  }
  RejectIdentityStorageRequests();
  identity_storage_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                               WPARAM const wparam,
                               LPARAM const lparam) noexcept {
  if (message == kIdentityStorageResultMessage) {
    DrainIdentityStorageCompletions();
    return 0;
  }

  if (message == WM_TIMER && wparam == kIdentityStoragePollTimerId) {
    DrainIdentityStorageCompletions();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::DrainIdentityStorageCompletions() {
  if (!identity_storage_dispatcher_) return;
  std::vector<std::unique_ptr<CompletedIdentityStorageRequest>> completions;
  {
    std::lock_guard<std::mutex> lock(identity_storage_dispatcher_->mutex);
    completions.swap(identity_storage_dispatcher_->completions);
  }
  for (const auto& completed : completions) {
    const auto request = identity_storage_requests_.find(completed->request_id);
    if (request == identity_storage_requests_.end()) {
      continue;
    }
    auto result = std::move(request->second);
    identity_storage_requests_.erase(request);
    if (completed->dispatch_failed) {
      result->Error("DISPATCH_FAILED", "Identity storage response dispatch failed.");
    } else if (completed->error_code.empty()) {
      if (completed->value.has_value()) {
        result->Success(flutter::EncodableValue(*completed->value));
      } else {
        result->Success();
      }
    } else {
      result->Error(completed->error_code, completed->error_message);
    }
  }
}

void FlutterWindow::HandleIdentityStorage(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "read" && call.method_name() != "write" &&
      call.method_name() != "delete") {
    result->NotImplemented();
    return;
  }
  const std::string* key = Argument(call, "key");
  if (key == nullptr || key->empty()) {
    result->Error("INVALID_ARGUMENT", "Missing storage key");
    return;
  }
  const std::wstring target = std::wstring(kCredentialPrefix) + Utf8ToWide(*key);
  if (target.size() == wcslen(kCredentialPrefix)) {
    result->Error("INVALID_ARGUMENT", "Storage key must be valid UTF-8");
    return;
  }
  std::optional<std::string> value;
  if (call.method_name() == "write") {
    const std::string* storage_value = Argument(call, "value");
    if (storage_value == nullptr) {
      result->Error("INVALID_ARGUMENT", "Missing storage value");
      return;
    }
    value = *storage_value;
  }

  if (!identity_storage_timer_active_) {
    result->Error("DISPATCH_FAILED", "Identity storage response dispatch failed.");
    return;
  }

  const uint64_t request_id = ++next_identity_storage_request_id_;
  identity_storage_requests_.emplace(request_id, std::move(result));
  StartIdentityStorageOperation(identity_storage_dispatcher_, request_id,
                                call.method_name(), target, std::move(value));
}

void FlutterWindow::RejectIdentityStorageRequests() {
  for (auto& request : identity_storage_requests_) {
    request.second->Error("WINDOW_CLOSING", "Identity storage is closing.");
  }
  identity_storage_requests_.clear();
}
