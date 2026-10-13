import SwiftUI

/// L'orbe de HAL : un iris qui tourne quand il réfléchit, un « ! » quand il a
/// quelque chose à dire (ORB-4). Le logo de l'appli est le même iris.
struct Orbe: View {
    let etat: EtatOrbe
    var taille: CGFloat = 56
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var mouvementReduit
    @State private var rotation = 0.0
    @State private var pulsation = false

    var body: some View {
        ZStack {
            Circle().fill(Palette.fondOrbe)
            Circle()
                .fill(theme.secondaire)
                .frame(width: taille * 0.54, height: taille * 0.54)
                .blur(radius: etat == .active ? 14 : 10)
            if etat == .recap {
                Circle()
                    .fill(AngularGradient(colors: [theme.principal, theme.secondaire, theme.principal], center: .center))
                    .frame(width: taille * 0.64, height: taille * 0.64)
                Text("!")
                    .font(.system(size: taille * 0.43, weight: .heavy))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .fill(AngularGradient(colors: [theme.principal, theme.secondaire, theme.principal], center: .center))
                    .frame(width: taille * (etat == .active ? 0.71 : 0.64), height: taille * (etat == .active ? 0.71 : 0.64))
                    .rotationEffect(.degrees(rotation))
                Circle()
                    .fill(RadialGradient(colors: [.white, .white.opacity(0.85), theme.secondaire],
                                         center: .center, startRadius: 0, endRadius: taille * 0.13))
                    .frame(width: taille * 0.25, height: taille * 0.25)
            }
            Circle().strokeBorder(.white.opacity(bord), lineWidth: 1)
        }
        .frame(width: taille, height: taille)
        .scaleEffect(pulsation ? 1.06 : 1)
        .shadow(color: theme.secondaire.opacity(0.45), radius: 12)
        .onAppear(perform: animer)
        .onChange(of: etat) { animer() }
        .accessibilityHidden(true)
    }

    private var bord: Double {
        switch etat {
        case .repos: 0.35
        case .active: 0.8
        case .recap: 0.9
        }
    }

    private func animer() {
        guard !mouvementReduit else { return }
        if etat == .active {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { rotation += 360 }
        } else {
            withAnimation(.smooth(duration: 0.4)) { rotation = 0 }
        }
        if etat == .recap {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsation = true }
        } else {
            withAnimation(.smooth) { pulsation = false }
        }
    }
}
