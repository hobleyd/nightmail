#include <windows.h>  // <-- This must be the first Windows header

#include "clipboard_image.h"

#include <gdiplus.h>
#include <objidl.h>
#include <shellapi.h>
#include <shlwapi.h>

#include <algorithm>
#include <cwctype>
#include <fstream>
#include <memory>

namespace {

// GDI+ for the process, started on first use and never shut down: a
// shutdown racing an engine's late call would leave it uninitialised.
bool EnsureGdiplus() {
  static bool started = [] {
    Gdiplus::GdiplusStartupInput input;
    ULONG_PTR token = 0;
    return Gdiplus::GdiplusStartup(&token, &input, nullptr) == Gdiplus::Ok;
  }();
  return started;
}

bool EncoderClsid(const wchar_t* mime, CLSID* clsid) {
  UINT count = 0, size = 0;
  if (Gdiplus::GetImageEncodersSize(&count, &size) != Gdiplus::Ok ||
      size == 0) {
    return false;
  }
  std::vector<uint8_t> buffer(size);
  auto* codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
  if (Gdiplus::GetImageEncoders(count, size, codecs) != Gdiplus::Ok) {
    return false;
  }
  for (UINT i = 0; i < count; ++i) {
    if (wcscmp(codecs[i].MimeType, mime) == 0) {
      *clsid = codecs[i].Clsid;
      return true;
    }
  }
  return false;
}

std::unique_ptr<Gdiplus::Bitmap> Decode(const std::vector<uint8_t>& data) {
  IStream* stream = SHCreateMemStream(data.data(), static_cast<UINT>(data.size()));
  if (stream == nullptr) return nullptr;
  std::unique_ptr<Gdiplus::Bitmap> bitmap(Gdiplus::Bitmap::FromStream(stream));
  stream->Release();
  if (!bitmap || bitmap->GetLastStatus() != Gdiplus::Ok) return nullptr;
  return bitmap;
}

std::optional<std::vector<uint8_t>> Encode(Gdiplus::Bitmap* bitmap,
                                           const wchar_t* mime,
                                           long quality) {
  CLSID clsid;
  if (!EncoderClsid(mime, &clsid)) return std::nullopt;
  IStream* stream = nullptr;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
    return std::nullopt;
  }
  Gdiplus::EncoderParameters params;
  params.Count = 1;
  params.Parameter[0].Guid = Gdiplus::EncoderQuality;
  params.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
  params.Parameter[0].NumberOfValues = 1;
  params.Parameter[0].Value = &quality;
  const bool jpeg = wcscmp(mime, L"image/jpeg") == 0;
  std::optional<std::vector<uint8_t>> out;
  if (bitmap->Save(stream, &clsid, jpeg ? &params : nullptr) == Gdiplus::Ok) {
    STATSTG stat = {};
    HGLOBAL global = nullptr;
    if (SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME)) &&
        SUCCEEDED(GetHGlobalFromStream(stream, &global))) {
      const auto* p = static_cast<const uint8_t*>(GlobalLock(global));
      if (p != nullptr) {
        out.emplace(p, p + stat.cbSize.QuadPart);
        GlobalUnlock(global);
      }
    }
  }
  stream->Release();
  return out;
}

std::unique_ptr<Gdiplus::Bitmap> Halved(Gdiplus::Bitmap* bitmap) {
  const int w = (std::max)(1, static_cast<int>(bitmap->GetWidth()) / 2);
  const int h = (std::max)(1, static_cast<int>(bitmap->GetHeight()) / 2);
  auto out = std::make_unique<Gdiplus::Bitmap>(w, h, PixelFormat32bppARGB);
  Gdiplus::Graphics g(out.get());
  g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  g.DrawImage(bitmap, 0, 0, w, h);
  return out;
}

// [bitmap] as PNG, or as JPEG — halved until it fits — when the PNG is over
// the limit.
std::optional<ClipboardImage> Encoded(Gdiplus::Bitmap* bitmap,
                                      const std::string& stem) {
  if (auto png = Encode(bitmap, L"image/png", 0);
      png && png->size() <= kClipboardImageLimit) {
    return ClipboardImage{std::move(*png), "image/png", stem + ".png",
                          static_cast<int>(bitmap->GetWidth()),
                          static_cast<int>(bitmap->GetHeight())};
  }
  std::unique_ptr<Gdiplus::Bitmap> owned;
  Gdiplus::Bitmap* current = bitmap;
  for (int i = 0; i < 4; ++i) {
    if (auto jpeg = Encode(current, L"image/jpeg", 82);
        jpeg && jpeg->size() <= kClipboardImageLimit) {
      return ClipboardImage{std::move(*jpeg), "image/jpeg", stem + ".jpg",
                            static_cast<int>(current->GetWidth()),
                            static_cast<int>(current->GetHeight())};
    }
    owned = Halved(current);
    current = owned.get();
  }
  return std::nullopt;
}

std::string Utf8(const std::wstring& s) {
  if (s.empty()) return {};
  const int n = WideCharToMultiByte(CP_UTF8, 0, s.data(),
                                    static_cast<int>(s.size()), nullptr, 0,
                                    nullptr, nullptr);
  std::string out(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      out.data(), n, nullptr, nullptr);
  return out;
}

std::wstring Lower(std::wstring s) {
  std::transform(s.begin(), s.end(), s.begin(), ::towlower);
  return s;
}

std::vector<uint8_t> GlobalBytes(HANDLE handle) {
  std::vector<uint8_t> out;
  const auto* p = static_cast<const uint8_t*>(GlobalLock(handle));
  if (p != nullptr) {
    out.assign(p, p + GlobalSize(handle));
    GlobalUnlock(handle);
  }
  return out;
}

