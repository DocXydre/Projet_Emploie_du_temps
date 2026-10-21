import SwiftUI
import PhotosUI

/// Réglages (5.1), en cinq groupes (C.12) : apparence ; planning ; HAL et sport ;
/// appareil ; foyer et compte. Ce qui n'est pas encore construit ouvre un écran
/// qui dit à quel lot il arrive.
struct EcranReglages: View {
    @Environment(Foyer.self) private var foyer
    @Environment(Apparence.self) private var apparence
    @Environment(Disposition.self) private var disposition
    @Environment(Session.self) private var session
    @Environment(EnvoiSante.self) private var sante
    @Environment(Notifications.self) private var notifications
    @AppStorage(Yanga.cleActive) private var yanga = true

    var body: some View {
        PageDefilante {
            Text("Réglages").texte(.grandTitre).foregroundStyle(Palette.textePrincipal).padding(.bottom, 4)

            HStack(spacing: 12) {
                Avatar(nom: foyer.moi.nom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(foyer.moi.nom).texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                    Text(!foyer.connecte ? "Démonstration · données fictives"
                         : foyer.autre.map { "Connecté · avec \($0.nom)" } ?? "Connecté")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                }
                Spacer()
            }
            .padding(14)
            .carte(rayon: Rayon.controle)

            EnTeteGroupe(texte: "Apparence")
            GroupeReglages {
                lien("Fond et couleurs", "photo", Categorie.ia.couleur, valeur: apparence.combinaison.nom) { EcranFondCouleurs() }
                lien("Disposition de l'accueil", "checklist", Categorie.menage.couleur,
                     valeur: "\(disposition.places.count + 1) widgets") { EcranDisposition() }
            }

            EnTeteGroupe(texte: "Planning")
            GroupeReglages {
                lien("Calendriers à suivre", "calendar", Categorie.travail.couleur,
                     valeur: foyer.sansCalendrier ? "À ajouter" : nil) { EcranCalendriersSuivis() }
                lien("Calendriers abonnés", "calendar.badge.plus", Categorie.travail.couleur) { EcranCalendriersAbonnes() }
                lien("Types de tâches", "paintpalette", Categorie.menage.couleur,
                     valeur: "\(foyer.types.count)") { EcranTypesTaches() }
                lien("Historique", "clock", Categorie.travail.couleur) { EcranHistorique() }
            }

            EnTeteGroupe(texte: "HAL et sport")
            GroupeReglages {
                lien("Profil sportif", "person", Categorie.sport.couleur) { EcranProfilSportif() }
                lien("Limitations", "exclamationmark.circle", Categorie.alerte.couleur) { EcranLimitations() }
                lien("Lieux de sport", "mappin", Categorie.sport.couleur) { EcranLieux() }
                LigneReglage(icone: "drop", couleur: Categorie.sport.couleur, libelle: "Gourde Yanga",
                             accessoire: .interrupteur($yanga),
                             sousTitre: "Une recharge toutes les 20 min")
                lien("Mémoire de HAL", "sparkle", Categorie.ia.couleur) { EcranMemoire() }
                lien("Mettre HAL en pause", "pause", Categorie.ia.couleur,
                     valeur: foyer.sportDuServeur?.pause != nil ? "En pause" : nil) { EcranPause() }
                lien("Démarrage de HAL", "arrow.counterclockwise", Categorie.ia.couleur,
                     valeur: foyer.demarrageDeHAL.map { $0 == "profil" ? "À faire" : "À finir" }) { EcranDemarrageReglages() }
                lien("Intelligence", "terminal", Categorie.ia.couleur) { EcranIntelligence() }
            }

            EnTeteGroupe(texte: "Appareil")
            GroupeReglages {
                lien("Santé", "heart", Categorie.alerte.couleur,
                     valeur: !sante.disponible ? "Indisponible"
                        : sante.accesDemande ? "\(sante.lues.count) lues" : "À autoriser") { EcranReglagesSante() }
                lien("Apple Watch et Strava", "applewatch", Categorie.sport.couleur) { EcranMontre() }
                lien("Notifications et heures", "bell", Categorie.alerte.couleur,
                     valeur: etatNotifications) { EcranNotifications() }
            }

            EnTeteGroupe(texte: "Foyer et compte")
            GroupeReglages {
                lien("Le foyer", "person.2", Categorie.ia.couleur,
                     valeur: foyer.connecte ? "\(foyer.membres.count) membre\(foyer.membres.count > 1 ? "s" : "")" : nil) { EcranFoyer() }
                lien("Serveur et connexion", "lock", Palette.texteSecondaire,
                     valeur: session.pseudo ?? "Démonstration") { EcranServeur() }
            }

            EnTeteGroupe(texte: "Essais")
            GroupeReglages {
                lien("Composants", "square.grid.2x2", Categorie.linge.couleur) { EcranComposants() }
                lien("États à forcer", "slider.horizontal.3", Categorie.linge.couleur) { EcranEssais() }
            }
            Text("Les états à forcer ne valent qu'en démonstration. Connecté, tout vient du serveur.")
                .texte(.legende).foregroundStyle(Palette.texteTertiaire)
        }
    }

