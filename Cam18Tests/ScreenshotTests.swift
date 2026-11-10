import SwiftUI
import UIKit
import XCTest
@testable import Cam18

/// Takes pictures of the camera screen for the CI artifact, so the UI can be
/// judged without a device. The simulator has no camera, so a styled sample
/// photo stands in for the live preview. These never fail the build: if the
/// simulator can't produce a screenshot, the test is skipped.
final class ScreenshotTests: XCTestCase {
    @MainActor
    func testCameraScreenScreenshots() throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("No window scene to draw in")
        }
        let sample = try TestSupport.sample("portrait")
        // The viewfinder is 3:4, so use the middle of the landscape sample.
        let crop = CGRect(x: sample.extent.midX - sample.extent.height * 0.375, y: sample.extent.minY,
                          width: sample.extent.height * 0.75, height: sample.extent.height)
        var recipe = StyleRecipe(look: .film, intensity: 0.5)
        recipe.colorStyle = .warmGold
        recipe.styleIntensity = 0.8
        let styled = StylePipeline.render(sample.cropped(to: crop), recipe: recipe)
        guard let cg = TestSupport.context.createCGImage(styled, from: styled.extent) else {
            throw XCTSkip("Couldn't render the stand-in photo")
        }
        let photo = UIImage(cgImage: cg)

        let shots: [(String, Panel?)] = [("ui-camera", nil), ("ui-style-panel", .style),
                                         ("ui-adjust-panel", .adjust), ("ui-film-panel", .film)]
        for (name, panel) in shots {
            let window = UIWindow(windowScene: scene)
            let root = ContentView(demoImage: photo, demoPanel: panel).preferredColorScheme(.dark)
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))

            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            guard let data = image.pngData() else { continue }
            let url = TestSupport.outputDirectory.appendingPathComponent(name).appendingPathExtension("png")
            try? data.write(to: url)
        }
    }
}