// What was on the clipboard, copied out so it is closed again before any
// decoding: another app cannot copy while it is held open.
struct Snapshot {
  std::wstring file;           // one file, from CF_HDROP
  bool many_files = false;
  bool text = false;
  std::vector<uint8_t> png;    // the registered "PNG" format
  std::vector<uint8_t> dib;    // CF_DIB
};

bool OpenClipboardPatiently() {
  // Another process may hold it for a moment after writing.
  for (int i = 0; i < 5; ++i) {
    if (OpenClipboard(nullptr)) return true;
    Sleep(10);
  }
  return false;
}

std::optional<Snapshot> TakeSnapshot() {
  if (!OpenClipboardPatiently()) return std::nullopt;
  Snapshot s;
  if (HANDLE drop = GetClipboardData(CF_HDROP)) {
    auto* hdrop = static_cast<HDROP>(GlobalLock(drop));
    if (hdrop != nullptr) {
      const UINT count = DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
      if (count == 1) {
        const UINT len = DragQueryFileW(hdrop, 0, nullptr, 0);
        s.file.resize(len + 1);
        DragQueryFileW(hdrop, 0, s.file.data(), len + 1);
        s.file.resize(len);
      } else {
        s.many_files = count > 1;
      }
      GlobalUnlock(drop);
    }
  }
  s.text = IsClipboardFormatAvailable(CF_UNICODETEXT) != FALSE;
  static const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (s.file.empty() && !s.many_files && !s.text) {
    if (HANDLE h = GetClipboardData(png_format)) {
      s.png = GlobalBytes(h);
    } else if (HANDLE dib = GetClipboardData(CF_DIB)) {
      s.dib = GlobalBytes(dib);
    }
  }
  CloseClipboard();
  return s;
}

// A packed DIB as a .bmp file, which GDI+ decodes whatever its compression
// (BI_RGB, BI_BITFIELDS) — and as BMP, without a 32-bit DIB's alpha, which
// a screenshot leaves at zero.
std::vector<uint8_t> BmpFile(const std::vector<uint8_t>& dib) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) return {};
  const auto* info = reinterpret_cast<const BITMAPINFOHEADER*>(dib.data());
  DWORD colors = info->biClrUsed;
  if (colors == 0 && info->biBitCount <= 8) colors = 1u << info->biBitCount;
  DWORD masks = (info->biSize == sizeof(BITMAPINFOHEADER) &&
                 info->biCompression == BI_BITFIELDS)
                    ? 3 * sizeof(DWORD)
                    : 0;
  BITMAPFILEHEADER header = {};
  header.bfType = 0x4D42;  // "BM"
  header.bfSize = static_cast<DWORD>(sizeof(header) + dib.size());
  header.bfOffBits = static_cast<DWORD>(sizeof(header) + info->biSize + masks +
                                        colors * sizeof(RGBQUAD));
  std::vector<uint8_t> out(sizeof(header));
  memcpy(out.data(), &header, sizeof(header));
  out.insert(out.end(), dib.begin(), dib.end());
  return out;
}

std::optional<ClipboardImage> FromFile(const std::wstring& path) {
  const std::wstring ext = Lower(PathFindExtensionW(path.c_str()));
  std::string mime;
  if (ext == L".png") {
    mime = "image/png";
  } else if (ext == L".jpg" || ext == L".jpeg") {
    mime = "image/jpeg";
  } else if (ext == L".gif") {
    mime = "image/gif";
  } else if (ext != L".bmp" && ext != L".tif" && ext != L".tiff") {
    return std::nullopt;  // not a picture: a text paste
  }
  std::ifstream in(path.c_str(), std::ios::binary);
  if (!in) return std::nullopt;
  std::vector<uint8_t> data((std::istreambuf_iterator<char>(in)),
                            std::istreambuf_iterator<char>());
  auto bitmap = Decode(data);
  if (!bitmap) return std::nullopt;
  const std::string name = Utf8(PathFindFileNameW(path.c_str()));
  if (!mime.empty() && data.size() <= kClipboardImageLimit) {
    return ClipboardImage{std::move(data), mime, name,
                          static_cast<int>(bitmap->GetWidth()),
                          static_cast<int>(bitmap->GetHeight())};
  }
  std::wstring stem = PathFindFileNameW(path.c_str());
  PathRemoveExtensionW(stem.data());
  stem.resize(wcslen(stem.c_str()));
  return Encoded(bitmap.get(), Utf8(stem));
}

}  // namespace

std::optional<ClipboardImage> ReadClipboardImage() {
  if (!EnsureGdiplus()) return std::nullopt;
  const auto snapshot = TakeSnapshot();
  if (!snapshot || snapshot->many_files) return std::nullopt;
  if (!snapshot->file.empty()) return FromFile(snapshot->file);
  if (snapshot->text) return std::nullopt;
  if (!snapshot->png.empty()) {
    auto bitmap = Decode(snapshot->png);
    if (!bitmap) return std::nullopt;
    if (snapshot->png.size() <= kClipboardImageLimit) {
      return ClipboardImage{snapshot->png, "image/png", "image.png",
                            static_cast<int>(bitmap->GetWidth()),
                            static_cast<int>(bitmap->GetHeight())};
    }
    return Encoded(bitmap.get(), "image");
  }
  if (!snapshot->dib.empty()) {
    auto bitmap = Decode(BmpFile(snapshot->dib));
    if (!bitmap) return std::nullopt;
    return Encoded(bitmap.get(), "image");
  }
  return std::nullopt;
}
