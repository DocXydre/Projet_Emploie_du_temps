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
                                ForEach(message.elements) { element in
                                    CarteElement(element: element, ouvrir: ouvrir)
                                }
                            }
                            .id(message.id)
                        }
                        if conversation.reflechit { Reflexion(texte: conversation.regarde).id("reflexion") }
                        if conversation.echec { Echec() }
                    }
                    .padding(.horizontal, Espace.interne)
                }
                .scrollIndicators(.hidden)
                .onChange(of: conversation.messages.count) { descendre(defilement) }
                .onChange(of: conversation.reflechit) { descendre(defilement) }
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
        // sur un fond sombre et presque opaque, quelle que soit la photo.
        .background {
            let forme = RoundedRectangle(cornerRadius: 32, style: .continuous)
            forme.fill(Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.86))
                .background(.ultraThinMaterial, in: forme)
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
                FeuilleMesure(mesure: mesure).presentationDetents([.large]).feuilleEnVerre()
            case .objectifs:
                NavigationStack { EcranObjectifs() }.feuilleEnVerre()
            }
        }
    }

    private func descendre(_ defilement: ScrollViewProxy) {
        let cible = conversation.reflechit ? "reflexion" : conversation.messages.last?.id
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
                        Button(proposition.texte) {
                            conversation.envoyer(proposition.texte, moment: proposition.moment,
                                                 horsReseau: foyer.essais.horsReseau)
                        }
                        .buttonStyle(.hal(.verre))
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
                Text(message.texte)
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

    private var fond: Color {
        switch message.auteur {
        case .moi: Categorie.ia.voile
        case .hal: Palette.verreTeinteForte
        case .systeme: Categorie.alerte.voile
        }
    }

    private var legende: String? {
        if message.enAttente { return "En attente de HAL" }
        if message.moment == "synthese" || message.moment == "revision" { return "Récap du soir" }
        return nil
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
            return element.seances.map { ["\($0) séance\($0 > 1 ? "s" : "") proposée\($0 > 1 ? "s" : "")"] } ?? []
        case "fenetre_mesure":
            return [["Du", TexteHAL.jour(element.du), "au", TexteHAL.jour(element.au)].compactMap { $0 }
                        .joined(separator: " "), element.consigne].compactMap { $0 }
        case "avis_objectif", "avis_seance_libre":
            return [TexteHAL.avis(element.avis), element.detail].compactMap { $0 }
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
                    Bouton(libelle: "Voir") { ouvrir(.semaine(lundi)) }].compactMap { $0 }
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
