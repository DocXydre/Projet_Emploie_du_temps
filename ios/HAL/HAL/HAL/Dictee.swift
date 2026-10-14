import AVFoundation
import Observation
import Speech
import SwiftUI

/// La dictée (ORB-5) : la voix est transcrite en direct, sur le téléphone quand
/// il le permet. Rien n'est enregistré : le texte seul part vers HAL, et
/// seulement quand on touche « Envoyer ».
@MainActor
@Observable
final class Ecoute {
    private(set) var texte = ""
    /// De 0 à 1 : le volume de la voix, pour les barres.
    private(set) var niveau: Float = 0
    private(set) var refus: String?
    private(set) var enCours = false

    private let moteur = AVAudioEngine()
    private var demande: SFSpeechAudioBufferRecognitionRequest?
    private var tache: SFSpeechRecognitionTask?
    private let reconnaisseur = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))

    func commencer() async {
        guard !enCours else { return }
        refus = nil
        texte = ""
        guard await Self.autoriserLaReconnaissance() else {
            refus = "La dictée n'est pas autorisée. Réglages d'iOS, HAL, Reconnaissance vocale."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            refus = "Le micro n'est pas autorisé. Réglages d'iOS, HAL, Micro."
            return
        }
        guard let reconnaisseur, reconnaisseur.isAvailable else {
            refus = "La dictée n'est pas disponible pour l'instant."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let demande = SFSpeechAudioBufferRecognitionRequest()
            demande.shouldReportPartialResults = true
            if reconnaisseur.supportsOnDeviceRecognition { demande.requiresOnDeviceRecognition = true }
            self.demande = demande

            Self.brancher(moteur.inputNode, sur: demande) { [weak self] volume in
                Task { @MainActor in self?.niveau = volume }
            }
            moteur.prepare()
            try moteur.start()
            enCours = true
            tache = Self.ecouter(reconnaisseur, demande) { [weak self] lu, fini in
                Task { @MainActor in
                    if let lu { self?.texte = lu }
                    if fini { self?.arreter() }
                }
            }
        } catch {
            refus = "Le micro n'a pas pu démarrer."
            arreter()
        }
    }

    func arreter() {
        if moteur.isRunning {
            moteur.stop()
            moteur.inputNode.removeTap(onBus: 0)
        }
        demande?.endAudio()
        tache?.finish()
        demande = nil
        tache = nil
        enCours = false
        niveau = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Ce qui suit tourne sur le fil du son, hors du fil principal.

    nonisolated private static func autoriserLaReconnaissance() async -> Bool {
        await withCheckedContinuation { suite in
            SFSpeechRecognizer.requestAuthorization { etat in suite.resume(returning: etat == .authorized) }
        }
    }

    nonisolated private static func brancher(_ entree: AVAudioInputNode,
                                             sur demande: SFSpeechAudioBufferRecognitionRequest,
                                             volume: @escaping @Sendable (Float) -> Void) {
        let format = entree.outputFormat(forBus: 0)
        entree.installTap(onBus: 0, bufferSize: 1024, format: format) { tampon, _ in
            demande.append(tampon)
            volume(mesurer(tampon))
        }
    }

    nonisolated private static func ecouter(_ reconnaisseur: SFSpeechRecognizer,
                                            _ demande: SFSpeechAudioBufferRecognitionRequest,
                                            resultat: @escaping @Sendable (String?, Bool) -> Void)
        -> SFSpeechRecognitionTask {
        reconnaisseur.recognitionTask(with: demande) { lu, erreur in
            resultat(lu?.bestTranscription.formattedString, erreur != nil || (lu?.isFinal ?? false))
        }
    }

    nonisolated private static func mesurer(_ tampon: AVAudioPCMBuffer) -> Float {
        guard let canal = tampon.floatChannelData?[0], tampon.frameLength > 0 else { return 0 }
        var somme: Float = 0
        for rang in 0..<Int(tampon.frameLength) { somme += canal[rang] * canal[rang] }
        let rms = (somme / Float(tampon.frameLength)).squareRoot()
        return min(1, rms * 12)
    }
}

/// L'écoute dans le panneau : le texte s'écrit en direct ; carré pour envoyer,
/// croix pour annuler, bulle pour passer au clavier (ORB-5).
struct Dictee: View {
    let envoyer: (String) -> Void
    let clavier: (String) -> Void
    @Environment(ConversationHAL.self) private var conversation
    @State private var ecoute = Ecoute()
    @State private var barres: [CGFloat] = Array(repeating: 0.15, count: 24)

    var body: some View {
        VStack(spacing: 12) {
            if let refus = ecoute.refus {
                Text(refus).texte(.legende).foregroundStyle(Palette.texteSecondaire)
                    .multilineTextAlignment(.center)
            } else {
                Text(ecoute.texte.isEmpty ? "J'écoute…" : ecoute.texte)
                    .texte(.corps)
                    .foregroundStyle(ecoute.texte.isEmpty ? Palette.texteSecondaire : Palette.textePrincipal)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 3) {
                    ForEach(barres.indices, id: \.self) { rang in
                        Capsule().fill(Categorie.ia.couleur).frame(width: 4, height: 6 + barres[rang] * 30)
                    }
                }
                .frame(height: 40)
            }
            HStack(spacing: 24) {
                bouton("xmark", "Annuler") {
                    ecoute.arreter()
                    conversation.dictee = false
                }
                bouton("stop.fill", "Envoyer") {
                    let dit = ecoute.texte
                    ecoute.arreter()
                    conversation.dictee = false
                    if !dit.trimmingCharacters(in: .whitespaces).isEmpty { envoyer(dit) }
                }
                .disabled(ecoute.texte.isEmpty)
                bouton("keyboard", "Passer au clavier") {
                    let dit = ecoute.texte
                    ecoute.arreter()
                    conversation.dictee = false
                    clavier(dit)
                }
            }
        }
        .padding(.horizontal, Espace.interne)
        .task { await ecoute.commencer() }
        .onDisappear { ecoute.arreter() }
        .onChange(of: ecoute.niveau) { _, niveau in
            withAnimation(.easeOut(duration: 0.1)) {
                barres.removeFirst()
                barres.append(CGFloat(niveau) * CGFloat.random(in: 0.7...1))
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
