//
//  main.swift
//  simforge-cli
//
//  Created by Matteo Zappia on 1/17/25.
//

import Foundation

// MARK: - Constants
let appsDirectory = "apps"
let simforgeBinary = ".build/release/simforge"
let configFile = ".simforge_config"

// MARK: - Configuration
struct Config: Codable {
    var simulatorUDID: String?
}

func loadConfig() -> Config {
    if !FileManager.default.fileExists(atPath: configFile) {
        // Create empty config if it doesn't exist
        let config = Config()
        saveConfig(config)
        return config
    }
    
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configFile)),
          let config = try? JSONDecoder().decode(Config.self, from: data) else {
        return Config()
    }
    return config
}

func saveConfig(_ config: Config) {
    guard let data = try? JSONEncoder().encode(config) else { return }
    try? data.write(to: URL(fileURLWithPath: configFile))
}

// MARK: - Utilities
func printStep(_ message: String) {
    print("==> " + message)
}

func printError(_ message: String) {
    print("Error: " + message)
}

func printSuccess(_ message: String) {
    print(message)
}

// MARK: - Simulator Management
func getSimulators() -> [(name: String, udid: String)] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "list", "devices", "available", "-j"]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    
    do {
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devices = json["devices"] as? [String: [[String: Any]]] {
            
            var simulators: [(name: String, udid: String)] = []
            for (runtime, deviceList) in devices where runtime.contains("iOS") {
                for device in deviceList {
                    if let name = device["name"] as? String,
                       let udid = device["udid"] as? String,
                       let isAvailable = device["isAvailable"] as? Bool,
                       isAvailable {
                        simulators.append((name: "\(name) (\(runtime))", udid: udid))
                    }
                }
            }
            return simulators
        }
    } catch {
        printError("Failed to get simulators: \(error)")
    }
    
    return []
}

// MARK: - Code Signing
func getSigningIdentities() -> [(name: String, id: String)] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-identity", "-v", "-p", "codesigning"]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    
    do {
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        
        return output.components(separatedBy: .newlines)
            .compactMap { line -> (name: String, id: String)? in
                let parts = line.split(separator: ")")
                guard parts.count >= 2 else { return nil }
                let id = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let name = String(parts[1]).trimmingCharacters(in: .whitespaces)
                return (name: name, id: id)
            }
    } catch {
        printError("Failed to get signing identities: \(error)")
    }
    
    return []
}

// Add this function before processApp
func isIPAEncrypted(tempDir: URL) -> Bool {
    let scInfoPath = tempDir.appendingPathComponent("Payload").appendingPathComponent("SC_Info")
    return FileManager.default.fileExists(atPath: scInfoPath.path)
}

// MARK: - App Processing
func processApp(at path: String, signingIdentity: String, simulatorUDID: String) {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    
    do {
        // Create temp directory
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let appPath: URL
        if path.hasSuffix(".ipa") {
            // Extract IPA
            printStep("Extracting IPA...")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", path, "-d", tempDir.path]
            try process.run()
            process.waitUntilExit()
            
            // Check if IPA is encrypted
            if isIPAEncrypted(tempDir: tempDir) {
                throw NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "The IPA file is encrypted. Please provide a decrypted IPA."])
            }
            
            // Find .app in Payload directory
            let payloadDir = tempDir.appendingPathComponent("Payload")
            guard let appBundle = try FileManager.default.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "No .app bundle found in IPA"])
            }
            appPath = appBundle
        } else {
            // Copy .app bundle
            let destination = tempDir.appendingPathComponent((path as NSString).lastPathComponent)
            try FileManager.default.copyItem(atPath: path, toPath: destination.path)
            appPath = destination
        }
        
        // Run simforge
        printStep("Converting app for simulator...")
        let simforge = Process()
        simforge.executableURL = URL(fileURLWithPath: simforgeBinary)
        simforge.arguments = [appPath.path]
        try simforge.run()
        simforge.waitUntilExit()
        
        // Sign frameworks
        let frameworksPath = appPath.appendingPathComponent("Frameworks")
        if FileManager.default.fileExists(atPath: frameworksPath.path) {
            printStep("Signing frameworks...")
            let frameworks = try FileManager.default.contentsOfDirectory(atPath: frameworksPath.path)
            for framework in frameworks {
                let frameworkPath = frameworksPath.appendingPathComponent(framework)
                let codesign = Process()
                codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                codesign.arguments = ["-f", "-s", signingIdentity, frameworkPath.path]
                try codesign.run()
                codesign.waitUntilExit()
            }
        }
        
        // Sign main bundle
        printStep("Signing main bundle...")
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["-f", "-s", signingIdentity, appPath.path]
        try codesign.run()
        codesign.waitUntilExit()
        
        // Boot simulator if needed and install app
        bootSimulator(simulatorUDID)
        
        printStep("Installing to simulator...")
        let install = Process()
        install.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        install.arguments = ["simctl", "install", simulatorUDID, appPath.path]
        try install.run()
        install.waitUntilExit()
        
        // Launch the app
        printStep("Launching app...")
        let bundleID = try getBundleID(from: appPath)
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        launch.arguments = ["simctl", "launch", simulatorUDID, bundleID]
        try launch.run()
        launch.waitUntilExit()
        
        printSuccess("Successfully processed and installed the app!")
    } catch {
        printError("Failed to process app: \(error)")
    }
}

