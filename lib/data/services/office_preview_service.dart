import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// The OOXML office formats we can preview.
enum OfficeFormat { docx, xlsx, pptx }

/// Produces in-app previews for Word / Excel / PowerPoint attachments.
///
/// Two rendering strategies (see the plan / CLAUDE notes):
///   * [buildJsViewer] — writes a self-contained `viewer.html` (plus the
///     vendored JS libraries) into a single temp directory and inlines the
///     document as base64. Loaded into the native webview via `loadUrl`
///     (NOT `loadHtml` — WebView2's `NavigateToString` caps at ~2 MB).
///   * [convertToPdf] — shells out to a locally installed LibreOffice
///     (`soffice --headless --convert-to pdf`) and returns the PDF path so the
///     existing PDF preview widget can render it. Used for Excel/PowerPoint
///     when LibreOffice is present (higher fidelity than the JS fallback).
class OfficePreviewService {
  OfficePreviewService();

  static const String _assetDir = 'assets/docviewer';

  /// Vendored libraries copied next to each generated `viewer.html` so the
  /// page can reference them with *relative* `<script src>` — required because
  /// macOS `loadFileURL` only grants read access to the file's own directory.
  static const List<String> _libFiles = <String>[
    'jszip.min.js', // shared by the docx (docx-preview) and pptx paths
    'docx-preview.min.js',
    'xlsx.full.min.js',
  ];

  String? _sofficeCache;
  bool _sofficeLookedUp = false;
  bool _assetsExtracted = false;

  // ---------------------------------------------------------------------------
  // LibreOffice detection
  // ---------------------------------------------------------------------------

  /// Absolute path to the `soffice` executable, or null if LibreOffice is not
  /// installed. Result is cached for the lifetime of the app.
  String? findSoffice() {
    if (_sofficeLookedUp) return _sofficeCache;
    _sofficeLookedUp = true;
    _sofficeCache = _locateSoffice();
    return _sofficeCache;
  }

  bool get libreOfficeAvailable => findSoffice() != null;

