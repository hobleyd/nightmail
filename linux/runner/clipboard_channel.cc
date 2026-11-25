#include "clipboard_channel.h"

#include "clipboard_image.h"

namespace {

void on_image(ClipboardImage* image, gpointer data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(data);
  if (image == nullptr) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  g_autoptr(FlValue) map = fl_value_new_map();
  gsize size = 0;
  const uint8_t* bytes =
      static_cast<const uint8_t*>(g_bytes_get_data(image->bytes, &size));
  fl_value_set_string_take(map, "bytes", fl_value_new_uint8_list(bytes, size));
  fl_value_set_string_take(map, "mimeType",
                           fl_value_new_string(image->mime_type));
  fl_value_set_string_take(map, "name", fl_value_new_string(image->name));
  fl_value_set_string_take(map, "width", fl_value_new_int(image->width));
  fl_value_set_string_take(map, "height", fl_value_new_int(image->height));
  clipboard_image_free(image);
  fl_method_call_respond_success(call, map, nullptr);
}

void method_call_cb(FlMethodChannel*, FlMethodCall* call, gpointer) {
  if (g_strcmp0(fl_method_call_get_name(call), "readImage") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  // Answered when GTK has the clipboard's contents; on_image drops the ref.
  // A window closed meanwhile is harmless: its messenger drops the answer.
  clipboard_image_read(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD), on_image,
                       g_object_ref(call));
}

}  // namespace

void clipboard_channel_register(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "ClipboardImage");
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, "au.com.sharpblue.nightmail/clipboard", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                            nullptr);
  // The channel lives as long as its view: dropped with it, as the relays'
  // are (window_relay.cc), so a closed window's handler goes too.
  FlView* view = fl_plugin_registrar_get_view(registrar);
  if (view != nullptr) {
    g_object_set_data_full(G_OBJECT(view), "nightmail-clipboard-channel",
                           channel, g_object_unref);
  }
}
