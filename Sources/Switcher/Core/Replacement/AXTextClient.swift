import ApplicationServices
import Foundation

/// Тонкая обёртка над Accessibility с обязательным таймаутом.
///
/// Без таймаута дефолт составляет 6 секунд: одно подвисшее приложение
/// заблокировало бы поток. Все вызовы синхронные, поэтому вызывать этот
/// класс из callback'а event tap запрещено.
public final class AXTextClient {

    private let system = AXUIElementCreateSystemWide()

    /// Таймаут, переданный в init. Хранится отдельно от system-элемента,
    /// потому что применяется повторно к каждому найденному фокусному
    /// элементу — до фикса он был захардкожен литералом 0.25 в
    /// focusedElement() и переданное вызывающим значение молча игнорировалось.
    private let timeout: Float

    public init(timeout: Float = 0.25) {
        self.timeout = timeout
        AXUIElementSetMessagingTimeout(system, timeout)
    }

    public func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let raw = value,
              // Значение приходит из чужого процесса через XPC: приложения с
              // неполной реализацией Accessibility (Electron, Java-мосты,
              // самодельные тулкиты) могут при статусе .success вернуть не
              // тот CF-тип. `as?`/`as!` для CF-типов в Swift не делают
              // рантайм-проверку (компилятор считает даункаст «всегда
              // успешным» и в случае `as!` просто интерпретирует чужую
              // память как AXUIElement) — поэтому тип проверяется явно через
              // CFGetTypeID, как и советует диагностика компилятора.
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let axElement = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(axElement, timeout)
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
    ///
    /// nil здесь означает и «есть выделение», и «атрибут недоступен», и
    /// «пришёл не тот CF-тип», и «конвертация в CFRange не удалась» — все
    /// четыре случая осознанно не различаются. Единственный потребитель nil —
    /// решение «можно ли безопасно заменить текст под кареткой», и во всех
    /// четырёх случаях ответ на этот вопрос одинаков: нет. Различение причин
    /// усложнило бы API ради диагностики, которая нужна только при ручной
    /// проверке в отладчике (Task 13) — там причину проще увидеть, прочитав
    /// сырые атрибуты AX напрямую, чем через отдельный enum ошибок здесь.
    public func caretLocation(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let raw = value,
              // См. комментарий в focusedElement(): значение приходит из
              // чужого процесса, гарантий на фактический CF-тип нет, а
              // `as?`/`as!` эту гарантию не проверяют — нужен CFGetTypeID.
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.length == 0 else { return nil }
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
