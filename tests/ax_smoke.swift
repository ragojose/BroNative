import ApplicationServices
import CoreGraphics
import Foundation

private func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
    return nil
  }
  return value as? T
}

private func children(of element: AXUIElement) -> [AXUIElement] {
  attribute(element, kAXChildrenAttribute as CFString) ?? []
}

private func stringAttribute(_ element: AXUIElement,
                             _ name: CFString) -> String {
  attribute(element, name) ?? ""
}

private func descendants(of root: AXUIElement) -> [AXUIElement] {
  var result: [AXUIElement] = []
  var queue = children(of: root)
  while !queue.isEmpty {
    let element = queue.removeFirst()
    result.append(element)
    queue.append(contentsOf: children(of: element))
  }
  return result
}

private func broPID() -> pid_t? {
  let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
  return windows.compactMap { window -> pid_t? in
    guard window[kCGWindowOwnerName as String] as? String == "Bro Computer"
    else { return nil }
    return window[kCGWindowOwnerPID as String] as? pid_t
  }.first
}

guard AXIsProcessTrusted() else {
  fputs("AX smoke requires Accessibility permission\n", stderr)
  exit(2)
}
guard let pid = broPID() else {
  fputs("AX smoke could not find a visible Bro Computer window\n", stderr)
  exit(2)
}

let app = AXUIElementCreateApplication(pid)
if CommandLine.arguments.contains("--dump") {
  let elements = [app] + descendants(of: app)
  for element in elements {
    let role = stringAttribute(element, kAXRoleAttribute as CFString)
    let title = stringAttribute(element, kAXTitleAttribute as CFString)
    let description = stringAttribute(
      element, kAXDescriptionAttribute as CFString)
    let identifier = stringAttribute(
      element, kAXIdentifierAttribute as CFString)
    if !title.isEmpty || !description.isEmpty || !identifier.isEmpty ||
         role == kAXButtonRole as String || role == kAXTextFieldRole as String {
      print("role=\(role) title=\(title) description=\(description) " +
            "identifier=\(identifier)")
    }
  }
  exit(0)
}

private func fail(_ message: String) -> Never {
  fputs("AX smoke failed: \(message)\n", stderr)
  exit(1)
}

private func firstElement(role: String? = nil,
                          title: String? = nil,
                          description: String? = nil,
                          identifier: String? = nil) -> AXUIElement? {
  ([app] + descendants(of: app)).first { element in
    if let role,
       stringAttribute(element, kAXRoleAttribute as CFString) != role {
      return false
    }
    if let title,
       stringAttribute(element, kAXTitleAttribute as CFString) != title {
      return false
    }
    if let description,
       stringAttribute(element, kAXDescriptionAttribute as CFString) !=
         description {
      return false
    }
    if let identifier,
       stringAttribute(element, kAXIdentifierAttribute as CFString) !=
         identifier {
      return false
    }
    return true
  }
}

private func waitUntil(timeout: TimeInterval = 8,
                       _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  repeat {
    if condition() { return true }
    Thread.sleep(forTimeInterval: 0.05)
  } while Date() < deadline
  return condition()
}

private func tabCount() -> Int {
  guard let group = firstElement(role: kAXTabGroupRole as String) else {
    return 0
  }
  return descendants(of: group).filter {
    stringAttribute($0, kAXRoleAttribute as CFString) ==
      kAXRadioButtonRole as String
  }.count
}

guard let window = firstElement(role: kAXWindowRole as String) else {
  fail("launch produced no accessible window")
}
let launchTitle = stringAttribute(window, kAXTitleAttribute as CFString)
guard launchTitle.hasPrefix("WEBGL_OK_") else {
  fail("expected a rendered WebGL fixture, got window title \(launchTitle)")
}

let initialTabs = tabCount()
guard initialTabs > 0 else {
  fail("tab strip exposed no accessible tabs")
}
guard let newTab = firstElement(role: kAXButtonRole as String,
                                description: "New Tab") else {
  fail("New Tab button is missing from the accessibility tree")
}
guard AXUIElementPerformAction(newTab, kAXPressAction as CFString) == .success
else {
  fail("AXPress failed for New Tab")
}
guard waitUntil({ tabCount() == initialTabs + 1 }) else {
  fail("New Tab AXPress did not add exactly one accessible tab")
}

guard let screenshotMode = firstElement(
  role: kAXMenuItemRole as String,
  identifier: "toggleScreenshotMode:") else {
  fail("Screenshot Mode menu item is missing from the accessibility tree")
}
guard AXUIElementPerformAction(screenshotMode,
                               kAXPressAction as CFString) == .success else {
  fail("AXPress failed for Screenshot Mode")
}
guard waitUntil({
  firstElement(role: kAXButtonRole as String,
               description: "New Tab") == nil
}) else {
  fail("Screenshot Mode did not hide chrome from the accessibility tree")
}

guard AXUIElementPerformAction(screenshotMode,
                               kAXPressAction as CFString) == .success else {
  fail("AXPress failed while leaving Screenshot Mode")
}
guard waitUntil({
  firstElement(role: kAXButtonRole as String,
               description: "New Tab") != nil
}) else {
  fail("leaving Screenshot Mode did not restore accessible chrome")
}

var appearanceResult = ""
if let option = CommandLine.arguments.firstIndex(of: "--preferences"),
   CommandLine.arguments.indices.contains(option + 1) {
  let preferencesURL = URL(
    fileURLWithPath: CommandLine.arguments[option + 1])
  func storedAppearance() -> String? {
    guard let data = try? Data(contentsOf: preferencesURL),
          let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] else { return nil }
    return object["appearance"] as? String
  }
  for choice in ["Dark", "System"] {
    guard let item = firstElement(role: kAXMenuItemRole as String,
                                  title: choice,
                                  identifier: "selectAppearance:") else {
      fail("\(choice) appearance menu item is missing")
    }
    guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    else {
      fail("AXPress failed for \(choice) appearance")
    }
    let expected = choice.lowercased()
    guard waitUntil({ storedAppearance() == expected }) else {
      fail("\(choice) appearance was not persisted as \(expected)")
    }
  }
  appearanceResult = ", appearance Dark→System persisted"
}

print("AX smoke passed: launch title \(launchTitle), tabs " +
      "\(initialTabs)→\(initialTabs + 1), screenshot chrome hidden/restored" +
      appearanceResult)
