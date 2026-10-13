import SwiftUI

/// Le panneau de HAL. Il s'ouvre au-dessus de la barre d'onglets et pousse le
/// contenu vers le haut au lieu de le recouvrir (ORB-1).
struct PanneauHAL: View {
    @Environment(ConversationHAL.self) private var conversation
    @Environment(Foyer.self) private var foyer
    @State private var texte = ""
    @FocusState private var saisie: Bool

    var body: some View {
        VStack(spacing: 12) {
            Capsule().fill(Palette.verreBord).frame(width: 36, height: 5).padding(.top, 8)
            entete
            ScrollViewReader { defilement in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(conversation.messages) { message in
                            Bulle(message: message).id(message.id)
                        }
                        if conversation.reflechit { Reflexion(texte: conversation.regarde) }
                        if conversation.echec { Echec() }
                    }
                    .padding(.horizontal, Espace.interne)
                }
                .scrollIndicators(.hidden)
                .onChange(of: conversation.messages.count) {
                    if let dernier = conversation.messages.last?.id {
                        withAnimation { defilement.scrollTo(dernier, anchor: .bottom) }
                    }
                }
            }
            if conversation.dictee { Dictee() } else { champ }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .carte(rayon: 32)
        .gesture(DragGesture(minimumDistance: 20).onEnded { geste in
            if geste.translation.height > 60 { conversation.fermer() }
        })
    }

    private var entete: some View {
        HStack(spacing: 10) {
            Orbe(etat: conversation.etatOrbe, taille: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("HAL").texte(.titreWidget).foregroundStyle(Palette.textePrincipal)
                Text("Voit : \(conversation.contexte)").texte(.legende).foregroundStyle(Palette.texteSecondaire)
            }
            Spacer()
            BoutonRond("chevron.down", libelle: "Fermer HAL") { conversation.fermer() }
        }
        .padding(.horizontal, Espace.interne)
    }

    private var champ: some View {
        HStack(spacing: 8) {
            TextField("Demande à HAL…", text: $texte, axis: .vertical)
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
            .disabled(texte.trimmingCharacters(in: .whitespaces).isEmpty)
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
    let message: Message

    var body: some View {
        HStack {
            if message.auteur == .moi { Spacer(minLength: 48) }
            Text(message.texte)
                .texte(.corps)
                .foregroundStyle(Palette.textePrincipal)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.auteur == .moi ? Categorie.ia.voile : Palette.verreTeinteForte,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if message.auteur == .hal { Spacer(minLength: 48) }
        }
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
            Text("Ton message est gardé. Je réessaie tout seul dès que le serveur répond, ou maintenant :")
                .texte(.legende).foregroundStyle(Palette.texteSecondaire)
            HStack {
                Button("Réessayer") { conversation.reessayer(horsReseau: foyer.essais.horsReseau) }
                    .buttonStyle(.hal(.accent, pleineLargeur: true))
                Button("Plus tard") { conversation.fermer() }
                    .buttonStyle(.hal(.verre, pleineLargeur: true))
            }
        }
        .padding(12)
        .background(Categorie.alerte.voile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// La dictée (ORB-5). L'interface est là ; la reconnaissance de la voix arrive au lot 7.
private struct Dictee: View {
    @Environment(ConversationHAL.self) private var conversation
    @State private var niveau: [CGFloat] = Array(repeating: 0.3, count: 24)

    var body: some View {
        VStack(spacing: 12) {
            Text("J'écoute…").texte(.corps).foregroundStyle(Palette.texteSecondaire)
            HStack(spacing: 3) {
                ForEach(niveau.indices, id: \.self) { rang in
                    Capsule().fill(Categorie.ia.couleur).frame(width: 4, height: 6 + niveau[rang] * 30)
                }
            }
            .frame(height: 40)
            HStack(spacing: 24) {
                bouton("xmark", "Annuler") { conversation.dictee = false; conversation.fermer() }
                bouton("stop.fill", "Envoyer") { conversation.dictee = false }
                bouton("keyboard", "Passer au clavier") { conversation.dictee = false }
            }
        }
        .padding(.horizontal, Espace.interne)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.easeInOut(duration: 0.12)) {
                    niveau = niveau.map { _ in CGFloat.random(in: 0.1...1) }
                }
            }
        }
    }

    private func bouton(_ icone: String, _ libelle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icone).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.textePrincipal).frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .verreControle(Circle())
        .accessibilityLabel(libelle)
    }
}
