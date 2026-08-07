import CoreImage.CIFilterBuiltins
import SwiftUI

struct PairingQRCodeView: View {
    let payload: String

    var body: some View {
        if let image = qrImage {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .accessibilityLabel("MacLink secure pairing QR code")
        } else {
            ContentUnavailableView("QR unavailable", systemImage: "qrcode")
                .frame(width: 220, height: 220)
        }
    }

    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
