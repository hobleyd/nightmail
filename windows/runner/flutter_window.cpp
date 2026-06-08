#include "flutter_window.h"

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  if (taskbar_list_) {
    taskbar_list_->Release();
    taskbar_list_ = nullptr;
  }
}

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Acquire ITaskbarList3 for overlay icon (badge) support.
  ::CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                     IID_PPV_ARGS(&taskbar_list_));
  if (taskbar_list_) taskbar_list_->HrInit();

  // Register the badge method channel.
  badge_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "au.com.sharpblue.nightmail/badge",
          &flutter::StandardMethodCodec::GetInstance());
  badge_channel_->SetMethodCallHandler(
      [this](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        if (call.method_name() == "setBadgeCount") {
          int count = 0;
          if (const auto* v = std::get_if<int32_t>(call.arguments())) {
            count = *v;
          } else if (const auto* v64 = std::get_if<int64_t>(call.arguments())) {
            count = static_cast<int>(*v64);
          }
          UpdateBadge(count);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                               WPARAM const wparam,
                               LPARAM const lparam) noexcept {
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

void FlutterWindow::UpdateBadge(int count) {
  if (!taskbar_list_) return;
  HWND hwnd = GetHandle();
  if (count <= 0) {
    taskbar_list_->SetOverlayIcon(hwnd, nullptr, L"");
    return;
  }
  HICON icon = CreateNumberIcon(count);
  taskbar_list_->SetOverlayIcon(hwnd, icon, L"Unread emails");
  ::DestroyIcon(icon);
}

HICON FlutterWindow::CreateNumberIcon(int count) {
  const int kSize = 16;

  HDC screen_dc = ::GetDC(nullptr);
  HDC mem_dc = ::CreateCompatibleDC(screen_dc);
  ::ReleaseDC(nullptr, screen_dc);

  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize        = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth       = kSize;
  bmi.bmiHeader.biHeight      = -kSize;  // top-down
  bmi.bmiHeader.biPlanes      = 1;
  bmi.bmiHeader.biBitCount    = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  DWORD* pixels = nullptr;
  HBITMAP bmp = ::CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS,
                                    reinterpret_cast<void**>(&pixels),
                                    nullptr, 0);
  ::SelectObject(mem_dc, bmp);
  ::memset(pixels, 0, kSize * kSize * sizeof(DWORD));

  // Draw red circle background.
  HBRUSH brush = ::CreateSolidBrush(RGB(211, 47, 47));
  HPEN no_pen = static_cast<HPEN>(::GetStockObject(NULL_PEN));
  ::SelectObject(mem_dc, no_pen);
  ::SelectObject(mem_dc, brush);
  ::Ellipse(mem_dc, 0, 0, kSize + 1, kSize + 1);
  ::DeleteObject(brush);

  // GDI leaves the alpha channel at 0; set it for all drawn circle pixels.
  for (int i = 0; i < kSize * kSize; ++i) {
    if (pixels[i] & 0x00FFFFFFu) pixels[i] |= 0xFF000000u;
  }

  // Draw white count text.
  std::wstring text = count < 100 ? std::to_wstring(count) : L"99+";
  HFONT font = ::CreateFont(-9, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
                              OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                              CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS,
                              L"Segoe UI");
  ::SelectObject(mem_dc, font);
  ::SetTextColor(mem_dc, RGB(255, 255, 255));
  ::SetBkMode(mem_dc, TRANSPARENT);
  RECT rc{0, 0, kSize, kSize};
  ::DrawTextW(mem_dc, text.c_str(), -1, &rc,
               DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  ::DeleteObject(font);

  // GDI text also zeroes the alpha channel; restore it for newly written pixels.
  for (int i = 0; i < kSize * kSize; ++i) {
    if ((pixels[i] & 0x00FFFFFFu) && !(pixels[i] & 0xFF000000u)) {
      pixels[i] |= 0xFF000000u;
    }
  }

  HBITMAP mask = ::CreateBitmap(kSize, kSize, 1, 1, nullptr);
  ICONINFO ii{TRUE, 0, 0, mask, bmp};
  HICON icon = ::CreateIconIndirect(&ii);

  ::DeleteObject(mask);
  ::DeleteObject(bmp);
  ::DeleteDC(mem_dc);

  return icon;
}