    private func lien<Destination: View>(_ libelle: String, _ icone: String, _ couleur: Color, valeur: String? = nil,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            LigneReglage(icone: icone, couleur: couleur, libelle: libelle, accessoire: .chevron(valeur))
        }
        .buttonStyle(.plain)
    }

    private var etatNotifications: String {
        switch notifications.etat {
        case .autorisees: "Activées"
        case .aDemander: "À activer"
        case .refusees: "Refusées"
        }
    }
}

/// Fond et couleurs (5.2) : la photo, son traitement et la combinaison (THM).
struct EcranFondCouleurs: View {
    @Environment(Apparence.self) private var apparence
    @State private var choix: PhotosPickerItem?

    var body: some View {
        @Bindable var apparence = apparence
        PagePoussee(titre: "Fond et couleurs") {
            HStack(alignment: .center, spacing: 16) {
                ApercuTelephone()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ta photo").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                    Text(apparence.photo == nil
                         ? "Celle d'origine. Le texte reste lisible grâce au voile."
                         : "Le texte reste lisible grâce au voile.")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        .fixedSize(horizontal: false, vertical: true)
                    PhotosPicker(selection: $choix, matching: .images) {
                        Text("Choisir une photo")
                    }
                    .buttonStyle(.hal(.verre))
                    if apparence.photo != nil {
                        Button("Photo d'origine") { apparence.changerPhoto(nil) }
                            .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    }
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 14) {
                curseur("Flou", valeur: $apparence.flou)
                curseur("Assombrissement", valeur: $apparence.assombrissement, bornes: 0...0.7)
                if apparence.plancherAssombrissement > apparence.assombrissement {
                    Text("Photo claire : elle reste assombrie d'au moins \(Int((apparence.plancherAssombrissement * 100).rounded())) %, pour que le texte se lise.")
                        .texte(.legende).foregroundStyle(Palette.texteSecondaire)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                curseur("Saturation", valeur: $apparence.saturation, bornes: 0...1.2)
                Toggle(isOn: $apparence.couleursDeLaPhoto.animation(.smooth)) {
                    Text("Couleurs tirées de la photo").texte(.corps).foregroundStyle(Palette.textePrincipal)
                }
                .tint(apparence.theme.principal)
                .disabled(apparence.photo == nil)
                Button("Réglages d'origine") { apparence.revenirAuxReglagesParDefaut() }
                    .buttonStyle(.hal(.verre))
            }
            .padding(Espace.interne)
            .carte(rayon: Rayon.controle)

            VStack(alignment: .leading, spacing: 14) {
                Text("COULEURS DES BOUTONS").texte(.etiquette).foregroundStyle(Palette.texteSecondaire)
                HStack(alignment: .top) {
                    ForEach(Combinaison.allCases) { combinaison in
                        PastilleTheme(combinaison: combinaison,
                                      choisie: !apparence.couleursDeLaPhoto && apparence.combinaison == combinaison) {
                            withAnimation(.smooth) {
                                apparence.couleursDeLaPhoto = false
                                apparence.combinaison = combinaison
                            }
                        }
                    }
                }
            }
            .padding(Espace.interne)
            .carte(rayon: Rayon.controle)

            EnTeteGroupe(texte: "Verre des cartes")
            VStack(alignment: .leading, spacing: 14) {
                Segmente(choix: StyleVerre.allCases.map { ($0, $0.nom) },
                         selection: $apparence.styleVerre.animation(.smooth))
                Text(apparence.styleVerre.detail).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .fixedSize(horizontal: false, vertical: true)
                if apparence.styleVerre != .depoli {
                    curseur("Assombrir le verre", valeur: $apparence.teinteVerre, bornes: 0...0.6)
                }
            }
            .padding(Espace.interne)
            .carte(rayon: Rayon.controle)

        }
        .onChange(of: choix) {
            guard let choix else { return }
            Task {
                if let donnees = try? await choix.loadTransferable(type: Data.self),
                   let image = UIImage(data: donnees) {
                    apparence.changerPhoto(image.reduite(cote: 2400))
                }
                self.choix = nil
            }
        }
    }

