import SwiftUI
import Charts

/// Un point d'une série : une date et une valeur, absente si la donnée manque.
struct PointSerie: Identifiable {
    let date: Date
    let valeur: Double?
    var id: Date { date }
}

/// Une courbe : fréquence cardiaque, poids, allure. Un jour sans donnée reste vide (APP-4).
struct Courbe: View {
    let points: [PointSerie]
    var couleur: Color = Categorie.alerte.couleur
    var hauteur: CGFloat = 90

    var body: some View {
        Chart {
            ForEach(points) { point in
                if let valeur = point.valeur {
                    LineMark(x: .value("Moment", point.date), y: .value("Valeur", valeur))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(couleur)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: hauteur)
    }
}

/// Des barres : séances de la semaine, temps passé aux tâches.
struct Barres: View {
    let valeurs: [(String, Double)]
    var couleur: Color? = nil
    var hauteur: CGFloat = 90
    @Environment(\.theme) private var theme

    var body: some View {
        Chart {
            ForEach(valeurs.indices, id: \.self) { rang in
                BarMark(x: .value("Jour", valeurs[rang].0), y: .value("Valeur", valeurs[rang].1))
                    .foregroundStyle(couleur ?? theme.principal)
                    .cornerRadius(4)
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().foregroundStyle(Palette.texteTertiaire)
            }
        }
        .frame(height: hauteur)
    }
}
