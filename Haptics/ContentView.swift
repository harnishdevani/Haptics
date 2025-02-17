import SwiftUI
import ARKit
import CoreHaptics
import RealityKit
import AVFoundation

// MARK: - Audio Engine
class AudioEngine {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastAnnouncementTime: Date = Date()
    private let minimumAnnouncementInterval: TimeInterval = 2.0
    
    func speak(_ message: String) {
        let currentTime = Date()
        guard currentTime.timeIntervalSince(lastAnnouncementTime) >= minimumAnnouncementInterval else {
            return
        }
        
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "it-IT")
        utterance.rate = 0.5
        utterance.volume = 1.0
        synthesizer.speak(utterance)
        lastAnnouncementTime = currentTime
    }
}

// MARK: - Haptic Engine
class HapticEngine {
    private var engine: CHHapticEngine?
    
    init() {
        prepareHapticEngine()
    }
    
    private func prepareHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        
        do {
            engine = try CHHapticEngine()
            try engine?.start()
            
            engine?.resetHandler = { [weak self] in
                print("Restarting Haptic Engine...")
                do {
                    try self?.engine?.start()
                } catch {
                    print("Failed to restart engine: \(error.localizedDescription)")
                }
            }
        } catch {
            print("Failed to start haptic engine: \(error.localizedDescription)")
        }
    }
    
    func playObstacleWarning(intensity: Float) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let engine = engine else { return }
        
        do {
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            print("Failed to play haptic pattern: \(error.localizedDescription)")
        }
    }
}

// MARK: - Obstacle Detection Manager
class ObstacleDetectionManager: NSObject, ObservableObject, ARSessionDelegate {
    private var session: ARSession?
    private let hapticEngine: HapticEngine
    private let audioEngine: AudioEngine
    
    @Published var currentDistance: Double = 5.0
    @Published var obstacleDirection: String = "Clear"
    @Published var lowerHeightObstacleDetected: Bool = false
    
    // Track if an obstacle has been announced
    private var hasAnnouncedObstacle: Bool = false
    private var hasAnnouncedLowerHeightObstacle: Bool = false
    
    // Track the last detected obstacle direction
    private var lastObstacleDirection: String = "Clear"
    
    override init() {
        hapticEngine = HapticEngine()
        audioEngine = AudioEngine()
        super.init()
        setupAR()
    }
    
