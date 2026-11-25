#include "clipboard_image.h"

#include <string.h>

namespace {

struct Request {
  GtkClipboard* clipboard;
  ClipboardImageCallback callback;
  gpointer user_data;
};

void finish(Request* request, ClipboardImage* image) {
  request->callback(image, request->user_data);
  g_object_unref(request->clipboard);
  g_free(request);
}

ClipboardImage* make_image(GBytes* bytes, const char* mime, char* name,
                           int width, int height) {
  ClipboardImage* image = g_new0(ClipboardImage, 1);
  image->bytes = bytes;
  image->mime_type = mime;
  image->name = name;
  image->width = width;
  image->height = height;
  return image;
}

GBytes* save(GdkPixbuf* pixbuf, const char* type, const char* quality) {
  gchar* buffer = nullptr;
  gsize size = 0;
  gboolean ok =
      quality == nullptr
          ? gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &size, type, nullptr,
                                      nullptr)
          : gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &size, type, nullptr,
                                      "quality", quality, nullptr);
  if (!ok) return nullptr;
  return g_bytes_new_take(buffer, size);
}

// [pixbuf] as PNG, or as JPEG — halved until it fits — when the PNG is over
// the limit.
ClipboardImage* encoded(GdkPixbuf* pixbuf, const char* stem) {
  GBytes* png = save(pixbuf, "png", nullptr);
  if (png != nullptr && g_bytes_get_size(png) <= kClipboardImageLimit) {
    return make_image(png, "image/png", g_strdup_printf("%s.png", stem),
                      gdk_pixbuf_get_width(pixbuf),
                      gdk_pixbuf_get_height(pixbuf));
  }
  if (png != nullptr) g_bytes_unref(png);
  GdkPixbuf* current = GDK_PIXBUF(g_object_ref(pixbuf));
  ClipboardImage* out = nullptr;
  for (int i = 0; i < 4 && out == nullptr; ++i) {
    // JPEG has no alpha; gdk-pixbuf's saver refuses a pixbuf that has one.
    GdkPixbuf* opaque =
        gdk_pixbuf_get_has_alpha(current)
            ? gdk_pixbuf_composite_color_simple(
                  current, gdk_pixbuf_get_width(current),
                  gdk_pixbuf_get_height(current), GDK_INTERP_NEAREST, 255, 8,
                  0xffffffff, 0xffffffff)
            : GDK_PIXBUF(g_object_ref(current));
    GBytes* jpeg = opaque != nullptr ? save(opaque, "jpeg", "82") : nullptr;
    if (opaque != nullptr) g_object_unref(opaque);
    if (jpeg != nullptr && g_bytes_get_size(jpeg) <= kClipboardImageLimit) {
      out = make_image(jpeg, "image/jpeg", g_strdup_printf("%s.jpg", stem),
                       gdk_pixbuf_get_width(current),
                       gdk_pixbuf_get_height(current));
      break;
    }
    if (jpeg != nullptr) g_bytes_unref(jpeg);
    GdkPixbuf* half = gdk_pixbuf_scale_simple(
        current, MAX(1, gdk_pixbuf_get_width(current) / 2),
        MAX(1, gdk_pixbuf_get_height(current) / 2), GDK_INTERP_BILINEAR);
    g_object_unref(current);
    current = half;
    if (current == nullptr) return nullptr;
  }
  g_object_unref(current);
  return out;
}

// The file's contents when it is a picture; nullptr for anything else.
ClipboardImage* from_file(const char* uri) {
  g_autofree char* path = g_filename_from_uri(uri, nullptr, nullptr);
  if (path == nullptr) return nullptr;
  int width = 0, height = 0;
  GdkPixbufFormat* format = gdk_pixbuf_get_file_info(path, &width, &height);
  if (format == nullptr) return nullptr;
  g_autofree char* basename = g_path_get_basename(path);
  g_autofree char* format_name = gdk_pixbuf_format_get_name(format);
  const char* mime = nullptr;
  if (g_strcmp0(format_name, "png") == 0) {
    mime = "image/png";
  } else if (g_strcmp0(format_name, "jpeg") == 0) {
    mime = "image/jpeg";
  } else if (g_strcmp0(format_name, "gif") == 0) {
    mime = "image/gif";
  }
  gchar* contents = nullptr;
  gsize size = 0;
  if (mime != nullptr && g_file_get_contents(path, &contents, &size, nullptr)) {
    if (size <= kClipboardImageLimit) {
      return make_image(g_bytes_new_take(contents, size), mime,
                        g_strdup(basename), width, height);
    }
    g_free(contents);
  }
  g_autoptr(GdkPixbuf) pixbuf = gdk_pixbuf_new_from_file(path, nullptr);
  if (pixbuf == nullptr) return nullptr;
  char* dot = strrchr(basename, '.');
  if (dot != nullptr) *dot = '\0';
  return encoded(pixbuf, basename);
}

void on_uris(GtkClipboard*, gchar** uris, gpointer data) {
  Request* request = static_cast<Request*>(data);
  const bool one = uris != nullptr && uris[0] != nullptr && uris[1] == nullptr;
  finish(request, one ? from_file(uris[0]) : nullptr);
}

void on_image(GtkClipboard*, GdkPixbuf* pixbuf, gpointer data) {
  Request* request = static_cast<Request*>(data);
  finish(request, pixbuf != nullptr ? encoded(pixbuf, "image") : nullptr);
}

void on_targets(GtkClipboard* clipboard, GdkAtom* targets, gint count,
                gpointer data) {
  Request* request = static_cast<Request*>(data);
  if (targets == nullptr || count <= 0) {
    finish(request, nullptr);
  } else if (gtk_targets_include_uri(targets, count)) {
    gtk_clipboard_request_uris(clipboard, on_uris, request);
  } else if (gtk_targets_include_text(targets, count)) {
    finish(request, nullptr);
  } else if (gtk_targets_include_image(targets, count, FALSE)) {
    gtk_clipboard_request_image(clipboard, on_image, request);
  } else {
    finish(request, nullptr);
  }
}

}  // namespace

void clipboard_image_free(ClipboardImage* image) {
  if (image == nullptr) return;
  g_bytes_unref(image->bytes);
  g_free(image->name);
  g_free(image);
}

void clipboard_image_read(GtkClipboard* clipboard,
                          ClipboardImageCallback callback, gpointer user_data) {
  Request* request = g_new0(Request, 1);
  request->clipboard = GTK_CLIPBOARD(g_object_ref(clipboard));
  request->callback = callback;
  request->user_data = user_data;
  gtk_clipboard_request_targets(clipboard, on_targets, request);
}
