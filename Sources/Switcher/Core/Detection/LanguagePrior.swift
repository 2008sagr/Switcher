import Foundation

/// Язык последних подтверждённых слов.
///
/// Нужен для случаев, принципиально неразрешимых по одному слову: 0.68%
/// словаря составляют пары вида «руку» ←→ «here», где обе интерпретации —
/// настоящие слова, и нажатия клавиш физически одинаковы. Никакая модель
/// одного слова их не различает; язык соседей — единственный сигнал.
///
/// Вес намеренно умеренный: при полностью однородном контексте порог
/// сдвигается на 0.5, что переворачивает пограничные слова («руки», «еще»,
/// «душ»), но не трогает частотные слова другого языка («here», delta −0.44).
/// Более агрессивный вес ломал бы смешанный текст.
public final class LanguagePrior {

    private var history: [Layout] = []
    private let capacity: Int
    private let weight: Double
    private let lock = NSLock()

    public init(capacity: Int = 3, weight: Double = 0.5) {
        self.capacity = max(1, capacity)
        self.weight = weight
    }

    /// Запоминает язык подтверждённого слова. Вызывается только на границе
    /// слова: на паузе и ранней конверсии слово ещё может измениться.
    public func record(_ layout: Layout) {
        lock.lock(); defer { lock.unlock() }
        history.append(layout)
        if history.count > capacity { history.removeFirst(history.count - capacity) }
    }

    /// Сбрасывается вместе с буфером: смена приложения, клик мышью, смена
    /// фокуса означают, что предыдущий контекст больше не относится к делу.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        history.removeAll(keepingCapacity: true)
    }

    /// Сдвиг порога для конверсии в `to`. Положительное значение облегчает
    /// конверсию, отрицательное — ужесточает. Диапазон [-weight, +weight].
    public func bonus(forConverting to: Layout) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard !history.isEmpty else { return 0 }
        let matching = history.filter { $0 == to }.count
        let share = Double(matching) / Double(history.count)
        return weight * (share - (1.0 - share))
    }
}
