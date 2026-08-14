import ApplicationServices
import Foundation

/// Тонкая обёртка над Accessibility с обязательным таймаутом.
///
/// Без таймаута дефолт составляет 6 секунд: одно подвисшее приложение
/// заблокировало бы поток. Все вызовы синхронные, поэтому вызывать этот
/// класс из callback'а event tap запрещено.
public final class AXTextClient {

    private let system = AXUIElementCreateSystemWide()

    public init(timeout: Float = 0.25) {
        AXUIElementSetMessagingTimeout(system, timeout)
    }

    public func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value else { return nil }
        let axElement = element as! AXUIElement
        AXUIElementSetMessagingTimeout(axElement, 0.25)
        return axElement
    }

    public func isSecure(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let role = value as? String else { return false }
        return role == "AXSecureTextField"
    }

    /// Позиция каретки в UTF-16. Возвращает nil, если есть выделение:
    /// заменять что-либо при активном выделении нельзя.
    public func caretLocation(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.length == 0 else { return nil }
        return range.location
    }

    /// Читает текст диапазона НЕ трогая выделение — параметризованный атрибут.
    /// Прежняя реализация двигала выделение ради проверки и оставляла его
    /// сдвинутым при неудаче.
    public func string(_ element: AXUIElement, location: Int, length: Int) -> String? {
        guard location >= 0, length > 0 else { return nil }
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    public func select(_ element: AXUIElement, location: Int, length: Int) -> Bool {
        guard location >= 0, length >= 0 else { return false }
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    public func replaceSelection(_ element: AXUIElement, with text: String) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    public func selectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