func getBundleID(from appPath: URL) throws -> String {
    let plist = Process()
    plist.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
    plist.arguments = ["-c", "Print :CFBundleIdentifier", appPath.appendingPathComponent("Info.plist").path]
    
    let pipe = Pipe()
    plist.standardOutput = pipe
    
    try plist.run()
    plist.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let bundleID = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get bundle ID"])
    }
    
    return bundleID
}

// MARK: - Simulator Management
func bootSimulator(_ udid: String) {
    printStep("Checking simulator status...")
    
    // Launch Simulator.app first
    printStep("Launching Simulator.app...")
    let launchSimulator = Process()
    launchSimulator.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launchSimulator.arguments = ["-a", "Simulator"]
    
    do {
        try launchSimulator.run()
        launchSimulator.waitUntilExit()
        
        // Give Simulator.app time to initialize
        Thread.sleep(forTimeInterval: 2)
        
        // Check simulator state
        let stateProcess = Process()
        stateProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        stateProcess.arguments = ["simctl", "list", "devices", "-j"]
        
        let statePipe = Pipe()
        stateProcess.standardOutput = statePipe
        
        try stateProcess.run()
        stateProcess.waitUntilExit()
        
        let data = statePipe.fileHandleForReading.readDataToEndOfFile()
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devices = json["devices"] as? [String: [[String: Any]]] {
            
            var isBooted = false
            for deviceList in devices.values {
                if let device = deviceList.first(where: { ($0["udid"] as? String) == udid }),
                   let state = device["state"] as? String {
                    isBooted = state == "Booted"
                    break
                }
            }
            
            if !isBooted {
                printStep("Booting simulator device...")
                let bootProcess = Process()
                bootProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                bootProcess.arguments = ["simctl", "boot", udid]
                try bootProcess.run()
                bootProcess.waitUntilExit()
                
                // Wait for simulator to be ready
                printStep("Waiting for simulator to be ready...")
                Thread.sleep(forTimeInterval: 5)
            }
        }
    } catch {
        printError("Failed to manage simulator: \(error)")
    }
}

// MARK: - Main
func main() {
    print("Simforge CLI")
    print("------------")
    
    do {
        // Verify simforge exists
        guard FileManager.default.fileExists(atPath: simforgeBinary) else {
            printError("simforge binary not found. Please run 'swift build -c release' first.")
            return
        }
        
        // Create apps directory if needed
        try FileManager.default.createDirectory(atPath: appsDirectory, withIntermediateDirectories: true)
        
        // Get available apps
        let apps = try FileManager.default.contentsOfDirectory(atPath: appsDirectory)
            .filter { $0.hasSuffix(".app") || $0.hasSuffix(".ipa") }
        
        guard !apps.isEmpty else {
            printError("No .app or .ipa files found in the apps directory")
            return
        }
        
        // Get signing identities
        let identities = getSigningIdentities()
        guard !identities.isEmpty else {
            printError("No signing identities found")
            return
        }
        
        // Get simulators
        let simulators = getSimulators()
        guard !simulators.isEmpty else {
            printError("No simulators found")
            return
        }
        
        // Select app
        print("\nAvailable apps:")
        for (index, app) in apps.enumerated() {
            print("[\(index + 1)] \(app)")
        }
        print("\nSelect app (1-\(apps.count)): ", terminator: "")
        guard let appInput = readLine(),
              let appIndex = Int(appInput),
              appIndex > 0 && appIndex <= apps.count else {
            printError("Invalid selection")
            return
        }
        let selectedApp = apps[appIndex - 1]
        
        // Select signing identity
        print("\nAvailable signing identities:")
        for (index, identity) in identities.enumerated() {
            print("[\(index + 1)] \(identity.name)")
        }
        print("\nSelect signing identity (1-\(identities.count)): ", terminator: "")
        guard let identityInput = readLine(),
              let identityIndex = Int(identityInput),
              identityIndex > 0 && identityIndex <= identities.count else {
            printError("Invalid selection")
            return
        }
        let selectedIdentity = identities[identityIndex - 1]
        
        // Load config and check for saved simulator
        let config = loadConfig()
        let simulatorUDID: String
        
        if let savedUDID = config.simulatorUDID,
           simulators.contains(where: { $0.udid == savedUDID }) {
            // Use saved simulator
            simulatorUDID = savedUDID
            if let simulator = simulators.first(where: { $0.udid == savedUDID }) {
                printStep("Using saved simulator: \(simulator.name)")
            }
        } else {
            // Select simulator
            print("\nAvailable simulators:")
            for (index, simulator) in simulators.enumerated() {
                print("[\(index + 1)] \(simulator.name)")
            }
            print("\nSelect simulator (1-\(simulators.count)): ", terminator: "")
            guard let simulatorInput = readLine(),
                  let simulatorIndex = Int(simulatorInput),
                  simulatorIndex > 0 && simulatorIndex <= simulators.count else {
                printError("Invalid selection")
                return
            }
            simulatorUDID = simulators[simulatorIndex - 1].udid
        }
        
        // Process the app
        let appPath = (appsDirectory as NSString).appendingPathComponent(selectedApp)
        processApp(at: appPath, signingIdentity: selectedIdentity.id, simulatorUDID: simulatorUDID)
        
    } catch {
        printError("\(error)")
    }
}

main() 