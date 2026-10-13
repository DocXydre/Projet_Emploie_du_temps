import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Déduit deux couleurs d'une photo (THM-4) : sa teinte moyenne, ravivée pour
/// les boutons, et une teinte voisine pour l'orbe.
enum CouleursPhoto {
    private static let contexte = CIContext(options: [.workingColorSpace: NSNull()])

    static func theme(depuis image: UIImage) -> Theme? {
        guard let entree = CIImage(image: image) else { return nil }
        let filtre = CIFilter.areaAverage()
        filtre.inputImage = entree
        filtre.extent = entree.extent
        guard let sortie = filtre.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        contexte.render(sortie, toBitmap: &pixel, rowBytes: 4,
                        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                        format: .RGBA8, colorSpace: nil)

        let moyenne = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                              blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var teinte: CGFloat = 0, saturation: CGFloat = 0, luminosite: CGFloat = 0, alpha: CGFloat = 0
        moyenne.getHue(&teinte, saturation: &saturation, brightness: &luminosite, alpha: &alpha)

        // Une photo presque grise donne une couleur pâle et lisible plutôt qu'un gris sale.
        let saturationVive = saturation < 0.08 ? 0.12 : max(0.45, min(0.75, saturation * 1.6))
        let principal = UIColor(hue: teinte, saturation: saturationVive, brightness: 0.92, alpha: 1)
        let voisine = (teinte + 0.12).truncatingRemainder(dividingBy: 1)
        let secondaire = UIColor(hue: voisine, saturation: saturationVive * 0.8, brightness: 0.95, alpha: 1)
        return Theme(principal: Color(principal), secondaire: Color(secondaire))
    }
}