    private func setupAR() {
        guard ARWorldTrackingConfiguration.isSupported else {
            audioEngine.speak("AR is not supported on this device")
            return
        }
        
        session = ARSession()
        session?.delegate = self
        
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal] // Enable horizontal plane detection
        if type(of: configuration).supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = .sceneDepth
        }
        
        session?.run(configuration)
        audioEngine.speak("Navigation assistant ready")
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depthMap = frame.sceneDepth?.depthMap else { return }
        processDepthMap(depthMap)
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        print("AR Session failed: \(error.localizedDescription)")
        audioEngine.speak("Navigation system encountered an error")
    }
    
    private func processDepthMap(_ depthMap: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        // Define regions for directional detection
        let regionWidth = width / 3
        var regionDepths: [String: Float] = [:]
        let regions = [
            "Left": 0..<regionWidth,
            "Center": regionWidth..<(2 * regionWidth),
            "Right": (2 * regionWidth)..<width
        ]
        
        // Track lower-height obstacles
        var lowerHeightObstacleDetected = false
        
        // Process each region at multiple heights
        for (region, xRange) in regions {
            var totalDepth: Float = 0
            var samplesCount = 0
            
            for x in xRange {
                // Sample from multiple heights (e.g., middle and lower regions)
                for y in [height / 2, height * 3 / 4] {
                    let offset = (y * bytesPerRow / MemoryLayout<Float32>.stride) + Int(x)
                    let depth = floatBuffer[offset]
                    
                    if depth > 0 && depth < 5.0 {
                        totalDepth += depth
                        samplesCount += 1
                        
                        // Check for lower-height obstacles
                        if y >= height * 3 / 4 && depth < 1.5 {
                            lowerHeightObstacleDetected = true
                        }
                    }
                }
            }
            
            if samplesCount > 0 {
                regionDepths[region] = totalDepth / Float(samplesCount)
            }
        }
        
        DispatchQueue.main.async {
            // Update overall distance and haptic feedback
            if let center = regionDepths["Center"] {
                self.currentDistance = Double(center)
                self.provideFeedback(depth: Double(center))
            }
            
            // Update obstacle direction
            if let left = regionDepths["Left"], let center = regionDepths["Center"], let right = regionDepths["Right"] {
                if center < 1.0 {
                    self.obstacleDirection = "Centro"
                } else if left < 1.0 {
                    self.obstacleDirection = "Sinistra"
                } else if right < 1.0 {
                    self.obstacleDirection = "Destra"
                } else {
                    self.obstacleDirection = "Chiaro"
                }
                
                // Announce obstacle only if the direction has changed
                if self.obstacleDirection != self.lastObstacleDirection {
                    self.announceObstacle(direction: self.obstacleDirection)
                    self.lastObstacleDirection = self.obstacleDirection
                }
            }
            
            // Announce lower-height obstacles
            if lowerHeightObstacleDetected && !self.hasAnnouncedLowerHeightObstacle {
                self.audioEngine.speak("Rilevato ostacolo di altezza inferiore")
                self.hasAnnouncedLowerHeightObstacle = true
            } else if !lowerHeightObstacleDetected {
                self.hasAnnouncedLowerHeightObstacle = false
            }
        }
    }
    
    private func announceObstacle(direction: String) {
        guard direction != "Clear" else {
            hasAnnouncedObstacle = false // Reset announcement state
            return
        }
        
        guard !hasAnnouncedObstacle else { return } // Announce only once
        
        switch direction {
        case "Center":
            audioEngine.speak("Ostacolo direttamente davanti a sé")
        case "Left":
            audioEngine.speak("Ostacolo alla tua sinistra")
        case "Right":
            audioEngine.speak("Ostacolo alla tua destra")
        default:
            break
        }
        
        hasAnnouncedObstacle = true // Mark as announced
    }
    
    private func provideFeedback(depth: Double) {
        // Haptic feedback intensity increases as obstacle gets closer
        let maxDistance: Double = 5.0
        let intensity = Float((maxDistance - min(depth, maxDistance)) / maxDistance)
        hapticEngine.playObstacleWarning(intensity: intensity)
        
        // Audio feedback only within 2 meters
        if depth < 2.0 {
            if depth < 1.0 {
                audioEngine.speak("Ostacolo molto vicino, muoversi con cautela")
            } else {
                audioEngine.speak("Ostacolo rilevato a \(String(format: "%.1f", depth)) metri")
            }
        }
    }
    
    func stopSession() {
        session?.pause()
        audioEngine.speak("Navigation assistant stopped")
    }
}

// MARK: - Visual Overlay View
struct VisualOverlayView: View {
    @Binding var obstacleDirection: String
    @Binding var lowerHeightObstacleDetected: Bool

    var body: some View {
        ZStack {
            if obstacleDirection == "Left" {
                Text("⬅️").font(.largeTitle).foregroundColor(.red)
            } else if obstacleDirection == "Right" {
                Text("➡️").font(.largeTitle).foregroundColor(.red)
            } else if obstacleDirection == "Center" {
                Text("⬆️").font(.largeTitle).foregroundColor(.red)
            } else {
                Text("✔️ Clear").font(.largeTitle).foregroundColor(.green)
            }
            
            if lowerHeightObstacleDetected {
                Text("⚠️ Lower-height obstacle").font(.headline).foregroundColor(.orange)
            }
        }
    }
}

// MARK: - Content View
struct ContentView: View {
    @StateObject private var obstacleManager = ObstacleDetectionManager()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Indoor Navigation Assistant")
                .font(.title)
                .padding()
            
            VStack {
                Text("Detected Obstacle Distance")
                    .font(.headline)
                Text(String(format: "%.2f meters", obstacleManager.currentDistance))
                    .font(.title2)
                
                if obstacleManager.currentDistance < 1.0 {
                    Text("⚠️ Obstacle Nearby!")
                        .foregroundColor(.red)
                        .font(.headline)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            
            VisualOverlayView(obstacleDirection: $obstacleManager.obstacleDirection,
                             lowerHeightObstacleDetected: $obstacleManager.lowerHeightObstacleDetected)
                .padding()
            
            Text("Move the device around to detect obstacles")
                .font(.caption)
                .foregroundColor(.gray)
                .padding()
        }
        .padding()
    }
}
