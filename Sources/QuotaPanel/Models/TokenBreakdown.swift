import Foundation

/// input / önbellek-yazma / çıktı token bileşimi. Önbellek *okumaları* bilinçli
/// olarak hariç: her turda aynı geçmişi yeniden sayar ve diğer her şeyi gölgeler.
struct TokenParts: Equatable, Sendable {
    var input = 0
    var cache = 0
    var output = 0

    var total: Int { input + cache + output }

    /// Her parçanın toplam içindeki oranı (0...1); toplam sıfırsa hepsi 0
    var fractions: (input: Double, cache: Double, output: Double) {
        let t = Double(max(total, 1))
        return (Double(input) / t, Double(cache) / t, Double(output) / t)
    }
}

/// Açık bir oturumun bağlam penceresi doluluğu
struct ContextSnapshot: Identifiable, Equatable, Sendable {
    /// Oturum jsonl dosyasının yolu
    let id: String
    /// Oturumun çalışma dizininden türetilen kısa etiket
    let project: String
    let model: String
    let used: Int
    let limit: Int
    /// Oturum-kümülatif bileşim (pencereyi neyin doldurduğu)
    let parts: TokenParts

    var percent: Double {
        limit > 0 ? Double(used) / Double(limit) * 100 : 0
    }
}

/// Offline özet: bir dönemin toplamı ve bileşimi
struct HistoryBucket: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let parts: TokenParts
}

struct HeatmapCell: Equatable, Sendable {
    let label: String
    let tokens: Int
    /// 0 (boş) ... 4 (en yoğun)
    let level: Int
}

struct HeatmapHourRow: Identifiable, Equatable, Sendable {
    let id: String
    let dayLabel: String
    let cells: [HeatmapCell]
}

/// Bir sağlayıcının offline + ısı haritası verisi (istendiğinde hesaplanır)
struct ProviderActivity: Equatable, Sendable {
    let history: [HistoryBucket]
    /// GitHub tarzı günlük grid: hafta sütunları × 7 gün (Pzt...Paz); gelecek günler nil
    let dailyGrid: [[HeatmapCell?]]
    let hourRows: [HeatmapHourRow]
    let totalTokens: Int
}

/// 1.2M / 45.3K biçiminde kompakt token sayısı
func formatTokenCount(_ value: Int) -> String {
    switch value {
    case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
    case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
    default: "\(value)"
    }
}

/// Yüzde etiketi: kesirliyse tek ondalıkla (3.1), tam sayıysa ondalıksız (32)
func formatPercent(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    return rounded == rounded.rounded()
        ? String(Int(rounded))
        : String(format: "%.1f", rounded)
}