    private func curseur(_ titre: String, valeur: Binding<Double>, bornes: ClosedRange<Double> = 0...1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(titre).texte(.corps).foregroundStyle(Palette.textePrincipal)
                Spacer()
                Text("\(Int((valeur.wrappedValue * 100).rounded())) %")
                    .texte(.corps).monospacedDigit().foregroundStyle(Palette.texteSecondaire)
            }
            Slider(value: valeur, in: bornes).tint(apparence.theme.principal)
        }
    }
}

/// Le fond en vignette de téléphone, avec deux cartes de verre posées dessus,
/// pour juger la lisibilité d'un coup d'œil (5.2).
private struct ApercuTelephone: View {
    var body: some View {
        ZStack(alignment: .top) {
            Fond()
            VStack(alignment: .leading, spacing: 6) {
                carte(lignes: 2, accent: Categorie.travail.couleur)
                HStack(spacing: 6) {
                    carte(lignes: 3, accent: Categorie.menage.couleur)
                    carte(lignes: 3, accent: Categorie.sport.couleur)
                }
                carte(lignes: 1, accent: Categorie.ia.couleur)
            }
            .padding(.horizontal, 8)
            .padding(.top, 22)
        }
        .frame(width: 112, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Palette.verreBord, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func carte(lignes: Int, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(accent).frame(width: 22, height: 3)
            ForEach(0..<lignes, id: \.self) { rang in
                Capsule().fill(Palette.textePrincipal.opacity(rang == 0 ? 0.8 : 0.4))
                    .frame(height: 3).padding(.trailing, CGFloat(rang * 8))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Disposition de l'accueil : revenir à celle d'origine.
struct EcranDisposition: View {
    @Environment(Disposition.self) private var disposition
    @Environment(\.annoncer) private var annoncer

    var body: some View {
        PagePoussee(titre: "Disposition de l'accueil") {
            Text("La disposition se change directement sur Aujourd'hui : touche le crayon, puis déplace, retire ou agrandis les widgets. Elle reste sur ce téléphone.")
                .texte(.corps).foregroundStyle(Palette.texteSecondaire)
            Button("Revenir à la disposition d'origine") {
                let avant = disposition.places
                disposition.revenirAuParDefaut()
                annoncer("Disposition d'origine remise") { disposition.restaurer(avant) }
            }
            .buttonStyle(.hal(.verre, pleineLargeur: true, grand: true))
        }
    }
}

extension UIImage {
    /// La même image, ramenée à `cote` points sur son plus grand côté.
    func reduite(cote: CGFloat) -> UIImage {
        let plusGrand = max(size.width, size.height)
        guard plusGrand > cote else { return self }
        let echelle = cote / plusGrand
        let taille = CGSize(width: size.width * echelle, height: size.height * echelle)
        return UIGraphicsImageRenderer(size: taille).image { _ in draw(in: CGRect(origin: .zero, size: taille)) }
    }
}
