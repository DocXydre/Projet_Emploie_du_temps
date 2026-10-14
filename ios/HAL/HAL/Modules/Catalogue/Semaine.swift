import SwiftUI

extension Module {
    static let semaine = Module(
        id: "semaine", nom: "Semaine", icone: "calendar", categorie: .travail,
        tailles: [.grand],
        widget: { _ in AnyView(WidgetSemaine()) },
        ecran: { AnyView(EcranPlanning()) }
    )
}

/// Les sept jours d'un coup d'œil, tout compris : chaque bloc à son heure, dans
/// la couleur de sa famille. Toucher ouvre le planning [1.12].
struct WidgetSemaine: View {
    @Environment(Foyer.self) private var foyer

    /// La plage dessinée : de 7 h à 23 h.
    private let debutJour = 7.0
    private let finJour = 23.0

    var body: some View {
        CoquilleWidget(.semaine) {
            let elements = foyer.maSemaine
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Array(jours.enumerated()), id: \.offset) { _, jour in
                        colonne(jour, elements.filter { Calendar.current.isDate($0.debut, inSameDayAs: jour) })
                    }
                }
                legende(elements)
            }
        }
    }

    private var jours: [Date] {
        let calendrier = Calendar.current
        let aujourdhui = calendrier.startOfDay(for: .now)
        let lundi = calendrier.date(from: calendrier.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                                     from: aujourdhui)) ?? aujourdhui
        return (0..<7).compactMap { calendrier.date(byAdding: .day, value: $0, to: lundi) }
    }

    private func colonne(_ jour: Date, _ elements: [ElementPlanning]) -> some View {
        let aujourdhui = Calendar.current.isDateInToday(jour)
        return VStack(spacing: 4) {
            Text(String(EnFrancais.jourCourt(jour).prefix(1)))
                .texte(.etiquette)
                .foregroundStyle(aujourdhui ? Palette.textePrincipal : Palette.texteTertiaire)
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(aujourdhui ? Palette.verreTeinteForte : Palette.verreTeinte)
                    ForEach(elements.filter { $0.journeeEntiere != true }, id: \.cle) { element in
                        let (y, hauteur) = position(element, hauteurTotale: geo.size.height)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(element.famille.couleur)
                            .frame(height: max(4, hauteur))
                            .padding(.horizontal, 3)
                            .offset(y: y)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// La position d'un bloc dans la colonne, de 7 h à 23 h.
    private func position(_ element: ElementPlanning, hauteurTotale: CGFloat) -> (CGFloat, CGFloat) {
        func heures(_ date: Date) -> Double {
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        }
        let etendue = finJour - debutJour
        let debut = min(max(heures(element.debut), debutJour), finJour)
        let fin = min(max(heures(element.fin ?? element.debut.addingTimeInterval(1800)), debut), finJour)
        return (CGFloat((debut - debutJour) / etendue) * hauteurTotale,
                CGFloat((fin - debut) / etendue) * hauteurTotale)
    }

    private func legende(_ elements: [ElementPlanning]) -> some View {
        let familles = [Categorie.cours, .travail, .sport, .menage, .linge, .chat]
            .filter { famille in elements.contains { $0.famille == famille } }
        return HStack(spacing: 10) {
            ForEach(familles) { famille in
                HStack(spacing: 4) {
                    Circle().fill(famille.couleur).frame(width: 6, height: 6)
                    Text(famille == .chat ? "Sassy" : famille.libelle)
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// 1.12 : le planning de la semaine, un jour à la fois, filtré par personne,
/// en couleurs par catégorie (NOT-17 : la raison d'un changement en dessous).
struct EcranPlanning: View {
    @Environment(Foyer.self) private var foyer
    @State private var jour = Calendar.current.startOfDay(for: .now)
    @State private var qui: Int?
    @State private var semaine: [ElementPlanning]?
    @State private var erreur: String?
    @State private var ajoutRapide = false

    var body: some View {
        PageDefilante {
            EnTeteOnglet(surTitre: "Semaine du \(lundi.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR"))))",
                         titre: "Planning") {
                BoutonRond("plus", libelle: "Ajouter") { ajoutRapide = true }
            }
            choixDuJour
            if foyer.membres.count > 1 {
                HStack(spacing: 8) {
                    PuceChoix(texte: "Les deux", choisie: qui == nil) { qui = nil }
                    ForEach(foyer.membres) { membre in
                        PuceChoix(texte: membre.nom, choisie: qui == membre.id) { qui = membre.id }
                    }
                }
            }
            liste
        }
        .containerBackground(.clear, for: .navigation)
        .task { await charger() }
        .refreshable { await charger() }
        .sheet(isPresented: $ajoutRapide) { AjoutRapide().presentationDetents([.fraction(0.64), .large]) }
    }

    private var lundi: Date {
        let calendrier = Calendar.current
        return calendrier.date(from: calendrier.dateComponents([.yearForWeekOfYear, .weekOfYear], from: jour)) ?? jour
    }

    private var choixDuJour: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { rang in
                let date = Calendar.current.date(byAdding: .day, value: rang, to: lundi) ?? lundi
                let choisi = Calendar.current.isDate(date, inSameDayAs: jour)
                Button { withAnimation(.snappy) { jour = date } } label: {
                    VStack(spacing: 2) {
                        Text(String(EnFrancais.jourCourt(date).prefix(1))).texte(.etiquette)
                        Text(date.formatted(.dateTime.day())).texte(.corpsFort)
                    }
                    .foregroundStyle(choisi ? Color.black.opacity(0.85) : Palette.textePrincipal)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(choisi ? Categorie.sport.couleur : Palette.verreTeinte,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choisi ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var liste: some View {
        if let semaine {
            let lignes = semaine.filter {
                Calendar.current.isDate($0.debut, inSameDayAs: jour) && (qui == nil || $0.idUtilisateur == qui)
                    && $0.categorie != "sommeil"
            }
            if lignes.isEmpty {
                Text("Rien de prévu ce jour-là.")
                    .texte(.corps).foregroundStyle(Palette.texteSecondaire)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .carte()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(lignes.enumerated()), id: \.element.cle) { rang, element in
                        ligne(element)
                        if rang < lignes.count - 1 { Divider().overlay(Palette.verreBord) }
                    }
                }
                .carte()
            }
        } else if let erreur {
            Text(erreur).texte(.corps).foregroundStyle(Palette.texteSecondaire)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func ligne(_ element: ElementPlanning) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(element.journeeEntiere == true ? "Jour" : EnFrancais.heure(element.debut))
                    .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
                if element.journeeEntiere != true, let fin = element.fin {
                    Text(EnFrancais.heure(fin)).texte(.legende).foregroundStyle(Palette.texteTertiaire)
                }
            }
            .frame(width: 50, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(element.famille.couleur).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(element.libelle).texte(.corpsFort).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                if let sous = element.lieu ?? element.motif, !sous.isEmpty {
                    Text(sous).texte(.legende).foregroundStyle(Palette.texteSecondaire).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let membre = foyer.membre(numero: element.idUtilisateur), foyer.membres.count > 1 {
                Avatar(nom: membre.nom, couleur: foyer.couleur(de: membre), taille: 28)
            }
        }
        .padding(.horizontal, Espace.interne)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func charger() async {
        guard foyer.connecte else {
            semaine = []
            return
        }
        let iso = ISO8601DateFormatter()
        let fin = Calendar.current.date(byAdding: .day, value: 7, to: lundi) ?? lundi
        do {
            semaine = try await foyer.demander(
                "GET", "planning?debut=\(iso.string(from: lundi))&fin=\(iso.string(from: fin))")
            erreur = nil
        } catch {
            erreur = (error as? ErreurAPI)?.message ?? "Chargement impossible"
        }
    }
}
