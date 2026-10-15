import AppKit
@main enum Benchmark {
 static func main() {
  let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
  let window = NSWindow(contentRect: NSRect(x:0,y:0,width:900,height:700), styleMask:[.titled], backing:.buffered, defer:false)
  let editor = MarkdownEditorView(frame:NSRect(x:0,y:0,width:900,height:700)); window.contentView = editor
  for size in [200, 1000] {
   let text = "Performance note\n" + (0..<size).map { i in i % 20 == 0 ? "- [ ] Review item \(i)\n" : "A readable paragraph with **bold** detail and useful content for writing in a long document.\n" }.joined()
   let start = CFAbsoluteTimeGetCurrent(); editor.setText(text); editor.layoutSubtreeIfNeeded()
   let load = (CFAbsoluteTimeGetCurrent()-start)*1000
   editor.selectSourceRange(NSRange(location:(text as NSString).length/2,length:0), scroll:false)
   var timings:[Double] = []
   for _ in 0..<20 { let t = CFAbsoluteTimeGetCurrent(); editor.textView.insertText("e",replacementRange:editor.textView.selectedRange()); timings.append((CFAbsoluteTimeGetCurrent()-t)*1000) }
   timings.sort()
   print("lines=\(size) chars=\((text as NSString).length) load_ms=\(String(format:"%.2f",load)) median_key_ms=\(String(format:"%.2f",timings[10])) p95_key_ms=\(String(format:"%.2f",timings[18]))")
  }
 }
}
