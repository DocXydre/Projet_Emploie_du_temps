import SwiftUI

/// Ce que le panneau ouvre par-dessus lui : une séance, une semaine, une mesure.
private enum FeuillePanneau: Identifiable {
    case seance(DetailSeance)
    case semaine(Date?)
    case mesure(MesureDemandee)
    case objectifs

    var id: String {
        switch self {
        case .seance(let detail): "seance-\(detail.seance.idOccurrence)"
        case .semaine(let lundi): "semaine-\(lundi?.timeIntervalSince1970 ?? 0)"
        case .mesure(let mesure): "mesure-\(mesure.id)"
        case .objectifs: "objectifs"
        }
    }
}

/// Le panneau de HAL. Il s'ouvre au-dessus de la barre d'onglets et pousse le
/// contenu vers le haut au lieu de le recouvrir (ORB-1).
struct PanneauHAL: View {
    @Environment(ConversationHAL.self) private var conversation
    @Environment(Foyer.self) private var foyer
    @State private var texte = ""
    @State private var feuille: FeuillePanneau?
    @FocusState private var saisie: Bool

    var body: some View {
        VStack(spacing: 12) {
            Capsule().fill(Palette.verreBord).frame(width: 36, height: 5).padding(.top, 8)
            entete
            if let joint = conversation.joint { carteJointe(joint) }
            ScrollViewReader { defilement in
                ScrollView {
                    VStack(spacing: 10) {
                        if conversation.inactif || foyer.sportDuServeur?.demarrage != nil {
                            CarteDemarrage()
                        }
                        ForEach(conversation.messages) { message in
                            VStack(spacing: 8) {
                                Bulle(message: message)
                                ForEach(Self.regrouper(message.elements)) { bloc in
                                    switch bloc {
                                    case .seul(let element):
                                        CarteElement(element: element, ouvrir: ouvrir)
                                    case .semaine(let semaine, let seances):
                                        CarteElement(element: semaine, seances: seances, ouvrir: ouvrir)
                                    }
                                }
                            }
                            .id(message.id)
                        }
                        if conversation.reflechit { Reflexion(texte: conversation.regarde).id("reflexion") }
                        if conversation.echec { Echec().id("echec") }
                    }
                    .padding(.horizontal, Espace.interne)
                }
                .scrollIndicators(.hidden)
                .onChange(of: conversation.messages.count) { descendre(defilement) }
                .onChange(of: conversation.reflechit) { descendre(defilement) }
                .onChange(of: conversation.echec) { descendre(defilement) }
                .onAppear { descendre(defilement) }
            }
            if conversation.dictee {
                Dictee { dicte in
                    texte = dicte
                    envoyer()
                } clavier: { dicte in
                    texte = dicte
                    saisie = true
                }
            } else {
                reponsesPretes
                champ
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        // Le panneau ne suit pas le réglage du verre : une conversation se lit
        // sur le verre dépoli, un peu plus dense que celui des widgets.
        .background {
            let forme = RoundedRectangle(cornerRadius: 32, style: .continuous)
            forme.fill(Color.black.opacity(0.18))
                .background(.thinMaterial, in: forme)
                .overlay(forme.strokeBorder(Palette.verreBord, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        }
        .gesture(DragGesture(minimumDistance: 20).onEnded { geste in
            if geste.translation.height > 60 { conversation.fermer() }
        })
        .sheet(item: $feuille) { choix in
            switch choix {
            case .seance(let detail):
                EcranSeancePrevue(detail: detail)
            case .semaine(let lundi):
                NavigationStack { EcranSemaine(lundi: lundi) }.feuilleEnVerre()
            case .mesure(let mesure):
                FeuilleMesure(mesure: mesure).presentationDetents([.fraction(0.8), .large]).feuilleEnVerre()
            case .objectifs:
                NavigationStack { EcranObjectifs() }.feuilleEnVerre()
            }
        }
    }

    /// 2.3 : une semaine à valider porte ses séances proposées dans une seule
    /// carte, avec « Valider la semaine ». Le reste garde une carte chacun.
    enum Bloc: Identifiable {
        case seul(ElementHAL)
        case semaine(ElementHAL, [ElementHAL])

        var id: String {
            switch self {
            case .seul(let element): element.id
            case .semaine(let semaine, _): semaine.id
            }
        }
    }

    static func regrouper(_ elements: [ElementHAL]) -> [Bloc] {
        let semaines = elements.filter { $0.type == "semaine_a_valider" }
        guard !semaines.isEmpty else { return elements.map(Bloc.seul) }
        func lundi(de element: ElementHAL) -> String? {
            guard let texte = element.jour ?? element.debut, let date = Dates.lire(texte) else { return nil }
            let calendrier = Calendar.current
            let debut = calendrier.date(from: calendrier.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))
            return debut.map(TexteHAL.jourISO)
        }
        var rattachees: [String: [ElementHAL]] = [:]
        var blocs: [Bloc] = []
        for element in elements where element.type == "seance_proposee" {
            if let cle = lundi(de: element), semaines.contains(where: { $0.lundi?.prefix(10) == cle.prefix(10) }) {
                rattachees[cle, default: []].append(element)
            }
        }
        for element in elements {
            if element.type == "semaine_a_valider" {
                blocs.append(.semaine(element, rattachees[String(element.lundi?.prefix(10) ?? "")] ?? []))
            } else if element.type == "seance_proposee", let cle = lundi(de: element),
                      rattachees[cle]?.contains(element) == true {
                continue
            } else {
                blocs.append(.seul(element))
            }
        }
        return blocs
    }

    private func descendre(_ defilement: ScrollViewProxy) {
        let cible = conversation.reflechit ? "reflexion"
            : conversation.echec ? "echec" : conversation.messages.last?.id
        guard let cible else { return }
        withAnimation { defilement.scrollTo(cible, anchor: .bottom) }
    }

    private func ouvrir(_ demande: OuvertureDepuisHAL) {
        switch demande {
        case .seance(let id):
            Task {
                if let detail: DetailSeance = try? await foyer.demander("GET", "seances/\(id)") {
                    feuille = .seance(detail)
                }
            }
        case .semaine(let lundi): feuille = .semaine(lundi)
        case .mesure(let mesure): feuille = .mesure(mesure)
        case .objectifs: feuille = .objectifs
        }
    }

    private var entete: some View {
        HStack(spacing: 10) {
            Orbe(etat: conversation.etatOrbe, taille: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("HAL").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                Text("Voit : \(conversation.voit)").texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .lineLimit(1)
            }
            Spacer()
            BoutonRond("chevron.down", libelle: "Fermer HAL") { conversation.fermer() }
        }
        .padding(.horizontal, Espace.interne)
    }

    /// COA-32 : l'élément sur lequel on demande un changement, joint en haut.
    private func carteJointe(_ joint: ElementJoint) -> some View {
        HStack(spacing: 10) {
            Image(systemName: joint.genre == .seance ? "figure.run" : "calendar")
                .foregroundStyle(Categorie.sport.couleur)
            VStack(alignment: .leading, spacing: 1) {
                Text("Changer").texte(.etiquette).foregroundStyle(Palette.texteTertiaire)
                Text(joint.libelle).texte(.corpsFort).foregroundStyle(Palette.textePrincipal).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { conversation.joint = nil } label: {
                Image(systemName: "xmark").foregroundStyle(Palette.texteSecondaire).frame(width: 32, height: 32)
            }
            .accessibilityLabel("Retirer l'élément joint")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.verreTeinteForte, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, Espace.interne)
    }

    /// ORB-9, ORB-11 : les réponses courantes en boutons, le texte libre reste possible.
    @ViewBuilder private var reponsesPretes: some View {
        let choix = propositions
        if !choix.isEmpty && !conversation.reflechit && conversation.enAttente == nil {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(choix, id: \.texte) { proposition in
                        Button {
                            conversation.envoyer(proposition.texte, moment: proposition.moment,
                                                 horsReseau: foyer.essais.horsReseau)
                        } label: {
                            HStack(spacing: 6) {
                                Orbe(etat: .repos, taille: 14)
                                Text(proposition.texte).texte(.legende).foregroundStyle(Palette.textePrincipal)
                            }
                            .padding(.leading, 6)
                            .padding(.trailing, 12)
                            .frame(height: 30)
                            .background(Categorie.ia.voile, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.verreBord, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var propositions: [(texte: String, moment: String?)] {
        if conversation.joint != nil {
            return [("Décale-la", nil), ("Raccourcis-la", nil), ("Je ne peux pas ce jour-là", nil)]
        }
        if let dernier = conversation.messages.last, dernier.auteur == .hal,
           dernier.texte.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            return [("Oui", nil), ("Non", nil), ("Je ne sais pas", nil)]
        }
        return [("J'ai mal quelque part", "signalement"), ("Je suis fatigué", "signalement"),
                ("J'ai un contretemps", "signalement")]
    }

    private var champ: some View {
        HStack(spacing: 8) {
            TextField(conversation.joint != nil ? "Qu'est-ce qui doit changer ?" : "Demande à HAL…",
                      text: $texte, axis: .vertical)
                .texte(.corps)
                .foregroundStyle(Palette.textePrincipal)
                .lineLimit(1...4)
                .focused($saisie)
                .submitLabel(.send)
                .onSubmit(envoyer)
            Button { conversation.dictee = true } label: {
                Image(systemName: "mic").foregroundStyle(Palette.texteSecondaire).frame(width: 32, height: 32)
            }
            .accessibilityLabel("Dicter")
            Button(action: envoyer) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.texteSurAccent)
                    .frame(width: 32, height: 32)
                    .background(Categorie.ia.couleur, in: Circle())
            }
            .disabled(texte.trimmingCharacters(in: .whitespaces).isEmpty || conversation.enAttente != nil)
            .accessibilityLabel("Envoyer")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(minHeight: 48)
        .verreControle(Capsule(), interactif: false)
        .padding(.horizontal, 12)
    }

    private func envoyer() {
        conversation.envoyer(texte, horsReseau: foyer.essais.horsReseau)
        texte = ""
    }
}

/// Une parole, à droite pour soi, à gauche pour HAL.
private struct Bulle: View {
    let message: MessageHAL

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.auteur == .moi { Spacer(minLength: 48) }
            VStack(alignment: message.auteur == .moi ? .trailing : .leading, spacing: 3) {
                Text(Self.enForme(message.texte))
                    .texte(.corps)
                    .foregroundStyle(Palette.textePrincipal)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(fond, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
                if let legende {
                    Text(legende).texte(.legende).foregroundStyle(Palette.texteTertiaire)
                }
            }
            if message.auteur != .moi { Spacer(minLength: 48) }
        }
    }

    /// HAL écrit en markdown : le gras, l'italique et les listes s'affichent,
    /// pas leurs signes. Un texte qui ne se lit pas ainsi reste tel quel.
    static func enForme(_ texte: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let puces = texte.replacingOccurrences(of: #"(?m)^\s*[-*] "#, with: "• ", options: .regularExpression)
        return (try? AttributedString(markdown: puces, options: options)) ?? AttributedString(texte)
    }

    private var fond: Color {
        switch message.auteur {
        case .moi: Categorie.ia.voile
        case .hal: Palette.verreTeinteForte
        case .systeme: Categorie.alerte.voile
        }
    }

    private var legende: String? {
        if message.enAttente { return "En attente de HAL" }
        if message.moment == "synthese" || message.moment == "revision" {
            return ["Récap du soir", message.noteFournisseur].compactMap { $0 }.joined(separator: " · ")
        }
        return message.noteFournisseur
    }
}

/// Ce qu'un élément ouvre dans le panneau.
enum OuvertureDepuisHAL {
    case seance(Int)
    case semaine(Date?)
    case mesure(MesureDemandee)
    case objectifs
}

/// Un élément de la réponse, avec ses boutons (COA-17, ORB-6).
private struct CarteElement: View {
    let element: ElementHAL
    /// Les séances proposées d'une semaine à valider, une ligne chacune (2.3).
    var seances: [ElementHAL] = []
    let ouvrir: (OuvertureDepuisHAL) -> Void
    @Environment(ConversationHAL.self) private var conversation
    @Environment(\.annoncer) private var annoncer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(titre, systemImage: icone)
                .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            ForEach(lignes, id: \.self) { ligne in
                Text(ligne).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(seances) { seance in
                HStack(spacing: 10) {
                    Text(TexteHAL.jour(seance.jour ?? seance.debut).map { String($0.split(separator: " ").prefix(2).joined(separator: " ")) } ?? "")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        .frame(width: 58, alignment: .leading)
                    Text([seance.typeSeance ?? Discipline.nom(seance.discipline), TexteHAL.heure(seance.debut)]
                            .compactMap { $0 }.joined(separator: " · "))
                        .texte(.corps).foregroundStyle(Palette.textePrincipal).lineLimit(1)
                }
            }
            if let regle = conversation.faits[element.id] ?? element.regle {
                Label(regle, systemImage: "checkmark.circle.fill")
                    .texte(.corpsFort).foregroundStyle(Categorie.sport.couleur)
            } else if !boutons.isEmpty {
                // Jusqu'à quatre boutons : ils passent à la ligne plutôt que de déborder.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading,
                          spacing: 8) {
                    ForEach(boutons.indices, id: \.self) { rang in
                        let bouton = boutons[rang]
                        Button(bouton.libelle, action: bouton.faire)
                            .buttonStyle(.hal(rang == 0 ? .accent : .verre, pleineLargeur: true))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.verreBord, lineWidth: 0.5))
        .padding(.trailing, 24)
    }

    private var titre: String {
        switch element.type {
        case "seance_proposee":
            return [Discipline.nom(element.discipline), element.typeSeance].compactMap { $0 }.joined(separator: " · ")
        case "seance_retiree": return "Séance retirée"
        case "ajustement": return "\(TexteHAL.nature(element.nature)) : \(Discipline.nom(element.discipline))"
        case "semaine_a_valider":
            return "Semaine du \(TexteHAL.jour(element.lundi) ?? "") à valider"
        case "fenetre_mesure": return TypeMesure.nom(element.typeMesure ?? "")
        case "avis_objectif": return element.libelle ?? "Ton objectif"
        case "avis_seance_libre": return "Ta séance libre"
        case "plan": return "Ton plan sur quatre semaines"
        case "demande": return element.libelle ?? "Une demande"
        default: return element.type
        }
    }

    private var icone: String {
        switch element.type {
        case "seance_proposee": "figure.run"
        case "seance_retiree": "minus.circle"
        case "ajustement": "slider.horizontal.3"
        case "semaine_a_valider": "calendar.badge.checkmark"
        case "fenetre_mesure": "scalemass"
        case "avis_objectif": "target"
        case "plan": "calendar"
        case "demande": "hand.raised"
        default: "sparkle"
        }
    }

    private var lignes: [String] {
        switch element.type {
        case "seance_proposee":
            var morceaux = [TexteHAL.jour(element.jour ?? element.debut), TexteHAL.heure(element.debut),
                            element.dureeMinutes.map { "\($0) min" }, element.lieu].compactMap { $0 }
            if element.esquisse == true { morceaux.append("esquisse") }
            return [morceaux.joined(separator: " · ")]
        case "seance_retiree":
            return [TexteHAL.jour(element.jour), element.motif].compactMap { $0 }
        case "ajustement":
            return [[TexteHAL.jour(element.jour ?? element.debut), TexteHAL.heure(element.debut)]
                        .compactMap { $0 }.joined(separator: " · "),
                    element.motif].compactMap { $0 }.filter { !$0.isEmpty }
        case "semaine_a_valider":
            guard seances.isEmpty else { return [] }
            return element.seances.map { ["\($0) séance\($0 > 1 ? "s" : "") proposée\($0 > 1 ? "s" : "")"] } ?? []
        case "fenetre_mesure":
            return [["Du", TexteHAL.jour(element.du), "au", TexteHAL.jour(element.au)].compactMap { $0 }
                        .joined(separator: " "), element.consigne].compactMap { $0 }
        case "avis_objectif", "avis_seance_libre":
            return [TexteHAL.avis(element.avis), element.detail].compactMap { $0 }
        case "demande":
            return [element.motif, "Rien ne change sans ton accord"].compactMap { $0 }
        case "plan":
            return (element.semaines ?? []).map { semaine in
                "Semaine du \(TexteHAL.jour(semaine.lundi) ?? "") : \(TexteHAL.role(semaine.role))"
            }
        default: return []
        }
    }

    private struct Bouton {
        let libelle: String
        let faire: () -> Void
    }

    /// Seuls les boutons que l'appli sait faire sans autre question. Déplacer ou
    /// changer de lieu passent par « Changer », qui en parle à HAL.
    private var boutons: [Bouton] {
        let actions = element.actions ?? []
        func route(_ libelle: String) -> ActionHAL? { actions.first { $0.libelle == libelle } }
        func differe(_ libelle: String, _ confirmation: String) -> Bouton? {
            route(libelle).map { action in
                Bouton(libelle: libelle) {
                    conversation.agir(action, sur: element.id, confirmation: confirmation, annoncer: annoncer)
                }
            }
        }
        switch element.type {
        case "seance_proposee":
            guard let id = element.idOccurrence else { return [] }
            return [differe("Valider", "Séance validée"),
                    Bouton(libelle: "Voir") { ouvrir(.seance(id)) },
                    Bouton(libelle: "Changer") {
                        conversation.joint = ElementJoint(genre: .seance, idOccurrence: id, libelle: titre)
                    },
                    differe("Supprimer", "Séance supprimée")].compactMap { $0 }
        case "semaine_a_valider":
            let lundi = element.lundi.flatMap(Dates.lire)
            return [differe("Valider la semaine", "Semaine validée"),
                    Bouton(libelle: "Ouvrir") { ouvrir(.semaine(lundi)) }].compactMap { $0 }
        case "ajustement":
            return [differe("Accepter", "Ajustement accepté"),
                    differe("Refuser", "Ajustement refusé")].compactMap { $0 }
        case "fenetre_mesure":
            guard let type = element.typeMesure else { return [] }
            let mesure = MesureDemandee(titre: TypeMesure.nom(type), consigne: element.consigne ?? "",
                                        jusquA: "", id: element.idFenetre ?? 0, type: type)
            return [Bouton(libelle: "Saisir") { ouvrir(.mesure(mesure)) },
                    differe("Reporter", "Mesure repoussée")].compactMap { $0 }
        case "avis_objectif":
            return [Bouton(libelle: "Voir les objectifs") { ouvrir(.objectifs) }]
        case "plan":
            return [Bouton(libelle: "Voir la semaine") { ouvrir(.semaine(nil)) }]
        case "demande":
            // ACC-5, ACC-7 : l'accord part au bout de cinq secondes, « Annuler » le retient.
            return [differe("Accepter", "Demande acceptée"),
                    differe("Refuser", "Demande refusée")].compactMap { $0 }
        default:
            return []
        }
    }
}

/// HAL n'est pas encore prêt pour ce compte : le démarrage (DEM-1).
private struct CarteDemarrage: View {
    @Environment(ConversationHAL.self) private var conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("HAL n'a pas encore ton profil", systemImage: "sparkle")
                .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            Text("Quelques questions à toucher, et il te propose quatre semaines d'entraînement.")
                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
            Button("Démarrer HAL") {
                conversation.fermer()
                conversation.demarrageOuvert = true
            }
            .buttonStyle(.hal(.accent, pleineLargeur: true))
        }
        .padding(12)
        .background(Categorie.ia.voile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Les trois points pendant que HAL réfléchit, et ce qu'il regarde (ORB-7).
private struct Reflexion: View {
    let texte: String
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3) { rang in
                    Circle().fill(Categorie.ia.couleur).frame(width: 7, height: 7)
                        .opacity(phase == rang ? 1 : 0.35)
                }
            }
            Text(texte).texte(.legende).foregroundStyle(Palette.texteSecondaire)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Palette.verreTeinte, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                phase = (phase + 1) % 3
            }
        }
    }
}

/// HAL n'a pas pu répondre : le message est gardé, on réessaie (ORB-8).
private struct Echec: View {
    @Environment(ConversationHAL.self) private var conversation
    @Environment(Foyer.self) private var foyer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("HAL n'a pas pu répondre", systemImage: "exclamationmark.circle")
                .texte(.corpsFort).foregroundStyle(Palette.textePrincipal)
            Text("Ton message est gardé. Il repart tout seul à la prochaine ouverture, ou maintenant :")
                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
            HStack {
                Button("Réessayer") { conversation.reessayer(horsReseau: foyer.essais.horsReseau) }
                    .buttonStyle(.hal(.accent, pleineLargeur: true))
                Button("Plus tard") { conversation.plusTard() }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
            }
        }
        .padding(12)
        .background(Categorie.alerte.voile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
