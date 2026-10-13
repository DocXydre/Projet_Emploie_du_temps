import SwiftUI
import PhotosUI

/// Réglages (5.1), rangés en groupes. Ce qui n'est pas encore construit ouvre un
/// écran qui dit à quel lot il arrive.
struct EcranReglages: View {
    @Environment(Foyer.self) private var foyer
    @Environment(Apparence.self) private var apparence
    @Environment(Disposition.self) private var disposition
    @Environment(Session.self) private var session

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
                aVenir("Calendriers à suivre", "calendar", Categorie.travail.couleur, lot: 5)
                aVenir("Calendriers abonnés", "calendar.badge.plus", Categorie.travail.couleur, lot: 5)
                aVenir("Historique", "clock", Categorie.travail.couleur, lot: 8)
            }

            EnTeteGroupe(texte: "HAL et sport")
            GroupeReglages {
                aVenir("Profil sportif", "person", Categorie.sport.couleur, lot: 7)
                aVenir("Limitations", "exclamationmark.circle", Categorie.alerte.couleur, lot: 7)
                aVenir("Lieux de sport", "mappin", Categorie.sport.couleur, lot: 7)
                aVenir("Mémoire de HAL", "sparkle", Categorie.ia.couleur, lot: 7)
                aVenir("Mettre HAL en pause", "pause", Categorie.ia.couleur, lot: 7)
            }

            EnTeteGroupe(texte: "Appareil")
            GroupeReglages {
                aVenir("Santé", "heart", Categorie.alerte.couleur, lot: 6)
                aVenir("Apple Watch", "applewatch", Categorie.sport.couleur, lot: 9)
                aVenir("Notifications", "bell", Categorie.alerte.couleur, lot: 8)
            }

            EnTeteGroupe(texte: "Foyer et compte")
            GroupeReglages {
                aVenir("Le foyer", "person.2", Categorie.ia.couleur, lot: 8)
                lien("Serveur et mot de passe", "lock", Palette.texteSecondaire,
                     valeur: session.pseudo ?? "Démonstration") { EcranCompte() }
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

    private func aVenir(_ libelle: String, _ icone: String, _ couleur: Color, lot: Int) -> some View {
        lien(libelle, icone, couleur) { EcranAVenir(titre: libelle, lot: lot) }
    }
}

/// Un réglage qui n'est pas encore construit.
struct EcranAVenir: View {
    let titre: String
    let lot: Int

    var body: some View {
        PagePoussee(titre: titre) {
            VStack(spacing: 12) {
                Image(systemName: "hammer").font(.system(size: 28)).foregroundStyle(Palette.texteSecondaire)
                Text("Cet écran arrive au lot \(lot).").texte(.corps).foregroundStyle(Palette.texteSecondaire)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
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
            Fond()
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Rayon.widget, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Rayon.widget, style: .continuous)
                    .strokeBorder(Palette.verreBord, lineWidth: 0.5))

            HStack {
                PhotosPicker(selection: $choix, matching: .images) {
                    Text("Choisir une photo")
                }
                .buttonStyle(.hal(.accent, pleineLargeur: true))
                if apparence.photo != nil {
                    Button("Photo d'origine") { apparence.changerPhoto(nil) }
                        .buttonStyle(.hal(.verre, pleineLargeur: true))
                }
            }

            EnTeteGroupe(texte: "Lisibilité")
            VStack(spacing: 14) {
                curseur("Flou", valeur: $apparence.flou)
                curseur("Assombrissement", valeur: $apparence.assombrissement, bornes: 0...0.7)
                curseur("Couleurs de la photo", valeur: $apparence.saturation, bornes: 0...1.2)
                Button("Réglages d'origine") { apparence.revenirAuxReglagesParDefaut() }
                    .buttonStyle(.hal(.verre))
            }
            .padding(Espace.interne)
            .carte(rayon: Rayon.controle)

            EnTeteGroupe(texte: "Couleurs des boutons")
            VStack(spacing: 14) {
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
                Toggle(isOn: $apparence.couleursDeLaPhoto.animation(.smooth)) {
                    Text("Déduire les couleurs de la photo").texte(.corps).foregroundStyle(Palette.textePrincipal)
                }
                .tint(apparence.theme.principal)
                .disabled(apparence.photo == nil)
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
            Text(titre).texte(.corps).foregroundStyle(Palette.textePrincipal)
            Slider(value: valeur, in: bornes).tint(apparence.theme.principal)
        }
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

/// Le compte : à quel serveur on est connecté, changer son mot de passe, se
/// déconnecter (CNX-2, CNX-6). En démonstration, se connecter.
struct EcranCompte: View {
    @Environment(Session.self) private var session
    @Environment(Foyer.self) private var foyer
    @Environment(FileAttente.self) private var file
    @Environment(\.annoncer) private var annoncer
    @State private var nouveau = ""
    @State private var enCours = false
    @State private var erreur: String?
    @State private var confirmer = false

    var body: some View {
        Form {
            if let pseudo = session.pseudo {
                Section("Connecté") {
                    LabeledContent("Pseudo", value: pseudo)
                    LabeledContent("Serveur", value: session.adresse?.host() ?? "")
                    if let misAJour = foyer.misAJour {
                        LabeledContent("À jour", value: misAJour.formatted(date: .omitted, time: .shortened))
                    }
                }
                Section {
                    SecureField("Nouveau mot de passe", text: $nouveau)
                        .textContentType(.newPassword)
                    Button("Changer le mot de passe") { Task { await changer() } }
                        .disabled(nouveau.count < 10 || enCours)
                } header: {
                    Text("Mot de passe")
                } footer: {
                    Text("Au moins dix caractères. La clé de l'appli ne change pas : tes autres appareils restent connectés.")
                }
                if let erreur {
                    Section { Label(erreur, systemImage: "exclamationmark.circle").foregroundStyle(Categorie.alerte.couleur) }
                }
                Section {
                    Button("Se déconnecter", role: .destructive) { confirmer = true }
                        .frame(maxWidth: .infinity)
                } footer: {
                    if !file.enAttente.isEmpty {
                        Text("\(file.enAttente.count) envoi(s) en attente seront perdus.")
                    }
                }
            } else {
                Section {
                    Text("L'appli tourne sur des données fictives.")
                    Button("Se connecter à un serveur") { session.deconnecter() }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Serveur et mot de passe")
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(.clear, for: .navigation)
        .confirmationDialog("Se déconnecter ?", isPresented: $confirmer, titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) {
                file.vider(sansEnvoyer: true)
                session.deconnecter()
            }
        }
    }

    private struct Demande: Encodable { let motDePasse: String }

    private func changer() async {
        enCours = true
        erreur = nil
        defer { enCours = false }
        do {
            try await foyer.agir("PUT", "mot-de-passe", corps: ClientAPI.corps(Demande(motDePasse: nouveau)))
            nouveau = ""
            annoncer("Mot de passe changé")
        } catch {
            erreur = (error as? ErreurAPI)?.message ?? error.localizedDescription
        }
    }
}
