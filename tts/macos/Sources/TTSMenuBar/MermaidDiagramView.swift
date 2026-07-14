import SwiftUI
import WebKit

struct MermaidDiagramView: NSViewRepresentable {
    let source: String
    let accentHue: Int

    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> MermaidWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = MermaidWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = true
        webView.setAccessibilityLabel("Mermaid diagram")
        return webView
    }

    func updateNSView(_ webView: MermaidWebView, context: Context) {
        let document = MermaidHTML.document(
            source: source,
            darkMode: colorScheme == .dark,
            accentHue: accentHue
        )
        guard document != webView.renderedDocument else { return }
        webView.renderedDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }
}

final class MermaidWebView: WKWebView {
    var renderedDocument: String?
}

enum MermaidHTML {
    static func document(source: String, darkMode: Bool, accentHue: Int) -> String {
        let encodedSource = ((try? JSONEncoder().encode(source))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\"")
            .replacingOccurrences(of: "</", with: "<\\/")
        let background = darkMode ? "#17191b" : "#f6f6f4"
        let foreground = darkMode ? "#e7e7e5" : "#242522"
        let muted = darkMode ? "#a5a7a2" : "#676963"
        let border = darkMode ? "#41443f" : "#d1d3cd"
        let theme = darkMode ? "dark" : "default"
        let normalizedHue = max(0, min(accentHue, WorkspaceAccent.count - 1))
        let accent = "hsl(\(normalizedHue), 50%, \(darkMode ? 48 : 42)%)"

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root { color-scheme: \(darkMode ? "dark" : "light"); }
            * { box-sizing: border-box; }
            html, body { width: 100%; min-height: 100%; margin: 0; background: \(background); color: \(foreground); }
            body { display: grid; place-items: center; padding: 20px; font: 14px -apple-system, BlinkMacSystemFont, sans-serif; }
            #diagram { width: 100%; text-align: center; }
            #diagram svg { display: block; width: 100%; height: auto; max-height: calc(100vh - 40px); margin: auto; }
            .status { color: \(muted); }
            .fallback { width: 100%; text-align: left; }
            .fallback strong { display: block; margin-bottom: 10px; color: \(foreground); }
            pre { overflow: auto; margin: 0; padding: 14px; border: 1px solid \(border); border-radius: 10px; color: \(foreground); background: \(background); white-space: pre-wrap; font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
          </style>
        </head>
        <body>
          <div id="diagram"><span class="status">Rendering diagram…</span></div>
          <script type="module">
            const source = \(encodedSource);
            const target = document.getElementById('diagram');
            const escapeHTML = value => value.replace(/[&<>]/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[character]));
            try {
              const { default: mermaid } = await import('https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs');
              mermaid.initialize({
                startOnLoad: false,
                securityLevel: 'strict',
                theme: '\(theme)',
                flowchart: { useMaxWidth: true, htmlLabels: true },
                themeVariables: { primaryColor: '\(accent)', lineColor: '\(accent)' }
              });
              const { svg, bindFunctions } = await mermaid.render('tts-mermaid-diagram', source);
              target.innerHTML = svg;
              bindFunctions?.(target);
            } catch (error) {
              target.className = 'fallback';
              target.innerHTML = '<strong>Diagram preview unavailable</strong><pre>' + escapeHTML(source) + '</pre>';
            }
          </script>
        </body>
        </html>
        """
    }
}
