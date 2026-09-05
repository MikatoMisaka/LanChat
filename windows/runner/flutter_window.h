#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <memory>
#include <unordered_map>

#include "win32_window.h"

struct IdentityStorageDispatcher;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void HandleIdentityStorage(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DrainIdentityStorageCompletions();
  void RejectIdentityStorageRequests();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      identity_storage_channel_;
  std::shared_ptr<IdentityStorageDispatcher> identity_storage_dispatcher_;
  bool identity_storage_timer_active_ = false;
  uint64_t next_identity_storage_request_id_ = 0;
  std::unordered_map<
      uint64_t,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>>
      identity_storage_requests_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
