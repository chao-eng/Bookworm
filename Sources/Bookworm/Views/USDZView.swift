import SwiftUI
import AppKit
import SceneKit

/// Loads a bundled USDZ model, frames the camera around its bounding box,
/// auto-rotates it around Y, and lets the user click-and-drag to spin it.
/// USDZ is SceneKit-native — no third-party loader needed.
struct USDZView: NSViewRepresentable {
    var resourceName: String = "Color_orb"
    var spinDuration: Double = 180

    func makeCoordinator() -> Coordinator {
        Coordinator(spinDuration: spinDuration)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true

        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        // Very dim, slightly-cool IBL so PBR materials don't render pure black,
        // but low enough that the red/blue directional lights dominate.
        scene.lightingEnvironment.contents = NSColor(red: 0.32, green: 0.28, blue: 0.42, alpha: 1)
        scene.lightingEnvironment.intensity = 0.45
        view.scene = scene

        if let url = USDZView.locateResource(named: resourceName, ext: "usdz"),
           let loaded = try? SCNScene(url: url) {
            let rotor = SCNNode()
            rotor.name = "USDZRotor"
            for child in loaded.rootNode.childNodes {
                child.removeFromParentNode()
                rotor.addChildNode(child)
            }
            scene.rootNode.addChildNode(rotor)

            frameCamera(in: scene, around: rotor)
            addLights(to: scene)

            let action = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: spinDuration)
            rotor.runAction(SCNAction.repeatForever(action), forKey: "autoSpin")

            context.coordinator.rotorNode = rotor
            context.coordinator.scnView = view
        }

        let pan = NSPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)

        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}

    /// Find a bundled resource without touching `Bundle.module`. `Bundle.module`
    /// is a lazily-initialized static whose initializer calls `fatalError`
    /// when the SPM-generated resource bundle isn't on disk where it expects —
    /// which traps the process with EXC_BREAKPOINT (SIGTRAP) on launch.
    /// We instead look in the candidate paths a packaged .app actually has,
    /// and gracefully return nil if nothing's there so the onboarding view
    /// can just render without the 3D model instead of crashing the app.
    fileprivate static func locateResource(named name: String, ext: String) -> URL? {
        let fm = FileManager.default

        // 1. Directly under the .app's Resources/ (where build-app.sh now
        //    copies the USDZ alongside the SPM bundle).
        if let direct = Bundle.main.url(forResource: name, withExtension: ext),
           fm.fileExists(atPath: direct.path) {
            return direct
        }

        // 2. Inside the SPM-generated resource bundle that lives at
        //    Contents/Resources/Bookworm_Bookworm.bundle/<name>.<ext>.
        let spmBundle = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Bookworm_Bookworm.bundle")
            .appendingPathComponent("\(name).\(ext)")
        if fm.fileExists(atPath: spmBundle.path) {
            return spmBundle
        }

        // 3. Next to the executable when running via `swift run` (no .app).
        let next = Bundle.main.bundleURL
            .appendingPathComponent("Bookworm_Bookworm.bundle")
            .appendingPathComponent("\(name).\(ext)")
        if fm.fileExists(atPath: next.path) {
            return next
        }

        return nil
    }

    private func frameCamera(in scene: SCNScene, around node: SCNNode) {
        let (minB, maxB) = node.boundingBox
        let center = SCNVector3(
            (minB.x + maxB.x) / 2,
            (minB.y + maxB.y) / 2,
            (minB.z + maxB.z) / 2
        )
        let size = SCNVector3(
            maxB.x - minB.x,
            maxB.y - minB.y,
            maxB.z - minB.z
        )
        let radius = max(size.x, max(size.y, size.z)) / 2.0
        // 3.6× radius pulls the camera back far enough to leave a comfortable
        // margin around the model at the chosen FOV — so it never clips even
        // when the user drags it around.
        let dist = max(radius * 3.6, 0.5)

        let camera = SCNCamera()
        camera.fieldOfView = 34
        camera.zNear = max(0.001, Double(radius) * 0.001)
        camera.zFar = Double(radius) * 50 + 100
        camera.wantsHDR = true

        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(
            center.x,
            center.y + radius * 0.10,
            center.z + dist
        )
        camNode.look(at: center)
        scene.rootNode.addChildNode(camNode)
    }

    /// Two strong directional lights — red from the right, blue from the left —
    /// plus a faint cool ambient so the shadow side keeps some definition
    /// without washing out the colored rims.
    private func addLights(to scene: SCNScene) {
        let red = SCNLight()
        red.type = .directional
        red.intensity = 1800
        red.color = NSColor(red: 1.0, green: 0.18, blue: 0.30, alpha: 1)
        let redNode = SCNNode()
        redNode.light = red
        // Pitched down + rotated to come from upper-right.
        redNode.eulerAngles = SCNVector3(-0.30, -0.70, 0)
        scene.rootNode.addChildNode(redNode)

        let blue = SCNLight()
        blue.type = .directional
        blue.intensity = 1800
        blue.color = NSColor(red: 0.20, green: 0.45, blue: 1.0, alpha: 1)
        let blueNode = SCNNode()
        blueNode.light = blue
        // Pitched down + rotated to come from upper-left.
        blueNode.eulerAngles = SCNVector3(-0.30, 0.70, 0)
        scene.rootNode.addChildNode(blueNode)

        // A subtle counter-fill from below so the bottom isn't pitch black —
        // a cool magenta blend of the two key colors keeps the palette tight.
        let bottom = SCNLight()
        bottom.type = .directional
        bottom.intensity = 250
        bottom.color = NSColor(red: 0.55, green: 0.30, blue: 0.75, alpha: 1)
        let bottomNode = SCNNode()
        bottomNode.light = bottom
        bottomNode.eulerAngles = SCNVector3(0.85, 0, 0)
        scene.rootNode.addChildNode(bottomNode)

        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 120
        amb.color = NSColor(red: 0.45, green: 0.35, blue: 0.55, alpha: 1)
        let ambNode = SCNNode()
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)
    }

    final class Coordinator: NSObject {
        let spinDuration: Double
        weak var scnView: SCNView?
        weak var rotorNode: SCNNode?
        private var dragStartYaw: CGFloat = 0
        private var dragStartPitch: CGFloat = 0

        init(spinDuration: Double) { self.spinDuration = spinDuration }

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard let view = scnView, let rotor = rotorNode else { return }
            switch gesture.state {
            case .began:
                rotor.removeAllActions()
                dragStartYaw = rotor.eulerAngles.y
                dragStartPitch = rotor.eulerAngles.x
            case .changed:
                let t = gesture.translation(in: view)
                let yaw = dragStartYaw + t.x * 0.012
                let pitchClamp: CGFloat = .pi / 2 - 0.05
                let pitch = max(-pitchClamp,
                                min(pitchClamp, dragStartPitch + t.y * 0.012))
                rotor.eulerAngles = SCNVector3(pitch, yaw, 0)
            case .ended, .cancelled, .failed:
                let action = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0,
                                                 duration: spinDuration)
                rotor.runAction(SCNAction.repeatForever(action), forKey: "autoSpin")
            default:
                break
            }
        }
    }
}