  String? _locateSoffice() {
    final candidates = <String>[];
    if (Platform.isWindows) {
      candidates.addAll([
        r'C:\Program Files\LibreOffice\program\soffice.exe',
        r'C:\Program Files (x86)\LibreOffice\program\soffice.exe',
      ]);
    } else if (Platform.isMacOS) {
      candidates.add('/Applications/LibreOffice.app/Contents/MacOS/soffice');
    } else {
      candidates.addAll([
        '/usr/bin/soffice',
        '/usr/local/bin/soffice',
        '/snap/bin/libreoffice',
        '/usr/bin/libreoffice',
      ]);
    }
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    // Fall back to a PATH scan.
    final exe = Platform.isWindows ? 'soffice.exe' : 'soffice';
    final pathEnv = Platform.environment['PATH'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    for (final dir in pathEnv.split(sep)) {
      if (dir.trim().isEmpty) continue;
      final p = '$dir${Platform.pathSeparator}$exe';
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // LibreOffice → PDF conversion
  // ---------------------------------------------------------------------------

  /// Converts [inputPath] to a PDF using LibreOffice and returns the PDF path,
  /// or null on failure/timeout (caller falls back to the JS viewer).
  Future<String?> convertToPdf(String inputPath) async {
    final soffice = findSoffice();
    if (soffice == null) return null;
    try {
      final tmp = await getTemporaryDirectory();
      final sep = Platform.pathSeparator;
      final outDir = Directory('${tmp.path}${sep}nightmail_lo_out');
      if (!outDir.existsSync()) outDir.createSync(recursive: true);

      // A dedicated user-installation profile lets the conversion run even when
      // the user already has LibreOffice open (otherwise it silently no-ops).
      final profileDir = Directory('${tmp.path}${sep}nightmail_lo_profile');
      final profileUri = Uri.file(profileDir.path).toString();

      final result = await Process.run(
        soffice,
        [
          '--headless',
          '--norestore',
          '--convert-to',
          'pdf',
          '--outdir',
          outDir.path,
          '-env:UserInstallation=$profileUri',
          inputPath,
        ],
      ).timeout(const Duration(seconds: 30));

      // LibreOffice names the output <stem>.pdf in --outdir.
      final base = inputPath.split(RegExp(r'[\\/]')).last;
      final stem =
          base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
      final pdf = File('${outDir.path}$sep$stem.pdf');
      if (pdf.existsSync() && pdf.lengthSync() > 0) return pdf.path;

      // No output produced — log in debug and fall back to the JS viewer.
      debugPrint('LibreOffice convert failed (exit ${result.exitCode}): '
          '${result.stderr}');
      return null;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // JS viewer (option A)
  // ---------------------------------------------------------------------------

  /// Writes a self-contained `viewer.html` (plus vendored libs) into a temp
  /// directory and returns its path. Load it with `HtmlViewController.loadUrl`.
  Future<String> buildJsViewer(String docPath, OfficeFormat fmt) async {
    final dir = await _ensureAssetsDir();
    final bytes = await File(docPath).readAsBytes();
    final b64 = base64Encode(bytes);
    final html = _viewerHtml(fmt, b64);

    // Unique name per call so the preview widget's ValueKey(path) changes and
    // the webview reloads when switching between office attachments.
    final name = 'viewer_${DateTime.now().microsecondsSinceEpoch}.html';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(html);
    return file.path;
  }

  /// Ensures the vendored JS libraries are present in the shared temp dir.
  /// Extracts them once per app session (overwriting, so app updates take
  /// effect on next launch).
  Future<Directory> _ensureAssetsDir() async {
    final tmp = await getTemporaryDirectory();
    final dir =
        Directory('${tmp.path}${Platform.pathSeparator}nightmail_docviewer');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    if (!_assetsExtracted) {
      for (final f in _libFiles) {
        final data = await rootBundle.load('$_assetDir/$f');
        final out = File('${dir.path}${Platform.pathSeparator}$f');
        await out.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      _assetsExtracted = true;
    }
    return dir;
  }

  String _viewerHtml(OfficeFormat fmt, String b64) {
    switch (fmt) {
      case OfficeFormat.docx:
        return _docxHtml(b64);
      case OfficeFormat.xlsx:
        return _xlsxHtml(b64);
      case OfficeFormat.pptx:
        return _pptxHtml(b64);
    }
  }

  // A tiny shared preamble: base64 → Uint8Array helper + error renderer.
  static const String _commonHead = r'''
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  html,body{margin:0;padding:0;background:#f4f4f5;color:#222;
    font-family:-apple-system,Segoe UI,Roboto,sans-serif;}
  #err{display:none;padding:28px;color:#666;font-size:13px;}
</style>
<script>
  function b2u(b){var s=atob(b),n=s.length,a=new Uint8Array(n);
    for(var i=0;i<n;i++)a[i]=s.charCodeAt(i);return a;}
  function showErr(){var e=document.getElementById('err');
    if(e){e.style.display='block';}}
</script>
''';

  String _docxHtml(String b64) {
    return '''<!DOCTYPE html><html><head>$_commonHead
<style>.docx-wrapper{background:#f4f4f5 !important;padding:16px 0;}
  .docx{box-shadow:0 1px 6px rgba(0,0,0,.15);margin:0 auto 16px;}</style>
</head><body>
<div id="err">Couldn't render this document. Try opening it externally.</div>
<div id="container"></div>
<script src="jszip.min.js"></script>
<script src="docx-preview.min.js"></script>
<script>
  try{
    docx.renderAsync(b2u("$b64").buffer, document.getElementById('container'),
      null, {className:'docx', inWrapper:true, ignoreLastRenderedPageBreak:true})
      .catch(function(){showErr();});
  }catch(e){showErr();}
</script>
</body></html>''';
  }

  String _xlsxHtml(String b64) {
    return '''<!DOCTYPE html><html><head>$_commonHead
<style>
  #tabs{position:sticky;top:0;background:#fff;border-bottom:1px solid #ddd;
    padding:6px 8px;white-space:nowrap;overflow-x:auto;}
  #tabs button{border:1px solid #ccc;background:#f0f0f0;border-radius:5px;
    padding:3px 10px;margin-right:5px;font-size:12px;cursor:pointer;}
  #tabs button.active{background:#2563eb;color:#fff;border-color:#2563eb;}
  #sheet{padding:12px;overflow:auto;}
  table{border-collapse:collapse;font-size:12px;background:#fff;}
  td,th{border:1px solid #ddd;padding:3px 7px;white-space:nowrap;}
</style>
</head><body>
<div id="err">Couldn't render this spreadsheet. Try opening it externally.</div>
<div id="tabs"></div>
<div id="sheet"></div>
<script src="xlsx.full.min.js"></script>
<script>
  try{
    var wb = XLSX.read("$b64", {type:'base64'});
    var tabs = document.getElementById('tabs');
    var host = document.getElementById('sheet');
    function show(i){
      var ws = wb.Sheets[wb.SheetNames[i]];
      host.innerHTML = XLSX.utils.sheet_to_html(ws, {editable:false});
      var bs = tabs.getElementsByTagName('button');
      for(var j=0;j<bs.length;j++)bs[j].className = (j===i)?'active':'';
    }
    wb.SheetNames.forEach(function(nm,i){
      var b=document.createElement('button');
      b.textContent=nm; b.onclick=function(){show(i);}; tabs.appendChild(b);
    });
    if(wb.SheetNames.length){show(0);} else {showErr();}
  }catch(e){showErr();}
</script>
</body></html>''';
  }

  // Full client-side PowerPoint layout renderers (PPTXjs et al.) are heavy and
  // unreliable, so the JS fallback is a best-effort *text* view: unzip the pptx
  // with JSZip and pull each slide's text runs. (LibreOffice → PDF is the
  // primary, high-fidelity path when it's installed.)
  static const String _pptxScript = r'''<script src="jszip.min.js"></script>
<script>
  function esc(s){return s.replace(/[&<>]/g,function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c];});}
  function slideNum(n){var m=n.match(/slide(\d+)\.xml$/);return m?parseInt(m[1],10):0;}
  (async function(){
    try{
      var zip = await JSZip.loadAsync(b2u("__B64__"));
      var names = Object.keys(zip.files)
        .filter(function(n){return /^ppt\/slides\/slide\d+\.xml$/.test(n);})
        .sort(function(a,b){return slideNum(a)-slideNum(b);});
      if(!names.length){showErr();return;}
      var host = document.getElementById('slides');
      for(var i=0;i<names.length;i++){
        var xml = await zip.file(names[i]).async('string');
        var paras = xml.split(/<a:p[ >]/).slice(1).map(function(chunk){
          var runs = chunk.match(/<a:t>([\s\S]*?)<\/a:t>/g) || [];
          return runs.map(function(r){return r.replace(/<\/?a:t>/g,'');}).join('');
        }).filter(function(t){return t.trim().length;});
        var div = document.createElement('div'); div.className='slide';
        var html = '<div class="num">Slide '+(i+1)+'</div>';
        if(paras.length){ html += '<div class="title">'+esc(paras[0])+'</div>';
          for(var j=1;j<paras.length;j++) html += '<p>'+esc(paras[j])+'</p>'; }
        else { html += '<p class="empty">(no text on this slide)</p>'; }
        div.innerHTML = html; host.appendChild(div);
      }
    }catch(e){showErr();}
  })();
</script>''';

  String _pptxHtml(String b64) {
    return '''<!DOCTYPE html><html><head>$_commonHead
<style>
  #slides{padding:16px;max-width:760px;margin:0 auto;}
  .slide{background:#fff;box-shadow:0 1px 6px rgba(0,0,0,.15);border-radius:6px;
    padding:22px 26px;margin:0 0 16px;}
  .slide .num{font-size:11px;color:#999;margin-bottom:8px;
    text-transform:uppercase;letter-spacing:.05em;}
  .slide .title{font-size:19px;font-weight:600;margin:0 0 10px;}
  .slide p{font-size:14px;line-height:1.5;margin:3px 0;}
  .slide p.empty{color:#999;}
</style>
</head><body>
<div id="err">Couldn't render this presentation. Try opening it externally.</div>
<div id="slides"></div>
${_pptxScript.replaceFirst('__B64__', b64)}
</body></html>''';
  }
}
