#ifndef FLUTTER_PLUGIN_HTML_VIEW_PLUGIN_H_
#define FLUTTER_PLUGIN_HTML_VIEW_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_DECLARE_FINAL_TYPE(HtmlViewPlugin, html_view_plugin, HTML_VIEW, PLUGIN, GObject)

G_BEGIN_DECLS

void html_view_plugin_register_with_registrar(FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_HTML_VIEW_PLUGIN_H_
