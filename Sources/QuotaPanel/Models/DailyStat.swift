import Foundation

/// Grafik ve toplamlar için günlük istatistik
struct DailyStat: Identifiable, Equatable, Sendable {
    /// Yerel takvime göre günün başlangıcı
    let day: Date
    /// Claude için tahmini USD maliyet; Codex için 0
    let costUSD: Double
    /// Toplam token (input + output + cache)
    let tokens: Int

    var id: Date { day }
}
